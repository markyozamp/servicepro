#!/usr/bin/env bash
# Rebuilds a throwaway database and runs the full test.
# Usage: PGHOST=/tmp PGPORT=54329 ./supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=servicepro_test
psql -U postgres -qc "drop database if exists $DB" -c "create database $DB" >/dev/null
run() { psql -U postgres -d $DB -v ON_ERROR_STOP=1 -q -f "$1"; }
run tests/00_supabase_stub.sql
for f in migrations/*.sql; do run "$f"; done
run seed.sql
run tests/01_service_call.sql
