-- Kiểm thử bản 35: nạp XML HĐ chính thức → mã hàng {mã khai báo}-{số HĐ}; tra MST lưu lên phiếu; pháp nhân + dữ liệu bộ chứng từ
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into public.customers(id, code, company_name, contact_name, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0035-0000000000c1', 'KHV35', 'HKD JIN V35', 'Anh Dương', 'nha_buon', 'tu_tim_zalo', '+84 912 350 035', id, 'jinvpp35' from public.profiles where email='a@nt.vn';
insert into public.acc_trucks(id, name) values ('00000000-0000-0000-0035-000000000001', 'XH071126035');
insert into public.acc_lines(id, truck_id, line_key, ma_dong, ma_kb_apt, md, sale_id, ma_kh, apt_stt, ten_apt, sl_apt, gia_nhap, gia_khach, vat, luong, status) select
  id::uuid, '00000000-0000-0000-0035-000000000001', k, kb, kb, md, (select id from public.profiles where email='a@nt.vn'), 'jinvpp35', stt, ten, sl, gia, gk, 0.08, 'A', 'ok'
from (values
  ('00000000-0000-0000-0035-0000000000a1', 'X1', 'M3433-2', 'MD3433', 1, 'Móc khóa hình quả bóng thể thao V35', 400, 1942, 2000),
  ('00000000-0000-0000-0035-0000000000a2', 'X2', 'M3433-5', 'MD3433', 2, 'Bình nước inox V35', 10, 50000, 52000),
  ('00000000-0000-0000-0035-0000000000a3', 'X3', 'M3434-1', 'MD3434', 3, 'Giá đỡ điện thoại V35', 20, 10000, 10300)
) v(id, k, kb, md, stt, ten, sl, gia, gk);

-- A. Nạp XML (màn hình đã ghép tên + SL): mã hàng ERP = {mã khai báo}-{số HĐ}; dòng không ghép được → CHUAKB-{số HĐ}-{STT}
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_items_import('[
 {"src":"xml","ma_hang":"M3433-2-2080","ten":"Móc khóa hình quả bóng thể thao V35","dvt":"Cái","vat":0.08,"sl_nhap":400,"dg_nhap":1942,"so_hd_vao":"2080","ky_hieu":"1C26TAP","ngay_vao":"2026-11-05","stt_hd":1,"acc_line_id":"00000000-0000-0000-0035-0000000000a1"},
 {"src":"xml","ma_hang":"M3433-5-2080","ten":"Bình nước inox V35","dvt":"Chiếc","vat":0.08,"sl_nhap":10,"dg_nhap":50000,"so_hd_vao":"2080","ky_hieu":"1C26TAP","ngay_vao":"2026-11-05","stt_hd":2,"acc_line_id":"00000000-0000-0000-0035-0000000000a2"},
 {"src":"xml","ma_hang":"CHUAKB-2080-3","ten":"Giá đỡ ĐT (APT sửa tên)","dvt":"Cái","vat":0.08,"sl_nhap":20,"dg_nhap":10000,"so_hd_vao":"2080","ky_hieu":"1C26TAP","ngay_vao":"2026-11-05","stt_hd":3}]');
reset role;
select pg_temp.check((select string_agg(ma_hang, ',' order by stt_hd) from public.out_items where so_hd_vao = '2080' and ky_hieu = '1C26TAP') = 'M3433-2-2080,M3433-5-2080,CHUAKB-2080-3', 'mã hàng tự sinh');
select pg_temp.check((select bool_and(ma_auto) from public.out_items where so_hd_vao = '2080' and ky_hieu = '1C26TAP'), 'đánh dấu mã tự sinh');
select pg_temp.check((select ma_kb = 'M3433-2' and md = 'MD3433' and gia_khach = 2000 and customer_id = '00000000-0000-0000-0035-0000000000c1' from public.out_items where ma_hang = 'M3433-2-2080'), 'nhận mã KB, đơn, giá, khách');
-- Ghép tay dòng chưa có nháp → đổi sang mã chuẩn
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_item_relink((select id from public.out_items where ma_hang = 'CHUAKB-2080-3'), '00000000-0000-0000-0035-0000000000a3');
reset role;
select pg_temp.check((select count(*) = 1 from public.out_items where ma_hang = 'M3434-1-2080' and stt_hd = 3), 'ghép tay xong đổi mã hàng = M3434-1-2080');
-- Nạp lại cùng file (màn hình lần này chưa ghép dòng 3 → gửi mã tạm) → không tạo trùng, giữ mã đã chuẩn
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_items_import('[
 {"src":"xml","ma_hang":"M3433-2-2080","ten":"Móc khóa hình quả bóng thể thao V35","dvt":"Cái","vat":0.08,"sl_nhap":400,"dg_nhap":1942,"so_hd_vao":"2080","ky_hieu":"1C26TAP","ngay_vao":"2026-11-05","stt_hd":1,"acc_line_id":"00000000-0000-0000-0035-0000000000a1"},
 {"src":"xml","ma_hang":"CHUAKB-2080-3","ten":"Giá đỡ ĐT (APT sửa tên)","dvt":"Cái","vat":0.08,"sl_nhap":20,"dg_nhap":10000,"so_hd_vao":"2080","ky_hieu":"1C26TAP","ngay_vao":"2026-11-05","stt_hd":3}]');
reset role;
select pg_temp.check((select count(*) = 3 from public.out_items where so_hd_vao = '2080' and ky_hieu = '1C26TAP'), 'nạp lại không tạo dòng mới');
select pg_temp.check((select count(*) = 1 from public.out_items where ma_hang = 'M3434-1-2080'), 'dòng đã ghép tay giữ mã chuẩn');
-- Excel cũ vẫn chạy như trước (không ma_auto)
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_items_import('[{"ma_hang":"HH00001-9999-2026","ten":"Hàng sổ Excel V35","dvt":"Cái","vat":0.08,"sl_nhap":1,"dg_nhap":1000,"so_hd_vao":"9999","ky_hieu":"C26TYT","ngay_vao":"2026-11-05"}]');
reset role;
select pg_temp.check((select not ma_auto from public.out_items where ma_hang = 'HH00001-9999-2026'), 'sổ Excel giữ mã hàng MISA');

-- C. Pháp nhân: đại diện, chức vụ, mã HĐNT (ngày tự đọc từ mã); sale chỉ sửa được đại diện / chức vụ
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_buyer_save(null, '{"username":"jinvpp35","name":"HỘ KINH DOANH JIN VPP V35","tax_code":"038098020305","address":"Thanh Hóa","ma_hdnt":"28/08/2026/HĐNTHH/NT/JINVPP"}');
reset role;
select pg_temp.check((select ngay_hdnt = '2026-08-28' and customer_id is not null from public.out_buyers where tax_code = '038098020305' and username = 'jinvpp35'), 'ngày HĐNT đọc từ mã');
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select (r->'counts'->>'co_hdnt')::int >= 1 and jsonb_array_length(public.out_buyers_page('{"flag":"co_hdnt"}')->'rows') >= 1 from (select public.out_buyers_page('{}') r) z), 'lọc pháp nhân có HĐNT');
-- sửa tên không gửi trường chứng từ → giữ nguyên mã HĐNT
select public.out_buyer_save((select id from public.out_buyers where tax_code = '038098020305' and username = 'jinvpp35'), '{"username":"jinvpp35","name":"HỘ KINH DOANH JIN VPP V35","tax_code":"038098020305","address":"Thanh Hóa"}');
reset role;
select pg_temp.check((select ma_hdnt = '28/08/2026/HĐNTHH/NT/JINVPP' from public.out_buyers where tax_code = '038098020305' and username = 'jinvpp35'), 'giữ mã HĐNT khi không gửi');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_buyer_doc_info((select id from public.out_buyers where tax_code = '038098020305' and username = 'jinvpp35'), '{"dai_dien":"Ông Trương Văn Dương","chuc_vu":"Chủ hộ kinh doanh","ma_hdnt":"HACK"}');
reset role;
select pg_temp.check((select dai_dien = 'Ông Trương Văn Dương' and chuc_vu = 'Chủ hộ kinh doanh' and ma_hdnt = '28/08/2026/HĐNTHH/NT/JINVPP' from public.out_buyers where tax_code = '038098020305' and username = 'jinvpp35'), 'sale điền đại diện, không đổi được mã HĐNT');
select id as pn35 from public.out_buyers where tax_code = '038098020305' and username = 'jinvpp35' \gset
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.err(format('select public.out_buyer_doc_info(%L, %L)', :'pn35', '{"dai_dien":"X"}'), 'Không có quyền');
reset role;
-- Import Excel: cột chứng từ, ô trống giữ nguyên
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_buyers_import_v2('[{"username":"jinvpp35","name":"HỘ KINH DOANH JIN VPP V35","tax_code":"038098020305","dia_chi_giao":"Kho Hậu Lộc","dai_dien":""}]');
reset role;
select pg_temp.check((select dia_chi_giao = 'Kho Hậu Lộc' and dai_dien = 'Ông Trương Văn Dương' from public.out_buyers where tax_code = '038098020305' and username = 'jinvpp35'), 'import cột chứng từ');

