# Spark Word — architecture

> Five letters. Six tries. One industry. **Compete → Learn → Return.**

## 1. Shape of the system

```
 Newsletter (email)                 Browser (static site)                     Supabase
 ─────────────────                  ─────────────────────                     ────────
 Play Issue 014 →  ──────────────►  index.html#spark-word                     Postgres
 /spark-word/014?t=TOKEN            ├─ assets/spark-word.js  ── RPC (anon) ─► sw_* functions (SECURITY DEFINER)
                                    │   token stripped from URL,               ├─ subscribers  (closed to anon)
                                    │   stored in localStorage                 ├─ issues       (answer never selectable)
                                    │                                          ├─ word_bank, dictionary
                                    └─ admin.html / assets/admin.js            ├─ games, guesses, events
                                        Supabase Auth (admins table) ──────►   └─ admin_* functions + RLS for admins
```

* **Front end** – the existing single-page TMT Spark site plus one page section, one CSS
  file and one JS module. Vanilla JS, no build step. `window.TMTSpark` is a tiny bridge the
  site exposes (`showPage`, `toast`, veils, search `INDEX`) so the game feels native.
* **Backend** – Supabase Postgres. Every gameplay call is a Postgres function invoked through
  PostgREST (`supabase.rpc`). There are no Edge Functions: the logic is SQL, testable with
  `psql`, deployable with one file, and has no cold starts.
* **Auth** – players never log in. Subscribers are recognised by an opaque token; guests by a
  client id. Only editors use Supabase Auth (for `admin.html`).

## 2. Data model

| Table | Purpose | Notes |
|---|---|---|
| `subscribers` | one row per person | `subscriber_token` (32 random bytes, base64url), `leaderboard_visibility`, cached stats (`games_played`, `games_won`, `average_guesses`, `current_streak`, `best_streak`, `total_points`), `company_key` (normalised, generated) |
| `issues` | one Spark Word per newsletter issue | `answer` (5 A–Z), `category`, `hint`, `explanation`, `status` draft→scheduled→active→archived. Partial unique index: **only one active issue**. Trigger blocks answer reuse unless `allow_reuse`. |
| `word_bank` | curated answers (173 seeded) | `used` / `last_used_issue` kept in sync by triggers; `related_type/ref` links into Spark Learning |
| `dictionary` | 12,578 legal five-letter guesses | MIT-licensed `word-list` + every bank word (trigger guarantees answers are guessable) |
| `games` | one row per attempt | `mode` official/archive/preview, `status`, `guess_count`, `hint_used`, `completion_seconds`, `score`, `streak_at_completion`, `flagged`. Unique official game per (subscriber, issue) and per (guest, issue). |
| `guesses` | each submitted row | `result` is a 5-char pattern `c/p/a` |
| `events` | analytics | whitelisted event names; the answer is stripped from props |
| `admins` | editors | Supabase Auth user ids; `role` owner/editor |
| `sw_settings` | tunables | hint unlock, streak cap, company minimum, cadence threshold, site URL, URL style |

**Leaderboards are never stored.** `sw_issue_leaderboard`, `sw_allstars`, `sw_company_standings`
and `sw_last_issue_summary` compute from `games` on every call. They cannot drift and cannot
be written to. Subscriber stat columns are a cache recomputed after each official game
(`sw_recompute_subscriber_stats`) and can be rebuilt any time with `admin_recompute_all_stats()`.

## 3. Subscriber identification

1. The editor exports links (`admin_issue_links`) → `https://site/spark-word/014?t=TOKEN`.
2. `index.html` hops to `?issue=14&t=TOKEN#spark-word`; `spark-word.js` stores the token,
   removes it from the address bar (`history.replaceState`) and passes it in every RPC.
3. `sw_resolve_subscriber(token)` runs inside SECURITY DEFINER functions. The `subscribers`
   table has **no** anon policy, so the token is the only door and email never leaves the DB.
4. Guests get `guest-<uuid>` in localStorage. Their games are ranked as "Guest" until claimed.
5. **Claim** (`sw_claim_profile`): a new email creates the profile, attaches every guest game
   (converting an official game to archive if the profile already had one for that issue),
   rescores with the real streak, and returns the token. An email that already exists returns
   `verify_required` — the client sends a Supabase magic link; after the round trip
   `sw_verified_link` (authenticated role, reads `auth.jwt()->>'email'`) attaches the games
   and returns the real token. Nobody can hijack a profile by typing someone else's address.
