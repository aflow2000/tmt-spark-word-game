-- ============================================================
-- SPARK WORD — 002 · Gameplay functions
--
-- All functions the game client calls are SECURITY DEFINER and are
-- the ONLY way the anon role touches the database. The answer for an
-- issue never leaves the database until a game is over.
-- ============================================================

-- ------------------------------------------------------------
-- Identity helpers
-- ------------------------------------------------------------
create or replace function sw_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

create or replace function sw_resolve_subscriber(p_token text) returns subscribers
language sql stable security definer set search_path = public as $$
  select s.* from subscribers s where p_token is not null and s.subscriber_token = p_token limit 1;
$$;

-- ------------------------------------------------------------
-- Core evaluation (two-pass: exact matches first, then leftovers)
-- Handles repeated letters correctly, e.g. answer STEEL / guess EERIE
-- → E(present) E(present→absent after count) R(absent) I(absent) E(absent)
-- ------------------------------------------------------------
create or replace function sw_evaluate(p_guess text, p_answer text) returns text
language plpgsql immutable strict as $$
declare
  g text := upper(p_guess);
  a text := upper(p_answer);
  res char[] := array['a','a','a','a','a'];
  remaining text := '';
  i int;
  ch text;
  pos int;
begin
  if length(g) <> 5 or length(a) <> 5 then
    raise exception 'sw_evaluate expects two five-letter words';
  end if;
  -- pass 1: correct positions; collect the unmatched answer letters
  for i in 1..5 loop
    if substr(g,i,1) = substr(a,i,1) then
      res[i] := 'c';
    else
      remaining := remaining || substr(a,i,1);
    end if;
  end loop;
  -- pass 2: present letters, consuming from the remaining pool once each
  for i in 1..5 loop
    if res[i] = 'c' then continue; end if;
    ch := substr(g,i,1);
    pos := position(ch in remaining);
    if pos > 0 then
      res[i] := 'p';
      remaining := overlay(remaining placing '' from pos for 1);
    end if;
  end loop;
  return array_to_string(res, '');
end $$;

-- ------------------------------------------------------------
-- Scoring
--   1 → 100 · 2 → 80 · 3 → 65 · 4 → 50 · 5 → 35 · 6 → 20 · fail → 0
--   hint used → −5 · streak bonus +2 per consecutive issue (capped)
-- ------------------------------------------------------------
create or replace function sw_score(p_solved boolean, p_guess_count int, p_hint_used boolean, p_streak int) returns int
language plpgsql stable as $$
declare
  base int;
  cap int := sw_setting('streak_bonus_cap', '10')::int;
begin
  if not p_solved then return 0; end if;
  base := case p_guess_count when 1 then 100 when 2 then 80 when 3 then 65 when 4 then 50 when 5 then 35 else 20 end;
  if p_hint_used then base := base - 5; end if;
  return greatest(0, base) + least(coalesce(p_streak,0), cap) * 2;
end $$;

