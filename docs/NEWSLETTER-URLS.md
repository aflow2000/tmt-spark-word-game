# Newsletter URL generation — the per-issue checklist

Every subscriber gets a **personal** link. It identifies them without an account, keeps their
streak, and never contains their email address.

```
https://YOUR-SITE/spark-word/014?t=Qm9mZ3l...opaque-43-char-token
```

## Step by step (about five minutes per issue)

1. **Import or refresh subscribers** — `admin.html → Subscribers & links → Import subscribers`.
   Paste CSV from your ESP: `email, first_name, last_name, company`. Existing people keep
   their token (their old links stay valid); new people get one.
2. **Create the issue** — `Issues → New issue`: number, publication date, title, pick the word
   from the bank (used words are blocked), sector, hint, explanation, recipients count.
   *Preview game* opens the real board for that issue (editors only, `preview` mode, never ranked).
3. **Activate** on send day (or set status *scheduled* and run `select admin_activate_due_issues();`
   from pg_cron at, say, 06:00 on publication day). Activating archives the previous issue.
4. **Export links** — `Subscribers & links → Download CSV` for the issue:

   | email | first_name | last_name | company | game_url |
   |---|---|---|---|---|
   | sarah@nvidia.com | Sarah | Mitchell | NVIDIA | https://tmtspark.com/spark-word/014?t=… |

   Upload as a merge file in your ESP (Mailchimp / HubSpot / Customer.io / Salesforce MC).
   Map `game_url` → a merge tag, e.g. `*|GAME_URL|*` or `{{ contact.game_url }}`.
5. **Insert the email module** — `Email module → Copy HTML` (source: `email/spark-word-module.html`).
   Replace `{{GAME_URL}}` with your merge tag, `{{ISSUE_NUMBER}}` with `014`, `{{LAST_PLAYERS}}`
   with the number from Analytics.
6. **Send.** Readers land on the game already recognised: name, company, streak, one official attempt.
7. **Next issue** — the `LAST ISSUE'S SPARK WORD` block (Analytics tab, screenshot-ready) gives you
   the recap: word, players, % solved, fastest minds, company champion.

## Generating links without the dashboard

```sql
-- all newsletter subscribers, one URL each (run as an admin or with the service role)
select * from admin_issue_links(14, true);

-- one person
select admin_subscriber_link('<subscriber uuid>', 14);
```

`site_url` and `url_style` in `sw_settings` control the format:

* `path`  → `https://site/spark-word/014?t=TOKEN` (needs the rewrite in `hosting/`)
* `query` → `https://site/index.html?issue=14&t=TOKEN#spark-word` (works anywhere)

## Public (non-personal) link

`https://YOUR-SITE/index.html#spark-word` — anyone can play; they are asked once for
email, name and company before their result is ranked.

## If a link leaks

Rotate the token: `Subscribers & links → Rotate token` (or `select admin_rotate_token('<uuid>')`).
Old links stop working; the person's history is untouched.
