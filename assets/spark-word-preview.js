/* ============================================================
   SPARK WORD — DESIGN PREVIEW ADAPTER (no backend)
   ------------------------------------------------------------
   Loaded by spark-word.js ONLY when assets/spark-word-config.js has no
   Supabase credentials. It answers the same RPC names with the same
   JSON shapes as the Postgres functions, from an in-memory copy of the
   seed data, so the interface can be reviewed before Supabase exists.

   ► Nothing here is persisted. Reloading the page resets everything.
   ► The game shows a "Design preview" banner while this is active.
   ► Gameplay logic is a faithful port of supabase/migrations/002 —
     tests/evaluate.test.js checks the two evaluators agree.
   ============================================================ */
(function () {
  "use strict";
  const pad3 = (n) => String(n).padStart(3, "0");
  const uuid = () => (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : "p-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
  const clone = (o) => JSON.parse(JSON.stringify(o));
  const SETTINGS = { hint_unlock_after: 3, second_spark_after: 5, streak_bonus_cap: 10, company_min_players: 3, min_seconds_per_guess: 0.7, require_verification_new: "false" };
  const CFG = window.SPARK_WORD_CONFIG || {};
  const NOUN = (CFG.issueNoun || "issue").toLowerCase();

  /* ---------------- daily schedule (optional) ----------------
     When assets/spark-word-daily-words.js is loaded, the issues are generated
     from it: one word per calendar day from startDate. The player's own games
     are kept in localStorage (this device only); the other players on the
     boards are generated sample data. */
  const SCHED = window.SPARK_WORD_SCHEDULE || null;
  const dayMs = 86400000;
  const utcDay = (y, m, d) => Date.UTC(y, m, d);
  const isoOf = (t) => new Date(t).toISOString().slice(0, 10);
  const decodeWord = (x) => x.w || atob(x.k).split("").reverse().join("");
  function todayNumber() {
    const now = new Date(), s = SCHED.startDate.split("-").map(Number);
    return Math.floor((utcDay(now.getFullYear(), now.getMonth(), now.getDate()) - utcDay(s[0], s[1] - 1, s[2])) / dayMs) + 1;
  }
  if (SCHED) {
    if (SCHED.hintUnlockAfter != null) SETTINGS.hint_unlock_after = SCHED.hintUnlockAfter;
    if (SCHED.secondSparkAfter != null) SETTINGS.second_spark_after = SCHED.secondSparkAfter;
  }

  /* ---------------- seed data (mirrors supabase/seed) ---------------- */
  const WORDS = {
    STEEL: { category: "Construction", definition: "The structural material of data centers, fabs and towers. Steel prices, tariffs and lead times move construction cost more than almost anything else.", learn: { type: "story", ref: "a4" } },
    RADIO: { category: "Telecommunications", definition: "Wireless communication over the airwaves. Radio access networks — the towers, antennas and small cells — are the most visible and expensive part of a mobile network.", learn: { type: "explainer", ref: "What is Private 5G?" } },
    POWER: { category: "Energy & Power", definition: "Electricity is now the binding constraint on AI growth. Rack densities past 100 kW and campuses measured in gigawatts mean site selection is an energy question first.", learn: { type: "story", ref: "a1" } },
    FIBER: { category: "Telecommunications", definition: "Fibre-optic cable carries data as pulses of light with enormous capacity and low loss. It is the backbone of telecom networks, data center connectivity and the corridors linking AI campuses.", learn: { type: "glossary", ref: "Dark fiber" } },
    CLOUD: { category: "Digital Infrastructure", definition: "Computing delivered as a service from someone else's data centers. Cloud demand built the hyperscale industry; AI is now building its second wave.", learn: { type: "glossary", ref: "Hyperscaler" } }
  };
  const ISSUES = SCHED ? [] : [
    { id: "i11", number: 11, title: "Concrete & Code", date: "2026-06-04", answer: "STEEL", category: "Construction", status: "archived", hint: "The metal that frames data centers, fabs and towers — beams, columns, rebar — and the first line item tariffs move.",
      explanation: "Steel is the structural backbone of data centers, fabs and towers. Its price, tariff exposure and lead times move construction cost more than almost any other material, which is why cost managers track steel indices as closely as interest rates." },
    { id: "i12", number: 12, title: "Signal & Stream", date: "2026-07-02", answer: "RADIO", category: "Telecommunications", status: "archived", hint: "The airwaves part of every mobile network — towers, antennas and the signal between them. AM, FM and 5G all use it.",
      explanation: "Radio access networks — the towers, antennas and small cells you can see — are the most visible and expensive part of a mobile network. Private 5G brings the same radio technology inside ports, factories and campuses, which is why connectivity is starting to appear in leases the way power does." },
    { id: "i13", number: 13, title: "The Power Issue", date: "2026-08-06", answer: "POWER", category: "Energy & Power", status: "archived", hint: "Measured in megawatts and gigawatts — the one thing every new data center campus is short of. Plants make it, grids move it.",
      explanation: "Electricity has become the binding constraint on AI growth. Racks that drew 5–10 kW are now specified at 100 kW and beyond, campuses are planned in gigawatts, and interconnection queues in major markets stretch past four years — so site selection is an energy question first and a real estate question second." },
    { id: "i14", number: 14, title: "The AI Infrastructure Race", date: "2026-09-03", answer: "FIBER", category: "Telecommunications", status: "active", hint: "Strands of glass that carry data as pulses of light — the cable that connects a data center to the rest of the world.",
      explanation: "Fiber carries enormous volumes of digital information using light and is fundamental to telecom networks, data centers and modern digital infrastructure. Long-haul and metro fiber routes are now being built along the corridors connecting AI data center clusters — connectivity is following compute, and fiber access is becoming a site-selection criterion alongside power." },
    { id: "i15", number: 15, title: "Where Compute Lives", date: "2026-10-01", answer: "CLOUD", category: "Digital Infrastructure", status: "scheduled", hint: "Computing you rent by the hour from someone else's data center — the business that made the hyperscalers giant.",
      explanation: "Cloud computing is capacity delivered as a service from someone else's data centers. Cloud demand built the hyperscale industry over the last decade; AI is now building its second wave." }
  ];
  if (SCHED) {
    const s0 = SCHED.startDate.split("-").map(Number), start = utcDay(s0[0], s0[1] - 1, s0[2]);
    const T = todayNumber(), N = SCHED.words.length;
    SCHED.words.forEach((x) => { const w = decodeWord(x); WORDS[w] = { category: x.c, definition: x.e, learn: null }; });
    const last = Math.max(1, T + 1);
    for (let n = 1; n <= last; n++) {
      if (n > N && SCHED.cycle === false) break;
      const x = SCHED.words[(n - 1) % N], w = decodeWord(x);
      ISSUES.push({ id: "d" + n, number: n, title: "", date: isoOf(start + (n - 1) * dayMs), answer: w, category: x.c, hint: x.h, explanation: x.e,
        status: n < T ? "archived" : (n === T ? "active" : "scheduled") });
    }
  }
  const SUBS = [
    ["s1", "sarah.m@example-nvidia.com", "Sarah", "Mitchell", "NVIDIA", "test-sarah-mitchell-nvidia-00000000000001", "first_last_initial"],
    ["s2", "david.l@example-nvidia.com", "David", "Lin", "NVIDIA", "test-david-lin-nvidia-000000000000000002", "first_last_initial"],
    ["s3", "priya.n@example-nvidia.com", "Priya", "Natarajan", "NVIDIA", "test-priya-natarajan-nvidia-000000000003", "full_name"],
    ["s4", "james.r@example-tt.com", "James", "Reyes", "Turner & Townsend", "test-james-reyes-tt-00000000000000000004", "first_last_initial"],
    ["s5", "alex.c@example-tt.com", "Alex", "Cortessis", "Turner & Townsend", "test-alex-cortessis-tt-000000000000000005", "first_last_initial"],
    ["s6", "mei.t@example-tt.com", "Mei", "Tanaka", "Turner & Townsend", "test-mei-tanaka-tt-000000000000000000006", "anonymous"],
    ["s7", "omar.h@example-tt.com", "Omar", "Haddad", "Turner & Townsend", "test-omar-haddad-tt-00000000000000000007", "first_last_initial"],
    ["s8", "michelle.k@example-google.com", "Michelle", "Kim", "Google", "test-michelle-kim-google-0000000000000008", "first_last_initial"],
    ["s9", "tom.b@example-google.com", "Tom", "Baker", "Google", "test-tom-baker-google-000000000000000009", "first_last_initial"],
    ["s10", "ana.s@example-google.com", "Ana", "Silva", "Google", "test-ana-silva-google-000000000000000010", "first_last_initial"],
    ["s11", "chris.w@example-microsoft.com", "Chris", "Walsh", "Microsoft", "test-chris-walsh-microsoft-00000000000011", "first_last_initial"],
    ["s12", "dana.o@example-microsoft.com", "Dana", "Okafor", "Microsoft", "test-dana-okafor-microsoft-00000000000012", "first_last_initial"],
    ["s13", "luis.f@example-microsoft.com", "Luis", "Fernandez", "Microsoft Corp.", "test-luis-fernandez-microsoft-0000000013", "first_last_initial"],
    ["s14", "grace.p@example-meta.com", "Grace", "Park", "Meta", "test-grace-park-meta-0000000000000000014", "first_last_initial"],
    ["s15", "ben.a@example-meta.com", "Ben", "Adler", "Meta", "test-ben-adler-meta-00000000000000000015", "first_last_initial"],
    ["s16", "nadia.r@example-vantage.com", "Nadia", "Rahman", "Vantage Data Centers", "test-nadia-rahman-vantage-000000000000016", "first_last_initial"],
    ["s17", "new.reader@example.com", "Jordan", "Lee", "Digital Realty", "test-jordan-lee-never-played-00000000017", "first_last_initial"]
  ].map((r) => ({ id: r[0], email: r[1], first_name: r[2], last_name: r[3], company: r[4], company_key: companyKey(r[4]), token: r[5], visibility: r[6], newsletter_subscriber: true, email_verified: false }));
  // [subscriber, issue, guesses, hint, seconds, completed_at]
  const SEED_GAMES = [
    ["s1",11,"crane steel",0,48,"2026-06-04T14:12Z"],["s2",11,"arise tiles steel",0,95,"2026-06-04T15:40Z"],["s4",11,"audio steel",0,61,"2026-06-04T09:05Z"],["s5",11,"crane slate steel",0,120,"2026-06-05T08:30Z"],["s6",11,"raise blend steel",1,210,"2026-06-05T12:00Z"],["s7",11,"crane sleet steel",0,88,"2026-06-06T10:10Z"],["s8",11,"solar metal steel",0,74,"2026-06-04T16:22Z"],["s9",11,"crane build tower racks cable power",0,300,"2026-06-04T18:00Z"],["s10",11,"steel",0,0,"2026-06-04T13:01Z"],["s11",11,"crane spelt steel",0,133,"2026-06-07T11:11Z"],["s12",11,"audio steer steel",0,101,"2026-06-05T17:45Z"],["s14",11,"plant steel",0,57,"2026-06-04T20:20Z"],["s16",11,"arise tease steel",0,140,"2026-06-08T09:00Z"],
    ["s1",12,"crane ratio radio",0,66,"2026-07-02T14:00Z"],["s2",12,"audio radio",0,40,"2026-07-02T15:10Z"],["s3",12,"arise roast radio",0,150,"2026-07-03T10:00Z"],["s4",12,"solar radio",0,52,"2026-07-02T09:00Z"],["s5",12,"crane rapid radio",0,97,"2026-07-02T08:40Z"],["s6",12,"media radio",0,45,"2026-07-02T12:30Z"],["s7",12,"crane solar braid radio",1,260,"2026-07-04T11:00Z"],["s8",12,"tower radio",0,39,"2026-07-02T16:00Z"],["s9",12,"crane ratio radio",0,80,"2026-07-02T18:30Z"],["s10",12,"audio radio",0,44,"2026-07-02T13:15Z"],["s11",12,"crane audit radio",0,110,"2026-07-05T11:00Z"],["s13",12,"arise radar radio",0,125,"2026-07-03T09:30Z"],["s14",12,"crane brand radio",0,71,"2026-07-02T20:00Z"],["s15",12,"solar cloud build tower media fiber",0,330,"2026-07-06T10:00Z"],["s16",12,"crane radio",0,58,"2026-07-02T21:00Z"],
    ["s1",13,"water power",0,37,"2026-08-06T14:05Z"],["s2",13,"crane tower power",0,72,"2026-08-06T15:00Z"],["s3",13,"arise motor power",0,140,"2026-08-07T10:00Z"],["s4",13,"solar power",0,49,"2026-08-06T09:00Z"],["s5",13,"crane rower power",0,90,"2026-08-06T08:45Z"],["s6",13,"crane solar robot tower power",0,280,"2026-08-08T12:00Z"],["s7",13,"lower power",0,41,"2026-08-06T10:30Z"],["s8",13,"audio power",0,35,"2026-08-06T16:10Z"],["s9",13,"crane slate build media fiber cloud",1,420,"2026-08-06T18:00Z"],["s10",13,"crane tower power",0,64,"2026-08-06T13:00Z"],["s11",13,"water power",0,55,"2026-08-09T11:00Z"],["s12",13,"solar power",0,43,"2026-08-06T17:00Z"],["s13",13,"arise mower power",0,118,"2026-08-07T09:00Z"],["s14",13,"crane poker power",0,77,"2026-08-06T20:30Z"],["s15",13,"tower power",0,46,"2026-08-07T10:00Z"],["s16",13,"crane tower power",0,83,"2026-08-06T21:00Z"],
    ["s1",14,"crane fiber",0,44,"2026-09-03T14:02Z"],["s2",14,"audio tiger fiber",0,91,"2026-09-03T15:20Z"],["s4",14,"arise fiber",0,50,"2026-09-03T09:02Z"],["s5",14,"crane brief fiber",0,96,"2026-09-03T08:50Z"],["s8",14,"cable fiber",0,38,"2026-09-03T16:05Z"],["s9",14,"crane solar fiery fiber",1,240,"2026-09-03T18:10Z"],["s11",14,"crane liber fiber",0,130,"2026-09-04T11:00Z"],["s14",14,"brief fiber",0,47,"2026-09-03T20:15Z"],["s16",14,"crane tower cable fiber",0,160,"2026-09-04T09:00Z"]
  ];
  const GAMES = [], GUESSES = [], EVENTS = [];
  let authEmail = null; // set by simulateVerifiedSession()

  /* ---------------- helpers ported from SQL ---------------- */
  function companyKey(p) {
    if (!p) return null;
    let s = String(p).toLowerCase().replace(/[^a-z0-9& ]+/g, " ");
    s = s.replace(/\s+(inc|inc\.|llc|ltd|limited|plc|corp|corporation|co|company|group|holdings|gmbh|sa|ag)(\s|$)/g, " ").replace(/\s+/g, " ").trim();
    return s || null;
  }
  function evaluate(guess, answer) {
    const g = guess.toUpperCase(), a = answer.toUpperCase();
    const res = ["a", "a", "a", "a", "a"]; let remaining = "";
    for (let i = 0; i < 5; i++) { if (g[i] === a[i]) res[i] = "c"; else remaining += a[i]; }
    for (let i = 0; i < 5; i++) {
      if (res[i] === "c") continue;
      const pos = remaining.indexOf(g[i]);
      if (pos >= 0) { res[i] = "p"; remaining = remaining.slice(0, pos) + remaining.slice(pos + 1); }
    }
    return res.join("");
  }
  function score(solved, n, hint, streak) {
    if (!solved) return 0;
    let base = { 1: 100, 2: 80, 3: 65, 4: 50, 5: 35 }[n] || 20;
    if (hint) base -= 5;
    return Math.max(0, base) + Math.min(streak || 0, SETTINGS.streak_bonus_cap) * 2;
  }
  const published = () => ISSUES.filter((i) => i.status === "active" || i.status === "archived").sort((a, b) => a.number - b.number);
  const issueByNumber = (n) => ISSUES.find((i) => i.number === n);
  const officialDone = (subId, issueId) => GAMES.some((g) => g.subscriber_id === subId && g.issue_id === issueId && g.mode === "official" && g.status !== "in_progress");
  function streakEndingAt(subId, n) {
    let k = 0;
    for (const i of published().filter((i) => i.number <= n).reverse()) { if (!officialDone(subId, i.id)) break; k++; }
    return k;
  }
  function currentStreak(subId) {
    const pub = published(); const latest = pub[pub.length - 1]; if (!latest) return 0;
    if (officialDone(subId, latest.id)) return streakEndingAt(subId, latest.number);
    if (latest.status === "active") { const prev = pub.filter((i) => i.number < latest.number).pop(); return prev ? streakEndingAt(subId, prev.number) : 0; }
    return 0;
  }
  function bestStreak(subId) { let run = 0, best = 0; for (const i of published()) { if (officialDone(subId, i.id)) { run++; best = Math.max(best, run); } else run = 0; } return best; }
  const subById = (id) => SUBS.find((s) => s.id === id);
  const subByToken = (t) => (t ? SUBS.find((s) => s.token === t) : null) || null;
  const isTT = (s) => ["turner & townsend", "turner townsend", "turner and townsend", "t&t"].includes(s.company_key) || /@turntown\.com$/i.test(s.email);
  function displayName(s) {
    if (s.visibility === "anonymous") return "Anonymous";
    if (s.visibility === "full_name") return s.display_name || (s.first_name + " " + (s.last_name || "")).trim() || "Spark Player";
    return (s.first_name + (s.last_name ? " " + s.last_name[0] + "." : "")).trim() || s.display_name || "Spark Player";
  }
  function stats(s) {
    const gs = GAMES.filter((g) => g.subscriber_id === s.id && g.mode === "official" && !g.flagged && g.status !== "in_progress");
    const won = gs.filter((g) => g.solved);
    return {
      games_played: gs.length, games_won: won.length,
      win_pct: gs.length ? Math.round(100 * won.length / gs.length) : null,
      average_guesses: won.length ? +(won.reduce((a, g) => a + g.guess_count, 0) / won.length).toFixed(2) : null,
      current_streak: currentStreak(s.id), best_streak: bestStreak(s.id),
      total_points: gs.reduce((a, g) => a + (g.score || 0), 0)
    };
  }
  const playerJson = (s) => ({ recognized: true, id: s.id, first_name: s.first_name, name: displayName(s), company: s.company, newsletter_subscriber: s.newsletter_subscriber, visibility: s.visibility, is_tt: isTT(s), stats: stats(s) });
  const completedOfficial = (issueId) => GAMES.filter((g) => g.issue_id === issueId && g.mode === "official" && g.status !== "in_progress");
  const issuePublic = (i) => ({ id: i.id, number: i.number, slug: "issue-" + pad3(i.number), title: i.title, date: i.date, category: i.category, status: i.status, is_active: i.status === "active",
    players_completed: completedOfficial(i.id).length, players_started: GAMES.filter((g) => g.issue_id === i.id && g.mode === "official").length });
  const rankOrder = (a, b) => (b.solved - a.solved) || (a.guess_count - b.guess_count) || (a.hint_used - b.hint_used) || (a.completion_seconds - b.completion_seconds) || (a.completed_at < b.completed_at ? -1 : a.completed_at > b.completed_at ? 1 : 0);
  function gameRank(g) {
    const pool = completedOfficial(g.issue_id).filter((x) => !x.flagged);
    const total = pool.length, solved_total = pool.filter((x) => x.solved).length;
    if (g.mode !== "official" || g.status === "in_progress" || g.flagged || !g.solved) return { rank: null, total, solved_total, percentile: null };
    const sorted = pool.slice().sort(rankOrder);
    let rank = sorted.findIndex((x) => x.id === g.id) + 1;
    while (rank > 1 && rankOrder(sorted[rank - 2], sorted[rank - 1]) === 0) rank--; // ties share rank
    return { rank, total, solved_total, percentile: Math.max(1, Math.ceil(100 * rank / Math.max(total, 1))) };
  }
  function badges(solved, n, streak, rank, total) {
    const b = [];
    if (solved && n === 1) b.push("LIGHTNING STRIKE"); if (solved && n === 2) b.push("HIGH VOLTAGE"); if (solved && n === 3) b.push("FULLY CHARGED");
    if ((streak || 0) >= 5) b.push("ON A ROLL"); if (rank && rank <= 10 && (total || 0) >= 20) b.push("TOP OF THE GRID");
    return b;
  }
  function completionJson(g) {
    if (g.status === "in_progress") return null;
    const i = ISSUES.find((x) => x.id === g.issue_id), w = WORDS[i.answer] || {}, s = g.subscriber_id ? subById(g.subscriber_id) : null;
    const rk = gameRank(g), st = s ? stats(s) : null;
    const nxt = ISSUES.filter((x) => x.number > i.number && x.status !== "archived").sort((a, b) => a.number - b.number)[0];
    return {
      answer: i.answer, category: i.category, explanation: i.explanation, definition: w.definition, learn: w.learn || null,
      solved: g.solved, guess_count: g.guess_count, hint_used: g.hint_used, completion_seconds: g.completion_seconds, score: g.score, mode: g.mode, flagged: g.flagged,
      rank: rk, badges: badges(g.solved, g.guess_count, g.streak_at_completion || (st && st.current_streak), rk.rank, rk.total),
      streak: { current: st ? st.current_streak : 0, best: st ? st.best_streak : 0 },
      player: s ? playerJson(s) : null, players_completed: completedOfficial(i.id).length,
      next_issue: nxt ? { number: nxt.number, date: nxt.date } : null, newsletter_subscriber: !!(s && s.newsletter_subscriber)
    };
  }
  function gameJson(g) {
    const i = ISSUES.find((x) => x.id === g.issue_id);
    return { id: g.id, issue_number: i.number, mode: g.mode, status: g.status, guess_count: g.guess_count,
      rows: GUESSES.filter((q) => q.game_id === g.id).sort((a, b) => a.n - b.n).map((q) => ({ word: q.word, result: q.result })),
      hint_available: g.status === "in_progress" && g.guess_count >= SETTINGS.hint_unlock_after && !!i.hint, hint_used: g.hint_used, hint: g.hint_used ? i.hint : null,
      hint_unlock_after: SETTINGS.hint_unlock_after, second_spark_after: SETTINGS.second_spark_after,
      second_spark_available: g.status === "in_progress" && g.hint_used && SETTINGS.second_spark_after > 0 && g.guess_count >= SETTINGS.second_spark_after,
      first_letter: g.hint_used && SETTINGS.second_spark_after > 0 && g.guess_count >= SETTINGS.second_spark_after ? i.answer[0] : null,
      started_at: g.started_at, result: completionJson(g) };
  }
  function newGameMode(i, subId, guestId) {
    if (i.status === "draft" || i.status === "scheduled") return "closed";
    if (i.status === "archived") return "archive";
    if (subId && GAMES.some((g) => g.subscriber_id === subId && g.issue_id === i.id && g.mode === "official")) return "archive";
    if (!subId && guestId && GAMES.some((g) => !g.subscriber_id && g.guest_id === guestId && g.issue_id === i.id && g.mode === "official")) return "archive";
    return "official";
  }
  function findGame(issueId, subId, guestId, gameId) {
    const mine = (g) => g.issue_id === issueId && (subId ? g.subscriber_id === subId : (!g.subscriber_id && g.guest_id === guestId));
    if (gameId) { const g = GAMES.find((g) => g.id === gameId && mine(g)); if (g) return g; }
    return GAMES.filter(mine).sort((a, b) => ((b.status === "in_progress") - (a.status === "in_progress")) || ((b.mode === "official") - (a.mode === "official")) || (b.created < a.created ? -1 : 1))[0] || null;
  }
  function attachGuestGames(subId, guestId) {
    GAMES.filter((g) => g.guest_id === guestId && !g.subscriber_id).forEach((g) => {
      if (g.mode === "official" && GAMES.some((x) => x.subscriber_id === subId && x.issue_id === g.issue_id && x.mode === "official")) { g.mode = "archive"; g.score = 0; g.streak_at_completion = null; }
      g.subscriber_id = subId;
    });
    GAMES.filter((g) => g.subscriber_id === subId && g.guest_id === guestId && g.mode === "official" && g.status !== "in_progress")
      .sort((a, b) => ISSUES.find((i) => i.id === a.issue_id).number - ISSUES.find((i) => i.id === b.issue_id).number)
      .forEach((g) => { const n = ISSUES.find((i) => i.id === g.issue_id).number; g.streak_at_completion = streakEndingAt(subId, n); g.score = score(g.solved, g.guess_count, g.hint_used, g.streak_at_completion); });
  }

  /* ---------------- dictionary (lazy) ---------------- */
  let DICT = null, dictReady = null;
  function loadDict() {
    if (dictReady) return dictReady;
    dictReady = new Promise((resolve) => {
      const finish = () => { DICT = new Set((window.SPARK_WORD_DICTIONARY || "").split(" ")); Object.keys(WORDS).forEach((w) => DICT.add(w.toLowerCase())); resolve(); };
      if (window.SPARK_WORD_DICTIONARY) return finish();
      const sc = document.createElement("script");
      const cfg = window.SPARK_WORD_CONFIG || {};
      sc.src = (cfg.assetsPath || "assets/") + "spark-word-dictionary.js"; sc.onload = finish; sc.onerror = finish;
      document.head.appendChild(sc);
    });
    return dictReady;
  }

  /* ---------------- seed the in-memory games ---------------- */
  function seedDaily() {
    // deterministic sample players per day (mulberry32 seeded by day number)
    const rng = (seed) => () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
    const pool = SUBS.filter((s) => s.id !== "s17");
    published().forEach((i) => {
      const r = rng(i.number * 7919 + 13);
      const players = pool.filter(() => r() < 0.72);
      players.forEach((s) => {
        const u = r();
        const guesses = u < 0.05 ? 1 : u < 0.22 ? 2 : u < 0.55 ? 3 : u < 0.82 ? 4 : u < 0.93 ? 5 : 6;
        const solved = guesses < 6 || r() < 0.5;
        const hint = guesses >= 3 && r() < 0.3;
        const secs = Math.round(25 + guesses * (30 + r() * 45));
        const hour = 7 + Math.floor(r() * 13), min = Math.floor(r() * 60);
        const at = i.date + "T" + String(hour).padStart(2, "0") + ":" + String(min).padStart(2, "0") + ":00Z";
        GAMES.push({ id: "seed-" + i.number + "-" + s.id, issue_id: i.id, subscriber_id: s.id, guest_id: null, mode: "official", status: solved ? "won" : "lost", started_at: at, guess_count: guesses, hint_used: hint, solved, completion_seconds: secs, completed_at: at, flagged: false, created: at, ref: "seed" });
      });
    });
  }
  if (SCHED) seedDaily();
  else SEED_GAMES.forEach((r) => {
    const s = subById(r[0]), i = issueByNumber(r[1]), words = r[2].split(" ");
    const g = { id: uuid(), issue_id: i.id, subscriber_id: s.id, guest_id: null, mode: "official", status: "in_progress", started_at: r[5], guess_count: 0, hint_used: !!r[3], solved: false, completion_seconds: r[4], completed_at: r[5], flagged: false, created: r[5], ref: "seed" };
    words.forEach((w, k) => { const res = evaluate(w, i.answer); GUESSES.push({ game_id: g.id, n: k + 1, word: w.toUpperCase(), result: res }); if (res === "ccccc") g.solved = true; });
    g.guess_count = words.length; g.status = g.solved ? "won" : "lost"; GAMES.push(g);
  });
  GAMES.slice().sort((a, b) => ISSUES.find((i) => i.id === a.issue_id).number - ISSUES.find((i) => i.id === b.issue_id).number).forEach((g) => {
    const n = ISSUES.find((i) => i.id === g.issue_id).number; g.streak_at_completion = streakEndingAt(g.subscriber_id, n); g.score = score(g.solved, g.guess_count, g.hint_used, g.streak_at_completion);
  });
  if (!SCHED) EVENTS.push({ event_name: "spark_word_shared", issue_id: "i13" }, { event_name: "spark_word_shared", issue_id: "i14" });

  /* ---------------- this device's own games (daily edition) ---------------- */
  const STORE_KEY = "sw_daily_v1";
  function persist() {
    if (!SCHED) return;
    try {
      const games = GAMES.filter((g) => g.local), ids = new Set(games.map((g) => g.id));
      localStorage.setItem(STORE_KEY, JSON.stringify({ subs: SUBS.filter((x) => x.local), games, guesses: GUESSES.filter((q) => ids.has(q.game_id)) }));
    } catch (e) {}
  }
  if (SCHED) {
    try {
      const saved = JSON.parse(localStorage.getItem(STORE_KEY) || "null");
      if (saved) {
        (saved.subs || []).forEach((x) => { if (!SUBS.some((s) => s.id === x.id)) SUBS.push(x); });
        (saved.games || []).forEach((g) => { if (ISSUES.some((i) => i.id === g.issue_id) && !GAMES.some((x) => x.id === g.id)) GAMES.push(g); });
        (saved.guesses || []).forEach((q) => { if (GAMES.some((g) => g.id === q.game_id)) GUESSES.push(q); });
      }
    } catch (e) {}
  }

  /* ---------------- RPC implementations ---------------- */
  const periodIssues = (p) => {
    const pub = published();
    if (p === "issue") { const act = pub.find((i) => i.status === "active") || pub[pub.length - 1]; return act ? [act.id] : []; }
    if (p === "month") { const now = new Date(); return pub.filter((i) => { const d = new Date(i.date + "T12:00:00"); return d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth(); }).map((i) => i.id); }
    return pub.map((i) => i.id);
  };
  const RPC = {
    sw_bootstrap(p) {
      const s = subByToken(p.p_token);
      const act = ISSUES.find((i) => i.status === "active"), pub = published();
      const i = p.p_issue_number ? issueByNumber(p.p_issue_number) : (act || pub[pub.length - 1]);
      const base = { active_issue_number: act ? act.number : null, latest_issue_number: pub.length ? pub[pub.length - 1].number : null, player: s ? playerJson(s) : null };
      if (!i) return Object.assign({ ok: false, error: "no_issue" }, base);
      if (i.status === "draft" || i.status === "scheduled") return Object.assign({ ok: false, error: "issue_not_published" }, base);
      const g = findGame(i.id, s && s.id, s ? null : p.p_guest_id, null);
      return Object.assign({ ok: true, now: new Date().toISOString(), issue: issuePublic(i), game: g ? gameJson(g) : null,
        new_game_mode: newGameMode(i, s && s.id, s ? null : p.p_guest_id), settings: { hint_unlock_after: SETTINGS.hint_unlock_after, second_spark_after: SETTINGS.second_spark_after, require_verification_new: SETTINGS.require_verification_new } }, base);
    },
    async sw_submit_guess(p) {
      await loadDict();
      const s = subByToken(p.p_token), i = issueByNumber(p.p_issue_number);
      if (!i) return { ok: false, error: "no_issue" };
      const guess = String(p.p_guess || "").replace(/[^A-Za-z]/g, "").toUpperCase();
      if (guess.length !== 5) return { ok: false, error: "invalid_length" };
      if (!DICT.has(guess.toLowerCase())) return { ok: false, error: "not_in_dictionary" };
      let g = findGame(i.id, s && s.id, s ? null : p.p_guest_id, p.p_game_id);
      if (g && g.status !== "in_progress") g = null;
      const now = new Date();
      if (!g) {
        if (!s && !p.p_guest_id) return { ok: false, error: "no_identity" };
        const mode = newGameMode(i, s && s.id, s ? null : p.p_guest_id);
        if (mode === "closed") return { ok: false, error: "issue_not_published" };
        g = { id: uuid(), issue_id: i.id, subscriber_id: s ? s.id : null, guest_id: s ? null : p.p_guest_id, mode, status: "in_progress", started_at: now.toISOString(), startedMs: now.getTime(), guess_count: 0, hint_used: false, solved: false, flagged: false, created: now.toISOString(), ref: p.p_ref, local: true };
        GAMES.push(g);
      }
      const n = g.guess_count + 1, result = evaluate(guess, i.answer);
      GUESSES.push({ game_id: g.id, n, word: guess, result });
      g.guess_count = n;
      if (result === "ccccc" || n >= 6) {
        g.solved = result === "ccccc"; g.status = g.solved ? "won" : "lost"; g.completed_at = now.toISOString();
        g.completion_seconds = Math.max(0, Math.floor((now.getTime() - (g.startedMs || now.getTime())) / 1000));
        if (n >= 2 && (now.getTime() - g.startedMs) / 1000 < SETTINGS.min_seconds_per_guess * (n - 1)) { g.flagged = true; }
        let streak = 0;
        if (g.mode === "official") streak = s ? streakEndingAt(s.id, i.number - 1) + 1 : 1;
        g.streak_at_completion = g.mode === "official" ? streak : null;
        g.score = g.mode === "official" ? score(g.solved, n, g.hint_used, streak) : 0;
      }
      persist();
      return { ok: true, game_id: g.id, mode: g.mode, guess_number: n, word: guess, result, status: g.status,
        hint_available: g.status === "in_progress" && g.guess_count >= SETTINGS.hint_unlock_after && !!i.hint, hint_used: g.hint_used,
        second_spark_available: g.status === "in_progress" && g.hint_used && SETTINGS.second_spark_after > 0 && g.guess_count >= SETTINGS.second_spark_after,
        first_letter: g.status === "in_progress" && g.hint_used && SETTINGS.second_spark_after > 0 && g.guess_count >= SETTINGS.second_spark_after ? i.answer[0] : null,
        completion: g.status !== "in_progress" ? completionJson(g) : null };
    },
    sw_use_hint(p) {
      const s = subByToken(p.p_token);
      const g = GAMES.find((g) => g.id === p.p_game_id && (s ? g.subscriber_id === s.id : (!g.subscriber_id && g.guest_id === p.p_guest_id)));
      if (!g) return { ok: false, error: "not_found" };
      const i = ISSUES.find((x) => x.id === g.issue_id);
      if (g.status !== "in_progress") return { ok: false, error: "game_over" };
      if (!i.hint) return { ok: false, error: "no_hint" };
      if (g.guess_count < SETTINGS.hint_unlock_after) return { ok: false, error: "locked", unlock_after: SETTINGS.hint_unlock_after };
      g.hint_used = true; persist();
      const second = SETTINGS.second_spark_after > 0 && g.guess_count >= SETTINGS.second_spark_after;
      return { ok: true, hint: i.hint, second_spark_available: second, first_letter: second ? i.answer[0] : null };
    },
    sw_claim_profile(p) {
      const email = String(p.p_email || "").trim().toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { ok: false, error: "invalid_email" };
      if (!String(p.p_first_name || "").trim()) return { ok: false, error: "first_name_required" };
      if (!String(p.p_company || "").trim()) return { ok: false, error: "company_required" };
      if (!p.p_guest_id) return { ok: false, error: "no_identity" };
      const existing = SUBS.find((s) => s.email === email);
      if (existing || SETTINGS.require_verification_new === "true") return { ok: true, status: "verify_required", email };
      const s = { id: uuid(), email, first_name: p.p_first_name.trim(), last_name: (p.p_last_name || "").trim() || null, company: p.p_company.trim(), company_key: companyKey(p.p_company), token: "preview-" + uuid(), visibility: p.p_visibility || "first_last_initial", newsletter_subscriber: false, email_verified: false, local: true };
      SUBS.push(s); attachGuestGames(s.id, p.p_guest_id); persist();
      const g = p.p_game_id ? GAMES.find((g) => g.id === p.p_game_id && g.subscriber_id === s.id) : null;
      return { ok: true, status: "created", token: s.token, player: playerJson(s), game: g ? gameJson(g) : null };
    },
    sw_verified_link(p) {
      if (!authEmail) return { ok: false, error: "not_authenticated" };
      let s = SUBS.find((x) => x.email === authEmail);
      if (!s) { s = { id: uuid(), email: authEmail, first_name: p.p_first_name, last_name: p.p_last_name, company: p.p_company, company_key: companyKey(p.p_company), token: "preview-" + uuid(), visibility: p.p_visibility || "first_last_initial", newsletter_subscriber: false, email_verified: true }; SUBS.push(s); }
      else { s.email_verified = true; s.first_name = s.first_name || p.p_first_name; s.last_name = s.last_name || p.p_last_name; s.company = s.company || p.p_company; if (p.p_visibility) s.visibility = p.p_visibility; }
      if (p.p_guest_id) attachGuestGames(s.id, p.p_guest_id);
      const g = p.p_game_id ? GAMES.find((g) => g.id === p.p_game_id && g.subscriber_id === s.id) : null;
      return { ok: true, status: "linked", token: s.token, player: playerJson(s), game: g ? gameJson(g) : null };
    },
    sw_update_profile(p) {
      const s = subByToken(p.p_token); if (!s) return { ok: false, error: "not_recognized" };
      if (p.p_visibility) s.visibility = p.p_visibility; if (p.p_display_name != null) s.display_name = p.p_display_name.trim().slice(0, 40) || null;
      persist();
      return { ok: true, player: playerJson(s) };
    },
    sw_track(p) { const i = issueByNumber(p.p_issue_number); EVENTS.push({ event_name: p.p_event, issue_id: i ? i.id : null, props: p.p_props || {} }); return { ok: true }; },
    sw_archive(p) {
      const s = subByToken(p.p_token);
      return { ok: true, issues: published().slice().reverse().slice(0, SCHED ? 30 : 1000).map((i) => {
        const g = findGame(i.id, s && s.id, s ? null : p.p_guest_id, null), done = completedOfficial(i.id);
        const w = WORDS[i.answer] || {};
        return { number: i.number, title: i.title, date: i.date, category: i.category, status: i.status, is_active: i.status === "active",
          players_completed: done.length, solved_pct: done.length ? Math.round(100 * done.filter((x) => x.solved).length / done.length) : null,
          my: g ? { mode: g.mode, status: g.status, solved: g.solved, guess_count: g.guess_count, hint_used: g.hint_used, answer: g.status !== "in_progress" ? i.answer : null,
                    definition: g.status !== "in_progress" ? w.definition : null, explanation: g.status !== "in_progress" ? i.explanation : null,
                    rank: g.mode === "official" && g.solved ? gameRank(g).rank : null } : null,
          new_game_mode: newGameMode(i, s && s.id, s ? null : p.p_guest_id) };
      }) };
    },
    sw_issue_leaderboard(p) {
      const s = subByToken(p.p_token);
      const i = p.p_issue_number ? issueByNumber(p.p_issue_number) : (ISSUES.find((x) => x.status === "active") || published().pop());
      if (!i || !(i.status === "active" || i.status === "archived")) return { ok: false, error: "no_issue" };
      const pool = completedOfficial(i.id).filter((g) => !g.flagged), solved = pool.filter((g) => g.solved).sort(rankOrder);
      const top = solved.slice(0, p.p_limit || 10).map((g) => { const sub = g.subscriber_id ? subById(g.subscriber_id) : null; return { rank: gameRank(g).rank, name: sub ? displayName(sub) : "Guest", company: sub ? sub.company : "Guest", is_me: !!(s && sub && sub.id === s.id), solved: true, guesses: g.guess_count, hint_used: g.hint_used, seconds: g.completion_seconds, streak: g.streak_at_completion || 0, points: g.score }; });
      const mine = findGame(i.id, s && s.id, s ? null : p.p_guest_id, null);
      const me = mine && mine.mode === "official" && mine.status !== "in_progress" ? Object.assign(gameRank(mine), { solved: mine.solved, guesses: mine.guess_count, hint_used: mine.hint_used, seconds: mine.completion_seconds, points: mine.score, flagged: mine.flagged }) : null;
      return { ok: true, issue: issuePublic(i), total_players: pool.length, solved_players: solved.length, solved_pct: pool.length ? Math.round(100 * solved.length / pool.length) : null, top, me };
    },
    sw_allstars(p) {
      const s = subByToken(p.p_token), ids = periodIssues(p.p_period || "all"), key = companyKey(p.p_company);
      const by = {};
      GAMES.filter((g) => g.mode === "official" && g.status !== "in_progress" && !g.flagged && g.subscriber_id && ids.includes(g.issue_id)).forEach((g) => {
        const sub = subById(g.subscriber_id); if (!sub) return;
        const scope = p.p_scope || "all";
        if (scope === "tt" && !isTT(sub)) return; if (scope === "industry" && isTT(sub)) return; if (scope === "company" && sub.company_key !== key) return;
        const a = by[sub.id] = by[sub.id] || { sub, n: 0, wins: 0, gsum: 0, points: 0, last: "" };
        a.n++; if (g.solved) { a.wins++; a.gsum += g.guess_count; } a.points += g.score || 0; a.last = g.completed_at > a.last ? g.completed_at : a.last;
      });
      const rows = Object.values(by).map((a) => ({ id: a.sub.id, name: displayName(a.sub), company: a.sub.company, is_me: !!(s && s.id === a.sub.id), is_tt: isTT(a.sub), issues_played: a.n, wins: a.wins, win_pct: Math.round(100 * a.wins / a.n), avg_guesses: a.wins ? +(a.gsum / a.wins).toFixed(2) : null, current_streak: currentStreak(a.sub.id), points: a.points, last: a.last }))
        .sort((x, y) => (y.points - x.points) || (y.wins - x.wins) || ((x.avg_guesses || 99) - (y.avg_guesses || 99)) || (x.last < y.last ? -1 : 1));
      rows.forEach((r, i) => { r.rank = i > 0 && rows[i - 1].points === r.points && rows[i - 1].wins === r.wins && rows[i - 1].avg_guesses === r.avg_guesses ? rows[i - 1].rank : i + 1; });
      const me = s ? rows.find((r) => r.id === s.id) : null;
      return { ok: true, period: p.p_period, scope: p.p_scope, company: p.p_company, rows: rows.slice(0, p.p_limit || 25), me: me ? { rank: me.rank, total: rows.length, points: me.points, issues_played: me.issues_played, win_pct: me.win_pct, avg_guesses: me.avg_guesses, current_streak: me.current_streak } : null };
    },
    sw_company_standings(p) {
      const ids = periodIssues(p.p_period || "all"), per = {};
      GAMES.filter((g) => g.mode === "official" && g.status !== "in_progress" && !g.flagged && g.subscriber_id && ids.includes(g.issue_id)).forEach((g) => {
        const sub = subById(g.subscriber_id); if (!sub || !sub.company_key) return;
        const c = per[sub.company_key] = per[sub.company_key] || { company: sub.company, players: {} };
        const pl = c.players[sub.id] = c.players[sub.id] || { n: 0, wins: 0, gsum: 0, pts: 0 };
        pl.n++; if (g.solved) { pl.wins++; pl.gsum += g.guess_count; } pl.pts += g.score || 0;
      });
      const rows = Object.values(per).map((c) => { const ps = Object.values(c.players); const n = ps.length; if (n < SETTINGS.company_min_players) return null;
        const avg = ps.reduce((a, x) => a + x.pts / x.n, 0) / n, games = ps.reduce((a, x) => a + x.n, 0), wins = ps.reduce((a, x) => a + x.wins, 0), gs = ps.filter((x) => x.wins).map((x) => x.gsum / x.wins);
        return { company: c.company, players: n, avg_points: +avg.toFixed(1), win_pct: Math.round(100 * wins / games), avg_guesses: gs.length ? +(gs.reduce((a, b) => a + b, 0) / gs.length).toFixed(2) : null, games }; })
        .filter(Boolean).sort((a, b) => (b.avg_points - a.avg_points) || (b.win_pct - a.win_pct) || (b.players - a.players));
      rows.forEach((r, i) => { r.rank = i + 1; });
      return { ok: true, period: p.p_period, min_players: SETTINGS.company_min_players, rows: rows.slice(0, p.p_limit || 10),
        methodology: "Each player's points are averaged per " + NOUN + " played in the period; a company's score is the mean of its players' averages. Companies need at least " + SETTINGS.company_min_players + " players with a completed official game to appear, so large organisations cannot win on headcount alone." };
    },
    sw_last_issue_summary(p) {
      const s = subByToken(p.p_token);
      const i = p.p_issue_number ? issueByNumber(p.p_issue_number) : published().filter((x) => x.status === "archived").pop();
      if (!i) return { ok: false, error: "no_issue" };
      const g = findGame(i.id, s && s.id, s ? null : p.p_guest_id, null), revealed = !!(g && g.status !== "in_progress");
      const pool = completedOfficial(i.id).filter((x) => !x.flagged), solved = pool.filter((x) => x.solved).sort(rankOrder);
      const top = solved.slice(0, 3).map((x, k) => { const sub = subById(x.subscriber_id); return { rank: k + 1, name: sub ? displayName(sub) : "Guest", company: sub ? sub.company : "", guesses: x.guess_count }; });
      const per = {}; pool.forEach((x) => { const sub = subById(x.subscriber_id); if (!sub || !sub.company_key) return; const c = per[sub.company_key] = per[sub.company_key] || { company: sub.company, pts: [] }; c.pts.push(x.score || 0); });
      const champ = Object.values(per).filter((c) => c.pts.length >= SETTINGS.company_min_players).map((c) => ({ company: c.company, avg: c.pts.reduce((a, b) => a + b, 0) / c.pts.length })).sort((a, b) => b.avg - a.avg)[0];
      return { ok: true, issue: issuePublic(i), revealed, answer: revealed ? i.answer : null, answer_masked: i.answer[0] + "····", players: pool.length, solved_pct: pool.length ? Math.round(100 * solved.length / pool.length) : null, top, company_champion: champ ? champ.company : null };
    },
    sw_my_stats(p) {
      const s = subByToken(p.p_token); if (!s) return { ok: false, error: "not_recognized" };
      const gs = GAMES.filter((g) => g.subscriber_id === s.id && g.mode === "official" && g.status !== "in_progress");
      return { ok: true, player: playerJson(s), distribution: {}, history: gs.map((g) => { const i = ISSUES.find((x) => x.id === g.issue_id); return { issue: i.number, date: i.date, solved: g.solved, guesses: g.guess_count, points: g.score, rank: gameRank(g).rank }; }).sort((a, b) => b.issue - a.issue) };
    }
  };

  window.SparkWordPreview = {
    label: SCHED ? "DAILY EDITION — no backend, this device only" : "DESIGN PREVIEW — not connected to Supabase",
    async rpc(name, params) {
      await new Promise((r) => setTimeout(r, 120)); // a hint of network latency
      if (!RPC[name]) throw new Error("preview: unknown rpc " + name);
      return clone(await RPC[name](params || {}));
    },
    simulateVerifiedSession(email) { authEmail = String(email || "").toLowerCase(); },
    evaluate, score, _data: { ISSUES, SUBS, GAMES, GUESSES, EVENTS }
  };
})();
