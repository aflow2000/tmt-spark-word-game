/* ============================================================
   LOCAL INTEGRATION HARNESS — a tiny PostgREST look-alike
   ------------------------------------------------------------
   Serves the project as static files and answers `POST /rest/v1/rpc/<fn>`
   by calling the real Postgres function in the local test database as
   the `anon` role — exactly what supabase-js does against Supabase.
   Lets tests/ui.integration.js drive the REAL front-end against the REAL
   SQL without a Supabase project. Not used in production.

   Usage:  bash tests/reset_local_db.sh && node tests/local-rpc-server.js
   ============================================================ */
const express = require("express");
const path = require("path");
const { Pool } = require("pg");

const PORT = process.env.PORT || 54321;
const pool = new Pool({ host: "/var/run/postgresql", user: "postgres", database: process.env.DB || "sparkword" });
const app = express();
app.use(express.json({ limit: "1mb" }));
app.use((req, res, next) => { res.setHeader("Access-Control-Allow-Origin", "*"); res.setHeader("Access-Control-Allow-Headers", "*"); res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS"); if (req.method === "OPTIONS") return res.end(); next(); });

/* ============================================================
   GoTrue look-alike — enough of Supabase Auth for the browser tests to
   exercise sign-up (with and without email confirmation), password
   sign-in, magic links, password reset, PKCE code exchange and sign-out.
   "Emails" land in an in-memory mailbox the test reads back.
   ============================================================ */
const crypto = require("crypto");
const AUTH = { users: new Map(), codes: new Map(), mailbox: [], autoconfirm: process.env.AUTOCONFIRM === "1" };
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const nowS = () => Math.floor(Date.now() / 1000);
const jwtFor = (u) => b64u({ alg: "HS256", typ: "JWT" }) + "." + b64u({ sub: u.id, email: u.email, role: "authenticated", aud: "authenticated", iat: nowS(), exp: nowS() + 3600, user_metadata: u.meta || {}, app_metadata: { provider: "email", providers: ["email"] } }) + ".test-signature";
const userJson = (u, hidden) => ({ id: u.id, aud: "authenticated", role: "authenticated", email: u.email, email_confirmed_at: u.confirmed ? u.created : null, confirmation_sent_at: u.confirmed ? undefined : new Date().toISOString(), user_metadata: u.meta || {}, app_metadata: { provider: "email", providers: ["email"] }, identities: hidden ? [] : [{ id: u.id, user_id: u.id, provider: "email", identity_data: { email: u.email } }], created_at: u.created, updated_at: u.created });
const sessionJson = (u) => ({ access_token: jwtFor(u), token_type: "bearer", expires_in: 3600, expires_at: nowS() + 3600, refresh_token: "rt-" + u.id, user: userJson(u) });
const bearerUser = (req) => { const m = /^Bearer (.+)$/.exec(req.headers.authorization || ""); if (!m) return null; const parts = m[1].split("."); if (parts.length !== 3) return null; try { const p = JSON.parse(Buffer.from(parts[1], "base64url").toString()); return [...AUTH.users.values()].find((u) => u.id === p.sub) || null; } catch (e) { return null; } };
const gotrueError = (res, status, code, msg) => res.status(status).json({ code: status, error_code: code, msg, message: msg, error: code === "invalid_credentials" ? "invalid_grant" : code, error_description: msg });
async function ensureAuthUserRow(u) { const c = await pool.connect(); try { const r = await c.query("insert into auth.users (id, email) values ($1, $2) on conflict (email) do update set email = excluded.email returning id", [u.id, u.email]); u.id = r.rows[0].id; } finally { c.release(); } }
function sendLink(u, type, redirectTo) {
  const token = crypto.randomBytes(12).toString("hex"), code = crypto.randomBytes(12).toString("hex");
  AUTH.codes.set(token, { code, email: u.email, type }); AUTH.codes.set(code, { email: u.email, type });
  const link = `http://localhost:${PORT}/auth/v1/verify?token=${token}&type=${type}&redirect_to=${encodeURIComponent(redirectTo || "")}`;
  AUTH.mailbox.push({ to: u.email, type, link, at: new Date().toISOString() });
}
app.post("/auth/v1/signup", async (req, res) => {
  const { email, password, data } = req.body || {}; const em = String(email || "").toLowerCase();
  if (!em || !password) return gotrueError(res, 422, "validation_failed", "Signup requires a valid password");
  if (String(password).length < 6) return gotrueError(res, 422, "weak_password", "Password should be at least 6 characters.");
  if (AUTH.users.has(em)) { const u = AUTH.users.get(em); return res.json(userJson(Object.assign({}, u, { id: crypto.randomUUID(), created: new Date().toISOString() }), true)); } // GoTrue hides existing users: fake user with no identities
  const u = { id: crypto.randomUUID(), email: em, password: String(password), meta: data || {}, confirmed: AUTH.autoconfirm, created: new Date().toISOString() };
  AUTH.users.set(em, u); await ensureAuthUserRow(u);
  if (AUTH.autoconfirm) return res.json(sessionJson(u));
  sendLink(u, "signup", req.headers["x-redirect-to"] || req.query.redirect_to || (req.body && req.body.gotrue_meta_security && "") || "");
  res.json(userJson(u));
});
app.post("/auth/v1/token", async (req, res) => {
  const grant = req.query.grant_type, b = req.body || {};
  if (grant === "password") {
    const u = AUTH.users.get(String(b.email || "").toLowerCase());
    if (!u || u.password !== String(b.password || "")) return gotrueError(res, 400, "invalid_credentials", "Invalid login credentials");
    if (!u.confirmed) return gotrueError(res, 400, "email_not_confirmed", "Email not confirmed");
    return res.json(sessionJson(u));
  }
  if (grant === "refresh_token") { const u = [...AUTH.users.values()].find((x) => "rt-" + x.id === b.refresh_token); return u ? res.json(sessionJson(u)) : gotrueError(res, 400, "refresh_token_not_found", "Invalid Refresh Token"); }
  if (grant === "pkce") {
    const c = AUTH.codes.get(b.auth_code); if (!c) return gotrueError(res, 400, "flow_state_not_found", "invalid flow state, no valid flow state found");
    const u = AUTH.users.get(c.email); if (!u) return gotrueError(res, 400, "user_not_found", "User not found");
    if (c.type === "signup") u.confirmed = true;
    AUTH.codes.delete(b.auth_code);
    return res.json(sessionJson(u));
  }
  gotrueError(res, 400, "unsupported_grant_type", "unsupported grant type");
});
app.get("/auth/v1/verify", (req, res) => {
  const t = AUTH.codes.get(req.query.token); const to = String(req.query.redirect_to || `http://localhost:${PORT}/index.html`);
  if (!t) return res.redirect(303, to + (to.includes("?") ? "&" : "?") + "error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired");
  AUTH.codes.delete(req.query.token);
  res.redirect(303, to + (to.includes("?") ? "&" : "?") + "code=" + t.code);
});
app.post("/auth/v1/otp", (req, res) => {
  const em = String((req.body || {}).email || "").toLowerCase(); let u = AUTH.users.get(em);
  if (!u) { if ((req.body || {}).create_user === false) return gotrueError(res, 422, "otp_disabled", "Signups not allowed for otp"); u = { id: crypto.randomUUID(), email: em, password: null, meta: (req.body || {}).data || {}, confirmed: true, created: new Date().toISOString() }; AUTH.users.set(em, u); ensureAuthUserRow(u); }
  sendLink(u, "magiclink", (req.body || {}).redirect_to || req.query.redirect_to || ""); res.json({});
});
app.post("/auth/v1/recover", (req, res) => {
  const em = String((req.body || {}).email || "").toLowerCase(); const u = AUTH.users.get(em);
  if (u) sendLink(u, "recovery", (req.body || {}).redirect_to || req.query.redirect_to || "");
  res.json({});
});
app.get("/auth/v1/user", (req, res) => { const u = bearerUser(req); return u ? res.json(userJson(u)) : gotrueError(res, 401, "bad_jwt", "invalid JWT"); });
app.put("/auth/v1/user", (req, res) => { const u = bearerUser(req); if (!u) return gotrueError(res, 401, "bad_jwt", "invalid JWT"); const b = req.body || {}; if (b.password) { if (String(b.password).length < 6) return gotrueError(res, 422, "weak_password", "Password should be at least 6 characters."); u.password = String(b.password); } if (b.data) u.meta = Object.assign({}, u.meta, b.data); res.json(userJson(u)); });
app.post("/auth/v1/logout", (req, res) => res.status(204).end());
app.get("/auth/v1/health", (req, res) => res.json({ name: "GoTrue look-alike" }));
/* test helpers */
app.get("/__auth/mailbox", (req, res) => res.json(AUTH.mailbox));
app.post("/__auth/config", (req, res) => { if (typeof (req.body || {}).autoconfirm === "boolean") AUTH.autoconfirm = req.body.autoconfirm; res.json({ autoconfirm: AUTH.autoconfirm }); });
app.post("/__auth/reset", (req, res) => { AUTH.users.clear(); AUTH.codes.clear(); AUTH.mailbox.length = 0; res.json({ ok: true }); });

app.post("/rest/v1/rpc/:fn", async (req, res) => {
  const fn = req.params.fn;
  if (!/^[a-z_]+$/.test(fn)) return res.status(400).json({ message: "bad function name" });
  const client = await pool.connect();
  try {
    const meta = await client.query("select p.proretset, t.typname from pg_proc p join pg_type t on t.oid = p.prorettype join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = $1 limit 1", [fn]);
    if (!meta.rows.length) return res.status(404).json({ message: `function ${fn} not found` });
    const params = req.body || {};
    const keys = Object.keys(params);
    const args = keys.map((k, i) => `${k} := $${i + 1}${typeof params[k] === "object" && params[k] !== null ? "::jsonb" : ""}`).join(", ");
    const values = keys.map((k) => (typeof params[k] === "object" && params[k] !== null ? JSON.stringify(params[k]) : params[k]));
    await client.query("begin");
    // impersonate the caller like PostgREST: anon, or authenticated with the JWT claims from a test header
    let claims = req.headers["x-test-jwt-claims"];
    if (!claims) { const u = bearerUser(req); if (u) claims = JSON.stringify({ sub: u.id, email: u.email, role: "authenticated", user_metadata: u.meta || {} }); }
    if (claims) { await client.query("select set_config('request.jwt.claims', $1, true)", [claims]); await client.query("set local role authenticated"); }
    else await client.query("set local role anon");
    let out;
    if (meta.rows[0].proretset) out = (await client.query(`select coalesce(json_agg(t), '[]'::json) as j from ${fn}(${args}) t`, values)).rows[0].j;
    else out = (await client.query(`select ${fn}(${args}) as j`, values)).rows[0].j;
    await client.query("commit");
    res.json(out);
  } catch (e) {
    await client.query("rollback").catch(() => {});
    res.status(400).json({ message: e.message, code: e.code });
  } finally { client.release(); }
});

app.use(express.static(path.resolve(__dirname, "..")));
// SPA rewrite for /spark-word/014 → index.html (mirrors hosting/_redirects)
app.get(/^\/spark-word\/\d+\/?$/, (req, res) => res.sendFile(path.resolve(__dirname, "../index.html")));

app.listen(PORT, () => console.log(`local Spark Word harness on http://localhost:${PORT}  (db: ${process.env.DB || "sparkword"})`));
