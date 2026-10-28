-- Kiểm thử bản 4: đồng bộ khách, kho báo giá, tồn kho, màn hình đăng nhập
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

select pg_temp.check(app.norm_text('Ống phun KIM tuyến – Đỏ') = 'ong phun kim tuyen do', 'chuẩn hóa tên');
select pg_temp.check((select value->'metrics' ? 'cuoc_goi_nhat_ky' from public.settings where key = 'kpi'), 'KPI có cuộc gọi nhật ký');

-- Màn hình đăng nhập đọc được khi chưa đăng nhập
set role anon;
select pg_temp.check(jsonb_array_length(public.login_content()->'messages') = 30, '30 lời chúc');
reset role;

-- Đồng bộ khách: khớp SĐT → cập nhật mã hệ thống + ngày đơn cuối; tạo mới khi bật
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select pg_temp.check((public.import_customers('[{"sys_code":"kh-0099","phone":"0888886812","days_no_order":"20","order_count":"7"},{"sys_code":"X1","phone":"0911000111"}]'::jsonb, false)->>'updated')::int = 1, 'đồng bộ 1 khách');
select pg_temp.check((select sys_code = 'KH-0099' and sys_last_order_date = app.vn_today() - 20 and sys_order_count = 7 from public.customers where phone_norm = '0888886812'), 'đã ghi mã + ngày');
select pg_temp.check((public.import_customers('[{"sys_code":"KH-5001","contact_name":"Anh Tùng","phone":"0912345678","sale":"Sale B","customer_type":"Nhà buôn","days_no_order":"200"}]'::jsonb, true)->>'created')::int = 1, 'tạo khách mới');
select pg_temp.check((select owner_id = (select id from public.profiles where email = 'b@nt.vn') and stage = 'kho_ngu' and source = 'du_lieu_cu' from public.customers where sys_code = 'KH-5001'), 'gán đúng sale + kho ngủ');
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ begin perform public.import_customers('[]'::jsonb, true); raise exception 'phải bị chặn'; exception when others then if sqlerrm not like 'Chỉ Admin%' then raise; end if; end $$;
reset role;

-- Tồn kho + cảnh báo
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check(public.import_inventory('[{"sku":"TK1","name":"Ống phun kim tuyến màu đỏ 80cm","qty":"500","unit":"Chiếc"},{"sku":"tk1","name":"Ống phun kim tuyến đỏ","qty":"1"},{"name":"Chai thủy tinh 100ml","qty":"20"}]'::jsonb, true) = 2, 'nhập tồn kho, gộp trùng mã');
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.inventory_match(array['ống phun kim tuyến màu đỏ, không khí nén', 'máy xúc'])) >= 1, 'tìm thấy hàng giống');
select pg_temp.check((select count(*) from public.inventory_match(array['máy xúc đất'])) = 0, 'không khớp bậy');
do $$ begin insert into public.quote_archive(item_name) values ($q$x$q$); raise exception $q$phải bị chặn$q$; exception when insufficient_privilege then null; end $$;
reset role;
select pg_temp.as_user('tp@nt.vn'); set role authenticated;
insert into public.quote_archive(src_code, quote_date, item_name, hs_code, qty, price_cny) values ('BG-CU-1', '2025-05-01', 'Chai thủy tinh 100ml nắp nhôm', '70109099', 1000, 1.2);
reset role;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.quote_library('chai thuy tinh', null, 50, 0)) >= 1, 'kế toán tra cứu kho báo giá');
select pg_temp.check((select bool_and(source in ('he_thong','luu_tru')) from public.quote_library(null, null, 50, 0)), 'nguồn hợp lệ');
reset role;
select 'V4 TESTS PASSED' as result;
