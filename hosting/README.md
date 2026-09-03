# Hosting notes

The site is static: `index.html`, `admin.html`, `assets/`, `email/`. Any static host works.

## Deep links

Newsletter links use the path style `https://YOUR-SITE/spark-word/014?t=TOKEN`.
That path must be served by `index.html` (an SPA rewrite that keeps the query string).
`index.html` then hops to `/index.html?issue=14&t=TOKEN#spark-word`, reads the token,
stores it, and removes it from the address bar.

| Host | File |
|---|---|
| Netlify | `_redirects` (copy to site root) |
| Vercel | `vercel.json` (copy to site root) |
| Cloudflare Pages | `cloudflare-pages_redirects` → rename to `_redirects` |
| nginx | `nginx.conf.snippet` |
| S3/CloudFront, GitHub Pages, plain folder | no rewrite available → set `url_style = query` in **Settings** (or `sw_settings`) and `urlStyle: "query"` in `assets/spark-word-config.js`. Links become `https://YOUR-SITE/index.html?issue=14&t=TOKEN#spark-word` and need no server support. |

## Supabase Auth redirect

For the one-time verification link (public-link players who claim an email that already
exists) and admin magic links, add your site origin to **Authentication → URL Configuration
→ Redirect URLs** in Supabase, e.g. `https://YOUR-SITE/*`.
