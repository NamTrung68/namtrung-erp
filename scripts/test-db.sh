#!/usr/bin/env bash
# Chạy toàn bộ migration + test trên PostgreSQL cục bộ (giả lập Supabase)
set -e
PSQL="psql -h ${PGHOST:-/var/tmp/pg} -p ${PGPORT:-5433} -U ${PGUSER:-postgres} -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "drop database if exists nt_test" -c "create database nt_test"
$PSQL -d nt_test -f supabase/tests/00_supabase_stub.sql
for f in supabase/migrations/*.sql; do echo "== $f"; $PSQL -d nt_test -f "$f"; done
for f in supabase/tests/[1-9]*.sql; do echo "== TEST $f"; $PSQL -d nt_test -f "$f"; done
echo "ALL OK"
