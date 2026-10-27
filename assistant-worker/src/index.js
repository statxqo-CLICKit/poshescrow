// POSH Assistant – Cloudflare Worker using Workers AI (free tier).
// POST { messages:[{role,content}], context:{tab} }  ->  { reply }
// On error: { reply:null, error }
import { SYSTEM_PROMPT } from "./prompt.js";

export const LIMITS = {
  MAX_INPUT_CHARS: 1200,   // total chars of conversation sent to the model
  MAX_MESSAGES: 12,        // history kept (oldest dropped first)
  MAX_TOKENS: 300,         // model output cap
  WINDOW_MS: 60_000,
  DEFAULT_PER_MIN: 8,
};

const ALLOWED_ORIGINS = new Set(["https://hark.site", "https://poshescrow.pages.dev"]);
const TABS = new Set([
  "deals", "handoff", "handoff mode", "proof vault", "trust passport", "rewards",
  "pre-sale", "presale", "safety", "add funds", "iso 20022", "export", "legal", "legal & risk",
]);
const PRESALE_RE = /pre-?sale|round one/i;
const LOSS_RE = /lose (everything|all)/i;
const PRESALE_WARNING = " Reminder: the pre-sale is testnet, pending legal review, and you can lose everything you put in.";

export function isAllowedOrigin(origin) {
  if (!origin) return false;
  if (ALLOWED_ORIGINS.has(origin)) return true;
  try {
    const u = new URL(origin);
    if ((u.hostname === "localhost" || u.hostname === "127.0.0.1") && /^https?:$/.test(u.protocol)) return true;
    // Cloudflare Pages preview deployments, e.g. https://abc123.poshescrow.pages.dev
    if (u.protocol === "https:" && u.hostname.endsWith(".poshescrow.pages.dev")) return true;
  } catch { /* bad origin */ }
  return false;
}

function corsHeaders(origin) {
  const h = {
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "86400",
  };
  if (isAllowedOrigin(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

function json(body, status, origin, extra = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...corsHeaders(origin), ...extra },
  });
}
const fail = (error, status, origin, extra) => json({ reply: null, error }, status, origin, extra);

// ---- in-memory per-IP rate limit (per isolate; best-effort, free) ----
const hits = new Map(); // ip -> number[] timestamps
export function _resetRateLimit() { hits.clear(); }
export function rateLimited(ip, perMin, now = Date.now()) {
  const recent = (hits.get(ip) || []).filter((t) => now - t < LIMITS.WINDOW_MS);
  if (recent.length >= perMin) { hits.set(ip, recent); return true; }
  recent.push(now);
  hits.set(ip, recent);
  if (hits.size > 5000) { // prune stale entries
    for (const [k, v] of hits) if (!v.length || now - v[v.length - 1] >= LIMITS.WINDOW_MS) hits.delete(k);
  }
  return false;
}

// ---- validation ----
export function validate(body) {
  if (!body || typeof body !== "object") return { error: "Body must be a JSON object." };
  const { messages, context } = body;
  if (!Array.isArray(messages) || messages.length === 0) return { error: "messages must be a non-empty array." };
  const clean = [];
  for (const m of messages) {
    if (!m || typeof m !== "object" || typeof m.content !== "string") return { error: "Each message needs a string content." };
    if (m.role !== "user" && m.role !== "assistant") return { error: "role must be 'user' or 'assistant'." };
    const content = m.content.trim();
    if (content) clean.push({ role: m.role, content });
  }
  if (!clean.length || clean[clean.length - 1].role !== "user") return { error: "The last message must be from the user." };
  const last = clean[clean.length - 1];
  if (last.content.length > LIMITS.MAX_INPUT_CHARS) return { error: `Message too long (max ${LIMITS.MAX_INPUT_CHARS} characters).` };
  // keep newest messages within message and character budgets
  const kept = [];
  let total = 0;
  for (let i = clean.length - 1; i >= 0 && kept.length < LIMITS.MAX_MESSAGES; i--) {
    if (total + clean[i].content.length > LIMITS.MAX_INPUT_CHARS) break;
    total += clean[i].content.length;
    kept.unshift(clean[i]);
  }
  while (kept.length && kept[0].role !== "user") kept.shift();
  let tab = null;
  if (context && typeof context === "object" && typeof context.tab === "string") {
    const t = context.tab.trim().toLowerCase().slice(0, 40);
    if (TABS.has(t)) tab = t;
  }
  return { messages: kept, tab };
}

function extractText(out) {
  if (!out) return "";
  if (typeof out === "string") return out;
  if (typeof out.response === "string") return out.response;
  if (out.choices?.[0]?.message?.content) return out.choices[0].message.content;
  return "";
}

export function postProcess(reply, userText) {
  let r = reply.trim();
  if (PRESALE_RE.test(userText + " " + r) && !LOSS_RE.test(r)) {
    r += PRESALE_WARNING;
  }
  return r;
}

export default {
  async fetch(request, env) {
    const origin = request.headers.get("Origin");
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      if (!isAllowedOrigin(origin)) return new Response(null, { status: 403, headers: { Vary: "Origin" } });
      return new Response(null, { status: 204, headers: corsHeaders(origin) });
    }
    if (request.method === "GET" && url.pathname === "/health") return json({ ok: true }, 200, origin);
    if (request.method !== "POST") return fail("Use POST.", 405, origin, { Allow: "POST, OPTIONS" });
    if (origin && !isAllowedOrigin(origin)) return fail("Origin not allowed.", 403, origin);

    const ip = request.headers.get("CF-Connecting-IP") || request.headers.get("X-Forwarded-For")?.split(",")[0].trim() || "unknown";
    const perMin = Number(env.RATE_LIMIT_PER_MIN) || LIMITS.DEFAULT_PER_MIN;
    if (rateLimited(ip, perMin)) return fail("Too many requests. Please wait a minute.", 429, origin, { "Retry-After": "60" });

    const len = Number(request.headers.get("Content-Length") || 0);
    if (len > 20_000) return fail("Request too large.", 413, origin);

    let body;
    try { body = await request.json(); } catch { return fail("Invalid JSON.", 400, origin); }
    const v = validate(body);
    if (v.error) return fail(v.error, 400, origin);

    if (!env.AI) return fail("AI binding not configured.", 500, origin);
    const system = SYSTEM_PROMPT + (v.tab ? `\n\nThe user is currently viewing the "${v.tab}" tab.` : "");
    const input = { messages: [{ role: "system", content: system }, ...v.messages], max_tokens: LIMITS.MAX_TOKENS, temperature: 0.3 };
    const models = [env.MODEL || "@cf/meta/llama-3.1-8b-instruct-fp8", env.FALLBACK_MODEL].filter(Boolean);

    let lastErr = "AI unavailable.";
    for (const model of models) {
      try {
        const text = extractText(await env.AI.run(model, input));
        if (text.trim()) {
          const userText = v.messages[v.messages.length - 1].content;
          return json({ reply: postProcess(text, userText) }, 200, origin);
        }
        lastErr = "Empty reply from model.";
      } catch (e) {
        lastErr = String(e?.message || e).slice(0, 200);
      }
    }
    return fail(`Assistant is unavailable right now (${lastErr}). Please try again later or ask on Discord.`, 502, origin);
  },
};
