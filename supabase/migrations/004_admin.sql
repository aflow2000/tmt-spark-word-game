-- ============================================================
-- SPARK WORD — 004 · Admin functions
--
-- Every function here re-checks sw_is_admin() (a Supabase Auth user
-- listed in `admins`). The admin dashboard also has direct table access
-- through the RLS policies in 005_rls.sql.
-- ============================================================

create or replace function sw_require_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not sw_is_admin() then
    raise exception 'admin_only' using errcode = 'insufficient_privilege';
  end if;
end $$;

-- ------------------------------------------------------------
-- Overview numbers for the dashboard home
-- ------------------------------------------------------------
create or replace function admin_overview() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform sw_require_admin();
  return jsonb_build_object(
    'subscribers', (select count(*) from subscribers),
    'newsletter_subscribers', (select count(*) from subscribers where newsletter_subscriber),
    'players', (select count(distinct subscriber_id) from games where mode = 'official' and subscriber_id is not null),
    'issues', (select count(*) from issues),
    'active_issue', (select jsonb_build_object('number', issue_number, 'title', title, 'answer', answer, 'category', category, 'date', publication_date)
                       from issues where status = 'active'),
    'next_issue', (select jsonb_build_object('number', issue_number, 'title', title, 'status', status, 'date', publication_date)
                     from issues where status in ('draft','scheduled') order by issue_number asc limit 1),
    'word_bank_total', (select count(*) from word_bank),
    'word_bank_available', (select count(*) from word_bank where active and not used),
    'games_total', (select count(*) from games where mode = 'official' and status <> 'in_progress'),
    'flagged_games', (select count(*) from games where flagged)
  );
end $$;

