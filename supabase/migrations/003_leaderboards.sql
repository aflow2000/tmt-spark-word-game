-- ============================================================
-- SPARK WORD — 003 · Leaderboards & statistics
--
-- Leaderboards are COMPUTED from `games`, never stored. Only official,
-- completed, unflagged games count. Ranking order everywhere:
--   solved → fewest guesses → no hint → fastest → earliest finish
-- ============================================================

-- Resolve a period filter to a set of issue ids
create or replace function sw_period_issues(p_period text) returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from issues
   where status in ('active','archived')
     and case coalesce(p_period,'all')
           when 'issue' then issue_number = coalesce((select issue_number from issues where status = 'active'),
                                                     (select max(issue_number) from issues where status in ('active','archived')))
           when 'month' then date_trunc('month', publication_date) = date_trunc('month', current_date)
           else true
         end;
$$;

-- ------------------------------------------------------------
-- Issue leaderboard: TOP N + the caller's own position + percentile
-- ------------------------------------------------------------
create or replace function sw_issue_leaderboard(
  p_issue_number int default null,
  p_token text default null,
  p_guest_id text default null,
  p_limit int default 10
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s subscribers%rowtype;
  i issues%rowtype;
  v_total int; v_solved int;
  v_top jsonb; v_me jsonb;
  mine games%rowtype;
begin
  s := sw_resolve_subscriber(p_token);
  if p_issue_number is null then
    select * into i from issues where status = 'active';
    if i.id is null then select * into i from issues where status = 'archived' order by issue_number desc limit 1; end if;
  else
    select * into i from issues where issue_number = p_issue_number and status in ('active','archived');
  end if;
  if i.id is null then return jsonb_build_object('ok', false, 'error', 'no_issue'); end if;

  select count(*), count(*) filter (where solved) into v_total, v_solved
    from games where issue_id = i.id and mode = 'official' and status <> 'in_progress' and not flagged;

  select coalesce(jsonb_agg(row_to_json(r)::jsonb order by r.rank), '[]'::jsonb) into v_top from (
    select rank() over (order by g.solved desc, g.guess_count asc, g.hint_used asc, g.completion_seconds asc, g.completed_at asc) as rank,
           sw_display_name(sub) as name,
           case when sub.id is null then 'Guest' else sub.company end as company,
           sub.id = s.id as is_me,
           g.solved, g.guess_count as guesses, g.hint_used, g.completion_seconds as seconds,
           coalesce(g.streak_at_completion, 0) as streak, g.score as points
      from games g left join subscribers sub on sub.id = g.subscriber_id
     where g.issue_id = i.id and g.mode = 'official' and g.status <> 'in_progress' and not g.flagged and g.solved
     order by rank limit greatest(1, least(coalesce(p_limit,10), 100))
  ) r;

  mine := sw_find_game(i.id, s.id, case when s.id is null then p_guest_id end);
  if mine.id is not null and mine.mode = 'official' and mine.status <> 'in_progress' then
    v_me := sw_game_rank(mine.id) || jsonb_build_object('solved', mine.solved, 'guesses', mine.guess_count, 'hint_used', mine.hint_used,
                                                       'seconds', mine.completion_seconds, 'points', mine.score, 'flagged', mine.flagged);
  end if;

  insert into events (event_name, issue_id, subscriber_id, guest_id, company_key, props)
    values ('spark_word_leaderboard_viewed', i.id, s.id, case when s.id is null then p_guest_id end, s.company_key, jsonb_build_object('board', 'issue'));

  return jsonb_build_object(
    'ok', true,
    'issue', sw_issue_public_json(i),
    'total_players', v_total,
    'solved_players', v_solved,
    'solved_pct', case when v_total > 0 then round(100.0 * v_solved / v_total) else null end,
    'top', v_top,
    'me', v_me
  );
end $$;

-- ------------------------------------------------------------
-- All-Stars: cross-issue points with period + scope filters
--   p_period: 'issue' | 'month' | 'all'
--   p_scope:  'all' | 'tt' | 'industry' | 'company' (with p_company)
-- ------------------------------------------------------------
create or replace function sw_allstars(
  p_period text default 'all',
  p_scope text default 'all',
  p_company text default null,
  p_token text default null,
  p_limit int default 25,
  p_guest_id text default null   -- accepted for a uniform client call signature; guests are never ranked here
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s subscribers%rowtype;
  v_rows jsonb; v_me jsonb; v_key text := sw_company_key(p_company);
begin
  s := sw_resolve_subscriber(p_token);
  with agg as (
    select sub.id, sub.company, sub.company_key, sw_display_name(sub) as name, sw_is_tt(sub) as is_tt,
           sub.current_streak,
           count(*) as issues_played,
           count(*) filter (where g.solved) as wins,
           round(avg(g.guess_count) filter (where g.solved), 2) as avg_guesses,
           sum(g.score) as points,
           max(g.completed_at) as last_played
      from games g join subscribers sub on sub.id = g.subscriber_id
     where g.mode = 'official' and g.status <> 'in_progress' and not g.flagged
       and g.issue_id in (select sw_period_issues(p_period))
       and case coalesce(p_scope,'all')
             when 'tt' then sw_is_tt(sub)
             when 'industry' then not sw_is_tt(sub)
             when 'company' then sub.company_key = v_key
             else true end
     group by sub.id
  ), ranked as (
    select rank() over (order by points desc, wins desc, avg_guesses asc nulls last, last_played asc) as rank, agg.*
      from agg
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank', rank, 'name', name, 'company', company, 'is_me', id = s.id, 'is_tt', is_tt,
           'issues_played', issues_played, 'wins', wins,
           'win_pct', round(100.0 * wins / issues_played), 'avg_guesses', avg_guesses,
           'current_streak', current_streak, 'points', points) order by rank), '[]'::jsonb),
         (select jsonb_build_object('rank', rank, 'total', (select count(*) from ranked), 'points', points, 'issues_played', issues_played,
                                    'win_pct', round(100.0 * wins / issues_played), 'avg_guesses', avg_guesses, 'current_streak', current_streak)
            from ranked where id = s.id)
    into v_rows, v_me
    from (select * from ranked order by rank limit greatest(1, least(coalesce(p_limit,25), 200))) top;

  insert into events (event_name, subscriber_id, company_key, props)
    values ('spark_word_leaderboard_viewed', s.id, s.company_key, jsonb_build_object('board', 'allstars', 'period', p_period, 'scope', p_scope));

  return jsonb_build_object('ok', true, 'period', p_period, 'scope', p_scope, 'company', p_company, 'rows', v_rows, 'me', v_me);
