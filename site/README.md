# Phantasm marketing site

A static site — plain HTML + CSS, no build step, no dependencies.

## Local preview

```sh
python3 -m http.server 8080 --directory site
```

## Deploy to Cloudflare Pages

Direct upload (no build config needed):

```sh
npx wrangler pages deploy site --project-name phantasm
```

Or connect the repo in the Cloudflare dashboard (Workers & Pages → Create →
Pages → Connect to Git) with:

- **Build command:** *(none)*
- **Build output directory:** `site`
