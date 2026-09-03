-- ============================================================
-- SPARK WORD — 005 · Row Level Security & grants
--
-- Principle: the anon role can only EXECUTE the gameplay functions.
-- It has no direct SELECT/INSERT/UPDATE/DELETE on any table, so the
-- answer, hints, emails and tokens are unreachable from the browser.
-- Admins (auth users in `admins`) get full table access for admin.html.
-- ============================================================

-- ------------------------------------------------------------
-- Enable RLS everywhere
-- ------------------------------------------------------------
alter table sw_settings enable row level security;
alter table admins      enable row level security;
alter table subscribers enable row level security;
alter table word_bank   enable row level security;
alter table dictionary  enable row level security;
alter table issues      enable row level security;
alter table games       enable row level security;
alter table guesses     enable row level security;
alter table events      enable row level security;

-- ------------------------------------------------------------
-- Table grants: nothing for anon; authenticated gets table privileges
-- but the policies below only let ADMINS through.
-- ------------------------------------------------------------
revoke all on all tables in schema public from anon;
grant select, insert, update, delete on sw_settings, admins, subscribers, word_bank, dictionary, issues, games, guesses, events to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- ------------------------------------------------------------
-- Admin policies (one per table; sw_is_admin() checks auth.uid())
-- ------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['sw_settings','subscribers','word_bank','dictionary','issues','games','guesses','events'] loop
    execute format('drop policy if exists %I on %I', t || '_admin_all', t);
    execute format('create policy %I on %I for all to authenticated using (sw_is_admin()) with check (sw_is_admin())', t || '_admin_all', t);
  end loop;
end $$;

-- admins table: admins can read the list; only owners may change it
drop policy if exists admins_read on admins;
create policy admins_read on admins for select to authenticated using (sw_is_admin());
drop policy if exists admins_owner_write on admins;
create policy admins_owner_write on admins for all to authenticated
  using (exists (select 1 from admins a where a.user_id = auth.uid() and a.role = 'owner'))
  with check (exists (select 1 from admins a where a.user_id = auth.uid() and a.role = 'owner'));

-- ------------------------------------------------------------
-- Function grants
-- Supabase exposes public functions to anon by default: lock them all
-- down first, then open exactly the gameplay surface.
-- ------------------------------------------------------------
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and (p.proname like 'sw\_%' or p.proname like 'admin\_%') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- Gameplay surface (anon + authenticated)
grant execute on function sw_bootstrap(int, text, text, text)                              to anon, authenticated;
grant execute on function sw_submit_guess(int, text, text, text, uuid, text, text)         to anon, authenticated;
grant execute on function sw_use_hint(uuid, text, text)                                    to anon, authenticated;
grant execute on function sw_claim_profile(text, text, text, text, text, text, uuid)       to anon, authenticated;
grant execute on function sw_update_profile(text, text, text)                              to anon, authenticated;
grant execute on function sw_track(text, int, uuid, text, text, jsonb)                     to anon, authenticated;
grant execute on function sw_archive(text, text)                                           to anon, authenticated;
grant execute on function sw_issue_leaderboard(int, text, text, int)                       to anon, authenticated;
grant execute on function sw_allstars(text, text, text, text, int, text)                   to anon, authenticated;
grant execute on function sw_company_standings(text, int)                                  to anon, authenticated;
grant execute on function sw_last_issue_summary(text, text, int)                           to anon, authenticated;
grant execute on function sw_my_stats(text)                                                to anon, authenticated;
-- Requires a Supabase Auth session (magic-link verification round trip)
grant execute on function sw_verified_link(text, text, text, text, text, uuid)             to authenticated;
-- Admin surface (functions verify sw_is_admin() themselves)
grant execute on function sw_is_admin()                                                    to anon, authenticated;
grant execute on function admin_overview()                                                 to authenticated;
grant execute on function admin_issue_analytics(uuid)                                      to authenticated;
grant execute on function admin_issue_links(int, boolean)                                  to authenticated;
grant execute on function admin_subscriber_link(uuid, int)                                 to authenticated;
grant execute on function admin_import_subscribers(jsonb)                                  to authenticated;
grant execute on function admin_rotate_token(uuid)                                         to authenticated;
grant execute on function admin_set_issue_status(uuid, text)                               to authenticated;
grant execute on function admin_activate_due_issues()                                      to authenticated;
grant execute on function admin_word_bank_search(text, text, boolean)                      to authenticated;
grant execute on function admin_recompute_all_stats()                                      to authenticated;

-- Helper functions used by the functions above run as their owner (SECURITY DEFINER),
-- so they need no grants. sw_evaluate / sw_score are harmless and may be tested directly:
grant execute on function sw_evaluate(text, text) to anon, authenticated;
grant execute on function sw_score(boolean, int, boolean, int) to anon, authenticated;
