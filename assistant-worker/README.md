# POSH Assistant – free AI backend (Cloudflare Worker + Workers AI)

Backend for the POSH Assistant chatbot on the POSH Escrow page. Runs on the **Workers Free plan** using the **Workers AI free daily allocation** (10,000 Neurons/day, resets 00:00 UTC). No paid features, no KV/D1/Durable Objects. On the free plan, going over the daily allocation makes requests fail (the bot returns an error); it never bills.

- Model: `@cf/meta/llama-3.1-8b-instruct-fp8` (fallback `@cf/meta/llama-3.2-3b-instruct`). Set in `wrangler.toml` `[vars]`.
- Rough capacity: worst case about 22 Neurons per reply (≈1,050 input + 300 output tokens) ≈ **450 replies/day free**; shorter chats go further.
- Account: `1531fc8f5ef3475c2d4059445ab6ce65` (already in `wrangler.toml`).

## Files
| File | Purpose |
|---|---|
| `wrangler.toml` | Worker `posh-assistant`, AI binding `AI`, model + rate-limit vars |
| `src/index.js` | The Worker (POST endpoint, CORS, rate limit, validation, guardrails) |
| `src/prompt.js` | System prompt as a JS string (must equal `prompt.md`; the test checks) |
| `prompt.md` | Human-readable system prompt — edit here, then regenerate `src/prompt.js` |
| `test/worker.test.js` | Node test with a mocked `env.AI` |

## API
`POST /` with JSON:
```json
{ "messages": [{ "role": "user", "content": "What is Handoff Mode?" }], "context": { "tab": "handoff" } }
```
- Success `200` → `{ "reply": "..." }`
- Error → `{ "reply": null, "error": "..." }` with 400 (bad input), 403 (origin), 413, 429 (rate limit, `Retry-After: 60`), 502 (AI failed/quota)
- `GET /health` → `{ "ok": true }`

Rules enforced in code:
- CORS: `https://hark.site`, `https://poshescrow.pages.dev`, `*.poshescrow.pages.dev` previews, `http(s)://localhost:*`, `127.0.0.1:*`. Other browser origins get 403.
- Roles must be `user`/`assistant` (client cannot inject `system`); last message must be the user's.
- Latest user message max **1200 chars**; history is trimmed from the oldest so the total sent stays ≤ 1200 chars (max 12 messages).
- Output capped at **300 tokens**, temperature 0.3.
- Per-IP rate limit: **8 requests/min** (`RATE_LIMIT_PER_MIN`), in memory per Worker isolate (best-effort; resets when the isolate recycles).
- Any reply touching the pre-sale/Round One gets a "you can lose everything" line appended if the model left it out.
- `context.tab` is accepted only from a known list (deals, handoff, proof vault, trust passport, rewards, pre-sale, safety, add funds, iso 20022/export, legal) and added to the prompt.

## Test (no Cloudflare needed)
```bash
cd assistant-worker
node --test test/worker.test.js     # or: npm test
```

## Deploy (only after the Cloudflare account email is verified)
```bash
cd assistant-worker
npx wrangler login       # opens browser; sign in as the Cloudflare account owner
npx wrangler deploy
```
Wrangler prints a URL like `https://posh-assistant.<your-subdomain>.workers.dev`. If this is the account's first Worker, Wrangler/dashboard will ask you to pick a free `workers.dev` subdomain first.

Quick check:
```bash
curl -s -X POST https://posh-assistant.<your-subdomain>.workers.dev/ \
  -H 'Content-Type: application/json' -H 'Origin: https://poshescrow.pages.dev' \
  -d '{"messages":[{"role":"user","content":"What is Proof Vault?"}],"context":{"tab":"proof vault"}}'
```
Local dev: `npx wrangler dev` (Workers AI calls still run remotely on your account and count toward the free allocation).

## Connect the page
In the POSH Escrow page's `CONFIG` object, set `assistantEndpoint` to the deployed URL:
```js
const CONFIG = {
  // ...existing keys...
  assistantEndpoint: "https://posh-assistant.<your-subdomain>.workers.dev/",
};
```
The page should `fetch(CONFIG.assistantEndpoint, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ messages, context: { tab } }) })`, show `data.reply` when present, and fall back to its built-in canned answers when `data.reply` is `null` (show `data.error` or a friendly "assistant is busy" line). Leave `assistantEndpoint` empty until deployed so the page keeps using its offline answers. If the page is served from another domain, add it to `ALLOWED_ORIGINS` in `src/index.js` and redeploy.

## Editing the prompt
Edit `prompt.md`, then regenerate:
```bash
python3 -c "import json;p=open('prompt.md').read();open('src/prompt.js','w').write('// Generated from ../prompt.md — keep in sync (test/worker.test.js checks this).\nexport const SYSTEM_PROMPT = '+json.dumps(p)+';\n')"
node --test test/worker.test.js && npx wrangler deploy
```
