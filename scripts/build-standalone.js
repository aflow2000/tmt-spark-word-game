/* ============================================================
   Builds the SINGLE-FILE editions of Spark Word from the project sources:

     spark-word.html        the game on its own page (no site chrome)
     spark-word-admin.html  the admin dashboard

   Everything (CSS, dictionary, preview adapter, game module) is inlined.
   The only external request is the supabase-js UMD bundle from jsDelivr.
   A CONFIG block sits at the very top of each file; it is the one thing
   to edit (or let scripts/build-config.js fill it from env vars).

   Also concatenates the SQL into supabase/spark-word-setup.sql (schema +
   functions + word bank + dictionary + Issue 014) and
   supabase/spark-word-test-data.sql (sample players and games).

   Run:  node scripts/build-standalone.js
   ============================================================ */
const fs = require("fs");
const path = require("path");
const R = path.join(__dirname, "..");
const read = (p) => fs.readFileSync(path.join(R, p), "utf8");

const SUPABASE_UMD = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js";
const FAVICON = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%230B111E'/%3E%3Cpath d='M32 8 L37.5 26.5 L56 32 L37.5 37.5 L32 56 L26.5 37.5 L8 32 L26.5 26.5 Z' fill='%23D9C892'/%3E%3C/svg%3E";

/* The config block is identical in both files so build-config.js can patch either. */
function configBlock(file) {
  return `<script>
/* ═══════════════════════════════════════════════════════════════════
   SPARK WORD · CONFIG — the only lines you need to edit in this file.

   1. supabaseUrl / supabaseAnonKey
        Supabase → Project Settings → API → "Project URL" and the
        "anon public" key. (Deploying on Vercel with the Supabase
        Marketplace integration? Leave them empty — scripts/build-config.js
        fills them in from the environment at build time.)
   2. siteUrl
        Public address of the game page, e.g.
        https://your-app.vercel.app/spark-word.html
        Leave "" to auto-detect from the browser address bar.

   With empty keys the page runs as a clearly-labelled DESIGN PREVIEW
   on sample data — nothing is saved. Run supabase/spark-word-setup.sql
   in the Supabase SQL editor once, then paste the two values above.
   ═══════════════════════════════════════════════════════════════════ */
window.SPARK_WORD_CONFIG = {
  supabaseUrl: "",
  supabaseAnonKey: "",
  siteUrl: "",
  urlStyle: "query",
  analytics: null,
  gamePage: "spark-word.html",
  configHint: "the CONFIG block at the top of ${file}"
};
</script>`;
}

/* ---------- shared pieces from index.html ---------- */
const html = read("index.html");
const siteCss = html.match(/<style>([\s\S]*?)<\/style>/)[1];
const sprite = html.match(/<!-- ============ icon sprite ============ -->\s*([\s\S]*?<\/svg>)/)[1];
const section = html.match(/<section class="page" id="page-spark-word">[\s\S]*?<\/section>\n<\/main>/)[0]
  .replace(/\n<\/main>$/, "")
  .replace('<section class="page" id="page-spark-word">', '<section class="page on" id="page-spark-word">');
const modals = html.match(/<!-- Spark Word modals[\s\S]*?<div class="veil" id="swProfileVeil">.*?<\/div>\n/)[0];

/* Minimal stand-in for the site's TMTSpark bridge so the game runs on its own page */
const bridge = `(function(){
  var $=function(s){return document.querySelector(s)}, $$=function(s){return Array.prototype.slice.call(document.querySelectorAll(s))};
  var hooks=[], toastTimer=null;
  function toast(m){ $("#toastTxt").textContent=m; $("#toast").classList.add("on"); clearTimeout(toastTimer); toastTimer=setTimeout(function(){$("#toast").classList.remove("on")},3800); }
  function openVeil(id){ $("#"+id).classList.add("on"); document.body.style.overflow="hidden"; }
  function closeVeil(id){ $("#"+id).classList.remove("on"); document.body.style.overflow=""; }
  $$(".veil").forEach(function(v){ v.addEventListener("mousedown",function(e){ if(e.target===v) closeVeil(v.id); }); });
  document.addEventListener("click",function(e){
    var c=e.target.closest("[data-close]"); if(c){ closeVeil(c.getAttribute("data-close")); }
    var j=e.target.closest("[data-join]"); if(j){ toast("Newsletter sign-up lives on the TMT Spark site."); }
  });
  document.addEventListener("keydown",function(e){ if(e.key==="Escape") $$(".veil.on").forEach(function(v){closeVeil(v.id)}); });
  window.TMTSpark={
    showPage:function(id){ if(id!=="spark-word") toast("That section lives on the TMT Spark site."); hooks.forEach(function(f){try{f("spark-word")}catch(err){}}); },
    openVeil:openVeil, closeVeil:closeVeil,
    anyVeilOpen:function(){ return $$(".veil").some(function(v){return v.classList.contains("on")}); },
    toast:toast, copyText:function(t){ if(navigator.clipboard){ navigator.clipboard.writeText(t).then(function(){toast("Copied.")}); } },
    INDEX:[], goToEl:function(){ toast("Opens in Spark Learning on the TMT Spark site."); }, flashEl:function(el){ if(el) el.scrollIntoView({behavior:"smooth",block:"center"}); },
    REDUCED:window.matchMedia&&window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    onPage:function(fn){ hooks.push(fn); }, currentPage:function(){ return "spark-word"; }
  };
})();`;

