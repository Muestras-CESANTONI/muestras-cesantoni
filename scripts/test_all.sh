#!/usr/bin/env bash
# Full local verification: fresh DB → migrations → initial migration → DB tests → fresh DB → browser tests.
# Requires the dev server (scripts/dev_server.ts) running on :8787 for the browser part.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
D="postgresql://postgres@/samples?host=/tmp&port=${PGPORT:-55432}"
python3 -I migration/migrate_houston.py "${XLSX:?path to the backed-up xlsx}" migration/out >/dev/null
scripts/local_db.sh >/dev/null && psql "$D" -q -v ON_ERROR_STOP=1 -f migration/out/load.sql >/dev/null
(cd tests && node --test --test-concurrency=1 db.test.mjs 2>&1 | grep -E "^(ok|not ok|# pass|# fail)")
scripts/local_db.sh >/dev/null && psql "$D" -q -v ON_ERROR_STOP=1 -f migration/out/load.sql -f scripts/e2e_fixture.sql >/dev/null
(cd tests && PLAYWRIGHT_PATH="$(npm root -g)/playwright" node e2e.mjs http://localhost:8787 "${SHOTS:-/var/tmp/shots}")
