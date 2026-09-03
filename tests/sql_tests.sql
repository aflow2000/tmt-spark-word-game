-- ============================================================
-- SPARK WORD — SQL behaviour tests (run against the local test DB)
--   bash tests/reset_local_db.sh && su postgres -c "psql -v ON_ERROR_STOP=1 -d sparkword -f tests/sql_tests.sql"
-- Each block raises on failure; a clean run prints "ALL SQL TESTS PASSED".
-- ============================================================
\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Tests submit guesses within milliseconds; disable the cadence flag for the main run
update sw_settings set value = '0' where key = 'min_seconds_per_guess';

-- Run everything as the anon role, exactly like PostgREST does
set role anon;

do $$
declare r jsonb; g uuid; tok text := 'test-priya-natarajan-nvidia-000000000003'; guest text := 'guest-test-0001';
        r2 jsonb; tok2 text; adm uuid;
begin
  -- ---------- evaluator: duplicate letters ----------
  assert sw_evaluate('EERIE','STEEL') = 'ppaaa', 'dup letters 1';
  assert sw_evaluate('LEVEL','STEEL') = 'apacc', 'dup letters 2';
  assert sw_evaluate('SLEET','STEEL') = 'cpccp', 'dup letters 3';
  assert sw_evaluate('ABBEY','BABES') = 'ppcca', 'dup letters 4';
  assert sw_evaluate('FIBER','FIBER') = 'ccccc', 'exact';

  -- ---------- bootstrap: recognised subscriber, no game yet ----------
  r := sw_bootstrap(null, tok, null, 'newsletter');
  assert (r->>'ok')::boolean, 'bootstrap ok';
  assert (r->'issue'->>'number')::int = 14, 'active issue is 14';
  assert r->'issue'->>'answer' is null, 'answer must never be in bootstrap';
  assert (r->'player'->>'recognized')::boolean, 'recognised';
  assert (r->'player'->'stats'->>'current_streak')::int = 2, 'priya streak carries (played 12,13; 14 still open)';
  assert r->>'new_game_mode' = 'official', 'official window';
  assert r->'game' is null or jsonb_typeof(r->'game') = 'null', 'no game yet';

  -- ---------- validation ----------
  r := sw_submit_guess(14, 'FIB', tok);       assert r->>'error' = 'invalid_length', 'short guess rejected';
  r := sw_submit_guess(14, 'FIBERS', tok);    assert r->>'error' = 'invalid_length', 'long guess rejected';
  r := sw_submit_guess(14, 'ZZZZZ', tok);     assert r->>'error' = 'not_in_dictionary', 'nonsense rejected';
  r := sw_submit_guess(14, 'cr4ne', tok);     assert r->>'error' = 'invalid_length', 'non-alpha stripped then rejected';

  -- ---------- play: three wrong guesses, hint locked then unlocked ----------
  r := sw_submit_guess(14, 'crane', tok);
  assert (r->>'ok')::boolean and r->>'result' = 'apaap', 'guess 1 evaluated (crane vs fiber → apaap): ' || r::text;
  g := (r->>'game_id')::uuid;
  assert not (r->>'hint_available')::boolean, 'hint locked after 1';
  r2 := sw_use_hint(g, tok); assert r2->>'error' = 'locked', 'hint locked server-side';
  r := sw_submit_guess(14, 'audio', tok, null, g);
  assert r->>'result' = 'aaapa', 'guess 2 (audio vs fiber)';
  r := sw_submit_guess(14, 'tower', tok, null, g);
  assert r->>'result' = 'aaacc', 'guess 3 (tower vs fiber)';
  assert (r->>'hint_available')::boolean, 'hint unlocked after 3';
  r2 := sw_use_hint(g, tok);
  assert (r2->>'ok')::boolean and r2->>'hint' like 'Strands of glass%', 'hint returned';
  assert not (r2->>'second_spark_available')::boolean and r2->>'first_letter' is null, 'no second spark at guess 3';
  -- resume: bootstrap returns the in-progress game with rows and hint
  r := sw_bootstrap(14, tok);
  assert jsonb_array_length(r->'game'->'rows') = 3 and (r->'game'->>'hint_used')::boolean, 'resume state';
  assert r->'game'->>'result' is null, 'no result while in progress';
  -- solve on guess 4
  r := sw_submit_guess(14, 'fiber', tok, null, g);
  assert r->>'status' = 'won' and r->'completion'->>'answer' = 'FIBER', 'solved on 4';
  assert (r->'completion'->>'score')::int = sw_score(true, 4, true, 3), 'score = 50 - 5 + streak(3)*2';
  assert (r->'completion'->'rank'->>'rank')::int is not null, 'ranked';
  assert (r->'completion'->'streak'->>'current')::int = 3, 'streak now 3';
  assert r->'completion'->>'explanation' is not null, 'explanation delivered';
  -- duplicate official attempt → archive mode
  r := sw_bootstrap(14, tok);
  assert r->>'new_game_mode' = 'archive', 'replay is archive mode';
  r := sw_submit_guess(14, 'fiber', tok);
  assert r->>'mode' = 'archive' and r->>'status' = 'won' and (r->'completion'->>'score')::int = 0, 'archive game scores 0';
  assert (select count(*) from jsonb_array_elements(sw_my_stats(tok)->'history') h where (h->>'issue')::int = 14) = 1, 'only one official game';

  -- ---------- six failed attempts ----------
  r := sw_submit_guess(13, 'crane', 'test-jordan-lee-never-played-00000000017');
  g := (r->>'game_id')::uuid;
  assert r->>'mode' = 'archive', 'issue 13 is archived → archive mode';
  perform sw_submit_guess(13, 'build', 'test-jordan-lee-never-played-00000000017', null, g);
  perform sw_submit_guess(13, 'cloud', 'test-jordan-lee-never-played-00000000017', null, g);
  r2 := sw_use_hint(g, 'test-jordan-lee-never-played-00000000017');
  assert (r2->>'ok')::boolean and r2->>'first_letter' is null, 'hint at 3 guesses, no first letter yet';
  perform sw_submit_guess(13, 'media', 'test-jordan-lee-never-played-00000000017', null, g);
  r2 := sw_use_hint(g, 'test-jordan-lee-never-played-00000000017');
  assert r2->>'first_letter' is null, 'still no first letter at 4';
  r := sw_submit_guess(13, 'radio', 'test-jordan-lee-never-played-00000000017', null, g);
  assert (r->>'second_spark_available')::boolean and r->>'first_letter' = 'P', 'second spark at guess 5 reveals first letter (P for POWER)';
  r2 := sw_use_hint(g, 'test-jordan-lee-never-played-00000000017');
  assert r2->>'first_letter' = 'P', 'sw_use_hint returns the first letter at guess 5';
  r := sw_submit_guess(13, 'steel', 'test-jordan-lee-never-played-00000000017', null, g);
  assert r->>'status' = 'lost' and r->'completion'->>'answer' = 'POWER', 'lost after 6 reveals answer';
  r := sw_submit_guess(13, 'power', 'test-jordan-lee-never-played-00000000017', null, g);
  assert r->>'mode' = 'archive' and r->>'guess_number' = '1', 'a 7th guess starts a new archive game, never extends the old one';

  -- ---------- anonymous guest: play, then claim ----------
  r := sw_bootstrap(14, null, guest);
  assert r->'player' is null or jsonb_typeof(r->'player') = 'null', 'guest not recognised';
  assert r->>'new_game_mode' = 'official', 'guest may play officially';
  r := sw_submit_guess(14, 'cable', null, guest);
  g := (r->>'game_id')::uuid;
  r := sw_submit_guess(14, 'fiber', null, guest, g);
  assert r->>'status' = 'won' and r->'completion'->'rank'->>'rank' is not null, 'guest game ranked (unclaimed, shown as Guest)';
  -- claim with an EXISTING subscriber email → verification required, no token leaked
  r := sw_claim_profile(guest, 'sarah.m@example-nvidia.com', 'Sarah', 'Mitchell', 'NVIDIA', 'first_last_initial', g);
  assert r->>'status' = 'verify_required' and r->>'token' is null, 'existing email needs verification';
  -- claim with a NEW email → profile created, game attached, token returned
  r := sw_claim_profile(guest, 'new.player@example-anthropic.com', 'Kai', 'Nguyen', 'Anthropic', 'full_name', g);
  assert r->>'status' = 'created' and length(r->>'token') > 20, 'new profile created';
  tok2 := r->>'token';
  assert (sw_bootstrap(14, tok2)->'game'->>'id')::uuid = g, 'game attached';
  assert (sw_my_stats(tok2)->'history'->0->>'points')::int = sw_score(true, 2, false, 1), 'attached game rescored with streak 1';
  r := sw_bootstrap(14, tok2);
  assert (r->'player'->>'name') = 'Kai Nguyen' and (r->'player'->'stats'->>'games_played')::int = 1, 'new player recognised';
  -- bad claims
  r := sw_claim_profile(guest, 'not-an-email', 'Kai', null, 'X'); assert r->>'error' = 'invalid_email', 'email validated';
  r := sw_claim_profile(guest, 'a@b.co', '', null, 'X');          assert r->>'error' = 'first_name_required', 'first name required';
  r := sw_claim_profile(guest, 'a@b.co', 'Kai', null, '');        assert r->>'error' = 'company_required', 'company required';

  -- ---------- leaderboards ----------
  r := sw_issue_leaderboard(14, tok);
  assert (r->>'ok')::boolean and jsonb_array_length(r->'top') >= 5, 'issue leaderboard has rows';
  assert (r->'top'->0->>'rank')::int = 1, 'top row rank 1';
  assert (r->'me'->>'rank')::int is not null, 'me ranked';
  assert (r->'top'->0->>'guesses')::int <= (r->'top'->1->>'guesses')::int, 'ordered by guesses';
  -- ties: two players with 2 guesses, no hint → fewer seconds wins
  assert (select bool_and(ok) from (
            select (lag(x->>'seconds') over (order by (x->>'rank')::int))::int <= (x->>'seconds')::int or lag(x->>'seconds') over (order by (x->>'rank')::int) is null as ok
              from jsonb_array_elements(r->'top') x where (x->>'guesses')::int = 2 and not (x->>'hint_used')::boolean) t), 'tie-break by time within same guess count';
  r := sw_allstars('all', 'all', null, tok);
  assert jsonb_array_length(r->'rows') >= 10 and (r->'rows'->0->>'points')::int >= (r->'rows'->1->>'points')::int, 'allstars ordered by points';
  assert (r->'me'->>'rank')::int is not null, 'allstars me';
  r := sw_allstars('all', 'tt', null, tok);
  assert (select bool_and((x->>'is_tt')::boolean) from jsonb_array_elements(r->'rows') x), 'tt scope';
  r := sw_allstars('all', 'company', 'nvidia inc', tok);
  assert jsonb_array_length(r->'rows') = 3, 'company scope normalises names (nvidia inc → NVIDIA): ' || r::text;
  r := sw_allstars('issue', 'all', null, tok);
  assert (select bool_and((x->>'issues_played')::int = 1) from jsonb_array_elements(r->'rows') x), 'issue period';
  r := sw_company_standings('all');
  assert jsonb_array_length(r->'rows') >= 4, 'company standings';
  assert not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'company' = 'Vantage Data Centers'), 'single-player company excluded (min 3)';
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'company' = 'Microsoft' and (x->>'players')::int = 3), 'Microsoft Corp. merged into Microsoft';
  r := sw_last_issue_summary(tok);
  assert (r->'issue'->>'number')::int = 13 and (r->>'revealed')::boolean and r->>'answer' = 'POWER', 'shareout revealed to a player who completed 13';
  r := sw_last_issue_summary('test-jordan-lee-never-played-00000000017');
  assert (r->>'revealed')::boolean, 'jordan completed 13 in archive mode → revealed';
  r := sw_last_issue_summary(tok2);
  assert not (r->>'revealed')::boolean and r->>'answer' is null and r->>'answer_masked' = 'P····', 'masked for someone who has not played 13';
  assert r->>'company_champion' is not null, 'company champion computed';

  -- ---------- archive ----------
  r := sw_archive(tok2);
  assert jsonb_array_length(r->'issues') = 4, 'archive lists published issues only';
  assert (select bool_and(x->'my' is null or jsonb_typeof(x->'my') = 'null' or x->'my'->>'answer' is not null)
            from jsonb_array_elements(r->'issues') x), 'answers only where played';
  assert (select x->'my'->>'answer' from jsonb_array_elements(r->'issues') x where (x->>'number')::int = 13) is null, 'issue 13 answer hidden from tok2';
  assert (select x->'my'->>'answer' from jsonb_array_elements(r->'issues') x where (x->>'number')::int = 14) = 'FIBER', 'issue 14 answer shown to tok2';

  -- ---------- analytics whitelist & hygiene ----------
  r := sw_track('spark_word_shared', 14, null, tok, null, '{"method":"copy","answer":"FIBER"}'::jsonb);
  assert (r->>'ok')::boolean, 'track ok';
  r := sw_track('drop_table', 14, null, tok); assert r->>'error' = 'unknown_event', 'unknown event rejected';

  -- ---------- profile preference ----------
  r := sw_update_profile(tok2, 'anonymous');
  assert r->'player'->>'name' = 'Anonymous', 'anonymous display';
  r := sw_update_profile(tok2, 'first_last_initial');
  assert r->'player'->>'name' = 'Kai N.', 'first + last initial';

  -- ---------- unpublished issue is closed to the public ----------
  r := sw_bootstrap(15, tok);
  assert r->>'error' = 'issue_not_published', 'scheduled issue hidden';
  r := sw_submit_guess(15, 'cloud', tok);
  assert r->>'error' = 'issue_not_published', 'cannot play a scheduled issue';

  raise notice 'anon gameplay tests passed';
