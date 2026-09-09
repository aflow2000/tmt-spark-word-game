/* ============================================================
   PLAYER ACCOUNTS — browser test against the real SQL + the harness's
   GoTrue look-alike (tests/local-rpc-server.js).

   Covers: guest win → create account → confirmation email → signed in with
   the game attached · sign out · password sign-in · wrong password ·
   duplicate sign-up · forgot password → reset link → new password · magic
   link · a second device signing in · sign-up with "Confirm email" off ·
   the "Next word · date (in N days)" header.

   Prereqs:  bash tests/reset_local_db.sh
             cd tests && node local-rpc-server.js &     (port 54321)
   Run:      node tests/ui.accounts.js
   ============================================================ */
const { chromium, devices } = require("playwright");
const path = require("path");
const BASE = process.env.BASE || "http://localhost:54321";
const UMD = path.resolve(__dirname, "node_modules/@supabase/supabase-js/dist/umd/supabase.js");
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (cond, msg) => { console.log((cond ? "  ✓ " : "  ✗ ") + msg); if (!cond) failures++; };
const post = (p, body) => fetch(BASE + p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body || {}) }).then((r) => r.json());
const lastMail = async (type, to) => { const box = await fetch(BASE + "/__auth/mailbox").then((r) => r.json()); const m = box.filter((x) => x.type === type && (!to || x.to === to)).pop(); return m && m.link; };

async function context(browser, opts) {
  const ctx = await browser.newContext(opts || { viewport: { width: 1380, height: 900 } });
  await ctx.route("**/cdn.jsdelivr.net/**", (route) => route.fulfill({ path: UMD, contentType: "application/javascript" }));
  await ctx.route("**/assets/spark-word-config.js", (route) => route.fulfill({ contentType: "application/javascript", body: `window.SPARK_WORD_CONFIG={supabaseUrl:"${BASE}",supabaseAnonKey:"test-anon-key",siteUrl:"${BASE}",urlStyle:"path"};` }));
  const errors = [];
  ctx.on("page", (p) => { p.on("pageerror", (e) => errors.push("pageerror: " + e.message)); p.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); }); });
  return { ctx, errors };
}
const identity = (page) => page.$eval("#swIdentity", (el) => el.innerText.replace(/\s+/g, " "));
const authErr = (page) => page.$eval("#swAuthErr", (el) => el.innerText);
const closeSheets = async (page) => { for (const v of await page.$$(".veil.on")) { const x = await v.$(".x"); if (x) await x.click().catch(() => {}); } await wait(250); };

