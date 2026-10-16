# Phone-size end-to-end test of the technician app

Drives the live site in a real browser (iPhone 13 size) through two full calls:
sign-in, start + ETA, GPS arrival, check-in code, nameplate + equipment, before/after photos,
repair + kit parts, finishing **with no signal** and syncing when signal returns, the cost meter
stopping the tech at the limit, and a quote built from hours + parts.

Needs a machine that can reach the site and Supabase (not this repo's sandbox):

```bash
npm i playwright@1.48.2 && npx playwright install --with-deps chromium
node e2e.mjs            # SITE=https://… to point elsewhere
```

It creates real calls on the demo data; cancel or keep them afterwards.
