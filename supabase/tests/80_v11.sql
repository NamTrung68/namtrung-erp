-- Kiểm thử bản 11: nạp thử, chuyển chính thức, xóa xe, đánh dấu xuất thẳng
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

delete from public.notifications where kind = 'acc';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
create temp table t11 as select public.acc_truck_save(null, '{"name":"Xe thử","is_test":true,"md_xuat_thang":["MD7001"]}', '[
 {"line_key":"A1","md":"MD7000","apt_stt":1,"sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"issues":["x"],"notes":[]},
 {"line_key":"A2","md":"MD7002","apt_stt":2,"sale_name":"trungdv22","luong":"A","status":"ok","level":3,"issues":[],"notes":[]}]') id;
reset role;
grant select on t11 to authenticated;
select pg_temp.check((select count(*) from public.notifications where kind = 'acc') = 0, 'nạp thử không báo sale');
select pg_temp.check((select md_xuat_thang from public.acc_trucks where id = (select id from t11)) = '{MD7001}', 'lưu MD xuất thẳng theo xe');
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.acc_lines where truck_id = (select id from t11)) = 0, 'sale không thấy xe thử');
reset role;
-- Đánh dấu xuất thẳng
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_line_xuat_thang((select id from public.acc_lines where truck_id = (select id from t11) and line_key = 'A1'), true);
reset role;
select pg_temp.check((select luong = 'C' and status = 'info' from public.acc_lines where truck_id = (select id from t11) and line_key = 'A1'), 'đánh dấu xuất thẳng');
select pg_temp.check((select 'A1' = any(xt_keys) from public.acc_trucks where id = (select id from t11)), 'lưu dòng xuất thẳng theo xe');
-- Chuyển chính thức
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_line_xuat_thang((select id from public.acc_lines where truck_id = (select id from t11) and line_key = 'A1'), false);
select public.acc_truck_publish((select id from t11));
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.acc_lines where truck_id = (select id from t11)) = 2, 'chính thức: sale thấy');
reset role;
-- Xóa: xe có HĐ → kế toán không xóa được, Admin xóa được
update public.acc_lines set inv_id = (select id from public.acc_invoices limit 1) where truck_id = (select id from t11) and line_key = 'A2';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
do $$ begin perform public.acc_truck_delete((select id from t11)); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
reset role;
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.acc_truck_delete((select id from t11));
reset role;
select pg_temp.check(not exists(select 1 from public.acc_trucks where id = (select id from t11)), 'đã xóa xe');
select pg_temp.check(exists(select 1 from public.audit_logs where table_name = 'acc_trucks' and action = 'DELETE'), 'ghi nhật ký xóa');
select 'V11 TESTS PASSED' as result;
