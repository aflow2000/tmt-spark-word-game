/* ============================================================
   SPARK WORD — game module for TMT Spark
   ------------------------------------------------------------
   Five letters. Six tries. One industry.

   • Talks to Supabase through the RPC functions in supabase/migrations
     (the answer never reaches the browser until the game is over).
   • Uses the site bridge `window.TMTSpark` (showPage, toast, veils,
     search INDEX) so it feels native to the existing single-page site.
   • localStorage is used ONLY for: subscriber token, guest id,
     onboarding flag, unfinished-guess draft, pending claim.
     Every result and leaderboard lives in the database.
   • If no backend is configured, `assets/spark-word-preview.js` provides
     a loudly-labelled in-memory preview so designers can review the UI.
   ============================================================ */
(function () {
  "use strict";

  const CFG = window.SPARK_WORD_CONFIG || {};
  const TS  = window.TMTSpark || {};
  const $   = (s, c) => (c || document).querySelector(s);
  const $$  = (s, c) => Array.prototype.slice.call((c || document).querySelectorAll(s));
  const REDUCED = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const toast = (m) => (TS.toast ? TS.toast(m) : console.log("[toast]", m));
  const pad3 = (n) => String(n).padStart(3, "0");
  const esc  = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  const PAGE_ID = "spark-word";
  const KEYS = { token: "sw_token", guest: "sw_guest_id", onboarded: "sw_onboarded", draft: "sw_draft:", pending: "sw_pending_claim" };
  const SERVER_EVENTS = ["spark_word_viewed", "spark_word_shared", "spark_word_leaderboard_viewed", "spark_word_archive_played", "spark_word_onboarding_seen", "spark_word_claim_opened"];
  const SEC_TAG = { c: "correct", p: "present", a: "absent" };
  const SEC_TXT = { c: "right letter, right place", p: "right letter, wrong place", a: "not in the word" };

  /* ---------------- safe storage ---------------- */
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
    del(k) { try { localStorage.removeItem(k); } catch (e) {} }
  };
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => { const r = Math.random() * 16 | 0; return (c === "x" ? r : (r & 3 | 8)).toString(16); });
  }
  const getToken = () => store.get(KEYS.token) || null;
  const setToken = (t) => { if (t) store.set(KEYS.token, t); else store.del(KEYS.token); };
  function getGuestId() { let g = store.get(KEYS.guest); if (!g) { g = "guest-" + uuid(); store.set(KEYS.guest, g); } return g; }
  /* identity params for every RPC: token wins; guest id only when no token */
  const ident = () => ({ p_token: getToken(), p_guest_id: getToken() ? null : getGuestId() });
  /* "issue" (newsletter editions) or "day" (daily edition) — CFG.issueNoun */
  const NOUN = (CFG.issueNoun || "issue").toLowerCase(), NOUNC = NOUN.charAt(0).toUpperCase() + NOUN.slice(1), NOUNU = NOUN.toUpperCase(), DAILY = NOUN === "day";
  const hintAfter = () => (S.boot && S.boot.settings && S.boot.settings.hint_unlock_after) || 3;
  const secondAfter = () => (S.boot && S.boot.settings && typeof S.boot.settings.second_spark_after === "number") ? S.boot.settings.second_spark_after : 5;
  const numWord = (n) => ["zero", "one", "two", "three", "four", "five", "six"][n] || String(n);

  /* ---------------- API layer ---------------- */
  const API = (function () {
    let client = null, mode = "none", ready = Promise.resolve();
    if (CFG.supabaseUrl && CFG.supabaseAnonKey && window.supabase && window.supabase.createClient) {
      client = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, {
        auth: { persistSession: true, detectSessionInUrl: true, flowType: "pkce" }
      });
      mode = "supabase";
    } else if (CFG.preview !== false) {
      // No backend configured → load the clearly-labelled in-memory design preview.
      mode = "preview";
      ready = new Promise((resolve) => {
        if (window.SparkWordPreview) return resolve();
        const sc = document.createElement("script");
        sc.src = (CFG.assetsPath || "assets/") + "spark-word-preview.js";
        sc.onload = () => resolve();
        sc.onerror = () => { mode = "none"; resolve(); };
        document.head.appendChild(sc);
      });
    }
    async function rpc(name, params) {
      await ready;
      if (mode === "supabase") {
        const { data, error } = await client.rpc(name, params || {});
        if (error) throw new Error(error.message || "rpc_failed");
        return data;
      }
      if (mode === "preview" && window.SparkWordPreview) return window.SparkWordPreview.rpc(name, params || {});
      throw new Error("not_configured");
    }
    return { rpc, get mode() { return mode; }, client, ready };
  })();

  /* ---------------- state ---------------- */
  const S = {
    entry: null,          // parsed URL entry (issue, token, ref, view, verify)
    boot: null,           // last bootstrap payload
    issue: null, player: null, game: null,
    rows: [], current: "", status: "idle", busy: false,
    hintAvailable: false, hintUsed: false, hint: null, secondSpark: false, firstLetter: null, firstLetterShown: false,
    completion: null, newGameMode: null,
    activeIssueNumber: null, latestIssueNumber: null,
    view: null, ready: false, pageShown: false, boardBuilt: false,
    indexed: {}, lastIssue: null
  };

  /* ---------------- URL / entry parsing ---------------- */
  function parseEntry() {
    const q = new URLSearchParams(location.search);
    const m = location.pathname.match(/\/spark-word\/(\d{1,4})\/?$/i);
    const hash = (location.hash || "").replace(/^#/, "");
    const hp = hash.split("/");
    const e = {
      issue: m ? parseInt(m[1], 10) : (q.get("issue") ? parseInt(q.get("issue"), 10) : null),
      token: q.get("t") || null,
      ref: q.get("ref") || (q.get("t") ? "newsletter" : (hp[0] === PAGE_ID ? "link" : "site")),
      verify: q.get("verify") === "1",
      preview: q.get("preview") === "1",
      company: q.get("company") || null,   // optional prefill for the one-time claim form (e.g. an internal newsletter's generic link)
      first: q.get("first") || null,
      view: hp[0] === PAGE_ID ? (hp[1] || null) : null,
      wantsPage: !!m || hp[0] === PAGE_ID || !!q.get("issue") || !!q.get("t")
    };
    if (e.token) {
      setToken(e.token);
      // never leave the token in the address bar (screenshots, history, share)
      q.delete("t");
      const qs = q.toString();
      const clean = (m ? location.pathname : location.pathname) + (qs ? "?" + qs : "") + (m ? "#" + PAGE_ID : (location.hash || "#" + PAGE_ID));
      try { history.replaceState(null, "", clean); } catch (err) {}
    }
    return e;
  }

  function siteUrl() {
    if (CFG.siteUrl) return CFG.siteUrl.replace(/\/$/, "");
    if (location.protocol === "file:") return location.href.split(/[?#]/)[0];
    const p = location.pathname.replace(/\/spark-word\/\d+\/?$/i, "/");
    const file = p.match(/([^/]+\.html?)$/i);
    // a game-only page (e.g. spark-word.html) keeps its own file name; index.html collapses to the folder
    if (file && !/^index\.html?$/i.test(file[1])) return location.origin + p;
    return location.origin + p.replace(/[^/]*$/, "").replace(/\/$/, "");
  }
  function gameUrl(issueNumber) {
    const n = issueNumber || (S.issue && S.issue.number);
    const base = siteUrl();
    if ((CFG.urlStyle || "path") === "path" && location.protocol !== "file:") return base + "/spark-word/" + pad3(n);
    const file = base.match(/\.html?$/) ? base : base + "/index.html";
    return file + "?issue=" + n + "#" + PAGE_ID;
  }

  /* ---------------- analytics hooks ---------------- */
  function track(name, props) {
    props = props || {};
    const payload = Object.assign({
      issue_id: S.issue ? S.issue.slug : null,
      issue_number: S.issue ? S.issue.number : null,
      subscriber_id: S.player ? S.player.id : null,
      company: S.player ? S.player.company : null,
      mode: S.game ? S.game.mode : null
    }, props);
    delete payload.answer;
    try { if (typeof CFG.analytics === "function") CFG.analytics(name, payload); } catch (e) {}
    try { (window.dataLayer = window.dataLayer || []).push(Object.assign({ event: name }, payload)); } catch (e) {}
    try { window.dispatchEvent(new CustomEvent("spark-word:analytics", { detail: { event: name, props: payload } })); } catch (e) {}
    if (SERVER_EVENTS.indexOf(name) >= 0 && S.issue) {
      API.rpc("sw_track", Object.assign({ p_event: name, p_issue_number: S.issue.number, p_game_id: S.game ? S.game.id : null, p_props: props }, ident())).catch(() => {});
    }
  }

  /* ---------------- bootstrap / load ---------------- */
  async function bootstrap(issueNumber, opts) {
    opts = opts || {};
    const seq = (S.bootSeq = (S.bootSeq || 0) + 1);
    const params = Object.assign({ p_issue_number: issueNumber || null, p_ref: (S.entry && S.entry.ref) || "site" }, ident());
    const data = await API.rpc("sw_bootstrap", params);
    if (seq !== S.bootSeq) return data; // a newer bootstrap superseded this one — never overwrite state with stale data
    S.boot = data;
    S.activeIssueNumber = data.active_issue_number;
    S.latestIssueNumber = data.latest_issue_number;
    if (data.player) { S.player = data.player; }
    else if (getToken() && data.ok !== false) {
      // stored token no longer resolves (rotated / deleted) — fall back to guest
      S.player = null; setToken(null);
      if (!opts.silent) toast("We couldn't recognise your link — you can still play as a guest.");
    } else S.player = null;
    if (!data.ok) { S.issue = null; S.game = null; return data; }
    S.issue = data.issue;
    S.newGameMode = data.new_game_mode;
    applyGame(data.game);
    return data;
  }

  function applyGame(g) {
    S.game = g ? { id: g.id, mode: g.mode, issue_number: g.issue_number } : null;
    S.rows = g ? g.rows.slice() : [];
    S.status = g ? g.status : "idle";
    S.hintAvailable = !!(g && g.hint_available);
    S.hintUsed = !!(g && g.hint_used);
    S.hint = g && g.hint ? g.hint : null;
    S.secondSpark = !!(g && g.second_spark_available);
    S.firstLetter = g && g.first_letter ? g.first_letter : null;
    S.firstLetterShown = false;
    S.completion = g && g.result ? g.result : null;
    S.current = (g && g.status === "in_progress") || !g ? (store.get(KEYS.draft + draftKey()) || "") : "";
    if (S.current.length > 5) S.current = "";
  }
  const draftKey = () => (S.game ? S.game.id : "issue-" + (S.issue ? S.issue.number : "x"));
  const saveDraft = () => { if (S.current) store.set(KEYS.draft + draftKey(), S.current); else store.del(KEYS.draft + draftKey()); };

  /* ---------------- rendering: header ---------------- */
  function renderHeader() {
    const line = $("#swIssueLine");
    if (!S.issue) { line.innerHTML = "<span>Spark Word</span>"; return; }
    line.innerHTML =
      "<span>" + NOUNC + " " + pad3(S.issue.number) + "</span>" +
      (S.issue.title ? "<span class='sep'>·</span><span>" + esc(S.issue.title) + "</span>" : "") +
      (S.issue.date ? (DAILY ? "<span class='sep'>·</span><span>" + esc(fmtDate(S.issue.date)) + "</span>" : "<span class='sep sw-long'>·</span><span class='sw-long'>" + esc(fmtMonth(S.issue.date)) + "</span>") : "");
    document.title = "Spark Word · " + NOUNC + " " + pad3(S.issue.number) + " · TMT Spark";

    const banner = $("#swModeBanner");
    const mode = S.game ? S.game.mode : S.newGameMode;
    if (mode === "archive") {
      banner.className = "sw-mode-banner";
      banner.innerHTML = "Archive mode · doesn't affect the leaderboard" +
        (S.activeIssueNumber && S.activeIssueNumber !== S.issue.number ? " &nbsp;<button class='btn btn-ghost btn-sm' style='padding:2px 8px;font-size:11px' data-sw-issue='" + S.activeIssueNumber + "'>Play " + (DAILY ? "today's word" : NOUN + " " + pad3(S.activeIssueNumber)) + " →</button>" : "");
      banner.hidden = false;
    } else if (mode === "preview") {
      banner.className = "sw-mode-banner preview"; banner.textContent = "Editor preview · this " + NOUN + " is not published"; banner.hidden = false;
    } else if (mode === "closed") {
      banner.className = "sw-mode-banner"; banner.textContent = "This " + NOUN + " is not open yet"; banner.hidden = false;
    } else banner.hidden = true;

    renderIdentity();
  }

  function renderIdentity() {
    const el = $("#swIdentity");
    if (!el) return;
    if (S.player) {
      const st = S.player.stats || {};
      el.innerHTML =
        "<div class='sw-identity'><span>Playing as <b>" + esc(S.player.name) + "</b>" + (S.player.company ? " · " + esc(S.player.company) : "") + "</span>" +
        (st.current_streak > 0 ? "<span class='streak'><svg aria-hidden='true'><use href='#i-bolt'/></svg>" + st.current_streak + " " + NOUN + " streak</span>" : "") +
        "<button type='button' id='swPrefsBtn'>Preferences</button></div>";
    } else {
      el.innerHTML = "<div class='sw-identity guest'><span>Playing as <b>guest</b><span class='sw-long'> · add your details after the game to be ranked</span></span>" +
        "<button type='button' id='swWhoBtn'>Got a newsletter link?</button></div>";
    }
  }

  function renderFoot() {
    const f = $("#swFoot"); if (!f || !S.issue) return;
    const n = S.issue.players_completed || 0;
    f.innerHTML = "Players " + (DAILY ? "today" : "this issue") + ": <b>" + n.toLocaleString("en-US") + "</b>" + (API.mode === "preview" ? " · <b>preview data</b>" : "");
  }

  /* ---------------- rendering: board ---------------- */
  function buildBoard() {
    const b = $("#swBoard"); if (!b || S.boardBuilt) return;
    let html = "";
    for (let r = 0; r < 6; r++) {
      html += "<div class='sw-row' role='row' data-row='" + r + "'>";
      for (let c = 0; c < 5; c++) html += "<div class='sw-tile' role='gridcell' data-r='" + r + "' data-c='" + c + "' aria-label='Row " + (r + 1) + " letter " + (c + 1) + ": empty'></div>";
      html += "</div>";
    }
    b.innerHTML = html;
    S.boardBuilt = true;
  }
  function tile(r, c) { return $(".sw-tile[data-r='" + r + "'][data-c='" + c + "']"); }
  function setTile(r, c, letter, state, animate) {
    const t = tile(r, c); if (!t) return;
    t.textContent = letter || "";
    t.className = "sw-tile" + (letter && !state ? " filled" : "") + (state ? " " + state : "");
    if (!animate) t.classList.remove("filled");
    t.setAttribute("aria-label", "Row " + (r + 1) + " letter " + (c + 1) + ": " + (letter ? letter + (state ? ", " + SEC_TXT[state] : "") : "empty"));
  }
  /* paint the whole board from state (resume / reset) — no animation */
  function paintBoard() {
    for (let r = 0; r < 6; r++) {
      const row = S.rows[r];
      for (let c = 0; c < 5; c++) {
        if (row) setTile(r, c, row.word[c], row.result[c], false);
        else if (r === S.rows.length && S.status !== "won" && S.status !== "lost") setTile(r, c, S.current[c] || "", null, false);
        else setTile(r, c, "", null, false);
      }
    }
  }
  function paintCurrent() {
    const r = S.rows.length; if (r > 5) return;
    for (let c = 0; c < 5; c++) {
      const t = tile(r, c); if (!t) continue;
      const ch = S.current[c] || "";
      const had = t.textContent;
      t.textContent = ch;
      t.className = "sw-tile" + (ch ? " filled" : "");
      if (ch && had !== ch && !REDUCED) { t.style.animation = "none"; void t.offsetWidth; t.style.animation = ""; }
      t.setAttribute("aria-label", "Row " + (r + 1) + " letter " + (c + 1) + ": " + (ch || "empty"));
    }
  }
  function shakeRow() {
    const row = $(".sw-row[data-row='" + S.rows.length + "']"); if (!row || REDUCED) return;
    row.classList.remove("shake"); void row.offsetWidth; row.classList.add("shake");
    setTimeout(() => row.classList.remove("shake"), 520);
  }
  async function animateRow(r, word, result) {
    if (REDUCED) { for (let c = 0; c < 5; c++) setTile(r, c, word[c], result[c], false); return; }
    for (let c = 0; c < 5; c++) {
      const t = tile(r, c);
      t.textContent = word[c];
      t.classList.add("flip");
      setTimeout(() => { setTile(r, c, word[c], result[c], false); t.classList.add("flip"); }, 270);
      setTimeout(() => t.classList.remove("flip"), 600);
      await sleep(130);
    }
    await sleep(480);
  }
  function bounceRow(r) {
    if (REDUCED) return;
    for (let c = 0; c < 5; c++) setTimeout(() => { const t = tile(r, c); if (t) t.classList.add("bounce"); }, c * 90);
  }

  /* ---------------- rendering: keyboard ---------------- */
  const KROWS = ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"];
  function buildKeyboard() {
    const k = $("#swKbd"); if (!k) return;
    k.innerHTML = KROWS.map((row, i) => {
      let h = "<div class='sw-krow" + (i === 1 ? " mid" : "") + "'>";
      if (i === 2) h += "<button type='button' class='sw-key wide' data-key='Enter' aria-label='Enter guess'>Enter</button>";
      h += row.split("").map((ch) => "<button type='button' class='sw-key' data-key='" + ch + "' aria-label='" + ch + "'>" + ch + "</button>").join("");
      if (i === 2) h += "<button type='button' class='sw-key wide' data-key='Backspace' aria-label='Delete letter'><svg aria-hidden='true' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='1.9' stroke-linecap='round' stroke-linejoin='round'><path d='M9 5h11a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H9l-6-7 6-7z M12 9l6 6 M18 9l-6 6'/></svg></button>";
      return h + "</div>";
    }).join("");
    k.addEventListener("click", (e) => { const b = e.target.closest("[data-key]"); if (b) { handleKey(b.getAttribute("data-key")); if (e.detail) b.blur(); } });
  }
  function keyboardStates() {
    const st = {};
    S.rows.forEach((row) => row.word.split("").forEach((ch, i) => {
      const r = row.result[i], cur = st[ch];
      if (!cur || (r === "c") || (r === "p" && cur === "a")) st[ch] = r;
    }));
    return st;
  }
  function updateKeyboard() {
    const st = keyboardStates();
    $$("#swKbd .sw-key:not(.wide)").forEach((b) => {
      const ch = b.getAttribute("data-key"), s = st[ch];
      b.className = "sw-key" + (s ? " " + s : "");
      b.setAttribute("aria-label", ch + (s ? ", " + SEC_TXT[s] : ""));
    });
    const over = S.status === "won" || S.status === "lost";
    $("#swKbd").hidden = over;
  }

  /* ---------------- input ---------------- */
  function handleKey(key) {
    if (!S.ready || S.busy || !S.issue) return;
    if (S.status === "won" || S.status === "lost") return;
    if (S.newGameMode === "closed" && !S.game) return;
    if (key === "Enter") { submitGuess(); return; }
    if (key === "Backspace") { if (S.current.length) { S.current = S.current.slice(0, -1); paintCurrent(); saveDraft(); } return; }
    if (/^[A-Za-z]$/.test(key) && S.current.length < 5) { S.current += key.toUpperCase(); paintCurrent(); saveDraft(); }
  }
  document.addEventListener("keydown", (e) => {
    if (!S.pageShown) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable)) return;
    if (TS.anyVeilOpen && TS.anyVeilOpen()) return;
    if (e.key === "Enter" || e.key === "Backspace" || /^[a-zA-Z]$/.test(e.key)) {
      if (e.key === "Enter" && t && t.tagName === "BUTTON" && !t.closest("#swKbd")) return; // let normal buttons work
      e.preventDefault(); handleKey(e.key);
    }
  });

  function announce(msg) { const l = $("#swLive"); if (l) { l.textContent = ""; setTimeout(() => { l.textContent = msg; }, 30); } }

  /* ---------------- submit ---------------- */
  async function submitGuess() {
    if (S.busy) return;
    if (S.current.length < 5) { shakeRow(); announce("Not enough letters."); toast("Five letters needed."); return; }
    S.busy = true;
    try {
      const res = await API.rpc("sw_submit_guess", Object.assign({
        p_issue_number: S.issue.number, p_guess: S.current, p_game_id: S.game ? S.game.id : null,
        p_ref: S.entry ? S.entry.ref : "site", p_user_agent: navigator.userAgent
      }, ident()));
      if (!res || !res.ok) {
        const err = res ? res.error : "unknown";
        if (err === "not_in_dictionary") { shakeRow(); announce("Not in the word list."); toast("Not in the word list."); }
        else if (err === "invalid_length") { shakeRow(); toast("Five letters needed."); }
        else if (err === "issue_not_published") toast("This " + NOUN + " isn't open yet.");
        else if (err === "no_identity") toast("Couldn't start a game — please reload the page.");
        else toast("Something went wrong — please try again.");
        return;
      }
      const firstGuess = !S.game;
      S.game = { id: res.game_id, mode: res.mode, issue_number: S.issue.number };
      if (firstGuess) { track("spark_word_started", { mode: res.mode }); if (res.mode === "archive") track("spark_word_archive_played"); renderHeader(); }
      track("spark_word_guess", { guess_number: res.guess_number });
      const rowIdx = S.rows.length;
      S.rows.push({ word: res.word, result: res.result });
      S.current = ""; store.del(KEYS.draft + "issue-" + S.issue.number); saveDraft();
      await animateRow(rowIdx, res.word, res.result);
      updateKeyboard();
      const wasAvailable = S.hintAvailable;
      S.hintAvailable = !!res.hint_available; S.hintUsed = !!res.hint_used;
      S.secondSpark = !!res.second_spark_available; if (res.first_letter) S.firstLetter = res.first_letter;
      renderHint();
      if (S.hintAvailable && !wasAvailable && !S.hintUsed) { setTimeout(() => announce("A hint is ready — Need a Spark? sits under the board."), 900); }
      announce("Guess " + res.guess_number + " of 6: " + res.word.split("").map((ch, i) => ch + " " + SEC_TXT[res.result[i]]).join(", ") + ".");
      if (res.status !== "in_progress") {
        S.status = res.status; S.completion = res.completion;
        onComplete(rowIdx);
      }
    } catch (e) {
      console.error(e);
      toast(API.mode === "none" ? "Spark Word isn't connected to its backend yet — see the README." : "Couldn't reach Spark Word — check your connection and try again.");
    } finally { S.busy = false; }
  }

  /* ---------------- clue bar: sector + hint ----------------
     Sits ABOVE the board so it is the first thing a player sees:
       [ This issue's sector · Telecommunications ]  [ Need a Spark? · unlocks after 3 guesses ●○○ ]
       locked → progress dots · ready → gold "Reveal" button (pulses once) ·
       used   → the hint text; at guess 5+ a "second spark" offers the first letter */
  function renderHint() {
    const h = $("#swHint"); if (!h) return;
    if (!S.issue) { h.innerHTML = ""; return; }
    const unlockAfter = (S.boot && S.boot.settings && S.boot.settings.hint_unlock_after) || 3;
    const secondAfter = (S.boot && S.boot.settings && typeof S.boot.settings.second_spark_after === "number") ? S.boot.settings.second_spark_after : 5;
    const sector = "<div class='sw-sector-chip'><span>" + (DAILY ? "Today's sector" : "This issue's sector") + "</span><b>" + esc(S.issue.category) + "</b></div>";
    const over = S.status === "won" || S.status === "lost";
    let pill = "", below = "";
    if (over || (S.newGameMode === "closed" && !S.game)) {
      pill = "";
    } else if (S.hintUsed && S.hint) {
      pill = "<div class='sw-spark used'><span class='sp-ico'><svg aria-hidden='true'><use href='#i-bolt'/></svg></span><span class='sp-txt'><b>Your Spark</b><small>Hint used · shown below</small></span></div>";
      let extra = "";
      if (S.firstLetterShown && S.firstLetter) extra = "<div class='sw-second'><span class='lbl'>Second spark</span>The word starts with <b class='sw-first'>" + esc(S.firstLetter) + "</b></div>";
      else if (S.secondSpark) extra = "<div class='sw-second'><button type='button' class='btn btn-outline btn-sm' id='swSecondBtn'><svg width='12' height='12' aria-hidden='true'><use href='#i-bolt'/></svg> Still stuck? Show the first letter</button></div>";
      else if (secondAfter > 0) extra = "<div class='sw-second dim'>Still stuck after guess " + secondAfter + "? A second spark will show the first letter.</div>";
      below = hintBox(S.hint, extra);
    } else {
      const n = S.rows.length;
      const dots = Array.from({ length: unlockAfter }, (_, i) => "<i class='" + (i < n ? "on" : "") + "'></i>").join("");
      if (S.hintAvailable) {
        pill = "<button type='button' class='sw-spark ready' id='swHintBtn'><span class='sp-ico'><svg aria-hidden='true'><use href='#i-bolt'/></svg></span><span class='sp-txt'><b>Need a Spark?</b><small>Your hint is ready · costs 5 points</small></span><span class='sp-go'>Reveal <svg width='12' height='12' aria-hidden='true'><use href='#i-arrow'/></svg></span></button>";
      } else {
        const left = Math.max(0, unlockAfter - n);
        pill = "<div class='sw-spark locked' role='status'><span class='sp-ico'><svg aria-hidden='true'><use href='#i-bolt'/></svg></span><span class='sp-txt'><b>Need a Spark?</b><small>" + (n === 0 ? "Hint unlocks after " + unlockAfter + " guesses" : "Hint unlocks " + (left === 1 ? "after your next guess" : "in " + left + " more guesses")) + "</small></span><span class='sp-dots' aria-hidden='true'>" + dots + "</span></div>";
      }
    }
    h.innerHTML = "<div class='sw-cluebar'>" + sector + pill + "</div>" + below;
  }
  const hintBox = (t, extra) => "<div class='sw-hint-box' role='note'><svg width='16' height='16' aria-hidden='true'><use href='#i-bolt'/></svg><div><b>Your Spark</b>" + String(t || "").split(/\n+/).map((line) => "<p>" + esc(line) + "</p>").join("") + (extra || "") + "</div></div>";
  async function useHint() {
    if (!S.game) return;
    try {
      const res = await API.rpc("sw_use_hint", Object.assign({ p_game_id: S.game.id }, ident()));
      if (res && res.ok) {
        const already = S.hintUsed;
        S.hintUsed = true; S.hint = res.hint; S.secondSpark = !!res.second_spark_available; if (res.first_letter) S.firstLetter = res.first_letter;
        if (already && S.firstLetter) { S.firstLetterShown = true; announce("Second spark: the word starts with " + S.firstLetter + "."); }
        else { track("spark_word_hint_used", { guess_count: S.rows.length }); announce("Hint: " + res.hint); }
        renderHint();
      }
      else toast(res && res.error === "locked" ? "The hint unlocks after " + (res.unlock_after || 3) + " guesses." : "No hint available for this " + NOUN + ".");
    } catch (e) { toast("Couldn't fetch the hint — try again."); }
  }

  /* ---------------- completion ---------------- */
  function onComplete(rowIdx) {
    const c = S.completion || {};
    if (S.status === "won") bounceRow(rowIdx);
    if (c.player) { S.player = c.player; }
    if (S.issue) S.issue.players_completed = c.players_completed || S.issue.players_completed;
    track(S.status === "won" ? "spark_word_completed" : "spark_word_failed", { guess_count: c.guess_count, hint_used: c.hint_used, mode: c.mode });
    announce(S.status === "won"
      ? "You got the Spark. The word was " + c.answer + ", solved in " + c.guess_count + " of 6."
      : "The Spark got away. The word was " + c.answer + ".");
    renderHeader(); renderFoot(); renderHint(); updateKeyboard();
    renderInlineResult();
    setTimeout(openResultSheet, REDUCED ? 200 : 700);
    if (S.status === "won") indexRevealedWord(S.issue.number, c.answer, c.category);
    if (S.status === "lost") indexRevealedWord(S.issue.number, c.answer, c.category);
    refreshLearningStrip();
  }

  function badgesHTML(c) {
    return (c.badges || []).map((b) => "<span class='sw-badge" + (b === "ON A ROLL" || b === "TOP OF THE GRID" ? " gold" : "") + "'>" + esc(b) + "</span>").join("");
  }
  function statsHTML(c) {
    const st = (c.player && c.player.stats) || (S.player && S.player.stats);
    if (!st) return "";
    const cells = [
      [st.games_played, "Games played"],
      [st.win_pct == null ? "—" : st.win_pct + "%", "Win rate"],
      [st.average_guesses == null ? "—" : Number(st.average_guesses).toFixed(1), "Avg guesses"],
      [st.current_streak, "Current streak"],
      [st.best_streak, "Best streak"]
    ];
    return "<div class='sw-stats'>" + cells.map((x) => "<div class='stat'><div class='sv'>" + esc(x[0]) + "</div><div class='sk'>" + x[1] + "</div></div>").join("") + "</div>";
  }
  function rankHTML(c) {
    const rk = c.rank || {};
    if (c.mode === "archive") return "<div class='sw-rank'><div><div class='rk-l'>Archive mode</div><div class='rk-v' style='font-size:1.1rem'>Not ranked — this " + NOUN + "'s official window has closed.</div></div></div>";
    if (c.mode === "preview") return "<div class='sw-rank'><div><div class='rk-l'>Editor preview</div><div class='rk-v' style='font-size:1.1rem'>Preview games are never ranked.</div></div></div>";
    if (c.flagged) return "<div class='sw-rank'><div><div class='rk-l'>Not ranked</div><div class='rk-v' style='font-size:1rem'>This game finished faster than a human could type — it counts as played but not for ranking.</div></div></div>";
    if (!c.solved) return "<div class='sw-rank'><div><div class='rk-l'>Completed</div><div class='rk-v' style='font-size:1.05rem'>Counted as played · no solved score " + (DAILY ? "today" : "this issue") + "</div></div><div class='rk-pct'>" + (rk.total || 0) + " players so far</div></div>";
    if (!rk.rank) return "";
    const pct = rk.percentile <= 50 ? "<div class='rk-pct'>Top " + rk.percentile + "%</div>" : "<div class='rk-pct' style='color:var(--celadon)'>" + rk.solved_total + " solved so far</div>";
    return "<div class='sw-rank'><div><div class='rk-l'>You rank</div><div class='rk-v'>#" + rk.rank + " <small>of " + rk.total + "</small></div></div>" + pct + "</div>";
  }
  function teaserHTML(c) {
    const nxt = c.next_issue;
    const isSub = !!(c.newsletter_subscriber || (S.player && S.player.newsletter_subscriber));
    return "<div class='sw-teaser'><div><div class='t-l'>" + (DAILY ? "Tomorrow's Spark Word" + (nxt ? " · " + NOUNC + " " + pad3(nxt.number) : "") : "Next Spark Word drops with " + (nxt ? "Issue " + pad3(nxt.number) : "the next issue")) + "</div>" +
      (nxt && nxt.date ? "<div class='dim-t' style='font-size:12px;margin-top:3px'>" + esc(fmtDate(nxt.date)) + "</div>" : "") + "</div>" +
      (isSub ? "<p>You're in. We'll see you next issue.</p>" : "<p>Subscribe to TMT Spark so you don't miss it.</p><button class='btn btn-outline btn-sm' type='button' data-join>Subscribe free</button>") + "</div>";
  }
  function learnHTML(c) {
    if (!c.learn) return "";
    const l = c.learn, label = l.type === "glossary" ? "Read “" + esc(l.ref) + "” in the glossary" : l.type === "explainer" ? "Explain it: " + esc(l.ref) : "Read the story in Insights";
    return "<button type='button' class='sw-learn' data-sw-learn='" + esc(l.type) + "' data-sw-ref='" + esc(l.ref) + "'><svg width='13' height='13' aria-hidden='true'><use href='#i-grad'/></svg>" + label + "</button>";
  }
  function resultBodyHTML(c, sheet) {
    const won = !!c.solved, n = c.guess_count;
    let h = "<div class='" + (sheet ? "sw-res-head" : "") + "'>";
    h += "<p class='r-eyebrow'>" + (won ? "You got the Spark." : "The Spark got away.") + "</p>";
    if (!won) h += "<p class='dim-t' style='margin:0 0 6px;font-size:13px'>This issue's word was</p>";
    h += "<p class='r-word'>" + esc(c.answer) + "</p>";
    h += "<div class='r-line'>" + (won ? "<span>Solved in " + n + "/6</span>" : "<span>Not solved · 6/6 used</span>") +
      (c.hint_used ? "<span class='dim-t'>· hint used</span>" : "") + "<span class='tag'>" + esc(c.category) + "</span>" + badgesHTML(c) + "</div></div>";
    h += "<p class='r-exp'>" + esc(c.explanation) + (c.definition && c.definition !== c.explanation ? " <b>In short:</b> " + esc(c.definition) : "") + "</p>";
    h += rankHTML(c);
    h += statsHTML(c);
    h += "<div class='r-actions'>";
    h += "<button type='button' class='btn btn-primary btn-sm' data-sw-share='share'><svg width='13' height='13' aria-hidden='true'><use href='#i-send'/></svg> Share result</button>";
    h += "<button type='button' class='btn btn-outline btn-sm' data-sw-share='copy'>Copy result</button>";
    h += "<button type='button' class='btn btn-ghost btn-sm' data-sw-share='link'>Copy game link</button>";
    h += "<button type='button' class='btn btn-outline btn-sm' data-sw-open-view='leaderboard'>View leaderboard <svg class='arr' width='13' height='13' aria-hidden='true'><use href='#i-arrow'/></svg></button>";
    h += learnHTML(c);
    if (!sheet) h += "<button type='button' class='btn btn-ghost btn-sm' data-sw-replay title='Play this " + NOUN + " again for fun'>Replay in archive mode</button>";
    h += "</div>";
    if (!S.player && c.mode === "official") {
      h += "<div class='sw-teaser' style='border-top-color:rgba(77,163,255,.3)'><div><div class='t-l' style='color:var(--spark)'>Get on the leaderboard</div></div><p>Add your name and company once — your rank for " + (DAILY ? "today" : "this issue") + " is waiting.</p><button type='button' class='btn btn-primary btn-sm' data-sw-claim>Claim my rank</button></div>";
    }
    h += teaserHTML(c);
    return h;
  }
  function renderInlineResult() {
    const el = $("#swResult"); if (!el || !S.completion) return;
    el.className = "sw-result sw-res" + (S.completion.solved ? "" : " fail");
    el.innerHTML = resultBodyHTML(S.completion, false);
    el.hidden = false;
  }
  function openResultSheet() {
    const v = $("#swResultVeil"), sheet = $("#swResultSheet"); if (!v || !S.completion) return;
    sheet.className = "sheet sw-sheet sw-res" + (S.completion.solved ? "" : " fail");
    sheet.innerHTML = "<button class='x' data-close='swResultVeil' aria-label='Close'>✕</button>" + resultBodyHTML(S.completion, true);
    TS.openVeil("swResultVeil");
    setTimeout(() => { const b = sheet.querySelector(".r-actions .btn"); if (b) b.focus(); }, 80);
  }

  /* ---------------- share ---------------- */
  function shareText() {
    const c = S.completion || {};
    const grid = S.rows.map((r) => r.result.split("").map((ch) => ch === "c" ? "🟦" : ch === "p" ? "🟨" : "⬛").join("")).join("\n");
    const score = (c.solved ? S.rows.length : "X") + "/6";
    let line = "";
    if (c.mode === "archive") line = "Archive mode.";
    else if (c.rank && c.rank.rank) line = c.rank.percentile <= 50 ? "Top " + c.rank.percentile + "% " + (DAILY ? "today" : "this issue") + "." : "#" + c.rank.rank + " of " + c.rank.total + " " + (DAILY ? "today" : "this issue") + ".";
    return ["TMT SPARK WORD · " + NOUNU + " " + pad3(S.issue.number) + " ⚡", score + (c.hint_used ? " · with a Spark" : ""), grid, line, "Can you beat me?", gameUrl()].filter(Boolean).join("\n");
  }
  async function share(kind) {
    if (kind === "link") { copy(gameUrl(), "Game link copied."); track("spark_word_shared", { method: "link" }); return; }
    const text = shareText();
    if (kind === "share" && navigator.share) {
      try { await navigator.share({ text }); track("spark_word_shared", { method: "native" }); return; } catch (e) { if (e && e.name === "AbortError") return; }
    }
    copy(text, "Result copied — paste it anywhere."); track("spark_word_shared", { method: "copy" });
  }
  function copy(text, okMsg) {
    const done = () => toast(okMsg);
    const legacy = () => {
      try { const ta = document.createElement("textarea"); ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0"; document.body.appendChild(ta); ta.select(); const ok = document.execCommand("copy"); document.body.removeChild(ta); ok ? done() : toast("Copy blocked — select the text manually."); }
      catch (e) { toast("Copy blocked — select the text manually."); }
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, legacy); else legacy();
  }

  /* ---------------- claim profile (guests) ---------------- */
  function openClaim() {
    const sheet = $("#swClaimSheet"); if (!sheet) return;
    track("spark_word_claim_opened");
    sheet.innerHTML =
      "<button class='x' data-close='swClaimVeil' aria-label='Close'>✕</button>" +
      "<h3>Claim your <span style='font-style:italic;color:var(--spark)'>rank</span></h3>" +
      "<p style='color:var(--mut);font-size:14px;margin:0'>Once, not every " + NOUN + ". Your email stays private — the leaderboard only shows the name you choose and your company.</p>" +
      "<form class='form-grid' id='swClaimForm' novalidate>" +
      "<div><label for='swcEmail'>Work email</label><input id='swcEmail' name='email' type='email' autocomplete='email' placeholder='you@company.com' required></div>" +
      "<div style='display:grid;grid-template-columns:1fr 1fr;gap:12px'><div><label for='swcFirst'>First name</label><input id='swcFirst' name='first' type='text' autocomplete='given-name' value='" + esc((S.entry && S.entry.first) || "") + "' required></div>" +
      "<div><label for='swcLast'>Last name</label><input id='swcLast' name='last' type='text' autocomplete='family-name'></div></div>" +
      "<div><label for='swcCompany'>Company</label><input id='swcCompany' name='company' type='text' autocomplete='organization' placeholder='Turner & Townsend' value='" + esc((S.entry && S.entry.company) || "") + "' required></div>" +
      "<div><label>Show me on leaderboards as</label><div class='radio-row'>" +
      "<label><input type='radio' name='vis' value='first_last_initial' checked> First name + last initial (Sarah M.)</label>" +
      "<label><input type='radio' name='vis' value='full_name'> Full name</label>" +
      "<label><input type='radio' name='vis' value='anonymous'> Anonymous</label></div></div>" +
      "<p class='sw-claim-note' id='swClaimErr' role='alert'></p>" +
      "<button class='btn btn-primary' type='submit' style='margin-top:4px'>Put me on the leaderboard</button>" +
      "</form>" +
      "<p class='sw-claim-note'>Already a TMT Spark subscriber? Use the personal link in your newsletter, or enter the same email and we'll send a one-time verification link.</p>";
    $("#swResultVeil").classList.remove("on");
    TS.openVeil("swClaimVeil");
    setTimeout(() => $("#swcEmail").focus(), 80);
  }
  async function submitClaim(form) {
    const f = new FormData(form);
    const err = $("#swClaimErr"); err.textContent = "";
    const payload = {
      p_guest_id: getGuestId(), p_email: (f.get("email") || "").trim(), p_first_name: (f.get("first") || "").trim(),
      p_last_name: (f.get("last") || "").trim() || null, p_company: (f.get("company") || "").trim(),
      p_visibility: f.get("vis") || "first_last_initial", p_game_id: S.game ? S.game.id : null
    };
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(payload.p_email)) { err.textContent = "Please enter a valid work email."; return; }
    if (!payload.p_first_name) { err.textContent = "First name is required."; return; }
    if (!payload.p_company) { err.textContent = "Company is required."; return; }
    const btn = form.querySelector("button[type=submit]"); btn.disabled = true;
    try {
      const res = await API.rpc("sw_claim_profile", payload);
      if (!res || !res.ok) {
        const msgs = { invalid_email: "Please enter a valid work email.", first_name_required: "First name is required.", company_required: "Company is required." };
        err.textContent = msgs[res && res.error] || "Couldn't save that — please try again."; return;
      }
      if (res.status === "created") {
        setToken(res.token); S.player = res.player;
        toast("Welcome, " + payload.p_first_name + " — you're on the leaderboard.");
        TS.closeVeil("swClaimVeil");
        await reloadState(); openResultSheet();
        return;
      }
      if (res.status === "verify_required") {
        store.set(KEYS.pending, JSON.stringify({ guest: getGuestId(), game: payload.p_game_id, first: payload.p_first_name, last: payload.p_last_name, company: payload.p_company, vis: payload.p_visibility, email: payload.p_email, issue: S.issue.number }));
        await startVerification(payload.p_email);
      }
    } catch (e) { console.error(e); err.textContent = "Couldn't reach Spark Word — please try again."; }
    finally { btn.disabled = false; }
  }
  function verifyRedirectUrl() {
    const base = siteUrl();
    const file = /\.html?$/.test(base) ? base : base + "/index.html";
    return file + "?issue=" + S.issue.number + "&verify=1";
  }
  async function startVerification(email) {
    const sheet = $("#swClaimSheet");
    if (API.mode === "supabase") {
      const { error } = await API.client.auth.signInWithOtp({ email, options: { emailRedirectTo: verifyRedirectUrl(), shouldCreateUser: true } });
      if (error) { $("#swClaimErr").textContent = "Couldn't send the verification email (" + error.message + ")."; return; }
    }
    sheet.innerHTML = "<button class='x' data-close='swClaimVeil' aria-label='Close'>✕</button>" +
      "<div class='sw-verify'><span class='ok'><svg width='24' height='24' aria-hidden='true'><use href='#i-send'/></svg></span>" +
      "<h4>Check your email</h4><p><b style='color:var(--ink)'>" + esc(email) + "</b> is already a TMT Spark subscriber, so we've sent a one-time link to confirm it's you. Open it on this device and your rank for " + NOUNC + " " + pad3(S.issue.number) + " attaches automatically.</p>" +
      (API.mode === "preview" ? "<p style='margin-top:14px'><button type='button' class='btn btn-outline btn-sm' id='swPreviewVerify'>Preview: simulate clicking the link</button></p>" : "") + "</div>";
  }
  async function completeVerification() {
    const raw = store.get(KEYS.pending); if (!raw) return false;
    let p; try { p = JSON.parse(raw); } catch (e) { store.del(KEYS.pending); return false; }
    try {
      const res = await API.rpc("sw_verified_link", { p_guest_id: p.guest, p_first_name: p.first, p_last_name: p.last, p_company: p.company, p_visibility: p.vis, p_game_id: p.game });
      if (res && res.ok) {
        setToken(res.token); S.player = res.player; store.del(KEYS.pending);
        if (API.mode === "supabase") { try { await API.client.auth.signOut(); } catch (e) {} }
        toast("Verified — welcome back, " + (res.player.first_name || "") + ".");
        return true;
      }
    } catch (e) { console.error(e); }
    return false;
  }

  /* ---------------- preferences ---------------- */
  function openPrefs() {
    const sheet = $("#swProfileSheet"); if (!sheet || !S.player) return;
    const v = S.player.visibility || "first_last_initial";
    sheet.innerHTML = "<button class='x' data-close='swProfileVeil' aria-label='Close'>✕</button>" +
      "<h3>Leaderboard <span style='font-style:italic;color:var(--spark)'>preferences</span></h3>" +
      "<p style='color:var(--mut);font-size:14px;margin:0'>You're playing as <b style='color:var(--ink)'>" + esc(S.player.name) + "</b>" + (S.player.company ? " · " + esc(S.player.company) : "") + ". Your email is never shown.</p>" +
      "<form class='form-grid' id='swPrefsForm'><div><label>Show me as</label><div class='radio-row'>" +
      ["first_last_initial|First name + last initial", "full_name|Full name", "anonymous|Anonymous"].map((o) => { const [val, lab] = o.split("|"); return "<label><input type='radio' name='vis' value='" + val + "'" + (v === val ? " checked" : "") + "> " + lab + "</label>"; }).join("") +
      "</div></div><button class='btn btn-primary btn-sm' type='submit' style='align-self:flex-start'>Save</button></form>" +
      "<p class='sw-claim-note'>Not you? <button type='button' class='btn btn-ghost btn-sm' id='swForget' style='padding:2px 8px'>Play as someone else</button></p>";
    TS.openVeil("swProfileVeil");
  }
  async function savePrefs(form) {
    const vis = new FormData(form).get("vis");
    try {
      const res = await API.rpc("sw_update_profile", { p_token: getToken(), p_visibility: vis });
      if (res && res.ok) { S.player = res.player; renderIdentity(); toast("Saved — leaderboards now show " + res.player.name + "."); TS.closeVeil("swProfileVeil"); }
      else toast("Couldn't save that preference.");
    } catch (e) { toast("Couldn't reach Spark Word — try again."); }
  }
  function openWho() {
    const sheet = $("#swProfileSheet"); if (!sheet) return;
    sheet.innerHTML = "<button class='x' data-close='swProfileVeil' aria-label='Close'>✕</button>" +
      "<h3>Play as <span style='font-style:italic;color:var(--spark)'>you</span></h3>" +
      "<p style='color:var(--mut);font-size:14px;margin:0 0 6px'>Every TMT Spark newsletter carries a personal <b style='color:var(--ink)'>Play Spark Word</b> link. Open it from your email and we'll recognise you here — no account, no password. Or just play now as a guest and add your details after the game.</p>" +
      "<div class='hero-ctas' style='margin:18px 0 0'><button type='button' class='btn btn-primary btn-sm' data-close='swProfileVeil'>Play as guest</button><button type='button' class='btn btn-outline btn-sm' data-join>Subscribe to get a link</button></div>";
    TS.openVeil("swProfileVeil");
  }

  /* ---------------- onboarding / how to play ---------------- */
  const howtoHTML = () =>
    "<div class='sw-howto'>" +
    "<div class='hrow c'><div class='sw-tile c'>F</div><p><b>Blue</b>Right letter. Right place.</p></div>" +
    "<div class='hrow p'><div class='sw-tile p'>I</div><p><b>Gold</b>Right letter. Wrong place.</p></div>" +
    "<div class='hrow a'><div class='sw-tile a'>Z</div><p><b>Gray</b>Not in the word.</p></div></div>" +
    "<p class='sw-howto-note'>Guess the five-letter TMT term in six tries. " + (DAILY ? "Every day brings a new word from the industries TMT Spark covers — AI, data centers, semiconductors, telecom, media, digital infrastructure and the power behind them." : "Every TMT Spark issue brings a new word from the industries we work in — data centers, power, semiconductors, telecom, media, construction and the people who build them.") + " Stuck? <b style='color:var(--wheat)'>Need a Spark?</b> above the board unlocks a hint after " + numWord(hintAfter()) + " guess" + (hintAfter() === 1 ? "" : "es") + " (solving without it ranks higher)" + (secondAfter() > 0 ? ", and a second spark reveals the first letter if you're still stuck at guess " + numWord(secondAfter()) : "") + ". Fewest guesses wins; " + (DAILY ? "streaks count consecutive days played." : "streaks are counted in issues, not days.") + "</p>";
  function openOnboarding() {
    const sheet = $("#swOnboardSheet"); if (!sheet) return;
    sheet.innerHTML = "<button class='x' data-close='swOnboardVeil' aria-label='Close'>✕</button>" +
      "<p class='eyebrow' style='margin-bottom:10px'>Spark Word</p><h3>How to play</h3>" + howtoHTML() +
      "<button type='button' class='btn btn-primary' id='swStartBtn'>Start playing <svg class='arr' width='14' height='14' aria-hidden='true'><use href='#i-arrow'/></svg></button>";
    TS.openVeil("swOnboardVeil");
    track("spark_word_onboarding_seen");
    setTimeout(() => { const b = $("#swStartBtn"); if (b) b.focus(); }, 80);
  }
  function markOnboarded() { store.set(KEYS.onboarded, "1"); }

  /* ---------------- views: tabs, leaderboard, archive ---------------- */
  function setHash(view) {
    if (!S.pageShown) return;
    try { history.replaceState(null, "", "#" + PAGE_ID + (view ? "/" + view : "")); } catch (e) {}
  }
  function openView(view, scroll) {
    const same = S.view === view;
    S.view = same ? null : view;
    $$("#swTabs button").forEach((b) => b.classList.toggle("on", b.getAttribute("data-view") === S.view));
    $$(".sw-view").forEach((v) => v.classList.toggle("on", v.id === "swView-" + S.view));
    setHash(S.view);
    if (!S.view) return;
    if (S.view === "leaderboard") loadLeaderboard(S.lbTab || "issue");
    if (S.view === "archive") loadArchive();
    if (S.view === "howto") { const h = $("#swHowtoBody"); if (h && !h.innerHTML) h.innerHTML = howtoHTML(); }
    if (scroll !== false) setTimeout(() => { const el = $("#swView-" + S.view); if (el) el.scrollIntoView({ behavior: REDUCED ? "auto" : "smooth", block: "start" }); }, 60);
  }

  const fmtTime = (s) => s == null ? "—" : (s < 60 ? s + "s" : Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"));
  const fmtDate = (d) => { try { return new Date(d + "T12:00:00").toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }); } catch (e) { return d; } };
  const fmtMonth = (d) => { try { return new Date(d + "T12:00:00").toLocaleDateString("en-US", { month: "long", year: "numeric" }); } catch (e) { return d; } };

  async function loadLeaderboard(tab) {
    S.lbTab = tab;
    $$("#swLbTabs button").forEach((b) => b.classList.toggle("on", b.getAttribute("data-lb") === tab));
    const body = $("#swLbBody"); body.innerHTML = "<div class='sw-empty'>Loading…</div>";
    try {
      if (tab === "issue") await renderIssueBoard(body);
      else if (tab === "allstars") await renderAllStars(body);
      else await renderCompanies(body);
      track("spark_word_leaderboard_viewed", { board: tab });
      renderShareout();
    } catch (e) { console.error(e); body.innerHTML = "<div class='sw-empty'>Couldn't load the leaderboard — try again in a moment.</div>"; }
  }
  async function renderIssueBoard(body) {
    const n = S.issue ? S.issue.number : null;
    const d = await API.rpc("sw_issue_leaderboard", Object.assign({ p_issue_number: n, p_limit: 10 }, ident()));
    if (!d.ok) { body.innerHTML = "<div class='sw-empty'>No leaderboard yet.</div>"; return; }
    let h = "<div class='sec-head' style='margin-bottom:16px'><p class='eyebrow'>" + NOUNC + " " + pad3(d.issue.number) + " leaderboard</p>" +
      "<p class='lede' style='font-size:14px'>" + d.total_players.toLocaleString("en-US") + " players · " + (d.solved_pct == null ? "—" : d.solved_pct + "%") + " solved · ranked by fewest guesses, then no hint, then time.</p></div>";
    h += "<span class='lbl'>Top 10</span>";
    if (!d.top.length) h += "<div class='sw-table-wrap'><div class='sw-empty'>No one has solved " + (DAILY ? "today's word" : "this issue") + " yet — be the first.</div></div>";
    else h += "<div class='sw-table-wrap'><table class='sw-table'><thead><tr><th>Rank</th><th>Player</th><th>Company</th><th class='num'>Guesses</th><th class='num'>Time</th><th class='num'>Streak</th></tr></thead><tbody>" +
      d.top.map((r) => "<tr" + (r.is_me ? " class='me'" : "") + "><td class='n'>" + r.rank + "</td><td class='pl'>" + esc(r.name) + "</td><td>" + esc(r.company || "—") + "</td><td class='num'>" + r.guesses + "/6" + (r.hint_used ? "<span class='hintmark' title='Hint used'>+HINT</span>" : "") + "</td><td class='num'>" + fmtTime(r.seconds) + "</td><td class='num'>" + (r.streak ? "🔥 " + r.streak : "—") + "</td></tr>").join("") +
      "</tbody></table></div>";
    if (d.me && d.me.rank) h += "<div class='sw-you'><span class='lbl'>Your position</span><span class='yv'>#" + d.me.rank + " <small>of " + d.me.total + "</small></span>" + (d.me.percentile <= 50 ? "<span class='ypct'>Top " + d.me.percentile + "%</span>" : "") + "</div>";
    else if (d.me) h += "<div class='sw-you'><span class='lbl'>Your position</span><span class='yv' style='font-size:1rem'>" + (d.me.flagged ? "Not ranked (flagged)" : "Completed · unranked (not solved)") + "</span></div>";
    else if (S.status === "in_progress" || S.status === "idle") h += "<div class='sw-you'><span class='lbl'>Your position</span><span class='yv' style='font-size:1rem'>Finish " + (DAILY ? "today's word" : "this issue") + " to see where you land.</span></div>";
    body.innerHTML = h;
  }
  async function renderAllStars(body) {
    S.asPeriod = S.asPeriod || "all"; S.asScope = S.asScope || "all";
    const d = await API.rpc("sw_allstars", Object.assign({ p_period: S.asPeriod, p_scope: S.asScope, p_company: S.asScope === "company" ? (S.asCompany || "") : null, p_limit: 25 }, ident()));
    const chip = (attr, val, label, on) => "<button type='button' class='chip" + (on ? " on" : "") + "' data-" + attr + "='" + val + "'>" + label + "</button>";
    let h = "<div class='sec-head' style='margin-bottom:16px'><p class='eyebrow'>Spark Word All-Stars</p><p class='lede' style='font-size:14px'>Points across " + NOUN + "s: 1 guess = 100 · 2 = 80 · 3 = 65 · 4 = 50 · 5 = 35 · 6 = 20 · hint −5 · +2 per " + NOUN + " of streak (max +20). Not who played most — who played best.</p></div>";
    h += "<div class='sw-filters'><span class='lbl'>Period</span>" + chip("as-period", "issue", DAILY ? "Today" : "This issue", S.asPeriod === "issue") + chip("as-period", "month", "This month", S.asPeriod === "month") + chip("as-period", "all", "All time", S.asPeriod === "all") + "</div>";
    h += "<div class='sw-filters'><span class='lbl'>Who</span>" + chip("as-scope", "all", "Everyone", S.asScope === "all") + chip("as-scope", "tt", "Turner & Townsend", S.asScope === "tt") + chip("as-scope", "industry", "Clients & Industry", S.asScope === "industry") + chip("as-scope", "company", "Company", S.asScope === "company") +
      (S.asScope === "company" ? "<input type='text' id='swAsCompany' placeholder='Company name…' value='" + esc(S.asCompany || "") + "' aria-label='Company filter'>" : "") + "</div>";
    if (!d.rows.length) h += "<div class='sw-table-wrap'><div class='sw-empty'>No games in this view yet.</div></div>";
    else h += "<div class='sw-table-wrap'><table class='sw-table'><thead><tr><th>Rank</th><th>Player</th><th>Company</th><th class='num'>" + NOUNC + "s</th><th class='num'>Win %</th><th class='num'>Avg guesses</th><th class='num'>Streak</th><th class='num'>Points</th></tr></thead><tbody>" +
      d.rows.map((r) => "<tr" + (r.is_me ? " class='me'" : "") + "><td class='n'>" + r.rank + "</td><td class='pl'>" + esc(r.name) + (r.is_tt ? "<span class='tt'>T&amp;T</span>" : "") + "</td><td>" + esc(r.company || "—") + "</td><td class='num'>" + r.issues_played + "</td><td class='num'>" + r.win_pct + "%</td><td class='num'>" + (r.avg_guesses == null ? "—" : Number(r.avg_guesses).toFixed(2)) + "</td><td class='num'>" + (r.current_streak ? "🔥 " + r.current_streak : "—") + "</td><td class='num' style='color:var(--ink);font-weight:600'>" + r.points + "</td></tr>").join("") +
      "</tbody></table></div>";
    if (d.me && d.me.rank) h += "<div class='sw-you'><span class='lbl'>Your position</span><span class='yv'>#" + d.me.rank + " <small>of " + d.me.total + "</small></span><span class='ypct'>" + d.me.points + " pts · streak " + d.me.current_streak + "</span></div>";
    body.innerHTML = h;
  }
  async function renderCompanies(body) {
    S.coPeriod = S.coPeriod || "all";
    const d = await API.rpc("sw_company_standings", { p_period: S.coPeriod, p_limit: 10 });
    const chip = (val, label) => "<button type='button' class='chip" + (S.coPeriod === val ? " on" : "") + "' data-co-period='" + val + "'>" + label + "</button>";
    let h = "<div class='sec-head' style='margin-bottom:16px'><p class='eyebrow'>Company standings <span class='sw-methodology'><button type='button' aria-label='How company standings are calculated' aria-expanded='false'><svg width='12' height='12' aria-hidden='true'><use href='#i-info'/></svg></button><span class='tip' role='tooltip'>" + esc(d.methodology) + "</span></span></p>" +
      "<p class='lede' style='font-size:14px'>Friendly competition between the companies reading TMT Spark — normalised so headcount doesn't win.</p></div>";
    h += "<div class='sw-filters'><span class='lbl'>Period</span>" + chip("issue", DAILY ? "Today" : "This issue") + chip("month", "This month") + chip("all", "All time") + "</div>";
    if (!d.rows.length) h += "<div class='sw-table-wrap'><div class='sw-empty'>No company has " + d.min_players + " or more players in this period yet.</div></div>";
    else h += "<div class='sw-table-wrap'><table class='sw-table'><thead><tr><th>Rank</th><th>Company</th><th class='num'>Players</th><th class='num'>Avg points / issue</th><th class='num'>Win %</th><th class='num'>Avg guesses</th></tr></thead><tbody>" +
      d.rows.map((r) => "<tr><td class='n'>" + r.rank + "</td><td class='pl'>" + esc(r.company) + "</td><td class='num'>" + r.players + "</td><td class='num' style='color:var(--ink);font-weight:600'>" + r.avg_points + "</td><td class='num'>" + r.win_pct + "%</td><td class='num'>" + (r.avg_guesses == null ? "—" : Number(r.avg_guesses).toFixed(2)) + "</td></tr>").join("") +
      "</tbody></table></div>";
    body.innerHTML = h;
  }
  async function renderShareout() {
    const el = $("#swShareout"); if (!el) return;
    try {
      const d = await API.rpc("sw_last_issue_summary", ident());
      if (!d.ok) { el.hidden = true; return; }
      S.lastIssue = d;
      const word = d.revealed ? esc(d.answer) : "<span class='dim-t' aria-label='hidden'>" + esc(d.answer_masked) + "</span><button type='button' data-sw-issue='" + d.issue.number + "' title='Play it first'>Play it first →</button>";
      el.innerHTML = "<p class='so-l'>" + (DAILY ? "Yesterday's Spark Word · Day " + pad3(d.issue.number) + " · " + esc(fmtDate(d.issue.date)) : "Last issue's Spark Word · Issue " + pad3(d.issue.number) + " · " + esc(fmtMonth(d.issue.date))) + "</p>" +
        "<p class='so-word'>" + word + "</p>" +
        "<div class='so-stats'><div>" + (d.players || 0).toLocaleString("en-US") + "<span>Players</span></div><div>" + (d.solved_pct == null ? "—" : d.solved_pct + "%") + "<span>Solved</span></div></div>" +
        (d.top && d.top.length ? "<p class='so-l'>Fastest minds</p><ol>" + d.top.map((t) => "<li><span class='on2'>" + t.rank + "</span><span>" + esc(t.name) + "</span><span class='co'>· " + esc(t.company || "") + "</span><span class='gs'>" + t.guesses + "/6</span></li>").join("") + "</ol>" : "") +
        (d.company_champion ? "<div class='so-champ'><span class='so-l' style='margin:0'>Company champion</span><b>" + esc(d.company_champion) + "</b></div>" : "") +
        "<p class='so-cta'>Think you can do better? " + (S.activeIssueNumber ? "<button type='button' data-sw-issue='" + S.activeIssueNumber + "'>Play " + (DAILY ? "today's word" : "Issue " + pad3(S.activeIssueNumber)) + " →</button>" : "") + "</p>";
      el.hidden = false;
    } catch (e) { el.hidden = true; }
  }

  async function loadArchive() {
    const list = $("#swArchiveList"); if (!list) return;
    list.innerHTML = "<div class='sw-empty'>Loading…</div>";
    try {
      const d = await API.rpc("sw_archive", ident());
      if (!d.ok || !d.issues.length) { list.innerHTML = "<div class='sw-empty'>No past " + NOUN + "s yet.</div>"; return; }
      list.innerHTML = d.issues.map((i) => {
        const my = i.my, played = my && my.status !== "in_progress";
        let status = "";
        if (played) status = "<span class='a-word'>" + esc(my.answer) + "</span><div class='a-line'>" + (my.solved ? "<b>Solved " + my.guess_count + "/6</b>" : "<b>Not solved</b>") + (my.mode === "archive" ? " · archive mode" : (my.rank ? " · #" + my.rank : "")) + (my.hint_used ? " · hint used" : "") + "</div>";
        else if (my && my.status === "in_progress") status = "<span class='a-word hidden'>· · · · ·</span><div class='a-line'>In progress · " + my.guess_count + " guess" + (my.guess_count === 1 ? "" : "es") + " so far</div>";
        else status = "<span class='a-word hidden'>· · · · ·</span><div class='a-line'>You haven't played this " + NOUN + "" + (i.is_active ? "" : " — it stays hidden until you do") + ".</div>";
        const btn = i.is_active && i.new_game_mode === "official" && !played ? "<button type='button' class='btn btn-primary btn-sm' data-sw-issue='" + i.number + "'>Play now</button>"
          : played ? "<button type='button' class='btn btn-outline btn-sm' data-sw-issue='" + i.number + "'>" + (i.is_active ? "View result" : "Replay in archive mode") + "</button>"
          : "<button type='button' class='btn btn-outline btn-sm' data-sw-issue='" + i.number + "'>" + (i.is_active ? "Continue" : "Play in archive mode") + "</button>";
        if (played) indexRevealedWord(i.number, my.answer, i.category, my.definition);
        return "<div class='sw-arch" + (i.is_active ? " active" : "") + "' id='swArch" + i.number + "'><div class='a-top'><span class='a-meta'>" + NOUNC + " " + pad3(i.number) + " · " + esc(DAILY ? fmtDate(i.date) : fmtMonth(i.date)) + (i.is_active ? " · <span class='g'>Current</span>" : "") + "</span><span class='tag'>" + esc(i.category) + "</span></div>" +
          "<h4>" + esc(i.title || "") + "</h4>" + status +
          "<div class='a-foot'>" + btn + "<span class='a-players'>" + (i.players_completed || 0).toLocaleString("en-US") + " played" + (i.solved_pct != null ? " · " + i.solved_pct + "% solved" : "") + "</span></div></div>";
      }).join("");
      S.archive = d.issues;
      refreshLearningStrip();
    } catch (e) { console.error(e); list.innerHTML = "<div class='sw-empty'>Couldn't load past words — try again in a moment.</div>"; }
  }

  /* switch the board to another issue (archive replay or back to current) */
  async function loadIssue(n) {
    if (!n) return;
    S.busy = true;
    try {
      await bootstrap(n, { silent: true });
      S.entry.ref = "archive";
      renderAll();
      if (S.game && S.game.mode === "archive" && S.status === "in_progress") track("spark_word_archive_played");
      window.scrollTo({ top: 0, behavior: REDUCED ? "auto" : "smooth" });
      if (S.view) openView(S.view, false); // keep the open tab, re-render for the new issue
      if (S.view === "leaderboard") loadLeaderboard(S.lbTab || "issue");
      $("#swView-" + (S.view || "x")) && S.view && $$(".sw-view").forEach((v) => v.classList.toggle("on", v.id === "swView-" + S.view));
    } catch (e) { toast("Couldn't load that issue."); }
    finally { S.busy = false; }
  }

  /* a fresh board for a recreational replay (server will create an archive-mode game on the first guess) */
  function startReplay() {
    if (!S.issue) return;
    S.game = null; S.rows = []; S.current = ""; S.status = "idle"; S.completion = null;
    S.hintAvailable = false; S.hintUsed = false; S.hint = null; S.newGameMode = "archive";
    renderAll(); $("#swKbd").hidden = false;
    window.scrollTo({ top: 0, behavior: REDUCED ? "auto" : "smooth" });
    announce("New archive game started. This one doesn't affect the leaderboard.");
  }

  /* ---------------- learning + search integration ---------------- */
  function indexRevealedWord(n, word, category, definition) {
    if (!TS.INDEX || !word) return;
    const key = "w" + n; if (S.indexed[key]) return; S.indexed[key] = 1;
    TS.INDEX.push({ t: word + " — " + NOUNC + " " + pad3(n) + (category ? " · " + category : ""), sub: "Spark Word", type: "Spark Word", icon: "i-bolt",
      act: () => { TS.showPage(PAGE_ID); setTimeout(() => { openView("archive"); setTimeout(() => { const el = $("#swArch" + n); if (el && TS.flashEl) TS.flashEl(el); }, 400); }, 120); } });
  }
  function indexStatic() {
    if (!TS.INDEX || S.indexed.static) return; S.indexed.static = 1;
    TS.INDEX.push({ t: "Spark Word" + (S.issue ? " — " + NOUNC + " " + pad3(S.issue.number) : ""), sub: "Play", type: "Spark Word", icon: "i-bolt", act: () => TS.showPage(PAGE_ID) });
    TS.INDEX.push({ t: "Spark Word leaderboard", sub: "All-Stars · companies", type: "Spark Word", icon: "i-chart", act: () => { TS.showPage(PAGE_ID); setTimeout(() => openView("leaderboard"), 120); } });
    TS.INDEX.push({ t: "Past Spark Words", sub: "Archive", type: "Spark Word", icon: "i-book", act: () => { TS.showPage(PAGE_ID); setTimeout(() => openView("archive"), 120); } });
    TS.INDEX.push({ t: "How to play Spark Word", sub: "Rules", type: "Spark Word", icon: "i-info", act: () => { TS.showPage(PAGE_ID); setTimeout(() => openView("howto"), 120); } });
  }
  /* "Words you've cracked" strip inside the Spark Learning glossary */
  function refreshLearningStrip() {
    const strip = $("#swLearnStrip"); if (!strip) return;
    const words = (S.archive || []).filter((i) => i.my && i.my.status !== "in_progress" && i.my.answer).map((i) => ({ n: i.number, w: i.my.answer, d: i.my.definition || i.my.explanation }));
    if (S.completion && S.issue && !words.some((x) => x.n === S.issue.number)) words.unshift({ n: S.issue.number, w: S.completion.answer, d: S.completion.definition || S.completion.explanation });
    if (!words.length) { strip.hidden = true; return; }
    strip.hidden = false;
    strip.innerHTML = "<span class='lbl'>From Spark Word — terms you've cracked</span><div class='chips'>" +
      words.map((x) => "<button type='button' class='chip sw-word' data-sw-def='" + esc(x.d || "") + "' data-sw-w='" + esc(x.w) + "' data-sw-n='" + x.n + "'>" + esc(x.w) + "</button>").join("") + "</div>";
  }
  function goLearn(type, ref) {
    if (!TS.showPage) return;
    if (type === "glossary") {
      TS.showPage("learning");
      setTimeout(() => { const c = $$("#glossChips .chip").find((x) => x.textContent === ref); if (c) { c.click(); TS.flashEl && TS.flashEl($("#glDef")); } }, 200);
    } else if (type === "explainer") {
      const hit = (TS.INDEX || []).find((x) => x.type === "Explainers" && x.t === ref);
      if (hit) hit.act(); else TS.showPage("explain");
    } else if (type === "story") {
      TS.goToEl ? TS.goToEl("insights", ref, (el) => el.classList.add("open")) : TS.showPage("insights");
    }
  }

  /* ---------------- home promo + newsletter CTAs ---------------- */
  function renderPromo() {
    const n = S.activeIssueNumber || S.latestIssueNumber;
    $$("[data-sw-issue-number]").forEach((el) => { el.textContent = n ? pad3(n) : "—"; });
    const note = $("#swPromoNote");
    if (note && S.lastIssue && S.lastIssue.players) note.innerHTML = "<b>" + S.lastIssue.players.toLocaleString("en-US") + " people</b> played " + (DAILY ? "yesterday" : "last issue") + ". Can you make the Top 10?";
  }
  async function primePromo() {
    try {
      if (S.firstBoot) await S.firstBoot;                 // the game page is already loading — never race it
      if (!S.boot && !S.pageShown) await bootstrap(null, { silent: true });
      if (!S.lastIssue) { const d = await API.rpc("sw_last_issue_summary", ident()); if (d && d.ok) S.lastIssue = d; }
    } catch (e) {}
    renderPromo();
  }

  /* ---------------- page lifecycle ---------------- */
  function renderAll() {
    buildBoard(); renderHeader(); paintBoard(); updateKeyboard(); renderHint(); renderFoot();
    const panel = $("#swPanel"), res = $("#swResult");
    if (!S.issue) {
      if (!S.boot) { panel.hidden = true; return; }       // nothing loaded yet — don't flash an empty-state panel
      panel.hidden = false;
      const err = S.boot && S.boot.error;
      panel.innerHTML = err === "issue_not_published" ? "<h3>This " + NOUN + " isn't open yet.</h3><p>" + (DAILY ? "That word unlocks at midnight. Play today's in the meantime." : "The Spark Word for that issue goes live with the newsletter. Play the current issue in the meantime.") + "</p>" + (S.activeIssueNumber ? "<button class='btn btn-primary btn-sm' data-sw-issue='" + S.activeIssueNumber + "'>Play " + (DAILY ? "today's word" : "Issue " + pad3(S.activeIssueNumber)) + "</button>" : "")
        : "<h3>No Spark Word is live right now.</h3><p>" + (DAILY ? "Come back tomorrow for the next word." : "The next word drops with the next issue of TMT Spark.") + "</p><button class='btn btn-outline btn-sm' data-join>Subscribe free</button>";
      $("#swBoard").hidden = true; $("#swKbd").hidden = true; res.hidden = true;
      return;
    }
    panel.hidden = true; $("#swBoard").hidden = false;
    if (API.mode === "preview" && !$("#swPreviewBanner")) {
      const b = document.createElement("div"); b.id = "swPreviewBanner"; b.className = "sw-preview-banner";
      b.innerHTML = CFG.previewBanner || ("<b>Design preview</b> — sample data, nothing is saved." + (CFG.configHint === false ? "" : "<span class='sw-long'> Not connected to Supabase yet: add credentials in <code>" + (CFG.configHint || "assets/spark-word-config.js") + "</code>.</span>"));
      $("#swStage").insertBefore(b, $("#swStage").firstChild);
    }
    if (S.completion) renderInlineResult(); else res.hidden = true;
    if (S.newGameMode === "closed" && !S.game) { $("#swKbd").hidden = true; }
    indexStatic(); renderPromo();
  }

  async function onPageShown() {
    S.pageShown = true;
    const wanted = S.entry.issue;
    try {
      const fresh = S.boot && S.issue && (!wanted || S.issue.number === wanted) && (Date.now() - (S.bootAt || 0) < 60000);
      if (!fresh) { S.firstBoot = bootstrap(wanted, {}); await S.firstBoot; S.firstBoot = null; S.bootAt = Date.now(); }
      S.ready = true;
      renderAll();
      track("spark_word_viewed", { ref: S.entry.ref });
      if (!store.get(KEYS.onboarded)) openOnboarding();
      if (S.entry.view) { const v = S.entry.view; S.entry.view = null; setTimeout(() => openView(v === "how-to-play" ? "howto" : v), 150); }
      if (S.entry.wantsClaim) { S.entry.wantsClaim = false; }
    } catch (e) {
      console.error(e);
      S.ready = false;
      const panel = $("#swPanel");
      panel.hidden = false;
      panel.innerHTML = API.mode === "none"
        ? "<h3>Spark Word isn't connected yet.</h3><p>Add your Supabase URL and anon key to <code>" + (CFG.configHint || "assets/spark-word-config.js") + "</code> (see README) — or open the site with the preview adapter loaded to review the design.</p>"
        : "<h3>Couldn't reach Spark Word.</h3><p>Check your connection and try again.</p><button class='btn btn-outline btn-sm' id='swRetry'>Retry</button>";
      $("#swBoard").hidden = true; $("#swKbd").hidden = true;
    }
  }
  async function reloadState() {
    await bootstrap(S.issue ? S.issue.number : null, { silent: true });
    S.bootAt = Date.now();
    renderAll();
  }

  /* ---------------- event wiring ---------------- */
  document.addEventListener("click", (e) => {
    const t = e.target;
    const hintBtn = t.closest("#swHintBtn"); if (hintBtn) { useHint(); return; }
    const secondBtn = t.closest("#swSecondBtn"); if (secondBtn) { if (S.firstLetter) { S.firstLetterShown = true; renderHint(); announce("Second spark: the word starts with " + S.firstLetter + "."); } else useHint(); return; }
    const tab = t.closest("#swTabs [data-view]"); if (tab) { openView(tab.getAttribute("data-view")); return; }
    const lb = t.closest("#swLbTabs [data-lb]"); if (lb) { loadLeaderboard(lb.getAttribute("data-lb")); return; }
    const ov = t.closest("[data-sw-open-view]"); if (ov) { $$(".veil.on").forEach((v) => TS.closeVeil(v.id)); if (S.view !== ov.getAttribute("data-sw-open-view")) openView(ov.getAttribute("data-sw-open-view")); else { const el = $("#swView-" + S.view); el && el.scrollIntoView({ behavior: REDUCED ? "auto" : "smooth" }); } return; }
    const sh = t.closest("[data-sw-share]"); if (sh) { share(sh.getAttribute("data-sw-share")); return; }
    const cl = t.closest("[data-sw-claim]"); if (cl) { openClaim(); return; }
    const pv = t.closest("#swPreviewVerify"); if (pv && window.SparkWordPreview) { window.SparkWordPreview.simulateVerifiedSession(JSON.parse(store.get(KEYS.pending) || "{}").email); completeVerification().then((ok) => { if (ok) { TS.closeVeil("swClaimVeil"); reloadState().then(openResultSheet); } }); return; }
    const pr = t.closest("#swPrefsBtn"); if (pr) { openPrefs(); return; }
    const who = t.closest("#swWhoBtn"); if (who) { openWho(); return; }
    const fg = t.closest("#swForget"); if (fg) { setToken(null); store.del(KEYS.guest); S.player = null; TS.closeVeil("swProfileVeil"); reloadState(); toast("Playing as a guest now."); return; }
    const st = t.closest("#swStartBtn"); if (st) { markOnboarded(); TS.closeVeil("swOnboardVeil"); return; }
    const onbX = t.closest("#swOnboardSheet .x"); if (onbX) { markOnboarded(); return; }
    const ap = t.closest("[data-as-period]"); if (ap) { S.asPeriod = ap.getAttribute("data-as-period"); loadLeaderboard("allstars"); return; }
    const as = t.closest("[data-as-scope]"); if (as) { S.asScope = as.getAttribute("data-as-scope"); loadLeaderboard("allstars"); return; }
    const cp = t.closest("[data-co-period]"); if (cp) { S.coPeriod = cp.getAttribute("data-co-period"); loadLeaderboard("companies"); return; }
    const mth = t.closest(".sw-methodology button"); if (mth) { const w = mth.parentElement; w.classList.toggle("open"); mth.setAttribute("aria-expanded", w.classList.contains("open") ? "true" : "false"); return; }
    const iss = t.closest("[data-sw-issue]"); if (iss) { $$(".veil.on").forEach((v) => TS.closeVeil(v.id)); if (!S.pageShown) { TS.showPage(PAGE_ID); } loadIssue(parseInt(iss.getAttribute("data-sw-issue"), 10)); return; }
    const ln = t.closest("[data-sw-learn]"); if (ln) { $$(".veil.on").forEach((v) => TS.closeVeil(v.id)); goLearn(ln.getAttribute("data-sw-learn"), ln.getAttribute("data-sw-ref")); return; }
    const def = t.closest("[data-sw-def]"); if (def) { const box = $("#glDef"); if (box) { $$("#glossChips .chip, #swLearnStrip .chip").forEach((c) => c.classList.toggle("on", c === def)); box.innerHTML = "<b>" + esc(def.getAttribute("data-sw-w")) + " · Spark Word, " + NOUNC + " " + pad3(def.getAttribute("data-sw-n")) + "</b>" + esc(def.getAttribute("data-sw-def")); box.classList.add("on"); } return; }
    const rt = t.closest("#swRetry"); if (rt) { onPageShown(); return; }
    const rp = t.closest("[data-sw-replay]"); if (rp) { startReplay(); return; }
    const view = t.closest("[data-sw-view]"); if (view) { const v = view.getAttribute("data-sw-view"); setTimeout(() => openView(v), 200); return; }
  });
  /* archive links sit inside demo "cover" cards: intercept in the capture phase so the cover's own click doesn't fire */
  document.addEventListener("click", (e) => {
    const b = e.target.closest(".c-sw[data-sw-issue]"); if (!b) return;
    e.stopPropagation(); e.preventDefault();
    TS.showPage(PAGE_ID); loadIssue(parseInt(b.getAttribute("data-sw-issue"), 10));
  }, true);
  document.addEventListener("submit", (e) => {
    if (e.target.id === "swClaimForm") { e.preventDefault(); submitClaim(e.target); }
    if (e.target.id === "swPrefsForm") { e.preventDefault(); savePrefs(e.target); }
  });
  document.addEventListener("input", (e) => {
    if (e.target.id === "swAsCompany") { S.asCompany = e.target.value; clearTimeout(S.asTimer); S.asTimer = setTimeout(() => loadLeaderboard("allstars"), 450); }
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") $$(".sw-methodology.open").forEach((m) => m.classList.remove("open")); });

  /* ---------------- init ---------------- */
  async function init() {
    S.entry = parseEntry();
    buildKeyboard();
    if (TS.onPage) TS.onPage((id) => { document.body.classList.toggle("sw-active", id === PAGE_ID); if (id === PAGE_ID) onPageShown(); else { S.pageShown = false; } });

    // magic-link round trip: a Supabase session + a pending claim → attach and finish
    if (S.entry.verify) {
      try {
        if (API.mode === "supabase") {
          const { data } = await API.client.auth.getSession();
          if (data && data.session) await completeVerification();
          else toast("That verification link has expired — request a new one.");
        }
      } catch (e) {}
      try { const u = new URL(location.href); u.searchParams.delete("verify"); u.searchParams.delete("code"); history.replaceState(null, "", u.pathname + (u.search || "") + "#" + PAGE_ID); } catch (e) {}
    }

    if (S.entry.wantsPage && TS.showPage) TS.showPage(PAGE_ID, true);
    else if (document.querySelector("#page-" + PAGE_ID + ".on")) onPageShown();
    setTimeout(primePromo, 0);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();

  /* small public surface for the admin dashboard / tests */
  window.SparkWord = { state: S, api: API, track, openView, loadIssue, shareText, version: "1.0.0" };
})();