6. `require_verification_for_new_emails = true` makes every claim verify (stricter, more friction).

## 4. Gameplay contract (client → SQL)

| RPC | Does |
|---|---|
| `sw_bootstrap(issue, token, guest, ref)` | issue meta (no answer), player + stats, game to resume (rows + results, hint if already used), what mode a new game would be |
| `sw_submit_guess(issue, guess, token, guest, game_id, ref, ua)` | validates (5 letters, dictionary), creates the game lazily on the first guess, evaluates two-pass (duplicates correct), stores the row, ends the game on `ccccc` or the sixth guess, computes time/streak/score/flag, returns the pattern — and the answer + explanation **only** when the game is over |
| `sw_use_hint(game_id, token, guest)` | refuses until `hint_unlock_after` (3) guesses exist; records `hint_used` |
| `sw_claim_profile`, `sw_verified_link`, `sw_update_profile` | identity (above) |
| `sw_issue_leaderboard`, `sw_allstars`, `sw_company_standings`, `sw_last_issue_summary`, `sw_my_stats`, `sw_archive` | read models |
| `sw_track(event, …)` | client-side analytics events (server-side ones are written inside the functions) |

## 5. Scoring, streaks, ranking

* **Issue rank**: solved → fewest guesses → no hint → fastest → earliest finish. Failed games
  count as played (`total`) but are not ranked. Percentile = ⌈rank ÷ total × 100⌉.
* **Points** (All-Stars): 1 → 100, 2 → 80, 3 → 65, 4 → 50, 5 → 35, 6 → 20, fail → 0, hint −5,
  streak bonus +2 × min(streak, 10). Archive/preview games score 0.
* **Streaks are issue-based.** Published issues are ordered by `issue_number`. A streak is the
  run of consecutive published issues with a completed official game. The active issue may be
  unplayed without breaking it — it breaks once that issue is archived unplayed.
* **Company standings**: for each eligible player, average points per issue in the period;
  company score = mean of those averages; minimum `company_min_players` (3). Headcount can't win.
* **Ties** share a rank (`rank()`); completion time is the last tiebreak so speed matters little.

## 6. Anti-cheat (proportionate)

* The answer is not in any payload until the game ends; guesses are evaluated in Postgres.
* One official game per subscriber per issue (unique index); replays are archive mode with 0 points.
* Only the active issue can be played officially; drafts/scheduled issues are invisible to anon.
* Timing is server-side (first guess → last guess). Solves faster than
  `min_seconds_per_guess × (guesses − 1)` are `flagged`: kept, shown as played, excluded from ranking.
* Clients never send scores; `events` names are whitelisted; `answer`/`word`/`email` props are stripped.
* Tokens: 256-bit random, never logged by the app, removable with `admin_rotate_token`.
* Not covered (by design): a guest clearing localStorage and playing again as a *new* guest.
  They would need a new email to be ranked twice; the admin list makes that visible.

## 7. Analytics events

`spark_word_viewed` (ref = newsletter | site | link | archive), `spark_word_started`,
`spark_word_guess`, `spark_word_hint_used`, `spark_word_completed`, `spark_word_failed`,
`spark_word_shared` (method), `spark_word_leaderboard_viewed` (board), `spark_word_archive_played`,
plus `spark_word_onboarding_seen`, `spark_word_claim_opened`, `spark_word_profile_claimed`.
Every client event also goes to `window.dataLayer` (GTM/GA4), to the optional
`SPARK_WORD_CONFIG.analytics(name, props)` hook, and to a `spark-word:analytics` DOM event.
Payloads carry `issue_id`, `issue_number`, `subscriber_id` (when known), `company`, `mode`,
`guess_count` where relevant — never the answer before completion.

## 8. Why not Edge Functions / a custom server?

The requirement was a self-contained front end with Supabase behind it. Postgres functions
give server-side evaluation, transactional integrity (game + guess + event in one transaction),
RLS-native security and zero extra deployables. Edge Functions would only be needed for
outbound email or webhooks — Supabase Auth already sends the magic links this design uses.

## 9. Design preview mode

If `assets/spark-word-config.js` has no credentials, `spark-word.js` loads
`assets/spark-word-preview.js`: an in-memory implementation of the same RPCs on the seed data,
with a visible "Design preview" banner. It exists so the interface can be reviewed before
Supabase is provisioned. It persists nothing and is never used once credentials are present.
`tests/evaluate.test.js` proves its evaluator and scoring match the SQL exactly.
