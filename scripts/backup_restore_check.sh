#!/usr/bin/env bash
# Logical backup of the database and verification that it restores into a separate database.
# Production: SOURCE_URL = Supabase direct connection string (Settings › Database), kept outside the repo.
# Usage: SOURCE_URL=... RESTORE_URL=... scripts/backup_restore_check.sh <out_dir>
set -euo pipefail
OUT="${1:?output dir}"; mkdir -p "$OUT"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
FILE="$OUT/samples_$STAMP.dump"
AUTHF="$OUT/samples_${STAMP}_auth_users.sql"
# 1) user identities (auth.users rows only: the auth schema itself belongs to Supabase)
pg_dump "$SOURCE_URL" --data-only --table=auth.users --column-inserts --no-owner --file="$AUTHF"
# 2) application schemas, structure + data
pg_dump "$SOURCE_URL" --format=custom --no-owner --no-privileges \
  --schema=public --schema=app --file="$FILE"
sha256sum "$FILE" "$AUTHF" > "$FILE.sha256"
pg_restore --list "$FILE" > /dev/null                      # the archive is readable
psql "$RESTORE_URL" -q -v ON_ERROR_STOP=1 -f "$AUTHF"
pg_restore --list "$FILE" | grep -v " SCHEMA - public " > "$FILE.toc"
pg_restore --no-owner --no-privileges --exit-on-error --use-list="$FILE.toc" --dbname="$RESTORE_URL" "$FILE"
Q="select (select count(*) from public.sample_skus)||'|'||(select sum(on_hand) from public.stock)||'|'||(select sum(reserved) from public.stock)||'|'||(select count(*) from public.inventory_movements)||'|'||(select count(*) from public.requests)||'|'||(select count(*) from public.request_lines)||'|'||(select count(*) from public.audit_log)"
A=$(psql "$SOURCE_URL" -Atc "$Q"); B=$(psql "$RESTORE_URL" -Atc "$Q")
echo "source  : $A"; echo "restored: $B"
[ "$A" = "$B" ] && echo "RESTORE OK  $FILE" || { echo "RESTORE MISMATCH"; exit 1; }
