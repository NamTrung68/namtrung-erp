-- Kiểm thử bản 22: kho giá xuất nhiều nguồn, lập phiếu theo ID đơn, gợi ý đơn vị nhận HĐ
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- 1 đơn MD9001 có 2 mặt hàng khác giá; 1 đơn MD9002 chỉ 1 giá
insert into public.out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id) values
  ('HH-V22-1', 'Hộp đựng giấy vải polyester nhiều màu', 'Chiếc', 0.08, 400, 50000, 'MD9001', (select id from public.profiles where email='a@nt.vn')),
  ('HH-V22-2', 'Cốc sứ trắng men dung tích 350ml', 'Cái', 0.1, 120, 70000, 'MD9001', (select id from public.profiles where email='a@nt.vn')),
  ('HH-V22-3', 'Túi voan lưới chữ nhật', 'Cái', 0.08, 1000, 400, 'MD9002', (select id from public.profiles where email='a@nt.vn'));
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_orders_import('[{"md":"MD9001","username":"khach9001","ten":"Hộp đựng giấy vải polyester","sl":400,"gia":54000},
  {"md":"MD9001","ten":"Cốc sứ trắng men 350ml","sl":120,"gia":80000},{"md":"MD9002","gia":418}]');
reset role;
select pg_temp.check((select gia_khach from public.out_items where ma_hang='HH-V22-1') = 54000, 'đơn 2 giá: dòng hộp nhận đúng giá hộp (SL + tên)');
select pg_temp.check((select gia_khach from public.out_items where ma_hang='HH-V22-2') = 80000, 'đơn 2 giá: dòng cốc nhận đúng giá cốc');
select pg_temp.check((select gia_khach || '|' || gia_src || '|' || gia_n from public.out_items where ma_hang='HH-V22-3') = '418|don_hang|1', 'đơn 1 giá → nhận luôn, ghi nguồn');
-- giá không phân biệt được → để trống, đánh dấu nhiều giá
insert into public.out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id) values ('HH-V22-4', 'Bàn chải đánh răng', 'Cái', 0.08, 7, 1000, 'MD9001', (select id from public.profiles where email='a@nt.vn'));
select pg_temp.check((select gia_khach is null and gia_n = 2 from public.out_items where ma_hang='HH-V22-4'), 'không khớp tên / SL → để trống, gia_n = 2');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check(jsonb_array_length(public.out_item_prices((select id from public.out_items where ma_hang='HH-V22-4'))) = 2, 'sale xem 2 giá của đơn');
select pg_temp.check((public.out_items_page('{"mode":"mine","f":"nhieu_gia"}')->>'total')::int = 1, 'lọc đơn nhiều giá');
select pg_temp.check((public.out_items_stats('mine')->>'nhieu_gia')::int = 1, 'đếm đơn nhiều giá');
select public.out_item_set_price((select id from public.out_items where ma_hang='HH-V22-4'), 15000);
select pg_temp.check((select (x->>'md') from jsonb_array_elements(public.out_items_page('{"mode":"mine","sort":"md","limit":500}')->'rows') x where x->>'md' like 'MD900%' limit 1) = 'MD9001', 'sắp theo ID đơn');
select pg_temp.check((public.out_items_page('{"mode":"mine","md":"MD9001"}')->>'total')::int = 3, 'lọc 1 ID đơn');
reset role;
select pg_temp.check((select gia_khach || '|' || gia_src from public.out_items where ma_hang='HH-V22-4') = '15000|sale', 'sale đặt giá → giữ, không bị kho đè');
select pg_temp.check((select gia_khach from public.out_items where ma_hang='HH-V22-1') = 54000, 'giá sale nhập không đè dòng khác cùng đơn');
-- đối soát xe có giá mới cho đúng mặt hàng → dòng nhận giá theo tên + SL
insert into public.acc_trucks(id, name) values ('00000000-0000-0000-0022-000000000001', 'Xe test v22');
insert into public.acc_lines(truck_id, line_key, md, ten_ht, sl_ht, gia_khach, luong, status) values ('00000000-0000-0000-0022-000000000001', 'V22', 'MD9002', 'Túi voan lưới chữ nhật', 1000, 420, 'A', 'ok');
select pg_temp.check((select gia_khach || '|' || gia_src from public.out_items where ma_hang='HH-V22-3') = '420|doi_soat', 'đối soát xe đúng tên + SL thắng file đơn hàng');
-- phiếu: đơn giá sale chốt vào kho
insert into public.out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id) values ('HH-V22-5', 'Khay nhựa', 'Cái', 0.08, 50, 1000, 'MD9003', (select id from public.profiles where email='a@nt.vn'));
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_invoice_save(null, '{"buyer_name":"KH V22","tax_code":"0101010101","submit":false}'::jsonb, jsonb_build_array(jsonb_build_object('item_id', (select id from public.out_items where ma_hang='HH-V22-5'), 'sl', 20, 'don_gia', 1500)));
reset role;
select pg_temp.check((select gia_khach || '|' || gia_src from public.out_items where ma_hang='HH-V22-5') = '1500|phieu', 'đơn giá trên phiếu → dòng nhận giá');
select pg_temp.check((select count(*) from public.out_prices where md = 'MD9003' and src = 'phieu') = 1, 'kho giá ghi đơn giá phiếu');
-- danh sách phiếu: ID đơn + lọc việc tiếp theo + sắp xếp
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select x->>'mds' from jsonb_array_elements(public.out_invoices_page('{"status":"soan","limit":50}')->'rows') x where x->>'buyer_name' = 'KH V22') = 'MD9003', 'phiếu hiện ID đơn');
select pg_temp.check((public.out_invoices_page('{"next":"chua_gui","limit":50}')->>'total')::int >= 0, 'lọc việc tiếp theo chạy');
select pg_temp.check(jsonb_array_length(public.out_invoices_page('{"sort":"tien","dir":"asc","limit":50}')->'rows') >= 1, 'sắp theo tiền');
reset role;
-- gợi ý đơn vị nhận HĐ
insert into public.customers(id, code, company_name, contact_name, tax_code, customer_type, source, phone, owner_id) select '00000000-0000-0000-0022-0000000000c1', 'KHV22', 'CÔNG TY V22', 'Anh V22', '0202020202', 'nha_buon', 'tu_tim_zalo', '+84 912 222 022', id from public.profiles where email='a@nt.vn';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((public.out_buyer_suggest(array['00000000-0000-0000-0022-0000000000c1'::uuid])->'00000000-0000-0000-0022-0000000000c1'->>'tax_code') = '0202020202', 'gợi ý đơn vị từ hồ sơ khách');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check(public.out_buyer_suggest(array['00000000-0000-0000-0022-0000000000c1'::uuid]) = '{}'::jsonb, 'sale khác không xem gợi ý khách người khác');
select pg_temp.check((select count(*) from public.out_prices) = 0, 'sale không đọc kho giá trực tiếp');
reset role;
select 'V22 TESTS PASSED' as result;
