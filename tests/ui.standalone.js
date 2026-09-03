/* ============================================================
   SINGLE-FILE EDITIONS — smoke + contract test
   spark-word.html and spark-word-admin.html (built by
   scripts/build-standalone.js) against the local Postgres harness.

   Prereqs:  node scripts/build-standalone.js
             bash tests/reset_local_db.sh
             cd tests && node local-rpc-server.js &     (port 54321)
   Run:      node tests/ui.standalone.js
   ============================================================ */
const { chromium, devices } = require("playwright");
const path = require("path");
const fs = require("fs");
const BASE = process.env.BASE || "http://localhost:54321";
const UMD = path.resolve(__dirname, "node_modules/@supabase/supabase-js/dist/umd/supabase.js");
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (cond, msg) => { console.log((cond ? "  ✓ " : "  ✗ ") + msg); if (!cond) failures++; };

/* serve a copy of the page whose CONFIG block points at the harness (what build-config.js does on Vercel) */
function configured(file, withKeys) {
  let s = fs.readFileSync(path.resolve(__dirname, "..", file), "utf8");
  if (withKeys) s = s.replace(/(supabaseUrl:\s*)"[^"]*"/, `$1"${BASE}"`).replace(/(supabaseAnonKey:\s*)"[^"]*"/, '$1"test-anon-key"');
  return s;
}

