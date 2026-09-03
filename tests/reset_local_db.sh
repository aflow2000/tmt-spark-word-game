#!/usr/bin/env bash
# Rebuilds the local test database from scratch (local Postgres only).
set -e
cd "$(dirname "$0")/.."  # project root
DB=${DB:-sparkword}
# terminate lingering connections (e.g. the local RPC harness) so the drop succeeds
su postgres -c "psql -q -c \"select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB' and pid <> pg_backend_pid()\"" >/dev/null 2>&1
su postgres -c "psql -v ON_ERROR_STOP=1 -q -c 'drop database if exists $DB' -c 'create database $DB'" >/dev/null
run(){ echo "== $1"; su postgres -c "psql -v ON_ERROR_STOP=1 -q -d $DB -f $PWD/$1" 2>&1 | grep -v -E "^$|NOTICE" || true; }
run tests/local_auth_stub.sql
for f in supabase/migrations/*.sql; do run "$f"; done
if [ "$SEED" != "0" ]; then for f in supabase/seed/*.sql; do run "$f"; done; fi
