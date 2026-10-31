-- Kiểm thử bản 18: trang dữ liệu, thống kê, đổi tên xe
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((public.out_items_page('{"mode":"acc","f":"ton","limit":2}')->>'total')::int = (select count(*) from public.out_items_v where ton > 0.0001), 'đếm còn tồn');
select pg_temp.check(jsonb_array_length(public.out_items_page('{"mode":"acc","limit":2}')->'rows') = 2, 'trang 2 dòng');
select pg_temp.check((public.out_items_stats('acc')->>'daky_nosale')::int >= 0, 'thống kê');
select pg_temp.check((public.out_items_page('{"mode":"acc","q":"búp bê"}')->>'total')::int = 2, 'tìm kiếm');
select pg_temp.check(public.out_xe_rename('Xe 25/10', 'Xe 25/10 (sửa)') >= 1, 'đổi tên xe');
select pg_temp.check((public.out_invoices_page('{"status":"da_ky"}')->'counts'->>'da_ky')::int >= 1, 'đếm phiếu theo trạng thái');
reset role;
select pg_temp.check((select xe from public.out_items_v where ma_hang='HH0001-738-2026') = 'Xe 25/10 (sửa)', 'tên xe mới hiện ở sổ');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((public.out_items_page('{"mode":"free"}')->>'total')::int = (select count(*) from public.out_items_v where sale_id is null and ton > 0.0001), 'sale: dòng chưa có sale còn tồn');
select pg_temp.check((select bool_and(app.in_tree(sale_id)) from jsonb_to_recordset(public.out_items_page('{"mode":"mine","limit":500}')->'rows') x(sale_id uuid)) is not false, 'sale chỉ thấy dòng của mình');
reset role;
select 'V18 TESTS PASSED' as result;
