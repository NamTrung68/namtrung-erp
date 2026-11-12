-- Kiểm thử bản 45: sửa loại đơn nghỉ trước khi duyệt
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
-- a@ (cấp dưới lead@) gửi "Việc riêng có lương" buổi chiều, ngày làm việc sắp tới
create temp table d45 as select x::date d from generate_series(app.vn_today() + 7, app.vn_today() + 20, interval '1 day') x where extract(isodow from x) between 1 and 5 order by x limit 1;
select d as d45 from d45 \gset
select pg_temp.as_user('a@nt.vn'); set role authenticated;
insert into public.leave_requests(id, leave_type, start_date, end_date, part, reason) values ('00000000-0000-0000-0045-0000000000a1', 'che_do', :'d45', :'d45', 'pm', 'Việc nhà');
select pg_temp.err($$select public.leave_change_type('00000000-0000-0000-0045-0000000000a1', 'phep_nam')$$, 'không có quyền');
reset role;
select pg_temp.as_user('lead@nt.vn'); set role authenticated;
select public.leave_change_type('00000000-0000-0000-0045-0000000000a1', 'phep_nam', 'chọn nhầm');
select pg_temp.err($$select public.leave_change_type('00000000-0000-0000-0045-0000000000a1', 'muon_som')$$, 'theo giờ');
select public.decide_request('leave', '00000000-0000-0000-0045-0000000000a1', true);
select pg_temp.err($$select public.leave_change_type('00000000-0000-0000-0045-0000000000a1', 'khong_luong')$$, 'chờ duyệt');
reset role;
select pg_temp.check((select leave_type = 'phep_nam' and status = 'da_duyet' and decision_note like '%Sửa loại%' from public.leave_requests where id = '00000000-0000-0000-0045-0000000000a1'), 'đổi loại rồi duyệt');
select pg_temp.check((select days = 0.5 and decision_note like '%chọn nhầm%' from public.leave_requests where id = '00000000-0000-0000-0045-0000000000a1'), 'giữ 0,5 ngày + ghi chú sửa loại');
select 'V45 TESTS PASSED' as result;
