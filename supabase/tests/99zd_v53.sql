-- Kiểm thử bản 53: khách nhiều pháp nhân — lưu phiếu ghép đúng pháp nhân, không tạo pháp nhân mồ côi, không đè pháp nhân
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into public.customers(id, code, contact_name, phone, customer_type, source, owner_id, sys_username)
  select '00000000-0000-0000-0053-0000000000c1', 'KHV53', 'Khách V53', '+84 912 530 053', 'nha_buon', 'tu_tim_zalo', id, 'khv53' from public.profiles where email = 'a@nt.vn';
insert into public.out_buyers(id, customer_id, username, name, tax_code, address, email, is_default, ma_hdnt) values
  ('00000000-0000-0000-0053-0000000000b1', '00000000-0000-0000-0053-0000000000c1', 'khv53', 'HỘ KINH DOANH MỘT', '0105300001', 'Số 1 Phố A', 'mot@x.vn', true, '01/01/2026/HĐNT/NT/V53'),
  ('00000000-0000-0000-0053-0000000000b2', '00000000-0000-0000-0053-0000000000c1', 'khv53', 'CÔNG TY TNHH HAI', '0105300002', 'Số 2 Phố B', 'hai@x.vn', false, null);
insert into public.out_items(id, ma_hang, part, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id, customer_id, username)
  select ('00000000-0000-0000-0053-00000000a00' || k)::uuid, 'HH0000' || k || '-5301-2026', 1, 'Hàng V53 ' || k, 'Chiếc', 0.08, 10, 1000, 'MD530' || k, p.id, '00000000-0000-0000-0053-0000000000c1', 'khv53'
    from public.profiles p, generate_series(1, 4) k where p.email = 'a@nt.vn';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ declare v uuid; i public.out_invoices; b public.out_buyers; n int; begin
  -- 1) chọn pháp nhân thứ 2 nhưng gõ tên khác hoa thường / dấu chấm → vẫn ghép đúng pháp nhân HAI, không tạo trùng; địa chỉ phiếu khác không đè pháp nhân
  v := public.out_invoice_save(null, '{"customer_id":"00000000-0000-0000-0053-0000000000c1","buyer_name":"Công ty TNHH Hai.","tax_code":"0105300002","address":"Địa chỉ gõ khác","email":"khac@x.vn"}',
    '[{"item_id":"00000000-0000-0000-0053-00000000a001","sl":1,"don_gia":1030}]');
  select * into i from public.out_invoices where id = v;
  perform pg_temp.check(i.buyer_id = '00000000-0000-0000-0053-0000000000b2', 'phiếu gắn đúng pháp nhân HAI: ' || coalesce(i.buyer_id::text, 'null'));
  select count(*) into n from public.out_buyers where customer_id = '00000000-0000-0000-0053-0000000000c1';
  perform pg_temp.check(n = 2, 'không tạo pháp nhân trùng (đang có ' || n || ')');
  select * into b from public.out_buyers where id = '00000000-0000-0000-0053-0000000000b2';
  perform pg_temp.check(b.address = 'Số 2 Phố B' and b.email = 'hai@x.vn', 'phiếu không đè địa chỉ / email pháp nhân');
  -- 2) phiếu KHÔNG chọn khách (khách lấy theo dòng hàng) + pháp nhân mới → pháp nhân gắn khách + username, không mồ côi
  v := public.out_invoice_save(null, '{"buyer_name":"HỘ KINH DOANH BA","tax_code":"0105300003","address":"Số 3"}',
    '[{"item_id":"00000000-0000-0000-0053-00000000a002","sl":1,"don_gia":1030}]');
  select * into i from public.out_invoices where id = v;
  select * into b from public.out_buyers where id = i.buyer_id;
  perform pg_temp.check(i.customer_id = '00000000-0000-0000-0053-0000000000c1', 'phiếu lấy khách theo dòng hàng');
  perform pg_temp.check(b.customer_id = '00000000-0000-0000-0053-0000000000c1' and b.username = 'khv53' and not b.is_default, 'pháp nhân mới có khách + username, không giành ★: ' || row_to_json(b)::text);
  -- 3) phiếu không chọn khách, chọn pháp nhân ★ → ghép pháp nhân ★, không tạo pháp nhân mới
  v := public.out_invoice_save(null, '{"buyer_name":"HỘ KINH DOANH MỘT","tax_code":"0105300001"}', '[{"item_id":"00000000-0000-0000-0053-00000000a003","sl":1,"don_gia":1030}]');
  perform pg_temp.check((select buyer_id from public.out_invoices where id = v) = '00000000-0000-0000-0053-0000000000b1', 'không chọn khách vẫn ghép pháp nhân ★');
  select count(*) into n from public.out_buyers where customer_id is null and tax_code like '01053000%';
  perform pg_temp.check(n = 0, 'không có pháp nhân mồ côi');
end $$;
reset role;
-- 4) chuyển phát: HĐ khác MST, chưa gắn pháp nhân → không mượn người nhận của pháp nhân ★
update public.out_buyers set nguoi_nhan = 'Người nhận ★', sdt_nhan = '0912000053', dia_chi_giao = 'Kho ★' where id = '00000000-0000-0000-0053-0000000000b1';
insert into public.out_invoices(id, code, sale_id, customer_id, buyer_name, tax_code, address, status, so_hd, ngay_hd)
  select '00000000-0000-0000-0053-0000000000f1', 'XHD53F1', id, '00000000-0000-0000-0053-0000000000c1', 'HỘ KINH DOANH BỐN', '0105300004', 'Số 4 Phố D', 'da_ky', '53001', current_date from public.profiles where email = 'a@nt.vn';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
do $$ declare r jsonb; begin
  r := (public.out_ship_prep(array['00000000-0000-0000-0053-0000000000f1'::uuid])->'rows')->0;
  perform pg_temp.check(r->>'buyer_id' is null and r->>'dia_chi' = 'Số 4 Phố D' and coalesce(r->>'nguoi_nhan', '') <> 'Người nhận ★', 'chuyển phát không mượn pháp nhân ★ khác MST: ' || r::text);
end $$;
reset role;
select 'V53 TESTS PASSED' as result;
