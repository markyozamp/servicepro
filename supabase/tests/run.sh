#!/usr/bin/env bash
# Rebuilds a throwaway database and runs the full test.
# Usage: PGHOST=/tmp PGPORT=54329 ./supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=servicepro_test
psql -U postgres -qc "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
run() { psql -U postgres -d $DB -v ON_ERROR_STOP=1 -q -f "$1" 2>&1 | grep -v "NOTICE:" || true; }
run tests/00_supabase_stub.sql
for f in migrations/*.sql; do run "$f"; done
run tests/01_demo_users_stub.sql
run seed.sql
psql -U postgres -d $DB -v ON_ERROR_STOP=1 -q -f tests/02_scenarios.sql 2>&1 | grep -v "NOTICE:"
