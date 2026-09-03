-- ============================================================
-- SPARK WORD — seed 060 · Test games
--
-- Realistic play history for issues 011–014 so leaderboards, streaks,
-- All-Stars and company standings have something to show. Every game is
-- created through the REAL evaluator (sw_evaluate) so results are exact.
-- Scores and streaks are recomputed at the end, in issue order.
-- Delete with:  delete from games where ref = 'seed';
-- ============================================================

create or replace function sw_seed_game(
  p_email text, p_issue int, p_guesses text[], p_hint boolean, p_seconds int, p_completed timestamptz
) returns uuid
language plpgsql security definer set search_path = public as $$
declare s subscribers%rowtype; i issues%rowtype; g_id uuid; n int := 0; w text; res text; v_solved boolean := false;
begin
  select * into s from subscribers where email = p_email;
  select * into i from issues where issue_number = p_issue;
  if s.id is null or i.id is null then raise exception 'seed: unknown subscriber/issue % %', p_email, p_issue; end if;
  insert into games (issue_id, subscriber_id, mode, status, started_at, ref, hint_used, hint_used_at)
    values (i.id, s.id, 'official', 'in_progress', p_completed - make_interval(secs => p_seconds), 'seed', p_hint,
            case when p_hint then p_completed - make_interval(secs => p_seconds/2) end)
    returning id into g_id;
  foreach w in array p_guesses loop
    n := n + 1;
    w := upper(w);
    if not exists (select 1 from dictionary where word = lower(w)) then raise exception 'seed: % is not in the dictionary', w; end if;
    res := sw_evaluate(w, i.answer);
    insert into guesses (game_id, guess_number, word, result, created_at)
      values (g_id, n, w, res, p_completed - make_interval(secs => p_seconds) + make_interval(secs => p_seconds * n / array_length(p_guesses,1)));
    if res = 'ccccc' then v_solved := true; end if;
  end loop;
  update games set guess_count = n, solved = v_solved, status = (case when v_solved then 'won' else 'lost' end)::sw_game_status,
                   last_guess_at = p_completed, completed_at = p_completed, completion_seconds = p_seconds
   where id = g_id;
  insert into events (event_name, issue_id, subscriber_id, game_id, company_key, props)
    values ('spark_word_viewed', i.id, s.id, g_id, s.company_key, jsonb_build_object('ref','newsletter','seed',true)),
           ('spark_word_started', i.id, s.id, g_id, s.company_key, jsonb_build_object('mode','official','seed',true)),
           (case when v_solved then 'spark_word_completed' else 'spark_word_failed' end, i.id, s.id, g_id, s.company_key,
            jsonb_build_object('guess_count', n, 'hint_used', p_hint, 'seed', true));
  return g_id;
end $$;

-- ---------------- Issue 011 · STEEL (Jun 2026) ----------------
select sw_seed_game('sarah.m@example-nvidia.com',    11, array['crane','steel'],                         false, 48,  '2026-06-04 14:12+00');
select sw_seed_game('david.l@example-nvidia.com',    11, array['arise','tiles','steel'],                 false, 95,  '2026-06-04 15:40+00');
select sw_seed_game('james.r@example-tt.com',        11, array['audio','steel'],                         false, 61,  '2026-06-04 09:05+00');
select sw_seed_game('alex.c@example-tt.com',         11, array['crane','slate','steel'],                 false, 120, '2026-06-05 08:30+00');
select sw_seed_game('mei.t@example-tt.com',          11, array['raise','blend','steel'],                 true,  210, '2026-06-05 12:00+00');
select sw_seed_game('omar.h@example-tt.com',         11, array['crane','sleet','steel'],                 false, 88,  '2026-06-06 10:10+00');
select sw_seed_game('michelle.k@example-google.com', 11, array['solar','metal','steel'],                 false, 74,  '2026-06-04 16:22+00');
select sw_seed_game('tom.b@example-google.com',      11, array['crane','build','tower','racks','cable','power'], false, 300, '2026-06-04 18:00+00');
select sw_seed_game('ana.s@example-google.com',      11, array['steel'],                                 false, 0,   '2026-06-04 13:01+00');
select sw_seed_game('chris.w@example-microsoft.com', 11, array['crane','spelt','steel'],                 false, 133, '2026-06-07 11:11+00');
select sw_seed_game('dana.o@example-microsoft.com',  11, array['audio','steer','steel'],                 false, 101, '2026-06-05 17:45+00');
select sw_seed_game('grace.p@example-meta.com',      11, array['plant','steel'],                         false, 57,  '2026-06-04 20:20+00');
select sw_seed_game('nadia.r@example-vantage.com',   11, array['arise','tease','steel'],                 false, 140, '2026-06-08 09:00+00');

