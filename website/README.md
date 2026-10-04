# Website

ClaudeBar's site at **https://claudebar.tddworks.com**: the landing page, the leaderboard page and its globe. Static files only, served by the `claudebar-site` Cloudflare Worker (static assets, so page views cost nothing). The leaderboard data comes from the API at `claudebar-api.tddworks.com`, which lives in a separate, private repo.

Sparkle's update feed is **not** here: `docs/appcast.xml` stays on GitHub Pages, and `docs/index.html` only points to this site.

| Path | Holds |
|---|---|
| `public/index.html` | The landing page. Its contributors grid is written by `scripts/sync-contributors.py` |
| `public/leaderboard/index.html` | The public board; reads `/board` from the API |
| `public/_headers` | The CSP, `nosniff` and caching for every page |
| `public/404.html` | Not found |
| `client/globe.ts` | The globe (three.js), bundled into `public/leaderboard/globe.js` |
| `test/` | Checks on the files that ship: the CSP, text-only board rendering, sample-only names |
| `cloudflare.config.ts` | The Worker and its route `claudebar.tddworks.com/*` |

## Files you won't find in git

`npm run build` makes these, and `.gitignore` keeps them out:

```
docs/screenshots/  docs/sponsors/  docs/app-icon.png      (committed: the one source)
        │  npm run assets — copies into public/
        ▼
website/public/screenshots/  sponsors/  app-icon.png     (git-ignored copies)

website/client/globe.ts  ──esbuild──▶  website/public/leaderboard/globe.js   (git-ignored)
```

So **change a screenshot in `docs/screenshots/`**, never in `website/public/screenshots/`: the copy is replaced on every build. `docs/` stays the source because the README shows the same images.

New screenshots come from the real app running on sample data only, with no real account, email or usage: `scripts/demo-screenshots.sh [app] [theme]`.

## Develop

```bash
cd website
npm ci
npm run build                       # copy the assets, bundle the globe
npm test                            # the page checks
npx serve public                    # or any static server
```

## Deploy

`.github/workflows/website.yml` builds and tests every pull request that touches the site, and deploys on pushes to `main` that change `website/**`, `docs/screenshots/**`, `docs/sponsors/**` or `docs/app-icon.png`. The runner checks out the repo, `npm run build` copies the assets and bundles the globe, and `cf deploy` uploads `public/`.

It needs two repo secrets: `CLOUDFLARE_API_TOKEN` (Workers Scripts and Workers Routes, Edit, on `tddworks.com` only) and `CLOUDFLARE_ACCOUNT_ID`. Pull requests never see them.

A maintainer can also deploy by hand with the [`cf` CLI](https://developers.cloudflare.com/cf): `npm run deploy`.