-- ------------------------------------------------------------
-- Streaks — ISSUE based.
-- Published issues (active + archived) are ordered by issue_number.
-- sw_streak_ending_at(subscriber, n): consecutive published issues ending
--   at issue n (inclusive) that the subscriber completed officially.
-- sw_current_streak(subscriber): same, ending at the newest published
--   issue — except the currently ACTIVE issue may still be unplayed
--   without breaking the streak (it only breaks once it is archived).
-- ------------------------------------------------------------
create or replace function sw_streak_ending_at(p_subscriber_id uuid, p_issue_number int) returns int
language plpgsql stable security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select i.issue_number,
           exists (select 1 from games g
                    where g.subscriber_id = p_subscriber_id and g.issue_id = i.id
                      and g.mode = 'official' and g.status <> 'in_progress') as played
      from issues i
     where i.status in ('active','archived') and i.issue_number <= p_issue_number
     order by i.issue_number desc
  loop
    exit when not r.played;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function sw_current_streak(p_subscriber_id uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare
  v_latest issues%rowtype;
  v_played boolean;
  v_prev int;
begin
  select * into v_latest from issues where status in ('active','archived') order by issue_number desc limit 1;
  if v_latest.id is null then return 0; end if;
  select exists (select 1 from games where subscriber_id = p_subscriber_id and issue_id = v_latest.id
                   and mode = 'official' and status <> 'in_progress') into v_played;
  if v_played then
    return sw_streak_ending_at(p_subscriber_id, v_latest.issue_number);
  elsif v_latest.status = 'active' then
    -- still open: streak carries from the previous published issue
    select issue_number into v_prev from issues
     where status = 'archived' and issue_number < v_latest.issue_number
     order by issue_number desc limit 1;
    if v_prev is null then return 0; end if;
    return sw_streak_ending_at(p_subscriber_id, v_prev);
  else
    return 0;
  end if;
end $$;

-- Best streak ever: longest run of consecutive published issues played
create or replace function sw_best_streak(p_subscriber_id uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare
  r record; run int := 0; best int := 0;
begin
  for r in
    select exists (select 1 from games g where g.subscriber_id = p_subscriber_id and g.issue_id = i.id
                     and g.mode = 'official' and g.status <> 'in_progress') as played
      from issues i where i.status in ('active','archived') order by i.issue_number
  loop
    if r.played then run := run + 1; best := greatest(best, run); else run := 0; end if;
  end loop;
  return best;
end $$;

-- ------------------------------------------------------------
-- Cached subscriber stats (official games only)
-- ------------------------------------------------------------
create or replace function sw_recompute_subscriber_stats(p_subscriber_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update subscribers s set
    games_played    = coalesce(a.played, 0),
    games_won       = coalesce(a.won, 0),
    average_guesses = a.avg_guesses,
    total_points    = coalesce(a.points, 0),
    current_streak  = sw_current_streak(p_subscriber_id),
    best_streak     = sw_best_streak(p_subscriber_id)
  from (
    select count(*) filter (where status <> 'in_progress') as played,
           count(*) filter (where solved) as won,
           round(avg(guess_count) filter (where solved), 2) as avg_guesses,
           sum(score) filter (where status <> 'in_progress') as points
      from games where subscriber_id = p_subscriber_id and mode = 'official' and not flagged
  ) a
  where s.id = p_subscriber_id;
end $$;

-- ------------------------------------------------------------
-- Presentation helpers
-- ------------------------------------------------------------
create or replace function sw_display_name(s subscribers) returns text
language sql immutable as $$
  select case s.leaderboard_visibility
    when 'anonymous' then 'Anonymous'
    when 'full_name' then coalesce(nullif(s.display_name,''),
                            nullif(trim(coalesce(s.first_name,'') || ' ' || coalesce(s.last_name,'')),''), 'Spark Player')
    else coalesce(
           nullif(trim(coalesce(s.first_name,'') || case when coalesce(s.last_name,'') <> '' then ' ' || left(s.last_name,1) || '.' else '' end),''),
           nullif(s.display_name,''), 'Spark Player')
  end;
$$;

create or replace function sw_is_tt(s subscribers) returns boolean
language sql immutable as $$
  select coalesce(s.company_key in ('turner & townsend','turner townsend','turner and townsend','t&t'), false)
      or s.email::text ilike '%@turntown.com';
$$;

create or replace function sw_player_json(s subscribers) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'recognized', true,
    'id', s.id,
    'first_name', s.first_name,
    'name', sw_display_name(s),
    'company', s.company,
    'newsletter_subscriber', s.newsletter_subscriber,
    'visibility', s.leaderboard_visibility,
    'is_tt', sw_is_tt(s),
    'stats', jsonb_build_object(
      'games_played', s.games_played,
      'games_won', s.games_won,
      'win_pct', case when s.games_played > 0 then round(100.0 * s.games_won / s.games_played) else null end,
      'average_guesses', s.average_guesses,
      'current_streak', s.current_streak,
      'best_streak', s.best_streak,
      'total_points', s.total_points
    )
  );
$$;

-- Public-safe issue JSON (never includes answer / hint / explanation)
create or replace function sw_issue_public_json(i issues) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', i.id,
    'number', i.issue_number,
    'slug', i.slug,
    'title', i.title,
    'date', i.publication_date,
    'category', i.category,
    'status', i.status,
    'is_active', i.status = 'active',
    'players_completed', (select count(*) from games g where g.issue_id = i.id and g.mode = 'official' and g.status <> 'in_progress'),
    'players_started',   (select count(*) from games g where g.issue_id = i.id and g.mode = 'official')
  );
$$;

-- Rank of a game within its issue (official, completed, unflagged games only).
-- Ordering: solved → fewest guesses → no hint → fastest → earliest finish.
create or replace function sw_game_rank(p_game_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  g games%rowtype;
  v_rank int; v_total int; v_solved int;
begin
  select * into g from games where id = p_game_id;
  if g.id is null then return null; end if;
  select count(*), count(*) filter (where solved) into v_total, v_solved
    from games where issue_id = g.issue_id and mode = 'official' and status <> 'in_progress' and not flagged;
  if g.mode <> 'official' or g.status = 'in_progress' or g.flagged or not g.solved then
    return jsonb_build_object('rank', null, 'total', v_total, 'solved_total', v_solved, 'percentile', null);
  end if;
  select r into v_rank from (
    select id, rank() over (order by solved desc, guess_count asc, hint_used asc, completion_seconds asc, completed_at asc) as r
      from games where issue_id = g.issue_id and mode = 'official' and status <> 'in_progress' and not flagged
  ) x where x.id = g.id;
  return jsonb_build_object('rank', v_rank, 'total', v_total, 'solved_total', v_solved,
                            'percentile', greatest(1, ceil(100.0 * v_rank / greatest(v_total,1))::int));
end $$;

-- Badges (restrained gamification)
create or replace function sw_badges(p_solved boolean, p_guess_count int, p_streak int, p_rank int, p_total int default 0) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(b), '[]'::jsonb) from (
    select 'LIGHTNING STRIKE' as b where p_solved and p_guess_count = 1
    union all select 'HIGH VOLTAGE'   where p_solved and p_guess_count = 2
    union all select 'FULLY CHARGED'  where p_solved and p_guess_count = 3
    union all select 'ON A ROLL'      where coalesce(p_streak,0) >= 5
    -- Top 10 only means something once the field is bigger than 10
    union all select 'TOP OF THE GRID' where p_rank is not null and p_rank <= 10 and coalesce(p_total,0) >= 20
  ) x;
$$;

-- Everything the client may see once a game is over
create or replace function sw_completion_json(g games) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  i issues%rowtype;
  w word_bank%rowtype;
  s subscribers%rowtype;
  rk jsonb;
  nxt issues%rowtype;
  v_streak int;
begin
  if g.status = 'in_progress' then return null; end if;
  select * into i from issues where id = g.issue_id;
  select * into w from word_bank where word = i.answer;
  if g.subscriber_id is not null then
    select * into s from subscribers where id = g.subscriber_id;
    v_streak := s.current_streak;
  end if;
  rk := sw_game_rank(g.id);
  select * into nxt from issues where issue_number > i.issue_number and status in ('scheduled','draft','active')
   order by issue_number asc limit 1;
  return jsonb_build_object(
    'answer', i.answer,
    'category', i.category,
    'explanation', i.explanation,
    'definition', w.definition,
    'learn', case when w.related_type is not null then jsonb_build_object('type', w.related_type, 'ref', w.related_ref) else null end,
    'solved', g.solved,
    'guess_count', g.guess_count,
    'hint_used', g.hint_used,
    'completion_seconds', g.completion_seconds,
    'score', g.score,
    'mode', g.mode,
    'flagged', g.flagged,
    'rank', rk,
    'badges', sw_badges(g.solved, g.guess_count, coalesce(g.streak_at_completion, v_streak), (rk->>'rank')::int, (rk->>'total')::int),
    'streak', jsonb_build_object('current', coalesce(v_streak, 0), 'best', coalesce(s.best_streak, 0)),
    'player', case when s.id is not null then sw_player_json(s) else null end,
    'players_completed', (select count(*) from games x where x.issue_id = i.id and x.mode = 'official' and x.status <> 'in_progress'),
    'next_issue', case when nxt.id is not null then jsonb_build_object('number', nxt.issue_number, 'date', nxt.publication_date) else null end,
    'newsletter_subscriber', coalesce(s.newsletter_subscriber, false)
  );
end $$;

create or replace function sw_game_json(g games) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  i issues%rowtype;
  unlock_after int := sw_setting('hint_unlock_after', '3')::int;
  second_after int := sw_setting('second_spark_after', '5')::int;
begin
  select * into i from issues where id = g.issue_id;
  return jsonb_build_object(
    'id', g.id,
    'issue_number', i.issue_number,
    'mode', g.mode,
    'status', g.status,
    'guess_count', g.guess_count,
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('word', q.word, 'result', q.result) order by q.guess_number), '[]'::jsonb)
               from guesses q where q.game_id = g.id),
    'hint_available', g.status = 'in_progress' and g.guess_count >= unlock_after and i.hint is not null,
    'hint_used', g.hint_used,
    'hint', case when g.hint_used then i.hint else null end,
    'hint_unlock_after', unlock_after,
    'second_spark_after', second_after,
    'second_spark_available', g.status = 'in_progress' and g.hint_used and second_after > 0 and g.guess_count >= second_after,
    'first_letter', case when g.hint_used and second_after > 0 and g.guess_count >= second_after then left(i.answer, 1) end,
    'started_at', g.started_at,
    'result', sw_completion_json(g)
  );
