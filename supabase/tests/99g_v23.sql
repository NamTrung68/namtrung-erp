-- Kiểm thử bản 23: ghép HĐ ký APT theo tên + SL, khóa dòng lệch, khung biên 2–4%, chờ duyệt giá, trả sửa, không hủy sau export
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- Xe XH261026001 sau chu kỳ 1 (giá APT nháp, giá khách, mã khai báo đã ghép theo đơn + SL)
insert into public.customers(id, code, company_name, contact_name, tax_code, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0023-0000000000c1', 'KHV23', 'HKD V23', 'Chị V23', '001182015117', 'nha_buon', 'tu_tim_zalo', '+84 912 230 023', id, 'thuyvuvu' from public.profiles where email='a@nt.vn';
insert into public.customers(id, code, company_name, contact_name, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0023-0000000000c2', 'KHV23B', 'HKD V23 B', 'Anh B', 'nha_buon', 'tu_tim_zalo', '+84 912 230 024', id, 'tiendat2603' from public.profiles where email='a@nt.vn';
insert into public.acc_trucks(id, name) values ('00000000-0000-0000-0023-000000000001', 'XH261026001');
insert into public.acc_lines(truck_id, line_key, ma_dong, ma_kb_apt, match_kind, md, sale_id, ma_kh, apt_stt, ten_apt, sl_apt, gia_nhap, gia_khach, vat, luong, status) select
  '00000000-0000-0000-0023-000000000001', k, kb, kba, mk, md, (select id from public.profiles where email='a@nt.vn'), kh, stt, ten, sl, gia, gk, 0.08, 'A', 'ok'
from (values
  ('A52', 'MD2415-4', 'MD2415-2', 'don', 'MD2415', 'thuyvuvu', 52, 'Giá đỡ cắm hoa bằng nhựa, 2 đầu vuông, KT: (7.5*7.5*16)cm', 1500, 1746, 1800),
  ('A53', 'MD2415-3', 'MD2415-3', 'ma',  'MD2415', 'thuyvuvu', 53, 'Đồ trang trí cắm hoa (cốt cắm hoa) bằng nhựa, cao 31cm', 760, 5820, 6000),
  ('A54', 'MD2415-2', 'MD2415-4', 'don', 'MD2415', 'thuyvuvu', 54, 'Dụng cụ cắm hoa (cốt cắm hoa) bằng nhựa, cao 35cm', 900, 4365, 4500),
  ('A35', 'MD2525-2', 'MD2525-1', 'don', 'MD2525', 'tiendat2603', 35, 'Loa máy tính để bàn gaming có dây', 90, 114560, 118000)
) v(k, kb, kba, mk, md, kh, stt, ten, sl, gia, gk);

-- Chu kỳ 2: kế toán nạp HĐ chính thức (mã hàng MISA), tên có sai số copy (khoảng trắng, dấu chấm cuối)
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_items_import('[
 {"ma_hang":"HH00044-2080-2026","ten":"Giá đỡ cắm hoa bằng nhựa,  2 đầu vuông, KT: (7.5*7.5*16)cm.","dvt":"Cái","vat":0.08,"sl_nhap":1500,"dg_nhap":1746,"so_hd_vao":"2080","ky_hieu":"C26TYT","ngay_vao":"2026-10-30"},
 {"ma_hang":"HH00045-2080-2026","ten":"Đồ trang trí cắm hoa (cốt cắm hoa) bằng nhựa, cao 31cm","dvt":"Cái","vat":0.08,"sl_nhap":760,"dg_nhap":5820,"so_hd_vao":"2080","ky_hieu":"C26TYT","ngay_vao":"2026-10-30"},
 {"ma_hang":"HH00046-2080-2026","ten":"Dụng cụ cắm hoa (cốt cắm hoa) bằng nhựa, cao 35cm","dvt":"Cái","vat":0.08,"sl_nhap":900,"dg_nhap":4400,"so_hd_vao":"2080","ky_hieu":"C26TYT","ngay_vao":"2026-10-30"},
 {"ma_hang":"HH00029-2080-2026","ten":"Loa máy tính để bàn gaming có dây","dvt":"Chiếc","vat":0.08,"sl_nhap":90,"dg_nhap":114560,"so_hd_vao":"2080","ky_hieu":"C26TYT","ngay_vao":"2026-10-30"},
 {"ma_hang":"HH00099-2080-2026","ten":"Mặt hàng không có trên nháp","dvt":"Cái","vat":0.08,"sl_nhap":5,"dg_nhap":1000,"so_hd_vao":"2080","ky_hieu":"C26TYT","ngay_vao":"2026-10-30"}]');
reset role;
select pg_temp.check((select ma_kb || '|' || md || '|' || match_src || '|' || gia_khach from public.out_items where ma_hang='HH00044-2080-2026') = 'MD2415-4|MD2415|ten|1800', 'tên lệch khoảng trắng/dấu chấm vẫn khớp → mã khai báo, đơn, giá khách');
select pg_temp.check((select sale_id = (select id from public.profiles where email='a@nt.vn') and customer_id = '00000000-0000-0000-0023-0000000000c1' from public.out_items where ma_hang='HH00044-2080-2026'), 'dòng HĐ nhận sale + khách theo đơn');
select pg_temp.check((select not lech from public.out_items where ma_hang='HH00045-2080-2026'), 'khớp đủ → không lệch');
select pg_temp.check((select lech and lech_note like '%Đơn giá HĐ 4400%' from public.out_items where ma_hang='HH00046-2080-2026'), 'giá HĐ ký khác nháp → khóa dòng');
select pg_temp.check((select acc_line_id is null and not lech from public.out_items where ma_hang='HH00099-2080-2026'), 'không có trên nháp → chờ ghép tay');
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check(not exists(select 1 from jsonb_array_elements(public.out_item_suggest((select id from public.out_items where ma_hang='HH00099-2080-2026'))) z where (z->>'sl_apt')::numeric <> 5), 'gợi ý ghép tay chỉ lấy dòng nháp cùng SL');
reset role;

-- Chu kỳ 3: sale tạo yêu cầu
select pg_temp.as_user('a@nt.vn'); set role authenticated;
-- dòng lệch đang khóa → không tạo được
select pg_temp.err($$select public.out_invoice_save(null, '{"buyer_name":"HKD V23","tax_code":"001182015117","customer_id":"00000000-0000-0000-0023-0000000000c1","submit":true}',
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH00046-2080-2026'),'sl',900,'don_gia',4500)))$$, 'đang lệch');
-- dưới biên 2% → cấm
select pg_temp.err($$select public.out_invoice_save(null, '{"buyer_name":"HKD V23","tax_code":"001182015117","customer_id":"00000000-0000-0000-0023-0000000000c1","submit":true}',
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH00044-2080-2026'),'sl',1500,'don_gia',1770)))$$, 'dưới 2');
-- gộp 2 khách → cấm
select pg_temp.err($$select public.out_invoice_save(null, '{"buyer_name":"HKD V23","submit":true}', jsonb_build_array(
  jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH00044-2080-2026'),'sl',1500,'don_gia',1800),
  jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH00029-2080-2026'),'sl',90,'don_gia',118000)))$$, '2 khách');
-- 2–4% → vào thẳng hàng chờ kế toán
create temp table r23 as select public.out_invoice_save(null, '{"buyer_name":"HKD V23","tax_code":"001182015117","customer_id":"00000000-0000-0000-0023-0000000000c1","submit":true}',
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH00044-2080-2026'),'sl',1500,'don_gia',1800))) id;
select pg_temp.check((select status from public.out_invoices where id = (select id from r23)) = 'cho_nhap', 'biên 3,09% → chờ export, không cần duyệt');
-- > 4% → chờ duyệt giá
create temp table r23b as select public.out_invoice_save(null, '{"buyer_name":"HKD V23","tax_code":"001182015117","customer_id":"00000000-0000-0000-0023-0000000000c1","submit":true}',
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH00045-2080-2026'),'sl',760,'don_gia',6500))) id;
select pg_temp.check((select status from public.out_invoices where id = (select id from r23b)) = 'cho_duyet_gia', 'biên 11,7% → chờ duyệt giá');
select pg_temp.err($$select public.out_price_approve(array[(select id from r23b)])$$, 'duyệt giá');
reset role;
select pg_temp.check((select is_default from public.out_buyers where customer_id = '00000000-0000-0000-0023-0000000000c1' and tax_code = '001182015117'), 'pháp nhân đầu tiên của khách là mặc định');
select pg_temp.as_user('tp@nt.vn'); set role authenticated;
select pg_temp.check(public.out_price_approve(array[(select id from r23b)], 'Khách lẻ, đồng ý') = 1, 'trưởng phòng duyệt giá');
reset role;
select pg_temp.check((select status || '|' || (price_ok_by is not null) from public.out_invoices where id = (select id from r23b)) = 'cho_nhap|true', 'đã duyệt → hàng chờ export');

-- Kế toán export MISA → sale không hủy được nữa
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_mark_misa(array[(select id from r23)]);
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_invoice_status(array[(select id from r23)], 'huy')$$, 'không hủy được');
reset role;
-- PDF nháp về → sale trả sửa → sửa → phiên bản 2, quay lại hàng chờ, mốc export bị xóa
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_invoice_status(array[(select id from r23)], 'da_nhap');
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_invoice_status(array[(select id from r23)], 'tra_sua')$$, 'Ghi nội dung');
select public.out_invoice_status(array[(select id from r23)], 'tra_sua', 'Khách đổi địa chỉ');
select public.out_invoice_save((select id from r23), '{"buyer_name":"HKD V23","tax_code":"001182015117","address":"Phúc Lộc, Hà Nội","customer_id":"00000000-0000-0000-0023-0000000000c1","submit":true}',
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH00044-2080-2026'),'sl',1500,'don_gia',1800)));
reset role;
select pg_temp.check((select status || '|' || version || '|' || (misa_at is null) from public.out_invoices where id = (select id from r23)) = 'cho_nhap|2|true', 'sửa sau export → v2, chờ export lại');

-- Kế toán mở khóa dòng lệch kèm lý do → sale tạo được
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_item_lech_ok(array[(select id from public.out_items where ma_hang='HH00046-2080-2026')], '')$$, 'lý do');
select public.out_item_lech_ok(array[(select id from public.out_items where ma_hang='HH00046-2080-2026')], 'APT làm tròn, chấp nhận');
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check(public.out_invoice_save(null, '{"buyer_name":"HKD V23","tax_code":"001182015117","customer_id":"00000000-0000-0000-0023-0000000000c1"}',
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH00046-2080-2026'),'sl',900,'don_gia',4550))) is not null, 'mở khóa → tạo được');
-- đơn sạch / báo cáo tồn
select pg_temp.check((select z->>'ly_do' from jsonb_array_elements(public.out_clean_orders(array['MD2525'])) z) = 'Khách chưa có pháp nhân mặc định', 'đơn MD2525 chưa có pháp nhân → không xuất hàng loạt');
select pg_temp.check(jsonb_array_length(public.out_ton_report()) >= 1, 'báo cáo tồn theo sale');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check(jsonb_array_length(public.out_clean_orders(array['MD2525'])) = 0, 'sale khác không thấy đơn');
reset role;
-- bản 23b: pháp nhân nhận HĐ khớp theo username khách; khách mới vào ERP sau vẫn tự gắn
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_buyers_import('[{"tax_code":"0101999888","name":"CÔNG TY LOA V23","username":"tiendat2603"},{"tax_code":"0101777666","name":"HKD CHƯA VÀO ERP","username":"khachmoi23"}]');
reset role;
select pg_temp.check((select is_default from public.out_buyers where tax_code='0101999888' and customer_id='00000000-0000-0000-0023-0000000000c2'), 'username → đúng khách, thành pháp nhân mặc định');
select pg_temp.check((select customer_id is null and username = 'khachmoi23' from public.out_buyers where tax_code='0101777666'), 'chưa có khách → giữ username chờ gắn');
insert into public.customers(id, code, company_name, contact_name, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0023-0000000000c3', 'KHV23C', 'HKD C', 'Anh C', 'nha_buon', 'tu_tim_zalo', '+84 912 230 025', id, 'khachmoi23' from public.profiles where email='a@nt.vn';
insert into public.out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap, customer_id) values ('HH00001-2099-2026', 'Hàng khách mới', 'Cái', 0.08, 1, 1000, '00000000-0000-0000-0023-0000000000c3');
select pg_temp.check((select customer_id = '00000000-0000-0000-0023-0000000000c3' and is_default from public.out_buyers where tax_code='0101777666'), 'khách vào ERP + có hàng → pháp nhân tự gắn, mặc định');
-- bản 25: nạp HĐ kèm dòng nháp đã đối chiếu trên màn hình (acc_line_id) → nhận đúng mã khai báo dù tên khác hẳn
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_items_import(jsonb_build_array(jsonb_build_object('ma_hang','HH00077-2080-2026','ten','Tên HĐ khác hẳn nháp','dvt','Chiếc','vat',0.08,'sl_nhap',90,'dg_nhap',114560,'so_hd_vao','2080',
  'acc_line_id',(select id from public.acc_lines where line_key='A35' and truck_id='00000000-0000-0000-0023-000000000001'))));
reset role;
select pg_temp.check((select ma_kb || '|' || md || '|' || match_src || '|' || (not lech) from public.out_items where ma_hang='HH00077-2080-2026') = 'MD2525-2|MD2525|ten|true', 'acc_line_id từ màn xem trước → mã khai báo, đơn');
select 'V23 TESTS PASSED' as result;
