#!/usr/bin/env bash
# Creates a throw-away local PostgreSQL 16 cluster, loads the Supabase shim and every migration.
# Usage: scripts/local_db.sh [dbname]   → prints the connection string
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGDIR="${PGDIR:-/var/tmp/samples-pg}"
BIN=/usr/lib/postgresql/16/bin
DB="${1:-samples}"
PORT="${PGPORT:-55432}"
if [ ! -f "$PGDIR/PG_VERSION" ]; then
  mkdir -p "$PGDIR"; chown postgres "$PGDIR"
  su postgres -c "$BIN/initdb -D $PGDIR -A trust -U postgres >/dev/null"
fi
su postgres -c "$BIN/pg_ctl -D $PGDIR -o '-p $PORT -k /tmp' -l $PGDIR/log status >/dev/null" || \
  su postgres -c "$BIN/pg_ctl -D $PGDIR -o '-p $PORT -k /tmp -c max_connections=50' -l $PGDIR/log start -w >/dev/null"
PSQL="psql -h /tmp -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB"
$PSQL -d "$DB" -f "$ROOT/tests/supabase_shim.sql"
# Like Supabase: migrations run as a role that is NOT superuser and does NOT bypass RLS.
$PSQL -d "$DB" -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='app_owner') then create role app_owner login nosuperuser nobypassrls createrole; end if; end \$\$" \
  -c "grant create on database $DB to app_owner; grant usage, create on schema public to app_owner; alter schema public owner to app_owner;
      grant references, select on auth.users to app_owner; grant all on storage.buckets to app_owner; alter table storage.objects owner to app_owner;
      grant anon, authenticated, service_role to app_owner with admin option;"
for f in "$ROOT"/supabase/migrations/*.sql; do psql -h /tmp -p "$PORT" -U app_owner -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"; done
echo "postgresql://postgres@/$DB?host=/tmp&port=$PORT"