end $$;

-- What mode would a NEW game be for this caller + issue?
create or replace function sw_new_game_mode(p_issue issues, p_subscriber_id uuid, p_guest_id text) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if p_issue.status in ('draft','scheduled') then
    return case when sw_is_admin() then 'preview' else 'closed' end;
  end if;
  if p_issue.status = 'archived' then return 'archive'; end if;
  -- active issue
  if p_subscriber_id is not null and exists (select 1 from games where subscriber_id = p_subscriber_id and issue_id = p_issue.id and mode = 'official') then
    return 'archive';
  end if;
  if p_subscriber_id is null and p_guest_id is not null and exists (select 1 from games where guest_id = p_guest_id and subscriber_id is null and issue_id = p_issue.id and mode = 'official') then
    return 'archive';
  end if;
  return 'official';
end $$;

-- Locate the game to show/resume for a caller on an issue: in-progress first, else the official one.
create or replace function sw_find_game(p_issue_id uuid, p_subscriber_id uuid, p_guest_id text, p_game_id uuid default null) returns games
language plpgsql stable security definer set search_path = public as $$
declare g games%rowtype;
begin
  if p_game_id is not null then
    select * into g from games where id = p_game_id and issue_id = p_issue_id
       and ((p_subscriber_id is not null and subscriber_id = p_subscriber_id)
         or (p_subscriber_id is null and subscriber_id is null and guest_id = p_guest_id));
    if g.id is not null then return g; end if;
  end if;
  if p_subscriber_id is not null then
    select * into g from games where subscriber_id = p_subscriber_id and issue_id = p_issue_id
     order by (status = 'in_progress') desc, (mode = 'official') desc, created_at desc limit 1;
  elsif p_guest_id is not null then
    select * into g from games where subscriber_id is null and guest_id = p_guest_id and issue_id = p_issue_id
     order by (status = 'in_progress') desc, (mode = 'official') desc, created_at desc limit 1;
  end if;
  return g;
