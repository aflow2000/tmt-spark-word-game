/* Smoke test of the DESIGN PREVIEW (no backend): serves the folder, plays a
   full game with the physical + on-screen keyboard, checks share text, tabs,
   search and the learning strip. Run: python3 -m http.server 8080 & node tests/ui.preview.js */
const { chromium } = require("playwright");
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const BASE = process.env.BASE || "http://localhost:8080";
let failures = 0; const check = (c, m) => { console.log((c ? "  ✓ " : "  ✗ ") + m); if (!c) failures++; };
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" });
  const page = await browser.newPage({ viewport: { width: 1380, height: 900 } });
  const errors = []; page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(BASE + "/index.html?issue=14&t=test-priya-natarajan-nvidia-000000000003", { waitUntil: "networkidle" }); await wait(900);
  check(await page.evaluate(() => window.SparkWord.api.mode) === "preview", "preview adapter active");
  check(await page.$("#swPreviewBanner") !== null, "preview banner visible");
  await page.click("#swStartBtn"); await wait(300);
  for (const w of ["crane", "audio", "tower"]) { await page.keyboard.type(w); await page.keyboard.press("Enter"); await wait(1500); }
  await page.click("#swHintBtn"); await wait(400);
  for (const ch of "FIBER") await page.click(`.sw-key[data-key="${ch}"]`);
  await page.click(".sw-key[data-key='Enter']"); await wait(2600);
  check(/you got the spark/i.test(await page.$eval("#swResultSheet", (el) => el.innerText)), "win state");
  const share = await page.evaluate(() => window.SparkWord.shareText());
  check(share.startsWith("TMT SPARK WORD · ISSUE 014 ⚡") && !share.includes("FIBER"), "share text format, answer hidden");
  await page.click("#swResultSheet .x");
  await page.click("#swTabs [data-view='leaderboard']"); await wait(800);
  check((await page.$eval("#swLbBody", (el) => el.innerText)).includes("ISSUE 014 LEADERBOARD"), "leaderboard tab");
  await page.click("#swTabs [data-view='archive']"); await wait(800);
  check((await page.$$("#swArchiveList .sw-arch")).length === 4, "archive lists 4 published issues");
  await page.click(".navlinks button[data-go='learning']"); await wait(600);
  check((await page.$eval("#swLearnStrip", (el) => el.hidden ? "" : el.innerText)).includes("FIBER"), "Spark Learning strip shows cracked words");
  await page.keyboard.press("Control+k"); await wait(200); await page.fill("#searchInput", "spark word"); await wait(200);
  check((await page.$eval("#searchRes", (el) => el.innerText)).includes("Past Spark Words"), "search index entries");
  check(errors.length === 0, "no JS errors");
  await browser.close();
  console.log(failures ? `\n${failures} CHECK(S) FAILED` : "\nPREVIEW SMOKE TEST PASSED");
  process.exit(failures ? 1 : 0);
})();
