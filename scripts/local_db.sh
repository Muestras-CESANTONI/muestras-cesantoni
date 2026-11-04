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
for f in "$ROOT"/supabase/migrations/*.sql; do $PSQL -d "$DB" -f "$f"; done
echo "postgresql://postgres@/$DB?host=/tmp&port=$PORT"
