// POSH Escrow sign-up list — Cloudflare Worker + SQLite-backed Durable Object (Workers Free plan).
// Emails are stored only here (off-chain), and only when the visitor ticked marketing opt-in.
//
// POST /             public, CORS-limited: store one sign-up -> {ok:true}
// GET  /count        admin: {ok:true,count:N}
// GET  /export.csv   admin: all sign-ups as CSV
// DELETE /signup?id=N | ?email=x   admin: remove one row (cleanup / unsubscribe)
// GET  /health       {ok:true}
// Admin auth: header "Authorization: Bearer <ADMIN_KEY>" (Worker secret ADMIN_KEY).

const ALLOWED = [/^https:\/\/poshescrow\.pages\.dev$/, /^https:\/\/[a-z0-9-]+\.poshescrow\.pages\.dev$/, /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/];
const MAX_BODY = 4096;
const RATE_PER_MIN = 5, RATE_PER_HOUR = 30;
export const COLUMNS = ["id", "createdAt", "receivedAt", "source", "username", "displayName", "role", "wallet", "email", "marketingOptIn", "roundOneInterest", "consentText", "userAgent", "referrer"];

const corsHeaders = (origin) => origin && ALLOWED.some((r) => r.test(origin))
  ? { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "Content-Type, Accept", "Access-Control-Max-Age": "86400", Vary: "Origin" }
  : { Vary: "Origin" };
const json = (obj, status = 200, extra = {}) => new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json", ...extra } });

function clip(v, n) { return typeof v === "string" ? v.replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, n) : ""; }

export function validate(d) {
  if (!d || typeof d !== "object" || Array.isArray(d)) return { error: "Body must be a JSON object" };
  if (typeof d.website === "string" && d.website) return { honeypot: true };
  const source = clip(d.source, 32).toLowerCase();
  if (!/^[a-z0-9_-]{1,32}$/.test(source)) return { error: "Invalid source" };
  const optIn = d.marketingOptIn === true || d.optIn === true;
  let email = "";
  if (optIn && d.email != null && d.email !== "") {
    email = clip(d.email, 254).toLowerCase();
    if (!/^[^\s@]{1,64}@[^\s@]+\.[^\s@]{2,}$/.test(email)) return { error: "Invalid email" };
  }
  const username = clip(d.username, 32);
  if (username && !/^[\w.-]{1,32}$/.test(username)) return { error: "Invalid username" };
  const wallet = clip(d.wallet, 42);
  if (wallet && !/^0x[0-9a-fA-F]{40}$/.test(wallet)) return { error: "Invalid wallet" };
  const role = clip(d.role, 16);
  if (role && !/^[\w &-]{1,16}$/.test(role)) return { error: "Invalid role" };
  let createdAt = clip(d.createdAt, 40);
  if (createdAt && isNaN(Date.parse(createdAt))) createdAt = "";
  if (!email && !username && !wallet) return { error: "Nothing to save (email with opt-in, username or wallet required)" };
  return {
    row: {
      createdAt, source, username, displayName: clip(d.displayName, 64), role, wallet, email,
      marketingOptIn: optIn && !!email ? 1 : 0, roundOneInterest: clip(String(d.roundOneInterest ?? ""), 64),
      consentText: optIn && email ? clip(d.consentText, 300) : "", userAgent: clip(d.userAgent, 300), referrer: clip(d.referrer, 300),
    },
  };
}

function csvCell(v) { const s = v == null ? "" : String(v); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }

async function sha256(s) { const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)); return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join(""); }

async function isAdmin(req, env) {
  const key = env.ADMIN_KEY; if (!key) return false;
  const got = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!got) return false;
  const [a, b] = await Promise.all([sha256(got), sha256(key)]);
  let diff = 0; for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url), origin = req.headers.get("Origin") || "", cors = corsHeaders(origin);
    const store = env.SIGNUPS.get(env.SIGNUPS.idFromName("main"));
    if (req.method === "OPTIONS") return new Response(null, { status: cors["Access-Control-Allow-Origin"] ? 204 : 403, headers: cors });
    if (url.pathname === "/health") return json({ ok: true }, 200, cors);

    if (url.pathname === "/" && req.method === "POST") {
      if (!cors["Access-Control-Allow-Origin"]) return json({ ok: false, error: "Origin not allowed" }, 403, cors);
      const len = +req.headers.get("Content-Length") || 0;
      if (len > MAX_BODY) return json({ ok: false, error: "Too large" }, 413, cors);
      const text = await req.text(); // accept application/json and the page's text/plain no-cors fallback
      if (text.length > MAX_BODY) return json({ ok: false, error: "Too large" }, 413, cors);
      let d; try { d = JSON.parse(text); } catch { return json({ ok: false, error: "Invalid JSON" }, 400, cors); }
      const v = validate(d);
      if (v.honeypot) return json({ ok: true }, 200, cors);
      if (v.error) return json({ ok: false, error: v.error }, 400, cors);
      const ipHash = (await sha256((req.headers.get("CF-Connecting-IP") || "unknown") + "|" + (env.ADMIN_KEY || ""))).slice(0, 32);
      const r = await store.fetch("https://do/add", { method: "POST", body: JSON.stringify({ row: v.row, ipHash }) });
      const out = await r.json();
      if (r.status === 429) return json({ ok: false, error: "Too many requests" }, 429, { ...cors, "Retry-After": "60" });
      return json(out.ok ? { ok: true } : { ok: false, error: "Store failed" }, out.ok ? 200 : 500, cors);
    }

    if (["/count", "/export.csv", "/signup"].includes(url.pathname)) {
      if (!(await isAdmin(req, env))) return json({ ok: false, error: "Unauthorized" }, 401);
      if (url.pathname === "/count" && req.method === "GET") return store.fetch("https://do/count");
      if (url.pathname === "/export.csv" && req.method === "GET") return store.fetch("https://do/export");
      if (url.pathname === "/signup" && req.method === "DELETE") return store.fetch("https://do/delete" + url.search, { method: "POST" });
    }
    return json({ ok: false, error: "Not found" }, 404, cors);
  },
};