-- ---------------- Issue 012 · RADIO (Jul 2026) ----------------
select sw_seed_game('sarah.m@example-nvidia.com',    12, array['crane','ratio','radio'],                 false, 66,  '2026-07-02 14:00+00');
select sw_seed_game('david.l@example-nvidia.com',    12, array['audio','radio'],                         false, 40,  '2026-07-02 15:10+00');
select sw_seed_game('priya.n@example-nvidia.com',    12, array['arise','roast','radio'],                 false, 150, '2026-07-03 10:00+00');
select sw_seed_game('james.r@example-tt.com',        12, array['solar','radio'],                         false, 52,  '2026-07-02 09:00+00');
select sw_seed_game('alex.c@example-tt.com',         12, array['crane','rapid','radio'],                 false, 97,  '2026-07-02 08:40+00');
select sw_seed_game('mei.t@example-tt.com',          12, array['media','radio'],                         false, 45,  '2026-07-02 12:30+00');
select sw_seed_game('omar.h@example-tt.com',         12, array['crane','solar','braid','radio'],         true,  260, '2026-07-04 11:00+00');
select sw_seed_game('michelle.k@example-google.com', 12, array['tower','radio'],                         false, 39,  '2026-07-02 16:00+00');
select sw_seed_game('tom.b@example-google.com',      12, array['crane','ratio','radio'],                 false, 80,  '2026-07-02 18:30+00');
select sw_seed_game('ana.s@example-google.com',      12, array['audio','radio'],                         false, 44,  '2026-07-02 13:15+00');
select sw_seed_game('chris.w@example-microsoft.com', 12, array['crane','audit','radio'],                 false, 110, '2026-07-05 11:00+00');
select sw_seed_game('luis.f@example-microsoft.com',  12, array['arise','radar','radio'],                 false, 125, '2026-07-03 09:30+00');
select sw_seed_game('grace.p@example-meta.com',      12, array['crane','brand','radio'],                 false, 71,  '2026-07-02 20:00+00');
select sw_seed_game('ben.a@example-meta.com',        12, array['solar','cloud','build','tower','media','fiber'], false, 330, '2026-07-06 10:00+00');
select sw_seed_game('nadia.r@example-vantage.com',   12, array['crane','radio'],                         false, 58,  '2026-07-02 21:00+00');

