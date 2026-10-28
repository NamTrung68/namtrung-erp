#!/usr/bin/env bash
set -e
PSQL="psql -h /var/tmp/pg -p 5433 -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "drop database if exists nt_e2e with (force)" -c "create database nt_e2e"
$PSQL -d nt_e2e -f supabase/tests/00_supabase_stub.sql
for f in supabase/migrations/*.sql; do $PSQL -d nt_e2e -f "$f" >/dev/null; done
$PSQL -d nt_e2e <<'SQL'
insert into auth.users(email) values ('namtrung20266@gmail.com');
insert into public.invites(email, full_name, roles, job_level) values ('lead@nt.vn','Trần Trưởng Nhóm','{tn_kd}','truong_nhom'),('a@nt.vn','Lê Văn Khơi','{sale}','chuyen_vien'),('hr@nt.vn','Nguyễn HCNS','{hcns}','chuyen_vien');
insert into auth.users(email) values ('lead@nt.vn'),('a@nt.vn'),('hr@nt.vn');
update public.profiles set manager_id = (select id from public.profiles where email='lead@nt.vn'), sale_aliases='{Khơi Lê}' where email='a@nt.vn';
update public.profiles set full_name='Giám Đốc' where email='namtrung20266@gmail.com';
SQL
echo e2e db ready
