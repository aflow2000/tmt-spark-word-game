-- ============================================================
-- SPARK WORD — seed 010 · Settings
-- Edit these from the admin dashboard (Settings tab) or here.
-- ============================================================
insert into sw_settings (key, value, description) values
  ('site_url',                              'https://tmtspark.example.com', 'Public origin of the site — used to build newsletter game URLs and share links.'),
  ('url_style',                             'path',  'path → /spark-word/014?t=TOKEN (needs the SPA rewrite in hosting/). query → /index.html?issue=14&t=TOKEN#spark-word (works on any static host).'),
  ('hint_unlock_after',                     '3',     'Number of guesses before "Need a Spark?" unlocks.'),
  ('second_spark_after',                    '5',     'After this many guesses, a player who used the hint can reveal the first letter. 0 disables it.'),
  ('streak_bonus_cap',                      '10',    'Streak bonus is +2 points per consecutive issue, capped at this many issues.'),
  ('company_min_players',                   '3',     'Minimum eligible players for a company to appear in Company Standings.'),
  ('min_seconds_per_guess',                 '0.7',   'Games completed faster than this average cadence are flagged and excluded from ranking.'),
  ('require_verification_for_new_emails',   'false','true → every public-link claim must verify by magic link (existing subscriber emails always must).')
on conflict (key) do update set value = excluded.value, description = excluded.description;