end $$;

-- ---------- analytics hygiene (checked as superuser) ----------
reset role;
do $$ begin
  assert not exists (select 1 from events where event_name = 'spark_word_shared' and props ? 'answer'), 'answer stripped from props';
  assert exists (select 1 from events where event_name = 'spark_word_shared' and props->>'method' = 'copy'), 'share event stored';
end $$;
set role anon;

-- ---------- anon has no table access ----------
do $$
begin
  begin
    perform * from subscribers limit 1;
    raise exception 'anon could read subscribers!';
  exception when insufficient_privilege then null; end;
  begin
    perform * from issues limit 1;
    raise exception 'anon could read issues!';
  exception when insufficient_privilege then null; end;
  begin
    perform admin_overview();
    raise exception 'anon could call admin_overview!';
  exception when insufficient_privilege then null; end;
  raise notice 'anon table isolation passed';
end $$;

reset role;

-- ---------- verified-link flow (authenticated role with a JWT) ----------
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'sarah.m@example-nvidia.com') on conflict do nothing;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","email":"sarah.m@example-nvidia.com","role":"authenticated"}', false);
do $$
declare r jsonb;
begin
  r := sw_verified_link('guest-test-0001', 'Sarah', 'Mitchell', 'NVIDIA', null, null);
  assert r->>'status' = 'linked' and r->>'token' = 'test-sarah-mitchell-nvidia-00000000000001', 'verified link returns the REAL token for the existing subscriber';
  -- non-admin authenticated users see NO rows (RLS filters everything)
  assert (select count(*) from subscribers) = 0, 'non-admin authenticated user must not see subscribers';
  assert (select count(*) from issues) = 0, 'non-admin authenticated user must not see issues';
  raise notice 'verified-link tests passed';
