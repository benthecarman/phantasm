# QR pairing

Design for pairing the app with a backend by scanning a QR code instead of
typing a URL and bearer token by hand. Referenced from
[`SPEC.md`](SPEC.md) §2.2d / FR-A12 / FR-O10.

## Problem

Backend setup today is manual: the user types a base URL and pastes a bearer
token into the onboarding or profile-edit form (FR-A1). Tokens are long random
strings; typing one on a phone keyboard is the worst step of first-run, and
it's repeated for every device and every profile.

A backend connection is fully described by `{url, token?, name?}` (design
principle §1.1: "URL + token, nothing else"). Pairing is therefore a pure
*transport* problem — get those three strings onto the phone — not an auth
protocol problem. This design deliberately does **not** add token issuance,
per-device credentials, or a challenge/response exchange (see "Alternatives
considered").

## The pairing URI (the contract piece)

A single URI format that doubles as QR payload and tappable deep link:

```
phantasm://pair?v=1&url=<percent-encoded base URL>&token=<token>&name=<label>
```

| Param   | Required | Meaning                                                        |
|---------|----------|----------------------------------------------------------------|
| `v`     | yes      | Format version. This document defines `1`.                     |
| `url`   | yes      | Backend base URL, `http`/`https` only. Percent-encoded.        |
| `token` | no       | Bearer token. Absent ⇒ unauthenticated backend (bare Ollama, orchestrator with auth disabled). |
| `name`  | no       | Human label for the profile. Absent ⇒ the app derives one from the host. |

Rules:

- **Parsing.** Scheme `phantasm`, authority `pair`. `v` ≠ `1` ⇒ reject with an
  "update the app" message (never partially import). Unknown params are
  **ignored** (forward compatibility — a v1 app must tolerate extra params a
  later producer adds, which is why breaking changes bump `v` instead).
- **URL normalization.** The `url` value goes through the same
  `BackendProfile.normalizedBaseURLString` path as typed input (trailing `/`
  and `/v1` stripped), so `https://host/v1` in a QR behaves like the pasted
  form.
- **Producer-agnostic.** The format is an app-side convention, not a server
  endpoint. Anything can mint one — the orchestrator (below), another phone
  running the app, or `qrencode` in a shell script pointed at a bare Ollama.
  This is what keeps pairing working for backends that aren't the
  orchestrator, preserving XR-1.
- **The URI is a credential.** It embeds the bearer token verbatim. Producers
  and consumers MUST treat it like the token itself: never logged (NFR-O7
  applies to it on the server; the app must exclude it from logs and
  analytics), never rendered persistently without a warning, never sent to a
  third party.

Why a URI and not bare JSON: the same string scanned by the **system** Camera
app deep-links straight into Phantasm (no in-app scanner needed in the happy
path), and it can be shared over AirDrop/Messages between trusted devices as a
tappable link. JSON in a QR would require the in-app scanner always.

## App behavior (FR-A12)

### Scanning / receiving

Two entry points, one flow:

1. **In-app scanner** — a "Scan QR code" button on the onboarding screen and
   on the profile list in Settings. Uses `DataScannerViewController` (needs
   `NSCameraUsageDescription`). Camera access is requested explicitly before
   the scanner mounts; denied access or unsupported hardware degrades to an
   explanatory fallback with a paste-the-pairing-link action (plus an Open
   Settings shortcut when denied) — scanning is an accelerator, never the
   only path, and the manual form always remains.
2. **Deep link** — the app registers the `phantasm://` URL scheme
   (`project.yml` → re-run `xcodegen generate`) and handles `onOpenURL`, so a
   QR scanned with the system Camera, or a URI tapped in Messages, lands in
   the same flow.

Flow after a URI is received, from either entry point:

1. Parse + validate per the rules above. Malformed ⇒ one error alert, nothing
   saved.
2. **The standard backend editor, prefilled** — always. Pairing is not a
   separate save path: the payload lands in the same Add/Edit Backend screen
   as manual entry, with name, URL, and token filled in, so Test Connection
   (FR-A1's unreachable / auth-failed / no-models surfaces) and the
   default-model picker come for free — models auto-load on open. Nothing is
   stored until the user reviews the address and taps Save; that explicit
   review-then-save is the mitigation for both hostile-QR redirection
   (someone re-points your app at their server to harvest your prompts) and
   iOS custom-scheme hijacking (another app claiming `phantasm://` is
   possible; universal links would fix it but require developer-hosted web
   infrastructure, out of scope per §7). Saving is allowed without a
   successful probe (the backend might be off right now) — same affordance
   as manual entry.
3. **Save.** Token → Keychain keyed by profile id (NFR-A2); the rest → a
   `BackendProfile` via the normal `ProfileStore` path; the paired profile
   becomes active. **Dedup:** if a profile for the same backend exists —
   matched on a *canonical* URL (host case and default ports ignored, since
   producers normalize differently) — the editor opens *that* profile, so
   re-pairing updates in place (profile id and per-profile preferences kept)
   instead of silently creating a duplicate. On update, a URI that carries
   no token **keeps** the saved token rather than deleting it (the editor's
   Keychain prefill): a QR minted in a shell without `PHANTASM_AUTH_TOKEN`
   must not wipe a working credential.

### Sharing (device → device)

The settings screen for an existing profile gets "Show pairing QR": the app
renders the pairing URI from the profile editor's current connection values
(URL + name + token — prefilled from the Keychain, so what's shared is
what's on screen) as a QR image, generated locally via
`CIFilter.qrCodeGenerator` — no network, no server support. Behind a
confirmation warning that the code grants full access to the backend, and
displayed with screen-capture-conscious styling (no share-sheet export of the
raw URI by default). This is how a second device pairs when the server
terminal isn't handy, and it works for *any* profile, including bare-Ollama
ones the orchestrator never saw.

### PhantasmKit split

Parsing, validation, and generation of the pairing URI live in `PhantasmKit`
(pure logic, host-testable — e.g. `PairingURI.parse(_:) -> PairingPayload?` /
`PairingPayload.uri`), with `swift test` coverage for: round-trip, percent-
encoding of exotic tokens, `/v1` normalization, missing/extra params, wrong
`v`, non-http schemes, and case-insensitivity of scheme/authority. Camera and
QR-image rendering are view code in the app target.

## Orchestrator behavior (optional convenience)

The orchestrator already knows its own token; the same binary gets a `pair`
subcommand so post-install pairing is one line in the terminal:

```sh
phantasm-orchestrator pair                    # URL from PAIR_URL / PUBLIC_BASE_URL
phantasm-orchestrator pair https://host:8080  # or given explicitly
# docker: docker compose run --rm orchestrator pair https://host:8080
```

It prints the pairing URI and an ANSI-rendered QR to the terminal, then
exits — it never starts the server, and it can run while a server instance is
up (it reads the same env the service does, so it emits the same token).

- **Invocation mode, not config.** The env-only config rule (NFR-O4) governs
  *settings*; `pair` is a subcommand of the existing binary (no CLI args
  exist today — the bare invocation stays the server, so nothing breaks).
  The optional positional argument overrides the embedded URL for the
  one-off case where `PUBLIC_BASE_URL` isn't configured.
- **Partial-env friendly.** `pair` reads only `PHANTASM_AUTH_TOKEN` and the
  URL (arg > `PAIR_URL` > `PUBLIC_BASE_URL`); it must not require the rest of
  `Config::from_env` (upstream vars etc.), so it works right after install
  before the deployment is fully wired. Missing URL ⇒ exit non-zero with one
  line naming the arg/vars. No LAN-IP guessing: the address the *phone* can
  reach (LAN IP, DNS name, or hosted hostname) is deployment knowledge the
  server can't reliably infer, and a QR that encodes the wrong host is worse
  than no QR. Unset token ⇒ emit a token-less URI (auth-disabled deployment)
  with a warning mirroring the server's own auth-disabled warning.
- **Interactive-only emission.** There is deliberately *no* print-at-startup
  mode: the QR is the bearer token, and service stderr gets log-shipped and
  scrolled-back. A human running `pair` in a terminal is a deliberate act
  (same spirit as `LOG_MESSAGE_CONTENT` gating).
- `name` in the emitted URI defaults to the host of the embedded URL.
- **Not on the dashboard.** The dashboard is gated by `PHANTASM_METRICS_TOKEN`
  precisely so that credential never grants chat access; rendering a
  chat-token QR there would collapse that separation. If a browser-served QR
  is ever wanted, it must be a main-token-gated route — deferred until asked
  for.
- No new HTTP surface, no new dependency beyond a small pure-Rust `qrcode`
  crate (terminal rendering only).

Everything else about the server is unchanged — pairing consumes the existing
static `PHANTASM_AUTH_TOKEN`, and the interface contract's HTTP surface (§2)
gains nothing.

## Security considerations

- **The QR is the key.** Anyone who photographs it has the backend. This is
  accepted for the MVP threat model (self-hosted, single-user, token already
  shared across that user's devices): the QR is shown transiently in a
  terminal the operator controls or on a device they own. Both surfaces warn
  before display.
- **Hostile QR / URI injection.** A scanned URI can point anywhere; the
  confirmation sheet showing the host before save is the containment. The app
  never auto-connects, auto-sends history, or auto-activates a profile from a
  URI without that confirmation.
- **No revocation granularity.** All paired devices share the one static
  token; revoking a device means rotating `PHANTASM_AUTH_TOKEN` and re-pairing
  the others. Acceptable at MVP scale; per-device tokens are the premium-layer
  problem (§7).
- **Token never round-trips.** Pairing adds no endpoint that *returns* the
  token; the server only ever emits it to the terminal of whoever runs the
  `pair` subcommand — someone who can already read the env it comes from.

## Alternatives considered

- **Short-lived pairing code + token exchange** (server mints a one-time code,
  QR carries code-not-token, app POSTs it to `/v1/pair` for the real token):
  strictly better hygiene, but it requires the server to *issue* credentials,
  and today it merely *checks* one static env-configured token. Issuance means
  minted-token storage, which breaks the stateless/env-only config model
  (NFR-O4, XR-2) for marginal gain at MVP scale. Deferred; the `v` param
  leaves room for a future `phantasm://pair?v=2&code=…` without breaking v1
  apps.
- **QR on the dashboard**: rejected above (metrics/chat token separation).
- **mDNS/Bonjour discovery** instead of QR: discovers the URL but not the
  token, only works on the same LAN segment, and adds a discovery surface.
  QR carries both halves and is transport-independent.

## Test plan

- **PhantasmKit** (`swift test`): the parsing/round-trip matrix above.
- **App-side manual**: system-Camera deep link path; permission-denied
  degradation; re-pairing an existing backend opens that profile prefilled
  (token kept when the code has none); probe-failure save-anyway.
- **Orchestrator** (`cargo test`): URL precedence (arg > `PAIR_URL` >
  `PUBLIC_BASE_URL` > non-zero exit), emitted URI is well-formed and
  percent-encoded, token-less emission when auth is disabled, and `pair`
  succeeding without the server-only env vars set. Keep the URI construction
  a pure function so these don't shell out.
