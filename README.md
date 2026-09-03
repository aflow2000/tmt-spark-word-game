# Spark Word — TMT Spark's industry word game

> **Five letters. Six tries. One industry.**
> A recurring, newsletter-driven word game for TMT Spark by Turner & Townsend.
> Every issue hides a five-letter term from the industries TMT Spark covers. Readers compete,
> learn what the word means, and come back next issue to protect their streak.

```
tmt-spark-spark-word/
├── index.html                      the TMT Spark site with Spark Word integrated
├── admin.html                      editor dashboard (issues · word bank · links · analytics · email · settings)
├── spark-word.html                 ► SINGLE-FILE game page (everything inlined, CONFIG block at the top) — see §2.0
├── spark-word-admin.html           ► SINGLE-FILE dashboard
├── spark-word-daily.html           ► DAILY edition: one file, no backend, a new TMT word every day for 100 days — see §1.1
├── assets/
│   ├── spark-word-config.js        ► the ONLY file you must edit: Supabase URL + anon key
│   ├── spark-word.css              game styles (built on the site's tokens)
│   ├── spark-word.js               game module (board, keyboard, hints, results, share, claim, leaderboards, archive)
│   ├── admin.css / admin.js        dashboard
│   ├── spark-word-preview.js       in-memory design preview (auto-used only when unconfigured)
│   ├── spark-word-dictionary.js    preview-only copy of the guess dictionary
│   └── spark-word-wordbank-preview.js  preview-only snapshot of the word bank
├── supabase/
│   ├── spark-word-setup.sql        ► ONE file for the Supabase SQL editor (= migrations 001…005 + seeds 010…040)
│   ├── spark-word-test-data.sql    optional sample players & games (= seeds 050 + 060)
│   ├── migrations/001…005          schema · game functions · leaderboards · admin functions · RLS
│   └── seed/010…060                settings · 173-word bank · 12,578-word dictionary · issues 011–015 · test subscribers · test games
├── email/spark-word-module.html    drop-in newsletter block (any ESP)
├── email/staffbase/                Staffbase Email recipe: banner PNG, Outlook-safe block, CSV template, guide
├── vercel.json · _redirects        rewrites for /spark-word/014 links (Vercel · Netlify/Cloudflare)
├── scripts/build-config.js         Vercel build step: writes the config from injected env vars (also patches the single-file editions)
├── scripts/build-standalone.js     regenerates spark-word.html, spark-word-admin.html and the combined SQL from the sources
├── scripts/build-daily.js          regenerates spark-word-daily.html from assets/spark-word-daily-words.js
├── hosting/                        rewrites for Netlify / Vercel / Cloudflare / nginx
├── docs/ARCHITECTURE.md            data architecture, identification, scoring, anti-cheat
├── docs/NEWSLETTER-URLS.md         per-issue link generation checklist
├── tests/                          SQL suite · evaluator parity · UI↔SQL integration harness
└── .env.example
```

---

## 1. See it in two minutes (no backend yet)

Open `index.html` in a browser (or serve the folder). **Spark Word** is in the navigation,
on the home page, inside Edition 014 and in Spark Learning. Without credentials the game runs
on an in-memory *design preview* of the seed data — a banner says so, and nothing is saved.
`admin.html` does the same ("Enter as editor@turntown.com").

### 1.1 Daily edition — one file, no backend, 100 words

`spark-word-daily.html` is the game on its own, with no database and nothing to configure: upload it anywhere
(GitHub Pages, Vercel, a shared drive) and it serves a new five-letter TMT word every calendar day from
`assets/spark-word-daily-words.js` — 100 words across AI & compute, data centers, semiconductors, telecom, media,
digital infrastructure and power, each with a two-line hint (what it is, then a giveaway) and an explanation.
Day 1 is `startDate` in that file; after word 100 the list starts over. The hint unlocks after two guesses and a
second spark shows the first letter after four (`hintUnlockAfter` / `secondSparkAfter`).

