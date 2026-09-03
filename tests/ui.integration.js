/* ============================================================
   UI ↔ SQL INTEGRATION TEST
   Drives the real front-end (index.html + spark-word.js + supabase-js)
   against the real Postgres functions through tests/local-rpc-server.js.
   Verifies the RPC contract (parameter names, payload shapes) end to end.

   Prereqs:  cd tests && npm install
             bash reset_local_db.sh
             node local-rpc-server.js &            (port 54321)
   Run:      node ui.integration.js
   ============================================================ */
const { chromium, devices } = require("playwright");
const path = require("path");
const BASE = process.env.BASE || "http://localhost:54321";
const UMD = path.resolve(__dirname, "node_modules/@supabase/supabase-js/dist/umd/supabase.js");
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (cond, msg) => { console.log((cond ? "  ✓ " : "  ✗ ") + msg); if (!cond) failures++; };

async function context(browser, opts) {
  const ctx = await browser.newContext(opts || { viewport: { width: 1380, height: 900 } });
  await ctx.route("**/cdn.jsdelivr.net/**", (route) => route.fulfill({ path: UMD, contentType: "application/javascript" }));
  await ctx.route("**/assets/spark-word-config.js", (route) => route.fulfill({ contentType: "application/javascript", body: `window.SPARK_WORD_CONFIG={supabaseUrl:"${BASE}",supabaseAnonKey:"test-anon-key",siteUrl:"${BASE}",urlStyle:"path"};` }));
  const errors = [];
  ctx.on("page", (p) => { p.on("pageerror", (e) => errors.push("pageerror: " + e.message)); p.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); }); });
  return { ctx, errors };
}

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" });

  console.log("\n▶ Newsletter link (path style) as Priya — token stripped, recognised, official window");
  let { ctx, errors } = await context(browser);
  let page = await ctx.newPage();
  await page.goto(BASE + "/spark-word/014?t=test-priya-natarajan-nvidia-000000000003", { waitUntil: "networkidle" });
  await wait(800);
  check(!page.url().includes("t=test-"), "token removed from address bar → " + page.url());
  check(await page.evaluate(() => window.SparkWord.api.mode) === "supabase", "client is in supabase mode");
  check((await page.$eval("#swIdentity", (el) => el.innerText)).includes("Priya Natarajan"), "recognised as Priya Natarajan (full-name preference)");
  check((await page.$eval("#swIssueLine", (el) => el.innerText)).includes("ISSUE 014"), "issue 014 loaded");
  await page.click("#swStartBtn"); await wait(300);

  console.log("\n▶ Gameplay: invalid guess, three misses, hint gate, solve");
  await page.keyboard.type("zzzzz"); await page.keyboard.press("Enter"); await wait(700);
  check((await page.$eval("#swLive", (el) => el.textContent)).includes("Not in the word list"), "dictionary rejection surfaced (live region)");
  for (let i = 0; i < 5; i++) await page.keyboard.press("Backspace");
  for (const w of ["crane", "audio", "tower"]) { await page.keyboard.type(w); await page.keyboard.press("Enter"); await wait(1500); }
  check(await page.$("#swHintBtn") !== null, "hint button unlocked after 3 guesses");
  const tileStates = await page.$$eval(".sw-row[data-row='0'] .sw-tile", (ts) => ts.map((t) => t.className.replace("sw-tile", "").trim()).join(""));
  check(tileStates === "apaap", "CRANE vs FIBER evaluated server-side → apaap (got " + tileStates + ")");
  await page.click("#swHintBtn"); await wait(500);
  check((await page.$eval("#swHint", (el) => el.innerText)).includes("Strands of glass"), "hint text delivered from the DB");
  await page.keyboard.type("fiber"); await page.keyboard.press("Enter"); await wait(2600);
  check((await page.$eval("#swResultSheet", (el) => el.innerText)).includes("FIBER"), "result sheet shows the answer");
  check(/solved in 4\/6/i.test(await page.$eval("#swResultSheet", (el) => el.innerText)), "solved in 4/6");
  const st = await page.evaluate(() => window.SparkWord.state.completion);
  check(st.score === 51, "score 50 − 5 hint + 3-issue streak ×2 = 51 (got " + st.score + ")");
  check(st.streak.current === 3, "streak now 3 (12, 13, 14)");
  check(st.rank && st.rank.rank >= 1, "ranked #" + (st.rank && st.rank.rank) + " of " + (st.rank && st.rank.total));
  const share = await page.evaluate(() => window.SparkWord.shareText());
  check(!share.includes("FIBER") && share.includes("ISSUE 014") && share.includes("4/6"), "share text hides the answer");
  await page.click("#swResultSheet .x"); await wait(300);

  console.log("\n▶ Resume + replay protection");
  await page.reload({ waitUntil: "networkidle" }); await wait(900);
  check((await page.$eval("#swResult", (el) => el.hidden === false && el.innerText.includes("FIBER"))), "completed game restored after reload");
  await page.click("#swResult [data-sw-replay]"); await wait(500);
  check((await page.$eval("#swModeBanner", (el) => el.innerText)).toLowerCase().includes("archive"), "replay opens in archive mode");
  await page.keyboard.type("fiber"); await page.keyboard.press("Enter"); await wait(2400);
  const rp = await page.evaluate(() => window.SparkWord.state.completion);
  check(rp.mode === "archive" && rp.score === 0, "replay is an archive game with 0 points");
  await page.click("#swResultSheet .x"); await wait(200);

  console.log("\n▶ Leaderboards from the database");
  await page.click("#swTabs [data-view='leaderboard']"); await wait(1200);
  const lb = await page.$eval("#swLbBody", (el) => el.innerText);
  check(lb.includes("ISSUE 014 LEADERBOARD") && lb.includes("Michelle K."), "issue leaderboard rendered with DB rows");
  check(lb.includes("YOUR POSITION"), "your position block present");
  await page.click("#swLbTabs [data-lb='allstars']"); await wait(1000);
  check((await page.$eval("#swLbBody", (el) => el.innerText)).includes("James R."), "All-Stars rendered");
  await page.click("[data-as-scope='tt']"); await wait(900);
  const tt = await page.$$eval("#swLbBody tbody tr", (trs) => trs.map((t) => t.innerText));
  check(tt.length > 0 && tt.every((r) => r.includes("Turner & Townsend")), "T&T scope filter");
  await page.click("#swLbTabs [data-lb='companies']"); await wait(900);
  check((await page.$eval("#swLbBody", (el) => el.innerText)).includes("NVIDIA"), "company standings rendered");
  check((await page.$eval("#swShareout", (el) => el.innerText)).includes("POWER"), "shareout reveals POWER to a player who completed issue 013");

  console.log("\n▶ Archive");
  await page.click("#swTabs [data-view='archive']"); await wait(1000);
  const arch = await page.$eval("#swArchiveList", (el) => el.innerText);
  check(arch.includes("011") && (await page.$("#swArch11 .a-word.hidden")) !== null && !arch.includes("STEEL"), "unplayed issue 011 stays hidden");
  check(arch.includes("POWER") && arch.includes("RADIO"), "played issues show their words");
  await page.click("#swArch11 button"); await wait(1200);
  check((await page.$eval("#swModeBanner", (el) => el.innerText)).toLowerCase().includes("archive"), "issue 011 opens in archive mode");
  await page.keyboard.type("steel"); await page.keyboard.press("Enter"); await wait(2400);
  const arc = await page.evaluate(() => window.SparkWord.state.completion);
  check(arc.mode === "archive" && arc.score === 0, "archive game scores 0 and is unranked");
  await ctx.close();

  console.log("\n▶ Guest on a phone: fail in six, then claim a NEW email");
  ({ ctx, errors } = await context(browser, { ...devices["iPhone 13"], viewport: { width: 390, height: 844 } }));
  page = await ctx.newPage();
  await page.goto(BASE + "/index.html#spark-word", { waitUntil: "networkidle" }); await wait(800);
  await page.tap("#swStartBtn"); await wait(300);
  check((await page.$eval("#swIdentity", (el) => el.innerText)).includes("guest"), "guest identity");
  for (const w of ["CRANE", "SOLAR", "BUILD", "MEDIA", "TOWER", "CLOUD"]) { for (const ch of w) await page.tap(`.sw-key[data-key="${ch}"]`); await page.tap(".sw-key[data-key='Enter']"); await wait(1400); }
  await wait(1200);
  const fail = await page.$eval("#swResultSheet", (el) => el.innerText);
  check(/the spark got away/i.test(fail) && fail.includes("FIBER"), "fail state reveals the word");
  check(fail.includes("Claim my rank"), "guest offered to claim");
  await page.tap("#swResultSheet [data-sw-claim]"); await wait(500);
  await page.fill("#swcEmail", "kai.nguyen@example-anthropic.com"); await page.fill("#swcFirst", "Kai"); await page.fill("#swcLast", "Nguyen"); await page.fill("#swcCompany", "Anthropic");
  await page.tap("#swClaimForm button[type=submit]"); await wait(1500);
  check((await page.$eval("#swIdentity", (el) => el.innerText)).includes("Kai N."), "profile created and recognised → " + (await page.$eval("#swIdentity", (el) => el.innerText)).split("\n")[0]);
  const tok = await page.evaluate(() => localStorage.getItem("sw_token"));
  check(tok && tok.length > 30, "token stored for future visits");

  console.log("\n▶ Guest claiming an EXISTING subscriber email → verification required (no token leaked)");
  await page.evaluate(() => { localStorage.removeItem("sw_token"); localStorage.removeItem("sw_guest_id"); });
  await page.goto(BASE + "/index.html?issue=13#spark-word", { waitUntil: "networkidle" }); await wait(900);
  await page.keyboard.type("power"); await page.keyboard.press("Enter"); await wait(2400);
  await page.tap("#swResultSheet .x"); await wait(200);
  // issue 13 is archived → no claim CTA (archive games aren't ranked); open claim via API directly to test the contract
  const res = await page.evaluate(async () => window.SparkWord.api.rpc("sw_claim_profile", { p_guest_id: localStorage.getItem("sw_guest_id"), p_email: "sarah.m@example-nvidia.com", p_first_name: "Sarah", p_company: "NVIDIA" }));
  check(res.status === "verify_required" && !res.token, "existing email → verify_required, token withheld");
  check(!errors.filter((e) => !/net::|ERR_/.test(e)).length, "no JS errors (" + errors.length + " network-only noise)");
  await ctx.close();
  await browser.close();
  console.log(failures ? `\n${failures} CHECK(S) FAILED` : "\nALL INTEGRATION CHECKS PASSED");
  process.exit(failures ? 1 : 0);
})();