-- ---------------- Issue 013 · POWER (Aug 2026) ----------------
select sw_seed_game('sarah.m@example-nvidia.com',    13, array['water','power'],                         false, 37,  '2026-08-06 14:05+00');
select sw_seed_game('david.l@example-nvidia.com',    13, array['crane','tower','power'],                 false, 72,  '2026-08-06 15:00+00');
select sw_seed_game('priya.n@example-nvidia.com',    13, array['arise','motor','power'],                 false, 140, '2026-08-07 10:00+00');
select sw_seed_game('james.r@example-tt.com',        13, array['solar','power'],                         false, 49,  '2026-08-06 09:00+00');
select sw_seed_game('alex.c@example-tt.com',         13, array['crane','rower','power'],                 false, 90,  '2026-08-06 08:45+00');
select sw_seed_game('mei.t@example-tt.com',          13, array['crane','solar','robot','tower','power'], false, 280, '2026-08-08 12:00+00');
select sw_seed_game('omar.h@example-tt.com',         13, array['lower','power'],                         false, 41,  '2026-08-06 10:30+00');
select sw_seed_game('michelle.k@example-google.com', 13, array['audio','power'],                         false, 35,  '2026-08-06 16:10+00');
select sw_seed_game('tom.b@example-google.com',      13, array['crane','slate','build','media','fiber','cloud'], true, 420, '2026-08-06 18:00+00');
select sw_seed_game('ana.s@example-google.com',      13, array['crane','tower','power'],                 false, 64,  '2026-08-06 13:00+00');
select sw_seed_game('chris.w@example-microsoft.com', 13, array['water','power'],                         false, 55,  '2026-08-09 11:00+00');
select sw_seed_game('dana.o@example-microsoft.com',  13, array['solar','power'],                         false, 43,  '2026-08-06 17:00+00');
select sw_seed_game('luis.f@example-microsoft.com',  13, array['arise','mower','power'],                 false, 118, '2026-08-07 09:00+00');
select sw_seed_game('grace.p@example-meta.com',      13, array['crane','poker','power'],                 false, 77,  '2026-08-06 20:30+00');
select sw_seed_game('ben.a@example-meta.com',        13, array['tower','power'],                         false, 46,  '2026-08-07 10:00+00');
select sw_seed_game('nadia.r@example-vantage.com',   13, array['crane','tower','power'],                 false, 83,  '2026-08-06 21:00+00');

-- ---------------- Issue 014 · FIBER (Sep 2026, ACTIVE — partially played) ----------------
select sw_seed_game('sarah.m@example-nvidia.com',    14, array['crane','fiber'],                         false, 44,  '2026-09-03 14:02+00');
select sw_seed_game('david.l@example-nvidia.com',    14, array['audio','tiger','fiber'],                 false, 91,  '2026-09-03 15:20+00');
select sw_seed_game('james.r@example-tt.com',        14, array['arise','fiber'],                         false, 50,  '2026-09-03 09:02+00');
select sw_seed_game('alex.c@example-tt.com',         14, array['crane','brief','fiber'],                 false, 96,  '2026-09-03 08:50+00');
select sw_seed_game('michelle.k@example-google.com', 14, array['cable','fiber'],                         false, 38,  '2026-09-03 16:05+00');
select sw_seed_game('tom.b@example-google.com',      14, array['crane','solar','fiery','fiber'],         true,  240, '2026-09-03 18:10+00');
select sw_seed_game('chris.w@example-microsoft.com', 14, array['crane','liber','fiber'],                 false, 130, '2026-09-04 11:00+00');
select sw_seed_game('grace.p@example-meta.com',      14, array['brief','fiber'],                         false, 47,  '2026-09-03 20:15+00');
select sw_seed_game('nadia.r@example-vantage.com',   14, array['crane','tower','cable','fiber'],         false, 160, '2026-09-04 09:00+00');
-- priya, mei, omar, ana, dana, luis, ben and jordan have NOT played 014 yet

-- ---------------- Recompute streak-aware scores in issue order ----------------
do $$
declare r record;
begin
  for r in select g.id, g.subscriber_id, g.solved, g.guess_count, g.hint_used, i.issue_number
             from games g join issues i on i.id = g.issue_id
            where g.ref = 'seed' and g.mode = 'official' order by i.issue_number, g.completed_at loop
    update games set streak_at_completion = sw_streak_ending_at(r.subscriber_id, r.issue_number),
                     score = sw_score(r.solved, r.guess_count, r.hint_used, sw_streak_ending_at(r.subscriber_id, r.issue_number))
     where id = r.id;
  end loop;
  perform sw_recompute_subscriber_stats(id) from subscribers;
end $$;

-- A few share / leaderboard events so the analytics tab isn't empty
insert into events (event_name, issue_id, subscriber_id, company_key, props)
select 'spark_word_shared', i.id, s.id, s.company_key, jsonb_build_object('method','copy','seed',true)
  from issues i join subscribers s on s.email in ('sarah.m@example-nvidia.com','james.r@example-tt.com','michelle.k@example-google.com')
 where i.issue_number in (13,14);

drop function if exists sw_seed_game(text, int, text[], boolean, int, timestamptz);