end $$;

-- ------------------------------------------------------------
-- sw_bootstrap — first call on page load
-- ------------------------------------------------------------
create or replace function sw_bootstrap(
  p_issue_number int default null,
  p_token text default null,
  p_guest_id text default null,
  p_ref text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s subscribers%rowtype;
  i issues%rowtype;
  g games%rowtype;
  v_active int;
  v_latest int;
begin
  s := sw_resolve_subscriber(p_token);
  if s.id is not null then
    update subscribers set last_seen_at = now() where id = s.id;
  end if;

  select issue_number into v_active from issues where status = 'active';
  select max(issue_number) into v_latest from issues where status in ('active','archived');

  if p_issue_number is not null then
    select * into i from issues where issue_number = p_issue_number;
  else
    select * into i from issues where issue_number = coalesce(v_active, v_latest);
  end if;

  if i.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_issue', 'active_issue_number', v_active, 'latest_issue_number', v_latest,
                              'player', case when s.id is not null then sw_player_json(s) else null end);
  end if;
  if i.status in ('draft','scheduled') and not sw_is_admin() then
    return jsonb_build_object('ok', false, 'error', 'issue_not_published', 'active_issue_number', v_active, 'latest_issue_number', v_latest,
                              'player', case when s.id is not null then sw_player_json(s) else null end);
  end if;

  g := sw_find_game(i.id, s.id, case when s.id is null then p_guest_id end);

  return jsonb_build_object(
    'ok', true,
    'now', now(),
    'issue', sw_issue_public_json(i),
    'active_issue_number', v_active,
    'latest_issue_number', v_latest,
    'player', case when s.id is not null then sw_player_json(s) else null end,
    'game', case when g.id is not null then sw_game_json(g) else null end,
    'new_game_mode', sw_new_game_mode(i, s.id, case when s.id is null then p_guest_id end),
    'settings', jsonb_build_object(
      'hint_unlock_after', sw_setting('hint_unlock_after','3')::int,
      'second_spark_after', sw_setting('second_spark_after','5')::int,
      'require_verification_new', sw_setting('require_verification_for_new_emails','false')
    )
  );
end $$;

