-- Kiểm thử bản 54: bỏ nhãn dán nhầm; chứng từ lấy pháp nhân cùng MST (đúng HĐNT từng pháp nhân); cờ lệch HĐ đã ký
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
select pg_temp.check(app.pn_ten_sach('HỘ KINH DOANH SHOP HOÀI VŨ Đại diện: Ông Châu Nguyễn Hoài Vũ') = 'HỘ KINH DOANH SHOP HOÀI VŨ', 'bỏ "Đại diện:"');
select pg_temp.check(app.pn_ten_sach('CÔNG TY TNHH ĐẠI DIỆN THƯƠNG MẠI') = 'CÔNG TY TNHH ĐẠI DIỆN THƯƠNG MẠI', 'không cắt chữ "đại diện" trong tên');
select pg_temp.check(app.pn_dc_sach('ĐIA CHI : 49 ĐƯỜNG SỐ 7') = '49 ĐƯỜNG SỐ 7' and app.pn_dc_sach('Địa chỉ: Số 49') = 'Số 49', 'bỏ "Địa chỉ:"');
select pg_temp.check(app.ten_norm('CÔNG TY TNHH THIẾT BỊ ĐIỆN-TỰ ĐỘNG HÓA') = app.ten_norm('Công Ty TNHH Thiết Bị Điện - Tự Động Hóa'), 'tên bỏ qua dấu gạch');
select pg_temp.check(app.dc_norm('Địa chỉ: Số 49, Đường số 7, TP Hồ Chí Minh') = app.dc_norm('Số 49 Đường số 7 Thành phố Hồ Chí Minh, Việt Nam'), 'so địa chỉ bỏ nhãn');
insert into public.customers(id, code, contact_name, phone, customer_type, source, owner_id, sys_username)
  select '00000000-0000-0000-0054-0000000000c1', 'KHV54', 'Khách V54', '+84 912 540 054', 'nha_buon', 'tu_tim_zalo', id, 'khv54' from public.profiles where email = 'a@nt.vn';
insert into public.out_buyers(id, customer_id, username, name, tax_code, address, is_default, ma_hdnt, dai_dien) values
  ('00000000-0000-0000-0054-0000000000b1', '00000000-0000-0000-0054-0000000000c1', 'khv54', 'HỘ KINH DOANH MỘT', '0105400001', 'Số 1 Phố A', true, '01/01/2026/HĐNTMB/NT/KHV54', 'Ông Một'),
  ('00000000-0000-0000-0054-0000000000b2', '00000000-0000-0000-0054-0000000000c1', 'khv54', 'HỘ KINH DOANH HAI', '0105400002', 'Số 2 Phố B', false, '02/02/2026/HĐNTMB/NT/KHV54', 'Bà Hai');
-- HĐ của pháp nhân HAI nhưng buyer_id trỏ nhầm pháp nhân ★ MỘT, tên dán nhãn
insert into public.out_invoices(id, code, sale_id, customer_id, buyer_id, buyer_name, tax_code, address, status, so_hd, ngay_hd)
  select '00000000-0000-0000-0054-0000000000f1', 'XHD54F1', id, '00000000-0000-0000-0054-0000000000c1', '00000000-0000-0000-0054-0000000000b1',
         'HỘ KINH DOANH HAI Đại diện: Bà Hai', '0105400002', 'Địa chỉ: Số 2 Phố B', 'da_ky', '54001', '2026-11-10' from public.profiles where email = 'a@nt.vn';
insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat)
  select '00000000-0000-0000-0054-0000000000f1', id, 1, 1, 1000, 0.08 from public.out_items limit 1;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
do $$ declare r jsonb; p jsonb; begin
  r := public.out_docs_data(array['00000000-0000-0000-0054-0000000000f1'::uuid])->0->'buyer';
  perform pg_temp.check(r->>'id' = '00000000-0000-0000-0054-0000000000b2' and r->>'ma_hdnt' = '02/02/2026/HĐNTMB/NT/KHV54' and r->>'name' = 'HỘ KINH DOANH HAI', 'chứng từ lấy pháp nhân cùng MST + HĐNT của nó: ' || coalesce(r::text, 'null'));
  -- cờ lệch: bỏ nhãn thì HĐ khớp pháp nhân HAI
  p := (select x from jsonb_array_elements(public.out_buyers_page('{"q":"0105400002","limit":10}')->'rows') x limit 1);
  perform pg_temp.check((p->>'khop_ky')::int = 1 and p->'lech_mau' = 'null'::jsonb, 'HĐ chỉ khác nhãn → không báo lệch: ' || p::text);
end $$;
reset role;
-- lệch thật (địa chỉ khác) → có lech_mau chỉ rõ HĐ + địa chỉ
update public.out_invoices set address = 'Số 99 Phố Khác' where id = '00000000-0000-0000-0054-0000000000f1';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
do $$ declare p jsonb; begin
  p := (select x from jsonb_array_elements(public.out_buyers_page('{"q":"0105400002","limit":10}')->'rows') x limit 1);
  perform pg_temp.check(p->'lech_mau'->>'so' = '54001' and (p->'lech_mau'->>'dc_khac')::boolean and not (p->'lech_mau'->>'ten_khac')::boolean, 'lech_mau chỉ ra địa chỉ khác: ' || p::text);
end $$;
reset role;
-- lưu phiếu: tên / địa chỉ có nhãn được làm sạch
insert into public.out_items(id, ma_hang, part, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id, customer_id, username)
  select '00000000-0000-0000-0054-00000000a001', 'HH00001-5401-2026', 1, 'Hàng V54', 'Chiếc', 0.08, 10, 1000, 'MD5401', id, '00000000-0000-0000-0054-0000000000c1', 'khv54' from public.profiles where email = 'a@nt.vn';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ declare v uuid; i public.out_invoices; begin
  v := public.out_invoice_save(null, '{"buyer_name":"HỘ KINH DOANH MỘT Đại diện: Ông Một","tax_code":"0105400001","address":"Địa chỉ: Số 1 Phố A"}', '[{"item_id":"00000000-0000-0000-0054-00000000a001","sl":1,"don_gia":1030}]');
  select * into i from public.out_invoices where id = v;
  perform pg_temp.check(i.buyer_name = 'HỘ KINH DOANH MỘT' and i.address = 'Số 1 Phố A' and i.buyer_id = '00000000-0000-0000-0054-0000000000b1', 'lưu phiếu làm sạch nhãn: ' || row_to_json(i)::text);
  perform pg_temp.check((select x->>'ma_hdnt' from jsonb_array_elements(public.out_buyers_for(array['00000000-0000-0000-0054-0000000000c1'::uuid], '{}')) x where x->>'id' = '00000000-0000-0000-0054-0000000000b2') = '02/02/2026/HĐNTMB/NT/KHV54', 'lập nhanh có mã HĐNT');
end $$;
reset role;
select 'V54 TESTS PASSED' as result;
