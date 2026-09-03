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