end $$;
reset role;
do $$ begin
  assert (select email_verified from subscribers where subscriber_token = 'test-sarah-mitchell-nvidia-00000000000001'), 'email marked verified';
end $$;

-- ---------- admin surface ----------
insert into auth.users (id, email) values ('22222222-2222-2222-2222-222222222222', 'editor@turntown.com') on conflict do nothing;
insert into admins (user_id, email, role) values ('22222222-2222-2222-2222-222222222222', 'editor@turntown.com', 'owner') on conflict do nothing;
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","email":"editor@turntown.com","role":"authenticated"}', false);
do $$
declare r jsonb; iid uuid; n int; cnt int;
begin
  assert sw_is_admin(), 'admin recognised';
  r := admin_overview();
  assert (r->'active_issue'->>'number')::int = 14 and r->'active_issue'->>'answer' = 'FIBER', 'admin sees the answer';
  select id into iid from issues where issue_number = 14;
  r := admin_issue_analytics(iid);
  assert (r->>'unique_players')::int >= 10 and jsonb_array_length(r->'distribution') = 7, 'analytics';
  assert (r->>'shares')::int >= 1, 'shares counted';
  select count(*) into cnt from admin_issue_links(14, true);
  assert cnt >= 17, 'links for every newsletter subscriber';
  assert (select url from admin_issue_links(14, true) limit 1) like 'https://tmtspark.example.com/spark-word/014?t=%', 'url format';
  -- admin can read tables directly (dashboard grids)
  perform * from subscribers limit 1;
  perform * from games limit 1;
  -- reuse guard
  begin
    insert into issues (issue_number, title, publication_date, answer, category, explanation) values (99, 'x', '2027-01-01', 'FIBER', 'X', 'x');
    raise exception 'reuse guard failed';
  exception when check_violation then null; end;
  -- preview: admin can bootstrap a scheduled issue
  r := sw_bootstrap(15, null, 'admin-guest');
  assert (r->>'ok')::boolean and r->>'new_game_mode' = 'preview', 'admin preview of scheduled issue';
  r := sw_submit_guess(15, 'cloud', null, 'admin-guest');
  assert r->>'mode' = 'preview' and r->>'status' = 'won', 'preview game does not count';
  assert not exists (select 1 from jsonb_array_elements(sw_issue_leaderboard(15)->'top')), 'preview games never rank';
  -- activation is exclusive
  r := admin_set_issue_status(iid, 'active');
  perform admin_set_issue_status((select id from issues where issue_number = 15), 'active');
  assert (select status from issues where issue_number = 14) = 'archived', 'activating 15 archived 14';
  assert (select count(*) from issues where status = 'active') = 1, 'one active';
  perform admin_set_issue_status(iid, 'active'); -- restore
  update issues set status = 'scheduled' where issue_number = 15;
  assert (select status from issues where issue_number = 14) = 'active', 'restored';
  n := admin_recompute_all_stats();
  assert n >= 17, 'recompute';
  -- import upserts and never re-tokens
  r := admin_import_subscribers('[{"email":"sarah.m@example-nvidia.com","company":"NVIDIA Corporation"},{"email":"brand.new@example.com","first_name":"Pat","company":"Equinix"},{"email":"bad"}]'::jsonb);
  assert (r->>'inserted')::int = 1 and (r->>'updated')::int = 1 and (r->>'skipped')::int = 1, 'import counts';
  assert (select subscriber_token from subscribers where email = 'sarah.m@example-nvidia.com') = 'test-sarah-mitchell-nvidia-00000000000001', 'token preserved on import';
  raise notice 'admin tests passed';
end $$;
reset role;

-- ---------- anti-cheat: inhuman cadence is flagged and unranked ----------
update sw_settings set value = '0.7' where key = 'min_seconds_per_guess';
set role anon;
do $$
declare r jsonb; g uuid;
begin
  r := sw_submit_guess(14, 'crane', 'test-ben-adler-meta-00000000000000000015');
  g := (r->>'game_id')::uuid;
  r := sw_submit_guess(14, 'fiber', 'test-ben-adler-meta-00000000000000000015', null, g);
  assert r->>'status' = 'won' and (r->'completion'->>'flagged')::boolean, 'sub-second solve flagged';
  assert r->'completion'->'rank'->>'rank' is null, 'flagged game is unranked';
  assert not exists (select 1 from jsonb_array_elements(sw_issue_leaderboard(14)->'top') x where x->>'name' = 'Ben A.'), 'flagged game absent from leaderboard';
  raise notice 'anti-cheat tests passed';
end $$;
reset role;

select 'ALL SQL TESTS PASSED' as result;
