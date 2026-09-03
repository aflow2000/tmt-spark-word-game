-- ============================================================
-- SPARK WORD — one-shot setup for the Supabase SQL editor
-- ============================================================

-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- It creates the schema, game functions, leaderboards, admin functions,
-- row-level security, the settings, the word bank, the dictionary and
-- the sample Issue 014. Safe to re-run (idempotent where it matters).
--
-- Afterwards:
--   1. Supabase → Authentication → Users → add your admin user (email + password)
--   2. run:  insert into admins (email) values ('you@turnerandtownsend.com');
--   3. run:  update sw_settings set value = 'https://YOUR-APP.vercel.app/spark-word.html' where key = 'site_url';
--            update sw_settings set value = 'query' where key = 'url_style';
--      (or use the Settings tab in spark-word-admin.html)
-- Sample players/games for testing live in spark-word-test-data.sql.

-- ============================================================
-- FILE: supabase/migrations/001_schema.sql
-- ============================================================
-- ============================================================
-- SPARK WORD — 001 · Schema
-- TMT Spark · Turner & Townsend
--
-- Run order: 001_schema → 002_game_functions → 003_leaderboards
--            → 004_admin → 005_rls → seed/*
--
-- Design notes
-- • Every table has Row Level Security enabled (005_rls.sql). The anon
--   role has NO direct table access: all gameplay goes through the
--   SECURITY DEFINER functions in 002/003. Admins (Supabase Auth users
--   listed in `admins`) get direct table access for the dashboard.
-- • Leaderboards are computed, never stored (see 003_leaderboards.sql).
-- • Streaks are ISSUE-based, not calendar-based.
-- ============================================================

create extension if not exists pgcrypto;
create extension if not exists citext;

-- ------------------------------------------------------------
-- Helper functions used by defaults / generated columns
-- ------------------------------------------------------------

-- Opaque subscriber token: 32 random bytes, base64url (43 chars, no padding).
create or replace function sw_new_token() returns text
language sql volatile as $$
  select translate(rtrim(encode(gen_random_bytes(32), 'base64'), '='), '+/', '-_');
$$;

-- Normalises a company name so "NVIDIA Corp.", "Nvidia" and "nvidia inc" group together.
create or replace function sw_company_key(p text) returns text
language sql immutable strict as $$
  select nullif(
    trim(
      regexp_replace(
        regexp_replace(
          regexp_replace(lower(p), '[^a-z0-9& ]+', ' ', 'g'),
          '\s+(inc|inc\.|llc|ltd|limited|plc|corp|corporation|co|company|group|holdings|gmbh|sa|ag)(\s|$)', ' ', 'g'),
        '\s+', ' ', 'g')
    ), '');
$$;

-- ------------------------------------------------------------
-- Enumerations
-- ------------------------------------------------------------
do $$ begin
  create type sw_issue_status as enum ('draft','scheduled','active','archived');
exception when duplicate_object then null; end $$;

do $$ begin
  create type sw_game_mode as enum ('official','archive','preview');
exception when duplicate_object then null; end $$;

do $$ begin
  create type sw_game_status as enum ('in_progress','won','lost');
exception when duplicate_object then null; end $$;

do $$ begin
  create type sw_visibility as enum ('first_last_initial','full_name','anonymous');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- Settings (key/value, editable from the admin dashboard)
-- ------------------------------------------------------------
create table if not exists sw_settings (
  key         text primary key,
  value       text not null,
  description text,
  updated_at  timestamptz not null default now()
);

create or replace function sw_setting(p_key text, p_default text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select value from sw_settings where key = p_key), p_default);
$$;

-- ------------------------------------------------------------
-- Admins — Supabase Auth users allowed into admin.html
-- ------------------------------------------------------------
create table if not exists admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  role       text not null default 'editor',   -- 'editor' | 'owner'
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Subscribers — one row per person. NEVER exposed to anon.
-- ------------------------------------------------------------
create table if not exists subscribers (
  id                     uuid primary key default gen_random_uuid(),
  email                  citext not null unique,
  first_name             text,
  last_name              text,
  display_name           text,                 -- optional custom leaderboard name
  company                text,
  company_key            text generated always as (sw_company_key(company)) stored,
  subscriber_token       text not null unique default sw_new_token(),
  newsletter_subscriber  boolean not null default true,
  leaderboard_visibility sw_visibility not null default 'first_last_initial',
  source                 text not null default 'newsletter_import', -- newsletter_import | public_claim | verified_claim | admin
  email_verified         boolean not null default false,
  auth_user_id           uuid references auth.users(id) on delete set null,
  -- cached stats (recomputed by sw_recompute_subscriber_stats after each official game)
  games_played           integer not null default 0,
  games_won              integer not null default 0,
  average_guesses        numeric(4,2),
  current_streak         integer not null default 0,
  best_streak            integer not null default 0,
  total_points           integer not null default 0,
  created_at             timestamptz not null default now(),
  last_seen_at           timestamptz,
  notes                  text
);
create index if not exists subscribers_company_key_idx on subscribers(company_key);

-- ------------------------------------------------------------
-- Word bank — the curated answer pool (NOT the guess dictionary)
-- ------------------------------------------------------------
create table if not exists word_bank (
  id              uuid primary key default gen_random_uuid(),
  word            text not null unique check (word ~ '^[A-Z]{5}$'),
  category        text not null,
  definition      text not null,      -- shown after the game: what it is + why it matters
  hint            text,               -- suggested "Need a Spark?" hint
  related_type    text,               -- optional Spark Learning link: 'glossary' | 'explainer' | 'story'
  related_ref     text,               -- e.g. glossary term or explainer title
  active          boolean not null default true,
  used            boolean not null default false,
  last_used_issue integer,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists word_bank_category_idx on word_bank(category);

-- ------------------------------------------------------------
-- Dictionary — valid five-letter guesses (lower-case)
-- ------------------------------------------------------------
create table if not exists dictionary (
  word text primary key check (word ~ '^[a-z]{5}$')
);

-- ------------------------------------------------------------
-- Issues — one Spark Word per newsletter issue
-- ------------------------------------------------------------
create table if not exists issues (
  id                    uuid primary key default gen_random_uuid(),
  issue_number          integer not null unique check (issue_number > 0),
  slug                  text generated always as ('issue-' || lpad(issue_number::text, 3, '0')) stored,
  title                 text,                       -- e.g. "The AI Infrastructure Race"
  publication_date      date not null,
  answer                text not null check (answer ~ '^[A-Z]{5}$'),
  category              text not null,              -- "This issue's sector"
  hint                  text,                       -- unlocked after 3 guesses
  explanation           text not null,              -- post-game teaching copy
  status                sw_issue_status not null default 'draft',
  allow_reuse           boolean not null default false, -- admin override for the reuse guard
  newsletter_recipients integer,                    -- entered by the editor for analytics
  activated_at          timestamptz,
  archived_at           timestamptz,
  created_by            uuid references auth.users(id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
-- Only one official (active) issue at any time
create unique index if not exists issues_one_active_idx on issues((status)) where status = 'active';
create index if not exists issues_status_idx on issues(status);

-- ------------------------------------------------------------
-- Games — one per player per issue per mode
-- ------------------------------------------------------------
create table if not exists games (
  id                   uuid primary key default gen_random_uuid(),
  issue_id             uuid not null references issues(id) on delete cascade,
  subscriber_id        uuid references subscribers(id) on delete cascade,
  guest_id             text,                         -- client-generated id for players without a token
  mode                 sw_game_mode not null default 'official',
  status               sw_game_status not null default 'in_progress',
  started_at           timestamptz not null default now(),   -- = first guess
  last_guess_at        timestamptz,
  completed_at         timestamptz,
  solved               boolean not null default false,
  guess_count          integer not null default 0 check (guess_count between 0 and 6),
  hint_used            boolean not null default false,
  hint_used_at         timestamptz,
  completion_seconds   integer,
  score                integer,                      -- All-Stars points (official only)
  streak_at_completion integer,                      -- issue streak including this game
  flagged              boolean not null default false,   -- anti-cheat: excluded from ranking
  flag_reason          text,
  ref                  text,                         -- 'newsletter' | 'site' | 'share' | ...
  user_agent           text,
  created_at           timestamptz not null default now(),
  check (subscriber_id is not null or guest_id is not null)
);
-- One OFFICIAL game per subscriber per issue (and one per guest id while unclaimed).
create unique index if not exists games_official_subscriber_idx
  on games(subscriber_id, issue_id) where mode = 'official' and subscriber_id is not null;
create unique index if not exists games_official_guest_idx
  on games(guest_id, issue_id) where mode = 'official' and guest_id is not null and subscriber_id is null;
create index if not exists games_issue_idx on games(issue_id, mode, status);
create index if not exists games_subscriber_idx on games(subscriber_id);
create index if not exists games_guest_idx on games(guest_id);

-- ------------------------------------------------------------
-- Guesses — every submitted row
-- ------------------------------------------------------------
create table if not exists guesses (
  id           bigint generated always as identity primary key,
  game_id      uuid not null references games(id) on delete cascade,
  guess_number integer not null check (guess_number between 1 and 6),
  word         text not null check (word ~ '^[A-Z]{5}$'),
  result       text not null check (result ~ '^[cpa]{5}$'),  -- c=correct p=present a=absent
  created_at   timestamptz not null default now(),
  unique (game_id, guess_number)
);

-- ------------------------------------------------------------
-- Analytics events
-- ------------------------------------------------------------
create table if not exists events (
  id            bigint generated always as identity primary key,
  event_name    text not null,
  issue_id      uuid references issues(id) on delete set null,
  subscriber_id uuid references subscribers(id) on delete set null,
  guest_id      text,
  game_id       uuid references games(id) on delete set null,
  company_key   text,
  props         jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);
create index if not exists events_issue_name_idx on events(issue_id, event_name);
create index if not exists events_created_idx on events(created_at);

-- ------------------------------------------------------------
-- Triggers
-- ------------------------------------------------------------

-- updated_at bookkeeping
create or replace function sw_touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists issues_touch on issues;
create trigger issues_touch before update on issues
  for each row execute function sw_touch_updated_at();

drop trigger if exists word_bank_touch on word_bank;
create trigger word_bank_touch before update on word_bank
  for each row execute function sw_touch_updated_at();

-- Issue guard: normalise the answer, block accidental reuse, keep word_bank in sync,
-- and make activation exclusive (activating an issue archives the previous active one).
create or replace function sw_issue_guard() returns trigger
language plpgsql as $$
declare
  v_other integer;
begin
  new.answer := upper(trim(new.answer));

  -- reuse guard (unless the editor explicitly allows it)
  select issue_number into v_other
    from issues
   where answer = new.answer and id <> new.id
   limit 1;
  if v_other is not null and not new.allow_reuse then
    raise exception 'SPARK_WORD_REUSED: % was already the answer for issue %. Set allow_reuse to override.', new.answer, v_other
      using errcode = 'check_violation';
  end if;

  -- the answer must be a valid dictionary word (so it is always guessable)
  insert into dictionary(word) values (lower(new.answer)) on conflict do nothing;

  -- status transitions
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active') then
    new.activated_at := coalesce(new.activated_at, now());
    update issues set status = 'archived', archived_at = now()
     where status = 'active' and id <> new.id;
  end if;
  if new.status = 'archived' and (tg_op = 'INSERT' or old.status is distinct from 'archived') then
    new.archived_at := coalesce(new.archived_at, now());
  end if;

  return new;
end $$;

drop trigger if exists issues_guard on issues;
create trigger issues_guard before insert or update on issues
  for each row execute function sw_issue_guard();

-- After an issue is saved, mark its word as used in the bank (and un-mark a replaced word).
create or replace function sw_issue_after() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.answer <> new.answer then
    update word_bank set used = exists(select 1 from issues where answer = old.answer),
                         last_used_issue = (select max(issue_number) from issues where answer = old.answer)
     where word = old.answer;
  end if;
  update word_bank set used = true, last_used_issue = greatest(coalesce(last_used_issue,0), new.issue_number)
   where word = new.answer;
  return new;
end $$;

drop trigger if exists issues_after on issues;
create trigger issues_after after insert or update on issues
  for each row execute function sw_issue_after();

create or replace function sw_issue_after_delete() returns trigger
language plpgsql as $$
begin
  update word_bank set used = exists(select 1 from issues where answer = old.answer),
                       last_used_issue = (select max(issue_number) from issues where answer = old.answer)
   where word = old.answer;
  return old;
end $$;

drop trigger if exists issues_after_delete on issues;
create trigger issues_after_delete after delete on issues
  for each row execute function sw_issue_after_delete();

-- Word bank: normalise + keep the dictionary superset in sync
create or replace function sw_word_bank_guard() returns trigger
language plpgsql as $$
begin
  new.word := upper(trim(new.word));
  insert into dictionary(word) values (lower(new.word)) on conflict do nothing;
  return new;
end $$;

drop trigger if exists word_bank_guard on word_bank;
create trigger word_bank_guard before insert or update on word_bank
  for each row execute function sw_word_bank_guard();


-- ============================================================
-- FILE: supabase/migrations/002_game_functions.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/003_leaderboards.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/004_admin.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/005_rls.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/seed/010_settings.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/seed/020_word_bank.sql
-- ============================================================
-- ============================================================
-- SPARK WORD — seed 020 · Curated word bank
--
-- Every answer is a recognisable five-letter industry term from the
-- worlds TMT Spark covers: Technology, Media & Telecommunications and
-- the built environment around them (data centers, power, semiconductors,
-- construction, real estate, cost & project management, engineering).
--
-- Columns: word · category · definition (shown after the game) ·
--          hint ("Need a Spark?" — indirect, never a giveaway) ·
--          related Spark Learning content (optional).
--
-- The editor picks each issue's word by hand in the admin dashboard.
-- Nothing rotates automatically.
-- ============================================================

insert into word_bank (word, category, definition, hint, related_type, related_ref) values

-- ---------------------------------------------------------------- AI & Compute
('MODEL','AI & Compute','The trained system at the heart of AI — billions of learned parameters that turn an input into a prediction, an answer or an image. Every model has a physical footprint: the compute, power and buildings needed to train and run it.','The thing that gets trained — and needs a very large building to do it.','explainer','What is an AI Factory?'),
('TRAIN','AI & Compute','Training is the phase where a model learns from data, running thousands of accelerators flat-out for weeks. It is the workload that drives gigawatt campuses, liquid cooling and long-term power deals.','What a model does for weeks before it is ready to answer anything.','explainer','What is an AI Factory?'),
('TOKEN','AI & Compute','The unit of text an AI model reads and writes. Tokens are the product of an AI factory — and every token costs electricity, which is why compute demand shows up as power demand.','The smallest unit an AI factory produces, billions at a time.','glossary','Token'),
('AGENT','AI & Compute','An AI system that can plan and take actions — booking, coding, operating a building — rather than just answering. Agents multiply inference demand and push AI into physical operations.','AI that does things, not just says things.',null,null),
('LAYER','AI & Compute','Neural networks are stacked in layers, each transforming the signal from the last. Deep networks mean more compute per token, which flows straight into rack density and cooling design.','Networks are built by stacking these, one on top of another.',null,null),
('QUERY','AI & Compute','A request to a database, a search engine or a model. AI inference turns every query into compute — and metro data centers exist to answer them with low latency.','Every question you type is one of these.','explainer','What is Edge Computing?'),
('BATCH','AI & Compute','Processing many requests or training examples together to keep accelerators busy. Batch size is a big lever on efficiency, throughput and how hard a rack runs.','Doing many at once instead of one at a time.',null,null),
('CACHE','AI & Compute','Fast memory that keeps recently used data close to the processor. Caching decides how much traffic reaches the wider network and shapes edge and content-delivery infrastructure.','Keeping the answer close so you don''t have to fetch it again.',null,null),
('ROBOT','AI & Compute','A machine that senses and acts in the physical world. Foundation models are moving robots from demos to paid pilots in factories and warehouses — which changes how those buildings are designed.','Physical AI, on wheels or legs.','story','a5'),
('DRONE','AI & Compute','An uncrewed aircraft, increasingly used for site surveys, progress monitoring and inspection on construction and infrastructure projects.','A flying camera that construction sites now schedule.',null,null),
('LOGIC','AI & Compute','The decision rules inside software — and, in schedules, the dependencies that link one activity to the next. Chips, models and project plans all run on it.','Chips execute it; so do project schedules.',null,null),
('INFER','AI & Compute','To run a trained model and produce an answer. Inference is the everyday workload of AI, spread across many smaller facilities close to users rather than one giant training campus.','What a model does after training, millions of times a day.','explainer','What is Edge Computing?'),

-- ---------------------------------------------------------------- Data Centers
('RACKS','Data Centers','The standardised cabinets that hold servers. Rack power draw has jumped from 5–10 kW to 100 kW and beyond for AI, which is why cooling, electrical design and site selection are being rethought.','Where servers live, and what now draws 100 kW.','story','a1'),
('AISLE','Data Centers','Data halls are arranged in hot and cold aisles so cooling air flows one way through the equipment. Aisle containment is one of the simplest ways to cut energy waste.','Hot ones and cold ones, side by side.',null,null),
('CAGES','Data Centers','Fenced-off areas inside a shared colocation hall, leased to a single customer. Cages are how a wholesale building becomes many tenants'' private space.','A tenant''s own fenced patch inside a shared hall.',null,null),
('FLOOR','Data Centers','A data center''s raised floor hides power and cooling beneath the racks. Floor loading is a hard design constraint — AI racks are heavy enough to break the old assumptions.','Raised in older halls; struggling under the weight in new ones.',null,null),
('SHELL','Data Centers','A powered shell is a building delivered with structure, power and cooling capacity but no IT fit-out — the fastest way to hand a tenant space they can finish themselves.','The building without the servers, delivered ready to fill.',null,null),
('HALLS','Data Centers','The large rooms where the racks actually sit. A campus is planned in halls of a set megawatt capacity, and "data hall" is the unit developers lease and contractors deliver.','The rooms inside the building that everyone actually leases.',null,null),
('PUMPS','Data Centers','Liquid cooling replaces fans with pumped coolant loops. Pumps, piping and heat exchangers are now mechanical scope on every AI build.','What moves coolant when air is no longer enough.','explainer','What is Liquid Cooling?'),
('PLATE','Data Centers','A cold plate is a metal block piped directly onto a chip to draw heat into liquid. It is the workhorse of direct-to-chip cooling in AI racks.','Sits right on the chip and carries the heat away.','glossary','Cold plate'),
('FLUID','Data Centers','Liquid cooling uses water-based or engineered fluids to remove heat far more effectively than air. Once racks pass roughly 40–50 kW, fluid becomes the default.','Air can''t do it any more; this can.','explainer','What is Liquid Cooling?'),
('PANEL','Data Centers','Electrical panels and switchboards distribute power from the substation to the racks. Long lead times on panels and switchgear now drive construction schedules.','It distributes power — and takes months to arrive.','story','l3'),
('TRAYS','Data Centers','Cable trays route power and fibre overhead through a data hall. Tray density is a surprisingly good proxy for how much a facility has grown.','Overhead highways for cable.',null,null),
('LOADS','Data Centers','IT load is the electricity the computers themselves consume; total facility load adds cooling and losses. The ratio between them is the famous PUE.','What the servers draw versus what the building draws.','glossary','PUE'),
('WATER','Data Centers','Cooling towers and liquid systems can consume enormous volumes of water. Water availability and reuse are becoming site-selection questions alongside power.','Data centers use it, communities worry about it.',null,null),

-- ---------------------------------------------------------------- Semiconductors
('WAFER','Semiconductors','A thin disc of silicon on which hundreds of chips are made at once. Wafer starts per month are how fab capacity is measured — and what the construction boom is built for.','A silicon disc, hundreds of chips at a time.','story','a4'),
('CHIPS','Semiconductors','The processors, memory and accelerators inside every device and server. AI demand for chips is the force behind the data center, power and fab construction boom.','Everything else on this map exists to make or house them.','explainer','What is a GPU?'),
('YIELD','Semiconductors','The share of chips on a wafer that work. Yield decides a fab''s economics — and, in real estate, the same word means the return a property earns.','A fab lives or dies by it; so does a real estate deal.',null,null),
('INGOT','Semiconductors','A single-crystal cylinder of ultra-pure silicon, grown then sliced into wafers. The very start of the chip supply chain.','The cylinder that becomes a thousand wafers.',null,null),
('MASKS','Semiconductors','Photomasks carry the pattern for each chip layer, projected onto the wafer by lithography. A leading-edge chip needs dozens of them.','Stencils for light, one per layer of a chip.',null,null),
('DIODE','Semiconductors','The simplest semiconductor device — it lets current flow one way. Diodes, transistors and their descendants are what a fab is built to make.','Current goes one way through it.',null,null),
('LASER','Semiconductors','Lithography, cutting, inspection and fibre optics all depend on lasers. Extreme-ultraviolet light sources are among the most complex machines in any building.','Light, focused into a tool.',null,null),
('OXIDE','Semiconductors','Silicon dioxide layers insulate and pattern a chip. Growing and etching oxide is a core fab process and one reason ultra-pure water and gases matter so much.','The insulating layer grown on silicon.',null,null),
('TOOLS','Semiconductors','In a fab, "tools" are the multi-million-dollar process machines — lithography, etch, deposition. Tool move-in is the milestone that tells you a fab is really on schedule.','What moves in when the cleanroom is finished.','story','a4'),
('CLEAN','Semiconductors','A cleanroom keeps the air thousands of times purer than an operating theatre. It is the core of a fab and one of the most demanding spaces construction teams ever deliver.','Thousands of times purer than a hospital.','glossary','Cleanroom'),

-- ---------------------------------------------------------------- Telecommunications
('FIBER','Telecommunications','Fibre-optic cable carries data as pulses of light with enormous capacity and low loss. It is the backbone of telecom networks, data center connectivity and the corridors linking AI campuses.','Strands of glass that carry data as pulses of light — the cable that connects a data center to the rest of the world.','glossary','Dark fiber'),
('TOWER','Telecommunications','Cell towers carry the antennas and radios that make mobile networks work — and tower cranes lift the steel that builds everything else on this map.','Antennas on top, or steel swinging from the top.',null,null),
('RADIO','Telecommunications','Wireless communication over the airwaves. Radio access networks — the towers, antennas and small cells — are the most visible and expensive part of a mobile network.','The airwaves part of every mobile network — towers, antennas and the signal between them.','explainer','What is Private 5G?'),
('CABLE','Telecommunications','From subsea systems to the runs inside a building, cable is how signal and power physically travel. Copper and fibre cabling are a major cost line in any technical fit-out.','It runs under oceans and above ceilings.',null,null),
('OPTIC','Telecommunications','Fibre-optic systems move information as light. Optical transceivers and switches are now a bottleneck in AI clusters, where thousands of accelerators must talk at once.','Light does the talking.','glossary','Dark fiber'),
('BANDS','Telecommunications','Spectrum is divided into frequency bands, licensed or shared. Which band a network uses decides its reach, speed and how many towers it needs.','Slices of spectrum, bought at auction.','explainer','What is Private 5G?'),
('CELLS','Telecommunications','A mobile network is a patchwork of cells, each served by a site. Small cells are how carriers densify cities and campuses — and battery cells are how they store power.','Networks are made of them; so are batteries.','explainer','What is Private 5G?'),
('RELAY','Telecommunications','Equipment that receives a signal and passes it on, extending reach. Relays sit in telecom networks, in satellite links and in the protective switching of power systems.','It receives, then passes it along.',null,null),
('ORBIT','Telecommunications','Satellite constellations in low Earth orbit now deliver broadband and direct-to-device service, changing the economics of rural and remote connectivity.','Where the newest broadband providers actually are.',null,null),
('MODEM','Telecommunications','The device that converts data into a signal a network can carry and back again — the front door between a building and the internet.','The box that turns your data into a signal.',null,null),
('POLES','Telecommunications','Utility poles carry power lines, fibre and small cells. Pole access and make-ready work are a hidden schedule risk on broadband and grid projects alike.','Wood or steel, they carry power and fibre through every town.',null,null),
('TRUNK','Telecommunications','A trunk line is the high-capacity link between major nodes — the middle mile of a network. Trunk fibre routes are being built along the corridors connecting AI data center clusters.','The big pipe between big places.','story','l4'),
('PULSE','Telecommunications','Fibre carries information as pulses of light; power systems and clocks run on pulses too. Timing and signal integrity are what engineers protect.','Light travels through fibre this way.',null,null),

-- ---------------------------------------------------------------- Media
('MEDIA','Media','Content and the businesses that make and distribute it — studios, streamers, sports, news and the creator economy. Media economics drive studio real estate, production hubs and delivery infrastructure.','The M in TMT.','story','l5'),
('VIDEO','Media','The heaviest traffic on the internet and the reason content-delivery and edge infrastructure exist. Streaming and sports rights are reshaping how it is paid for.','Most of the internet''s traffic, by weight.','story','l5'),
('AUDIO','Media','Podcasts, music and voice interfaces. Audio is light on bandwidth but heavy on studio space, rights and now AI-generated production.','Podcasts, music, and now voice assistants.',null,null),
('STAGE','Media','A sound stage is the purpose-built space where film and TV are shot; a project stage is a phase of delivery. Studio real estate is a construction market of its own.','Film sets are built on one; projects move through them.',null,null),
('PIXEL','Media','The smallest element of a digital image. Pixel counts drive display technology, camera sensors, bandwidth and the storage sitting in data centers.','The smallest dot on every screen.',null,null),
('FRAME','Media','A single image in a video, or the structural skeleton of a building. Both TMT and construction think in frames — per second, or in steel.','Twenty-four of them a second — or one of steel.',null,null),
('BRAND','Media','The identity a company builds in its audience''s mind. Media platforms and events exist to build one — and TMT Spark is one too.','What every newsletter is quietly building.',null,null),
('PRESS','Media','Journalism and publishing — and the printing presses that gave them their name. Press coverage still moves markets and shapes reputations.','It publishes stories; it also stamps out metal.',null,null),
('STORY','Media','The unit of media — an article, a segment, a post. Every edition of TMT Spark is built from them, and every project has one worth telling.','What every newsletter edition is made of.',null,null),
('MUSIC','Media','Streaming turned music into a subscription business and a rights business. Its licensing economics foreshadowed what is now happening to video.','Streamed first, before video followed.',null,null),
('GAMES','Media','Video games are the largest entertainment industry by revenue and a major driver of GPU development — the same chips now powering AI.','The entertainment industry that trained the GPU.',null,null),
('VIRAL','Media','Content that spreads rapidly through sharing. Virality is the growth engine of platforms — and the reason share buttons exist, including the one on this game.','How a share button earns its keep.',null,null),

-- ---------------------------------------------------------------- Energy & Power
('POWER','Energy & Power','Electricity is now the binding constraint on AI growth. Rack densities past 100 kW and campuses measured in gigawatts mean site selection is an energy question first.','Measured in megawatts and gigawatts — the one thing every new data center campus is short of.','story','a1'),
('WATTS','Energy & Power','The unit of power. Data centers are sized in megawatts and gigawatts; a single AI rack draws more than a hundred thousand of these.','Kilo-, mega- and giga- versions decide everything.',null,null),
('VOLTS','Energy & Power','Voltage is electrical pressure. Moving data center distribution to higher-voltage DC cuts conversion losses, copper and heat — a quiet revolution in electrical design.','Pushing this up inside the building saves copper.','explainer','What is 800V DC?'),
('SOLAR','Energy & Power','Photovoltaic generation, now the cheapest new electricity in most markets. Paired with storage, solar is a core part of the power mix behind digital infrastructure.','Cheapest new electricity, weather permitting.',null,null),
('HYDRO','Energy & Power','Hydroelectric power — firm, low-carbon and historically why data centers clustered in places like the Pacific Northwest and the Nordics.','Why data centers first went to the Pacific Northwest.',null,null),
('STEAM','Energy & Power','Most of the world''s electricity still comes from spinning a turbine with steam — gas, coal, nuclear and geothermal alike. Steam also heats and sterilises industrial campuses.','What spins most turbines on Earth.',null,null),
('SURGE','Energy & Power','A sudden spike in current or demand. Surge protection guards equipment; demand surges from AI are what utilities are now planning around.','Protection against it is built into every panel.',null,null),
('METER','Energy & Power','The point where a utility measures what you use. Behind-the-meter generation bypasses the grid queue by making power on site — from gas turbines today to reactors tomorrow.','Generate behind it and you skip the queue.','glossary','Behind-the-meter'),
('PLANT','Energy & Power','A power plant, a manufacturing plant or a mechanical plant room — the industrial heart of any campus. Data centers are increasingly co-developed with their own generation plant.','Generates power, or makes things, or hides in the basement.',null,null),
('JOULE','Energy & Power','The unit of energy. A watt is one joule per second — the bridge between the energy a model consumes and the power a building must deliver.','One per second is a watt.',null,null),
('WIRES','Energy & Power','Conductors carrying electricity, from transmission lines to the copper inside a rack. Every megawatt needs miles of them, which is why higher voltage saves so much.','Copper by the mile, in every wall and rack.',null,null),
('FUELS','Energy & Power','Gas, diesel, hydrogen and uranium — what turbines, generators and reactors run on. Fuel choice sets emissions, cost and how quickly a site can get firm power.','Turbines and backup generators need them.',null,null),
('ATOMS','Energy & Power','Nuclear energy splits them. Hyperscalers are signing long-term nuclear deals and backing small modular reactors because AI wants firm, carbon-free power at gigawatt scale.','Split them for firm, carbon-free gigawatts.','explainer','What is a Small Modular Reactor?'),
('SPARK','Energy & Power','The discharge that jumps a gap when voltage is high enough — and the moment an idea catches. Spark gaps protect equipment; spark ignition starts engines; TMT Spark starts conversations.','It jumps the gap. It also names this newsletter.',null,null),

-- ---------------------------------------------------------------- Construction
('BUILD','Construction','To construct — and, as a noun, the project itself. Everything in TMT eventually becomes a build: a fab, a campus, a tower, an office.','What every plan eventually has to become.',null,null),
('STEEL','Construction','The structural material of data centers, fabs and towers. Steel prices, tariffs and lead times move construction cost more than almost anything else.','The metal that frames data centers, fabs and towers — beams, columns, rebar.','story','a4'),
('CRANE','Construction','The lifting equipment that sets the pace of a site. Crane availability and lift plans are a real constraint on fast-track data center and fab programmes.','It sets the pace of every site it towers over.',null,null),
('SITES','Construction','Where projects happen. Site selection now starts with power and fibre availability, and site logistics decide whether a schedule survives contact with reality.','Chosen for power first, land second.','story','l1'),
('SLABS','Construction','Flat concrete floors and foundations. Data hall slabs must carry AI racks that are heavier than anything the last generation of buildings assumed.','Concrete, flat and now carrying much heavier racks.',null,null),
('BEAMS','Construction','Horizontal structural members that carry floors and roofs to columns. Long-span beams create the column-free halls data centers and studios need.','They span the hall so columns don''t have to.',null,null),
('BRICK','Construction','The oldest modular building unit. Brick still clads offices and substations — and "brick" is the industry''s word for hardware that has stopped working.','Buildings are made of them; dead devices become one.',null,null),
('REBAR','Construction','Steel reinforcing bar embedded in concrete to give it tensile strength. Rebar tonnage is a bellwether of how much heavy construction is really happening.','Steel inside the concrete.',null,null),
('TRUSS','Construction','A triangulated frame that spans long distances with little material — roof trusses, tower structures and crane booms all use the same geometry.','Triangles that hold up roofs.',null,null),
('JOIST','Construction','The repeated horizontal members that support a floor or ceiling between beams. Joist depth is what limits how much you can run overhead.','Between the beams, holding up the floor.',null,null),
('PILES','Construction','Deep foundations driven or drilled into the ground when the soil near the surface cannot carry the building. Piling is often the first and noisiest phase of a data center.','Driven deep before anything rises.',null,null),
('GRADE','Construction','Ground level and the slope of a site — "at grade" means on the ground floor. Grading is the earthworks that turn a field into a buildable platform.','Level the site to this before you build.',null,null),
('LEVEL','Construction','A floor of a building, the tool that checks it is flat, and the quality of being so. Every site starts by establishing one.','Every floor is one; every builder checks one.',null,null),
('CREWS','Construction','The skilled trades who deliver a project. Fab and data center mega-projects absorb crews for years, tightening labour and cost for everyone building nearby.','Labour is the schedule, and they are the labour.','story','a4'),
('BOLTS','Construction','How steel is connected on site. High-strength bolting lets a structure go up fast — modular electrical rooms and prefabricated frames rely on it.','Steel goes up faster with them than with welds.',null,null),
('WELDS','Construction','Fused metal joints in structural steel and pipework. Welding capacity, inspection and certification are real bottlenecks on fabs and liquid-cooling installations.','Joints that need an inspector''s sign-off.',null,null),
('WALLS','Construction','Structural, partition, curtain and fire walls. In a data center, walls define halls, fire compartments and secure zones — and change every time a tenant does.','They define halls, zones and compartments.',null,null),
('DRAIN','Construction','Drainage carries water away from a site and a building. Liquid cooling has put leak detection and drainage back on the data hall design agenda.','Where the water goes when it must not stay.',null,null),
('HOIST','Construction','The lift that moves people and material up a building under construction — and the mechanism that raises crane loads. Hoist capacity is a hidden schedule driver on tall projects.','It goes up the outside of a building under construction.',null,null),
('FORMS','Construction','Formwork — the temporary moulds concrete is poured into. Reusable forms are one of the biggest productivity levers on repetitive structures like data halls.','Concrete is poured into them, then they come off.',null,null),
('GROUT','Construction','A fluid cement mix that fills gaps — under column base plates, around anchors, between tiles. Small item, big consequence when it is wrong.','Fills the gap under every column base.',null,null),
('BLOCK','Construction','Concrete masonry units, the city block a site sits on, or a block of a schedule. Blockwork still builds the substations and plant rooms behind every campus.','Masonry, or the piece of the city you build on.',null,null),
('STUDS','Construction','The vertical members inside a wall. Metal studs frame nearly every office fit-out — and stud spacing is where cost and speed get won or lost.','Inside every partition wall, evenly spaced.',null,null),
('PIERS','Construction','Vertical supports carrying loads to the ground — bridge piers, foundation piers, or the piers a port is built on. Ports are where private 5G first went to work.','Vertical supports; also where ships tie up.',null,null),

-- ---------------------------------------------------------------- Real Estate
('LEASE','Real Estate','The contract that lets a tenant occupy space. Data center capacity is leased years ahead, AI occupiers sign fast, and lease terms now cover power and connectivity as well as floor area.','Signed years ahead for capacity that isn''t built yet.','story','l7'),
('ASSET','Real Estate','A property or piece of infrastructure held for value. Digital infrastructure has become an asset class of its own, financed by funds that once bought toll roads.','Investors call the building one.','story','l2'),
('RENTS','Real Estate','What tenants pay for space — priced per square foot for offices and per kilowatt for data centers. Rents are the signal of scarcity in every market Spark covers.','Priced per square foot, or per kilowatt.',null,null),
('OWNER','Real Estate','The party that holds the asset and, on a project, the client who pays for it. Owner-furnished equipment is how owners take control of long-lead procurement.','The client, the landlord, the one who pays.',null,null),
('TITLE','Real Estate','Legal ownership of land, recorded and insured before any deal closes. Title issues can stall a site long after the power is secured.','Proof you own the land.',null,null),
('ZONES','Real Estate','Zoning decides what may be built where. Data centers, fabs and studios all live or die by zoning — and cooling systems have their own thermal zones.','Planning rules decide what goes in each one.',null,null),
('PLOTS','Real Estate','Parcels of land. Plot size, shape and access shape a campus master plan — and plots of data are how engineers read a project''s performance.','Land parcels, or charts of data.',null,null),
('SPACE','Real Estate','The product of real estate — office, industrial, studio, white space in a data hall. How much, how fast and how flexible is the whole occupier conversation.','What landlords sell and occupiers need faster.','story','l7'),
('SUITE','Real Estate','A self-contained unit of leased space — an office suite or a data hall suite delivered to one customer. Suite sizes define how a building is marketed.','A private unit inside a shared building.',null,null),
('ACRES','Real Estate','The unit of land at campus scale. AI data center sites are now measured in hundreds of acres, chosen for the substation next door as much as the land itself.','Hundreds of them, next to a substation.',null,null),
('VALUE','Real Estate','What an asset is worth, and what a project is meant to deliver. Value engineering is the discipline of getting the same outcome for less.','What an appraisal finds and a cost plan protects.',null,null),
('TRUST','Real Estate','A real estate investment trust holds income-producing property on behalf of shareholders — including many of the world''s largest data center landlords.','The T in REIT.',null,null),

-- ---------------------------------------------------------------- Cost Management
('COSTS','Cost Management','Everything a project spends — labour, materials, equipment, fees and risk. Managing them is Turner & Townsend''s oldest craft and the discipline every TMT programme depends on.','The plan protects them; the market moves them.',null,null),
('QUOTE','Cost Management','A supplier''s stated price for a defined scope. Quote validity periods are shrinking as equipment lead times and prices move.','A supplier''s price, valid for a limited time.',null,null),
('PRICE','Cost Management','What something costs to buy. Pricing the next-generation specification — not last cycle''s — is the difference between a cost plan that holds and one that doesn''t.','What the market charges today, not last year.','story','a2'),
('TOTAL','Cost Management','The bottom line of a cost plan or a tender. Total cost of ownership adds operating energy and maintenance to the capital number.','The bottom line.',null,null),
('AUDIT','Cost Management','A formal examination of costs, contracts or performance. Cost audits recover money; energy audits find waste; both are core advisory work.','Checking the numbers after the fact.',null,null),
('RATES','Cost Management','Unit prices — labour rates, rental rates, interest rates and the rates in a schedule of prices. Rate escalation is what a cost manager watches most closely.','Labour ones, interest ones, rental ones.',null,null),
('CLAIM','Cost Management','A formal request for extra money or time under a contract. Managing claims fairly is a big part of keeping mega-projects out of dispute.','A contractor''s formal request for more.',null,null),
('SPEND','Cost Management','Money committed and paid over time. Cash-flow forecasting — when the spend lands — matters as much as the total for a client''s capital plan.','Forecast by month, not just in total.',null,null),
('WASTE','Cost Management','Material, energy or effort that adds no value. Cutting waste is the shared goal of lean construction and data center efficiency alike.','What lean construction and PUE both try to remove.','glossary','PUE'),
('INDEX','Cost Management','A published measure of price movement, used to benchmark and escalate costs. Regional indices near fab hubs are running well ahead of national ones.','A benchmark that tells you how much prices moved.',null,null),
('TREND','Cost Management','The direction costs, lead times or demand are moving. Reading the trend early is what separates a cost plan from a cost surprise.','Which way the numbers are heading.',null,null),
('BASIS','Cost Management','The assumptions a cost plan or design is built on — the basis of design, the basis of estimate. Change the basis and every number moves.','The assumptions underneath the number.',null,null),
('ORDER','Cost Management','A change order alters scope, cost or time after award; a purchase order commits money. Both are where the real cost of a project gets decided.','Change ones and purchase ones.',null,null),
('AWARD','Cost Management','The moment a contract is granted to a bidder. Everything before it is pricing; everything after it is delivery.','The moment the bid becomes a contract.',null,null),
('CAPEX','Cost Management','Capital expenditure — money spent to build or buy long-lived assets. Hyperscaler capex is the number the whole data center supply chain plans around.','The spending figure the whole supply chain watches.','story','l2'),
('UNITS','Cost Management','Units of measure and units of accommodation. Unit rates — cost per megawatt, per square foot, per wafer start — are how benchmarks travel between projects.','Per megawatt, per square foot, per rack.',null,null),

-- ---------------------------------------------------------------- Project Management
('SCOPE','Project Management','What a project includes and, just as importantly, what it doesn''t. Scope creep is the quiet enemy of every budget and schedule.','Define it early; watch it creep.',null,null),
('PHASE','Project Management','A stage of a programme — and, in electrical systems, one of the three alternating currents feeding a building. Phased delivery is how AI occupiers get floors on time.','Projects have them; so does three-phase power.','story','l7'),
('TASKS','Project Management','The activities that make up a schedule. Linked by logic, sized by duration, owned by someone — thousands of them on a data center programme.','Thousands of them, linked in a schedule.',null,null),
('DELAY','Project Management','Time lost against the plan. Delay analysis decides who pays for it; procurement-first scheduling exists to avoid it.','Every long lead time threatens one.','story','l3'),
('RISKS','Project Management','Uncertain events that could hurt cost, time or quality. A risk register that names power, labour and equipment lead times reads like this quarter''s roundtables.','Listed in a register, priced in a contingency.',null,null),
('TEAMS','Project Management','The people who deliver. Integrated project teams put owner, designer, contractor and cost manager around one table — a Spark Session in hard hats.','Integrated ones deliver; siloed ones dispute.',null,null),
('FLOAT','Project Management','The amount an activity can slip without delaying the project. Who owns the float is one of the oldest arguments in construction contracts.','Slack in a schedule, and an argument over who owns it.',null,null),
('BRIEF','Project Management','The client''s statement of what they need — the document every design should answer. Also what TMT Spark calls its monthly newsletter.','The client writes it; the design answers it.',null,null),
('PLANS','Project Management','Drawings, schedules and strategies — the documents a project runs on. Plans change; the discipline is managing the change.','Drawn, scheduled, then changed.',null,null),
('DATES','Project Management','Milestones — energisation, tool move-in, occupancy. For AI occupiers the expensive risk is a late floor, not a change order, so dates rule.','Energisation, move-in, occupancy.',null,null),
('GATES','Project Management','Stage gates are the decision points where a programme is approved to proceed. Gate reviews are where capital is committed or paused.','Approval points between stages.',null,null),
('DRAFT','Project Management','An early version of a document, design or plan — and, in engineering, the current of air a chimney or data hall relies on.','Version one, before the red pen.',null,null),
('AGILE','Project Management','An iterative way of working, born in software, now applied to programme delivery and fit-out. Short cycles, fast decisions, constant reprioritisation.','Software''s way of working, now on site.',null,null),
('SCRUM','Project Management','A lightweight framework for agile teams: short sprints, daily stand-ups, a backlog. Increasingly used to run design and fit-out for fast-moving occupiers.','Sprints, stand-ups and a backlog.',null,null),
('CHART','Project Management','A visual schedule or dataset — the bar chart every project lives by, or the growth chart every platform watches.','Bars on a timeline, or a line going up.',null,null),
('TRACK','Project Management','To monitor progress against plan — and the fast track that compresses design and construction. Tracking cost and schedule weekly is how surprises are caught early.','Fast ones compress schedules; good ones catch drift.',null,null),

-- ---------------------------------------------------------------- Engineering
('VALVE','Engineering','A device that controls flow in a pipe. Liquid-cooled data halls contain thousands, and valve failure is the leak scenario every operator plans for.','It controls flow, and there are thousands per hall now.','explainer','What is Liquid Cooling?'),
('DUCTS','Engineering','Channels that carry air, cable or fibre. Ductwork moves cooling air through a building; fibre ducts move signal under a city.','Air overhead, fibre underground.',null,null),
('PIPES','Engineering','The circulatory system of a building — water, coolant, gas and drainage. Liquid cooling has turned the data hall into a piping project.','Data halls are now full of them.','explainer','What is Liquid Cooling?'),
('MOTOR','Engineering','Converts electricity into motion. Motors drive pumps, fans, chillers, cranes and elevators — most of a building''s mechanical load.','It turns electricity into motion.',null,null),
('GEARS','Engineering','Toothed wheels that transmit and transform motion. Gearboxes sit inside cranes, turbines and hoists — and "gearing" is also how a deal is financed.','Turbines have them; so do leveraged deals.',null,null),
('SHAFT','Engineering','A rotating rod that transmits power, or the vertical void that carries lifts, risers and services through a building. Both must be sized before the structure is fixed.','Rotating in a machine, or vertical in a building.',null,null),
('GAUGE','Engineering','An instrument that measures — pressure, temperature, flow — or the thickness of wire and sheet metal. Data centers are gauged everywhere.','It measures pressure, or describes wire thickness.',null,null),
('ANGLE','Engineering','A geometric measure, and an L-shaped steel section used for framing and bracing. Angle brackets hold up most of what hangs from a ceiling.','Measured in degrees, or rolled in steel.',null,null),
('SLOPE','Engineering','Gradient — of a roof, a drain, a site or a cost curve. Drainage design, road access and cable routing all start with it.','Roofs need it; drains depend on it.',null,null),
('CURVE','Engineering','The shape of a relationship: a load curve, a learning curve, an S-curve of spend over time. Engineers and cost managers both read them.','Load ones, cost ones, learning ones.',null,null),
('FORCE','Engineering','A push or pull. Structural engineering is the art of routing forces safely to the ground — including the weight of racks nobody planned for.','Structures exist to carry it to the ground.',null,null),
('COILS','Engineering','Cooling coils transfer heat between air and fluid; transformer coils transfer power between voltages. Both are long-lead items right now.','In the air handler, and inside the transformer.','story','l3'),
('ROTOR','Engineering','The rotating part of a motor, generator or turbine. Rotor failures are why generator maintenance is in every data center''s risk register.','The spinning part of every turbine and generator.',null,null),
('BRACE','Engineering','A diagonal member that stiffens a structure against wind and earthquake. Seismic bracing is a major scope item on West Coast fabs and data centers.','Diagonal steel against wind and earthquakes.',null,null),
('ALLOY','Engineering','A metal blended for strength, conductivity or corrosion resistance. Aluminium alloys, copper alloys and specialty steels run through every TMT supply chain.','Metals, blended on purpose.',null,null),
('STRUT','Engineering','A compression member that holds parts apart — the slotted channel that supports pipes, trays and conduit in every plant room.','Slotted channel holding up pipes and trays.',null,null),
('SCALE','Engineering','Scaling is the whole story of AI infrastructure: from megawatts to gigawatts, from one hall to a campus. In engineering, scale is also the drawing ratio and the deposit in a pipe.','Gigawatts are what happens when you do this to megawatts.','explainer','What is an AI Factory?'),

-- ---------------------------------------------------------------- Digital Infrastructure
('CLOUD','Digital Infrastructure','Computing delivered as a service from someone else''s data centers. Cloud demand built the hyperscale industry; AI is now building its second wave.','Computing you rent by the hour from someone else''s data center.','glossary','Hyperscaler'),
('NODES','Digital Infrastructure','Points on a network — a server, a switch, a cell site — and the process nodes that name each chip generation. Networks and fabs both advance node by node.','Networks are made of them; so are chip roadmaps.',null,null),
('ROUTE','Digital Infrastructure','The path data takes across a network, and the corridor a fibre or power line follows across a map. Route selection is real estate for infrastructure.','The path across a network, or across a map.','story','l4'),
('LINKS','Digital Infrastructure','Connections between nodes — fibre links, microwave links, the links in a supply chain. Bandwidth between AI accelerators is now as important as the accelerators themselves.','Between every pair of nodes.',null,null),
('PORTS','Digital Infrastructure','Network ports connect equipment; seaports connect economies. Both are where private 5G and automation arrived first.','Switches have them; ships use them.','story','l6'),
('STACK','Digital Infrastructure','The layered set of technologies that make a product work, from silicon to software. "Full stack" is now a description of AI companies that build their own data centers.','From the chip to the app, layer by layer.',null,null),
('SPINE','Digital Infrastructure','In a spine-leaf network, spine switches connect every leaf so any server can reach any other in one hop. It is the backbone of a modern data hall.','The backbone of a data hall network.',null,null),
('PATCH','Digital Infrastructure','A patch panel is where cables terminate and cross-connect; a software patch fixes a vulnerability. Both are maintenance that cannot be skipped.','Panels for cable, updates for software.',null,null),
('HOSTS','Digital Infrastructure','Machines that run workloads, and the companies that house them. Hosting is where the cloud began — racks in someone else''s building.','Servers are them; so are the companies that house them.',null,null),
('PROXY','Digital Infrastructure','An intermediary that handles requests on behalf of another system. Proxies sit at the edge of networks for security, caching and control.','It stands in for another system.',null,null),
('CYBER','Digital Infrastructure','Security in the digital domain. Data centers, grids and smart buildings are all cyber-physical systems now, and their attack surface is physical too.','Security that protects both the network and the building.',null,null),
('BYTES','Digital Infrastructure','The basic unit of digital storage. Zettabytes of data are why storage halls, fibre routes and backup power keep being built.','Eight bits, times a great many.',null,null),
('SMART','Digital Infrastructure','Buildings and grids that sense and respond — smart meters, smart buildings, smart cities. The tech has finally cleared its payback bar.','Buildings that finally pay back their sensors.','story','l8'),
('TWINS','Digital Infrastructure','A digital twin is a live virtual model of a real asset, kept in sync with sensor data. Twins let teams design, rehearse and operate a building before and while it exists.','A live virtual copy of a real building.','explainer','What is a Digital Twin?')
on conflict (word) do update set
  category = excluded.category, definition = excluded.definition, hint = excluded.hint,
  related_type = excluded.related_type, related_ref = excluded.related_ref;


-- ============================================================
-- FILE: supabase/seed/030_dictionary.sql
-- ============================================================
-- ============================================================
-- SPARK WORD — seed 030 · Guess dictionary
-- 12578 valid five-letter English words (source: the MIT-licensed
-- `word-list` npm package, filtered to five letters, plus every word-bank
-- answer so an answer is always a legal guess). Answers come ONLY from
-- word_bank; this table just decides which guesses are accepted.
-- ============================================================
insert into dictionary (word) values
('aahed'),('aalii'),('aargh'),('aarti'),('abaca'),('abaci'),('aback'),('abacs'),('abaft'),('abaka'),('abamp'),('aband'),
('abase'),('abash'),('abask'),('abate'),('abaya'),('abbas'),('abbed'),('abbes'),('abbey'),('abbot'),('abcee'),('abeam'),
('abear'),('abele'),('abets'),('abhor'),('abide'),('abies'),('abled'),('abler'),('ables'),('ablet'),('ablow'),('abmho'),
('abode'),('abohm'),('aboil'),('aboma'),('aboon'),('abord'),('abore'),('abort'),('about'),('above'),('abram'),('abray'),
('abrim'),('abrin'),('abris'),('absey'),('absit'),('abuna'),('abune'),('abuse'),('abuts'),('abuzz'),('abyes'),('abysm'),
('abyss'),('acais'),('acari'),('accas'),('accoy'),('acerb'),('acers'),('aceta'),('achar'),('ached'),('aches'),('achoo'),
('acids'),('acidy'),('acing'),('acini'),('ackee'),('acker'),('acmes'),('acmic'),('acned'),('acnes'),('acock'),('acold'),
('acorn'),('acred'),('acres'),('acrid'),('acted'),('actin'),('acton'),('actor'),('acute'),('acyls'),('adage'),('adapt'),
('adaws'),('adays'),('addax'),('added'),('adder'),('addio'),('addle'),('adeem'),('adept'),('adhan'),('adieu'),('adios'),
('adits'),('adman'),('admen'),('admin'),('admit'),('admix'),('adobe'),('adobo'),('adopt'),('adore'),('adorn'),('adown'),
('adoze'),('adrad'),('adred'),('adsum'),('aduki'),('adult'),('adunc'),('adust'),('advew'),('adyta'),('adzed'),('adzes'),
('aecia'),('aedes'),('aegis'),('aeons'),('aerie'),('aeros'),('aesir'),('afald'),('afara'),('afars'),('afear'),('affix'),
('afire'),('aflaj'),('afoot'),('afore'),('afoul'),('afrit'),('afros'),('after'),('again'),('agama'),('agami'),('agape'),
('agars'),('agast'),('agate'),('agave'),('agaze'),('agene'),('agent'),('agers'),('agger'),('aggie'),('aggri'),('aggro'),
('aggry'),('aghas'),('agila'),('agile'),('aging'),('agios'),('agism'),('agist'),('agita'),('aglee'),('aglet'),('agley'),
('agloo'),('aglow'),('aglus'),('agmas'),('agoge'),('agone'),('agons'),('agony'),('agood'),('agora'),('agree'),('agria'),
('agrin'),('agued'),('agues'),('aguna'),('aguti'),('ahead'),('aheap'),('ahent'),('ahigh'),('ahind'),('ahing'),('ahint'),
('ahold'),('ahull'),('ahuru'),('aidas'),('aided'),('aider'),('aides'),('aidoi'),('aidos'),('aiery'),('aigas'),('aight'),
('ailed'),('aimed'),('aimer'),('ainee'),('ainga'),('aioli'),('aired'),('airer'),('airns'),('airth'),('airts'),('aisle'),
('aitch'),('aitus'),('aiver'),('aizle'),('ajiva'),('ajuga'),('ajwan'),('akees'),('akela'),('akene'),('aking'),('akita'),
('akkas'),('alaap'),('alack'),('alamo'),('aland'),('alane'),('alang'),('alans'),('alant'),('alapa'),('alaps'),('alarm'),
('alary'),('alate'),('alays'),('albas'),('albee'),('album'),('alcid'),('alcos'),('aldea'),('alder'),('aldol'),('aleck'),
('alecs'),('alefs'),('aleft'),('aleph'),('alert'),('alews'),('aleye'),('alfas'),('algae'),('algal'),('algas'),('algid'),
('algin'),('algor'),('algum'),('alias'),('alibi'),('alien'),('alifs'),('align'),('alike'),('aline'),('alist'),('alive'),
('aliya'),('alkie'),('alkos'),('alkyd'),('alkyl'),('allay'),('allee'),('allel'),('alley'),('allis'),('allod'),('allot'),
('allow'),('alloy'),('allyl'),('almah'),('almas'),('almeh'),('almes'),('almud'),('almug'),('alods'),('aloed'),('aloes'),
('aloft'),('aloha'),('aloin'),('alone'),('along'),('aloof'),('aloos'),('aloud'),('alowe'),('alpha'),('altar'),('alter'),
('altho'),('altos'),('alula'),('alums'),('alure'),('alway'),('amahs'),('amain'),('amass'),('amate'),('amaut'),('amaze'),
('amban'),('amber'),('ambit'),('amble'),('ambos'),('ambry'),('ameba'),('ameer'),('amend'),('amene'),('amens'),('ament'),
('amias'),('amice'),('amici'),('amide'),('amido'),('amids'),('amies'),('amiga'),('amigo'),('amine'),('amino'),('amins'),
('amirs'),('amiss'),('amity'),('amlas'),('amman'),('ammon'),('ammos'),('amnia'),('amnic'),('amnio'),('amoks'),('amole'),
('among'),('amort'),('amour'),('amove'),('amowt'),('amped'),('ample'),('amply'),('ampul'),('amrit'),('amuck'),('amuse'),
('amyls'),('anana'),('anata'),('ancho'),('ancle'),('ancon'),('andro'),('anear'),('anele'),('anent'),('angas'),('angel'),
('anger'),('angle'),('anglo'),('angry'),('angst'),('anigh'),('anile'),('anils'),('anima'),('anime'),('animi'),('anion'),
('anise'),('anker'),('ankhs'),('ankle'),('ankus'),('anlas'),('annal'),('annas'),('annat'),('annex'),('annoy'),('annul'),
('anoas'),('anode'),('anole'),('anomy'),('ansae'),('antae'),('antar'),('antas'),('anted'),('antes'),('antic'),('antis'),
('antra'),('antre'),('antsy'),('anvil'),('anyon'),('aorta'),('apace'),('apage'),('apaid'),('apart'),('apayd'),('apays'),
('apeak'),('apeek'),('apers'),('apert'),('apery'),('apgar'),('aphid'),('aphis'),('apian'),('aping'),('apiol'),('apish'),
('apism'),('apnea'),('apode'),('apods'),('apoop'),('aport'),('appal'),('appay'),('appel'),('apple'),('apply'),('appro'),
('appui'),('appuy'),('apres'),('apron'),('apses'),('apsis'),('apsos'),('apted'),('apter'),('aptly'),('aquae'),('aquas'),
('araba'),('araks'),('arame'),('arars'),('arbas'),('arbor'),('arced'),('arcos'),('arcus'),('ardeb'),('ardor'),('ardri'),
('aread'),('areae'),('areal'),('arear'),('areas'),('areca'),('aredd'),('arede'),('arefy'),('areic'),('arena'),('arene'),
('arepa'),('arere'),('arete'),('arets'),('arett'),('argal'),('argan'),('argil'),('argle'),('argol'),('argon'),('argot'),
('argue'),('argus'),('arhat'),('arias'),('ariel'),('ariki'),('arils'),('ariot'),('arise'),('arish'),('arked'),('arled'),
('arles'),('armed'),('armer'),('armet'),('armil'),('armor'),('arnas'),('arnut'),('aroba'),('aroha'),('aroid'),('aroma'),
('arose'),('arpas'),('arpen'),('arrah'),('arras'),('array'),('arret'),('arris'),('arrow'),('arsis'),('arson'),('artal'),
('artel'),('artic'),('artis'),('artsy'),('aruhe'),('arums'),('arval'),('arvos'),('aryls'),('asana'),('ascot'),('ascus'),
('asdic'),('ashed'),('ashen'),('ashes'),('ashet'),('aside'),('asked'),('asker'),('askew'),('askoi'),('askos'),('aspen'),
('asper'),('aspic'),('aspis'),('aspro'),('assai'),('assam'),('assay'),('asset'),('assez'),('assot'),('aster'),('astir'),
('astun'),('asway'),('aswim'),('asyla'),('ataps'),('ataxy'),('atigi'),('atilt'),('atimy'),('atlas'),('atman'),('atmas'),
('atocs'),('atoke'),('atoks'),('atoll'),('atoms'),('atomy'),('atone'),('atony'),('atopy'),('atria'),('atrip'),('attap'),
('attar'),('attic'),('atuas'),('audad'),('audio'),('audit'),('auger'),('aught'),('augur'),('aulas'),('aulic'),('auloi'),
('aulos'),('aumil'),('aunes'),('aunts'),('aunty'),('aurae'),('aural'),('aurar'),('auras'),('aurei'),('aures'),('auric'),
('auris'),('aurum'),('autos'),('auxin'),('avail'),('avale'),('avant'),('avast'),('avels'),('avens'),('avers'),('avert'),
('avgas'),('avian'),('avine'),('avion'),('avise'),('aviso'),('avize'),('avoid'),('avows'),('avyze'),('await'),('awake'),
('award'),('aware'),('awarn'),('awash'),('awato'),('awave'),('aways'),('awdls'),('aweel'),('aweto'),('awful'),('awing'),
('awmry'),('awned'),('awner'),('awoke'),('awols'),('awork'),('axels'),('axial'),('axile'),('axils'),('axing'),('axiom'),
('axion'),('axite'),('axled'),('axles'),('axman'),('axmen'),('axoid'),('axone'),('axons'),('ayahs'),('ayelp'),('aygre'),
('ayins'),('ayont'),('ayres'),('ayrie'),('azans'),('azide'),('azido'),('azine'),('azlon'),('azoic'),('azole'),('azons'),
('azote'),('azoth'),('azuki'),('azure'),('azurn'),('azury'),('azygy'),('azyme'),('azyms'),('baaed'),('baals'),('babas'),
('babel'),('babes'),('babka'),('baboo'),('babul'),('babus'),('bacca'),('bacco'),('baccy'),('bacha'),('bachs'),('backs'),
('bacon'),('baddy'),('badge'),('badly'),('baels'),('baffs'),('baffy'),('bafts'),('bagel'),('baggy'),('baghs'),('bagie'),
('bahts'),('bahus'),('bahut'),('bails'),('bairn'),('baith'),('baits'),('baiza'),('baize'),('bajan'),('bajra'),('bajri'),
('bajus'),('baked'),('baken'),('baker'),('bakes'),('bakra'),('balas'),('balds'),('baldy'),('baled'),('baler'),('bales'),
('balks'),('balky'),('bally'),('balms'),('balmy'),('baloo'),('balsa'),('balti'),('balun'),('balus'),('bambi'),('banak'),
('banal'),('banco'),('bancs'),('banda'),('bandh'),('bands'),('bandy'),('baned'),('banes'),('bangs'),('bania'),('banjo'),
('banks'),('banns'),('bants'),('bantu'),('banty'),('banya'),('bapus'),('barbe'),('barbs'),('barby'),('barca'),('barde'),
('bardo'),('bards'),('bardy'),('bared'),('barer'),('bares'),('barfs'),('barge'),('baric'),('barks'),('barky'),('barms'),
('barmy'),('barns'),('barny'),('baron'),('barps'),('barra'),('barre'),('barro'),('barry'),('barye'),('basal'),('basan'),
('based'),('basen'),('baser'),('bases'),('basho'),('basic'),('basij'),('basil'),('basin'),('basis'),('basks'),('bason'),
('basse'),('bassi'),('basso'),('bassy'),('basta'),('baste'),('basti'),('basto'),('basts'),('batch'),('bated'),('bates'),
('bathe'),('baths'),('batik'),('baton'),('batta'),('batts'),('battu'),('batty'),('bauds'),('bauks'),('baulk'),('baurs'),
('bavin'),('bawds'),('bawdy'),('bawls'),('bawns'),('bawrs'),('bawty'),('bayed'),('bayes'),('bayle'),('bayou'),('bayts'),
('bazar'),('bazoo'),('beach'),('beads'),('beady'),('beaks'),('beaky'),('beams'),('beamy'),('beano'),('beans'),('beany'),
('beard'),('beare'),('bears'),('beast'),('beath'),('beats'),('beaty'),('beaus'),('beaut'),('beaux'),('bebop'),('becap'),
('becke'),('becks'),('bedad'),('bedel'),('bedes'),('bedew'),('bedim'),('bedye'),('beech'),('beedi'),('beefs'),('beefy'),
('beeps'),('beers'),('beery'),('beets'),('befit'),('befog'),('begad'),('began'),('begar'),('begat'),('begem'),('beget'),
('begin'),('begot'),('begum'),('begun'),('beige'),('beigy'),('being'),('bekah'),('belah'),('belar'),('belay'),('belch'),
('belee'),('belga'),('belie'),('belle'),('bells'),('belly'),('belon'),('below'),('belts'),('bemad'),('bemas'),('bemix'),
('bemud'),('bench'),('bends'),('bendy'),('benes'),('benet'),('benga'),('benis'),('benne'),('benni'),('benny'),('bento'),
('bents'),('benty'),('bepat'),('beray'),('beres'),('beret'),('bergs'),('berko'),('berks'),('berme'),('berms'),('berob'),
('berry'),('berth'),('beryl'),('besat'),('besaw'),('besee'),('beses'),('beset'),('besit'),('besom'),('besot'),('besti'),
('bests'),('betas'),('beted'),('betel'),('betes'),('beths'),('betid'),('beton'),('betta'),('betty'),('bevel'),('bever'),
('bevor'),('bevue'),('bevvy'),('bewet'),('bewig'),('bezel'),('bezes'),('bezil'),('bhais'),('bhaji'),('bhang'),('bhels'),
('bhoot'),('bhuna'),('bhuts'),('biach'),('biali'),('bialy'),('bibbs'),('bible'),('biccy'),('bicep'),('bices'),('biddy'),
('bided'),('bider'),('bides'),('bidet'),('bidis'),('bidon'),('bield'),('biers'),('biffo'),('biffs'),('biffy'),('bifid'),
('bigae'),('biggs'),('biggy'),('bigha'),('bight'),('bigly'),('bigos'),('bigot'),('bijou'),('biked'),('biker'),('bikes'),
('bikie'),('bilbo'),('bilby'),('biled'),('biles'),('bilge'),('bilgy'),('bilks'),('bills'),('billy'),('bimah'),('bimas'),
('bimbo'),('binal'),('bindi'),('binds'),('biner'),('bines'),('binge'),('bingo'),('bings'),('bingy'),('binit'),('binks'),
('bints'),('biogs'),('biome'),('biont'),('biota'),('biped'),('bipod'),('birch'),('birds'),('birks'),('birle'),('birls'),
('biros'),('birrs'),('birse'),('birsy'),('birth'),('bises'),('bisks'),('bisom'),('bison'),('biter'),('bites'),('bitos'),
('bitou'),('bitsy'),('bitte'),('bitts'),('bitty'),('bivia'),('bivvy'),('bizes'),('bizzo'),('bizzy'),('blabs'),('black'),
('blade'),('blads'),('blady'),('blaer'),('blaes'),('blaff'),('blags'),('blahs'),('blain'),('blame'),('blams'),('bland'),
('blank'),('blare'),('blart'),('blase'),('blash'),('blast'),('blate'),('blats'),('blatt'),('blaud'),('blawn'),('blaws'),
('blays'),('blaze'),('bleak'),('blear'),('bleat'),('blebs'),('bleed'),('bleep'),('blees'),('blend'),('blent'),('blert'),
('bless'),('blest'),('blets'),('bleys'),('blimp'),('blimy'),('blind'),('bling'),('blini'),('blink'),('blins'),('bliny'),
('blips'),('bliss'),('blist'),('blite'),('blits'),('blitz'),('blive'),('bloat'),('blobs'),('block'),('blocs'),('blogs'),
('bloke'),('blond'),('blood'),('blook'),('bloom'),('bloop'),('blore'),('blots'),('blown'),('blows'),('blowy'),('blubs'),
('blude'),('bludy'),('blued'),('bluer'),('blues'),('bluet'),('bluey'),('bluff'),('bluid'),('blume'),('blunk'),('blunt'),
('blurb'),('blurs'),('blurt'),('blush'),('blype'),('boabs'),('boaks'),('board'),('boars'),('boart'),('boast'),('boats'),
('bobac'),('bobak'),('bobas'),('bobby'),('bobol'),('bocca'),('bocce'),('bocci'),('boche'),('bocks'),('boded'),('bodes'),
('bodge'),('bodhi'),('bodle'),('boeps'),('boets'),('boeuf'),('boffo'),('boffs'),('bogan'),('bogey'),('boggy'),('bogie'),
('bogle'),('bogus'),('bohea'),('bohos'),('boils'),('boing'),('boink'),('boite'),('boked'),('bokeh'),('bokes'),('bokos'),
('bolar'),('bolas'),('bolds'),('boles'),('bolix'),('bolls'),('bolos'),('bolts'),('bolus'),('bomas'),('bombe'),('bombo'),
('bombs'),('bonce'),('bonds'),('boned'),('bones'),('boney'),('bongo'),('bongs'),('bonie'),('bonks'),('bonne'),('bonny'),
('bonus'),('bonza'),('bonze'),('booai'),('booay'),('booby'),('boody'),('booed'),('boofy'),('boogy'),('boohs'),('books'),
('booky'),('bools'),('booms'),('boomy'),('boong'),('boons'),('boord'),('boors'),('boose'),('boost'),('booth'),('boots'),
('booty'),('booze'),('boozy'),('borak'),('boral'),('boras'),('borax'),('borde'),('bords'),('bored'),('boree'),('borel'),
('borer'),('bores'),('borgo'),('boric'),('borks'),('borms'),('borna'),('borne'),('boron'),('borts'),('borty'),('bortz'),
('bosie'),('bosks'),('bosky'),('bosom'),('boson'),('bossy'),('bosun'),('botas'),('botch'),('botel'),('botes'),('bothy'),
('botte'),('botts'),('botty'),('bouge'),('bough'),('bouks'),('boule'),('boult'),('bound'),('bouns'),('bourd'),('bourg'),
('bourn'),('bouse'),('bousy'),('bouts'),('bovid'),('bowat'),('bowed'),('bowel'),('bower'),('bowes'),('bowet'),('bowie'),
('bowls'),('bowne'),('bowrs'),('bowse'),('boxed'),('boxen'),('boxer'),('boxes'),('boxty'),('boyar'),('boyau'),('boyed'),
('boyfs'),('boygs'),('boyla'),('boyos'),('boysy'),('bozos'),('braai'),('brace'),('brach'),('brack'),('bract'),('brads'),
('braes'),('brags'),('braid'),('brail'),('brain'),('brake'),('braks'),('braky'),('brame'),('brand'),('brane'),('brank'),
('brans'),('brant'),('brash'),('brass'),('brast'),('brats'),('brava'),('brave'),('bravi'),('bravo'),('brawl'),('brawn'),
('braws'),('braxy'),('brays'),('braza'),('braze'),('bread'),('break'),('bream'),('brede'),('breds'),('breed'),('breem'),
('breer'),('brees'),('breid'),('breis'),('breme'),('brens'),('brent'),('brere'),('brers'),('breve'),('brews'),('breys'),
('briar'),('bribe'),('brick'),('bride'),('brief'),('brier'),('bries'),('brigs'),('briki'),('briks'),('brill'),('brims'),
('brine'),('bring'),('brink'),('brins'),('briny'),('brios'),('brise'),('brisk'),('briss'),('brith'),('brits'),('britt'),
('brize'),('broad'),('broch'),('brock'),('brods'),('brogh'),('brogs'),('broil'),('broke'),('brome'),('bromo'),('bronc'),
('brond'),('brood'),('brook'),('brool'),('broom'),('broos'),('brose'),('brosy'),('broth'),('brown'),('brows'),('brugh'),
('bruin'),('bruit'),('brule'),('brume'),('brung'),('brunt'),('brush'),('brusk'),('brust'),('brute'),('bruts'),('buats'),
('buaze'),('bubal'),('bubas'),('bubba'),('bubby'),('bubus'),('buchu'),('bucko'),('bucks'),('bucku'),('budas'),('buddy'),
('budge'),('budis'),('budos'),('buffa'),('buffe'),('buffi'),('buffo'),('buffs'),('buffy'),('bufos'),('bufty'),('buggy'),
('bugle'),('buhls'),('buhrs'),('buiks'),('build'),('built'),('buist'),('bukes'),('bulbs'),('bulge'),('bulgy'),('bulks'),
('bulky'),('bulla'),('bulls'),('bully'),('bulse'),('bumbo'),('bumfs'),('bumph'),('bumps'),('bumpy'),('bunas'),('bunce'),
('bunch'),('bunco'),('bunde'),('bundh'),('bunds'),('bundt'),('bundu'),('bundy'),('bungs'),('bungy'),('bunia'),('bunje'),
('bunjy'),('bunko'),('bunks'),('bunns'),('bunny'),('bunts'),('bunty'),('bunya'),('buoys'),('buppy'),('buran'),('buras'),
('burbs'),('burds'),('buret'),('burgh'),('burgs'),('burin'),('burka'),('burke'),('burks'),('burls'),('burly'),('burns'),
('burnt'),('buroo'),('burps'),('burqa'),('burro'),('burrs'),('burry'),('bursa'),('burse'),('burst'),('busby'),('bused'),
('buses'),('bushy'),('busks'),('busky'),('bussu'),('busti'),('busts'),('butch'),('buteo'),('butes'),('butle'),('butte'),
('butts'),('butty'),('butut'),('butyl'),('buxom'),('buyer'),('buzzy'),('bwana'),('bwazi'),('byded'),('bydes'),('byked'),
('bykes'),('bylaw'),('byres'),('byrls'),('byssi'),('bytes'),('byway'),('caaed'),('cabal'),('cabas'),('cabby'),('caber'),
('cabin'),('cable'),('cabob'),('caboc'),('cabre'),('cacao'),('cacas'),('cache'),('cacks'),('cacky'),('cacti'),('caddy'),
('cadee'),('cades'),('cadet'),('cadge'),('cadgy'),('cadie'),('cadis'),('cadre'),('caeca'),('caese'),('cafes'),('caffs'),
('caged'),('cager'),('cages'),('cagey'),('cagot'),('cahow'),('caids'),('cains'),('caird'),('cairn'),('cajon'),('cajun'),
('caked'),('cakes'),('cakey'),('calfs'),('calid'),('calif'),('calix'),('calks'),('calla'),('calls'),('calms'),('calmy'),
('calos'),('calpa'),('calps'),('calve'),('calyx'),('caman'),('camas'),('camel'),('cameo'),('cames'),('camis'),('camos'),
('campi'),('campo'),('camps'),('campy'),('camus'),('canal'),('candy'),('caned'),('caneh'),('caner'),('canes'),('cangs'),
('canid'),('canna'),('canns'),('canny'),('canoe'),('canon'),('canso'),('canst'),('canto'),('cants'),('canty'),('capas'),
('caped'),('caper'),('capes'),('capex'),('caphs'),('capiz'),('caple'),('capon'),('capos'),('capot'),('capul'),('caput'),
('carap'),('carat'),('carbo'),('carbs'),('carby'),('cardi'),('cards'),('cardy'),('cared'),('carer'),('cares'),('caret'),
('carex'),('cargo'),('carks'),('carle'),('carls'),('carns'),('carny'),('carob'),('carol'),('carom'),('caron'),('carpi'),
('carps'),('carrs'),('carry'),('carse'),('carta'),('carte'),('carts'),('carve'),('carvy'),('casas'),('casco'),('cased'),
('cases'),('casks'),('casky'),('caste'),('casts'),('casus'),('catch'),('cater'),('cates'),('catty'),('cauda'),('cauks'),
('cauld'),('caulk'),('cauls'),('caums'),('caups'),('causa'),('cause'),('cavas'),('caved'),('cavel'),('caver'),('caves'),
('cavie'),('cavil'),('cawed'),('cawks'),('caxon'),('cease'),('ceaze'),('cebid'),('cecal'),('cecum'),('cedar'),('ceded'),
('ceder'),('cedes'),('cedis'),('ceiba'),('ceili'),('ceils'),('celeb'),('cella'),('celli'),('cello'),('cells'),('celom'),
('celts'),('cense'),('cento'),('cents'),('centu'),('ceorl'),('cepes'),('cerci'),('cered'),('ceres'),('cerge'),('ceria'),
('ceric'),('cerne'),('ceros'),('certs'),('certy'),('cesse'),('cesta'),('cesti'),('cetes'),('cetyl'),('cezve'),('chace'),
('chack'),('chaco'),('chado'),('chads'),('chafe'),('chaff'),('chaft'),('chain'),('chair'),('chais'),('chalk'),('chals'),
('champ'),('chams'),('chana'),('chang'),('chank'),('chant'),('chaos'),('chape'),('chaps'),('chapt'),('chara'),('chard'),
('chare'),('chark'),('charm'),('charr'),('chars'),('chart'),('chary'),('chase'),('chasm'),('chats'),('chave'),('chavs'),
('chawk'),('chaws'),('chaya'),('chays'),('cheap'),('cheat'),('check'),('cheek'),('cheep'),('cheer'),('chefs'),('cheka'),
('chela'),('chelp'),('chemo'),('chere'),('chert'),('chess'),('chest'),('cheth'),('chevy'),('chews'),('chewy'),('chiao'),
('chias'),('chibs'),('chica'),('chich'),('chick'),('chico'),('chics'),('chide'),('chief'),('chiel'),('chiks'),('child'),
('chile'),('chili'),('chill'),('chimb'),('chime'),('chimo'),('chimp'),('china'),('chine'),('chino'),('chins'),('chips'),
('chirk'),('chirl'),('chirm'),('chiro'),('chirp'),('chirr'),('chirt'),('chiru'),('chits'),('chive'),('chivs'),('chivy'),
('chizz'),('chock'),('choco'),('chocs'),('chode'),('chogs'),('choir'),('choke'),('choko'),('choky'),('chola'),('choli'),
('cholo'),('chomp'),('choof'),('chook'),('choom'),('choon'),('chops'),('chord'),('chore'),('chose'),('chota'),('chott'),
('chout'),('choux'),('chowk'),('chows'),('chubs'),('chuck'),('chufa'),('chuff'),('chugs'),('chump'),('chums'),('chunk'),
('churl'),('churn'),('churr'),('chuse'),('chute'),('chyle'),('chyme'),('chynd'),('cibol'),('cided'),('cider'),('cides'),
('ciels'),('cigar'),('ciggy'),('cilia'),('cills'),('cimar'),('cimex'),('cinch'),('cinct'),('cines'),('cions'),('cippi'),
('circa'),('circs'),('cires'),('cirls'),('cirri'),('cisco'),('cissy'),('cists'),('cital'),('cited'),('citer'),('cites'),
('cives'),('civet'),('civic'),('civie'),('civil'),('civvy'),('clach'),('clack'),('clade'),('clads'),('claes'),('clags'),
('claim'),('clame'),('clamp'),('clams'),('clang'),('clank'),('clans'),('claps'),('clapt'),('claro'),('clart'),('clary'),
('clash'),('clasp'),('class'),('clast'),('clats'),('claut'),('clave'),('clavi'),('claws'),('clays'),('clean'),('clear'),
('cleat'),('cleck'),('cleek'),('cleep'),('clefs'),('cleft'),('clegs'),('cleik'),('clems'),('clepe'),('clept'),('clerk'),
('cleve'),('clews'),('click'),('clied'),('clies'),('cliff'),('clift'),('climb'),('clime'),('cline'),('cling'),('clink'),
('clint'),('clipe'),('clips'),('clipt'),('cloak'),('cloam'),('clock'),('clods'),('cloff'),('clogs'),('cloke'),('clomb'),
('clomp'),('clone'),('clonk'),('clons'),('cloop'),('cloot'),('clops'),('close'),('clote'),('cloth'),('clots'),('cloud'),
('clour'),('clous'),('clout'),('clove'),('clown'),('clows'),('cloye'),('cloys'),('cloze'),('clubs'),('cluck'),('clued'),
('clues'),('clump'),('clung'),('clunk'),('clype'),('cnida'),('coach'),('coact'),('coala'),('coals'),('coaly'),('coapt'),
('coarb'),('coast'),('coate'),('coati'),('coats'),('cobbs'),('cobby'),('cobia'),('coble'),('cobra'),('cobza'),('cocas'),
('cocci'),('cocco'),('cocky'),('cocoa'),('cocos'),('codas'),('codec'),('coded'),('coden'),('coder'),('codes'),('codex'),
('codon'),('coeds'),('coffs'),('cogie'),('cogon'),('cogue'),('cohab'),('cohen'),('cohoe'),('cohog'),('cohos'),('coifs'),
('coign'),('coils'),('coins'),('coirs'),('coits'),('coked'),('cokes'),('colas'),('colby'),('colds'),('coled'),('coles'),
('coley'),('colic'),('colin'),('colls'),('colly'),('colog'),('colon'),('color'),('colts'),('colza'),('comae'),('comal'),
('comas'),('combe'),('combi'),('combo'),('combs'),('comby'),('comer'),('comes'),('comet'),('comfy'),('comic'),('comix'),
('comma'),('commo'),('comms'),('commy'),('compo'),('comps'),('compt'),('comte'),('comus'),('conch'),('condo'),('coned'),
('cones'),('coney'),('confs'),('conga'),('conge'),('congo'),('conia'),('conic'),('conin'),('conks'),('conky'),('conne'),
('conns'),('conte'),('conto'),('conus'),('convo'),('cooch'),('cooed'),('cooee'),('cooer'),('cooey'),('coofs'),('cooks'),
('cooky'),('cools'),('cooly'),('coomb'),('cooms'),('coomy'),('coops'),('coopt'),('coost'),('coots'),('cooze'),('copal'),
('copay'),('coped'),('copen'),('coper'),('copes'),('coppy'),('copra'),('copse'),('copsy'),('coral'),('coram'),('corbe'),
('corby'),('cords'),('cored'),('corer'),('cores'),('corey'),('corgi'),('coria'),('corks'),('corky'),('corms'),('corni'),
('corno'),('corns'),('cornu'),('corny'),('corps'),('corse'),('corso'),('cosec'),('cosed'),('coses'),('coset'),('cosey'),
('cosie'),('costa'),('coste'),('costs'),('cotan'),('coted'),('cotes'),('coths'),('cotta'),('cotts'),('couch'),('coude'),
('cough'),('could'),('count'),('coupe'),('coups'),('courb'),('courd'),('coure'),('cours'),('court'),('couta'),('couth'),
('coved'),('coven'),('cover'),('coves'),('covet'),('covey'),('covin'),('cowal'),('cowan'),('cowed'),('cower'),('cowks'),
('cowls'),('cowps'),('cowry'),('coxae'),('coxal'),('coxed'),('coxes'),('coxib'),('coyed'),('coyer'),('coyly'),('coypu'),
('cozed'),('cozen'),('cozes'),('cozey'),('cozie'),('craal'),('crabs'),('crack'),('craft'),('crags'),('craic'),('craig'),
('crake'),('crame'),('cramp'),('crams'),('crane'),('crank'),('crans'),('crape'),('craps'),('crapy'),('crare'),('crash'),
('crass'),('crate'),('crave'),('crawl'),('craws'),('crays'),('craze'),('crazy'),('creak'),('cream'),('credo'),('creds'),
('creed'),('creek'),('creel'),('creep'),('crees'),('creme'),('crems'),('crena'),('crepe'),('creps'),('crept'),('crepy'),
('cress'),('crest'),('crewe'),('crews'),('crias'),('cribs'),('crick'),('cried'),('crier'),('cries'),('crime'),('crimp'),
('crims'),('crine'),('crios'),('cripe'),('crise'),('crisp'),('crith'),('crits'),('croak'),('croci'),('crock'),('crocs'),
('croft'),('crogs'),('cromb'),('crome'),('crone'),('cronk'),('crony'),('crook'),('crool'),('croon'),('crops'),('crore'),
('cross'),('crost'),('croup'),('crout'),('crowd'),('crown'),('crows'),('croze'),('cruck'),('crude'),('cruds'),('crudy'),
('cruel'),('crues'),('cruet'),('cruft'),('crumb'),('crump'),('crunk'),('cruor'),('crura'),('cruse'),('crush'),('crust'),
('crusy'),('cruve'),('crwth'),('crypt'),('ctene'),('cubby'),('cubeb'),('cubed'),('cuber'),('cubes'),('cubic'),('cubit'),
('cuddy'),('cuffo'),('cuffs'),('cuifs'),('cuing'),('cuish'),('cuits'),('cukes'),('culch'),('culet'),('culex'),('culls'),
('cully'),('culms'),('culpa'),('culti'),('cults'),('culty'),('cumec'),('cumin'),('cundy'),('cunei'),('cupel'),('cupid'),
('cuppa'),('cuppy'),('curat'),('curbs'),('curch'),('curds'),('curdy'),('cured'),('curer'),('cures'),('curet'),('curfs'),
('curia'),('curie'),('curio'),('curli'),('curls'),('curly'),('curns'),('curny'),('currs'),('curry'),('curse'),('cursi'),
('curst'),('curve'),('curvy'),('cusec'),('cushy'),('cusks'),('cusps'),('cuspy'),('cusso'),('cusum'),('cutch'),('cuter'),
('cutes'),('cutey'),('cutie'),('cutin'),('cutis'),('cutto'),('cutty'),('cutup'),('cuvee'),('cwtch'),('cyano'),('cyans'),
('cyber'),('cycad'),('cycas'),('cycle'),('cyclo'),('cyder'),('cylix'),('cymae'),('cymar'),('cymas'),('cymes'),('cymol'),
('cynic'),('cysts'),('cytes'),('cyton'),('czars'),('daals'),('dabba'),('daces'),('dacha'),('dacks'),('dadah'),('dadas'),
('daddy'),('dados'),('daffs'),('daffy'),('dagga'),('daggy'),('dagos'),('dahls'),('daiko'),('daily'),('daine'),('daint'),
('dairy'),('daisy'),('daker'),('daled'),('dales'),('dalis'),('dalle'),('dally'),('dalts'),('daman'),('damar'),('dames'),
('damme'),('damns'),('damps'),('dampy'),('dance'),('dancy'),('dandy'),('dangs'),('danio'),('danks'),('danny'),('dants'),
('daraf'),('darbs'),('darcy'),('dared'),('darer'),('dares'),('darga'),('dargs'),('daric'),('daris'),('darks'),('darky'),
('darns'),('darre'),('darts'),('darzi'),('dashi'),('dashy'),('datal'),('dated'),('dater'),('dates'),('datos'),('datto'),
('datum'),('daube'),('daubs'),('dauby'),('dauds'),('dault'),('daunt'),('daurs'),('dauts'),('daven'),('davit'),('dawah'),
('dawds'),('dawed'),('dawen'),('dawks'),('dawns'),('dawts'),('dayan'),('daych'),('daynt'),('dazed'),('dazer'),('dazes'),
('deads'),('deair'),('deals'),('dealt'),('deans'),('deare'),('dearn'),('dears'),('deary'),('deash'),('death'),('deave'),
('deaws'),('deawy'),('debag'),('debar'),('debby'),('debel'),('debes'),('debit'),('debts'),('debud'),('debug'),('debur'),
('debus'),('debut'),('debye'),('decad'),('decaf'),('decal'),('decay'),('decko'),('decks'),('decor'),('decos'),('decoy'),
('decry'),('dedal'),('deeds'),('deedy'),('deely'),('deems'),('deens'),('deeps'),('deere'),('deers'),('deets'),('deeve'),
('deevs'),('defat'),('defer'),('deffo'),('defis'),('defog'),('degas'),('degum'),('degus'),('deice'),('deids'),('deify'),
('deign'),('deils'),('deism'),('deist'),('deity'),('deked'),('dekes'),('dekko'),('delay'),('deled'),('deles'),('delfs'),
('delft'),('delis'),('dells'),('delly'),('delos'),('delph'),('delta'),('delts'),('delve'),('deman'),('demes'),('demic'),
('demit'),('demob'),('demon'),('demos'),('dempt'),('demur'),('denar'),('denay'),('denes'),('denet'),('denim'),('denis'),
('dense'),('dents'),('deoxy'),('depot'),('depth'),('derat'),('deray'),('derby'),('dered'),('deres'),('derig'),('derma'),
('derms'),('derns'),('deros'),('derro'),('derry'),('derth'),('dervs'),('desex'),('deshi'),('desks'),('desse'),('deter'),
('detox'),('deuce'),('devas'),('devel'),('devil'),('devon'),('devot'),('dewan'),('dewar'),('dewax'),('dewed'),('dexes'),
('dexie'),('dhaks'),('dhals'),('dhobi'),('dhole'),('dholl'),('dhols'),('dhoti'),('dhows'),('dhuti'),('diact'),('dials'),
('diane'),('diary'),('diazo'),('dibbs'),('diced'),('dicer'),('dices'),('dicey'),('dicht'),('dicky'),('dicot'),('dicta'),
('dicts'),('dicty'),('diddy'),('didie'),('didos'),('didst'),('diebs'),('diene'),('diets'),('diffs'),('dight'),('digit'),
('dikas'),('diked'),('diker'),('dikes'),('dikey'),('dilli'),('dills'),('dilly'),('dimer'),('dimes'),('dimly'),('dimps'),
('dinar'),('dined'),('diner'),('dines'),('dinge'),('dingo'),('dings'),('dingy'),('dinic'),('dinky'),('dinna'),('dinos'),
('dints'),('diode'),('diols'),('diota'),('dippy'),('dipso'),('diram'),('direr'),('dirge'),('dirke'),('dirks'),('dirls'),
('dirts'),('dirty'),('disas'),('disci'),('disco'),('discs'),('dishy'),('disks'),('disme'),('dital'),('ditas'),('ditch'),
('dited'),('dites'),('ditsy'),('ditto'),('ditts'),('ditty'),('ditzy'),('divan'),('divas'),('dived'),('diver'),('dives'),
('divis'),('divna'),('divos'),('divot'),('divvy'),('diwan'),('dixie'),('dixit'),('diyas'),('dizen'),('dizzy'),('djinn'),
('djins'),('doabs'),('doats'),('dobby'),('dobie'),('dobla'),('dobra'),('dobro'),('docht'),('docks'),('docos'),('doddy'),
('dodge'),('dodgy'),('dodos'),('doeks'),('doers'),('doest'),('doeth'),('doffs'),('doges'),('dogey'),('doggo'),('doggy'),
('dogie'),('dogma'),('dohyo'),('doilt'),('doily'),('doing'),('doits'),('dojos'),('dolce'),('dolci'),('doled'),('doles'),
('dolia'),('dolls'),('dolly'),('dolma'),('dolor'),('dolos'),('dolts'),('domal'),('domed'),('domes'),('domic'),('donah'),
('donas'),('donee'),('doner'),('donga'),('dongs'),('donko'),('donna'),('donne'),('donny'),('donor'),('donsy'),('donut'),
('doobs'),('dooce'),('doody'),('dooks'),('doole'),('dools'),('dooly'),('dooms'),('doomy'),('doona'),('doorn'),('doors'),
('doozy'),('dopas'),('doped'),('doper'),('dopes'),('dopey'),('dorad'),('dorba'),('dorbs'),('doree'),('dores'),('doric'),
('doris'),('dorks'),('dorky'),('dorms'),('dormy'),('dorps'),('dorrs'),('dorsa'),('dorse'),('dorts'),('dorty'),('dosed'),
('doseh'),('doser'),('doses'),('dotal'),('doted'),('doter'),('dotes'),('dotty'),('douar'),('doubt'),('douce'),('doucs'),
('dough'),('douks'),('doula'),('douma'),('doums'),('doups'),('doura'),('douse'),('douts'),('doved'),('doven'),('dover'),
('doves'),('dovie'),('dowar'),('dowds'),('dowdy'),('dowed'),('dowel'),('dower'),('dowie'),('dowle'),('dowls'),('dowly'),
('downa'),('downs'),('downy'),('dowps'),('dowry'),('dowse'),('dowts'),('doxie'),('doyen'),('doyly'),('dozed'),('dozen'),
('dozer'),('dozes'),('drabs'),('drack'),('draco'),('draff'),('draft'),('drags'),('drail'),('drain'),('drake'),('drama'),
('drams'),('drank'),('drant'),('drape'),('draps'),('drats'),('drave'),('drawl'),('drawn'),('draws'),('drays'),('dread'),
('dream'),('drear'),('dreck'),('dreed'),('drees'),('dregs'),('dreks'),('drent'),('drere'),('dress'),('drest'),('dreys'),
('dribs'),('drice'),('dried'),('drier'),('dries'),('drift'),('drill'),('drily'),('drink'),('drips'),('dript'),('drive'),
('droid'),('droil'),('droit'),('drole'),('droll'),('drome'),('drone'),('drony'),('droob'),('droog'),('drook'),('drool'),
('droop'),('drops'),('dropt'),('dross'),('drouk'),('drove'),('drown'),('drows'),('drubs'),('drugs'),('druid'),('drums'),
('drunk'),('drupe'),('druse'),('drusy'),('druxy'),('dryad'),('dryer'),('dryly'),('dsobo'),('dsomo'),('duads'),('duals'),
('duans'),('duars'),('dubbo'),('ducal'),('ducat'),('duces'),('duchy'),('ducks'),('ducky'),('ducts'),('duddy'),('duded'),
('dudes'),('duels'),('duets'),('duett'),('duffs'),('dufus'),('duing'),('duits'),('dukas'),('duked'),('dukes'),('dukka'),
('dules'),('dulia'),('dulls'),('dully'),('dulse'),('dumas'),('dumbo'),('dumbs'),('dumka'),('dumky'),('dummy'),('dumps'),
('dumpy'),('dunam'),('dunce'),('dunch'),('dunes'),('dungs'),('dungy'),('dunks'),('dunno'),('dunny'),('dunsh'),('dunts'),
('duomi'),('duomo'),('duped'),('duper'),('dupes'),('duple'),('duply'),('duppy'),('dural'),('duras'),('dured'),('dures'),
('durgy'),('durns'),('duroc'),('duros'),('duroy'),('durra'),('durrs'),('durry'),('durst'),('durum'),('durzi'),('dusks'),
('dusky'),('dusts'),('dusty'),('dutch'),('duvet'),('duxes'),('dwaal'),('dwale'),('dwalm'),('dwams'),('dwang'),('dwarf'),
('dwaum'),('dweeb'),('dwell'),('dwelt'),('dwile'),('dwine'),('dyads'),('dyers'),('dying'),('dykon'),('dynel'),('dynes'),
('dzhos'),('eager'),('eagle'),('eagre'),('eales'),('eaned'),('eards'),('eared'),('earls'),('early'),('earns'),('earst'),
('earth'),('eased'),('easel'),('easer'),('eases'),('easle'),('easts'),('eaten'),('eater'),('eathe'),('eaved'),('eaves'),
('ebbed'),('ebbet'),('ebons'),('ebony'),('ebook'),('ecads'),('eched'),('eches'),('echos'),('eclat'),('ecrus'),('edema'),
('edged'),('edger'),('edges'),('edict'),('edify'),('edile'),('edits'),('educe'),('educt'),('eejit'),('eerie'),('eeven'),
('eevns'),('effed'),('egads'),('egers'),('egest'),('eggar'),('egged'),('egger'),('egmas'),('egret'),('ehing'),('eider'),
('eidos'),('eight'),('eigne'),('eiked'),('eikon'),('eilds'),('eisel'),('eject'),('eking'),('ekkas'),('elain'),('eland'),
('elans'),('elate'),('elbow'),('elchi'),('elder'),('eldin'),('elect'),('elegy'),('elemi'),('elfed'),('elfin'),('eliad'),
('elide'),('elint'),('elite'),('elmen'),('eloge'),('elogy'),('eloin'),('elope'),('elops'),('elpee'),('elsin'),('elude'),
('elute'),('elvan'),('elver'),('elves'),('emacs'),('email'),('embar'),('embay'),('embed'),('ember'),('embog'),('embow'),
('embox'),('embus'),('emcee'),('emeer'),('emend'),('emery'),('emeus'),('emirs'),('emits'),('emmas'),('emmer'),('emmet'),
('emmew'),('emmys'),('emong'),('emote'),('emove'),('empts'),('empty'),('emule'),('emure'),('emyde'),('emyds'),('enact'),
('enarm'),('enate'),('ended'),('ender'),('endew'),('endow'),('endue'),('enema'),('enemy'),('enews'),('enfix'),('eniac'),
('enjoy'),('enlit'),('enmew'),('ennog'),('ennui'),('enoki'),('enols'),('enorm'),('enows'),('enrol'),('ensew'),('ensky'),
('ensue'),('enter'),('entia'),('entry'),('enure'),('enurn'),('envoi'),('envoy'),('enzym'),('eorls'),('eosin'),('epact'),
('epees'),('ephah'),('ephas'),('ephod'),('ephor'),('epics'),('epoch'),('epode'),('epopt'),('epoxy'),('epris'),('equal'),
('equid'),('equip'),('erase'),('erbia'),('erect'),('erevs'),('ergon'),('ergos'),('ergot'),('erhus'),('erica'),('erick'),
('erics'),('ering'),('erned'),('ernes'),('erode'),('erose'),('erred'),('error'),('erses'),('eruct'),('erugo'),('erupt'),
('eruvs'),('erven'),('ervil'),('escar'),('escot'),('esile'),('eskar'),('esker'),('esnes'),('essay'),('esses'),('ester'),
('estoc'),('estop'),('estro'),('etage'),('etape'),('etats'),('etens'),('ethal'),('ether'),('ethic'),('ethos'),('ethyl'),
('etnas'),('ettin'),('ettle'),('etude'),('etuis'),('etwee'),('etyma'),('eughs'),('euked'),('eupad'),('euros'),('eusol'),
('evade'),('evens'),('event'),('evert'),('every'),('evets'),('evhoe'),('evict'),('evils'),('evite'),('evohe'),('evoke'),
('ewers'),('ewest'),('ewhow'),('ewked'),('exact'),('exalt'),('exams'),('excel'),('exeat'),('execs'),('exeem'),('exeme'),
('exert'),('exies'),('exile'),('exine'),('exing'),('exist'),('exits'),('exode'),('exons'),('expat'),('expel'),('expos'),
('extol'),('extra'),('exude'),('exuls'),('exult'),('exurb'),('eyass'),('eyers'),('eying'),('eyots'),('eyras'),('eyres'),
('eyrie'),('eyrir'),('fabby'),('fable'),('faced'),('facer'),('faces'),('facet'),('facia'),('facts'),('faddy'),('faded'),
('fader'),('fades'),('fadge'),('fados'),('faena'),('faery'),('faffs'),('faggy'),('fagin'),('faiks'),('fails'),('faine'),
('fains'),('faint'),('fairs'),('fairy'),('faith'),('faked'),('faker'),('fakes'),('fakey'),('fakie'),('fakir'),('falaj'),
('falls'),('false'),('famed'),('fames'),('fanal'),('fancy'),('fands'),('fanes'),('fanga'),('fango'),('fangs'),('fanks'),
('fanon'),('fanos'),('fanum'),('faqir'),('farad'),('farce'),('farci'),('farcy'),('fards'),('fared'),('farer'),('fares'),
('farle'),('farls'),('farms'),('faros'),('farse'),('farts'),('fasci'),('fasti'),('fasts'),('fatal'),('fated'),('fates'),
('fatly'),('fatso'),('fatty'),('fatwa'),('faugh'),('fauld'),('fault'),('fauna'),('fauns'),('faurd'),('fauts'),('fauve'),
('favas'),('favel'),('faver'),('faves'),('favor'),('favus'),('fawns'),('fawny'),('faxed'),('faxes'),('fayed'),('fayer'),
('fayne'),('fayre'),('fazed'),('fazes'),('feals'),('feare'),('fears'),('feart'),('fease'),('feast'),('feats'),('feaze'),
('fecht'),('fecit'),('fecks'),('fedex'),('feebs'),('feeds'),('feels'),('feens'),('feers'),('feese'),('feeze'),('fehme'),
('feign'),('feint'),('feist'),('felid'),('fella'),('fells'),('felly'),('felon'),('felts'),('felty'),('femal'),('femes'),
('femme'),('femmy'),('femur'),('fence'),('fends'),('fendy'),('fenis'),('fenks'),('fenny'),('fents'),('feods'),('feoff'),
('feral'),('ferer'),('feres'),('feria'),('ferly'),('fermi'),('ferms'),('ferns'),('ferny'),('ferry'),('fesse'),('festa'),
('fests'),('festy'),('fetal'),('fetas'),('fetch'),('feted'),('fetes'),('fetid'),('fetor'),('fetta'),('fetts'),('fetus'),
('fetwa'),('feuar'),('feuds'),('feued'),('fever'),('fewer'),('feyed'),('feyer'),('feyly'),('fezes'),('fezzy'),('fiars'),
('fiats'),('fiber'),('fibre'),('fibro'),('fices'),('fiche'),('fichu'),('ficin'),('ficos'),('ficus'),('fides'),('fidge'),
('fidos'),('fiefs'),('field'),('fiend'),('fient'),('fiere'),('fiers'),('fiery'),('fiest'),('fifed'),('fifer'),('fifes'),
('fifth'),('fifty'),('fight'),('figos'),('fiked'),('fikes'),('filar'),('filch'),('filed'),('filer'),('files'),('filet'),
('filii'),('fille'),('fillo'),('fills'),('filly'),('filmi'),('films'),('filmy'),('filos'),('filth'),('filum'),('final'),
('finca'),('finch'),('finds'),('fined'),('finer'),('fines'),('finis'),('finks'),('finny'),('finos'),('fiord'),('fiqhs'),
('fique'),('fired'),('firer'),('fires'),('firie'),('firks'),('firms'),('firns'),('firry'),('first'),('firth'),('fiscs'),
('fishy'),('fisks'),('fists'),('fisty'),('fitch'),('fitly'),('fitna'),('fitte'),('fitts'),('fiver'),('fives'),('fixed'),
('fixer'),('fixes'),('fixit'),('fizzy'),('fjeld'),('fjord'),('flabs'),('flack'),('flaff'),('flags'),('flail'),('flair'),
('flake'),('flaks'),('flaky'),('flame'),('flamm'),('flams'),('flamy'),('flank'),('flans'),('flaps'),('flare'),('flary'),
('flash'),('flask'),('flats'),('flava'),('flawn'),('flaws'),('flawy'),('flaxy'),('flays'),('fleam'),('fleas'),('fleck'),
('fleer'),('flees'),('fleet'),('flegs'),('fleme'),('flesh'),('flews'),('flexo'),('fleys'),('flick'),('flics'),('flied'),
('flier'),('flies'),('flimp'),('flims'),('fling'),('flint'),('flips'),('flirs'),('flirt'),('flisk'),('flite'),('flits'),
('flitt'),('float'),('flobs'),('flock'),('flocs'),('floes'),('flogs'),('flong'),('flood'),('floor'),('flops'),('flora'),
('flors'),('flory'),('flosh'),('floss'),('flota'),('flote'),('flour'),('flout'),('flown'),('flows'),('flubs'),('flued'),
('flues'),('fluey'),('fluff'),('fluid'),('fluke'),('fluky'),('flume'),('flump'),('flung'),('flunk'),('fluor'),('flurr'),
('flush'),('flute'),('fluty'),('fluyt'),('flyby'),('flyer'),('flype'),('flyte'),('foals'),('foams'),('foamy'),('focal'),
('focus'),('foehn'),('fogey'),('foggy'),('fogie'),('fogle'),('fogou'),('fohns'),('foids'),('foils'),('foins'),('foist'),
('folds'),('foley'),('folia'),('folic'),('folie'),('folio'),('folks'),('folky'),('folly'),('fomes'),('fonda'),('fonds'),
('fondu'),('fonly'),('fonts'),('foods'),('foody'),('fools'),('foots'),('footy'),('foram'),('foray'),('forbs'),('forby'),
('force'),('fordo'),('fords'),('forel'),('fores'),('forex'),('forge'),('forgo'),('forks'),('forky'),('forme'),('forms'),
('forte'),('forth'),('forts'),('forty'),('forum'),('forza'),('forze'),('fossa'),('fosse'),('fouat'),('fouds'),('fouer'),
('fouet'),('foule'),('fouls'),('found'),('fount'),('fours'),('fouth'),('fovea'),('fowls'),('fowth'),('foxed'),('foxes'),
('foxie'),('foyer'),('foyle'),('foyne'),('frabs'),('frack'),('fract'),('frags'),('frail'),('fraim'),('frame'),('franc'),
('frank'),('frape'),('fraps'),('frass'),('frate'),('frati'),('frats'),('fraud'),('fraus'),('frays'),('freak'),('freed'),
('freer'),('frees'),('freet'),('freit'),('fremd'),('frena'),('frere'),('fresh'),('frets'),('friar'),('fribs'),('fried'),
('frier'),('fries'),('frigs'),('frill'),('frise'),('frisk'),('frist'),('frith'),('frits'),('fritt'),('fritz'),('frize'),
('frizz'),('frock'),('froes'),('frogs'),('frond'),('frons'),('front'),('frore'),('frorn'),('frory'),('frosh'),('frost'),
('froth'),('frown'),('frows'),('frowy'),('froze'),('frugs'),('fruit'),('frump'),('frush'),('frust'),('fryer'),('fubar'),
('fubby'),('fubsy'),('fucus'),('fuddy'),('fudge'),('fuels'),('fuero'),('fuffs'),('fuffy'),('fugal'),('fuggy'),('fugie'),
('fugio'),('fugle'),('fugly'),('fugue'),('fugus'),('fujis'),('fulls'),('fully'),('fumed'),('fumer'),('fumes'),('fumet'),
('fundi'),('funds'),('fundy'),('fungi'),('fungo'),('fungs'),('funks'),('funky'),('funny'),('fural'),('furan'),('furca'),
('furls'),('furol'),('furor'),('furrs'),('furry'),('furth'),('furze'),('furzy'),('fused'),('fusee'),('fusel'),('fuses'),
('fusil'),('fussy'),('fusts'),('fusty'),('futon'),('fuzed'),('fuzee'),('fuzes'),('fuzil'),('fuzzy'),('fyces'),('fyked'),
('fykes'),('fyles'),('fyrds'),('fytte'),('gabba'),('gabby'),('gable'),('gaddi'),('gades'),('gadge'),('gadid'),('gadis'),
('gadje'),('gadjo'),('gadso'),('gaffe'),('gaffs'),('gaged'),('gager'),('gages'),('gaids'),('gaily'),('gains'),('gairs'),
('gaita'),('gaits'),('gaitt'),('gajos'),('galah'),('galas'),('galax'),('galea'),('gales'),('galls'),('gally'),('galop'),
('galut'),('galvo'),('gamas'),('gamay'),('gamba'),('gambe'),('gambo'),('gambs'),('gamed'),('gamer'),('games'),('gamey'),
('gamic'),('gamin'),('gamma'),('gamme'),('gammy'),('gamps'),('gamut'),('ganch'),('gandy'),('ganef'),('ganev'),('gangs'),
('ganja'),('ganof'),('gants'),('gaols'),('gaped'),('gaper'),('gapes'),('gapos'),('gappy'),('garbe'),('garbo'),('garbs'),
('garda'),('garis'),('garni'),('garre'),('garth'),('garum'),('gases'),('gasps'),('gaspy'),('gassy'),('gasts'),('gated'),
('gater'),('gates'),('gaths'),('gator'),('gaucy'),('gauds'),('gaudy'),('gauge'),('gauje'),('gault'),('gaums'),('gaumy'),
('gaunt'),('gaups'),('gaurs'),('gauss'),('gauze'),('gauzy'),('gavel'),('gavot'),('gawcy'),('gawds'),('gawks'),('gawky'),
('gawps'),('gawsy'),('gayal'),('gayer'),('gayly'),('gazal'),('gazar'),('gazed'),('gazer'),('gazes'),('gazon'),('gazoo'),
('geals'),('geans'),('geare'),('gears'),('geats'),('gebur'),('gecko'),('gecks'),('geeks'),('geeky'),('geeps'),('geese'),
('geest'),('geist'),('geits'),('gelds'),('gelee'),('gelid'),('gelly'),('gelts'),('gemel'),('gemma'),('gemmy'),('gemot'),
('genal'),('genas'),('genes'),('genet'),('genic'),('genie'),('genii'),('genip'),('genny'),('genoa'),('genom'),('genre'),
('genro'),('gents'),('genty'),('genua'),('genus'),('geode'),('geoid'),('gerah'),('gerbe'),('geres'),('gerle'),('germs'),
('germy'),('gerne'),('gesse'),('gesso'),('geste'),('gests'),('getas'),('getup'),('geums'),('geyan'),('geyer'),('ghast'),
('ghats'),('ghaut'),('ghazi'),('ghees'),('ghest'),('ghost'),('ghoul'),('ghyll'),('giant'),('gibed'),('gibel'),('giber'),
('gibes'),('gibli'),('gibus'),('giddy'),('gifts'),('gigas'),('gighe'),('gigot'),('gigue'),('gilas'),('gilds'),('gilet'),
('gills'),('gilly'),('gilpy'),('gilts'),('gimel'),('gimme'),('gimps'),('gimpy'),('ginge'),('gings'),('ginks'),('ginny'),
('ginzo'),('gipon'),('gippo'),('gippy'),('gipsy'),('girds'),('girls'),('girly'),('girns'),('giron'),('giros'),('girrs'),
('girsh'),('girth'),('girts'),('gismo'),('gisms'),('gists'),('gites'),('giust'),('gived'),('given'),('giver'),('gives'),
('gizmo'),('glace'),('glade'),('glads'),('glady'),('glaik'),('glair'),('glams'),('gland'),('glans'),('glare'),('glary'),
('glass'),('glaum'),('glaur'),('glaze'),('glazy'),('gleam'),('glean'),('gleba'),('glebe'),('gleby'),('glede'),('gleds'),
('gleed'),('gleek'),('glees'),('gleet'),('gleis'),('glens'),('glent'),('gleys'),('glial'),('glias'),('glibs'),('glide'),
('gliff'),('glift'),('glike'),('glime'),('glims'),('glint'),('glisk'),('glits'),('glitz'),('gloam'),('gloat'),('globe'),
('globi'),('globs'),('globy'),('glode'),('glogg'),('gloms'),('gloom'),('gloop'),('glops'),('glory'),('gloss'),('glost'),
('glout'),('glove'),('glows'),('gloze'),('glued'),('gluer'),('glues'),('gluey'),('glugs'),('glume'),('glums'),('gluon'),
('glute'),('gluts'),('glyph'),('gnarl'),('gnarr'),('gnars'),('gnash'),('gnats'),('gnawn'),('gnaws'),('gnome'),('gnows'),
('goads'),('goafs'),('goals'),('goary'),('goats'),('goaty'),('goban'),('gobar'),('gobbi'),('gobbo'),('gobby'),('gobis'),
('gobos'),('godet'),('godly'),('godso'),('goels'),('goers'),('goest'),('goeth'),('goety'),('gofer'),('goffs'),('gogga'),
('gogos'),('goier'),('going'),('gojis'),('golds'),('goldy'),('golem'),('goles'),('golfs'),('golly'),('golpe'),('golps'),
('gombo'),('gomer'),('gompa'),('gonad'),('gonef'),('goner'),('gongs'),('gonia'),('gonif'),('gonks'),('gonna'),('gonof'),
('gonys'),('gonzo'),('gooby'),('goods'),('goody'),('gooey'),('goofs'),('goofy'),('googs'),('gooks'),('gooky'),('goold'),
('gools'),('gooly'),('goons'),('goony'),('goops'),('goopy'),('goors'),('goory'),('goose'),('goosy'),('gopak'),('gopik'),
('goral'),('goras'),('gored'),('gores'),('gorge'),('goris'),('gorms'),('gormy'),('gorps'),('gorse'),('gorsy'),('gosht'),
('gosse'),('goths'),('gotta'),('gouch'),('gouge'),('gouks'),('goura'),('gourd'),('gouts'),('gouty'),('gowan'),('gowds'),
('gowfs'),('gowks'),('gowls'),('gowns'),('goxes'),('goyim'),('goyle'),('graal'),('grabs'),('grace'),('grade'),('grads'),
('graff'),('graft'),('grail'),('grain'),('graip'),('grama'),('grame'),('gramp'),('grams'),('grana'),('grand'),('grans'),
('grant'),('grape'),('graph'),('grapy'),('grasp'),('grass'),('grate'),('grave'),('gravs'),('gravy'),('grays'),('graze'),
('great'),('grebe'),('grebo'),('grece'),('greed'),('greek'),('green'),('grees'),('greet'),('grege'),('grego'),('grein'),
('grens'),('grese'),('greve'),('grews'),('greys'),('grice'),('gride'),('grids'),('grief'),('griff'),('grift'),('grigs'),
('grike'),('grill'),('grime'),('grimy'),('grind'),('grins'),('griot'),('gripe'),('grips'),('gript'),('gripy'),('grise'),
('grist'),('grisy'),('grith'),('grits'),('grize'),('groan'),('groat'),('grody'),('grogs'),('groin'),('groks'),('groma'),
('grone'),('groof'),('groom'),('gross'),('grosz'),('grots'),('grouf'),('group'),('grout'),('grove'),('growl'),('grown'),
('grows'),('grrls'),('grrrl'),('grubs'),('grued'),('gruel'),('grues'),('grufe'),('gruff'),('grume'),('grump'),('grund'),
('grunt'),('gryce'),('gryde'),('gryke'),('grype'),('grypt'),('guaco'),('guana'),('guano'),('guans'),('guard'),('guars'),
('guava'),('gucks'),('gucky'),('gudes'),('guess'),('guest'),('guffs'),('gugas'),('guide'),('guids'),('guild'),('guile'),
('guilt'),('guimp'),('guiro'),('guise'),('gulag'),('gular'),('gulas'),('gulch'),('gules'),('gulet'),('gulfs'),('gulfy'),
('gulls'),('gully'),('gulph'),('gulps'),('gulpy'),('gumbo'),('gumma'),('gummy'),('gumps'),('gundy'),('gunge'),('gungy'),
('gunks'),('gunky'),('gunny'),('guppy'),('guqin'),('gurge'),('gurls'),('gurly'),('gurns'),('gurry'),('gursh'),('gurus'),
('gushy'),('gusla'),('gusle'),('gusli'),('gussy'),('gusto'),('gusts'),('gusty'),('gutsy'),('gutta'),('gutty'),('guyed'),
('guyle'),('guyot'),('guyse'),('gwine'),('gyals'),('gybed'),('gybes'),('gyeld'),('gymps'),('gynae'),('gynie'),('gynny'),
('gyoza'),('gyppo'),('gyppy'),('gypsy'),('gyral'),('gyred'),('gyres'),('gyron'),('gyros'),('gyrus'),('gytes'),('gyved'),
('gyves'),('haafs'),('haars'),('habit'),('hable'),('habus'),('hacek'),('hacks'),('hadal'),('haded'),('hades'),('hadji'),
('hadst'),('haems'),('haets'),('haffs'),('hafis'),('hafiz'),('hafts'),('haggs'),('hahas'),('haick'),('haika'),('haiks'),
('haiku'),('hails'),('haily'),('hains'),('haint'),('hairs'),('hairy'),('haith'),('hajes'),('hajis'),('hajji'),('hakam'),
('hakas'),('hakea'),('hakes'),('hakim'),('hakus'),('halal'),('haled'),('haler'),('hales'),('halfa'),('halfs'),('halid'),
('hallo'),('halls'),('halma'),('halms'),('halon'),('halos'),('halse'),('halts'),('halva'),('halve'),('hamal'),('hamba'),
('hamed'),('hames'),('hammy'),('hamza'),('hanap'),('hance'),('hanch'),('hands'),('handy'),('hangi'),('hangs'),('hanks'),
('hanky'),('hansa'),('hanse'),('hants'),('haole'),('haoma'),('hapax'),('haply'),('happy'),('hapus'),('haram'),('hards'),
('hardy'),('hared'),('harem'),('hares'),('harim'),('harks'),('harls'),('harms'),('harns'),('haros'),('harps'),('harpy'),
('harry'),('harsh'),('harts'),('hashy'),('hasks'),('hasps'),('hasta'),('haste'),('hasty'),('hatch'),('hated'),('hater'),
('hates'),('hatha'),('hauds'),('haufs'),('haugh'),('hauld'),('haulm'),('hauls'),('hault'),('haunt'),('hause'),('haute'),
('haven'),('haver'),('haves'),('havoc'),('hawed'),('hawks'),('hawms'),('hawse'),('hayed'),('hayer'),('hayey'),('hayle'),
('hazan'),('hazed'),('hazel'),('hazer'),('hazes'),('heads'),('heady'),('heald'),('heals'),('heame'),('heaps'),('heapy'),
('heard'),('heare'),('hears'),('heart'),('heast'),('heath'),('heats'),('heave'),('heavy'),('heben'),('hebes'),('hecht'),
('hecks'),('heder'),('hedge'),('hedgy'),('heeds'),('heedy'),('heels'),('heeze'),('hefte'),('hefts'),('hefty'),('heids'),
('heigh'),('heils'),('heirs'),('heist'),('hejab'),('hejra'),('heled'),('heles'),('helio'),('helix'),('hello'),('hells'),
('helms'),('helos'),('helot'),('helps'),('helve'),('hemal'),('hemes'),('hemic'),('hemin'),('hemps'),('hempy'),('hence'),
('hends'),('henge'),('henna'),('henny'),('henry'),('hents'),('hepar'),('herbs'),('herby'),('herds'),('heres'),('herls'),
('herma'),('herms'),('herns'),('heron'),('heros'),('herry'),('herse'),('hertz'),('herye'),('hesps'),('hests'),('hetes'),
('heths'),('heuch'),('heugh'),('hevea'),('hewed'),('hewer'),('hewgh'),('hexad'),('hexed'),('hexer'),('hexes'),('hexyl'),
('heyed'),('hiant'),('hicks'),('hided'),('hider'),('hides'),('hiems'),('highs'),('hight'),('hijab'),('hijra'),('hiked'),
('hiker'),('hikes'),('hikoi'),('hilar'),('hilch'),('hillo'),('hills'),('hilly'),('hilts'),('hilum'),('hilus'),('himbo'),
('hinau'),('hinds'),('hinge'),('hings'),('hinky'),('hinny'),('hints'),('hiois'),('hiply'),('hippo'),('hippy'),('hired'),
('hiree'),('hirer'),('hires'),('hissy'),('hists'),('hitch'),('hithe'),('hived'),('hiver'),('hives'),('hizen'),('hoaed'),
('hoagy'),('hoard'),('hoars'),('hoary'),('hoast'),('hobby'),('hobos'),('hocks'),('hocus'),('hodad'),('hodja'),('hoers'),
('hogan'),('hogen'),('hoggs'),('hoghs'),('hohed'),('hoick'),('hoiks'),('hoing'),('hoise'),('hoist'),('hokas'),('hoked'),
('hokes'),('hokey'),('hokis'),('hokku'),('hokum'),('holds'),('holed'),('holes'),('holey'),('holks'),('holla'),('hollo'),
('holly'),('holms'),('holon'),('holts'),('homas'),('homed'),('homer'),('homes'),('homey'),('homie'),('homme'),('homos'),
('honan'),('honda'),('honds'),('honed'),('honer'),('hones'),('honey'),('hongi'),('hongs'),('honks'),('honky'),('honor'),
('hooch'),('hoods'),('hoody'),('hooey'),('hoofs'),('hooka'),('hooks'),('hooky'),('hooly'),('hoons'),('hoops'),('hoord'),
('hoors'),('hoosh'),('hoots'),('hooty'),('hoove'),('hoped'),('hoper'),('hopes'),('hoppy'),('horah'),('horal'),('horas'),
('horde'),('horis'),('horme'),('horns'),('horse'),('horst'),('horsy'),('hosed'),('hosel'),('hosen'),('hoser'),('hoses'),
('hosey'),('hosta'),('hosts'),('hotch'),('hotel'),('hoten'),('hotly'),('hotty'),('houff'),('houfs'),('hough'),('hound'),
('houri'),('hours'),('house'),('houts'),('hovea'),('hoved'),('hovel'),('hoven'),('hover'),('hoves'),('howbe'),('howdy'),
('howes'),('howff'),('howfs'),('howks'),('howls'),('howre'),('howso'),('hoxed'),('hoxes'),('hoyas'),('hoyed'),('hoyle'),
('hubby'),('hucks'),('hudna'),('hudud'),('huers'),('huffs'),('huffy'),('huger'),('huggy'),('huhus'),('huias'),('hulas'),
('hules'),('hulks'),('hulky'),('hullo'),('hulls'),('hully'),('human'),('humas'),('humfs'),('humic'),('humid'),('humor'),
('humph'),('humps'),('humpy'),('humus'),('hunch'),('hunks'),('hunky'),('hunts'),('hurds'),('hurls'),('hurly'),('hurra'),
('hurry'),('hurst'),('hurts'),('hushy'),('husks'),('husky'),('husos'),('hussy'),('hutch'),('hutia'),('huzza'),('huzzy'),
('hwyls'),('hydra'),('hydro'),('hyena'),('hyens'),('hying'),('hykes'),('hylas'),('hyleg'),('hyles'),('hylic'),('hymen'),
('hymns'),('hynde'),('hyoid'),('hyped'),('hyper'),('hypes'),('hypha'),('hyphy'),('hypos'),('hyrax'),('hyson'),('hythe'),
('iambi'),('iambs'),('ibrik'),('icers'),('iched'),('iches'),('ichor'),('icier'),('icily'),('icing'),('icker'),('ickle'),
('icons'),('ictal'),('ictic'),('ictus'),('idant'),('ideal'),('ideas'),('idees'),('ident'),('idiom'),('idiot'),('idled'),
('idler'),('idles'),('idola'),('idols'),('idyll'),('idyls'),('iftar'),('igapo'),('igged'),('igloo'),('iglus'),('ihram'),
('ikans'),('ikats'),('ikons'),('ileac'),('ileal'),('ileum'),('ileus'),('iliac'),('iliad'),('ilial'),('ilium'),('iller'),
('illth'),('image'),('imago'),('imams'),('imari'),('imaum'),('imbar'),('imbed'),('imbue'),('imide'),('imido'),('imids'),
('imine'),('imino'),('immew'),('immit'),('immix'),('imped'),('impel'),('impis'),('imply'),('impot'),('imshi'),('imshy'),
('inane'),('inapt'),('inarm'),('inbox'),('inbye'),('incle'),('incog'),('incur'),('incus'),('incut'),('indew'),('index'),
('india'),('indie'),('indol'),('indow'),('indri'),('indue'),('inept'),('inerm'),('inert'),('infer'),('infix'),('infos'),
('infra'),('ingan'),('ingle'),('ingot'),('inion'),('inked'),('inker'),('inkle'),('inlay'),('inlet'),('inned'),('inner'),
('innit'),('inorb'),('input'),('inrun'),('inset'),('intel'),('inter'),('intil'),('intis'),('intra'),('intro'),('inula'),
('inure'),('inurn'),('inust'),('invar'),('inwit'),('iodic'),('iodid'),('iodin'),('ionic'),('iotas'),('ippon'),('irade'),
('irate'),('irids'),('iring'),('irked'),('iroko'),('irone'),('irons'),('irony'),('isbas'),('ishes'),('isled'),('isles'),
('islet'),('isnae'),('issei'),('issue'),('istle'),('itchy'),('items'),('ither'),('ivied'),('ivies'),('ivory'),('ixias'),
('ixora'),('ixtle'),('izard'),('izars'),('izzat'),('jaaps'),('jabot'),('jacal'),('jacks'),('jacky'),('jaded'),('jades'),
('jafas'),('jaffa'),('jagas'),('jager'),('jaggs'),('jaggy'),('jagir'),('jagra'),('jails'),('jakes'),('jakey'),('jalap'),
('jalop'),('jambe'),('jambo'),('jambs'),('jambu'),('james'),('jammy'),('jamon'),('janes'),('janns'),('janny'),('janty'),
('japan'),('japed'),('japer'),('japes'),('jarks'),('jarls'),('jarps'),('jarta'),('jarul'),('jasey'),('jaspe'),('jasps'),
('jatos'),('jauks'),('jaunt'),('jaups'),('javas'),('javel'),('jawan'),('jawed'),('jaxie'),('jazzy'),('jeans'),('jeats'),
('jebel'),('jedis'),('jeels'),('jeely'),('jeeps'),('jeers'),('jefes'),('jeffs'),('jehad'),('jehus'),('jelab'),('jello'),
('jells'),('jelly'),('jembe'),('jemmy'),('jenny'),('jerid'),('jerks'),('jerky'),('jerry'),('jesse'),('jests'),('jesus'),
('jetes'),('jeton'),('jetty'),('jeune'),('jewed'),('jewel'),('jewie'),('jhala'),('jiaos'),('jibba'),('jibbs'),('jibed'),
('jiber'),('jibes'),('jiffs'),('jiffy'),('jiggy'),('jigot'),('jihad'),('jills'),('jilts'),('jimmy'),('jimpy'),('jingo'),
('jinks'),('jinne'),('jinni'),('jinns'),('jirds'),('jirga'),('jirre'),('jived'),('jiver'),('jives'),('jivey'),('jnana'),
('jobed'),('jobes'),('jocko'),('jocks'),('jodel'),('joeys'),('johns'),('joins'),('joint'),('joist'),('joked'),('joker'),
('jokes'),('jokey'),('jokol'),('joled'),('joles'),('jolls'),('jolly'),('jolts'),('jolty'),('jomon'),('jomos'),('jones'),
('jongs'),('jonty'),('jooks'),('joram'),('jorum'),('jotas'),('jotty'),('jotun'),('joual'),('jougs'),('jouks'),('joule'),
('jours'),('joust'),('jowar'),('jowed'),('jowls'),('jowly'),('joyed'),('jubas'),('jubes'),('jucos'),('judas'),('judge'),
('judos'),('jugal'),('jugum'),('juice'),('juicy'),('jujus'),('juked'),('jukes'),('jukus'),('julep'),('jumar'),('jumbo'),
('jumby'),('jumps'),('jumpy'),('junco'),('junks'),('junky'),('junta'),('junto'),('jupes'),('jupon'),('jural'),('jurat'),
('jurel'),('juror'),('justs'),('jutes'),('jutty'),('juves'),('juvie'),('kaama'),('kabab'),('kabar'),('kabob'),('kacha'),
('kacks'),('kades'),('kadis'),('kafir'),('kagos'),('kagus'),('kahal'),('kaiak'),('kaids'),('kaies'),('kaifs'),('kaika'),
('kaiks'),('kails'),('kaims'),('kaing'),('kains'),('kakas'),('kakis'),('kalam'),('kales'),('kalif'),('kalis'),('kalpa'),
('kamas'),('kames'),('kamik'),('kamis'),('kamme'),('kanae'),('kanas'),('kandy'),('kaneh'),('kanes'),('kanga'),('kangs'),
('kanji'),('kants'),('kanzu'),('kaons'),('kapas'),('kaphs'),('kapok'),('kappa'),('kaput'),('karas'),('karat'),('karks'),
('karma'),('karns'),('karoo'),('karos'),('karri'),('karst'),('karsy'),('karts'),('karzy'),('kasha'),('kasme'),('katal'),
('katas'),('katis'),('katti'),('kaugh'),('kauri'),('kauru'),('kaury'),('kaval'),('kavas'),('kawas'),('kawau'),('kawed'),
('kayak'),('kayle'),('kayos'),('kazis'),('kazoo'),('kbars'),('kebab'),('kebar'),('kebob'),('kecks'),('kedge'),('kedgy'),
('keech'),('keefs'),('keeks'),('keels'),('keema'),('keeno'),('keens'),('keeps'),('keets'),('keeve'),('kefir'),('kehua'),
('keirs'),('kelep'),('kelim'),('kells'),('kelly'),('kelps'),('kelpy'),('kelts'),('kelty'),('kembo'),('kembs'),('kemps'),
('kempt'),('kempy'),('kenaf'),('kench'),('kendo'),('kenos'),('kente'),('kents'),('kepis'),('kerbs'),('kerel'),('kerfs'),
('kerky'),('kerma'),('kerne'),('kerns'),('keros'),('kerry'),('kerve'),('kesar'),('kests'),('ketas'),('ketch'),('ketes'),
('ketol'),('kevel'),('kevil'),('kexes'),('keyed'),('khadi'),('khafs'),('khaki'),('khans'),('khaph'),('khats'),('khaya'),
('khazi'),('kheda'),('kheth'),('khets'),('khoja'),('khors'),('khoum'),('khuds'),('kiaat'),('kiang'),('kibbe'),('kibbi'),
('kibei'),('kibes'),('kibla'),('kicks'),('kicky'),('kiddo'),('kiddy'),('kidel'),('kidge'),('kiefs'),('kiers'),('kieve'),
('kievs'),('kight'),('kikoi'),('kiley'),('kilim'),('kills'),('kilns'),('kilos'),('kilps'),('kilts'),('kilty'),('kimbo'),
('kinas'),('kinda'),('kinds'),('kindy'),('kines'),('kings'),('kinin'),('kinks'),('kinos'),('kiore'),('kiosk'),('kipes'),
('kippa'),('kipps'),('kirby'),('kirks'),('kirns'),('kirri'),('kisan'),('kissy'),('kists'),('kited'),('kiter'),('kites'),
('kithe'),('kiths'),('kitty'),('kitul'),('kivas'),('kiwis'),('klang'),('klaps'),('klett'),('klick'),('klieg'),('kliks'),
('klong'),('kloof'),('kluge'),('klutz'),('knack'),('knags'),('knaps'),('knarl'),('knars'),('knaur'),('knave'),('knawe'),
('knead'),('kneed'),('kneel'),('knees'),('knell'),('knelt'),('knife'),('knish'),('knits'),('knive'),('knobs'),('knock'),
('knoll'),('knops'),('knosp'),('knots'),('knout'),('knowe'),('known'),('knows'),('knubs'),('knurl'),('knurr'),('knurs'),
('knuts'),('koala'),('koans'),('koaps'),('koban'),('kobos'),('koels'),('koffs'),('kofta'),('kogal'),('kohas'),('kohen'),
('kohls'),('koine'),('kojis'),('kokas'),('koker'),('kokra'),('kokum'),('kolas'),('kolos'),('kombu'),('konbu'),('kondo'),
('konks'),('kooks'),('kooky'),('koori'),('kopek'),('kophs'),('kopje'),('koppa'),('korai'),('koras'),('korat'),('kores'),
('korma'),('koros'),('korun'),('korus'),('koses'),('kotch'),('kotos'),('kotow'),('koura'),('kraal'),('krabs'),('kraft'),
('krait'),('krang'),('krans'),('kranz'),('kraut'),('kreep'),('kreng'),('krewe'),('krill'),('krona'),('krone'),('kroon'),
('krubi'),('krunk'),('ksars'),('kudos'),('kudus'),('kudzu'),('kufis'),('kugel'),('kuias'),('kukri'),('kukus'),('kulak'),
('kulan'),('kulas'),('kulfi'),('kumys'),('kuris'),('kurre'),('kurta'),('kurus'),('kusso'),('kutas'),('kutch'),('kutis'),
('kutus'),('kuzus'),('kvass'),('kvell'),('kwela'),('kyack'),('kyaks'),('kyang'),('kyars'),('kyats'),('kybos'),('kydst'),
('kyles'),('kylie'),('kylin'),('kylix'),('kyloe'),('kynde'),('kynds'),('kypes'),('kyrie'),('kytes'),('kythe'),('laari'),
('labda'),('label'),('labis'),('labor'),('labra'),('laced'),('lacer'),('laces'),('lacet'),('lacey'),('lacks'),('laded'),
('laden'),('lader'),('lades'),('ladle'),('laers'),('laevo'),('lagan'),('lager'),('lahar'),('laich'),('laics'),('laids'),
('laigh'),('laika'),('laiks'),('laird'),('lairs'),('lairy'),('laith'),('laity'),('laked'),('laker'),('lakes'),('lakhs'),
('lakin'),('laksa'),('laldy'),('lalls'),('lamas'),('lambs'),('lamby'),('lamed'),('lamer'),('lames'),('lamia'),('lammy'),
('lamps'),('lanai'),('lanas'),('lance'),('lanch'),('lande'),('lands'),('lanes'),('lanks'),('lanky'),('lants'),('lapel'),
('lapin'),('lapis'),('lapje'),('lapse'),('larch'),('lards'),('lardy'),('laree'),('lares'),('large'),('largo'),('laris'),
('larks'),('larky'),('larns'),('larum'),('larva'),('lased'),('laser'),('lases'),('lassi'),('lasso'),('lassu'),('lasts'),
('latah'),('latch'),('lated'),('laten'),('later'),('latex'),('lathe'),('lathi'),('laths'),('lathy'),('latke'),('latte'),
('lauan'),('lauch'),('lauds'),('laufs'),('laugh'),('laund'),('laura'),('lavas'),('laved'),('laver'),('laves'),('lavra'),
('lavvy'),('lawed'),('lawer'),('lawin'),('lawks'),('lawns'),('lawny'),('laxer'),('laxes'),('laxly'),('layed'),('layer'),
('layin'),('layup'),('lazar'),('lazed'),('lazes'),('lazos'),('lazzi'),('lazzo'),('leach'),('leads'),('leady'),('leafs'),
('leafy'),('leaks'),('leaky'),('leams'),('leans'),('leant'),('leany'),('leaps'),('leapt'),('leare'),('learn'),('lears'),
('leary'),('lease'),('leash'),('least'),('leats'),('leave'),('leavy'),('leaze'),('leben'),('leccy'),('ledge'),('ledgy'),
('ledum'),('leear'),('leech'),('leeks'),('leeps'),('leers'),('leery'),('leese'),('leets'),('leeze'),('lefte'),('lefts'),
('lefty'),('legal'),('leger'),('leges'),('legge'),('leggy'),('legit'),('lehrs'),('lehua'),('leirs'),('leish'),('leman'),
('lemed'),('lemel'),('lemes'),('lemma'),('lemon'),('lemur'),('lends'),('lenes'),('lengs'),('lenis'),('lenos'),('lense'),
('lenti'),('lento'),('leone'),('leper'),('lepid'),('lepra'),('lepta'),('lered'),('leres'),('lerps'),('lesbo'),('leses'),
('lests'),('letch'),('lethe'),('letup'),('leuch'),('leuco'),('leuds'),('leugh'),('levee'),('level'),('lever'),('leves'),
('levin'),('levis'),('lewis'),('lexes'),('lexis'),('lezes'),('lezza'),('lezzy'),('liana'),('liane'),('liang'),('liard'),
('liars'),('liart'),('libel'),('liber'),('libra'),('libri'),('lichi'),('licht'),('licit'),('licks'),('lidar'),('lidos'),
('liefs'),('liege'),('liens'),('liers'),('lieus'),('lieve'),('lifer'),('lifes'),('lifts'),('ligan'),('liger'),('ligge'),
('light'),('ligne'),('liked'),('liken'),('liker'),('likes'),('likin'),('lilac'),('lills'),('lilos'),('lilts'),('liman'),
('limas'),('limax'),('limba'),('limbi'),('limbo'),('limbs'),('limby'),('limed'),('limen'),('limes'),('limey'),('limit'),
('limma'),('limns'),('limos'),('limpa'),('limps'),('linac'),('linch'),('linds'),('lindy'),('lined'),('linen'),('liner'),
('lines'),('liney'),('linga'),('lingo'),('lings'),('lingy'),('linin'),('links'),('linky'),('linns'),('linny'),('linos'),
('lints'),('linty'),('linum'),('linux'),('lions'),('lipas'),('lipid'),('lipin'),('lipos'),('lippy'),('liras'),('lirks'),
('lirot'),('lisks'),('lisle'),('lisps'),('lists'),('litai'),('litas'),('lited'),('liter'),('lites'),('lithe'),('litho'),
('liths'),('litre'),('lived'),('liven'),('liver'),('lives'),('livid'),('livor'),('livre'),('llama'),('llano'),('loach'),
('loads'),('loafs'),('loams'),('loamy'),('loans'),('loast'),('loath'),('loave'),('lobar'),('lobby'),('lobed'),('lobes'),
('lobos'),('lobus'),('local'),('lochs'),('locks'),('locos'),('locum'),('locus'),('loden'),('lodes'),('lodge'),('loess'),
('lofts'),('lofty'),('logan'),('loges'),('loggy'),('logia'),('logic'),('logie'),('login'),('logoi'),('logon'),('logos'),
('lohan'),('loids'),('loins'),('loipe'),('loirs'),('lokes'),('lolls'),('lolly'),('lolog'),('lomas'),('lomed'),('lomes'),
('loner'),('longa'),('longe'),('longs'),('looby'),('looed'),('looey'),('loofa'),('loofs'),('looie'),('looks'),('looms'),
('loons'),('loony'),('loops'),('loopy'),('loord'),('loose'),('loots'),('loped'),('loper'),('lopes'),('loppy'),('loral'),
('loran'),('lords'),('lordy'),('lorel'),('lores'),('loric'),('loris'),('lorry'),('losed'),('losel'),('losen'),('loser'),
('loses'),('lossy'),('lotah'),('lotas'),('lotes'),('lotic'),('lotos'),('lotte'),('lotto'),('lotus'),('loued'),('lough'),
('louie'),('louis'),('louma'),('lound'),('louns'),('loupe'),('loups'),('loure'),('lours'),('loury'),('louse'),('lousy'),
('louts'),('lovat'),('loved'),('lover'),('loves'),('lovey'),('lowan'),('lowed'),('lower'),('lowes'),('lowly'),('lownd'),
('lowne'),('lowns'),('lowps'),('lowry'),('lowse'),('lowts'),('loxed'),('loxes'),('loyal'),('lozen'),('luach'),('luaus'),
('lubed'),('lubes'),('lubra'),('luces'),('lucid'),('lucks'),('lucky'),('lucre'),('ludes'),('ludic'),('ludos'),('luffa'),
('luffs'),('luged'),('luger'),('luges'),('lulls'),('lulus'),('lumas'),('lumen'),('lumme'),('lummy'),('lumps'),('lumpy'),
('lunar'),('lunas'),('lunch'),('lunes'),('lunet'),('lunge'),('lungi'),('lungs'),('lunks'),('lunts'),('lupin'),('lupus'),
('lurch'),('lured'),('lurer'),('lures'),('lurex'),('lurgi'),('lurgy'),('lurid'),('lurks'),('lurry'),('lurve'),('luser'),
('lushy'),('lusks'),('lusts'),('lusty'),('lusus'),('lutea'),('luted'),('luter'),('lutes'),('luvvy'),('luxes'),('lweis'),
('lyams'),('lyard'),('lyart'),('lyase'),('lycea'),('lycee'),('lycra'),('lying'),('lymes'),('lymph'),('lynch'),('lynes'),
('lyres'),('lyric'),('lysed'),('lyses'),('lysin'),('lysis'),('lysol'),('lyssa'),('lyted'),('lytes'),('lythe'),('lytic'),
('lytta'),('maaed'),('maare'),('maars'),('mabes'),('macaw'),('maced'),('macer'),('maces'),('mache'),('machi'),('macho'),
('machs'),('macks'),('macle'),('macon'),('macro'),('madam'),('madge'),('madid'),('madly'),('madre'),('maerl'),('mafia'),
('mafic'),('mages'),('maggs'),('magic'),('magma'),('magot'),('magus'),('mahoe'),('mahua'),('mahwa'),('maids'),('maiko'),
('maiks'),('maile'),('maill'),('mails'),('maims'),('mains'),('maire'),('mairs'),('maise'),('maist'),('maize'),('major'),
('makar'),('maker'),('makes'),('makis'),('makos'),('malam'),('malar'),('malas'),('malax'),('males'),('malic'),('malik'),
('malis'),('malls'),('malms'),('malmy'),('malts'),('malty'),('malva'),('malwa'),('mamas'),('mamba'),('mambo'),('mamee'),
('mamey'),('mamie'),('mamma'),('mammy'),('manas'),('manat'),('mandi'),('maned'),('maneh'),('manes'),('manet'),('manga'),
('mange'),('mango'),('mangs'),('mangy'),('mania'),('manic'),('manis'),('manky'),('manly'),('manna'),('manor'),('manos'),
('manse'),('manta'),('manto'),('manty'),('manul'),('manus'),('mapau'),('maple'),('maqui'),('marae'),('marah'),('maras'),
('march'),('marcs'),('mardy'),('mares'),('marge'),('margs'),('maria'),('marid'),('marka'),('marks'),('marle'),('marls'),
('marly'),('marms'),('maron'),('maror'),('marri'),('marry'),('marse'),('marsh'),('marts'),('marvy'),('masas'),('mased'),
('maser'),('mases'),('mashy'),('masks'),('mason'),('massa'),('masse'),('massy'),('masts'),('masty'),('masus'),('matai'),
('match'),('mated'),('mater'),('mates'),('matey'),('maths'),('matin'),('matlo'),('matte'),('matts'),('matza'),('matzo'),
('mauby'),('mauds'),('mauls'),('maund'),('mauri'),('mauts'),('mauve'),('maven'),('mavie'),('mavin'),('mavis'),('mawed'),
('mawks'),('mawky'),('mawrs'),('maxed'),('maxes'),('maxim'),('maxis'),('mayan'),('mayas'),('maybe'),('mayed'),('mayor'),
('mayos'),('mayst'),('mazed'),('mazer'),('mazes'),('mazey'),('mazut'),('mbira'),('meads'),('meals'),('mealy'),('meane'),
('means'),('meant'),('meany'),('meare'),('mease'),('meath'),('meats'),('meaty'),('mebos'),('mecca'),('mecks'),('medal'),
('media'),('medic'),('medii'),('medle'),('meeds'),('meers'),('meets'),('meffs'),('meins'),('meint'),('meiny'),('meith'),
('mekka'),('melas'),('melba'),('melds'),('melee'),('melic'),('melik'),('mells'),('melon'),('melts'),('melty'),('memes'),
('memos'),('menad'),('mends'),('mened'),('menes'),('menge'),('mengs'),('mensa'),('mense'),('mensh'),('menta'),('mento'),
('menus'),('meous'),('meows'),('merch'),('mercs'),('mercy'),('merde'),('mered'),('merel'),('merer'),('meres'),('merge'),
('meril'),('meris'),('merit'),('merks'),('merle'),('merls'),('merry'),('merse'),('mesal'),('mesas'),('mesel'),('meses'),
('meshy'),('mesic'),('mesne'),('meson'),('messy'),('mesto'),('metal'),('meted'),('meter'),('metes'),('metho'),('meths'),
('metic'),('metif'),('metis'),('metol'),('metre'),('metro'),('meuse'),('meved'),('meves'),('mewed'),('mewls'),('meynt'),
('mezes'),('mezze'),('mezzo'),('mhorr'),('miaou'),('miaow'),('miasm'),('miaul'),('micas'),('miche'),('micht'),('micks'),
('micky'),('micos'),('micra'),('micro'),('middy'),('midge'),('midgy'),('midis'),('midst'),('miens'),('mieve'),('miffs'),
('miffy'),('mifty'),('miggs'),('might'),('mihas'),('mihis'),('miked'),('mikes'),('mikra'),('milch'),('milds'),('miler'),
('miles'),('milia'),('milko'),('milks'),('milky'),('mille'),('mills'),('milor'),('milos'),('milpa'),('milts'),('milty'),
('miltz'),('mimed'),('mimeo'),('mimer'),('mimes'),('mimic'),('mimsy'),('minae'),('minar'),('minas'),('mince'),('mincy'),
('minds'),('mined'),('miner'),('mines'),('minge'),('mings'),('mingy'),('minim'),('minis'),('minke'),('minks'),('minny'),
('minor'),('minos'),('mints'),('minty'),('minus'),('mired'),('mires'),('mirex'),('mirin'),('mirks'),('mirky'),('mirly'),
('miros'),('mirth'),('mirvs'),('mirza'),('misch'),('misdo'),('miser'),('mises'),('misgo'),('misos'),('missa'),('missy'),
('mists'),('misty'),('mitch'),('miter'),('mites'),('mitis'),('mitre'),('mitts'),('mixed'),('mixen'),('mixer'),('mixes'),
('mixte'),('mixup'),('mizen'),('mizzy'),('mneme'),('moans'),('moats'),('mobby'),('mobes'),('mobey'),('mobie'),('moble'),
('mocha'),('mochs'),('mochy'),('mocks'),('modal'),('model'),('modem'),('moder'),('modes'),('modge'),('modii'),('modus'),
('moers'),('moggy'),('mogul'),('mohel'),('mohrs'),('mohua'),('mohur'),('moils'),('moira'),('moire'),('moist'),('moits'),
('mojos'),('mokes'),('mokis'),('mokos'),('molal'),('molar'),('molas'),('molds'),('moldy'),('moles'),('molla'),('molls'),
('molly'),('molto'),('molts'),('momes'),('momma'),('mommy'),('momus'),('monad'),('monal'),('monas'),('monde'),('mondo'),
('moner'),('money'),('mongo'),('mongs'),('monie'),('monks'),('monos'),('monte'),('month'),('monty'),('moobs'),('mooch'),
('moods'),('moody'),('mooed'),('mooks'),('moola'),('mooli'),('mools'),('mooly'),('moong'),('moons'),('moony'),('moops'),
('moors'),('moory'),('moose'),('moots'),('moove'),('moped'),('moper'),('mopes'),('mopey'),('moppy'),('mopsy'),('mopus'),
('morae'),('moral'),('moras'),('morat'),('moray'),('morel'),('mores'),('moria'),('morne'),('morns'),('moron'),('morph'),
('morra'),('morro'),('morse'),('morts'),('mosed'),('moses'),('mosey'),('mosks'),('mosso'),('mossy'),('moste'),('mosts'),
('moted'),('motel'),('moten'),('motes'),('motet'),('motey'),('moths'),('mothy'),('motif'),('motis'),('motor'),('motte'),
('motto'),('motts'),('motty'),('motus'),('motza'),('mouch'),('moues'),('mould'),('mouls'),('moult'),('mound'),('mount'),
('moups'),('mourn'),('mouse'),('moust'),('mousy'),('mouth'),('moved'),('mover'),('moves'),('movie'),('mowas'),('mowed'),
('mower'),('mowra'),('moxas'),('moxie'),('moyas'),('moyle'),('moyls'),('mozed'),('mozes'),('mozos'),('mpret'),('mucho'),
('mucic'),('mucid'),('mucin'),('mucks'),('mucky'),('mucor'),('mucro'),('mucus'),('muddy'),('mudge'),('mudir'),('mudra'),
('muffs'),('mufti'),('mugga'),('muggs'),('muggy'),('muhly'),('muids'),('muils'),('muirs'),('muist'),('mujik'),('mulch'),
('mulct'),('muled'),('mules'),('muley'),('mulga'),('mulla'),('mulls'),('mulse'),('mulsh'),('mumms'),('mummy'),('mumps'),
('mumsy'),('mumus'),('munch'),('munga'),('munge'),('mungo'),('mungs'),('munis'),('munts'),('muntu'),('muons'),('mural'),
('muras'),('mured'),('mures'),('murex'),('murid'),('murks'),('murky'),('murls'),('murly'),('murra'),('murre'),('murri'),
('murrs'),('murry'),('murti'),('murva'),('musar'),('musca'),('mused'),('muser'),('muses'),('muset'),('musha'),('mushy'),
('music'),('musit'),('musks'),('musky'),('musos'),('musse'),('mussy'),('musth'),('musts'),('musty'),('mutch'),('muted'),
('muter'),('mutes'),('mutis'),('muton'),('mutts'),('muxed'),('muxes'),('muzzy'),('mvule'),('myall'),('mylar'),('mynah'),
('mynas'),('myoid'),('myoma'),('myope'),('myops'),('myopy'),('myrrh'),('mysid'),('mythi'),('myths'),('mythy'),('myxos'),
('mzees'),('naams'),('naans'),('nabes'),('nabis'),('nabks'),('nabla'),('nabob'),('nache'),('nacho'),('nacre'),('nadas'),
('nadir'),('naeve'),('naevi'),('naffs'),('nagas'),('naggy'),('nagor'),('nahal'),('naiad'),('naifs'),('naiks'),('nails'),
('naira'),('nairu'),('naive'),('naked'),('naker'),('nakfa'),('nalas'),('naled'),('nalla'),('named'),('namer'),('names'),
('namma'),('namus'),('nanas'),('nance'),('nancy'),('nandu'),('nanna'),('nanny'),('nanua'),('napas'),('naped'),('napes'),
('napoo'),('nappa'),('nappe'),('nappy'),('naras'),('narco'),('narcs'),('nards'),('nares'),('naric'),('naris'),('narks'),
('narky'),('narre'),('nasal'),('nashi'),('nasty'),('natal'),('natch'),('nates'),('natis'),('natty'),('nauch'),('naunt'),
('naval'),('navar'),('navel'),('naves'),('navew'),('navvy'),('nawab'),('nazes'),('nazir'),('nazis'),('neafe'),('neals'),
('neaps'),('nears'),('neath'),('neats'),('nebek'),('nebel'),('necks'),('neddy'),('needs'),('needy'),('neeld'),('neele'),
('neemb'),('neems'),('neeps'),('neese'),('neeze'),('negus'),('neifs'),('neigh'),('neist'),('neive'),('nelis'),('nelly'),
('nemas'),('nemns'),('nempt'),('nenes'),('neons'),('neper'),('nepit'),('neral'),('nerds'),('nerdy'),('nerka'),('nerks'),
('nerol'),('nerts'),('nertz'),('nerve'),('nervy'),('nests'),('netes'),('netop'),('netts'),('netty'),('neuks'),('neume'),
('neums'),('nevel'),('never'),('neves'),('nevus'),('newed'),('newel'),('newer'),('newie'),('newly'),('newsy'),('newts'),
('nexts'),('nexus'),('ngaio'),('ngana'),('ngati'),('ngoma'),('ngwee'),('nicad'),('nicer'),('niche'),('nicht'),('nicks'),
('nicol'),('nidal'),('nided'),('nides'),('nidor'),('nidus'),('niece'),('niefs'),('nieve'),('nifes'),('niffs'),('niffy'),
('nifty'),('niger'),('nighs'),('night'),('nihil'),('nikab'),('nikah'),('nikau'),('nills'),('nimbi'),('nimbs'),('nimps'),
('nines'),('ninja'),('ninny'),('ninon'),('ninth'),('nipas'),('nippy'),('niqab'),('nirls'),('nirly'),('nisei'),('nisse'),
('nisus'),('niter'),('nites'),('nitid'),('niton'),('nitre'),('nitro'),('nitry'),('nitty'),('nival'),('nixed'),('nixer'),
('nixes'),('nixie'),('nizam'),('nkosi'),('noahs'),('nobby'),('noble'),('nobly'),('nocks'),('nodal'),('noddy'),('nodes'),
('nodus'),('noels'),('noggs'),('nohow'),('noils'),('noily'),('noint'),('noirs'),('noise'),('noisy'),('noles'),('nolls'),
('nolos'),('nomad'),('nomas'),('nomen'),('nomes'),('nomic'),('nomoi'),('nomos'),('nonas'),('nonce'),('nones'),('nonet'),
('nongs'),('nonis'),('nonny'),('nonyl'),('noobs'),('nooit'),('nooks'),('nooky'),('noons'),('noops'),('noose'),('nopal'),
('noria'),('noris'),('norks'),('norma'),('norms'),('north'),('nosed'),('noser'),('noses'),('nosey'),('notal'),('notch'),
('noted'),('noter'),('notes'),('notum'),('nould'),('noule'),('nouls'),('nouns'),('nouny'),('noups'),('novae'),('novas'),
('novel'),('novum'),('noway'),('nowed'),('nowls'),('nowts'),('nowty'),('noxal'),('noxes'),('noyau'),('noyed'),('noyes'),
('nubby'),('nubia'),('nucha'),('nuddy'),('nuder'),('nudge'),('nudzh'),('nuffs'),('nugae'),('nuked'),('nukes'),('nulla'),
('nulls'),('numbs'),('numen'),('nunny'),('nurds'),('nurdy'),('nurls'),('nurrs'),('nurse'),('nutso'),('nutsy'),('nutty'),
('nyaff'),('nyala'),('nying'),('nylon'),('nymph'),('nyssa'),('oaked'),('oaken'),('oaker'),('oakum'),('oared'),('oases'),
('oasis'),('oasts'),('oaten'),('oater'),('oaths'),('oaves'),('obang'),('obeah'),('obeli'),('obese'),('obeys'),('obias'),
('obied'),('obiit'),('obits'),('objet'),('oboes'),('obole'),('oboli'),('obols'),('occam'),('occur'),('ocean'),('ocher'),
('oches'),('ochre'),('ochry'),('ocker'),('ocrea'),('octad'),('octal'),('octan'),('octas'),('octet'),('octyl'),('oculi'),
('odahs'),('odals'),('odder'),('oddly'),('odeon'),('odeum'),('odism'),('odist'),('odium'),('odors'),('odour'),('odyle'),
('odyls'),('ofays'),('offal'),('offed'),('offer'),('offie'),('oflag'),('often'),('ofter'),('ogams'),('ogeed'),('ogees'),
('oggin'),('ogham'),('ogive'),('ogled'),('ogler'),('ogles'),('ogmic'),('ogres'),('ohias'),('ohing'),('ohmic'),('ohone'),
('oidia'),('oiled'),('oiler'),('oinks'),('oints'),('ojime'),('okapi'),('okays'),('okehs'),('okras'),('oktas'),('olden'),
('older'),('oldie'),('oleic'),('olein'),('olent'),('oleos'),('oleum'),('olios'),('olive'),('ollas'),('ollav'),('oller'),
('ollie'),('ology'),('olpae'),('olpes'),('omasa'),('omber'),('ombre'),('ombus'),('omega'),('omens'),('omers'),('omits'),
('omlah'),('omovs'),('omrah'),('oncer'),('onces'),('oncet'),('oncus'),('onely'),('oners'),('onery'),('onion'),('onium'),
('onkus'),('onlay'),('onned'),('onset'),('ontic'),('oobit'),('oohed'),('oomph'),('oonts'),('ooped'),('oorie'),('ooses'),
('ootid'),('oozed'),('oozes'),('opahs'),('opals'),('opens'),('opepe'),('opera'),('opine'),('oping'),('opium'),('oppos'),
('opsin'),('opted'),('opter'),('optic'),('orach'),('oracy'),('orals'),('orang'),('orant'),('orate'),('orbed'),('orbit'),
('orcas'),('orcin'),('order'),('ordos'),('oread'),('orfes'),('organ'),('orgia'),('orgic'),('orgue'),('oribi'),('oriel'),
('orixa'),('orles'),('orlon'),('orlop'),('ormer'),('ornis'),('orpin'),('orris'),('ortho'),('orval'),('orzos'),('oscar'),
('oshac'),('osier'),('osmic'),('osmol'),('ossia'),('ostia'),('otaku'),('otary'),('other'),('ottar'),('otter'),('ottos'),
('oubit'),('oucht'),('ouens'),('ought'),('ouija'),('oulks'),('oumas'),('ounce'),('oundy'),('oupas'),('ouped'),('ouphe'),
('ouphs'),('ourie'),('ousel'),('ousts'),('outby'),('outdo'),('outed'),('outer'),('outgo'),('outre'),('outro'),('ouzel'),
('ouzos'),('ovals'),('ovary'),('ovate'),('ovels'),('ovens'),('overs'),('overt'),('ovine'),('ovist'),('ovoid'),('ovoli'),
('ovolo'),('ovule'),('owche'),('owing'),('owled'),('owler'),('owlet'),('owned'),('owner'),('owres'),('owrie'),('owsen'),
('oxbow'),('oxers'),('oxeye'),('oxide'),('oxids'),('oxies'),('oxime'),('oxims'),('oxlip'),('oxter'),('oyers'),('ozeki'),
('ozone'),('ozzie'),('paals'),('paans'),('pacas'),('paced'),('pacer'),('paces'),('pacey'),('pacha'),('packs'),('pacos'),
('pacta'),('pacts'),('paddy'),('padis'),('padle'),('padma'),('padre'),('padri'),('paean'),('paedo'),('paeon'),('pagan'),
('paged'),('pager'),('pages'),('pagle'),('pagod'),('pagri'),('paiks'),('pails'),('pains'),('paint'),('paire'),('pairs'),
('paisa'),('paise'),('pakka'),('palas'),('palay'),('palea'),('paled'),('paler'),('pales'),('palet'),('palki'),('palla'),
('palls'),('pally'),('palms'),('palmy'),('palpi'),('palps'),('palsy'),('pampa'),('panax'),('pance'),('panda'),('pands'),
('pandy'),('paned'),('panel'),('panes'),('panga'),('pangs'),('panic'),('panim'),('panko'),('panne'),('pansy'),('panto'),
('pants'),('paoli'),('paolo'),('papal'),('papas'),('papaw'),('paper'),('papes'),('pappi'),('pappy'),('parae'),('paras'),
('parch'),('pardi'),('pards'),('pardy'),('pared'),('pareo'),('parer'),('pares'),('pareu'),('parev'),('parge'),('pargo'),
('paris'),('parka'),('parki'),('parks'),('parky'),('parle'),('parly'),('parol'),('parps'),('parra'),('parrs'),('parry'),
('parse'),('parti'),('parts'),('party'),('parve'),('parvo'),('paseo'),('pases'),('pasha'),('pashm'),('paspy'),('passe'),
('pasta'),('paste'),('pasts'),('pasty'),('patch'),('pated'),('paten'),('pater'),('pates'),('paths'),('patin'),('patio'),
('patka'),('patly'),('patsy'),('patte'),('patty'),('patus'),('pauas'),('pauls'),('pause'),('pavan'),('paved'),('paven'),
('paver'),('paves'),('pavid'),('pavin'),('pavis'),('pawas'),('pawaw'),('pawed'),('pawer'),('pawks'),('pawky'),('pawls'),
('pawns'),('paxes'),('payed'),('payee'),('payer'),('payor'),('paysd'),('peace'),('peach'),('peage'),('peags'),('peaks'),
('peaky'),('peals'),('peans'),('peare'),('pearl'),('pears'),('peart'),('pease'),('peats'),('peaty'),('peavy'),('peaze'),
('pebas'),('pecan'),('pechs'),('pecke'),('pecks'),('pecky'),('pedal'),('pedes'),('pedro'),('peece'),('peeks'),('peels'),
('peens'),('peeoy'),('peepe'),('peeps'),('peers'),('peery'),('peeve'),('peggy'),('peghs'),('peins'),('peise'),('peize'),
('pekan'),('pekes'),('pekin'),('pekoe'),('pelas'),('peles'),('pelfs'),('pells'),('pelma'),('pelon'),('pelta'),('pelts'),
('penal'),('pence'),('pends'),('pendu'),('pened'),('penes'),('pengo'),('penie'),('penks'),('penna'),('penne'),('penni'),
('penny'),('pents'),('peons'),('peony'),('pepla'),('pepos'),('peppy'),('perai'),('perce'),('perch'),('perdu'),('perdy'),
('perea'),('peres'),('peril'),('peris'),('perks'),('perky'),('perms'),('perns'),('perps'),('perry'),('perse'),('perst'),
('perts'),('perve'),('pervs'),('pervy'),('pesky'),('pesos'),('pesto'),('pests'),('pesty'),('petal'),('petar'),('peter'),
('petit'),('petre'),('petri'),('petti'),('petto'),('petty'),('pewee'),('pewit'),('peyse'),('phage'),('phang'),('phare'),
('pharm'),('phase'),('pheer'),('phene'),('pheon'),('phese'),('phial'),('phlox'),('phoca'),('phone'),('phono'),('phons'),
('phony'),('photo'),('phots'),('phpht'),('phuts'),('phyla'),('phyle'),('piani'),('piano'),('pians'),('pibal'),('pical'),
('picas'),('piccy'),('picks'),('picky'),('picot'),('picra'),('picul'),('piece'),('piend'),('piers'),('piert'),('pieta'),
('piets'),('piety'),('piezo'),('piggy'),('pight'),('pigmy'),('piing'),('pikas'),('pikau'),('piked'),('piker'),('pikes'),
('pikey'),('pikis'),('pikul'),('pilaf'),('pilao'),('pilar'),('pilau'),('pilaw'),('pilch'),('pilea'),('piled'),('pilei'),
('piler'),('piles'),('pilis'),('pills'),('pilot'),('pilow'),('pilum'),('pilus'),('pimas'),('pimps'),('pinas'),('pinch'),
('pined'),('pines'),('piney'),('pingo'),('pings'),('pinko'),('pinks'),('pinky'),('pinna'),('pinny'),('pinon'),('pinot'),
('pinta'),('pinto'),('pints'),('pinup'),('pions'),('piony'),('pious'),('pioye'),('pioys'),('pipal'),('pipas'),('piped'),
('piper'),('pipes'),('pipet'),('pipis'),('pipit'),('pippy'),('pipul'),('pique'),('pirai'),('pirls'),('pirns'),('pirog'),
('pisco'),('pises'),('pisky'),('pisos'),('piste'),('pitas'),('pitch'),('piths'),('pithy'),('piton'),('pitta'),('piums'),
('pivot'),('pixel'),('pixes'),('pixie'),('pized'),('pizes'),('pizza'),('plaas'),('place'),('plack'),('plage'),('plaid'),
('plain'),('plait'),('plane'),('plank'),('plans'),('plant'),('plaps'),('plash'),('plasm'),('plast'),('plate'),('plats'),
('platy'),('playa'),('plays'),('plaza'),('plead'),('pleas'),('pleat'),('plebe'),('plebs'),('plena'),('pleon'),('plesh'),
('plews'),('plica'),('plied'),('plier'),('plies'),('plims'),('pling'),('plink'),('ploat'),('plods'),('plong'),('plonk'),
('plook'),('plops'),('plots'),('plotz'),('plouk'),('plows'),('ploys'),('pluck'),('plues'),('pluff'),('plugs'),('plumb'),
('plume'),('plump'),('plums'),('plumy'),('plunk'),('plush'),('plyer'),('poach'),('poaka'),('poake'),('poboy'),('pocks'),
('pocky'),('podal'),('poddy'),('podex'),('podge'),('podgy'),('podia'),('poems'),('poeps'),('poesy'),('poets'),('pogey'),
('pogge'),('pogos'),('poilu'),('poind'),('point'),('poise'),('pokal'),('poked'),('poker'),('pokes'),('pokey'),('pokie'),
('polar'),('poled'),('poler'),('poles'),('poley'),('polio'),('polis'),('polje'),('polka'),('polks'),('polls'),('polly'),
('polos'),('polts'),('polyp'),('polys'),('pombe'),('pomes'),('pommy'),('pomos'),('pomps'),('ponce'),('poncy'),('ponds'),
('pones'),('poney'),('ponga'),('pongo'),('pongs'),('pongy'),('ponks'),('ponts'),('ponty'),('ponzu'),('pooch'),('poods'),
('poohs'),('pooja'),('pooka'),('pooks'),('pools'),('poons'),('poops'),('poori'),('poort'),('poots'),('poove'),('poovy'),
('popes'),('poppa'),('poppy'),('popsy'),('porae'),('poral'),('porch'),('pored'),('porer'),('pores'),('porge'),('porgy'),
('porks'),('porky'),('porta'),('ports'),('porty'),('posed'),('poser'),('poses'),('posey'),('posho'),('posit'),('posse'),
('posts'),('potae'),('potch'),('poted'),('potes'),('potin'),('potoo'),('potsy'),('potto'),('potts'),('potty'),('pouch'),
('pouff'),('poufs'),('pouke'),('pouks'),('poule'),('poulp'),('poult'),('pound'),('poupe'),('poupt'),('pours'),('pouts'),
('pouty'),('powan'),('power'),('powin'),('pownd'),('powns'),('powny'),('powre'),('poxed'),('poxes'),('poynt'),('poyou'),
('poyse'),('pozzy'),('praam'),('prads'),('prahu'),('prams'),('prana'),('prang'),('prank'),('praos'),('prase'),('prate'),
('prats'),('pratt'),('praty'),('praus'),('prawn'),('prays'),('predy'),('preed'),('preen'),('prees'),('preif'),('prems'),
('premy'),('prent'),('preon'),('preop'),('preps'),('presa'),('prese'),('press'),('prest'),('preve'),('prexy'),('preys'),
('prial'),('price'),('pricy'),('pride'),('pried'),('prief'),('prier'),('pries'),('prigs'),('prill'),('prima'),('prime'),
('primi'),('primo'),('primp'),('prims'),('primy'),('prink'),('print'),('prion'),('prior'),('prise'),('prism'),('priss'),
('privy'),('prize'),('proas'),('probe'),('probs'),('prods'),('proem'),('profs'),('progs'),('proin'),('proke'),('prole'),
('proll'),('promo'),('proms'),('prone'),('prong'),('pronk'),('proof'),('props'),('prore'),('prose'),('proso'),('pross'),
('prost'),('prosy'),('proto'),('proud'),('proul'),('prove'),('prowl'),('prows'),('proxy'),('proyn'),('prude'),('prune'),
('prunt'),('pruta'),('pryer'),('pryse'),('psalm'),('pseud'),('pshaw'),('psion'),('psoae'),('psoai'),('psoas'),('psora'),
('psych'),('psyop'),('pubco'),('pubic'),('pubis'),('pucan'),('pucer'),('puces'),('pucka'),('pucks'),('puddy'),('pudge'),
('pudgy'),('pudic'),('pudor'),('pudsy'),('pudus'),('puers'),('puffs'),('puffy'),('puggy'),('pugil'),('puhas'),('pujah'),
('pujas'),('pukas'),('puked'),('puker'),('pukes'),('pukey'),('pukka'),('pukus'),('pulao'),('pulas'),('puled'),('puler'),
('pules'),('pulik'),('pulis'),('pulka'),('pulks'),('pulli'),('pulls'),('pulmo'),('pulps'),('pulpy'),('pulse'),('pulus'),
('pumas'),('pumie'),('pumps'),('punas'),('punce'),('punch'),('punga'),('pungs'),('punji'),('punka'),('punks'),('punky'),
('punny'),('punto'),('punts'),('punty'),('pupae'),('pupal'),('pupas'),('pupil'),('puppy'),('pupus'),('purda'),('pured'),
('puree'),('purer'),('pures'),('purge'),('purin'),('puris'),('purls'),('purpy'),('purrs'),('purse'),('pursy'),('purty'),
('puses'),('pushy'),('pusle'),('putid'),('puton'),('putti'),('putto'),('putts'),('putty'),('puzel'),('pyats'),('pyets'),
('pygal'),('pygmy'),('pyins'),('pylon'),('pyned'),('pynes'),('pyoid'),('pyots'),('pyral'),('pyran'),('pyres'),('pyrex'),
('pyric'),('pyros'),('pyxed'),('pyxes'),('pyxie'),('pyxis'),('pzazz'),('qadis'),('qaids'),('qanat'),('qibla'),('qophs'),
('qorma'),('quack'),('quads'),('quaff'),('quags'),('quail'),('quair'),('quais'),('quake'),('quaky'),('quale'),('qualm'),
('quant'),('quare'),('quark'),('quart'),('quash'),('quasi'),('quass'),('quate'),('quats'),('quayd'),('quays'),('qubit'),
('quean'),('queen'),('queer'),('quell'),('queme'),('quena'),('quern'),('query'),('quest'),('queue'),('queyn'),('queys'),
('quich'),('quick'),('quids'),('quiet'),('quiff'),('quill'),('quilt'),('quina'),('quine'),('quino'),('quins'),('quint'),
('quipo'),('quips'),('quipu'),('quire'),('quirk'),('quirt'),('quist'),('quite'),('quits'),('quoad'),('quods'),('quoif'),
('quoin'),('quoit'),('quoll'),('quonk'),('quops'),('quota'),('quote'),('quoth'),('qursh'),('quyte'),('rabat'),('rabbi'),
('rabic'),('rabid'),('rabis'),('raced'),('racer'),('races'),('rache'),('racks'),('racon'),('radar'),('radge'),('radii'),
('radio'),('radix'),('radon'),('raffs'),('rafts'),('ragas'),('ragde'),('raged'),('ragee'),('rager'),('rages'),('ragga'),
('raggs'),('raggy'),('ragis'),('ragus'),('rahed'),('rahui'),('raias'),('raids'),('raiks'),('raile'),('rails'),('raine'),
('rains'),('rainy'),('raird'),('raise'),('raita'),('raits'),('rajah'),('rajas'),('rajes'),('raked'),('rakee'),('raker'),
('rakes'),('rakia'),('rakis'),('rakus'),('rales'),('rally'),('ralph'),('ramal'),('ramee'),('ramen'),('ramet'),('ramie'),
('ramin'),('ramis'),('rammy'),('ramps'),('ramus'),('ranas'),('rance'),('ranch'),('rands'),('randy'),('ranee'),('ranga'),
('range'),('rangi'),('rangy'),('ranid'),('ranis'),('ranke'),('ranks'),('rants'),('raphe'),('rapid'),('rappe'),('rared'),
('raree'),('rarer'),('rares'),('rarks'),('rased'),('raser'),('rases'),('rasps'),('raspy'),('rasse'),('rasta'),('ratal'),
('ratan'),('ratas'),('ratch'),('rated'),('ratel'),('rater'),('rates'),('ratha'),('rathe'),('raths'),('ratio'),('ratoo'),
('ratos'),('ratty'),('ratus'),('rauns'),('raupo'),('raved'),('ravel'),('raven'),('raver'),('raves'),('ravin'),('rawer'),
('rawin'),('rawly'),('rawns'),('raxed'),('raxes'),('rayah'),('rayas'),('rayed'),('rayle'),('rayne'),('rayon'),('razed'),
('razee'),('razer'),('razes'),('razoo'),('razor'),('reach'),('react'),('readd'),('reads'),('ready'),('reaks'),('realm'),
('realo'),('reals'),('reame'),('reams'),('reamy'),('reans'),('reaps'),('rearm'),('rears'),('reast'),('reata'),('reate'),
('reave'),('rebar'),('rebbe'),('rebec'),('rebel'),('rebid'),('rebit'),('rebop'),('rebus'),('rebut'),('rebuy'),('recal'),
('recap'),('recce'),('recco'),('reccy'),('recit'),('recks'),('recon'),('recta'),('recti'),('recto'),('recur'),('recut'),
('redan'),('redds'),('reddy'),('reded'),('redes'),('redia'),('redid'),('redip'),('redly'),('redon'),('redos'),('redox'),
('redry'),('redub'),('redux'),('redye'),('reech'),('reede'),('reeds'),('reedy'),('reefs'),('reefy'),('reeks'),('reeky'),
('reels'),('reens'),('reest'),('reeve'),('refed'),('refel'),('refer'),('reffo'),('refit'),('refix'),('refly'),('refry'),
('regal'),('regar'),('reges'),('reggo'),('regie'),('regma'),('regna'),('regos'),('regur'),('rehab'),('rehem'),('reifs'),
('reify'),('reign'),('reiki'),('reiks'),('reink'),('reins'),('reird'),('reist'),('reive'),('rejig'),('rejon'),('reked'),
('rekes'),('rekey'),('relax'),('relay'),('relet'),('relic'),('relie'),('relit'),('reman'),('remap'),('remen'),('remet'),
('remex'),('remit'),('remix'),('renal'),('renay'),('rends'),('renew'),('reney'),('renga'),('renig'),('renin'),('renne'),
('rente'),('rents'),('reoil'),('repay'),('repeg'),('repel'),('repin'),('repla'),('reply'),('repos'),('repot'),('repps'),
('repro'),('reran'),('rerig'),('rerun'),('resat'),('resaw'),('resay'),('resee'),('reses'),('reset'),('resew'),('resid'),
('resin'),('resit'),('resod'),('resow'),('resto'),('rests'),('resty'),('retag'),('retax'),('retch'),('retem'),('retia'),
('retie'),('retro'),('retry'),('reuse'),('revel'),('revet'),('revie'),('revue'),('rewan'),('rewax'),('rewed'),('rewet'),
('rewin'),('rewon'),('rewth'),('rexes'),('rheas'),('rheme'),('rheum'),('rhies'),('rhime'),('rhine'),('rhino'),('rhody'),
('rhomb'),('rhone'),('rhumb'),('rhyme'),('rhyne'),('rhyta'),('riads'),('rials'),('riant'),('riata'),('ribas'),('ribby'),
('ribes'),('riced'),('ricer'),('rices'),('ricey'),('richt'),('ricin'),('ricks'),('rider'),('rides'),('ridge'),('ridgy'),
('riels'),('riems'),('rieve'),('rifer'),('riffs'),('rifle'),('rifte'),('rifts'),('rifty'),('riggs'),('right'),('rigid'),
('rigol'),('rigor'),('riled'),('riles'),('riley'),('rille'),('rills'),('rimae'),('rimed'),('rimer'),('rimes'),('rimus'),
('rinds'),('rindy'),('rines'),('rings'),('rinks'),('rinse'),('rioja'),('riots'),('riped'),('ripen'),('riper'),('ripes'),
('ripps'),('risen'),('riser'),('rises'),('rishi'),('risks'),('risky'),('risps'),('risus'),('rites'),('ritts'),('ritzy'),
('rival'),('rivas'),('rived'),('rivel'),('riven'),('river'),('rives'),('rivet'),('riyal'),('rizas'),('roach'),('roads'),
('roams'),('roans'),('roars'),('roary'),('roast'),('roate'),('robed'),('robes'),('robin'),('roble'),('robot'),('rocks'),
('rocky'),('roded'),('rodeo'),('rodes'),('roger'),('rogue'),('roguy'),('roils'),('roily'),('roins'),('roist'),('rojak'),
('rojis'),('roked'),('roker'),('rokes'),('rolag'),('roles'),('rolfs'),('rolls'),('romal'),('roman'),('romeo'),('romps'),
('ronde'),('rondo'),('roneo'),('rones'),('ronin'),('ronne'),('ronte'),('ronts'),('roods'),('roofs'),('roofy'),('rooks'),
('rooky'),('rooms'),('roomy'),('roons'),('roops'),('roopy'),('roosa'),('roose'),('roost'),('roots'),('rooty'),('roped'),
('roper'),('ropes'),('ropey'),('roque'),('roral'),('rores'),('roric'),('rorid'),('rorie'),('rorts'),('rorty'),('rosed'),
('roses'),('roset'),('roshi'),('rosin'),('rosit'),('rosti'),('rosts'),('rotal'),('rotan'),('rotas'),('rotch'),('roted'),
('rotes'),('rotis'),('rotls'),('roton'),('rotor'),('rotos'),('rotte'),('rouen'),('roues'),('rouge'),('rough'),('roule'),
('rouls'),('roums'),('round'),('roups'),('roupy'),('rouse'),('roust'),('route'),('routh'),('routs'),('roved'),('roven'),
('rover'),('roves'),('rowan'),('rowdy'),('rowed'),('rowel'),('rowen'),('rower'),('rowme'),('rownd'),('rowth'),('rowts'),
('royal'),('royne'),('royst'),('rozet'),('rozit'),('ruana'),('rubai'),('rubby'),('rubel'),('rubes'),('rubin'),('ruble'),
('rubus'),('ruche'),('rucks'),('rudas'),('rudds'),('ruddy'),('ruder'),('rudes'),('rudie'),('rueda'),('ruers'),('ruffe'),
('ruffs'),('rugae'),('rugal'),('rugby'),('ruggy'),('ruing'),('ruins'),('rukhs'),('ruled'),('ruler'),('rules'),('rumal'),
('rumba'),('rumbo'),('rumen'),('rumes'),('rumly'),('rummy'),('rumor'),('rumpo'),('rumps'),('rumpy'),('runch'),('runds'),
('runed'),('runes'),('rungs'),('runic'),('runny'),('runts'),('runty'),('rupee'),('rupia'),('rural'),('rurps'),('rurus'),
('rusas'),('ruses'),('rushy'),('rusks'),('rusma'),('russe'),('rusts'),('rusty'),('ruths'),('rutin'),('rutty'),('ryals'),
('rybat'),('ryked'),('rykes'),('rymme'),('rynds'),('ryots'),('ryper'),('saags'),('sabal'),('sabed'),('saber'),('sabes'),
('sabha'),('sabin'),('sabir'),('sable'),('sabot'),('sabra'),('sabre'),('sacks'),('sacra'),('saddo'),('sades'),('sadhe'),
('sadhu'),('sadis'),('sadly'),('sados'),('sadza'),('safed'),('safer'),('safes'),('sagas'),('sager'),('sages'),('saggy'),
('sagos'),('sagum'),('saheb'),('sahib'),('saice'),('saick'),('saics'),('saids'),('saiga'),('sails'),('saims'),('saine'),
('sains'),('saint'),('sairs'),('saist'),('saith'),('sajou'),('sakai'),('saker'),('sakes'),('sakia'),('sakis'),('salad'),
('salal'),('salep'),('sales'),('salet'),('salic'),('salix'),('salle'),('sally'),('salmi'),('salol'),('salon'),('salop'),
('salpa'),('salps'),('salsa'),('salse'),('salto'),('salts'),('salty'),('salue'),('salve'),('salvo'),('saman'),('samas'),
('samba'),('sambo'),('samek'),('samel'),('samen'),('sames'),('samey'),('samfu'),('sammy'),('sampi'),('samps'),('sands'),
('sandy'),('saned'),('saner'),('sanes'),('sanga'),('sangh'),('sango'),('sangs'),('sanko'),('sansa'),('santo'),('sants'),
('saola'),('sapan'),('sapid'),('sapor'),('sappy'),('saran'),('sards'),('sared'),('saree'),('sarge'),('sargo'),('sarin'),
('saris'),('sarks'),('sarky'),('sarod'),('saros'),('sarus'),('saser'),('sasin'),('sasse'),('sassy'),('satai'),('satay'),
('sated'),('satem'),('sates'),('satin'),('satis'),('satyr'),('sauba'),('sauce'),('sauch'),('saucy'),('saugh'),('sauls'),
('sault'),('sauna'),('saunt'),('saury'),('saute'),('sauts'),('saved'),('saver'),('saves'),('savey'),('savin'),('savor'),
('savoy'),('savvy'),('sawah'),('sawed'),('sawer'),('saxes'),('sayed'),('sayer'),('sayid'),('sayne'),('sayon'),('sayst'),
('sazes'),('scabs'),('scads'),('scaff'),('scags'),('scail'),('scala'),('scald'),('scale'),('scall'),('scalp'),('scaly'),
('scamp'),('scams'),('scand'),('scans'),('scant'),('scapa'),('scape'),('scapi'),('scare'),('scarf'),('scarp'),('scars'),
('scart'),('scary'),('scath'),('scats'),('scatt'),('scaud'),('scaup'),('scaur'),('scaws'),('sceat'),('scena'),('scend'),
('scene'),('scent'),('schav'),('schmo'),('schul'),('schwa'),('scion'),('sclim'),('scody'),('scoff'),('scogs'),('scold'),
('scone'),('scoog'),('scoop'),('scoot'),('scopa'),('scope'),('scops'),('score'),('scorn'),('scots'),('scoug'),('scoup'),
('scour'),('scout'),('scowl'),('scowp'),('scows'),('scrab'),('scrae'),('scrag'),('scram'),('scran'),('scrap'),('scrat'),
('scraw'),('scray'),('scree'),('screw'),('scrim'),('scrip'),('scrod'),('scrog'),('scrow'),('scrub'),('scrum'),('scuba'),
('scudi'),('scudo'),('scuds'),('scuff'),('scuft'),('scugs'),('sculk'),('scull'),('sculp'),('sculs'),('scums'),('scups'),
('scurf'),('scurs'),('scuse'),('scuta'),('scute'),('scuts'),('scuzz'),('scyes'),('sdayn'),('sdein'),('seals'),('seame'),
('seams'),('seamy'),('seans'),('seare'),('sears'),('sease'),('seats'),('seaze'),('sebum'),('secco'),('sechs'),('sects'),
('sedan'),('seder'),('sedes'),('sedge'),('sedgy'),('sedum'),('seeds'),('seedy'),('seeks'),('seeld'),('seels'),('seely'),
('seems'),('seeps'),('seepy'),('seers'),('sefer'),('segar'),('segni'),('segno'),('segol'),('segos'),('segue'),('sehri'),
('seifs'),('seils'),('seine'),('seirs'),('seise'),('seism'),('seity'),('seize'),('sekos'),('sekts'),('selah'),('seles'),
('selfs'),('sella'),('selle'),('sells'),('selva'),('semee'),('semes'),('semie'),('semis'),('senas'),('sends'),('senes'),
('sengi'),('senna'),('senor'),('sensa'),('sense'),('sensi'),('sente'),('senti'),('sents'),('senvy'),('senza'),('sepad'),
('sepal'),('sepia'),('sepic'),('sepoy'),('septa'),('septs'),('serac'),('serai'),('seral'),('sered'),('serer'),('seres'),
('serfs'),('serge'),('seric'),('serif'),('serin'),('serks'),('seron'),('serow'),('serra'),('serre'),('serrs'),('serry'),
('serum'),('serve'),('servo'),('sesey'),('sessa'),('setae'),('setal'),('seton'),('setts'),('setup'),('seven'),('sever'),
('sewan'),('sewar'),('sewed'),('sewel'),('sewen'),('sewer'),('sewin'),('sexed'),('sexer'),('sexes'),('sexto'),('sexts'),
('seyen'),('shack'),('shade'),('shads'),('shady'),('shaft'),('shags'),('shahs'),('shake'),('shako'),('shakt'),('shaky'),
('shale'),('shall'),('shalm'),('shalt'),('shaly'),('shama'),('shame'),('shams'),('shand'),('shank'),('shans'),('shape'),
('shaps'),('shard'),('share'),('shark'),('sharn'),('sharp'),('shart'),('shash'),('shaul'),('shave'),('shawl'),('shawm'),
('shawn'),('shaws'),('shaya'),('shays'),('shchi'),('sheaf'),('sheal'),('shear'),('sheas'),('sheds'),('sheel'),('sheen'),
('sheep'),('sheer'),('sheet'),('sheik'),('shelf'),('shell'),('shend'),('shent'),('sheol'),('sherd'),('shere'),('shets'),
('sheva'),('shewn'),('shews'),('shiai'),('shied'),('shiel'),('shier'),('shies'),('shift'),('shill'),('shily'),('shims'),
('shine'),('shins'),('shiny'),('ships'),('shire'),('shirk'),('shirr'),('shirs'),('shirt'),('shish'),('shiso'),('shist'),
('shiur'),('shiva'),('shive'),('shivs'),('shlep'),('shlub'),('shmek'),('shoal'),('shoat'),('shock'),('shoed'),('shoer'),
('shoes'),('shogi'),('shogs'),('shoji'),('shola'),('shone'),('shook'),('shool'),('shoon'),('shoos'),('shoot'),('shope'),
('shops'),('shore'),('shorl'),('shorn'),('short'),('shote'),('shots'),('shott'),('shout'),('shove'),('showd'),('shown'),
('shows'),('showy'),('shoyu'),('shred'),('shrew'),('shris'),('shrow'),('shrub'),('shrug'),('shtik'),('shtum'),('shtup'),
('shuck'),('shule'),('shuln'),('shuls'),('shuns'),('shunt'),('shura'),('shush'),('shute'),('shuts'),('shwas'),('shyer'),
('shyly'),('sials'),('sibbs'),('sibyl'),('sices'),('sicht'),('sicko'),('sicks'),('sidas'),('sided'),('sider'),('sides'),
('sidha'),('sidhe'),('sidle'),('siege'),('sield'),('siens'),('sient'),('sieth'),('sieur'),('sieve'),('sifts'),('sighs'),
('sight'),('sigil'),('sigla'),('sigma'),('signa'),('signs'),('sijos'),('sikas'),('siker'),('sikes'),('silds'),('siled'),
('silen'),('siler'),('siles'),('silex'),('silks'),('silky'),('sills'),('silly'),('silos'),('silts'),('silty'),('silva'),
('simar'),('simas'),('simba'),('simis'),('simps'),('simul'),('since'),('sinds'),('sined'),('sines'),('sinew'),('singe'),
('sings'),('sinhs'),('sinks'),('sinky'),('sinus'),('siped'),('sipes'),('sippy'),('sired'),('siree'),('siren'),('sires'),
('sirih'),('siris'),('siroc'),('sirra'),('sirup'),('sisal'),('sises'),('sissy'),('sists'),('sitar'),('sited'),('sites'),
('sithe'),('sitka'),('situp'),('situs'),('siver'),('sixer'),('sixes'),('sixmo'),('sixte'),('sixth'),('sixty'),('sizar'),
('sized'),('sizel'),('sizer'),('sizes'),('skags'),('skail'),('skald'),('skart'),('skate'),('skats'),('skatt'),('skaws'),
('skean'),('skear'),('skeed'),('skeef'),('skeen'),('skeer'),('skees'),('skegg'),('skegs'),('skein'),('skelf'),('skell'),
('skelm'),('skelp'),('skene'),('skens'),('skeos'),('skeps'),('skers'),('skets'),('skews'),('skids'),('skied'),('skier'),
('skies'),('skiey'),('skiff'),('skill'),('skimo'),('skimp'),('skims'),('skink'),('skins'),('skint'),('skios'),('skips'),
('skirl'),('skirr'),('skirt'),('skite'),('skits'),('skive'),('skivy'),('sklim'),('skoal'),('skoff'),('skols'),('skool'),
('skort'),('skosh'),('skran'),('skrik'),('skuas'),('skugs'),('skulk'),('skull'),('skunk'),('skyed'),('skyer'),('skyey'),
('skyfs'),('skyre'),('skyrs'),('skyte'),('slabs'),('slack'),('slade'),('slaes'),('slags'),('slaid'),('slain'),('slake'),
('slams'),('slane'),('slang'),('slank'),('slant'),('slaps'),('slart'),('slash'),('slate'),('slats'),('slaty'),('slave'),
('slaws'),('slays'),('slebs'),('sleds'),('sleek'),('sleep'),('sleer'),('sleet'),('slept'),('slews'),('sleys'),('slice'),
('slick'),('slide'),('slier'),('slily'),('slime'),('slims'),('slimy'),('sling'),('slink'),('slipe'),('slips'),('slipt'),
('slish'),('slits'),('slive'),('sloan'),('slobs'),('sloes'),('slogs'),('sloid'),('slojd'),('sloom'),('sloop'),('sloot'),
('slope'),('slops'),('slopy'),('slorm'),('slosh'),('sloth'),('slots'),('slove'),('slows'),('sloyd'),('slubb'),('slubs'),
('slued'),('slues'),('sluff'),('slugs'),('sluit'),('slump'),('slums'),('slung'),('slunk'),('slurb'),('slurp'),('slurs'),
('sluse'),('slush'),('slyer'),('slyly'),('slype'),('smaak'),('smack'),('smaik'),('small'),('smalm'),('smalt'),('smarm'),
('smart'),('smash'),('smaze'),('smear'),('smeek'),('smees'),('smeik'),('smeke'),('smell'),('smelt'),('smerk'),('smews'),
('smile'),('smirk'),('smirr'),('smirs'),('smite'),('smith'),('smits'),('smock'),('smogs'),('smoke'),('smoko'),('smoky'),
('smolt'),('smoor'),('smoot'),('smore'),('smote'),('smout'),('smowt'),('smugs'),('smurs'),('smush'),('smuts'),('snabs'),
('snack'),('snafu'),('snags'),('snail'),('snake'),('snaky'),('snaps'),('snare'),('snarf'),('snark'),('snarl'),('snars'),
('snary'),('snash'),('snath'),('snaws'),('snead'),('sneak'),('sneap'),('snebs'),('sneck'),('sneds'),('sneed'),('sneer'),
('snees'),('snell'),('snibs'),('snick'),('snide'),('snies'),('sniff'),('snift'),('snigs'),('snipe'),('snips'),('snipy'),
('snirt'),('snits'),('snobs'),('snods'),('snoek'),('snoep'),('snogs'),('snoke'),('snood'),('snook'),('snool'),('snoop'),
('snoot'),('snore'),('snort'),('snots'),('snout'),('snowk'),('snows'),('snowy'),('snubs'),('snuck'),('snuff'),('snugs'),
('snush'),('snyes'),('soaks'),('soaps'),('soapy'),('soare'),('soars'),('soave'),('sobas'),('sober'),('socas'),('socko'),
('socks'),('socle'),('sodas'),('soddy'),('sodic'),('sodom'),('sofar'),('sofas'),('softa'),('softs'),('softy'),('soger'),
('soggy'),('sohur'),('soils'),('soily'),('sojas'),('sokah'),('soken'),('sokes'),('sokol'),('solah'),('solan'),('solar'),
('solas'),('solde'),('soldi'),('soldo'),('solds'),('soled'),('solei'),('soler'),('soles'),('solid'),('solon'),('solos'),
('solum'),('solus'),('solve'),('soman'),('somas'),('sonar'),('sonce'),('sonde'),('sones'),('songs'),('sonic'),('sonly'),
('sonne'),('sonny'),('sonse'),('sonsy'),('sooey'),('sooks'),('soole'),('sools'),('sooms'),('soops'),('soote'),('sooth'),
('soots'),('sooty'),('sophs'),('sophy'),('sopor'),('soppy'),('sopra'),('soral'),('soras'),('sorbo'),('sorbs'),('sorda'),
('sordo'),('sords'),('sored'),('soree'),('sorel'),('sorer'),('sores'),('sorex'),('sorgo'),('sorns'),('sorra'),('sorry'),
('sorta'),('sorts'),('sorus'),('soths'),('sotol'),('souce'),('souct'),('sough'),('souks'),('souls'),('soums'),('sound'),
('soups'),('soupy'),('sours'),('souse'),('south'),('souts'),('sowar'),('sowce'),('sowed'),('sower'),('sowff'),('sowfs'),
('sowle'),('sowls'),('sowms'),('sownd'),('sowne'),('sowps'),('sowse'),('sowth'),('soyas'),('soyle'),('soyuz'),('sozin'),
('space'),('spacy'),('spade'),('spado'),('spaed'),('spaer'),('spaes'),('spags'),('spahi'),('spail'),('spain'),('spait'),
('spake'),('spald'),('spale'),('spall'),('spalt'),('spams'),('spane'),('spang'),('spank'),('spans'),('spard'),('spare'),
('spark'),('spars'),('spart'),('spasm'),('spate'),('spats'),('spaul'),('spawl'),('spawn'),('spaws'),('spayd'),('spays'),
('speak'),('speal'),('spean'),('spear'),('speat'),('speck'),('specs'),('speed'),('speel'),('speer'),('speil'),('speir'),
('speks'),('speld'),('spelk'),('spell'),('spelt'),('spend'),('spent'),('speos'),('sperm'),('spets'),('speug'),('spews'),
('spewy'),('spial'),('spica'),('spice'),('spick'),('spics'),('spicy'),('spide'),('spied'),('spiel'),('spier'),('spies'),
('spiff'),('spifs'),('spike'),('spiks'),('spiky'),('spile'),('spill'),('spilt'),('spims'),('spina'),('spine'),('spink'),
('spins'),('spiny'),('spire'),('spirt'),('spiry'),('spite'),('spits'),('spitz'),('spivs'),('splat'),('splay'),('split'),
('splog'),('spode'),('spods'),('spoil'),('spoke'),('spoof'),('spook'),('spool'),('spoom'),('spoon'),('spoor'),('spoot'),
('spore'),('spork'),('sport'),('sposh'),('spots'),('spout'),('sprad'),('sprag'),('sprat'),('spray'),('spred'),('spree'),
('sprew'),('sprig'),('sprit'),('sprod'),('sprog'),('sprue'),('sprug'),('spuds'),('spued'),('spuer'),('spues'),('spugs'),
('spule'),('spume'),('spumy'),('spurn'),('spurs'),('spurt'),('sputa'),('spyal'),('spyre'),('squab'),('squad'),('squat'),
('squaw'),('squeg'),('squib'),('squid'),('squit'),('squiz'),('stabs'),('stack'),('stade'),('staff'),('stage'),('stags'),
('stagy'),('staid'),('staig'),('stain'),('stair'),('stake'),('stale'),('stalk'),('stall'),('stamp'),('stand'),('stane'),
('stang'),('stank'),('staph'),('staps'),('stare'),('stark'),('starn'),('starr'),('stars'),('start'),('stash'),('state'),
('stats'),('staun'),('stave'),('staws'),('stays'),('stead'),('steak'),('steal'),('steam'),('stean'),('stear'),('stedd'),
('stede'),('steds'),('steed'),('steek'),('steel'),('steem'),('steen'),('steep'),('steer'),('steil'),('stein'),('stela'),
('stele'),('stell'),('steme'),('stems'),('stend'),('steno'),('stens'),('stent'),('steps'),('stept'),('stere'),('stern'),
('stets'),('stews'),('stewy'),('stich'),('stick'),('stied'),('sties'),('stiff'),('stilb'),('stile'),('still'),('stilt'),
('stime'),('stims'),('stimy'),('sting'),('stink'),('stint'),('stipa'),('stipe'),('stire'),('stirk'),('stirp'),('stirs'),
('stive'),('stivy'),('stoae'),('stoai'),('stoas'),('stoat'),('stobs'),('stock'),('stoep'),('stogy'),('stoic'),('stoit'),
('stoke'),('stole'),('stoln'),('stoma'),('stomp'),('stond'),('stone'),('stong'),('stonk'),('stonn'),('stony'),('stood'),
('stook'),('stool'),('stoop'),('stoor'),('stope'),('stops'),('stopt'),('store'),('stork'),('storm'),('story'),('stoss'),
('stots'),('stott'),('stoun'),('stoup'),('stour'),('stout'),('stove'),('stown'),('stowp'),('stows'),('strad'),('strae'),
('strag'),('strak'),('strap'),('straw'),('stray'),('strep'),('strew'),('stria'),('strig'),('strim'),('strip'),('strop'),
('strow'),('stroy'),('strum'),('strut'),('stubs'),('stuck'),('stude'),('studs'),('study'),('stuff'),('stull'),('stulm'),
('stumm'),('stump'),('stums'),('stung'),('stunk'),('stuns'),('stunt'),('stupa'),('stupe'),('sture'),('sturt'),('styed'),
('styes'),('style'),('styli'),('stylo'),('styme'),('stymy'),('styre'),('styte'),('suave'),('subah'),('subas'),('subby'),
('suber'),('subha'),('succi'),('sucre'),('sudds'),('sudor'),('sudsy'),('suede'),('suent'),('suers'),('suets'),('suety'),
('sugan'),('sugar'),('sughs'),('sugos'),('suhur'),('suids'),('suing'),('suint'),('suite'),('suits'),('sujee'),('sukhs'),
('sukuk'),('sulci'),('sulfa'),('sulfo'),('sulks'),('sulky'),('sully'),('sulph'),('sulus'),('sumac'),('summa'),('sumos'),
('sumph'),('sumps'),('sunis'),('sunks'),('sunna'),('sunns'),('sunny'),('sunup'),('super'),('supes'),('supra'),('surah'),
('sural'),('suras'),('surat'),('surds'),('sured'),('surer'),('sures'),('surfs'),('surfy'),('surge'),('surgy'),('surly'),
('surra'),('suses'),('sushi'),('susus'),('sutor'),('sutra'),('sutta'),('swabs'),('swack'),('swads'),('swage'),('swags'),
('swail'),('swain'),('swale'),('swaly'),('swami'),('swamp'),('swamy'),('swang'),('swank'),('swans'),('swaps'),('swapt'),
('sward'),('sware'),('swarf'),('swarm'),('swart'),('swash'),('swath'),('swats'),('swayl'),('sways'),('sweal'),('swear'),
('sweat'),('swede'),('sweed'),('sweel'),('sweep'),('sweer'),('swees'),('sweet'),('sweir'),('swell'),('swelt'),('swept'),
('swerf'),('sweys'),('swies'),('swift'),('swigs'),('swill'),('swims'),('swine'),('swing'),('swink'),('swipe'),('swire'),
('swirl'),('swish'),('swiss'),('swith'),('swits'),('swive'),('swizz'),('swobs'),('swoln'),('swoon'),('swoop'),('swops'),
('swopt'),('sword'),('swore'),('sworn'),('swots'),('swoun'),('swung'),('sybbe'),('sybil'),('syboe'),('sybow'),('sycee'),
('syces'),('syens'),('syker'),('sykes'),('sylis'),('sylph'),('sylva'),('symar'),('synch'),('syncs'),('synds'),('syned'),
('synes'),('synod'),('synth'),('syped'),('sypes'),('syphs'),('syrah'),('syren'),('syrup'),('sysop'),('sythe'),('syver'),
('taals'),('taata'),('tabby'),('taber'),('tabes'),('tabid'),('tabla'),('table'),('taboo'),('tabor'),('tabun'),('tabus'),
('tacan'),('taces'),('tacet'),('tache'),('tacho'),('tachs'),('tacit'),('tacks'),('tacky'),('tacos'),('tacts'),('taels'),
('taffy'),('tafia'),('taggy'),('tagma'),('tahas'),('tahrs'),('taiga'),('taigs'),('taiko'),('tails'),('tains'),('taint'),
('taira'),('taish'),('taits'),('tajes'),('takas'),('taken'),('taker'),('takes'),('takhi'),('takin'),('takis'),('talak'),
('talaq'),('talar'),('talas'),('talcs'),('talcy'),('talea'),('taler'),('tales'),('talks'),('talky'),('talls'),('tally'),
('talma'),('talon'),('talpa'),('taluk'),('talus'),('tamal'),('tamed'),('tamer'),('tames'),('tamin'),('tamis'),('tammy'),
('tamps'),('tanas'),('tanga'),('tangi'),('tango'),('tangs'),('tangy'),('tanhs'),('tanka'),('tanks'),('tanky'),('tanna'),
('tansy'),('tanti'),('tanto'),('tapas'),('taped'),('tapen'),('taper'),('tapes'),('tapet'),('tapir'),('tapis'),('tappa'),
('tapus'),('taras'),('tardo'),('tardy'),('tared'),('tares'),('targa'),('targe'),('tarns'),('taroc'),('tarok'),('taros'),
('tarot'),('tarps'),('tarre'),('tarry'),('tarsi'),('tarts'),('tarty'),('tasar'),('taser'),('tasks'),('tasse'),('taste'),
('tasty'),('tatar'),('tater'),('tates'),('taths'),('tatie'),('tatou'),('tatts'),('tatty'),('tatus'),('taube'),('tauld'),
('taunt'),('tauon'),('taupe'),('tauts'),('tavah'),('tavas'),('taver'),('tawai'),('tawas'),('tawed'),('tawer'),('tawie'),
('tawny'),('tawse'),('tawts'),('taxed'),('taxer'),('taxes'),('taxis'),('taxol'),('taxon'),('taxor'),('taxus'),('tayra'),
('tazza'),('tazze'),('teach'),('teade'),('teads'),('teaed'),('teaks'),('teals'),('teams'),('tears'),('teary'),('tease'),
('teats'),('teaze'),('techs'),('techy'),('tecta'),('teddy'),('teels'),('teems'),('teend'),('teene'),('teens'),('teeny'),
('teers'),('teeth'),('teffs'),('teggs'),('tegua'),('tegus'),('tehrs'),('teiid'),('teils'),('teind'),('teins'),('telae'),
('telco'),('teles'),('telex'),('telia'),('telic'),('tells'),('telly'),('teloi'),('telos'),('temed'),('temes'),('tempi'),
('tempo'),('temps'),('tempt'),('temse'),('tench'),('tends'),('tendu'),('tenes'),('tenet'),('tenge'),('tenia'),('tenne'),
('tenno'),('tenny'),('tenon'),('tenor'),('tense'),('tenth'),('tents'),('tenty'),('tenue'),('tepal'),('tepas'),('tepee'),
('tepid'),('tepoy'),('terai'),('teras'),('terce'),('terek'),('teres'),('terfe'),('terfs'),('terga'),('terms'),('terne'),
('terns'),('terra'),('terry'),('terse'),('terts'),('tesla'),('testa'),('teste'),('tests'),('testy'),('tetes'),('teths'),
('tetra'),('tetri'),('teuch'),('teugh'),('tewed'),('tewel'),('tewit'),('texas'),('texes'),('texts'),('thack'),('thagi'),
('thaim'),('thale'),('thali'),('thana'),('thane'),('thang'),('thank'),('thans'),('tharm'),('thars'),('thaws'),('thawy'),
('thebe'),('theca'),('theed'),('theek'),('thees'),('theft'),('thegn'),('theic'),('thein'),('their'),('thelf'),('thema'),
('theme'),('thens'),('theow'),('there'),('therm'),('these'),('thesp'),('theta'),('thete'),('thews'),('thewy'),('thick'),
('thief'),('thigh'),('thigs'),('thilk'),('thill'),('thine'),('thing'),('think'),('thins'),('thiol'),('third'),('thirl'),
('thoft'),('thole'),('tholi'),('thong'),('thorn'),('thoro'),('thorp'),('those'),('thous'),('thowl'),('thrae'),('thraw'),
('three'),('threw'),('thrid'),('thrip'),('throb'),('throe'),('throw'),('thrum'),('thuds'),('thugs'),('thuja'),('thumb'),
('thump'),('thunk'),('thurl'),('thuya'),('thyme'),('thymi'),('thymy'),('tians'),('tiara'),('tiars'),('tibia'),('tical'),
('ticca'),('ticed'),('tices'),('tichy'),('ticks'),('ticky'),('tidal'),('tiddy'),('tided'),('tides'),('tiers'),('tiffs'),
('tifts'),('tiger'),('tiges'),('tight'),('tigon'),('tikas'),('tikes'),('tikis'),('tikka'),('tilak'),('tilde'),('tiled'),
('tiler'),('tiles'),('tills'),('tilly'),('tilth'),('tilts'),('timbo'),('timed'),('timer'),('times'),('timid'),('timon'),
('timps'),('tinas'),('tinct'),('tinds'),('tinea'),('tined'),('tines'),('tinge'),('tings'),('tinks'),('tinny'),('tints'),
('tinty'),('tipis'),('tippy'),('tipsy'),('tired'),('tires'),('tirls'),('tiros'),('tirrs'),('titan'),('titch'),('titer'),
('tithe'),('titis'),('title'),('titre'),('titup'),('tiyin'),('tizzy'),('toads'),('toady'),('toast'),('toaze'),('tocks'),
('tocky'),('tocos'),('today'),('todde'),('toddy'),('toeas'),('toffs'),('toffy'),('tofts'),('tofus'),('togae'),('togas'),
('toged'),('toges'),('togue'),('toile'),('toils'),('toing'),('toise'),('toits'),('tokay'),('toked'),('token'),('toker'),
('tokes'),('tokos'),('tolan'),('tolar'),('tolas'),('toled'),('toles'),('tolls'),('tolly'),('tolts'),('tolus'),('tolyl'),
('toman'),('tombs'),('tomes'),('tomia'),('tommy'),('tomos'),('tonal'),('tondi'),('tondo'),('toned'),('toner'),('tones'),
('toney'),('tonga'),('tongs'),('tonic'),('tonka'),('tonks'),('tonne'),('tonus'),('tools'),('tooms'),('toons'),('tooth'),
('toots'),('topaz'),('toped'),('topee'),('topek'),('toper'),('topes'),('tophe'),('tophi'),('tophs'),('topic'),('topis'),
('topoi'),('topos'),('toppy'),('toque'),('torah'),('toran'),('toras'),('torch'),('torcs'),('tores'),('toric'),('torii'),
('toros'),('torot'),('torrs'),('torse'),('torsi'),('torsk'),('torso'),('torta'),('torte'),('torts'),('torus'),('tosas'),
('tosed'),('toses'),('toshy'),('tossy'),('total'),('toted'),('totem'),('toter'),('totes'),('totty'),('touch'),('tough'),
('touks'),('touns'),('tours'),('touse'),('tousy'),('touts'),('touze'),('touzy'),('towed'),('towel'),('tower'),('towie'),
('towns'),('towny'),('towse'),('towsy'),('towts'),('towze'),('towzy'),('toxic'),('toxin'),('toyed'),('toyer'),('toyon'),
('toyos'),('tozed'),('tozes'),('tozie'),('trabs'),('trace'),('track'),('tract'),('trade'),('trads'),('tragi'),('traik'),
('trail'),('train'),('trait'),('tramp'),('trams'),('trank'),('tranq'),('trans'),('trant'),('trape'),('traps'),('trapt'),
('trash'),('trass'),('trats'),('tratt'),('trave'),('trawl'),('trays'),('tread'),('treat'),('treck'),('treed'),('treen'),
('trees'),('trefa'),('treif'),('treks'),('trema'),('trend'),('tress'),('trest'),('trets'),('trews'),('treys'),('triac'),
('triad'),('trial'),('tribe'),('trice'),('trick'),('tride'),('tried'),('trier'),('tries'),('triff'),('trigo'),('trigs'),
('trike'),('trild'),('trill'),('trims'),('trine'),('trins'),('triol'),('trior'),('trios'),('tripe'),('trips'),('tripy'),
('trist'),('trite'),('troad'),('troak'),('troat'),('trock'),('trode'),('trods'),('trogs'),('trois'),('troke'),('troll'),
('tromp'),('trona'),('tronc'),('trone'),('tronk'),('trons'),('troop'),('trooz'),('trope'),('troth'),('trots'),('trout'),
('trove'),('trows'),('troys'),('truce'),('truck'),('trued'),('truer'),('trues'),('trugo'),('trugs'),('trull'),('truly'),
('trump'),('trunk'),('truss'),('trust'),('truth'),('tryer'),('tryke'),('tryma'),('tryps'),('tryst'),('tsade'),('tsadi'),
('tsars'),('tsked'),('tsuba'),('tuans'),('tuart'),('tuath'),('tubae'),('tubal'),('tubar'),('tubas'),('tubby'),('tubed'),
('tuber'),('tubes'),('tucks'),('tufas'),('tuffe'),('tuffs'),('tufts'),('tufty'),('tugra'),('tuina'),('tuism'),('tuktu'),
('tules'),('tulip'),('tulle'),('tulpa'),('tumid'),('tummy'),('tumor'),('tumps'),('tumpy'),('tunas'),('tunds'),('tuned'),
('tuner'),('tunes'),('tungs'),('tunic'),('tunny'),('tupek'),('tupik'),('tuple'),('tuque'),('turbo'),('turds'),('turfs'),
('turfy'),('turks'),('turme'),('turms'),('turns'),('turps'),('tusks'),('tusky'),('tutee'),('tutor'),('tutti'),('tutty'),
('tutus'),('tuxes'),('tuyer'),('twaes'),('twain'),('twals'),('twang'),('twank'),('tways'),('tweak'),('tweed'),('tweel'),
('tween'),('tweer'),('tweet'),('twerk'),('twerp'),('twice'),('twier'),('twigs'),('twill'),('twilt'),('twine'),('twins'),
('twiny'),('twire'),('twirl'),('twirp'),('twist'),('twite'),('twits'),('twixt'),('twoer'),('twyer'),('tyees'),('tyers'),
('tying'),('tyiyn'),('tykes'),('tyler'),('tymps'),('tynde'),('tyned'),('tynes'),('typal'),('typed'),('types'),('typey'),
('typic'),('typos'),('typps'),('typto'),('tyran'),('tyred'),('tyres'),('tyros'),('tythe'),('tzars'),('udals'),('udder'),
('udons'),('ugali'),('ugged'),('uhlan'),('uhuru'),('ukase'),('ulama'),('ulans'),('ulcer'),('ulema'),('ulmin'),('ulnad'),
('ulnae'),('ulnar'),('ulnas'),('ulpan'),('ultra'),('ulvas'),('ulyie'),('ulzie'),('umami'),('umbel'),('umber'),('umble'),
('umbos'),('umbra'),('umbre'),('umiac'),('umiak'),('umiaq'),('ummah'),('ummas'),('ummed'),('umped'),('umpie'),('umpty'),
('umrah'),('umras'),('unais'),('unapt'),('unarm'),('unary'),('unaus'),('unbag'),('unban'),('unbar'),('unbed'),('unbid'),
('unbox'),('uncap'),('unces'),('uncia'),('uncle'),('uncos'),('uncoy'),('uncus'),('uncut'),('undam'),('undee'),('under'),
('undid'),('undue'),('undug'),('uneth'),('unfed'),('unfit'),('unfix'),('ungag'),('unget'),('ungod'),('ungot'),('ungum'),
('unhat'),('unhip'),('unify'),('union'),('unite'),('units'),('unity'),('unjam'),('unked'),('unket'),('unkid'),('unlaw'),
('unlay'),('unled'),('unlet'),('unlid'),('unlit'),('unman'),('unmet'),('unmew'),('unmix'),('unpay'),('unpeg'),('unpen'),
('unpin'),('unred'),('unrid'),('unrig'),('unrip'),('unsay'),('unset'),('unsew'),('unsex'),('unsod'),('untax'),('untie'),
('until'),('untin'),('unwed'),('unwet'),('unwit'),('unwon'),('unzip'),('upbow'),('upbye'),('updos'),('updry'),('upend'),
('upjet'),('uplay'),('upled'),('uplit'),('upped'),('upper'),('upran'),('uprun'),('upsee'),('upset'),('upsey'),('uptak'),
('upter'),('uptie'),('uraei'),('urali'),('uraos'),('urare'),('urari'),('urase'),('urate'),('urban'),('urbia'),('urdee'),
('ureal'),('ureas'),('uredo'),('ureic'),('urena'),('urent'),('urged'),('urger'),('urges'),('urial'),('urine'),('urite'),
('urman'),('urnal'),('urned'),('urped'),('ursae'),('ursid'),('urson'),('urubu'),('urvas'),('usage'),('users'),('usher'),
('using'),('usnea'),('usque'),('usual'),('usure'),('usurp'),('usury'),('uteri'),('utile'),('utter'),('uveal'),('uveas'),
('uvula'),('vacua'),('vaded'),('vades'),('vagal'),('vague'),('vagus'),('vails'),('vaire'),('vairs'),('vairy'),('vakas'),
('vakil'),('vales'),('valet'),('valid'),('valis'),('valor'),('valse'),('value'),('valve'),('vamps'),('vampy'),('vanda'),
('vaned'),('vanes'),('vangs'),('vants'),('vapid'),('vapor'),('varan'),('varas'),('vardy'),('varec'),('vares'),('varia'),
('varix'),('varna'),('varus'),('varve'),('vasal'),('vases'),('vasts'),('vasty'),('vatic'),('vatus'),('vauch'),('vault'),
('vaunt'),('vaute'),('vauts'),('vawte'),('veale'),('veals'),('vealy'),('veena'),('veeps'),('veers'),('veery'),('vegan'),
('vegas'),('veges'),('vegie'),('vegos'),('vehme'),('veils'),('veily'),('veins'),('veiny'),('velar'),('velds'),('veldt'),
('veles'),('vells'),('velum'),('venae'),('venal'),('vends'),('veney'),('venge'),('venin'),('venom'),('vents'),('venue'),
('venus'),('verbs'),('verge'),('verra'),('verry'),('verse'),('verso'),('verst'),('verts'),('vertu'),('verve'),('vespa'),
('vesta'),('vests'),('vetch'),('vexed'),('vexer'),('vexes'),('vexil'),('vezir'),('vials'),('viand'),('vibes'),('vibex'),
('vibey'),('vicar'),('viced'),('vices'),('vichy'),('video'),('viers'),('views'),('viewy'),('vifda'),('vigas'),('vigia'),
('vigil'),('vigor'),('vilde'),('viler'),('villa'),('villi'),('vills'),('vimen'),('vinal'),('vinas'),('vinca'),('vined'),
('viner'),('vines'),('vinew'),('vinic'),('vinos'),('vints'),('vinyl'),('viola'),('viold'),('viols'),('viper'),('viral'),
('vired'),('vireo'),('vires'),('virga'),('virge'),('virid'),('virls'),('virtu'),('virus'),('visas'),('vised'),('vises'),
('visie'),('visit'),('visne'),('vison'),('visor'),('vista'),('visto'),('vitae'),('vital'),('vitas'),('vitex'),('vitta'),
('vivas'),('vivat'),('vivda'),('viver'),('vives'),('vivid'),('vixen'),('vizir'),('vizor'),('vleis'),('vlies'),('vlogs'),
('voars'),('vocab'),('vocal'),('voces'),('voddy'),('vodka'),('vodou'),('vodun'),('voema'),('vogie'),('vogue'),('voice'),
('voids'),('voila'),('voile'),('voips'),('volae'),('volar'),('voled'),('voles'),('volet'),('volks'),('volta'),('volte'),
('volti'),('volts'),('volva'),('volve'),('vomer'),('vomit'),('voted'),('voter'),('votes'),('vouch'),('vouge'),('voulu'),
('vowed'),('vowel'),('vower'),('voxel'),('vozhd'),('vraic'),('vrils'),('vroom'),('vrous'),('vrouw'),('vrows'),('vuggs'),
('vuggy'),('vughs'),('vughy'),('vulgo'),('vulns'),('vutty'),('vying'),('waacs'),('wacke'),('wacko'),('wacks'),('wacky'),
('wadds'),('waddy'),('waded'),('wader'),('wades'),('wadis'),('wadts'),('wafer'),('waffs'),('wafts'),('waged'),('wager'),
('wages'),('wagga'),('wagon'),('wagyu'),('wahoo'),('waide'),('waifs'),('waift'),('wails'),('wains'),('wairs'),('waist'),
('waite'),('waits'),('waive'),('wakas'),('waked'),('waken'),('waker'),('wakes'),('wakfs'),('waldo'),('walds'),('waled'),
('waler'),('wales'),('walis'),('walks'),('walla'),('walls'),('wally'),('walty'),('waltz'),('wamed'),('wames'),('wamus'),
('wands'),('waned'),('wanes'),('waney'),('wangs'),('wanle'),('wanly'),('wanna'),('wants'),('wanty'),('wanze'),('waqfs'),
('warbs'),('warby'),('wards'),('wared'),('wares'),('warez'),('warks'),('warms'),('warns'),('warps'),('warre'),('warst'),
('warts'),('warty'),('wases'),('washy'),('wasps'),('waspy'),('waste'),('wasts'),('watap'),('watch'),('water'),('watts'),
('wauff'),('waugh'),('wauks'),('waulk'),('wauls'),('waurs'),('waved'),('waver'),('waves'),('wavey'),('wawas'),('wawes'),
('wawls'),('waxed'),('waxen'),('waxer'),('waxes'),('wayed'),('wazir'),('wazoo'),('weald'),('weals'),('weamb'),('weans'),
('wears'),('weary'),('weave'),('webby'),('weber'),('wecht'),('wedel'),('wedge'),('wedgy'),('weeds'),('weedy'),('weeke'),
('weeks'),('weels'),('weems'),('weens'),('weeny'),('weeps'),('weepy'),('weest'),('weete'),('weets'),('wefte'),('wefts'),
('weids'),('weigh'),('weils'),('weird'),('weirs'),('weise'),('weize'),('wekas'),('welch'),('welds'),('welke'),('welks'),
('welkt'),('wells'),('welly'),('welsh'),('welts'),('wembs'),('wench'),('wends'),('wenge'),('wenny'),('wents'),('weros'),
('wersh'),('wests'),('wetas'),('wetly'),('wexed'),('wexes'),('whack'),('whale'),('whamo'),('whams'),('whang'),('whaps'),
('whare'),('wharf'),('whata'),('whats'),('whaup'),('whaur'),('wheal'),('whear'),('wheat'),('wheel'),('wheen'),('wheep'),
('wheft'),('whelk'),('whelm'),('whelp'),('whens'),('where'),('whets'),('whews'),('wheys'),('which'),('whids'),('whiff'),
('whift'),('whigs'),('while'),('whilk'),('whims'),('whine'),('whins'),('whiny'),('whios'),('whips'),('whipt'),('whirl'),
('whirr'),('whirs'),('whish'),('whisk'),('whiss'),('whist'),('white'),('whits'),('whity'),('whizz'),('whole'),('whomp'),
('whoof'),('whoop'),('whoot'),('whops'),('whorl'),('whort'),('whose'),('whoso'),('whump'),('whups'),('wicca'),('wicks'),
('wicky'),('widdy'),('widen'),('wider'),('wides'),('widow'),('width'),('wield'),('wiels'),('wifed'),('wifes'),('wifey'),
('wifie'),('wifty'),('wigan'),('wigga'),('wiggy'),('wight'),('wikis'),('wilco'),('wilds'),('wiled'),('wiles'),('wilga'),
('wilis'),('wilja'),('wills'),('wilts'),('wimps'),('wimpy'),('wince'),('winch'),('winds'),('windy'),('wined'),('wines'),
('winey'),('winge'),('wings'),('wingy'),('winks'),('winna'),('winns'),('winos'),('winze'),('wiped'),('wiper'),('wipes'),
('wired'),('wirer'),('wires'),('wirra'),('wised'),('wiser'),('wises'),('wisha'),('wisht'),('wisps'),('wispy'),('wists'),
('witan'),('witch'),('wited'),('wites'),('withe'),('withs'),('withy'),('witty'),('wived'),('wiver'),('wives'),('wizen'),
('wizes'),('woads'),('woald'),('wocks'),('wodge'),('woful'),('woken'),('wokka'),('wolds'),('wolfs'),('wolly'),('wolve'),
('woman'),('wombs'),('womby'),('women'),('womyn'),('wonga'),('wongi'),('wonks'),('wonky'),('wonts'),('woods'),('woody'),
('wooed'),('wooer'),('woofs'),('woofy'),('woold'),('wools'),('wooly'),('woons'),('woops'),('woose'),('woosh'),('wootz'),
('woozy'),('words'),('wordy'),('works'),('world'),('worms'),('wormy'),('worry'),('worse'),('worst'),('worth'),('worts'),
('would'),('wound'),('woven'),('wowed'),('wowee'),('woxen'),('wrack'),('wrang'),('wraps'),('wrapt'),('wrast'),('wrate'),
('wrath'),('wrawl'),('wreak'),('wreck'),('wrens'),('wrest'),('wrick'),('wried'),('wrier'),('wries'),('wring'),('wrist'),
('write'),('writs'),('wroke'),('wrong'),('wroot'),('wrote'),('wroth'),('wrung'),('wryer'),('wryly'),('wudus'),('wulls'),
('wurst'),('wuses'),('wushu'),('wussy'),('wuxia'),('wyled'),('wyles'),('wynds'),('wynns'),('wyted'),('wytes'),('xebec'),
('xenia'),('xenic'),('xenon'),('xeric'),('xerox'),('xerus'),('xoana'),('xrays'),('xylan'),('xylem'),('xylic'),('xylol'),
('xylyl'),('xysti'),('xysts'),('yaars'),('yabas'),('yabba'),('yabby'),('yacca'),('yacht'),('yacka'),('yacks'),('yaffs'),
('yager'),('yagis'),('yahoo'),('yaird'),('yakka'),('yakow'),('yales'),('yamen'),('yampy'),('yamun'),('yangs'),('yanks'),
('yapok'),('yapon'),('yapps'),('yappy'),('yarco'),('yards'),('yarer'),('yarfa'),('yarks'),('yarns'),('yarrs'),('yarta'),
('yarto'),('yates'),('yauds'),('yauld'),('yaups'),('yawed'),('yawey'),('yawls'),('yawns'),('yawny'),('yawps'),('ybore'),
('yclad'),('ycled'),('ycond'),('ydrad'),('ydred'),('yeads'),('yeahs'),('yealm'),('yeans'),('yeard'),('yearn'),('years'),
('yeast'),('yecch'),('yechs'),('yechy'),('yedes'),('yeeds'),('yeggs'),('yelks'),('yells'),('yelms'),('yelps'),('yelts'),
('yenta'),('yente'),('yerba'),('yerds'),('yerks'),('yeses'),('yesks'),('yests'),('yesty'),('yetis'),('yetts'),('yeuks'),
('yeuky'),('yeven'),('yeves'),('yewen'),('yexed'),('yexes'),('yfere'),('yield'),('yiked'),('yikes'),('yills'),('yince'),
('yipes'),('yippy'),('yirds'),('yirks'),('yirrs'),('yirth'),('yites'),('yitie'),('ylems'),('ylike'),('ylkes'),('ymolt'),
('ympes'),('yobbo'),('yocks'),('yodel'),('yodhs'),('yodle'),('yogas'),('yogee'),('yoghs'),('yogic'),('yogin'),('yogis'),
('yoick'),('yojan'),('yoked'),('yokel'),('yoker'),('yokes'),('yokul'),('yolks'),('yolky'),('yomim'),('yomps'),('yonic'),
('yonis'),('yonks'),('yoofs'),('yoops'),('yores'),('yorks'),('yorps'),('youks'),('young'),('yourn'),('yours'),('yourt'),
('youse'),('youth'),('yowed'),('yowes'),('yowie'),('yowls'),('yrapt'),('yrent'),('yrivd'),('yrneh'),('ysame'),('ytost'),
('yuans'),('yucas'),('yucca'),('yucch'),('yucko'),('yucks'),('yucky'),('yufts'),('yugas'),('yuked'),('yukes'),('yukky'),
('yukos'),('yulan'),('yules'),('yummo'),('yummy'),('yumps'),('yupon'),('yuppy'),('yurta'),('yurts'),('yuzus'),('zabra'),
('zacks'),('zaire'),('zakat'),('zaman'),('zambo'),('zamia'),('zanja'),('zante'),('zanza'),('zanze'),('zappy'),('zarfs'),
('zaris'),('zatis'),('zaxes'),('zayin'),('zazen'),('zeals'),('zebec'),('zebra'),('zebub'),('zebus'),('zeins'),('zerda'),
('zerks'),('zeros'),('zests'),('zesty'),('zetas'),('zexes'),('zezes'),('zhomo'),('zibet'),('ziffs'),('zigan'),('zilas'),
('zilch'),('zilla'),('zills'),('zimbi'),('zimbs'),('zinco'),('zincs'),('zincy'),('zineb'),('zines'),('zings'),('zingy'),
('zinke'),('zinky'),('zippo'),('zippy'),('ziram'),('zitis'),('zizel'),('zizit'),('zlote'),('zloty'),('zoaea'),('zobos'),
('zobus'),('zocco'),('zoeae'),('zoeal'),('zoeas'),('zoism'),('zoist'),('zombi'),('zonae'),('zonal'),('zonda'),('zoned'),
('zoner'),('zones'),('zonks'),('zooea'),('zooey'),('zooid'),('zooks'),('zooms'),('zoons'),('zooty'),('zoppa'),('zoppo'),
('zoril'),('zoris'),('zorro'),('zouks'),('zowie'),('zulus'),('zupan'),('zupas'),('zurfs'),('zuzim'),('zygal'),('zygon'),
('zymes'),('zymic')
on conflict do nothing;


-- ============================================================
-- FILE: supabase/seed/040_issues.sql
-- ============================================================
-- ============================================================
-- SPARK WORD — seed 040 · Issues
--
-- Mirrors the editions already on the TMT Spark site:
--   011 Concrete & Code (Jun 2026)   → STEEL   archived
--   012 Signal & Stream (Jul 2026)   → RADIO   archived
--   013 The Power Issue (Aug 2026)   → POWER   archived
--   014 The AI Infrastructure Race   → FIBER   ACTIVE  ← sample issue
--   015 (Oct 2026)                   → CLOUD   scheduled
-- Insert order matters: activating an issue archives the previous one.
-- ============================================================

insert into issues (issue_number, title, publication_date, answer, category, hint, explanation, status, newsletter_recipients) values
(11, 'Concrete & Code', '2026-06-04', 'STEEL', 'Construction',
 'The metal that frames data centers, fabs and towers — beams, columns, rebar — and the first line item tariffs move.',
 'Steel is the structural backbone of data centers, fabs and towers. Its price, tariff exposure and lead times move construction cost more than almost any other material, which is why cost managers track steel indices as closely as interest rates.',
 'archived', 3900),
(12, 'Signal & Stream', '2026-07-02', 'RADIO', 'Telecommunications',
 'The airwaves part of every mobile network — towers, antennas and the signal between them. AM, FM and 5G all use it.',
 'Radio access networks — the towers, antennas and small cells you can see — are the most visible and expensive part of a mobile network. Private 5G brings the same radio technology inside ports, factories and campuses, which is why connectivity is starting to appear in leases the way power does.',
 'archived', 4050),
(13, 'The Power Issue', '2026-08-06', 'POWER', 'Energy & Power',
 'Measured in megawatts and gigawatts — the one thing every new data center campus is short of. Plants make it, grids move it.',
 'Electricity has become the binding constraint on AI growth. Racks that drew 5–10 kW are now specified at 100 kW and beyond, campuses are planned in gigawatts, and interconnection queues in major markets stretch past four years — so site selection is an energy question first and a real estate question second.',
 'archived', 4180),
(14, 'The AI Infrastructure Race', '2026-09-03', 'FIBER', 'Telecommunications',
 'Strands of glass that carry data as pulses of light — the cable that connects a data center to the rest of the world.',
 'Fiber carries enormous volumes of digital information using light and is fundamental to telecom networks, data centers and modern digital infrastructure. Long-haul and metro fiber routes are now being built along the corridors connecting AI data center clusters — connectivity is following compute, and fiber access is becoming a site-selection criterion alongside power.',
 'active', 4250),
(15, 'Where Compute Lives', '2026-10-01', 'CLOUD', 'Digital Infrastructure',
 'Computing you rent by the hour from someone else''s data center — the business that made the hyperscalers giant.',
 'Cloud computing is capacity delivered as a service from someone else''s data centers. Cloud demand built the hyperscale industry over the last decade; AI is now building its second wave, with the largest cloud providers signing multi-gigawatt power deals and leasing capacity years ahead of delivery.',
 'scheduled', null)
on conflict (issue_number) do update set
  title = excluded.title, publication_date = excluded.publication_date, answer = excluded.answer,
  category = excluded.category, hint = excluded.hint, explanation = excluded.explanation,
  status = excluded.status, newsletter_recipients = excluded.newsletter_recipients;

