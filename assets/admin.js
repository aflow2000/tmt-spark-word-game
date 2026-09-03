/* ============================================================
   SPARK WORD — admin dashboard (admin.html)
   ------------------------------------------------------------
   • Supabase Auth sign-in (password or magic link); the account must be
     listed in the `admins` table (checked by sw_is_admin()).
   • Talks to Postgres directly (RLS lets admins read/write tables) and
     to the admin_* RPC functions for analytics, links and imports.
   • With no Supabase credentials in spark-word-config.js it runs a
     clearly-labelled DESIGN PREVIEW on the seed data (nothing is saved).
   ============================================================ */
(function () {
  "use strict";
  const CFG = window.SPARK_WORD_CONFIG || {};
  const GAME_PAGE = CFG.gamePage || "index.html";   // the page the game lives on (spark-word.html for the single-file build)
  const $ = (s, c) => (c || document).querySelector(s);
  const $$ = (s, c) => Array.prototype.slice.call((c || document).querySelectorAll(s));
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  const pad3 = (n) => String(n).padStart(3, "0");
  const fmtDate = (d) => { try { return new Date(d + "T12:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }); } catch (e) { return d; } };
  const CATEGORIES = ["AI & Compute", "Data Centers", "Semiconductors", "Telecommunications", "Media", "Energy & Power", "Construction", "Real Estate", "Cost Management", "Project Management", "Engineering", "Digital Infrastructure"];
  let toastTimer = null;
  function toast(msg, isErr) { const t = $("#toast"); $("#toastTxt").textContent = msg; t.className = isErr ? "on err" : "on"; clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.className = ""; }, 4200); }
  const openVeil = (id) => { $("#" + id).classList.add("on"); document.body.style.overflow = "hidden"; };
  const closeVeil = (id) => { $("#" + id).classList.remove("on"); document.body.style.overflow = ""; };
  const loadScript = (src) => new Promise((res, rej) => { const s = document.createElement("script"); s.src = src; s.onload = res; s.onerror = rej; document.head.appendChild(s); });

  /* ============================================================
     DATA LAYER — Supabase (production)
     ============================================================ */
  function supabaseAPI() {
    const client = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, { auth: { persistSession: true, detectSessionInUrl: true, flowType: "pkce" } });
    const q = async (p) => { const { data, error } = await p; if (error) throw new Error(error.message); return data; };
    const rpc = (name, params) => q(client.rpc(name, params || {}));
    return {
      mode: "supabase",
      async session() { const { data } = await client.auth.getSession(); return data.session ? { email: data.session.user.email, id: data.session.user.id } : null; },
      async signIn(email, password) { return q(client.auth.signInWithPassword({ email, password })); },
      async magicLink(email) { return q(client.auth.signInWithOtp({ email, options: { emailRedirectTo: location.href.split("#")[0], shouldCreateUser: false } })); },
      async signOut() { await client.auth.signOut(); },
      isAdmin: () => rpc("sw_is_admin"),
      overview: () => rpc("admin_overview"),
      issues: () => q(client.from("issues").select("*").order("issue_number", { ascending: false })),
      async saveIssue(o) {
        const row = { issue_number: o.issue_number, title: o.title, publication_date: o.publication_date, answer: o.answer, category: o.category, hint: o.hint || null, explanation: o.explanation, status: o.status, allow_reuse: !!o.allow_reuse, newsletter_recipients: o.newsletter_recipients || null };
        if (o.id) return q(client.from("issues").update(row).eq("id", o.id).select().single());
        return q(client.from("issues").insert(row).select().single());
      },
      deleteIssue: (id) => q(client.from("issues").delete().eq("id", id)),
      setIssueStatus: (id, status) => rpc("admin_set_issue_status", { p_issue_id: id, p_status: status }),
      words: (qq, cat, avail) => rpc("admin_word_bank_search", { p_q: qq || null, p_category: cat || null, p_only_available: !!avail }),
      async saveWord(o) {
        const row = { word: o.word, category: o.category, definition: o.definition, hint: o.hint || null, related_type: o.related_type || null, related_ref: o.related_ref || null, active: o.active !== false };
        if (o.id) return q(client.from("word_bank").update(row).eq("id", o.id).select().single());
        return q(client.from("word_bank").insert(row).select().single());
      },
      deleteWord: (id) => q(client.from("word_bank").delete().eq("id", id)),
      subscribers: async (qq) => { let b = client.from("subscribers").select("id,email,first_name,last_name,company,newsletter_subscriber,source,games_played,games_won,current_streak,best_streak,total_points,email_verified,created_at").order("created_at", { ascending: false }).limit(500); if (qq) b = b.or(`email.ilike.%${qq}%,first_name.ilike.%${qq}%,last_name.ilike.%${qq}%,company.ilike.%${qq}%`); return q(b); },
      links: (n, newsOnly) => rpc("admin_issue_links", { p_issue_number: n, p_newsletter_only: !!newsOnly }),
      subscriberLink: (id, n) => rpc("admin_subscriber_link", { p_subscriber_id: id, p_issue_number: n }),
      importSubscribers: (rows) => rpc("admin_import_subscribers", { p_rows: rows }),
      rotateToken: (id) => rpc("admin_rotate_token", { p_subscriber_id: id }),
      analytics: (id) => rpc("admin_issue_analytics", { p_issue_id: id }),
      settings: () => q(client.from("sw_settings").select("*").order("key")),
      saveSetting: (k, v) => q(client.from("sw_settings").update({ value: v, updated_at: new Date().toISOString() }).eq("key", k)),
      recompute: () => rpc("admin_recompute_all_stats"),
      lastIssue: (n) => rpc("sw_last_issue_summary", { p_issue_number: n })
    };
  }

  /* ============================================================
     DATA LAYER — design preview (no backend, in-memory seed data)
     ============================================================ */
  async function previewAPI() {
    if (!window.SparkWordPreview) await loadScript((CFG.assetsPath || "assets/") + "spark-word-preview.js");
    if (!window.SPARK_WORD_BANK) await loadScript((CFG.assetsPath || "assets/") + "spark-word-wordbank-preview.js");
    const P = window.SparkWordPreview, D = P._data;
    const WORDS = (window.SPARK_WORD_BANK || []).map((r, i) => ({ id: "w" + i, word: r[0], category: r[1], definition: r[2], hint: r[3], related_type: r[4], related_ref: r[5], active: true }));
    const SETTINGS = [
      { key: "site_url", value: "https://tmtspark.example.com", description: "Public origin of the site — used to build newsletter game URLs and share links." },
      { key: "url_style", value: "path", description: "path → /spark-word/014?t=TOKEN (needs the SPA rewrite). query → /index.html?issue=14&t=TOKEN#spark-word." },
      { key: "hint_unlock_after", value: "3", description: "Guesses before \"Need a Spark?\" unlocks." },
      { key: "second_spark_after", value: "5", description: "After this many guesses a player who used the hint can reveal the first letter. 0 disables it." },
      { key: "streak_bonus_cap", value: "10", description: "Streak bonus +2 per issue, capped here." },
      { key: "company_min_players", value: "3", description: "Minimum players for a company to appear in standings." },
      { key: "min_seconds_per_guess", value: "0.7", description: "Faster average cadence is flagged and unranked." },
      { key: "require_verification_for_new_emails", value: "false", description: "true → every public claim must verify by magic link." }
    ];
    const issueRow = (i) => ({ id: i.id, issue_number: i.number, title: i.title, publication_date: i.date, answer: i.answer, category: i.category, hint: i.hint, explanation: i.explanation, status: i.status, allow_reuse: false, newsletter_recipients: { 11: 3900, 12: 4050, 13: 4180, 14: 4250 }[i.number] || null });
    const usedBy = (w) => (D.ISSUES.find((i) => i.answer === w) || {}).number || null;
    const wordRow = (w) => Object.assign({}, w, { used: !!usedBy(w.word), last_used_issue: usedBy(w.word) });
    const gamesFor = (iid) => D.GAMES.filter((g) => g.issue_id === iid && g.mode === "official");
    const url = (n, tok) => (SETTINGS.find((s) => s.key === "site_url").value) + "/spark-word/" + pad3(n) + "?t=" + tok;
    let signedIn = null;
    return {
      mode: "preview",
      async session() { return signedIn; },
      async signIn(email) { signedIn = { email, id: "preview-admin" }; return signedIn; },
      async magicLink() { return {}; },
      async signOut() { signedIn = null; },
      isAdmin: async () => true,
      overview: async () => {
        const act = D.ISSUES.find((i) => i.status === "active"), nxt = D.ISSUES.filter((i) => i.status !== "active" && i.status !== "archived").sort((a, b) => a.number - b.number)[0];
        return { subscribers: D.SUBS.length, newsletter_subscribers: D.SUBS.filter((s) => s.newsletter_subscriber).length, players: new Set(D.GAMES.filter((g) => g.subscriber_id).map((g) => g.subscriber_id)).size, issues: D.ISSUES.length,
          active_issue: act ? { number: act.number, title: act.title, answer: act.answer, category: act.category, date: act.date } : null,
          next_issue: nxt ? { number: nxt.number, title: nxt.title, status: nxt.status, date: nxt.date } : null,
          word_bank_total: WORDS.length, word_bank_available: WORDS.filter((w) => w.active && !usedBy(w.word)).length,
          games_total: D.GAMES.filter((g) => g.mode === "official" && g.status !== "in_progress").length, flagged_games: D.GAMES.filter((g) => g.flagged).length };
      },
      issues: async () => D.ISSUES.slice().sort((a, b) => b.number - a.number).map(issueRow),
      saveIssue: async (o) => {
        const dup = D.ISSUES.find((i) => i.answer === o.answer && i.id !== o.id);
        if (dup && !o.allow_reuse) throw new Error("SPARK_WORD_REUSED: " + o.answer + " was already the answer for issue " + dup.number + ". Set allow_reuse to override.");
        let i = D.ISSUES.find((x) => x.id === o.id);
        if (!i) { i = { id: "i" + o.issue_number + "-" + Date.now() }; D.ISSUES.push(i); }
        Object.assign(i, { number: +o.issue_number, title: o.title, date: o.publication_date, answer: o.answer, category: o.category, hint: o.hint, explanation: o.explanation, status: o.status });
        if (o.status === "active") D.ISSUES.forEach((x) => { if (x.id !== i.id && x.status === "active") x.status = "archived"; });
        return issueRow(i);
      },
      deleteIssue: async (id) => { const k = D.ISSUES.findIndex((i) => i.id === id); if (k >= 0) D.ISSUES.splice(k, 1); },
      setIssueStatus: async (id, status) => { const i = D.ISSUES.find((x) => x.id === id); i.status = status; if (status === "active") D.ISSUES.forEach((x) => { if (x.id !== id && x.status === "active") x.status = "archived"; }); return { ok: true }; },
      words: async (qq, cat, avail) => WORDS.filter((w) => (!qq || w.word.includes(qq.toUpperCase()) || w.definition.toLowerCase().includes(qq.toLowerCase())) && (!cat || w.category === cat) && (!avail || (w.active && !usedBy(w.word)))).map(wordRow).sort((a, b) => (a.used - b.used) || a.category.localeCompare(b.category) || a.word.localeCompare(b.word)),
      saveWord: async (o) => { let w = WORDS.find((x) => x.id === o.id); if (!w) { if (WORDS.some((x) => x.word === o.word)) throw new Error("duplicate key: " + o.word + " already exists"); w = { id: "w" + Date.now() }; WORDS.push(w); } Object.assign(w, o, { word: o.word.toUpperCase() }); return wordRow(w); },
      deleteWord: async (id) => { const k = WORDS.findIndex((w) => w.id === id); if (k >= 0) WORDS.splice(k, 1); },
      subscribers: async (qq) => D.SUBS.filter((s) => !qq || [s.email, s.first_name, s.last_name, s.company].join(" ").toLowerCase().includes(qq.toLowerCase())).map((s) => { const gs = D.GAMES.filter((g) => g.subscriber_id === s.id && g.mode === "official" && g.status !== "in_progress"); return { id: s.id, email: s.email, first_name: s.first_name, last_name: s.last_name, company: s.company, newsletter_subscriber: s.newsletter_subscriber, source: "newsletter_import", games_played: gs.length, games_won: gs.filter((g) => g.solved).length, current_streak: 0, total_points: gs.reduce((a, g) => a + (g.score || 0), 0), email_verified: s.email_verified, _tok: s.token }; }),
      links: async (n, newsOnly) => D.SUBS.filter((s) => !newsOnly || s.newsletter_subscriber).map((s) => ({ email: s.email, first_name: s.first_name, last_name: s.last_name, company: s.company, url: url(n, s.token) })),
      subscriberLink: async (id, n) => url(n, D.SUBS.find((s) => s.id === id).token),
      importSubscribers: async (rows) => { let ins = 0, upd = 0, skip = 0; rows.forEach((r) => { const e = (r.email || "").toLowerCase().trim(); if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) { skip++; return; } const ex = D.SUBS.find((s) => s.email === e); if (ex) { Object.assign(ex, { first_name: r.first_name || ex.first_name, last_name: r.last_name || ex.last_name, company: r.company || ex.company, newsletter_subscriber: true }); upd++; } else { D.SUBS.push({ id: "s" + Date.now() + ins, email: e, first_name: r.first_name, last_name: r.last_name, company: r.company, company_key: (r.company || "").toLowerCase(), token: "preview-" + Math.random().toString(36).slice(2), visibility: "first_last_initial", newsletter_subscriber: true }); ins++; } }); return { ok: true, inserted: ins, updated: upd, skipped: skip }; },
      rotateToken: async (id) => { const s = D.SUBS.find((x) => x.id === id); s.token = "preview-" + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2); return s.token; },
      analytics: async (id) => {
        const i = D.ISSUES.find((x) => x.id === id), gs = gamesFor(id), done = gs.filter((g) => g.status !== "in_progress"), solved = done.filter((g) => g.solved);
        const priorIds = D.ISSUES.filter((x) => x.number < i.number).map((x) => x.id);
        const ret = gs.filter((g) => g.subscriber_id && D.GAMES.some((p) => p.subscriber_id === g.subscriber_id && p.mode === "official" && p.status !== "in_progress" && priorIds.includes(p.issue_id))).length;
        const dist = [1, 2, 3, 4, 5, 6].map((n) => ({ n, count: solved.filter((g) => g.guess_count === n).length })).concat([{ n: 7, count: done.filter((g) => !g.solved).length }]).map((d) => Object.assign(d, { pct: done.length ? Math.round(100 * d.count / done.length) : 0 }));
        const co = {}; done.forEach((g) => { const s = D.SUBS.find((x) => x.id === g.subscriber_id); if (!s) return; const c = co[s.company_key] = co[s.company_key] || { company: s.company, players: 0, solved: 0 }; c.players++; if (g.solved) c.solved++; });
        const lb = await P.rpc("sw_issue_leaderboard", { p_issue_number: i.number, p_limit: 10 });
        return { ok: true, issue: { id: i.id, number: i.number, title: i.title, date: i.date, status: i.status, answer: i.answer, category: i.category, hint: i.hint, explanation: i.explanation },
          newsletter_recipients: issueRow(i).newsletter_recipients, link_clicks: gs.length, page_views: gs.length, unique_players: gs.length, completed: done.length,
          completion_pct: gs.length ? Math.round(100 * done.length / gs.length) : null, solved: solved.length, win_pct: done.length ? Math.round(100 * solved.length / done.length) : null,
          avg_guesses: solved.length ? +(solved.reduce((a, g) => a + g.guess_count, 0) / solved.length).toFixed(2) : null,
          hint_used: done.filter((g) => g.hint_used).length, hint_pct: done.length ? Math.round(100 * done.filter((g) => g.hint_used).length / done.length) : null,
          returning_players: ret, new_players: gs.filter((g) => g.subscriber_id).length - ret, shares: D.EVENTS.filter((e) => e.event_name === "spark_word_shared" && e.issue_id === id).length, flagged: gs.filter((g) => g.flagged).length,
          distribution: dist, top_companies: Object.values(co).sort((a, b) => b.players - a.players), leaderboard: lb.top };
      },
      settings: async () => SETTINGS.slice(),
      saveSetting: async (k, v) => { const s = SETTINGS.find((x) => x.key === k); if (s) s.value = v; },
      recompute: async () => D.SUBS.length,
      lastIssue: (n) => P.rpc("sw_last_issue_summary", { p_issue_number: n }).then((d) => Object.assign(d, { revealed: true, answer: (D.ISSUES.find((i) => i.number === n) || {}).answer }))
    };
  }

  /* ============================================================
     UI
     ============================================================ */
  let API = null, ME = null, ISSUES = [], WORDS = [], SETTINGS = [];
  const state = { tab: "overview", showAnswers: false };

  function showTab(id) {
    state.tab = id;
    $$("#tabs button").forEach((b) => b.classList.toggle("on", b.getAttribute("data-tab") === id));
    $$(".view").forEach((v) => v.classList.toggle("on", v.id === "view-" + id));
    try { history.replaceState(null, "", "#" + id); } catch (e) {}
    ({ overview: renderOverview, issues: renderIssues, words: renderWords, subs: renderSubs, analytics: renderAnalytics, email: renderEmail, settings: renderSettings }[id] || (() => {}))();
  }

  /* ---------- overview ---------- */
  async function renderOverview() {
    try {
      const o = await API.overview();
      $("#ovStats").innerHTML = [
        [o.subscribers, "Subscribers", o.newsletter_subscribers + " on the newsletter"],
        [o.players, "Players", "have played at least once"],
        [o.games_total, "Official games", o.flagged_games + " flagged"],
        [o.word_bank_available + " <small>/ " + o.word_bank_total + "</small>", "Words available", "in the bank"],
        [o.issues, "Issues", "created"]
      ].map((x) => "<div class='stat'><div class='sv'>" + x[0] + "</div><div class='sk'>" + x[1] + "</div><div class='sd'>" + esc(x[2]) + "</div></div>").join("");
      const a = o.active_issue;
      $("#ovActive").innerHTML = a ? "<span class='lbl'>Active now</span><h3>Issue " + pad3(a.number) + " · " + esc(a.title || "") + "</h3><p><span class='tag'>" + esc(a.category) + "</span> &nbsp; <span class='masked' data-reveal='" + esc(a.answer) + "'>•••••</span> <button class='btn btn-ghost btn-sm' data-reveal-btn>Reveal</button></p><p>Published " + esc(fmtDate(a.date)) + ".</p><div class='form-actions'><button class='btn btn-outline btn-sm' data-tab-go='analytics'>Analytics</button><a class='btn btn-outline btn-sm' href='" + GAME_PAGE + "?issue=" + a.number + "#spark-word' target='_blank' rel='noopener'>Open game ↗</a></div>"
        : "<span class='lbl'>Active now</span><h3>No active issue</h3><p>Nobody can play until an issue is active.</p><div class='form-actions'><button class='btn btn-primary btn-sm' data-tab-go='issues'>Activate one</button></div>";
      const n = o.next_issue;
      $("#ovNext").innerHTML = n ? "<span class='lbl'>Up next</span><h3>Issue " + pad3(n.number) + " · " + esc(n.title || "untitled") + "</h3><p><span class='tag " + n.status + "'>" + n.status + "</span> &nbsp; " + esc(fmtDate(n.date)) + "</p><div class='form-actions'><button class='btn btn-outline btn-sm' data-tab-go='issues'>Edit</button><a class='btn btn-outline btn-sm' href='" + GAME_PAGE + "?issue=" + n.number + "&preview=1#spark-word' target='_blank' rel='noopener'>Preview game ↗</a></div>"
        : "<span class='lbl'>Up next</span><h3>Nothing scheduled</h3><p>Create the next issue so it's ready when the newsletter ships.</p><div class='form-actions'><button class='btn btn-primary btn-sm' data-open-issue='new'>New issue</button></div>";
      $("#ovNote").innerHTML = API.mode === "preview" ? "<div class='note'><svg width='16' height='16'><use href='#i-info'/></svg><span><b>Design preview</b> — this dashboard is running on in-memory sample data because <code>" + (CFG.configHint || "assets/spark-word-config.js") + "</code> has no Supabase credentials. Every action works, nothing persists past a reload.</span></div>" : "";
    } catch (e) { toast("Couldn't load overview: " + e.message, true); }
  }

  /* ---------- issues ---------- */
  async function loadIssues() { ISSUES = await API.issues(); return ISSUES; }
  async function renderIssues() {
    try { await loadIssues(); } catch (e) { toast(e.message, true); return; }
    const t = $("#issuesTable");
    if (!ISSUES.length) { t.innerHTML = "<div class='empty'>No issues yet.</div>"; return; }
    t.innerHTML = "<table class='tbl'><thead><tr><th>Issue</th><th>Title</th><th>Date</th><th>Answer</th><th>Sector</th><th>Status</th><th class='num'>Recipients</th><th></th></tr></thead><tbody>" +
      ISSUES.map((i) => "<tr><td class='strong'>" + pad3(i.issue_number) + "</td><td>" + esc(i.title || "—") + "</td><td>" + esc(fmtDate(i.publication_date)) + "</td><td class='w'>" + (state.showAnswers ? esc(i.answer) : "<span class='masked'>•••••</span>") + "</td><td><span class='tag'>" + esc(i.category) + "</span></td><td><span class='tag " + i.status + "'>" + i.status + "</span></td><td class='num'>" + (i.newsletter_recipients ? i.newsletter_recipients.toLocaleString("en-US") : "—") + "</td>" +
        "<td><div class='row-actions'><button class='btn btn-outline btn-sm' data-open-issue='" + i.id + "'>Edit</button>" +
        (i.status !== "active" ? "<button class='btn btn-primary btn-sm' data-issue-status='active' data-id='" + i.id + "'>Activate</button>" : "<button class='btn btn-warn btn-sm' data-issue-status='archived' data-id='" + i.id + "'>Archive</button>") +
        "<a class='btn btn-ghost btn-sm' href='" + GAME_PAGE + "?issue=" + i.issue_number + (i.status === "active" || i.status === "archived" ? "" : "&preview=1") + "#spark-word' target='_blank' rel='noopener'>Preview ↗</a></div></td></tr>").join("") + "</tbody></table>";
  }
  async function openIssueEditor(id) {
    if (!WORDS.length) { try { WORDS = await API.words("", "", false); } catch (e) {} }
    const i = id === "new" ? { issue_number: (ISSUES[0] ? ISSUES[0].issue_number + 1 : 1), publication_date: new Date(Date.now() + 7 * 864e5).toISOString().slice(0, 10), status: "draft" } : ISSUES.find((x) => x.id === id);
    if (!i) return;
    const sh = $("#issueSheet");
    sh.innerHTML = "<button class='x' data-close='issueVeil' aria-label='Close'>✕</button><h3>" + (id === "new" ? "New issue" : "Issue " + pad3(i.issue_number)) + "</h3><p class='sub'>One official answer per newsletter issue. Pick the word from the bank — used words are blocked unless you tick the override.</p>" +
      "<form class='form-grid' id='issueForm'>" +
      "<div><label for='fNum'>Issue number</label><input id='fNum' name='issue_number' type='number' min='1' value='" + esc(i.issue_number) + "' required></div>" +
      "<div><label for='fDate'>Publication date</label><input id='fDate' name='publication_date' type='date' value='" + esc(i.publication_date) + "' required></div>" +
      "<div class='full'><label for='fTitle'>Newsletter title</label><input id='fTitle' name='title' type='text' value='" + esc(i.title || "") + "' placeholder='The AI Infrastructure Race'></div>" +
      "<div class='word-pick'><label for='fAnswer'>Spark Word (answer)</label><input id='fAnswer' name='answer' type='text' maxlength='5' autocomplete='off' value='" + esc(i.answer || "") + "' placeholder='Type to search the bank…' required style='text-transform:uppercase;letter-spacing:.2em;font-family:var(--serif);font-size:18px'><div class='list' id='wordList'></div><div class='hint' id='answerHint'></div></div>" +
      "<div><label for='fCat'>Sector shown to players</label><select id='fCat' name='category'>" + CATEGORIES.map((c) => "<option" + (i.category === c ? " selected" : "") + ">" + c + "</option>").join("") + "</select></div>" +
      "<div class='full'><label for='fHint'>Hint — unlocks after 3 guesses (optional)</label><input id='fHint' name='hint' type='text' value='" + esc(i.hint || "") + "' placeholder='What it physically is + where you meet it in TMT — e.g. Strands of glass that carry data as pulses of light.'></div>" +
      "<div class='full'><label for='fExp'>Post-game explanation — what it is and why it matters</label><textarea id='fExp' name='explanation' required>" + esc(i.explanation || "") + "</textarea></div>" +
      "<div><label for='fStatus'>Status</label><select id='fStatus' name='status'>" + ["draft", "scheduled", "active", "archived"].map((s) => "<option value='" + s + "'" + (i.status === s ? " selected" : "") + ">" + s + "</option>").join("") + "</select><div class='hint'>Activating archives the current active issue.</div></div>" +
      "<div><label for='fRec'>Newsletter recipients (for analytics)</label><input id='fRec' name='newsletter_recipients' type='number' min='0' value='" + esc(i.newsletter_recipients || "") + "'></div>" +
      "<div class='full'><label class='check'><input type='checkbox' name='allow_reuse'" + (i.allow_reuse ? " checked" : "") + "> Allow this word even if it was used in an earlier issue</label></div>" +
      "<div class='full form-actions'><button class='btn btn-primary' type='submit'>Save issue</button>" +
      (i.id ? "<a class='btn btn-outline' href='" + GAME_PAGE + "?issue=" + i.issue_number + (i.status === "active" || i.status === "archived" ? "" : "&preview=1") + "#spark-word' target='_blank' rel='noopener'>Preview game ↗</a>" : "") +
      (i.id && i.status !== "active" ? "<button class='btn btn-outline' type='button' data-issue-status='active' data-id='" + i.id + "'>Save &amp; activate</button>" : "") +
      (i.id && i.status === "draft" ? "<button class='btn btn-warn btn-sm right' type='button' data-delete-issue='" + i.id + "'>Delete draft</button>" : "") +
      "</div></form>";
    if (i.id) sh.querySelector("#issueForm").dataset.id = i.id;
    openVeil("issueVeil");
    const inp = $("#fAnswer"), list = $("#wordList");
    const renderList = () => {
      const qv = inp.value.toUpperCase().replace(/[^A-Z]/g, "");
      const hits = WORDS.filter((w) => w.active && (!qv || w.word.startsWith(qv))).slice(0, 40);
      list.innerHTML = hits.map((w) => "<button type='button' data-pick='" + w.word + "'" + (w.used && w.word !== i.answer ? " disabled" : "") + "><b>" + w.word + "</b><span>" + esc(w.definition.slice(0, 70)) + "…</span><span class='tag" + (w.used ? " used" : "") + "'>" + (w.used ? "used · " + pad3(w.last_used_issue) : esc(w.category)) + "</span></button>").join("") || "<button type='button' disabled>No match in the bank — add it under Word bank first</button>";
      list.classList.add("on");
      const w = WORDS.find((x) => x.word === qv);
      $("#answerHint").textContent = w ? (w.used && w.word !== i.answer ? "Already used in issue " + pad3(w.last_used_issue) + " — tick the override to reuse." : w.category + " · suggested hint: " + (w.hint || "—")) : (qv.length === 5 ? "Not in the word bank." : "");
    };
    inp.addEventListener("input", renderList);
    inp.addEventListener("focus", renderList);
    list.addEventListener("click", (e) => {
      const b = e.target.closest("[data-pick]"); if (!b) return;
      const w = WORDS.find((x) => x.word === b.getAttribute("data-pick"));
      inp.value = w.word; $("#fCat").value = w.category;
      if (!$("#fHint").value) $("#fHint").value = w.hint || "";
      if (!$("#fExp").value) $("#fExp").value = w.definition;
      list.classList.remove("on"); $("#answerHint").textContent = w.category + " · definition pre-filled — edit it for this issue.";
    });
    document.addEventListener("click", (e) => { if (!e.target.closest(".word-pick")) list.classList.remove("on"); });
    setTimeout(() => (id === "new" ? $("#fTitle") : $("#fAnswer")).focus(), 60);
  }
  async function submitIssue(form) {
    const f = new FormData(form);
    const o = { id: form.dataset.id || null, issue_number: +f.get("issue_number"), publication_date: f.get("publication_date"), title: (f.get("title") || "").trim(), answer: (f.get("answer") || "").toUpperCase().replace(/[^A-Z]/g, ""), category: f.get("category"), hint: (f.get("hint") || "").trim(), explanation: (f.get("explanation") || "").trim(), status: f.get("status"), newsletter_recipients: f.get("newsletter_recipients") ? +f.get("newsletter_recipients") : null, allow_reuse: !!f.get("allow_reuse") };
    if (o.answer.length !== 5) { toast("The answer must be exactly five letters.", true); return null; }
    if (!WORDS.some((w) => w.word === o.answer)) { toast("Add " + o.answer + " to the word bank first, so it carries a definition.", true); return null; }
    try { const row = await API.saveIssue(o); toast("Issue " + pad3(row.issue_number) + " saved."); closeVeil("issueVeil"); await renderIssues(); renderOverview(); return row; }
    catch (e) { toast(e.message.replace("SPARK_WORD_REUSED: ", ""), true); return null; }
  }
  async function setIssueStatus(id, status) {
    if (status === "active" && !confirm("Activate this issue? The currently active issue will be archived and players will get this word.")) return;
    try { await API.setIssueStatus(id, status); toast("Issue " + status + "."); closeVeil("issueVeil"); await renderIssues(); renderOverview(); } catch (e) { toast(e.message, true); }
  }

  /* ---------- word bank ---------- */
  async function renderWords() {
    const sel = $("#wordCat"); if (sel.options.length === 1) CATEGORIES.forEach((c) => { const o = document.createElement("option"); o.textContent = c; o.value = c; sel.appendChild(o); });
    try { WORDS = await API.words($("#wordSearch").value.trim(), sel.value, $("#wordAvail").checked); } catch (e) { toast(e.message, true); return; }
    $("#wordCount").textContent = WORDS.length + " WORDS · " + WORDS.filter((w) => !w.used && w.active).length + " AVAILABLE";
    const t = $("#wordsTable");
    if (!WORDS.length) { t.innerHTML = "<div class='empty'>Nothing matches.</div>"; return; }
    t.innerHTML = "<table class='tbl'><thead><tr><th>Word</th><th>Sector</th><th>Definition</th><th>Status</th><th></th></tr></thead><tbody>" +
      WORDS.map((w) => "<tr><td class='w'>" + w.word + "</td><td><span class='tag'>" + esc(w.category) + "</span></td><td style='white-space:normal;max-width:520px'>" + esc(w.definition) + (w.hint ? "<div class='dim-t' style='font-size:12px;margin-top:4px'>Hint: " + esc(w.hint) + "</div>" : "") + "</td><td>" + (w.used ? "<span class='tag used'>used · " + pad3(w.last_used_issue) + "</span>" : w.active ? "<span class='tag active'>available</span>" : "<span class='tag draft'>inactive</span>") + "</td><td><div class='row-actions'><button class='btn btn-outline btn-sm' data-edit-word='" + w.id + "'>Edit</button>" + (w.used ? "" : "<button class='btn btn-warn btn-sm' data-delete-word='" + w.id + "'>Remove</button>") + "</div></td></tr>").join("") + "</tbody></table>";
  }
  function openWordEditor(id) {
    const w = id ? WORDS.find((x) => x.id === id) : { active: true };
    const sh = $("#wordSheet");
    sh.innerHTML = "<button class='x' data-close='wordVeil' aria-label='Close'>✕</button><h3>" + (id ? "Edit " + w.word : "Add a word") + "</h3><p class='sub'>Recognisable industry terms only — no company names, trademarks or obscure acronyms.</p>" +
      "<form class='form-grid' id='wordForm'" + (id ? " data-id='" + id + "'" : "") + ">" +
      "<div><label for='wWord'>Word (5 letters)</label><input id='wWord' name='word' maxlength='5' value='" + esc(w.word || "") + "' required style='text-transform:uppercase;letter-spacing:.2em;font-family:var(--serif);font-size:18px'" + (w.used ? " readonly" : "") + "></div>" +
      "<div><label for='wCat'>Sector</label><select id='wCat' name='category'>" + CATEGORIES.map((c) => "<option" + (w.category === c ? " selected" : "") + ">" + c + "</option>").join("") + "</select></div>" +
      "<div class='full'><label for='wDef'>Definition — what it is + why it matters</label><textarea id='wDef' name='definition' required>" + esc(w.definition || "") + "</textarea></div>" +
      "<div class='full'><label for='wHint'>Suggested hint (indirect — never a giveaway)</label><input id='wHint' name='hint' value='" + esc(w.hint || "") + "'></div>" +
      "<div><label for='wRT'>Spark Learning link (optional)</label><select id='wRT' name='related_type'><option value=''>None</option>" + ["glossary", "explainer", "story"].map((t) => "<option value='" + t + "'" + (w.related_type === t ? " selected" : "") + ">" + t + "</option>").join("") + "</select></div>" +
      "<div><label for='wRR'>Link reference (term / explainer title / story id)</label><input id='wRR' name='related_ref' value='" + esc(w.related_ref || "") + "' placeholder='Dark fiber · What is a GPU? · a1'></div>" +
      "<div class='full'><label class='check'><input type='checkbox' name='active'" + (w.active !== false ? " checked" : "") + "> Active (available to pick)</label></div>" +
      "<div class='full form-actions'><button class='btn btn-primary' type='submit'>Save word</button></div></form>";
    openVeil("wordVeil"); setTimeout(() => $("#wWord").focus(), 60);
  }
  async function submitWord(form) {
    const f = new FormData(form);
    const o = { id: form.dataset.id || null, word: (f.get("word") || "").toUpperCase().replace(/[^A-Z]/g, ""), category: f.get("category"), definition: (f.get("definition") || "").trim(), hint: (f.get("hint") || "").trim(), related_type: f.get("related_type") || null, related_ref: (f.get("related_ref") || "").trim() || null, active: !!f.get("active") };
    if (o.word.length !== 5) { toast("Five letters, please.", true); return; }
    try { await API.saveWord(o); toast(o.word + " saved."); closeVeil("wordVeil"); renderWords(); } catch (e) { toast(e.message.includes("duplicate") ? o.word + " is already in the bank." : e.message, true); }
  }

  /* ---------- subscribers & links ---------- */
  function fillIssueSelects() {
    const opts = ISSUES.map((i) => "<option value='" + i.issue_number + "' data-id='" + i.id + "'" + (i.status === "active" ? " selected" : "") + ">Issue " + pad3(i.issue_number) + " · " + esc(i.title || "") + " (" + i.status + ")</option>").join("");
    ["#linkIssue", "#anIssue", "#emIssue"].forEach((s) => { const el = $(s); if (el && el.innerHTML !== opts) el.innerHTML = opts; });
  }
  async function renderSubs() {
    if (!ISSUES.length) await loadIssues();
    fillIssueSelects();
    let rows;
    try { rows = await API.subscribers($("#subSearch").value.trim()); } catch (e) { toast(e.message, true); return; }
    $("#subCount").textContent = rows.length + " SUBSCRIBERS";
    const n = +$("#linkIssue").value;
    $("#subsTable").innerHTML = rows.length ? "<table class='tbl'><thead><tr><th>Name</th><th>Email</th><th>Company</th><th class='num'>Games</th><th class='num'>Points</th><th>Newsletter</th><th></th></tr></thead><tbody>" +
      rows.map((s) => "<tr><td class='strong'>" + esc((s.first_name || "") + " " + (s.last_name || "")) + "</td><td>" + esc(s.email) + (s.email_verified ? " <span class='tag'>verified</span>" : "") + "</td><td>" + esc(s.company || "—") + "</td><td class='num'>" + s.games_played + "</td><td class='num'>" + s.total_points + "</td><td>" + (s.newsletter_subscriber ? "<span class='tag active'>yes</span>" : "<span class='tag draft'>no</span>") + "</td><td><div class='row-actions'><button class='link' data-copy-link='" + s.id + "'>Copy link · " + pad3(n) + "</button><button class='link' style='color:var(--warn)' data-rotate='" + s.id + "'>Rotate token</button></div></td></tr>").join("") + "</tbody></table>" : "<div class='empty'>No subscribers match.</div>";
  }
  function csvEscape(v) { v = String(v == null ? "" : v); return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; }
  async function exportLinks(asText) {
    const n = +$("#linkIssue").value; if (!n) { toast("Pick an issue first.", true); return; }
    try {
      const rows = await API.links(n, $("#linkNewsOnly").checked);
      $("#linkCount").textContent = rows.length + " links";
      const fmt = ($("#linkFormat") && $("#linkFormat").value) || "generic";
      // Staffbase Email custom data: first column must be `identifier` (the email); tags are case-sensitive → {{gameUrl}}
      const csv = fmt === "staffbase"
        ? "identifier,firstName,lastName,company,gameUrl\n" + rows.map((r) => [r.email, r.first_name, r.last_name, r.company, r.url].map(csvEscape).join(",")).join("\n")
        : "email,first_name,last_name,company,game_url\n" + rows.map((r) => [r.email, r.first_name, r.last_name, r.company, r.url].map(csvEscape).join(",")).join("\n");
      if (asText) { await navigator.clipboard.writeText(csv); toast("Copied " + rows.length + " links as CSV text."); return; }
      const a = document.createElement("a"); a.href = "data:text/csv;charset=utf-8," + encodeURIComponent(csv); a.download = "spark-word-issue-" + pad3(n) + (fmt === "staffbase" ? "-staffbase" : "") + "-links.csv"; document.body.appendChild(a); a.click(); a.remove();
      toast("Downloaded " + rows.length + " personalised links for Issue " + pad3(n) + ".");
    } catch (e) { toast(e.message, true); }
  }
  function parseCSV(text) {
    const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    if (!lines.length) return [];
    const cells = (l) => { const out = []; let cur = "", q = false; for (const ch of l) { if (ch === '"') q = !q; else if (ch === "," && !q) { out.push(cur.trim()); cur = ""; } else cur += ch; } out.push(cur.trim()); return out; };
    let header = ["email", "first_name", "last_name", "company"];
    const first = cells(lines[0]);
    if (first.some((c) => /email/i.test(c))) { header = first.map((c) => c.toLowerCase().replace(/\s+/g, "_").replace("firstname", "first_name").replace("lastname", "last_name").replace("organisation", "company").replace("organization", "company")); lines.shift(); }
    return lines.map((l) => { const c = cells(l), o = {}; header.forEach((h, k) => { o[h] = c[k] || ""; }); return { email: o.email, first_name: o.first_name || o.first || "", last_name: o.last_name || o.last || "", company: o.company || "" }; });
  }

  /* ---------- analytics ---------- */
  async function renderAnalytics() {
    if (!ISSUES.length) await loadIssues();
    fillIssueSelects();
    const sel = $("#anIssue"), opt = sel.options[sel.selectedIndex]; if (!opt) { $("#anBody").innerHTML = "<div class='empty'>Create an issue first.</div>"; return; }
    const id = opt.getAttribute("data-id");
    $("#anBody").innerHTML = "<div class='empty'>Loading…</div>";
    try {
      const a = await API.analytics(id);
      const m = (v, lbl, sub) => "<div class='stat'><div class='sv'>" + (v == null ? "—" : v) + "</div><div class='sk'>" + lbl + "</div>" + (sub ? "<div class='sd'>" + esc(sub) + "</div>" : "") + "</div>";
      let h = "<div class='stat-row'>" + m(a.newsletter_recipients ? a.newsletter_recipients.toLocaleString("en-US") : null, "Newsletter recipients", "from the issue record") + m(a.link_clicks, "Game link clicks", a.newsletter_recipients ? Math.round(100 * a.link_clicks / a.newsletter_recipients) + "% of recipients" : "") + m(a.unique_players, "Unique players", "started a game") + m(a.completion_pct == null ? null : a.completion_pct + "%", "Completion", a.completed + " finished") + m(a.win_pct == null ? null : a.win_pct + "%", "Win rate", a.solved + " solved") + m(a.avg_guesses, "Average guesses", "solved games") + "</div>";
      h += "<div class='stat-row'>" + m(a.hint_pct == null ? null : a.hint_pct + "%", "Used the hint", a.hint_used + " players") + m(a.returning_players, "Returning players", "played an earlier issue") + m(a.new_players, "New players", "first Spark Word") + m(a.shares, "Shares", "copy or native share") + m(a.flagged, "Flagged games", "excluded from ranking") + m(a.page_views, "Page views", "all sources") + "</div>";
      h += "<div class='grid2'><div class='card'><h3>Guess distribution</h3><div class='dist'>" + a.distribution.map((d) => "<div class='r" + (d.n === 7 ? " fail" : "") + "'><span class='n'>" + (d.n === 7 ? "X" : d.n) + "</span><span class='bar'><i style='width:" + d.pct + "%'></i></span><span class='pct'>" + d.pct + "%</span></div>").join("") + "</div><p class='dim-t' style='margin-top:12px;font-size:12px'>" + a.distribution.map((d) => (d.n === 7 ? "X" : d.n) + " | " + "█".repeat(Math.round(d.pct / 4)) + " " + d.pct + "%").join("<br>") + "</p></div>" +
        "<div class='card'><h3>Top companies</h3>" + (a.top_companies.length ? "<div class='tbl-wrap'><table class='tbl' style='min-width:0'><thead><tr><th>Company</th><th class='num'>Players</th><th class='num'>Solved</th></tr></thead><tbody>" + a.top_companies.map((c) => "<tr><td class='strong'>" + esc(c.company) + "</td><td class='num'>" + c.players + "</td><td class='num'>" + c.solved + "</td></tr>").join("") + "</tbody></table></div>" : "<p>No completed games yet.</p>") + "</div></div>";
      h += "<div class='card'><h3>Issue " + pad3(a.issue.number) + " leaderboard</h3>" + (a.leaderboard && a.leaderboard.length ? "<div class='tbl-wrap'><table class='tbl'><thead><tr><th>Rank</th><th>Player</th><th>Company</th><th class='num'>Guesses</th><th class='num'>Time</th><th class='num'>Points</th></tr></thead><tbody>" + a.leaderboard.map((r) => "<tr><td class='strong'>" + r.rank + "</td><td>" + esc(r.name) + "</td><td>" + esc(r.company || "") + "</td><td class='num'>" + r.guesses + "/6" + (r.hint_used ? " +hint" : "") + "</td><td class='num'>" + (r.seconds == null ? "—" : r.seconds + "s") + "</td><td class='num'>" + r.points + "</td></tr>").join("") + "</tbody></table></div>" : "<p>No solved games yet.</p>") + "</div>";
      h += "<div id='anShareout'></div>";
      $("#anBody").innerHTML = h;
      try {
        const s = await API.lastIssue(a.issue.number);
        if (s && s.ok) $("#anShareout").innerHTML = "<span class='lbl'>Shareout block for the next newsletter (screenshot-ready)</span><div class='shareout'><p class='so-l'>Last issue's Spark Word · Issue " + pad3(a.issue.number) + "</p><p class='so-word'>" + esc(s.answer || a.issue.answer) + "</p><div class='so-stats'><div>" + (s.players || 0) + "<span>Players</span></div><div>" + (s.solved_pct == null ? "—" : s.solved_pct + "%") + "<span>Solved</span></div></div>" + (s.top.length ? "<p class='so-l'>Fastest minds</p><ol>" + s.top.map((t) => "<li><span class='on2'>" + t.rank + "</span><span>" + esc(t.name) + "</span><span class='co'>· " + esc(t.company || "") + "</span><span class='gs'>" + t.guesses + "/6</span></li>").join("") + "</ol>" : "") + (s.company_champion ? "<div class='so-champ'><span class='so-l' style='margin:0'>Company champion</span><b>" + esc(s.company_champion) + "</b></div>" : "") + "</div>";
      } catch (e) {}
    } catch (e) { $("#anBody").innerHTML = "<div class='empty'>" + esc(e.message) + "</div>"; }
  }

  /* ---------- email module ---------- */
  const EMAIL_FALLBACK = "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"background:#0B111E;\"><tr><td align=\"center\" style=\"padding:28px 16px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"max-width:600px;background:#101726;border:1px solid #212C42;border-radius:18px;\"><tr><td style=\"padding:30px 32px 10px 32px;font-family:Menlo,Consolas,monospace;font-size:11px;letter-spacing:3px;color:#4DA3FF;text-transform:uppercase;\">&#9889;&nbsp; Spark Word &nbsp;&middot;&nbsp; Issue {{ISSUE_NUMBER}}</td></tr><tr><td style=\"padding:0 32px 6px 32px;font-family:Georgia,serif;font-size:30px;line-height:1.15;color:#EDF1F7;\">Five letters.<br>Six guesses.<br><span style=\"color:#4DA3FF;font-style:italic;\">One industry.</span></td></tr><tr><td style=\"padding:12px 32px 22px 32px;font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:1.6;color:#A7B4C4;\">How well do you know the world you're building?</td></tr><tr><td style=\"padding:0 32px 18px 32px;\"><table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\"><tr><td align=\"center\" bgcolor=\"#4DA3FF\" style=\"border-radius:999px;\"><a href=\"{{GAME_URL}}\" style=\"display:inline-block;padding:14px 28px;font-family:Helvetica,Arial,sans-serif;font-size:15px;font-weight:700;color:#0A1B33;text-decoration:none;\">Play Issue {{ISSUE_NUMBER}} &rarr;</a></td></tr></table></td></tr><tr><td style=\"padding:0 32px 28px 32px;font-family:Helvetica,Arial,sans-serif;font-size:13px;color:#6C7A8C;\"><span style=\"color:#A7B4C4;font-weight:600;\">{{LAST_PLAYERS}} people played last issue.</span> Can you make the Top 10?</td></tr></table></td></tr></table>";
  let EMAIL_TPL = null;
  async function renderEmail() {
    if (!ISSUES.length) await loadIssues();
    fillIssueSelects();
    if (!EMAIL_TPL) { try { const r = await fetch("email/spark-word-module.html"); EMAIL_TPL = r.ok ? await r.text() : EMAIL_FALLBACK; } catch (e) { EMAIL_TPL = EMAIL_FALLBACK; } }
    const n = +$("#emIssue").value || 14;
    const prev = ISSUES.find((i) => i.issue_number < n && i.status === "archived");
    let lastPlayers = "Hundreds of";
    try { if (prev) { const s = await API.lastIssue(prev.issue_number); if (s && s.ok && s.players) lastPlayers = String(s.players); } } catch (e) {}
    const site = (SETTINGS.find((s) => s.key === "site_url") || {}).value || CFG.siteUrl || "https://tmtspark.example.com";
    const filled = EMAIL_TPL.replace(/\{\{ISSUE_NUMBER\}\}/g, pad3(n)).replace(/\{\{GAME_URL\}\}/g, site + "/spark-word/" + pad3(n) + "?t=SUBSCRIBER_TOKEN").replace(/\{\{LAST_PLAYERS\}\}/g, lastPlayers);
    $("#emCode").value = EMAIL_TPL;
    const fr = $("#emFrame"); fr.srcdoc = "<!doctype html><html><body style='margin:0;background:#0B111E'>" + filled + "</body></html>";
  }

  /* ---------- settings ---------- */
  async function renderSettings() {
    try { SETTINGS = await API.settings(); } catch (e) { toast(e.message, true); return; }
    $("#settingsBody").innerHTML = SETTINGS.map((s) => "<div class='kv'><span class='k'>" + esc(s.key) + "</span><input data-setting='" + esc(s.key) + "' value='" + esc(s.value) + "'><button class='btn btn-outline btn-sm' data-save-setting='" + esc(s.key) + "'>Save</button><span class='d'>" + esc(s.description || "") + "</span></div>").join("");
  }

  /* ---------- auth ---------- */
  async function boot() {
    if (CFG.supabaseUrl && CFG.supabaseAnonKey && window.supabase) { API = supabaseAPI(); }
    else { API = await previewAPI(); $("#modeBadge").textContent = "Design preview · no backend"; $("#modeBadge").classList.add("preview"); }
    const s = await API.session();
    if (!s) { showLogin(); return; }
    await afterLogin(s);
  }
  function showLogin() {
    $("#login").hidden = false; $("#notAdmin").hidden = true; $("#tabs").hidden = true; $("#who").hidden = true;
    if (API.mode === "preview") { $("#loginMsg").innerHTML = "Design preview: any email signs in (no backend). <button type='button' id='previewIn' class='btn btn-outline btn-sm' style='margin-left:8px'>Enter as editor@turntown.com</button>"; }
  }
  async function afterLogin(s) {
    ME = s;
    let ok = false; try { ok = await API.isAdmin(); } catch (e) { toast(e.message, true); }
    if (!ok) { $("#login").hidden = true; $("#notAdmin").hidden = false; $("#naEmail").textContent = s.email; $("#naSql").value = "insert into admins (user_id, email, role)\nselect id, email, 'editor' from auth.users where email = '" + s.email + "';"; return; }
    $("#login").hidden = true; $("#notAdmin").hidden = true; $("#tabs").hidden = false; $("#who").hidden = false; $("#whoEmail").textContent = s.email;
    await loadIssues();
    const tab = (location.hash || "#overview").slice(1);
    showTab(["overview", "issues", "words", "subs", "analytics", "email", "settings"].includes(tab) ? tab : "overview");
  }

  /* ---------- events ---------- */
  document.addEventListener("click", async (e) => {
    const t = e.target;
    const tab = t.closest("#tabs [data-tab]"); if (tab) { showTab(tab.getAttribute("data-tab")); return; }
    const go = t.closest("[data-tab-go]"); if (go) { showTab(go.getAttribute("data-tab-go")); return; }
    const oi = t.closest("[data-open-issue]"); if (oi) { openIssueEditor(oi.getAttribute("data-open-issue")); return; }
    const st = t.closest("[data-issue-status]"); if (st) { setIssueStatus(st.getAttribute("data-id"), st.getAttribute("data-issue-status")); return; }
    const di = t.closest("[data-delete-issue]"); if (di) { if (confirm("Delete this draft issue?")) { try { await API.deleteIssue(di.getAttribute("data-delete-issue")); closeVeil("issueVeil"); toast("Draft deleted."); renderIssues(); } catch (err) { toast(err.message, true); } } return; }
    const cl = t.closest("[data-close]"); if (cl) { closeVeil(cl.getAttribute("data-close")); return; }
    const rb = t.closest("[data-reveal-btn]"); if (rb) { const m = rb.parentElement.querySelector("[data-reveal]"); m.textContent = m.getAttribute("data-reveal"); m.style.letterSpacing = ".2em"; rb.remove(); return; }
    if (t.closest("#addWordBtn")) { openWordEditor(null); return; }
    const ew = t.closest("[data-edit-word]"); if (ew) { openWordEditor(ew.getAttribute("data-edit-word")); return; }
    const dw = t.closest("[data-delete-word]"); if (dw) { const w = WORDS.find((x) => x.id === dw.getAttribute("data-delete-word")); if (confirm("Remove " + w.word + " from the bank?")) { try { await API.deleteWord(w.id); toast(w.word + " removed."); renderWords(); } catch (err) { toast(err.message, true); } } return; }
    if (t.closest("#exportLinks")) { exportLinks(false); return; }
    if (t.closest("#copyLinks")) { exportLinks(true); return; }
    if (t.closest("#importBtn")) { const rows = parseCSV($("#importBox").value); if (!rows.length) { toast("Paste some rows first.", true); return; } try { const r = await API.importSubscribers(rows); $("#importMsg").textContent = r.inserted + " added · " + r.updated + " updated · " + r.skipped + " skipped"; toast("Import complete."); renderSubs(); } catch (err) { toast(err.message, true); } return; }
    const cp = t.closest("[data-copy-link]"); if (cp) { try { const u = await API.subscriberLink(cp.getAttribute("data-copy-link"), +$("#linkIssue").value); await navigator.clipboard.writeText(u); toast("Personal link copied."); } catch (err) { toast(err.message, true); } return; }
    const rt = t.closest("[data-rotate]"); if (rt) { if (confirm("Rotate this subscriber's token? Their old newsletter links stop working.")) { try { await API.rotateToken(rt.getAttribute("data-rotate")); toast("Token rotated."); } catch (err) { toast(err.message, true); } } return; }
    if (t.closest("#copyEmail")) { try { await navigator.clipboard.writeText($("#emCode").value); toast("Email module HTML copied."); } catch (err) { toast("Copy blocked — select the code manually.", true); } return; }
    const ss = t.closest("[data-save-setting]"); if (ss) { const k = ss.getAttribute("data-save-setting"), v = $("[data-setting='" + k + "']").value; try { await API.saveSetting(k, v); toast(k + " saved."); } catch (err) { toast(err.message, true); } return; }
    if (t.closest("#recomputeBtn")) { try { const n = await API.recompute(); toast("Recomputed stats for " + n + " subscribers."); } catch (err) { toast(err.message, true); } return; }
    if (t.closest("#signOut") || t.closest("#naSignOut")) { await API.signOut(); location.hash = ""; location.reload(); return; }
    if (t.closest("#previewIn")) { await API.signIn("editor@turntown.com"); afterLogin({ email: "editor@turntown.com" }); return; }
    if (t.closest("#magicBtn")) { const email = $("#lEmail").value.trim(); if (!email) { $("#loginMsg").textContent = "Enter your email first."; return; } try { await API.magicLink(email); $("#loginMsg").textContent = "Check your inbox for the sign-in link."; } catch (err) { $("#loginMsg").textContent = err.message; } return; }
  });
  document.addEventListener("submit", async (e) => {
    if (e.target.id === "loginForm") { e.preventDefault(); const btn = $("#loginBtn"); btn.disabled = true; try { await API.signIn($("#lEmail").value.trim(), $("#lPass").value); const s = await API.session(); if (s) afterLogin(s); else $("#loginMsg").textContent = "Signed in, but no session was returned."; } catch (err) { $("#loginMsg").textContent = err.message; } finally { btn.disabled = false; } }
    if (e.target.id === "issueForm") { e.preventDefault(); submitIssue(e.target); }
    if (e.target.id === "wordForm") { e.preventDefault(); submitWord(e.target); }
  });
  document.addEventListener("input", (e) => {
    if (e.target.id === "wordSearch") { clearTimeout(state.wt); state.wt = setTimeout(renderWords, 300); }
    if (e.target.id === "subSearch") { clearTimeout(state.st); state.st = setTimeout(renderSubs, 300); }
  });
  document.addEventListener("change", (e) => {
    if (e.target.id === "wordCat" || e.target.id === "wordAvail") renderWords();
    if (e.target.id === "showAnswers") { state.showAnswers = e.target.checked; renderIssues(); }
    if (e.target.id === "anIssue") renderAnalytics();
    if (e.target.id === "emIssue") renderEmail();
    if (e.target.id === "linkIssue") renderSubs();
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") $$(".veil.on").forEach((v) => closeVeil(v.id)); });
  $$(".veil").forEach((v) => v.addEventListener("mousedown", (e) => { if (e.target === v) closeVeil(v.id); }));

  boot().catch((e) => { console.error(e); toast("Admin failed to start: " + e.message, true); });
})();