What it can and can't do: the player's own games, streak and claimed name are kept in that browser's storage —
so streaks work day to day on one device — while the other players on the leaderboards are generated sample data.
Answers are encoded in the file rather than written in plain text. For real shared leaderboards use the Supabase
editions above. Edit the words file and run `node scripts/build-daily.js` to rebuild; `node tests/ui.daily.js` checks it.

## 2. Go live with Supabase (≈ 20 minutes)

### 2.0 Shortest path: three files (GitHub + Vercel + Supabase)

If you only want the game (not the whole TMT Spark site), you need **three files** from this folder:

| File | What it is |
|---|---|
| `spark-word.html` | the complete game — CSS, dictionary, game logic, all inlined; the only external request is the supabase-js library from jsDelivr |
| `spark-word-admin.html` | the editor dashboard, same single-file treatment |
| `supabase/spark-word-setup.sql` | the whole database in one query: schema, game functions, leaderboards, RLS, settings, word bank, dictionary, Issue 014 |

1. **Supabase** — create a free project → **SQL Editor** → paste `supabase/spark-word-setup.sql` → *Run*
   (add `supabase/spark-word-test-data.sql` too if you want populated leaderboards to look at).
   Then *Project Settings → API*: copy the **Project URL** and the **anon public** key.
2. **The CONFIG block** — open `spark-word.html`; the first `<script>` in the file is a clearly marked
   CONFIG block. Paste the two values into `supabaseUrl` and `supabaseAnonKey`. Do the same in
   `spark-word-admin.html`. (Deploying through the Vercel Marketplace instead? Leave them empty —
   `scripts/build-config.js` fills them from the environment, see §2.5.)
3. **GitHub + Vercel** — upload the files to a repository (*Add file → Upload files*), then on vercel.com/new
   import it with Framework preset **Other**. Vercel serves static files as they are: your game is at
   `https://YOUR-APP.vercel.app/spark-word.html`, the dashboard at `/spark-word-admin.html`.
4. **Admin user** — Supabase *Authentication → Users → Add user* (auto-confirm), then in SQL Editor
   `insert into admins (user_id, email, role) select id, email, 'owner' from auth.users where email = 'you@turntown.com';`
   and add `https://YOUR-APP.vercel.app/*` under *Authentication → URL Configuration → Redirect URLs*.
5. **Links** — in the dashboard *Settings* tab (or SQL) set `site_url` = `https://YOUR-APP.vercel.app/spark-word.html`
   and `url_style` = `query`. Newsletter links then look like
   `https://YOUR-APP.vercel.app/spark-word.html?issue=14&t=TOKEN` — no rewrite rules needed on any host.

With empty keys `spark-word.html` still opens as a labelled *design preview* on sample data, so you can look at it
before the database exists. Both single-file pages are generated from the sources by `node scripts/build-standalone.js`;
edit `assets/*` and rebuild rather than editing the big files by hand.

### 2.1 Create the database