-- ------------------------------------------------------------
-- Per-issue analytics
-- ------------------------------------------------------------
create or replace function admin_issue_analytics(p_issue_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  i issues%rowtype;
  v_started int; v_completed int; v_solved int; v_hint int;
  v_returning int; v_new int; v_shares int; v_clicks int; v_views int;
  v_dist jsonb; v_companies jsonb; v_top jsonb; v_flagged int;
begin
  perform sw_require_admin();
  select * into i from issues where id = p_issue_id;
  if i.id is null then return jsonb_build_object('ok', false, 'error', 'no_issue'); end if;

  select count(*), count(*) filter (where status <> 'in_progress'), count(*) filter (where solved),
         count(*) filter (where hint_used and status <> 'in_progress'), count(*) filter (where flagged)
    into v_started, v_completed, v_solved, v_hint, v_flagged
    from games where issue_id = i.id and mode = 'official';

  -- returning = players with an official completed game on an EARLIER issue
  select count(*) filter (where prior), count(*) filter (where not prior) into v_returning, v_new from (
    select g.id, exists (select 1 from games p join issues pi on pi.id = p.issue_id
                          where p.subscriber_id = g.subscriber_id and p.mode = 'official' and p.status <> 'in_progress'
                            and pi.issue_number < i.issue_number) as prior
      from games g where g.issue_id = i.id and g.mode = 'official' and g.subscriber_id is not null) x;

  select count(*) into v_shares from events where issue_id = i.id and event_name = 'spark_word_shared';
  select count(*) into v_clicks from events where issue_id = i.id and event_name = 'spark_word_viewed' and props->>'ref' = 'newsletter';
  select count(*) into v_views  from events where issue_id = i.id and event_name = 'spark_word_viewed';

  select coalesce(jsonb_agg(jsonb_build_object('n', n, 'count', c, 'pct', case when v_completed > 0 then round(100.0 * c / v_completed) else 0 end) order by n), '[]'::jsonb)
    into v_dist from (
      select n, (select count(*) from games where issue_id = i.id and mode = 'official' and solved and guess_count = n) as c
        from generate_series(1,6) n
      union all
      select 7, (select count(*) from games where issue_id = i.id and mode = 'official' and status = 'lost')) d;

  select coalesce(jsonb_agg(jsonb_build_object('company', company, 'players', players, 'solved', solved) order by players desc), '[]'::jsonb)
    into v_companies from (
      select min(sub.company) as company, count(*) as players, count(*) filter (where g.solved) as solved
        from games g join subscribers sub on sub.id = g.subscriber_id
       where g.issue_id = i.id and g.mode = 'official' and g.status <> 'in_progress' and sub.company_key is not null
       group by sub.company_key order by players desc limit 10) c;

  v_top := sw_issue_leaderboard(i.issue_number, null, null, 10) -> 'top';

  return jsonb_build_object(
    'ok', true,
    'issue', jsonb_build_object('id', i.id, 'number', i.issue_number, 'title', i.title, 'date', i.publication_date, 'status', i.status,
                                'answer', i.answer, 'category', i.category, 'hint', i.hint, 'explanation', i.explanation),
    'newsletter_recipients', i.newsletter_recipients,
    'link_clicks', v_clicks,
    'page_views', v_views,
    'unique_players', v_started,
    'completed', v_completed,
    'completion_pct', case when v_started > 0 then round(100.0 * v_completed / v_started) else null end,
    'solved', v_solved,
    'win_pct', case when v_completed > 0 then round(100.0 * v_solved / v_completed) else null end,
    'avg_guesses', (select round(avg(guess_count), 2) from games where issue_id = i.id and mode = 'official' and solved),
    'hint_used', v_hint,
    'hint_pct', case when v_completed > 0 then round(100.0 * v_hint / v_completed) else null end,
    'returning_players', v_returning,
    'new_players', v_new,
    'shares', v_shares,
    'flagged', v_flagged,
    'distribution', v_dist,
    'top_companies', v_companies,
    'leaderboard', v_top
  );
end $$;

-- ------------------------------------------------------------
-- Personalised newsletter links for an issue (mail-merge export)
-- ------------------------------------------------------------
-- Builds one game URL from the site_url / url_style settings.
--   path  → https://site/spark-word/014?t=TOKEN            (needs the SPA rewrite)
--   query → https://site/index.html?issue=14&t=TOKEN#spark-word
--           If site_url already names a page (…/spark-word.html) that page is used instead of index.html.
create or replace function sw_game_link(p_issue_number int, p_token text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_site text := rtrim(sw_setting('site_url', 'https://tmtspark.example.com'), '/');
        v_style text := sw_setting('url_style', 'path');
        v_page text;
begin
  if v_style = 'query' then
    v_page := case when v_site ~* '\.html?$' then v_site else v_site || '/index.html' end;
    return v_page || '?issue=' || p_issue_number || '&t=' || p_token || '#spark-word';
  end if;
  return v_site || '/spark-word/' || lpad(p_issue_number::text, 3, '0') || '?t=' || p_token;
end $$;

create or replace function admin_issue_links(p_issue_number int, p_newsletter_only boolean default true)
returns table (email text, first_name text, last_name text, company text, url text)
language plpgsql security definer set search_path = public as $$
begin
  perform sw_require_admin();
  return query
    select s.email::text, s.first_name, s.last_name, s.company,
           sw_game_link(p_issue_number, s.subscriber_token)
      from subscribers s
     where (not p_newsletter_only) or s.newsletter_subscriber
     order by s.email;
end $$;

-- Single link (for the admin "copy my test link" button)
create or replace function admin_subscriber_link(p_subscriber_id uuid, p_issue_number int) returns text
language plpgsql security definer set search_path = public as $$
declare v_tok text;
begin
  perform sw_require_admin();
  select subscriber_token into v_tok from subscribers where id = p_subscriber_id;
  if v_tok is null then return null; end if;
  return sw_game_link(p_issue_number, v_tok);
end $$;

-- ------------------------------------------------------------
-- Subscriber import (JSON array of {email, first_name, last_name, company})
-- Existing emails are updated (never re-tokened); new ones get a token.
-- ------------------------------------------------------------
create or replace function admin_import_subscribers(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; v_ins int := 0; v_upd int := 0; v_skip int := 0; v_email citext;
begin
  perform sw_require_admin();
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_email := lower(trim(coalesce(r->>'email','')));
    if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_skip := v_skip + 1; continue; end if;
    if exists (select 1 from subscribers where email = v_email) then
      update subscribers set
        first_name = coalesce(nullif(trim(r->>'first_name'),''), first_name),
        last_name  = coalesce(nullif(trim(r->>'last_name'),''), last_name),
        company    = coalesce(nullif(trim(r->>'company'),''), company),
        newsletter_subscriber = true
       where email = v_email;
      v_upd := v_upd + 1;
    else
      insert into subscribers (email, first_name, last_name, company, newsletter_subscriber, source)
        values (v_email, nullif(trim(r->>'first_name'),''), nullif(trim(r->>'last_name'),''), nullif(trim(r->>'company'),''), true, 'newsletter_import');
      v_ins := v_ins + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'inserted', v_ins, 'updated', v_upd, 'skipped', v_skip);
end $$;

create or replace function admin_rotate_token(p_subscriber_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  perform sw_require_admin();
  update subscribers set subscriber_token = sw_new_token() where id = p_subscriber_id returning subscriber_token into v;
  return v;
end $$;

-- ------------------------------------------------------------
-- Issue lifecycle
-- ------------------------------------------------------------
create or replace function admin_set_issue_status(p_issue_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i issues%rowtype;
begin
  perform sw_require_admin();
  if p_status not in ('draft','scheduled','active','archived') then
    return jsonb_build_object('ok', false, 'error', 'invalid_status');
  end if;
  update issues set status = p_status::sw_issue_status where id = p_issue_id returning * into i;
  if i.id is null then return jsonb_build_object('ok', false, 'error', 'no_issue'); end if;
  -- activation changes streak context for everyone: refresh cached stats
  if p_status in ('active','archived') then
    perform sw_recompute_subscriber_stats(id) from subscribers where games_played > 0;
  end if;
  return jsonb_build_object('ok', true, 'issue', row_to_json(i)::jsonb);
end $$;

-- Scheduled issues whose publication_date has arrived → activate (call from a cron / pg_cron)
create or replace function admin_activate_due_issues() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; r record;
begin
  for r in select id from issues where status = 'scheduled' and publication_date <= current_date order by issue_number loop
    update issues set status = 'active' where id = r.id;
    n := n + 1;
  end loop;
  if n > 0 then perform sw_recompute_subscriber_stats(id) from subscribers where games_played > 0; end if;
  return n;
end $$;

-- Word bank search helper (dashboard)
create or replace function admin_word_bank_search(p_q text default null, p_category text default null, p_only_available boolean default false)
returns setof word_bank
language plpgsql security definer set search_path = public as $$
begin
  perform sw_require_admin();
  return query
    select * from word_bank w
     where (p_q is null or w.word ilike '%' || p_q || '%' or w.definition ilike '%' || p_q || '%')
       and (p_category is null or w.category = p_category)
       and (not p_only_available or (w.active and not w.used))
     order by w.used asc, w.category, w.word;
end $$;

-- Recompute every subscriber's cached stats (maintenance)
create or replace function admin_recompute_all_stats() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; r record;
begin
  perform sw_require_admin();
  for r in select id from subscribers loop
    perform sw_recompute_subscriber_stats(r.id); n := n + 1;
  end loop;
  return n;
end $$;