/* ---------- spark-word.html ---------- */
const game = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>Spark Word · TMT Spark</title>
<meta name="description" content="Five letters. Six tries. One industry. The TMT Spark word game.">
<link rel="icon" href="${FAVICON}">
${configBlock("spark-word.html")}
<style>${siteCss}</style>
<style>${read("assets/spark-word.css")}
.sw-standalone-top .navwrap{height:60px}
.sw-standalone-top .poc-badge{display:inline-block;margin-left:auto}
.sw-standalone-top .poc-badge[hidden]{display:none}
@media (max-width:720px){.sw-standalone-top .poc-badge{font-size:8.5px;padding:4px 9px}}
</style>
</head>
<body>
${sprite}
<header id="top" class="sw-standalone-top">
  <div class="container navwrap">
    <span class="logo" aria-label="TMT Spark">
      <svg aria-hidden="true"><use href="#i-spark" style="color:var(--spark)"/></svg>
      <span><span class="lw">TMT&nbsp;<em>Spark</em></span><span class="by">By Turner <em>&amp;</em> Townsend</span></span>
    </span>
    <span class="poc-badge" id="swStandaloneBadge" hidden>Design preview</span>
  </div>
</header>
<main>
${section}
</main>
${modals}
<div id="toast" role="status"><svg width="15" height="15" aria-hidden="true"><use href="#i-check"/></svg><span id="toastTxt"></span></div>
<script>${bridge}</script>
<script>${read("assets/spark-word-dictionary.js")}</script>
<script>${read("assets/spark-word-preview.js")}</script>
<script src="${SUPABASE_UMD}" crossorigin="anonymous"></script>
<script>${read("assets/spark-word.js")}</script>
<script>(function(){ var b=document.getElementById("swStandaloneBadge"); if(b && window.SparkWord && window.SparkWord.api.mode==="preview") b.hidden=false; })();</script>
</body>
</html>
`;
fs.writeFileSync(path.join(R, "spark-word.html"), game);

/* ---------- spark-word-admin.html ---------- */
const adminHtml = read("admin.html");
const adminBody = adminHtml.match(/<body>\n([\s\S]*?)<script src="assets\/spark-word-config\.js"><\/script>/)[1];
const admin = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>Spark Word · Admin · TMT Spark</title>
<link rel="icon" href="${FAVICON}">
${configBlock("spark-word-admin.html")}
<style>${read("assets/admin.css")}</style>
</head>
<body>
${adminBody}<script>${read("assets/spark-word-dictionary.js")}</script>
<script>${read("assets/spark-word-wordbank-preview.js")}</script>
<script>${read("assets/spark-word-preview.js")}</script>
<script src="${SUPABASE_UMD}" crossorigin="anonymous"></script>
<script>${read("assets/admin.js")}</script>
</body>
</html>
`;
fs.writeFileSync(path.join(R, "spark-word-admin.html"), admin);

/* ---------- combined SQL ---------- */
const banner = (t) => `-- ============================================================\n-- ${t}\n-- ============================================================\n`;
const cat = (files) => files.map((f) => `\n${banner("FILE: " + f)}${read(f)}`).join("\n");
const setup = `${banner("SPARK WORD — one-shot setup for the Supabase SQL editor")}
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- It creates the schema, game functions, leaderboards, admin functions,
-- row-level security, the settings, the word bank, the dictionary and
-- the sample Issue 014. Safe to re-run (idempotent where it matters).
--
-- Afterwards:
--   1. Supabase → Authentication → Users → add your admin user (email + password)
--   2. run:  insert into admins (email) values ('you@turnerandtownsend.com');
--   3. run:  update sw_settings set value = 'https://YOUR-APP.vercel.app/spark-word.html' where key = 'site_url';
--            update sw_settings set value = 'query' where key = 'url_style';
--      (or use the Settings tab in spark-word-admin.html)
-- Sample players/games for testing live in spark-word-test-data.sql.
${cat(["supabase/migrations/001_schema.sql", "supabase/migrations/002_game_functions.sql", "supabase/migrations/003_leaderboards.sql", "supabase/migrations/004_admin.sql", "supabase/migrations/005_rls.sql", "supabase/seed/010_settings.sql", "supabase/seed/020_word_bank.sql", "supabase/seed/030_dictionary.sql", "supabase/seed/040_issues.sql"])}
`;
fs.writeFileSync(path.join(R, "supabase/spark-word-setup.sql"), setup);
const test = `${banner("SPARK WORD — optional sample data (players, games, leaderboards)")}
-- Run AFTER spark-word-setup.sql if you want populated leaderboards and the
-- README's test links to work. Remove before go-live:
--   delete from subscribers where notes = 'seed';
${cat(["supabase/seed/050_test_subscribers.sql", "supabase/seed/060_test_games.sql"])}
`;
fs.writeFileSync(path.join(R, "supabase/spark-word-test-data.sql"), test);

console.log("spark-word.html        " + (game.length / 1024).toFixed(0) + " KB");
console.log("spark-word-admin.html  " + (admin.length / 1024).toFixed(0) + " KB");
console.log("supabase/spark-word-setup.sql      " + (setup.length / 1024).toFixed(0) + " KB");
console.log("supabase/spark-word-test-data.sql  " + (test.length / 1024).toFixed(0) + " KB");
