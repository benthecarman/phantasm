# Phantasm marketing site

A static site — plain HTML + CSS, no build step, no dependencies.

## Local preview

```sh
python3 -m http.server 8080 --directory site
```

## Deploy to Cloudflare

The site deploys as an assets-only Worker; [`wrangler.jsonc`](../wrangler.jsonc)
at the repo root points at this directory. Manual deploy:

```sh
npx wrangler deploy
```

Automatic deploys are handled by the Workers Builds Git integration
(Cloudflare dashboard → Workers & Pages → the `phantasm` project): every push
to `master` deploys production, and non-production branches get preview
builds. Build command is empty; the deploy command is `npx wrangler deploy`.