export class SignupStore {
  constructor(state) {
    this.sql = state.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS signups (
      id INTEGER PRIMARY KEY AUTOINCREMENT, createdAt TEXT, receivedAt TEXT NOT NULL, source TEXT, username TEXT, displayName TEXT, role TEXT,
      wallet TEXT, email TEXT, marketingOptIn INTEGER, roundOneInterest TEXT, consentText TEXT, userAgent TEXT, referrer TEXT, ipHash TEXT)`);
    this.sql.exec("CREATE UNIQUE INDEX IF NOT EXISTS signups_email ON signups(email) WHERE email <> ''");
    this.sql.exec("CREATE TABLE IF NOT EXISTS rl (k TEXT PRIMARY KEY, n INTEGER, exp INTEGER)");
  }
  hit(key, limit, ttl, now) {
    const row = this.sql.exec("SELECT n, exp FROM rl WHERE k = ?", key).toArray()[0];
    if (!row || row.exp <= now) { this.sql.exec("INSERT OR REPLACE INTO rl (k, n, exp) VALUES (?, 1, ?)", key, now + ttl); return true; }
    if (row.n >= limit) return false;
    this.sql.exec("UPDATE rl SET n = n + 1 WHERE k = ?", key); return true;
  }
  async fetch(req) {
    const url = new URL(req.url), now = Date.now();
    if (url.pathname === "/add") {
      const { row, ipHash } = await req.json();
      this.sql.exec("DELETE FROM rl WHERE exp <= ?", now);
      if (!this.hit("m:" + ipHash, RATE_PER_MIN, 60e3, now) || !this.hit("h:" + ipHash, RATE_PER_HOUR, 3600e3, now)) return json({ ok: false }, 429);
      const received = new Date(now).toISOString();
      // Dedupe: same email -> update that row; no email but same wallet+source -> update that row.
      let existing = null;
      if (row.email) existing = this.sql.exec("SELECT id FROM signups WHERE email = ?", row.email).toArray()[0];
      else if (row.wallet) existing = this.sql.exec("SELECT id FROM signups WHERE email = '' AND lower(wallet) = lower(?) AND source = ?", row.wallet, row.source).toArray()[0];
      if (existing) {
        const sets = ["username", "displayName", "role", "wallet", "roundOneInterest", "consentText", "userAgent", "referrer"].filter((k) => row[k]);
        if (row.marketingOptIn) sets.push("marketingOptIn");
        if (sets.length) this.sql.exec(`UPDATE signups SET ${sets.map((k) => k + " = ?").join(", ")} WHERE id = ?`, ...sets.map((k) => row[k]), existing.id);
        return json({ ok: true, dup: true });
      }
      this.sql.exec(`INSERT INTO signups (createdAt, receivedAt, source, username, displayName, role, wallet, email, marketingOptIn, roundOneInterest, consentText, userAgent, referrer, ipHash)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, row.createdAt, received, row.source, row.username, row.displayName, row.role, row.wallet, row.email,
        row.marketingOptIn, row.roundOneInterest, row.consentText, row.userAgent, row.referrer, ipHash);
      return json({ ok: true });
    }
    if (url.pathname === "/count") return json({ ok: true, count: this.sql.exec("SELECT COUNT(*) AS c FROM signups").one().c });
    if (url.pathname === "/export") {
      const rows = this.sql.exec(`SELECT ${COLUMNS.join(", ")} FROM signups ORDER BY id`).toArray();
      const csv = [COLUMNS.join(","), ...rows.map((r) => COLUMNS.map((c) => csvCell(r[c])).join(","))].join("\r\n") + "\r\n";
      return new Response(csv, { headers: { "Content-Type": "text/csv; charset=utf-8", "Cache-Control": "no-store" } });
    }
    if (url.pathname === "/delete") {
      const id = url.searchParams.get("id"), email = (url.searchParams.get("email") || "").toLowerCase();
      let n = 0;
      if (id && /^\d+$/.test(id)) n = this.sql.exec("DELETE FROM signups WHERE id = ?", +id).rowsWritten;
      else if (email) n = this.sql.exec("DELETE FROM signups WHERE email = ?", email).rowsWritten;
      else return json({ ok: false, error: "id or email required" }, 400);
      return json({ ok: true, deleted: n });
    }
    return json({ ok: false }, 404);
  }
}