-- ------------------------------------------------------------
-- sw_submit_guess — the heart of the game
-- ------------------------------------------------------------
create or replace function sw_submit_guess(
  p_issue_number int,
  p_guess text,
  p_token text default null,
  p_guest_id text default null,
  p_game_id uuid default null,
  p_ref text default null,
  p_user_agent text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s subscribers%rowtype;
  i issues%rowtype;
  g games%rowtype;
  v_guess text := upper(regexp_replace(coalesce(p_guess,''), '[^A-Za-z]', '', 'g'));
  v_mode text;
  v_result text;
  v_n int;
  v_now timestamptz := clock_timestamp();
  v_streak int := 0;
  v_seconds int;
  v_min_per_guess numeric := sw_setting('min_seconds_per_guess','0.7')::numeric;
  unlock_after int := sw_setting('hint_unlock_after','3')::int;
  second_after int := sw_setting('second_spark_after','5')::int;
begin
  s := sw_resolve_subscriber(p_token);
  select * into i from issues where issue_number = p_issue_number;
  if i.id is null then return jsonb_build_object('ok', false, 'error', 'no_issue'); end if;

  -- validate guess
  if length(v_guess) <> 5 then return jsonb_build_object('ok', false, 'error', 'invalid_length'); end if;
  if not exists (select 1 from dictionary where word = lower(v_guess)) then
    return jsonb_build_object('ok', false, 'error', 'not_in_dictionary');
  end if;

  -- find or create the game
  g := sw_find_game(i.id, s.id, case when s.id is null then p_guest_id end, p_game_id);
  if g.id is not null and g.status <> 'in_progress' then
    -- the located game is finished: start a fresh one only if a replay is allowed
    g := null;
  end if;
  if g.id is null then
    if s.id is null and p_guest_id is null then
      return jsonb_build_object('ok', false, 'error', 'no_identity');
    end if;
    v_mode := sw_new_game_mode(i, s.id, case when s.id is null then p_guest_id end);
    if v_mode = 'closed' then return jsonb_build_object('ok', false, 'error', 'issue_not_published'); end if;
    insert into games (issue_id, subscriber_id, guest_id, mode, started_at, ref, user_agent)
      values (i.id, s.id, case when s.id is null then p_guest_id end, v_mode::sw_game_mode, v_now, p_ref, left(p_user_agent, 300))
      returning * into g;
    insert into events (event_name, issue_id, subscriber_id, guest_id, game_id, company_key, props)
      values ('spark_word_started', i.id, s.id, case when s.id is null then p_guest_id end, g.id, s.company_key,
              jsonb_build_object('mode', g.mode, 'ref', p_ref));
  end if;

  -- evaluate
  v_n := g.guess_count + 1;
  v_result := sw_evaluate(v_guess, i.answer);
  insert into guesses (game_id, guess_number, word, result, created_at) values (g.id, v_n, v_guess, v_result, v_now);
  insert into events (event_name, issue_id, subscriber_id, guest_id, game_id, company_key, props)
    values ('spark_word_guess', i.id, g.subscriber_id, g.guest_id, g.id, s.company_key,
            jsonb_build_object('guess_number', v_n, 'mode', g.mode));

  g.guess_count := v_n;
  g.last_guess_at := v_now;

  if v_result = 'ccccc' or v_n >= 6 then
    g.solved := (v_result = 'ccccc');
    g.status := case when g.solved then 'won' else 'lost' end;
    g.completed_at := v_now;
    g.completion_seconds := greatest(0, floor(extract(epoch from (v_now - g.started_at)))::int);
    -- anti-cheat: inhuman cadence → flagged (kept, but excluded from ranking)
    if v_n >= 2 and extract(epoch from (v_now - g.started_at)) < v_min_per_guess * (v_n - 1) then
      g.flagged := true; g.flag_reason := 'guess cadence below ' || v_min_per_guess || 's per guess';
    end if;
    if g.mode = 'official' and g.subscriber_id is not null then
      -- consecutive published issues played BEFORE this one, plus this one
      v_streak := sw_streak_ending_at(g.subscriber_id, i.issue_number - 1) + 1;
    elsif g.mode = 'official' then
      v_streak := 1; -- guest: no history yet
    end if;
    g.streak_at_completion := case when g.mode = 'official' then v_streak else null end;
    g.score := case when g.mode = 'official' then sw_score(g.solved, g.guess_count, g.hint_used, v_streak) else 0 end;
  end if;

  update games set guess_count = g.guess_count, last_guess_at = g.last_guess_at, solved = g.solved, status = g.status,
                   completed_at = g.completed_at, completion_seconds = g.completion_seconds, flagged = g.flagged,
                   flag_reason = g.flag_reason, streak_at_completion = g.streak_at_completion, score = g.score
   where id = g.id;

  if g.status <> 'in_progress' then
    if g.subscriber_id is not null and g.mode = 'official' then
      perform sw_recompute_subscriber_stats(g.subscriber_id);
    end if;
    insert into events (event_name, issue_id, subscriber_id, guest_id, game_id, company_key, props)
      values (case when g.solved then 'spark_word_completed' else 'spark_word_failed' end, i.id, g.subscriber_id, g.guest_id, g.id, s.company_key,
              jsonb_build_object('guess_count', g.guess_count, 'hint_used', g.hint_used, 'mode', g.mode, 'seconds', g.completion_seconds));
    select * into g from games where id = g.id; -- reload for presentation
  end if;

  return jsonb_build_object(
    'ok', true,
    'game_id', g.id,
    'mode', g.mode,
    'guess_number', v_n,
    'word', v_guess,
    'result', v_result,
    'status', g.status,
    'hint_available', g.status = 'in_progress' and g.guess_count >= unlock_after and i.hint is not null,
    'hint_used', g.hint_used,
    'second_spark_available', g.status = 'in_progress' and g.hint_used and second_after > 0 and g.guess_count >= second_after,
    'first_letter', case when g.status = 'in_progress' and g.hint_used and second_after > 0 and g.guess_count >= second_after then left(i.answer, 1) end,
    'completion', case when g.status <> 'in_progress' then sw_completion_json(g) else null end
  );
end $$;

-- ------------------------------------------------------------
-- sw_use_hint — unlocked server-side after N guesses
-- ------------------------------------------------------------
create or replace function sw_use_hint(p_game_id uuid, p_token text default null, p_guest_id text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s subscribers%rowtype; g games%rowtype; i issues%rowtype;
  unlock_after int := sw_setting('hint_unlock_after','3')::int;
  second_after int := sw_setting('second_spark_after','5')::int;
begin
  s := sw_resolve_subscriber(p_token);
  select * into g from games where id = p_game_id
     and ((s.id is not null and subscriber_id = s.id) or (s.id is null and subscriber_id is null and guest_id = p_guest_id));
  if g.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  select * into i from issues where id = g.issue_id;
  if g.status <> 'in_progress' then return jsonb_build_object('ok', false, 'error', 'game_over'); end if;
  if i.hint is null then return jsonb_build_object('ok', false, 'error', 'no_hint'); end if;
  if g.guess_count < unlock_after then return jsonb_build_object('ok', false, 'error', 'locked', 'unlock_after', unlock_after); end if;
  if not g.hint_used then
    update games set hint_used = true, hint_used_at = now() where id = g.id;
    insert into events (event_name, issue_id, subscriber_id, guest_id, game_id, company_key, props)
      values ('spark_word_hint_used', i.id, g.subscriber_id, g.guest_id, g.id, s.company_key, jsonb_build_object('guess_count', g.guess_count));
  end if;
  -- "second spark": once the hint is used and the player is still stuck late in the game, offer the first letter
  return jsonb_build_object('ok', true, 'hint', i.hint,
    'second_spark_available', second_after > 0 and g.guess_count >= second_after,
    'first_letter', case when second_after > 0 and g.guess_count >= second_after then left(i.answer, 1) end);
end $$;

-- ------------------------------------------------------------
-- Guest → subscriber: claim a profile once
-- ------------------------------------------------------------
create or replace function sw_attach_guest_games(p_subscriber_id uuid, p_guest_id text) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select * from games where guest_id = p_guest_id and subscriber_id is null order by created_at loop
    if r.mode = 'official' and exists (select 1 from games where subscriber_id = p_subscriber_id and issue_id = r.issue_id and mode = 'official') then
      update games set subscriber_id = p_subscriber_id, mode = 'archive', score = 0, streak_at_completion = null where id = r.id;
    else
      update games set subscriber_id = p_subscriber_id where id = r.id;
    end if;
    n := n + 1;
  end loop;
  -- official games that are now attributed need scores recomputed with the real streak
  for r in select * from games where subscriber_id = p_subscriber_id and mode = 'official' and status <> 'in_progress' and guest_id = p_guest_id
           order by (select issue_number from issues where id = issue_id) loop
    update games set streak_at_completion = sw_streak_ending_at(p_subscriber_id, (select issue_number from issues where id = r.issue_id)),
                     score = sw_score(r.solved, r.guess_count, r.hint_used, sw_streak_ending_at(p_subscriber_id, (select issue_number from issues where id = r.issue_id)))
     where id = r.id;
  end loop;
  update events set subscriber_id = p_subscriber_id where guest_id = p_guest_id and subscriber_id is null;
  perform sw_recompute_subscriber_stats(p_subscriber_id);
  return n;
end $$;

create or replace function sw_claim_profile(
  p_guest_id text,
  p_email text,
  p_first_name text,
  p_last_name text default null,
  p_company text default null,
  p_visibility text default 'first_last_initial',
  p_game_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email citext := lower(trim(coalesce(p_email,'')));
  s subscribers%rowtype;
  v_require_new boolean := sw_setting('require_verification_for_new_emails','false') = 'true';
  g games%rowtype;
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'invalid_email'); end if;
  if coalesce(trim(p_first_name),'') = '' then return jsonb_build_object('ok', false, 'error', 'first_name_required'); end if;
  if coalesce(trim(p_company),'') = '' then return jsonb_build_object('ok', false, 'error', 'company_required'); end if;
  if p_guest_id is null then return jsonb_build_object('ok', false, 'error', 'no_identity'); end if;
  if p_visibility not in ('first_last_initial','full_name','anonymous') then return jsonb_build_object('ok', false, 'error', 'invalid_visibility'); end if;

  select * into s from subscribers where email = v_email;
  if s.id is not null or v_require_new then
    -- Existing subscriber (or strict mode): never hand out a token on an unverified claim.
    return jsonb_build_object('ok', true, 'status', 'verify_required', 'email', v_email::text);
  end if;

  insert into subscribers (email, first_name, last_name, company, leaderboard_visibility, newsletter_subscriber, source, email_verified)
    values (v_email, trim(p_first_name), nullif(trim(p_last_name),''), trim(p_company), p_visibility::sw_visibility, false, 'public_claim', false)
    returning * into s;
  perform sw_attach_guest_games(s.id, p_guest_id);
  select * into s from subscribers where id = s.id;
  if p_game_id is not null then select * into g from games where id = p_game_id and subscriber_id = s.id; end if;
  insert into events (event_name, issue_id, subscriber_id, game_id, company_key, props)
    values ('spark_word_profile_claimed', g.issue_id, s.id, g.id, s.company_key, jsonb_build_object('verified', false));
  return jsonb_build_object('ok', true, 'status', 'created', 'token', s.subscriber_token, 'player', sw_player_json(s),
                            'game', case when g.id is not null then sw_game_json(g) else null end);
end $$;

-- Called with a Supabase Auth session after the magic-link round trip.
create or replace function sw_verified_link(
  p_guest_id text default null,
  p_first_name text default null,
  p_last_name text default null,
  p_company text default null,
  p_visibility text default null,
  p_game_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email citext := lower(coalesce(auth.jwt() ->> 'email', ''));
  s subscribers%rowtype;
  g games%rowtype;
begin
  if v_email = '' then return jsonb_build_object('ok', false, 'error', 'not_authenticated'); end if;
  select * into s from subscribers where email = v_email;
  if s.id is null then
    insert into subscribers (email, first_name, last_name, company, leaderboard_visibility, newsletter_subscriber, source, email_verified, auth_user_id)
      values (v_email, nullif(trim(p_first_name),''), nullif(trim(p_last_name),''), nullif(trim(p_company),''),
              coalesce(p_visibility,'first_last_initial')::sw_visibility, false, 'verified_claim', true, auth.uid())
      returning * into s;
  else
    update subscribers set
      email_verified = true,
      auth_user_id = coalesce(auth_user_id, auth.uid()),
      first_name = coalesce(first_name, nullif(trim(p_first_name),'')),
      last_name  = coalesce(last_name,  nullif(trim(p_last_name),'')),
      company    = coalesce(company,    nullif(trim(p_company),'')),
      leaderboard_visibility = coalesce(p_visibility::sw_visibility, leaderboard_visibility)
     where id = s.id returning * into s;
  end if;
  if p_guest_id is not null then perform sw_attach_guest_games(s.id, p_guest_id); end if;
  select * into s from subscribers where id = s.id;
  if p_game_id is not null then select * into g from games where id = p_game_id and subscriber_id = s.id; end if;
  insert into events (event_name, issue_id, subscriber_id, game_id, company_key, props)
    values ('spark_word_profile_claimed', g.issue_id, s.id, g.id, s.company_key, jsonb_build_object('verified', true));
  return jsonb_build_object('ok', true, 'status', 'linked', 'token', s.subscriber_token, 'player', sw_player_json(s),
                            'game', case when g.id is not null then sw_game_json(g) else null end);
end $$;

-- Display preference / name
create or replace function sw_update_profile(p_token text, p_visibility text default null, p_display_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s subscribers%rowtype;
begin
  s := sw_resolve_subscriber(p_token);
  if s.id is null then return jsonb_build_object('ok', false, 'error', 'not_recognized'); end if;
  if p_visibility is not null and p_visibility not in ('first_last_initial','full_name','anonymous') then
    return jsonb_build_object('ok', false, 'error', 'invalid_visibility');
  end if;
  update subscribers set
    leaderboard_visibility = coalesce(p_visibility::sw_visibility, leaderboard_visibility),
    display_name = case when p_display_name is not null then nullif(left(trim(p_display_name), 40), '') else display_name end
   where id = s.id returning * into s;
  return jsonb_build_object('ok', true, 'player', sw_player_json(s));
end $$;

-- ------------------------------------------------------------
-- Analytics hook (event names are whitelisted; the answer is never stored)
-- ------------------------------------------------------------
create or replace function sw_track(
  p_event text,
  p_issue_number int default null,
  p_game_id uuid default null,
  p_token text default null,
  p_guest_id text default null,
  p_props jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s subscribers%rowtype; v_issue uuid;
begin
  if p_event not in ('spark_word_viewed','spark_word_shared','spark_word_leaderboard_viewed','spark_word_archive_played',
                     'spark_word_link_clicked','spark_word_onboarding_seen','spark_word_claim_opened') then
    return jsonb_build_object('ok', false, 'error', 'unknown_event');
  end if;
  s := sw_resolve_subscriber(p_token);
  select id into v_issue from issues where issue_number = p_issue_number;
  insert into events (event_name, issue_id, subscriber_id, guest_id, game_id, company_key, props)
    values (p_event, v_issue, s.id, case when s.id is null then p_guest_id end, p_game_id, s.company_key,
            (coalesce(p_props, '{}'::jsonb) - 'answer' - 'word' - 'email'));
  return jsonb_build_object('ok', true);
end $$;

-- ------------------------------------------------------------
-- Archive — past Spark Words (answers only for issues the caller completed)
-- ------------------------------------------------------------
create or replace function sw_archive(p_token text default null, p_guest_id text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s subscribers%rowtype;
begin
  s := sw_resolve_subscriber(p_token);
  return jsonb_build_object('ok', true, 'issues', (
    select coalesce(jsonb_agg(jsonb_build_object(
        'number', i.issue_number, 'title', i.title, 'date', i.publication_date, 'category', i.category,
        'status', i.status, 'is_active', i.status = 'active',
        'players_completed', (select count(*) from games g where g.issue_id = i.id and g.mode = 'official' and g.status <> 'in_progress'),
        'solved_pct', (select case when count(*) > 0 then round(100.0 * count(*) filter (where solved) / count(*)) end
                         from games g where g.issue_id = i.id and g.mode = 'official' and g.status <> 'in_progress'),
        'my', (select jsonb_build_object('mode', g.mode, 'status', g.status, 'solved', g.solved, 'guess_count', g.guess_count,
                                         'hint_used', g.hint_used, 'answer', case when g.status <> 'in_progress' then i.answer end,
                                         'definition', case when g.status <> 'in_progress' then (select w.definition from word_bank w where w.word = i.answer) end,
                                         'explanation', case when g.status <> 'in_progress' then i.explanation end,
                                         'rank', case when g.mode = 'official' and g.solved then (sw_game_rank(g.id)->>'rank')::int end)
                 from games g
                where g.issue_id = i.id
                  and ((s.id is not null and g.subscriber_id = s.id) or (s.id is null and g.subscriber_id is null and g.guest_id = p_guest_id))
                order by (g.mode = 'official') desc, (g.status <> 'in_progress') desc, g.created_at desc limit 1),
        'new_game_mode', sw_new_game_mode(i, s.id, case when s.id is null then p_guest_id end)
      ) order by i.issue_number desc), '[]'::jsonb)
      from issues i where i.status in ('active','archived')
  ));
end $$;