async function context(browser, file, withKeys, opts) {
  const ctx = await browser.newContext(opts || { viewport: { width: 1380, height: 900 } });
  await ctx.route("**/cdn.jsdelivr.net/**", (route) => route.fulfill({ path: UMD, contentType: "application/javascript" }));
  await ctx.route("**/" + file + "*", (route) => route.fulfill({ contentType: "text/html", body: configured(file, withKeys) }));
  const errors = [];
  ctx.on("page", (p) => { p.on("pageerror", (e) => errors.push("pageerror: " + e.message)); p.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); }); });
  return { ctx, errors };
}

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" });

  console.log("\n▶ spark-word.html — no keys → design preview, badge shown, still playable");
  let { ctx, errors } = await context(browser, "spark-word.html", false);
  let page = await ctx.newPage();
  await page.goto(BASE + "/spark-word.html", { waitUntil: "networkidle" }); await wait(800);
  check(await page.evaluate(() => window.SparkWord.api.mode) === "preview", "mode = preview");
  check(await page.$eval("#swStandaloneBadge", (el) => !el.hidden), "'Design preview' badge visible");
  check((await page.$eval("#swPreviewBanner", (el) => el.innerText)).includes("CONFIG block at the top of spark-word.html"), "preview banner points at the CONFIG block");
  check(await page.$("link[rel=stylesheet], script[src*='assets/']") === null, "no relative asset references (fully self-contained)");
  await page.click("#swStartBtn"); await wait(300);
  await page.keyboard.type("crane"); await page.keyboard.press("Enter"); await wait(1500);
  check(await page.$$eval(".sw-row[data-row='0'] .sw-tile.a, .sw-row[data-row='0'] .sw-tile.p, .sw-row[data-row='0'] .sw-tile.n", (t) => t.length) === 5, "preview evaluates a guess");
  await ctx.close();

  console.log("\n▶ spark-word.html — keys set → real backend, newsletter link (query style) as Priya");
  ({ ctx, errors } = await context(browser, "spark-word.html", true));
  page = await ctx.newPage();
  await page.goto(BASE + "/spark-word.html?issue=14&t=test-priya-natarajan-nvidia-000000000003", { waitUntil: "networkidle" }); await wait(900);
  check(await page.evaluate(() => window.SparkWord.api.mode) === "supabase", "mode = supabase");
  check(await page.$eval("#swStandaloneBadge", (el) => el.hidden), "preview badge hidden");
  check(!page.url().includes("t=test-"), "token stripped → " + page.url());
  check((await page.$eval("#swIdentity", (el) => el.innerText)).includes("Priya Natarajan"), "recognised as Priya Natarajan");
  check((await page.$eval("#swIssueLine", (el) => el.innerText)).includes("ISSUE 014"), "issue 014 loaded");
  await page.click("#swStartBtn"); await wait(300);
  for (const w of ["crane", "audio", "tower"]) { await page.keyboard.type(w); await page.keyboard.press("Enter"); await wait(1500); }
  check(await page.$("#swHintBtn") !== null, "hint unlocked after 3 guesses");
  await page.click("#swHintBtn"); await wait(500);
  check((await page.$eval("#swHint", (el) => el.innerText)).includes("Strands of glass"), "hint from the DB");
  await page.keyboard.type("fiber"); await page.keyboard.press("Enter"); await wait(2600);
  check(/solved in 4\/6/i.test(await page.$eval("#swResultSheet", (el) => el.innerText)), "solved in 4/6 (server-evaluated)");
  const share = await page.evaluate(() => window.SparkWord.shareText());
  check(share.includes(BASE + "/spark-word.html?issue=14"), "share link keeps the page's own file name → " + (share.match(/https?:\S+/) || [""])[0]);
  check(!share.includes("FIBER"), "share text hides the answer");
  await page.click("#swResultSheet .x"); await wait(200);
  await page.click("#swTabs [data-view='leaderboard']"); await wait(1200);
  check((await page.$eval("#swLbBody", (el) => el.innerText)).includes("ISSUE 014 LEADERBOARD"), "leaderboard from the DB");
  await ctx.close();

  console.log("\n▶ spark-word.html — phone, guest");
  ({ ctx, errors } = await context(browser, "spark-word.html", true, { ...devices["iPhone 13"], viewport: { width: 390, height: 844 } }));
  page = await ctx.newPage();
  await page.goto(BASE + "/spark-word.html", { waitUntil: "networkidle" }); await wait(800);
  await page.tap("#swStartBtn"); await wait(300);
  check((await page.$eval("#swIdentity", (el) => el.innerText)).includes("guest"), "guest identity on a phone");
  const noHScroll = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
  check(noHScroll, "no horizontal scroll on a 390px phone");
  for (const ch of "CRANE") await page.tap(`.sw-key[data-key="${ch}"]`); await page.tap(".sw-key[data-key='Enter']"); await wait(1500);
  check(await page.$$eval(".sw-row[data-row='0'] .sw-tile", (ts) => ts.every((t) => /\b(a|p|n)\b/.test(t.className))) === true, "on-screen keyboard guess evaluated");
  await ctx.close();

  console.log("\n▶ spark-word-admin.html — no keys → design-preview dashboard renders");
  ({ ctx, errors } = await context(browser, "spark-word-admin.html", false));
  page = await ctx.newPage();
  await page.goto(BASE + "/spark-word-admin.html", { waitUntil: "networkidle" }); await wait(1200);
  check(/Design preview: any email signs in/.test(await page.$eval("#loginMsg", (el) => el.innerText)), "sign-in screen explains preview mode");
  await page.click("#previewIn"); await wait(1200);
  const txt = await page.evaluate(() => document.body.innerText);
  check(/design preview/i.test(txt), "preview note shown");
  check(/CONFIG block at the top of spark-word-admin\.html/.test(txt), "note points at the CONFIG block");
  check(/Issue 014/.test(txt), "overview lists Issue 014");
  const previewLink = await page.$eval("a[href*='?issue=']", (a) => a.getAttribute("href"));
  check(previewLink.startsWith("spark-word.html?issue="), "'Open game' links target spark-word.html → " + previewLink);
  await ctx.close();

  check(!errors.filter((e) => !/net::|ERR_/.test(e)).length, "no JS errors");
  await browser.close();
  console.log(failures ? `\n${failures} CHECK(S) FAILED` : "\nALL SINGLE-FILE CHECKS PASSED");
  process.exit(failures ? 1 : 0);
})();