-- B + C. Sale lập phiếu → lưu kết quả tra MST → kế toán ký → dữ liệu bộ chứng từ (ngày = ngày HĐ ký, pháp nhân theo MST)
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_invoice_save(null, jsonb_build_object('customer_id', '00000000-0000-0000-0035-0000000000c1', 'buyer_name', 'HỘ KINH DOANH JIN VPP V35', 'tax_code', '038098020305', 'address', 'Thanh Hóa', 'payment', 'TM/CK', 'submit', true),
  jsonb_build_array(jsonb_build_object('item_id', (select id from public.out_items where ma_hang = 'M3433-2-2080'), 'sl', 400, 'don_gia', 2000, 'vat', 0.08)));
select public.out_invoice_mst((select id from public.out_invoices where buyer_name = 'HỘ KINH DOANH JIN VPP V35' order by created_at desc limit 1), '{"mst":"038098020305","found":true,"provider":"vietqr","warnings":[]}');
reset role;
select pg_temp.check((select mst_check->>'provider' = 'vietqr' and mst_check ? 'by' from public.out_invoices where buyer_name = 'HỘ KINH DOANH JIN VPP V35'), 'lưu kết quả tra MST');
select id as inv35 from public.out_invoices where buyer_name = 'HỘ KINH DOANH JIN VPP V35' limit 1 \gset
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.err(format('select public.out_invoice_mst(%L, %L)', :'inv35', '{}'), 'Không có quyền');
reset role;
update public.out_invoices set status = 'da_ky', so_hd = '00002759', ngay_hd = '2026-11-07' where buyer_name = 'HỘ KINH DOANH JIN VPP V35';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select d->0->>'ngay_hd' = '2026-11-07' and d->0->'buyer'->>'ma_hdnt' = '28/08/2026/HĐNTHH/NT/JINVPP' and d->0->'buyer'->>'ngay_hdnt' = '2026-08-28'
   and d->0->'buyer'->>'dai_dien' = 'Ông Trương Văn Dương' and jsonb_array_length(d->0->'lines') = 1 and (d->0->'lines'->0->>'sl')::numeric = 400
  from (select public.out_docs_data(array(select id from public.out_invoices where buyer_name = 'HỘ KINH DOANH JIN VPP V35')) d) z), 'dữ liệu bộ chứng từ');
reset role; select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select jsonb_array_length(public.out_docs_data(array(select id from public.out_invoices where buyer_name = 'HỘ KINH DOANH JIN VPP V35'))) = 0), 'sale khác không lấy được chứng từ');
reset role;
select 'V35 TESTS PASSED' as result;
