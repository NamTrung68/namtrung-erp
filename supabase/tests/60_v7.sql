-- Kiểm thử bản 7: COM Mua hàng / CSKH / TP Kế toán, tồn kho, câu mẫu
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- B là NV mua hàng vào làm 2 tháng trước kỳ lương → tháng thứ 3 → đàm phán 4%
update public.profiles set sale_aliases = '{Diễm Ngọc MH}', hire_date = '2026-10-15' where email = 'b@nt.vn';
update public.profiles set sale_aliases = '{Thủy CSKH}' where email = 'hr@nt.vn';
update public.settings set value = jsonb_set(value, '{accounting_com,profile_ids}', to_jsonb(array[(select id::text from public.profiles where email = 'kt@nt.vn')])) where key = 'payroll';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.payroll_open('2026-12-01');
select public.import_order_results((select id from public.payroll_periods where month = '2026-12-01'), '[
 {"ext_order_code":"MDX1","sale_name":"Sale A","order_profit":6000000,"cskh_name":"Thủy CSKH","buyer_name":"Diễm Ngọc MH","purchase_fee":600000,"nego_fee":1500000},
 {"ext_order_code":"MDX2","sale_name":"Sale A","order_profit":4000000,"cskh_name":"Chưa phân công","buyer_name":"Diễm Ngọc MH","purchase_fee":400000,"nego_fee":500000}
]'::jsonb, true);
select public.payroll_compute((select id from public.payroll_periods where month = '2026-12-01'));
reset role;
-- Mua hàng: (1.000.000 × 2% + 2.000.000 × 4%) × 100% = 100.000
select pg_temp.check((select com_buyer from public.payslips s join public.profiles p on p.id = s.profile_id where p.email = 'b@nt.vn' and s.period_id = (select id from public.payroll_periods where month = '2026-12-01')) = 100000, 'COM mua hàng = 100.000');
-- CSKH: 600.000 × 2% + 1.500.000 × 1% = 27.000 (đơn "Chưa phân công" không tính)
select pg_temp.check((select com_cskh from public.payslips s join public.profiles p on p.id = s.profile_id where p.email = 'hr@nt.vn' and s.period_id = (select id from public.payroll_periods where month = '2026-12-01')) = 27000, 'COM CSKH = 27.000');
-- TP Kế toán: 10.000.000 × 60% × 0,5% = 30.000
select pg_temp.check((select com_accounting from public.payslips s join public.profiles p on p.id = s.profile_id where p.email = 'kt@nt.vn' and s.period_id = (select id from public.payroll_periods where month = '2026-12-01')) = 30000, 'COM kế toán = 30.000');
select pg_temp.check((select net >= com_buyer from public.payslips s join public.profiles p on p.id = s.profile_id where p.email = 'b@nt.vn' and s.period_id = (select id from public.payroll_periods where month = '2026-12-01')), 'thực lĩnh gồm COM');
-- Người mua hàng xem được đơn của mình
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.order_results where buyer_id = auth.uid()) = 2, 'NVMH xem đơn mình mua');
-- Câu mẫu: ai cũng đọc, sale không sửa
select pg_temp.check((select count(*) from public.reply_templates) >= 5, 'có câu mẫu');
do $$ begin insert into public.reply_templates(title, content) values ('x', 'y'); raise exception 'phải chặn'; exception when insufficient_privilege then null; end $$;
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select (public.inventory_totals(null)->>'items')::int) >= 1, 'tổng tồn kho');
select pg_temp.check((select count(*) from public.quote_status_counts(null)) >= 1, 'đếm trạng thái báo giá');
reset role;
select 'V7 TESTS PASSED' as result;