(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || "/opt/pw-browsers/chromium" });
  await post("/__auth/reset"); await post("/__auth/config", { autoconfirm: false });
  const EMAIL = "kai.nguyen@example-anthropic.com";

  console.log("\n▶ Header: fortnightly cadence visible");
  let { ctx, errors } = await context(browser);
  let page = await ctx.newPage();
  await page.goto(BASE + "/index.html#spark-word", { waitUntil: "networkidle" }); await wait(900);
  const line = await page.$eval("#swIssueLine", (el) => el.innerText.replace(/\s+/g, " "));
  check(/ISSUE 014 .* SEPTEMBER 3, 2026/.test(line), "issue line shows the publication date → " + line);
  check(/NEXT WORD OCTOBER 1 \(IN \d+ DAYS\)/.test(line), "next word + countdown from next_issue → " + (line.match(/NEXT WORD[^·]*/) || [""])[0]);
  check(/Sign in/.test(await identity(page)) && /Create account/.test(await identity(page)), "guest identity offers Sign in / Create account");

  console.log("\n▶ Guest wins, then creates an account (email confirmation ON)");
  await page.click("#swStartBtn"); await wait(300);
  await page.keyboard.type("crane"); await page.keyboard.press("Enter"); await wait(1500);
  await page.keyboard.type("fiber"); await page.keyboard.press("Enter"); await wait(2600);
  check(/solved in 2\/6/i.test(await page.$eval("#swResultSheet", (el) => el.innerText)), "guest solved 2/6");
  check(await page.$("#swResultSheet [data-sw-auth='signup']") !== null, "result sheet offers Create account");
  await page.click("#swResultSheet [data-sw-auth='signup']"); await wait(400);
  check(/Create your/.test(await page.$eval("#swClaimSheet h3", (el) => el.innerText)), "sign-up sheet opened");
  await page.fill("#swaEmail", EMAIL); await page.fill("#swaPass", "sparkword-2026"); await page.fill("#swaFirst", "Kai"); await page.fill("#swaLast", "Nguyen"); await page.fill("#swaCompany", "Anthropic");
  await page.click("#swAuthForm button[type=submit]"); await wait(1200);
  check(/Check your email/.test(await page.$eval("#swClaimSheet", (el) => el.innerText)), "asked to confirm the email");
  const link = await lastMail("signup", EMAIL);
  check(!!link && /verify\?token=/.test(link), "confirmation email 'sent' with a verify link");
  await page.goto(link, { waitUntil: "networkidle" }); await wait(1800);
  check(/index\.html\?issue=14/.test(page.url()) && !/code=|verify=/.test(page.url()), "redirected back, code + verify stripped → " + page.url());
  check(/Playing as Kai N\./.test(await identity(page)), "signed in as Kai N. after confirming → " + await identity(page));
  check(!!(await page.evaluate(() => localStorage.getItem("sw_token"))), "token stored");
  check(await page.$eval("#swResult", (el) => !el.hidden && /#\d+ of \d+|YOU RANK/i.test(el.innerText)), "guest game attached and ranked");
  await page.click("#swTabs [data-view='leaderboard']"); await wait(1200);
  check(/Kai N\./.test(await page.$eval("#swLbBody", (el) => el.innerText)), "appears on the issue leaderboard");
  const sess = await page.evaluate(() => Object.keys(localStorage).filter((k) => /^sb-.*auth-token$/.test(k)).length);
  check(sess === 0, "Supabase session released after linking (identity is the token)");

  console.log("\n▶ Sign out, wrong password, correct password");
  await closeSheets(page);
  await page.click("#swPrefsBtn"); await wait(300);
  check(/Sign out/.test(await page.$eval("#swProfileSheet", (el) => el.innerText)), "preferences offer Sign out");
  await page.click("#swForget"); await wait(1200);
  check(/Playing as guest/.test(await identity(page)), "signed out → guest");
  await page.click("#swIdentity [data-sw-auth='signin']"); await wait(300);
  await page.fill("#swaEmail", EMAIL); await page.fill("#swaPass", "wrong-password"); await page.click("#swAuthForm button[type=submit]"); await wait(800);
  check(/Wrong email or password/.test(await authErr(page)), "wrong password explained");
  await page.fill("#swaPass", "sparkword-2026"); await page.click("#swAuthForm button[type=submit]"); await wait(1500);
  check(/Playing as Kai N\./.test(await identity(page)), "password sign-in → Kai N.");
  check(await page.evaluate(() => window.SparkWord.state.player.stats.games_played) === 1, "history preserved (1 game played)");

  console.log("\n▶ Duplicate sign-up is refused politely");
  await closeSheets(page);
  await page.click("#swPrefsBtn"); await wait(200); await page.click("#swForget"); await wait(1000);
  await page.click("#swIdentity [data-sw-auth='signup']"); await wait(300);
  await page.fill("#swaEmail", EMAIL); await page.fill("#swaPass", "another-pass-123"); await page.fill("#swaFirst", "Kai"); await page.fill("#swaCompany", "Anthropic");
  await page.click("#swAuthForm button[type=submit]"); await wait(800);
  check(/already has an account/.test(await authErr(page)), "duplicate email → sign in instead");

  console.log("\n▶ Forgot password → reset link → new password");
  await page.click("#swAuthForm ~ p [data-sw-auth='signin']"); await wait(200);
  await page.click("[data-sw-auth='forgot']"); await wait(200);
  await page.fill("#swaEmail", EMAIL); await page.click("#swAuthForm button[type=submit]"); await wait(800);
  check(/reset link is on its way/.test(await page.$eval("#swClaimSheet", (el) => el.innerText)), "reset email 'sent'");
  const rlink = await lastMail("recovery", EMAIL);
  await page.goto(rlink, { waitUntil: "networkidle" }); await wait(1800);
  check(/Choose a new/.test(await page.$eval("#swClaimSheet h3", (el) => el.innerText).catch(() => "")), "reset sheet opened from the link");
  await page.fill("#swaPass", "brand-new-pass-1"); await page.fill("#swaPass2", "brand-new-pass-2"); await page.click("#swAuthForm button[type=submit]"); await wait(400);
  check(/don't match/.test(await authErr(page)), "mismatch caught");
  await page.fill("#swaPass2", "brand-new-pass-1"); await page.click("#swAuthForm button[type=submit]"); await wait(1500);
  check(/Playing as Kai N\./.test(await identity(page)), "signed in after saving the new password");
  await closeSheets(page);
  await page.click("#swPrefsBtn"); await wait(200); await page.click("#swForget"); await wait(1000);
  await page.click("#swIdentity [data-sw-auth='signin']"); await wait(300);
  await page.fill("#swaEmail", EMAIL); await page.fill("#swaPass", "brand-new-pass-1"); await page.click("#swAuthForm button[type=submit]"); await wait(1500);
  check(/Playing as Kai N\./.test(await identity(page)), "new password works");

  console.log("\n▶ Magic link (no password)");
  await closeSheets(page);
  await page.click("#swPrefsBtn"); await wait(200); await page.click("#swForget"); await wait(1000);
  await page.click("#swIdentity [data-sw-auth='signin']"); await wait(200);
  await page.click("[data-sw-auth='magic']"); await wait(200);
  await page.fill("#swaEmail", EMAIL); await page.click("#swAuthForm button[type=submit]"); await wait(800);
  const mlink = await lastMail("magiclink", EMAIL);
  check(!!mlink, "magic link 'sent'");
  await page.goto(mlink, { waitUntil: "networkidle" }); await wait(1800);
  check(/Playing as Kai N\./.test(await identity(page)), "magic link signs in");
  await ctx.close();

  console.log("\n▶ Second device: sign in with the password, history follows");
  ({ ctx, errors } = await context(browser, { ...devices["iPhone 13"], viewport: { width: 390, height: 844 } }));
  page = await ctx.newPage();
  await page.goto(BASE + "/index.html#spark-word", { waitUntil: "networkidle" }); await wait(900);
  await page.tap("#swStartBtn"); await wait(300);
  await page.tap("#swIdentity [data-sw-auth='signin']"); await wait(300);
  await page.fill("#swaEmail", EMAIL); await page.fill("#swaPass", "brand-new-pass-1"); await page.tap("#swAuthForm button[type=submit]"); await wait(1800);
  check(/Playing as Kai N\./.test(await identity(page)), "phone: signed in");
  check(await page.$eval("#swResult", (el) => !el.hidden && /FIBER/.test(el.innerText)), "phone: this issue's result from the other device is shown");
  check(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), "phone: no horizontal scroll with the account buttons");
  await ctx.close();

  console.log("\n▶ Sign-up with 'Confirm email' OFF → signed in immediately");
  await post("/__auth/config", { autoconfirm: true });
  ({ ctx, errors } = await context(browser));
  page = await ctx.newPage();
  await page.goto(BASE + "/index.html?issue=14#spark-word", { waitUntil: "networkidle" }); await wait(900);
  await page.click("#swStartBtn"); await wait(300);
  await page.keyboard.type("cable"); await page.keyboard.press("Enter"); await wait(1500);
  await page.keyboard.type("fiber"); await page.keyboard.press("Enter"); await wait(2600);
  await page.click("#swResultSheet [data-sw-auth='signup']"); await wait(300);
  await page.fill("#swaEmail", "dana.ruiz@example-vantage.com"); await page.fill("#swaPass", "vantage-2026!"); await page.fill("#swaFirst", "Dana"); await page.fill("#swaLast", "Ruiz"); await page.fill("#swaCompany", "Vantage Data Centers");
  await page.check("#swAuthForm input[value='full_name']");
  await page.click("#swAuthForm button[type=submit]"); await wait(1800);
  check(/Playing as Dana Ruiz/.test(await identity(page)), "instant sign-up → Dana Ruiz (full name preference)");
  check(await page.$eval("#swResultSheet", (el) => /#\d+ of \d+/i.test(el.innerText)), "result sheet reopened with the rank");
  await ctx.close();

  check(!errors.filter((e) => !/net::|ERR_/.test(e)).length, "no JS errors (" + errors.length + " network-only)");
  await browser.close();
  console.log(failures ? `\n${failures} CHECK(S) FAILED` : "\nALL ACCOUNT CHECKS PASSED");
  process.exit(failures ? 1 : 0);
})();
