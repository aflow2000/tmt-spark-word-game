# ⚡ Spark Word

**Five letters. Six tries. One industry.**

Spark Word is a Wordle-style word game for **TMT Spark**, Turner & Townsend's technology, media and telecom newsletter. Every word is a real term from the industries the newsletter covers — AI and compute, data centers, semiconductors, telecom, media, digital infrastructure and the power behind them — so readers learn something each time they play, and come back to protect their streak.

> **Play it:** open `spark-word-daily.html` from this repository, or the deployed link if one is set up (see *Put it online* below).

---

## How to play

Guess the five-letter TMT term in six tries. After each guess the tiles tell you how close you are:

| Tile | Meaning |
|---|---|
| 🟦 **Blue** | Right letter, right place |
| 🟨 **Gold** | Right letter, wrong place |
| ⬛ **Gray** | Not in the word |

Each tile also carries a small corner glyph, so the game works without relying on colour alone.

**Stuck? Ask for a Spark.** The sector (for example *Telecommunications*) is shown above the board from the start. After **two guesses**, the *Need a Spark?* button lights up and reveals a two-line hint: first what the thing is, then a plain giveaway. If you're still stuck after **four guesses**, a *second spark* shows the first letter. Using the hint costs 5 points and ranks below hint-free solves — but it means everyone gets to the answer and the explanation.

**Scoring** (Spark Word All-Stars points): solved in 1 guess = 100 · 2 = 80 · 3 = 65 · 4 = 50 · 5 = 35 · 6 = 20 · hint used = −5 · streak bonus = +2 per consecutive day played (capped). A missed word scores 0 and counts as played.

**After the game** you see the word, what it means and why it matters, your rank and percentile for the day, your streak, and a share card that never gives the answer away:

```
TMT SPARK WORD · DAY 012 ⚡
3/6
⬛🟦⬛⬛🟦
🟦🟨⬛🟦⬛
🟦🟦🟦🟦🟦
Top 8% today.
Can you beat me?
```

The **Leaderboard** tab has the day's board, the All-Stars table (today / this month / all time; everyone / Turner & Townsend / clients & industry / your company) and normalised Company Standings. **Past words** lets you replay any day you missed in archive mode — a past answer stays hidden until you've played it.

---

## The three editions

The same game ships in three forms. Pick the one that matches how much you want to run.

| | **Daily** — `spark-word-daily.html` | **Newsletter, single file** — `spark-word.html` | **Full site** — `index.html` |
|---|---|---|---|
| What it is | The game on its own page, a new word every calendar day | The game on its own page, one word per newsletter issue | The TMT Spark site with Spark Word built into the nav, home page, insights and Spark Learning |
| Backend | None — nothing to configure | Supabase (free tier) — paste two keys | Supabase (free tier) |
| Words | 100 preloaded TMT words, then repeats | Chosen per issue in the admin dashboard from a 173-word bank | Same |
| Leaderboards | Your own results are saved on your device; other players are sample data | Real, shared, across all readers | Real, shared |
| Newsletter links | Any link to the page | Personal `?t=TOKEN` links that recognise each subscriber | Same, plus `/spark-word/014` pretty links |
| Admin | Edit one JS file and rebuild | `spark-word-admin.html` — issues, word bank, links, analytics | `admin.html` |
| Set-up time | 0 minutes | ~20 minutes | ~30 minutes |

If you're not sure, start with **Daily**. It is the file most people should upload first; the other two are there when you want real shared leaderboards. The full guide for those is in [`docs/SETUP.md`](docs/SETUP.md).

---

## Daily edition

### Put it online

`spark-word-daily.html` is self-contained — styles, dictionary, game logic and the 100 words are all inside it, and it makes no network requests. Host it anywhere that serves static files:

- **Vercel** — import this repository at vercel.com/new with Framework preset *Other* and deploy. The game is at `https://YOUR-PROJECT.vercel.app/spark-word-daily.html`. Every commit redeploys.
- **GitHub Pages** (public repos) — *Settings → Pages → Deploy from a branch → main / root*. The game is at `https://YOUR-USER.github.io/YOUR-REPO/spark-word-daily.html`.
- **Anything else** — Netlify Drop, SharePoint, an intranet folder, or just double-click the file.

To put the game at the root address instead, rename the file to `index.html` (this repository's `index.html` is the full site — replace it only if you don't want that edition).

### Change the words, hints or start date

The schedule lives in [`assets/spark-word-daily-words.js`](assets/spark-word-daily-words.js):