end $$;

-- ------------------------------------------------------------
-- Company standings — normalised so headcount doesn't win.
-- Score = mean, across a company's eligible players, of each player's
-- average points per issue played in the period. Minimum N players.
-- ------------------------------------------------------------
create or replace function sw_company_standings(p_period text default 'all', p_limit int default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_min int := sw_setting('company_min_players','3')::int;
  v_rows jsonb;
begin
  with per_player as (
    select sub.company_key, min(sub.company) as company, sub.id,
           count(*) as issues_played, count(*) filter (where g.solved) as wins,
           avg(g.guess_count) filter (where g.solved) as avg_guesses,
           sum(g.score)::numeric / count(*) as points_per_issue
      from games g join subscribers sub on sub.id = g.subscriber_id
     where g.mode = 'official' and g.status <> 'in_progress' and not g.flagged
       and sub.company_key is not null
       and g.issue_id in (select sw_period_issues(p_period))
     group by sub.company_key, sub.id
  ), per_company as (
    select company_key, min(company) as company, count(*) as players,
           round(avg(points_per_issue), 1) as avg_points,
           round(100.0 * sum(wins) / sum(issues_played)) as win_pct,
           round(avg(avg_guesses), 2) as avg_guesses,
           sum(issues_played) as games
      from per_player group by company_key
     having count(*) >= v_min
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank', rank, 'company', company, 'players', players, 'avg_points', avg_points,
           'win_pct', win_pct, 'avg_guesses', avg_guesses, 'games', games) order by rank), '[]'::jsonb)
    into v_rows
    from (select rank() over (order by avg_points desc, win_pct desc, players desc) as rank, * from per_company
          order by rank limit greatest(1, least(coalesce(p_limit,10), 100))) x;
  return jsonb_build_object('ok', true, 'period', p_period, 'min_players', v_min, 'rows', v_rows,
    'methodology', 'Each player''s points are averaged per issue played in the period; a company''s score is the mean of its players'' averages. Companies need at least ' || v_min || ' players with a completed official game to appear, so large organisations cannot win on headcount alone.');
