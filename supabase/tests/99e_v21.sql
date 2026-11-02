-- Kiểm thử bản 21: mốc xuất file MISA, lọc sửa sau nháp
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check(public.out_mark_misa(array['00000000-0000-0000-0020-000000000002'::uuid]) = 1, 'ghi mốc xuất MISA');
reset role;
select pg_temp.check((select misa_at is not null from public.out_invoices where id = '00000000-0000-0000-0020-000000000002'), 'có mốc');
select pg_temp.check((select count(*) from public.out_events where invoice_id = '00000000-0000-0000-0020-000000000002' and action = 'misa') = 1, 'nhật ký xuất MISA');
update public.out_invoices set updated_at = now() + interval '1 second' where id = '00000000-0000-0000-0020-000000000002';
select pg_temp.check((select misa_at is null from public.out_invoices where id = '00000000-0000-0000-0020-000000000002'), 'sửa phiếu → mốc xuất MISA tự xóa');
update public.out_invoices set sua_sau_nhap = true where id = '00000000-0000-0000-0020-000000000002';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((public.out_invoices_page('{"status":"cho_nhap","flag":"sua"}')->>'total')::int = 1, 'lọc sửa sau nháp');
select pg_temp.check((public.out_invoices_page('{"limit":0}')->>'sua')::int = 1, 'đếm sửa sau nháp');
select pg_temp.check((public.out_invoices_page('{"status":"cho_nhap","flag":"misa_chua"}')->>'total')::int >= 1, 'lọc chưa xuất MISA');
select pg_temp.check(public.out_mark_misa(array['00000000-0000-0000-0020-000000000001'::uuid]) = 0, 'phiếu đã ký không ghi mốc');
reset role;
select 'V21 TESTS PASSED' as result;