1. Create a project at [supabase.com](https://supabase.com) → **SQL Editor**.
2. Run `supabase/spark-word-setup.sql` as one query (it is the files below concatenated), **or** run the files **in this order**, each as one query:
   `supabase/migrations/001_schema.sql` → `002_game_functions.sql` → `003_leaderboards.sql`
   → `004_admin.sql` → `005_rls.sql`, then `supabase/seed/010_settings.sql` → `020_word_bank.sql`
   → `030_dictionary.sql` → `040_issues.sql`.
   Optional for a demo: `050_test_subscribers.sql` and `060_test_games.sql` (illustrative people, delete before launch — see §7).

   With the CLI instead: `for f in supabase/migrations/*.sql supabase/seed/*.sql; do psql "$SUPABASE_DB_URL" -f $f; done`

3. Set your site origin: `update sw_settings set value = 'https://tmtspark.com' where key = 'site_url';`

### 2.2 Create the first admin

**► Configuration step.** In **Authentication → Users → Add user**, create the editor
(email + password, *auto-confirm*). Then in the SQL editor:

```sql
insert into admins (user_id, email, role)
select id, email, 'owner' from auth.users where email = 'editor@turntown.com';
```

Add **Authentication → URL Configuration → Redirect URLs**: `https://YOUR-SITE/*`
(used by admin magic links and the one-time player verification link).

### 2.3 Connect the front end

**► Configuration step.** Copy **Project Settings → API → Project URL** and the **anon public**
key into `assets/spark-word-config.js`:

```js
supabaseUrl: "https://abcdefghijklmnop.supabase.co",
supabaseAnonKey: "eyJhbGciOi...",
siteUrl: "https://tmtspark.com",
urlStyle: "path"          // or "query" — see hosting/README.md
```

That is the only credential in the front end; the anon key is public by design and RLS keeps
every table closed to it (see §6).

### 2.4 Deploy

Upload the folder to any static host and add the rewrite from `hosting/` so
`/spark-word/014?t=TOKEN` serves `index.html`. If your host can't rewrite, set
`urlStyle: "query"` and `sw_settings.url_style = 'query'`.

Optional: schedule issue activation with pg_cron —
`select cron.schedule('spark-word-activate', '0 6 * * *', $$select admin_activate_due_issues()$$);`

### 2.5 Recommended: GitHub + Vercel + Supabase from the Vercel Marketplace

Everything lives in one place and no key is pasted by hand.

1. **GitHub** — create an empty repository, then *Add file → Upload files* and drag the contents of this
   folder in (or `git push` it). Commit.
2. **Vercel** — vercel.com/new → *Import* the repository → Framework preset **Other** → *Deploy*.
   `vercel.json` already carries the `/spark-word/014` rewrite and a build step.
3. **Database** — in the Vercel project: *Storage → Create database → Supabase* (Marketplace) → create.
   Vercel provisions the Supabase project and injects `SUPABASE_URL`, `SUPABASE_ANON_KEY` etc. as
   environment variables; billing stays on your Vercel account (free tier is plenty for this data).
4. **Schema** — from the Storage tab open the database → *Open in Supabase* → **SQL Editor** → run the files
   in order: `supabase/migrations/001…005`, then `supabase/seed/010…040` (+ `050/060` for demo data).
5. **Admin user** — Supabase *Authentication → Users → Add user* (auto-confirm), then in SQL Editor:
   `insert into admins (user_id, email, role) select id, email, 'owner' from auth.users where email = 'you@turntown.com';`
6. **Redeploy** — Vercel *Deployments → Redeploy*. The build script writes `assets/spark-word-config.js`
   from the injected variables (`SITE_URL` optional; it defaults to the production URL).
7. **Auth redirect** — Supabase *Authentication → URL Configuration → Redirect URLs*: `https://YOUR-PROJECT.vercel.app/*`.
8. Set the site URL for links: `update sw_settings set value = 'https://YOUR-PROJECT.vercel.app' where key = 'site_url';`

Your public link is `https://YOUR-PROJECT.vercel.app/index.html#spark-word`; the dashboard is `/admin`.
Every later change is a commit — Vercel redeploys automatically.

*Why Supabase and not Neon from the same Marketplace?* The game logic runs as Postgres functions behind
Supabase's REST layer (and Supabase Auth signs the editor in). Neon is a bare Postgres: it would need a small
API layer (Vercel Functions) and a different admin sign-in — doable, but extra moving parts for no gain here.

### 2.5b Alternative: Netlify Drop (no GitHub)

1. **Supabase** (free tier): run the SQL from §2.1, create the admin from §2.2.
2. **Netlify Drop** (free): open app.netlify.com/drop and drag this whole folder onto it.
   `_redirects` is already at the root, so `/spark-word/014?t=TOKEN` links work immediately.
   You get a URL like `https://tmt-spark-word.netlify.app` (rename it under Site settings).
3. Put that URL in `assets/spark-word-config.js` (`siteUrl`) with the Supabase URL and anon key,
   and in `sw_settings.site_url`; drop the folder again.
4. Add the Netlify URL to Supabase **Authentication → URL Configuration → Redirect URLs**.

Your public link is then `https://YOUR-SITE/index.html#spark-word` and `admin.html` is your dashboard.
The claude.ai preview link runs on sample data and saves nothing — it is for showing the design, not for the competition.

## 2.6 Staffbase Email

See `email/staffbase/README-STAFFBASE.md`. Short version: add an **Image** element
(`spark-word-banner@2x.png`) + **Button** ("Play Issue 014 →") at the bottom of the email, linking to
either the generic link `https://YOUR-SITE/index.html?ref=staffbase&company=Turner%20%26%20Townsend#spark-word`
(players claim their name once) or, for personal links, upload the **Staffbase custom-data CSV** exported
from the dashboard and use `{{gameUrl}}` as the button link.

## 3. Run an issue (editor workflow)

`admin.html` → sign in → **Issues → New issue**

1. Issue number · publication date · newsletter title
2. **Spark Word** — type to search the bank; used words are blocked (override checkbox exists)
3. Sector shown to players · hint (unlocks after 3 guesses) · post-game explanation (pre-filled from the bank, edit for this issue)
4. **Preview game** (editors see draft/scheduled issues in a never-ranked *preview* mode)
5. **Activate** (or *scheduled* + the cron above) — the previous issue archives itself
6. **Subscribers & links → Download CSV** → merge `game_url` into the newsletter
7. **Email module → Copy HTML** → paste into the issue

Full checklist: `docs/NEWSLETTER-URLS.md`.

## 4. What players get

* Personal link → recognised instantly (name · company · 🔥 issue streak). Token is removed from the address bar and remembered on that device.
* Board 5 × 6, on-screen + physical keyboard, tile flips, keyboard state, screen-reader announcements, reduced-motion support, no colour-only signals (corner glyphs).
* `THIS ISSUE'S SECTOR` up front; a **Need a Spark?** pill sits under the board from the first guess with progress dots, turns gold when it unlocks after the third guess, and reveals the hint (costs 5 points and ranks below hint-free solves). If a player who used the hint is still stuck at guess five, a **second spark** shows the first letter, so everyone reaches the explanation.
* Win: **YOU GOT THE SPARK.** → word → *Solved in 3/6* → badge → explanation → rank (#14 of 387 · Top 4%) → stats → share / copy / link → Spark Learning link → next-issue teaser.
  Fail: **THE SPARK GOT AWAY.** → the word → explanation. Counts as played, never ranked.
* Share text (answer never included):
  ```
  TMT SPARK WORD · ISSUE 014 ⚡
  3/6
  ⬛🟦⬛⬛🟦
  🟦🟨⬛🟦⬛
  🟦🟦🟦🟦🟦
  Top 8% this issue.
  Can you beat me?
  https://tmtspark.com/spark-word/014
  ```
* Guests play immediately; to be ranked they add email · first name · last name · company once, and choose how they appear (First + last initial / Full name / Anonymous). An email that already belongs to a subscriber triggers a one-time magic-link verification instead — nobody can claim someone else's profile.
* **Leaderboard** tab: Issue leaderboard (Top 10 + your position + percentile), **Spark Word All-Stars** (This issue / This month / All time × Everyone / T&T / Clients & Industry / Company), **Company standings** (normalised, minimum 3 players, methodology tooltip), and the *Last issue's Spark Word* shareout block.
* **Past words** tab: archive mode replays; a past answer stays hidden until you've played it.
* Restrained badges: LIGHTNING STRIKE (1), HIGH VOLTAGE (2), FULLY CHARGED (3), ON A ROLL (streak ≥ 5), TOP OF THE GRID (top 10 of 20+).

## 5. Test data (seeded, illustrative)

Sample **Issue 014 · FIBER · Telecommunications** is active; 011 STEEL, 012 RADIO, 013 POWER are archived with 44 played games; 015 CLOUD is scheduled.

| Person | Company | Situation | Test link (append to your site) |
|---|---|---|---|
| Sarah Mitchell | NVIDIA | played every issue incl. 014 | `/spark-word/014?t=test-sarah-mitchell-nvidia-00000000000001` |
| Priya Natarajan | NVIDIA | streak 2, hasn't played 014 | `/spark-word/014?t=test-priya-natarajan-nvidia-000000000003` |
| Mei Tanaka | Turner & Townsend | anonymous display, hasn't played 014 | `/spark-word/014?t=test-mei-tanaka-tt-000000000000000000006` |
| Jordan Lee | Digital Realty | subscriber who has never played | `/spark-word/014?t=test-jordan-lee-never-played-00000000017` |
| *(no token)* | — | public link, guest → claim flow | `/index.html#spark-word` |

Full list in `supabase/seed/050_test_subscribers.sql`. Remove before launch (§7).

## 6. Security model (short version)

* `anon` has **no** table access at all — only EXECUTE on the `sw_*` gameplay functions (`005_rls.sql`).
* The answer, hint and explanation never leave Postgres until a game is over; guesses are evaluated server-side; hints are gated server-side.
* One official game per subscriber per issue (unique index). Replays are archive mode, 0 points. Draft/scheduled issues are invisible.
* Timing is server-stamped; inhuman cadence flags the game (`min_seconds_per_guess`) — kept, shown as played, excluded from ranking.
* Emails: never in URLs, never in any public payload; leaderboards show display name + company only.
* Admin access = Supabase Auth user in `admins`; admin functions re-check `sw_is_admin()`; RLS gives admins table access for the dashboard.

Details and trade-offs: `docs/ARCHITECTURE.md`.

## 7. Go-live checklist

```sql
delete from games where ref = 'seed';                  -- seeded play history
delete from subscribers where notes = 'seed';          -- illustrative people
update issues set status = 'draft' where issue_number < 14;   -- or delete the sample issues
update sw_settings set value = 'https://tmtspark.com' where key = 'site_url';
```
Then import real subscribers (dashboard), create the real first issue, activate, export links.
Set **Authentication → SMTP** to your own provider if you expect many verification/magic-link emails.

## 8. Tests

Local PostgreSQL + Node are needed. Test dependencies live in `tests/` so the deployable root stays dependency-free:

```bash
cd tests && npm install && cd ..
bash tests/reset_local_db.sh                       # fresh DB with migrations + seeds (adds a stub auth schema)
su postgres -c "psql -v ON_ERROR_STOP=1 -d sparkword -f tests/sql_tests.sql"   # 60+ assertions: duplicates, 6 fails, wins,
                                                   #   hints, claims, verification, ties, streaks, archive, admin, preview, anti-cheat
node tests/evaluate.test.js                        # JS preview evaluator == SQL evaluator (600 random pairs)
bash tests/reset_local_db.sh                       # (tests mutate the DB — reset between suites)
node tests/local-rpc-server.js &                   # PostgREST look-alike on :54321
node tests/ui.integration.js                       # real front-end + real SQL: newsletter link → play → hint → win → replay →
                                                   #   leaderboards → archive → guest fail → claim → verify-required
python3 -m http.server 8080 & node tests/ui.preview.js   # design-preview smoke test (no backend)
bash tests/reset_local_db.sh && node tests/local-rpc-server.js &
node tests/ui.standalone.js                        # single-file editions: preview mode, real backend via query-style link,
                                                   #   phone keyboard, admin preview — run after node scripts/build-standalone.js
```

## 9. Configuration reference (`sw_settings`)

| key | default | meaning |
|---|---|---|
| `site_url` | example | public origin for links |
| `url_style` | `path` | `path` or `query` |
| `hint_unlock_after` | 3 | guesses before *Need a Spark?* |
| `second_spark_after` | 5 | guesses before the first-letter nudge (0 = off) |
| `streak_bonus_cap` | 10 | +2 pts per issue of streak, capped |
| `company_min_players` | 3 | eligibility for Company standings |
| `min_seconds_per_guess` | 0.7 | flag threshold |
| `require_verification_for_new_emails` | false | force magic-link for every claim |

---

*Word list: the guess dictionary is derived from the MIT-licensed `word-list` package (five-letter words only). The answer bank is hand-curated in `supabase/seed/020_word_bank.sql` and editable in the dashboard.*
