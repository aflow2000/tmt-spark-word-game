/* Cross-checks the preview adapter's JS evaluator/scoring against the
   Postgres functions (sw_evaluate / sw_score) on random word pairs.
   Requires the local test DB:  bash tests/reset_local_db.sh
   Run from the project root:   node tests/evaluate.test.js */
const { Client } = require("pg");
const fs = require("fs"), vm = require("vm"), path = require("path");
const ROOT = path.resolve(__dirname, "..");
const ctx = { window: {}, document: { createElement: () => ({}), head: { appendChild() {} } }, setTimeout, JSON, Math, Date, String, Object, Array, Number, RegExp, Set, Promise, console };
ctx.window.SPARK_WORD_DICTIONARY = "";
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(ROOT, "assets/spark-word-preview.js"), "utf8"), ctx);
const P = ctx.window.SparkWordPreview;
const words = fs.readFileSync(path.join(ROOT, "supabase/seed/030_dictionary.sql"), "utf8").match(/\('([a-z]{5})'\)/g).map((m) => m.slice(2, 7).toUpperCase());
(async () => {
  const c = new Client({ host: "/var/run/postgresql", user: "postgres", database: process.env.DB || "sparkword" });
  await c.connect();
  let n = 0, bad = 0;
  const fixed = [["EERIE","STEEL"],["LEVEL","STEEL"],["SLEET","STEEL"],["ABBEY","BABES"],["FIBER","FIBER"],["CRANE","FIBER"],["POWER","EERIE"],["TOWER","FIBER"]];
  const pairs = fixed.slice();
  for (let i = 0; i < 600; i++) pairs.push([words[Math.floor(Math.random() * words.length)], words[Math.floor(Math.random() * words.length)]]);
  for (const [g, a] of pairs) {
    const r = await c.query("select sw_evaluate($1,$2) as r", [g, a]);
    n++; if (r.rows[0].r !== P.evaluate(g, a)) { bad++; console.log("MISMATCH", g, a, r.rows[0].r, P.evaluate(g, a)); }
  }
  for (const [s, k, h, st] of [[true,1,false,0],[true,1,false,1],[true,3,true,12],[true,6,true,3],[false,6,false,9],[true,4,false,10],[true,2,true,0]]) {
    const r = await c.query("select sw_score($1,$2,$3,$4) as r", [s, k, h, st]);
    n++; if (r.rows[0].r !== P.score(s, k, h, st)) { bad++; console.log("SCORE MISMATCH", s, k, h, st, r.rows[0].r, P.score(s, k, h, st)); }
  }
  await c.end();
  console.log(`evaluate/score parity: ${n} checks, ${bad} mismatches`);
  process.exit(bad ? 1 : 0);
})();
