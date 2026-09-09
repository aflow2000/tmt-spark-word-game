# Spark Word — go-live checklist for tmt-spark-word-game.vercel.app

The site is already deployed from this repository. Right now the game on it runs in *design preview*
(no database, sample players). This checklist turns it into the real thing: a word every two weeks
that goes live by itself, and player accounts with real, shared leaderboards. About 30 minutes,
all clicking, no code.

Everything marked **► you** needs your hands (accounts, keys, settings); everything else is already in the repo.

---

## 1. Create the database (Supabase, free tier) — ► you

1. Go to https://supabase.com → **New project**. Name it `spark-word`, pick a region near your readers (e.g. London), set a database password (keep it somewhere safe — you won't need it for the game).
2. When the project is ready, open **SQL Editor → New query**, paste the whole of
   [`supabase/spark-word-setup.sql`](../supabase/spark-word-setup.sql) and press **Run**.
   It takes 10–20 seconds and ends with `issues_activated: 1`. That one run creates everything:
   tables, game functions, security, the word bank, the guess dictionary, and the **fortnightly calendar** —
   Issue 015 (MODEL, live today), then a new word every 14 days through Issue 114 in 2030.
3. **Project Settings → API**: copy the **Project URL** (`https://xxxx.supabase.co`) and the **anon public** key.
   These are safe to be public — the database only lets them call the game functions.

## 2. Turn on player accounts — ► you

Still in Supabase, under **Authentication**:

1. **Providers → Email**: leave *Enable Email provider* on. Decide about **Confirm email**:
   - **On** (default): new players get a confirmation email and are signed in when they click it. Needs step 4 (email sending).
   - **Off**: creating an account signs the player in immediately — no email needed. Password resets and "email me a link" still need step 4, but the core sign-up works with nothing else configured. *Recommended for launch day.*
2. **URL Configuration**:
   - *Site URL*: `https://tmt-spark-word-game.vercel.app`
   - *Redirect URLs* → Add: `https://tmt-spark-word-game.vercel.app/**` (the two asterisks matter — confirmation and reset links come back to `/index.html?issue=15&verify=1`).
3. **Email Templates** (optional, but nicer): in *Confirm signup*, *Magic Link* and *Reset Password* change the subject lines to something like *"Confirm your Spark Word account"*. The `{{ .ConfirmationURL }}` placeholder must stay.

## 3. Create the editor login (for the admin dashboard) — ► you

1. **Authentication → Users → Add user → Create new user**: your work email, a password, and tick **Auto Confirm User**.
2. **SQL Editor → New query**:
   ```sql
   insert into admins (user_id, email, role)
   select id, email, 'owner' from auth.users where email = 'you@turnerandtownsend.com';
   ```
3. The dashboard is `https://tmt-spark-word-game.vercel.app/admin` — sign in with that email and password.

## 4. Email sending (needed for confirmation, magic links and password resets) — ► you

Supabase's built-in email service is for testing only: it sends **2 emails per hour, and only to
members of your Supabase project** — a real player would never receive their confirmation. Two ways forward:

- **Launch without it**: set *Confirm email* **off** (step 2.1). Sign-up and sign-in work with no email at all; only "Forgot password" and "Email me a link" are affected, and the page tells the player to try again if a mail doesn't arrive.
- **Set up custom SMTP** (15 minutes, can be done later): Supabase → **Project Settings → Authentication → SMTP Settings → Enable Custom SMTP**. Any provider works — [Resend](https://resend.com) has a free tier of 3,000 emails a month (100 a day) and a two-field setup (host `smtp.resend.com`, port 465, user `resend`, password = your Resend API key, sender = an address on a domain you've verified there). Your IT team may prefer Microsoft 365 SMTP. Then raise **Authentication → Rate Limits → Emails** from the default.

## 5. Connect the site — ► you

In Vercel, open the project → **Settings → Environment Variables** and add two:

| Name | Value |
|---|---|
| `SUPABASE_URL` | the Project URL from step 1.3 |
| `SUPABASE_ANON_KEY` | the anon public key from step 1.3 |

Then **Deployments → ⋯ on the latest → Redeploy**. The build step (`scripts/build-config.js`, already in
`vercel.json`) writes those two values into `assets/spark-word-config.js`, and the game switches from
preview to live. No key is ever committed to GitHub.

(Alternative with no environment variables: paste the two values into `assets/spark-word-config.js` in the
repo and commit. Works the same; the key is public anyway.)

## 6. Check it works (5 minutes)

1. Open https://tmt-spark-word-game.vercel.app/#spark-word — the *Design preview* banner is gone, the header reads **Issue 015 · September 8, 2026 · Next word September 22 (in N days)**.
2. Play the word as a guest, then **Create account** from the result. With *Confirm email* off you're signed in at once; with it on, check your inbox. Your result appears on the leaderboard under the name you chose.
3. **Preferences → Sign out**, then **Sign in** again — your streak and result are still there.
4. Open the dashboard at `/admin`: the **Issues** tab lists the whole calendar; **Overview** shows Issue 015 live and 016 up next.

## 7. Newsletter links (each issue, 2 minutes)

The generic link for every email is `https://tmt-spark-word-game.vercel.app/spark-word/015` (change the number
per issue — or use `/#spark-word`, which always opens the current word). Personal links that recognise a
subscriber without an account: dashboard → **Subscribers & links** → import your list once → **Download CSV**,
and merge the `game_url` column into the email (Staffbase recipe in `email/staffbase/`).

---

## Things you can change later

| Want to… | Do this |
|---|---|
| Change a word, hint or date | Dashboard → **Issues** → edit. Reuse of a word is blocked unless you tick *allow reuse*. |
| Move to weekly or monthly | Edit the dates in **Issues** (or regenerate: `EVERY=7 node scripts/build-schedule-sql.js` and run the new file). |
| Change when the switch happens | The new issue goes live at midnight in the `timezone` setting (**Settings** tab; default UTC — set `Europe/London` if you'd rather it flip at UK midnight). |
| Hint timing | **Settings** → `hint_unlock_after` (2) and `second_spark_after` (4). |
| Force an issue live early | Dashboard → **Issues** → *Activate*. |
| Remove the demo players | There are none in production — the setup SQL doesn't install them. (`spark-word-test-data.sql` is for a separate demo project and refuses to run here.) |

## What "accounts" means, precisely

- Players sign up with email + password (or ask for an emailed sign-in link). Their email is never shown anywhere; leaderboards show the display name they picked and their company.
- Games played as a guest on that device are attached to the account at sign-up, so nobody loses the result that made them want an account.
- Streaks, points and results follow the account to any device.
- A newsletter subscriber who later creates an account with the same email gets one merged history.
- Personal newsletter links still work with no account at all.
- Everything is enforced in the database: the browser can only call the game functions, never read tables; the answer is never sent to the browser before a game ends.
