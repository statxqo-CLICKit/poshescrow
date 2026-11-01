# posh-signups – POSH Escrow sign-up list (Cloudflare Worker)

Live: https://posh-signups.statxqo.workers.dev  (account 1531fc8f5ef3475c2d4059445ab6ce65, Workers Free plan)
Sheet: "POSH Escrow Sign-ups" in statxqo@gmail.com Drive — https://docs.google.com/spreadsheets/d/1e08ly-SjDgxqSWaQ0YCl9i_Z10cBQfKRfErMmPfZB90/edit?usp=drivesdk (tab "Sign-ups")

Storage: SQLite-backed Durable Object `SignupStore` (binding `SIGNUPS`). KV/D1 were not used because the saved
Cloudflare API token has no KV or D1 permission (auth error 10000); Durable Objects deploy with Workers Scripts permission only.
Emails live only here and in the sheet — never on-chain.

## API
- `POST /` (CORS: https://poshescrow.pages.dev, *.poshescrow.pages.dev, localhost) — JSON body (also accepts the page's text/plain no-cors fallback). Body ≤ 4 KB. → `{ok:true}`
  Fields: source (required, [a-z0-9_-]), username, displayName, role, wallet (0x…40 hex), email (stored only if `marketingOptIn` or `optIn` is true), roundOneInterest, consentText, createdAt (ISO), userAgent, referrer. Field lengths clipped. Honeypot field `website` → silently accepted, not stored.
  Dedupe: same email (case-insensitive) updates the existing row; no email + same wallet+source updates that row.
  Rate limit per IP (hashed): 5/min and 30/hour → 429.
- Admin (header `Authorization: Bearer $(cat ADMIN_KEY)`): `GET /count`, `GET /export.csv`, `DELETE /signup?email=…` or `?id=N`.
- `GET /health`.

## Files
- `src/index.js` worker + Durable Object; `wrangler.toml`
- `ADMIN_KEY` (0600, gitignored) — same value is the Worker secret `ADMIN_KEY`. Never print it.
- `sync_to_sheet.sh` — pulls /export.csv and appends rows whose id isn't in the sheet yet (status "new"). Values written RAW (no formula injection). Run in Hark with shell credentials [{"provider":"google"}].

## Deploy
Wrangler needs a writable cache: run from this dir (has package.json + node_modules/.cache), with
`HOME=/tmp/wrhome CLOUDFLARE_ACCOUNT_ID=1531fc8f5ef3475c2d4059445ab6ce65`, wrangler installed via
`npm install --prefix /tmp/wr --cache /tmp/npmcache wrangler@3`, then `/tmp/wr/node_modules/.bin/wrangler deploy`.
Rotate key: write a new ADMIN_KEY file (umask 077), then `wrangler secret put ADMIN_KEY < ADMIN_KEY`.
