/* ============================================================
   Builds spark-word-daily.html — the one-file, no-backend DAILY edition:
   a new TMT word every day from assets/spark-word-daily-words.js, the
   player's own results kept on their device, sample players on the boards.
   Nothing to configure; no external requests.

   Run:  node scripts/build-daily.js
   ============================================================ */
const fs = require("fs");
const path = require("path");
const R = path.join(__dirname, "..");
const read = (p) => fs.readFileSync(path.join(R, p), "utf8");
const FAVICON = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%230B111E'/%3E%3Cpath d='M32 8 L37.5 26.5 L56 32 L37.5 37.5 L32 56 L26.5 37.5 L8 32 L26.5 26.5 Z' fill='%23D9C892'/%3E%3C/svg%3E";

const html = read("index.html");
const siteCss = html.match(/<style>([\s\S]*?)<\/style>/)[1];
const sprite = html.match(/<!-- ============ icon sprite ============ -->\s*([\s\S]*?<\/svg>)/)[1];
const section = html.match(/<section class="page" id="page-spark-word">[\s\S]*?<\/section>\n<\/main>/)[0]
  .replace(/\n<\/main>$/, "").replace('<section class="page" id="page-spark-word">', '<section class="page on" id="page-spark-word">');
const modals = html.match(/<!-- Spark Word modals[\s\S]*?<div class="veil" id="swProfileVeil">.*?<\/div>\n/)[0];
/* daily wording for the static copy in the section */
const dailySection = section
  .replace("Loading this issue…", "Loading today's word…")
  .replace('data-lb="issue">This issue', 'data-lb="issue">Today')
  .replace("Solve in fewer guesses to climb the issue leaderboard. Points across issues build the All-Stars table; your company's average feeds the Company Standings. Miss an issue and your streak resets — so come back with the next newsletter.",
           "Solve in fewer guesses to climb today's leaderboard. Points across days build the All-Stars table; your company's average feeds the Company Standings. Miss a day and your streak resets — so come back tomorrow.")
  .replace("Replay any issue you missed in", "Replay any day you missed in");

/* schedule with the answers encoded (not readable in view-source) */
const schedSrc = read("assets/spark-word-daily-words.js");
const sandbox = { window: {} }; new Function("window", schedSrc)(sandbox.window);
const sched = sandbox.window.SPARK_WORD_SCHEDULE;
const enc = (w) => Buffer.from(w.split("").reverse().join(""), "utf8").toString("base64");
const schedOut = Object.assign({}, sched, { words: sched.words.map((x) => ({ k: enc(x.w), c: x.c, h: x.h, e: x.e })) });
const schedJs = "/* Daily schedule — Day 1 = startDate. Answers are encoded; edit assets/spark-word-daily-words.js and rebuild to change them. */\nwindow.SPARK_WORD_SCHEDULE = " + JSON.stringify(schedOut, null, 1) + ";";

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

const out = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
<title>Spark Word · TMT Spark</title>
<meta name="description" content="Five letters. Six tries. One industry. A new TMT word every day.">
<link rel="icon" href="${FAVICON}">
<style>${siteCss}</style>
<style>${read("assets/spark-word.css")}
.sw-standalone-top .navwrap{height:60px}
.sw-standalone-top .poc-badge{display:inline-block;margin-left:auto}
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
    <span class="poc-badge">Spark Word · daily</span>
  </div>
</header>
<main>
${dailySection}
</main>
${modals}
<div id="toast" role="status"><svg width="15" height="15" aria-hidden="true"><use href="#i-check"/></svg><span id="toastTxt"></span></div>
<script>${bridge}</script>
<script>
/* Daily edition: no backend. Your results stay on this device; the other players shown are sample data. */
window.SPARK_WORD_CONFIG = { siteUrl: "", urlStyle: "query", analytics: null, issueNoun: "day", configHint: false,
  previewBanner: "<b>Daily edition</b> — your results are saved on this device.<span class='sw-long'> The other players on the boards are sample data.</span>" };
</script>
<script>${schedJs}</script>
<script>${read("assets/spark-word-dictionary.js")}</script>
<script>${read("assets/spark-word-preview.js")}</script>
<script>${read("assets/spark-word.js")}</script>
</body>
</html>
`;
fs.writeFileSync(path.join(R, "spark-word-daily.html"), out);
console.log("spark-word-daily.html  " + (out.length / 1024).toFixed(0) + " KB · " + sched.words.length + " words from " + sched.startDate + " · answers in schedule: " + (sched.words.some((x) => schedJs.includes(JSON.stringify(x.w))) ? "VISIBLE (!)" : "encoded"));
