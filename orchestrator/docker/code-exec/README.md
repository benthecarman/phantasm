# Code-execution sandbox

The `code_exec` tool runs untrusted, model-authored code in a per-execution,
hardened container. This directory holds the sandbox **image**; this README also
covers the one piece the orchestrator can't do for you: the **network egress
firewall**.

## One tool, two network lanes (no app changes)

There is a single `code_exec` tool, advertised in **both** the app's utilities
bucket (always on) and its web-access bucket. The network it gets is chosen per
turn by the app's existing "Web access" toggle — so the app needs no changes:

| Web access | Lane | Network |
|---|---|---|
| off | offline | `--network none` (no internet at all) |
| on | online | `CODE_EXEC_NETWORK` (filtered internet) |

The server infers "web access is on" from the presence of other web tools
(`web_search`, `weather`, …) in the turn. **Caveat:** if `code_exec` is your only
web-access feature, that signal is absent and runs stay offline — enable at least
one other web tool if you want the online lane reachable.

## What the orchestrator does vs. what you do

The orchestrator applies all per-run isolation via container flags:
`--memory`, `--cpus`, `--pids-limit`, `--read-only`, `--tmpfs /tmp`, `--user`,
`--cap-drop ALL`, `--security-opt no-new-privileges`, and it destroys each
container after a single use. It attaches the container to the network named by
`CODE_EXEC_NETWORK` — but it does **not** build or enforce that network's
firewall. That is the deployment step below.

## 1. Build the image

The tag must match `CODE_EXEC_IMAGE` (default `phantasm/code-exec:latest`):

```sh
podman build -t phantasm/code-exec:latest docker/code-exec
# or: docker build -t phantasm/code-exec:latest docker/code-exec
```

Add a language by installing its runtime in the `Dockerfile`, adding a `case` in
`run-code`, and adding the name to `CODE_EXEC_LANGUAGES`.

## 2. Create the egress-filtered network ("internet yes, internal no")

Goal: executed code can reach the public internet but **not** your internal
services (Ollama, ComfyUI), the LAN, or the cloud metadata endpoint. Block these
destinations:

| Range | Why |
|---|---|
| `127.0.0.0/8` | localhost services (e.g. Ollama `:11434`, ComfyUI `:8188`) |
| `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | private LAN / other containers |
| `169.254.0.0/16` | link-local incl. `169.254.169.254` cloud metadata (IAM creds) |

### Docker example

```sh
docker network create phantasm-codeexec
# then DROP egress to internal ranges from that network's subnet:
sudo iptables -I DOCKER-USER -s <phantasm-codeexec-subnet> -d 10.0.0.0/8     -j DROP
sudo iptables -I DOCKER-USER -s <phantasm-codeexec-subnet> -d 172.16.0.0/12  -j DROP
sudo iptables -I DOCKER-USER -s <phantasm-codeexec-subnet> -d 192.168.0.0/16 -j DROP
sudo iptables -I DOCKER-USER -s <phantasm-codeexec-subnet> -d 169.254.0.0/16 -j DROP
# (localhost is already unreachable from a bridge network unless host networking is used)
```

Then set `CODE_EXEC_NETWORK=phantasm-codeexec`.

### Rootless podman note

Rootless podman routes container traffic through a userspace stack
(`pasta`/`slirp4netns`), so the container usually **cannot** see the host's
`127.0.0.1` services by default — a helpful property. Internet egress filtering to
the private ranges above must still be enforced at the host's forwarding layer
(`nftables`/`firewalld`). Verify with the smoke test below before trusting it.

## 3. Enable the tool

In the orchestrator's environment:

```sh
TOOL_CODE_EXEC=true
CODE_EXEC_RUNTIME=podman          # or docker
CODE_EXEC_IMAGE=phantasm/code-exec:latest
CODE_EXEC_NETWORK=phantasm-codeexec
CODE_EXEC_LANGUAGES=python,node,bash,ruby
```

## 4. Smoke test the isolation

With the tool enabled, ask the model to run code that probes the boundary, or test
the image directly:

# The image ENTRYPOINT is `sleep infinity` (pooled containers idle there); the
# orchestrator runs code via `exec`. To invoke the dispatcher directly with `run`,
# override the entrypoint and pass the language as the argument:
```sh
# internet should work:
echo 'import urllib.request; print(urllib.request.urlopen("https://example.com").status)' \
  | podman run --rm -i --entrypoint /usr/local/bin/run-code --network phantasm-codeexec \
      phantasm/code-exec:latest python   # expect: 200

# internal/metadata should FAIL (timeout/refused), not print credentials:
echo 'import urllib.request; print(urllib.request.urlopen("http://169.254.169.254/", timeout=3).read())' \
  | podman run --rm -i --entrypoint /usr/local/bin/run-code --network phantasm-codeexec \
      phantasm/code-exec:latest python   # expect: error, not data
```

After a chat that runs code, confirm no containers are left behind:

```sh
podman ps -a --filter name=phantasm-codeexec   # expect: none lingering
```