```js
window.SPARK_WORD_SCHEDULE = {
  startDate: "2026-09-03",   // Day 1, in the player's local calendar
  cycle: true,               // after word 100, start again from word 1
  hintUnlockAfter: 2,        // guesses before "Need a Spark?" unlocks
  secondSparkAfter: 4,       // guesses before the first letter is offered
  words: [
    { w: "MODEL", c: "AI & Compute",
      h: "The trained brain of any AI system — every chatbot is one of these underneath.\nIt's also what you call someone walking a fashion runway.",
      e: "A model is the trained system at the heart of AI: billions of learned parameters …" },
    …
  ]
};
```

Each word needs `w` (five letters, unique), `c` (the sector shown above the board), `h` (the hint — two lines separated by `\n`: what it is, then the giveaway) and `e` (the explanation shown after the game). Day *n* uses word *n*; the first 100 are already written, 15 AI & compute, 15 data centers, 14 semiconductors, 16 telecom, 16 media, 16 digital infrastructure and 8 power.

After editing, rebuild the single file:

```bash
node scripts/build-daily.js        # → spark-word-daily.html (answers are encoded, not plain text)
```

Commit the regenerated file and the host redeploys. Editing the big HTML file directly works once, but it drifts from the source — edit the words file and rebuild instead.

### What it does and doesn't do

Because there is no server, a player's own games, streak and claimed name are kept in **their browser's storage** — streaks work day to day on one device, and clearing site data resets them. The other names on the leaderboards are generated sample players, and the banner on the page says so. Answers are encoded in the file rather than written in plain text, which stops casual peeking but is not a security boundary. If you need real, shared, tamper-proof leaderboards, use the newsletter edition.

---

## Newsletter editions (real leaderboards)

Both Supabase editions keep the answer, hints and scoring in Postgres: guesses are evaluated server-side, the answer never reaches the browser before the game ends, one official game per subscriber per issue, and the `anon` key can only call the gameplay functions — it has no table access at all. Subscribers get personal links (`?t=TOKEN`, never `?email=`), guests can play immediately and claim their rank once, and an email that already belongs to a subscriber triggers a magic-link check so nobody can claim someone else's profile.

Shortest path — three files: `spark-word.html`, `spark-word-admin.html` and `supabase/spark-word-setup.sql`. Run the SQL once in the Supabase SQL editor, paste the project URL and anon key into the CONFIG block at the top of each HTML file, upload, done. Step-by-step instructions, the Vercel Marketplace flow, Netlify, the editor workflow for running an issue, the Staffbase email recipe, the security model, the go-live checklist and the test suites are all in **[`docs/SETUP.md`](docs/SETUP.md)**.

---

## What's in this repository

```
spark-word-daily.html            ► Daily edition — one file, no backend
spark-word.html                  ► Newsletter edition — one file + Supabase
spark-word-admin.html            ► Editor dashboard — one file + Supabase
index.html · admin.html            Full TMT Spark site with the game built in, and its dashboard
assets/
  spark-word-daily-words.js      ► The 100 daily words, hints and explanations — edit here
  spark-word.js · spark-word.css   Game module and styles (source for every edition)
  spark-word-preview.js            No-backend engine: daily schedule, sample players, device storage
  spark-word-dictionary.js         12,578 accepted five-letter guesses
  spark-word-config.js             Supabase keys for index.html / admin.html
  admin.js · admin.css             Dashboard
scripts/
  build-daily.js                   Rebuilds spark-word-daily.html from the words file
  build-standalone.js              Rebuilds spark-word.html, spark-word-admin.html and the combined SQL
  build-config.js                  Vercel build step: writes keys from environment variables
supabase/
  spark-word-setup.sql             The whole database in one paste (schema, functions, security, word bank, dictionary)
  spark-word-test-data.sql         Optional sample players and games
  migrations/ · seed/              The same SQL as separate files
email/                             Newsletter block (any ESP) and the Staffbase kit (banner, block, CSV template, guide)
docs/
  SETUP.md                         Full setup guide for the Supabase editions
  ARCHITECTURE.md                  Data model, identification, scoring, anti-cheat
  NEWSLETTER-URLS.md               Per-issue link checklist
hosting/                           Rewrite rules for Vercel, Netlify, Cloudflare Pages and nginx
tests/                             SQL suite, evaluator parity, and browser tests for every edition
vercel.json · _redirects           Pretty-link rewrites, ready for Vercel and Netlify
```

## Tests

```bash
node scripts/build-daily.js
python3 -m http.server 8080 &
node tests/ui.daily.js              # daily edition: day 1, hint timing, persistence, a mocked day 18, phone
```

The Supabase editions have a SQL suite (60+ assertions), an evaluator-parity test and two more browser suites; see `docs/SETUP.md` §8.

---

Built for TMT Spark by Turner & Townsend. The guess dictionary is derived from the MIT-licensed `word-list` package (five-letter words only); the answer lists are hand-curated.
