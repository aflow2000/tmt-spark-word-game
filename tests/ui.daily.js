/* DAILY EDITION test — build with `node scripts/build-daily.js`, serve the project root (python3 -m http.server 8080) and run `node tests/ui.daily.js`.
   Covers: day 1 today, hint after 2 guesses (two lines), first letter after 4, win sheet, device persistence across reload,
   day 18 with a mocked clock (word rotation, archive, yesterday shareout), phone layout. */
const { chromium, devices } = require("playwright");
const wait=(ms)=>new Promise(r=>setTimeout(r,ms)); let fails=0;
const check=(c,m)=>{console.log((c?"  ✓ ":"  ✗ ")+m); if(!c)fails++;};
const URL=(process.env.BASE || "http://localhost:8080")+"/spark-word-daily.html";
(async()=>{
  const b=await chromium.launch({executablePath:"/opt/pw-browsers/chromium"});
  // ---- Day 1 (today, 2026-09-03) ----
  let ctx=await b.newContext({viewport:{width:1280,height:900}}); let errs=[]; let reqs=[];
  let p=await ctx.newPage(); p.on("pageerror",e=>errs.push(e.message)); p.on("console",m=>{if(m.type()==="error")errs.push(m.text())}); p.on("request",r=>{ if(!r.url().includes("localhost")) reqs.push(r.url()); });
  await p.goto(URL,{waitUntil:"networkidle"}); await wait(900);
  console.log("\n▶ Day 1 — today");
  check(reqs.length===0,"no external requests");
  const line=await p.$eval("#swIssueLine",e=>e.innerText); check(/DAY 001/.test(line)&&/SEPTEMBER 3, 2026/i.test(line),"header → "+line.replace(/\n/g," "));
  check(/Daily edition/i.test(await p.$eval("#swPreviewBanner",e=>e.innerText)),"daily banner");
  check((await p.$eval("#swHint",e=>e.innerText)).includes("TODAY'S SECTOR"),"'Today's sector' chip");
  await p.click("#swStartBtn"); await wait(300);
  await p.keyboard.type("crane"); await p.keyboard.press("Enter"); await wait(1500);
  check(await p.$("#swHintBtn")===null && /after your next guess/i.test(await p.$eval("#swHint",e=>e.innerText)),"hint locked after 1 guess, unlocks after next");
  await p.keyboard.type("audio"); await p.keyboard.press("Enter"); await wait(1500);
  check(await p.$("#swHintBtn")!==null,"hint unlocked after 2 guesses");
  await p.click("#swHintBtn"); await wait(500);
  const paras=await p.$$eval(".sw-hint-box p",ps=>ps.map(x=>x.innerText));
  check(paras.length===2 && /trained brain/i.test(paras[0]) && /runway/i.test(paras[1]),"two-line hint: "+paras.join(" | "));
  await p.keyboard.type("tower"); await p.keyboard.press("Enter"); await wait(1500);
  await p.keyboard.type("build"); await p.keyboard.press("Enter"); await wait(1500);
  check(await p.$("#swSecondBtn")!==null,"second spark offered after 4 guesses");
  await p.click("#swSecondBtn"); await wait(500);
  check(/starts with\s*M/i.test(await p.$eval("#swHint",e=>e.innerText)),"first letter M revealed");
  await p.keyboard.type("model"); await p.keyboard.press("Enter"); await wait(2500);
  const sheet=await p.$eval("#swResultSheet",e=>e.innerText);
  check(/solved in 5\/6/i.test(sheet)&&sheet.includes("MODEL")&&/Tomorrow's Spark Word/i.test(sheet),"win sheet: MODEL, 5/6, tomorrow teaser");
  check(/trained system at the heart of AI/i.test(sheet),"explanation shown");
  await p.click("#swResultSheet .x"); await wait(300);
  await p.click("#swTabs [data-view='leaderboard']"); await wait(900);
  const lb=await p.$eval("#swLbBody",e=>e.innerText);
  check(/DAY 001 LEADERBOARD/.test(lb) && /YOUR POSITION/.test(lb),"day leaderboard + your position");
  await p.click("#swTabs [data-view='howto']"); await wait(400);
  const howto=await p.$eval("#swHowtoBody",e=>e.innerText);
  check(/after two guesses/.test(howto)&&/guess four/.test(howto)&&/consecutive days/.test(howto),"how-to text reflects 2/4 and days");
  await p.click("#swTabs [data-view='archive']"); await wait(600);
  check(/DAY 001 .* CURRENT/i.test((await p.$eval("#swArchiveList",e=>e.innerText)).replace(/\n/g," ")) && !/DAY 002/.test(await p.$eval("#swArchiveList",e=>e.innerText)),"archive shows only today on day 1");
  // persistence across reload
  await p.reload({waitUntil:"networkidle"}); await wait(900);
  check(await p.$eval("#swResult",e=>!e.hidden&&e.innerText.includes("MODEL")),"completed game restored after reload (device storage)");
  check(errs.length===0,"no JS errors "+JSON.stringify(errs.slice(0,2)));
  await p.screenshot({path:"/tmp/daily-1.png",fullPage:false});
  await ctx.close();

  // ---- Day 18 (clock moved to 2026-09-20) ----
  console.log("\n▶ Day 18 — clock set to 2026-09-20");
  ctx=await b.newContext({viewport:{width:1280,height:900}}); errs=[];
  p=await ctx.newPage(); p.on("pageerror",e=>errs.push(e.message));
  await p.clock.install({ time: new Date("2026-09-20T10:00:00") });
  await p.goto(URL,{waitUntil:"networkidle"}); await wait(900);
  const line2=await p.$eval("#swIssueLine",e=>e.innerText); check(/DAY 018/.test(line2)&&/SEPTEMBER 20, 2026/i.test(line2),"header → "+line2.replace(/\n/g," "));
  check((await p.$eval("#swHint",e=>e.innerText)).includes("Data Centers"),"sector chip: Data Centers");
  await p.click("#swStartBtn"); await wait(300);
  await p.keyboard.type("cages"); await p.keyboard.press("Enter"); await wait(2500);
  check(/solved in 1\/6/i.test(await p.$eval("#swResultSheet",e=>e.innerText)),"Day 18 word is CAGES (1/6)");
  await p.click("#swResultSheet .x"); await wait(300);
  await p.click("#swTabs [data-view='archive']"); await wait(800);
  const arch=await p.$eval("#swArchiveList",e=>e.innerText);
  check(/DAY 017/.test(arch)&&/DAY 001/.test(arch)&&!/AISLE/.test(arch),"archive lists past days, unplayed words hidden");
  await p.click("#swTabs [data-view='leaderboard']"); await wait(900);
  await p.click("#swLbTabs [data-lb='companies']"); await wait(700);
  check(/Yesterday's Spark Word · Day 017/i.test(await p.$eval("#swShareout",e=>e.innerText)),"shareout says yesterday · Day 017");
  check(errs.length===0,"no JS errors "+JSON.stringify(errs.slice(0,2)));
  await ctx.close();

  // ---- phone ----
  console.log("\n▶ Phone");
  ctx=await b.newContext({...devices["iPhone 13"],viewport:{width:390,height:844}}); errs=[];
  p=await ctx.newPage(); p.on("pageerror",e=>errs.push(e.message));
  await p.goto(URL,{waitUntil:"networkidle"}); await wait(900);
  await p.tap("#swStartBtn"); await wait(300);
  for (const w of ["CRANE","AUDIO"]) { for(const ch of w) await p.tap(`.sw-key[data-key="${ch}"]`); await p.tap(".sw-key[data-key='Enter']"); await wait(1500); }
  await p.tap("#swHintBtn"); await wait(600);
  check((await p.$$eval(".sw-hint-box p",ps=>ps.length))===2,"hint shows both lines on a phone");
  check(await p.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth+1),"no horizontal scroll");
  await p.screenshot({path:"/tmp/daily-phone.png"});
  check(errs.length===0,"no JS errors");
  await ctx.close(); await b.close();
  console.log(fails?"\nFAILED "+fails:"\nALL DAILY CHECKS PASSED"); process.exit(fails?1:0);
})();
