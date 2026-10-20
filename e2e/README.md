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

## Time Verify (`tv.mjs`)

Store opens a PO call (with not-to-exceed) → Prairie Plumbing's office accepts → Tony taps I'm going (a second tech is
blocked) → GPS arrival → store code → parts run (left → at supplier → back) → Leaving: done → office enters the invoice →
store sees billed vs verified hours and the over-limit flag in the call and the PO log, approves → QR sticker report
(wrong PIN refused, right PIN accepted) → a new tech signs in from a one-time link → sticker sheet → alert sender
refuses calls without its key. `node tv.mjs`