end $$;

-- ------------------------------------------------------------
-- "Last issue" shareout block for the next newsletter.
-- The word is masked unless the caller has completed that issue (or is admin).
-- ------------------------------------------------------------
create or replace function sw_last_issue_summary(p_token text default null, p_guest_id text default null, p_issue_number int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s subscribers%rowtype; i issues%rowtype; g games%rowtype;
  v_reveal boolean; v_total int; v_solved int; v_top jsonb; v_champ text;
begin
  s := sw_resolve_subscriber(p_token);
  if p_issue_number is not null then
    select * into i from issues where issue_number = p_issue_number and status in ('active','archived');
  else
    select * into i from issues where status = 'archived' order by issue_number desc limit 1;
  end if;
  if i.id is null then return jsonb_build_object('ok', false, 'error', 'no_issue'); end if;
  g := sw_find_game(i.id, s.id, case when s.id is null then p_guest_id end);
  v_reveal := sw_is_admin() or (g.id is not null and g.status <> 'in_progress');
  select count(*), count(*) filter (where solved) into v_total, v_solved
    from games where issue_id = i.id and mode = 'official' and status <> 'in_progress' and not flagged;
  select coalesce(jsonb_agg(jsonb_build_object('rank', r.rank, 'name', r.name, 'company', r.company, 'guesses', r.guesses) order by r.rank), '[]'::jsonb)
    into v_top from (
      select rank() over (order by g2.guess_count asc, g2.hint_used asc, g2.completion_seconds asc, g2.completed_at asc) as rank,
             sw_display_name(sub) as name, sub.company, g2.guess_count as guesses
        from games g2 join subscribers sub on sub.id = g2.subscriber_id
       where g2.issue_id = i.id and g2.mode = 'official' and g2.solved and not g2.flagged
       order by rank limit 3) r;
  -- Company champion for the issue itself (same normalised method, this issue only)
  with per_player as (
    select sub.company_key, min(sub.company) as company, sub.id, avg(g4.score) as pts
      from games g4 join subscribers sub on sub.id = g4.subscriber_id
     where g4.issue_id = i.id and g4.mode = 'official' and g4.status <> 'in_progress' and not g4.flagged and sub.company_key is not null
     group by sub.company_key, sub.id)
  select min(company) into v_champ from (
    select company_key, min(company) as company, avg(pts) as score, count(*) as players from per_player group by company_key
    having count(*) >= sw_setting('company_min_players','3')::int order by score desc limit 1) c;
  return jsonb_build_object(
    'ok', true,
    'issue', sw_issue_public_json(i),
    'revealed', v_reveal,
    'answer', case when v_reveal then i.answer end,
    'answer_masked', left(i.answer,1) || '····',
    'players', v_total,
    'solved_pct', case when v_total > 0 then round(100.0 * v_solved / v_total) else null end,
    'top', v_top,
    'company_champion', v_champ
  );
end $$;

-- Caller's own stats (used by the profile drawer)
create or replace function sw_my_stats(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s subscribers%rowtype;
begin
  s := sw_resolve_subscriber(p_token);
  if s.id is null then return jsonb_build_object('ok', false, 'error', 'not_recognized'); end if;
  return jsonb_build_object('ok', true, 'player', sw_player_json(s),
    'distribution', (select coalesce(jsonb_object_agg(n, c), '{}'::jsonb) from (
        select guess_count as n, count(*) as c from games where subscriber_id = s.id and mode = 'official' and solved group by guess_count) d),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('issue', i.issue_number, 'date', i.publication_date, 'solved', g.solved,
                        'guesses', g.guess_count, 'points', g.score, 'rank', (sw_game_rank(g.id)->>'rank')::int) order by i.issue_number desc), '[]'::jsonb)
                  from games g join issues i on i.id = g.issue_id
                 where g.subscriber_id = s.id and g.mode = 'official' and g.status <> 'in_progress'));
end $$;
