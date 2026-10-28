#!/usr/bin/env bash
# Khởi động lại môi trường e2e: DB sạch + PostgREST + gateway + web tĩnh
cd "$(dirname "$0")/../.."
pkill -f "^/var/tmp/postgrest" ; pkill -f "^node gateway.mjs"; pkill -f "^node tests/e2e/serve.mjs"
sleep 1
./tests/e2e/setup-db.sh >/dev/null 2>&1 || { echo "setup-db failed"; exit 1; }
(cd tests/e2e && nohup /var/tmp/postgrest postgrest.conf > /var/tmp/pgrst.log 2>&1 & echo $! > /var/tmp/pgrst.pid)
(cd tests/e2e && nohup node gateway.mjs > /var/tmp/gw.log 2>&1 & echo $! > /var/tmp/gw.pid)
(nohup node tests/e2e/serve.mjs dist > /var/tmp/static.log 2>&1 & echo $! > /var/tmp/static.pid)
sleep 2; echo restarted
