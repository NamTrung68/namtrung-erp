-- Kiểm thử bản 39: sửa ngày HĐ theo PDF đã ký
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
-- HĐ của bản 38 (đã có file ky): ngày hệ thống ghi = hôm nay, PDF ghi hôm qua
update public.out_invoices set ngay_hd = app.vn_today(), created_at = now() - interval '5 days' where id = '00000000-0000-0000-0038-0000000000b1';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check(public.out_ky_fix_ngay('00000000-0000-0000-0038-0000000000b1', app.vn_today() - 1), 'sửa ngày theo PDF');
select pg_temp.check(not public.out_ky_fix_ngay('00000000-0000-0000-0038-0000000000b1', app.vn_today() - 1), 'đã đúng → không đổi');
select pg_temp.err($$select public.out_ky_fix_ngay('00000000-0000-0000-0038-0000000000b1', app.vn_today() + 3)$$, 'không hợp lệ');
reset role;
select pg_temp.check((select ngay_hd = app.vn_today() - 1 from public.out_invoices where id = '00000000-0000-0000-0038-0000000000b1'), 'lưu ngày HĐ');
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_ky_fix_ngay('00000000-0000-0000-0038-0000000000b1', app.vn_today() - 2)$$, 'Không có quyền');
reset role;
select 'V39 TESTS PASSED' as result;
