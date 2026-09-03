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
    const claims = req.headers["x-test-jwt-claims"];
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
