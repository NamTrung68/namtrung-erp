-- Kiểm thử bản 60: Admin sửa trực tiếp dòng đối soát xe — quyền, tính lại biên, sửa theo cả đơn, đồng bộ HĐ đầu vào, chặn phiếu đã gửi, nạp lại giữ sửa tay
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where 'admin' = any(roles) order by created_at limit 1), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into public.customers(id, code, company_name, contact_name, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0060-0000000000c1', 'KHV60', 'HKD V60', 'Chị V60', 'nha_buon', 'tu_tim_zalo', '+84 912 600 060', id, 'khv60' from public.profiles where email='a@nt.vn';
insert into public.customers(id, code, company_name, contact_name, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0060-0000000000c2', 'KHV60B', 'HKD V60 B', 'Anh V60B', 'nha_buon', 'tu_tim_zalo', '+84 912 600 061', id, 'khv60b' from public.profiles where email='b@nt.vn';
insert into public.acc_trucks(id, name) values ('00000000-0000-0000-0060-000000000001', 'Xe V60');
insert into public.acc_lines(truck_id, line_key, ma_dong, md, sale_id, sale_name, ma_kh, apt_stt, hh, ten_apt, sl_apt, gia_nhap, gia_ap_dung, gia_khach, bien_nt, tt_apt, tt_khach, vat, luong, status, phan_hoi) select
  '00000000-0000-0000-0060-000000000001', k, kb, md, (select id from public.profiles where email='a@nt.vn'), 'Sale A', 'khv60', stt, 'HH' || stt, ten, sl, gia, gia, gk, gk / gia - 1, gia * sl, gk * sl, 0.08, 'A', 'ok', 'CHỐT'
from (values
  ('A1', 'MD6001-1', 'MD6001', 1, 'Ấm đun nước siêu tốc V60', 100, 1000, 1030),
  ('A2', 'MD6001-2', 'MD6001', 2, 'Bình giữ nhiệt V60', 50, 2000, 2060),
  ('A3', 'MD6002-1', 'MD6002', 3, 'Cốc sứ V60', 200, 500, 515),
  ('A4', 'MD6002-2', 'MD6002', 4, 'Đĩa sứ V60 bản nháp', 10, 800, 824)
) v(k, kb, md, stt, ten, sl, gia, gk);
create temp table goc60 as select * from public.acc_lines where truck_id = '00000000-0000-0000-0060-000000000001';
grant select on goc60 to authenticated;
create or replace function pg_temp.l(p_key text) returns public.acc_lines language sql as $$ select * from public.acc_lines where truck_id = '00000000-0000-0000-0060-000000000001' and line_key = p_key $$;
grant execute on all functions in schema pg_temp to authenticated;

-- 1) quyền + kiểm đầu vào
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"gia_khach":1035}', 'sửa')$$, 'Chỉ Admin');
reset role; select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"gia_khach":1035}', 'sửa')$$, 'Chỉ Admin');
reset role; select pg_temp.as_admin(); set role authenticated;
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"gia_khach":1035}', '  ')$$, 'lý do');
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"status":"ok"}', 'x')$$, 'không sửa được');
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"vat":8}', 'x')$$, 'tỷ lệ');
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"md":"abc"}', 'x')$$, 'không hợp lệ');
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"sl_apt":""}', 'x')$$, 'không được để trống');

-- 2) sửa giá khách trong khung → vẫn Chốt, tính lại tiền / biên, lưu giá gốc + nhật ký
select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"gia_khach":"1035"}', 'Up nhầm giá khách');
select pg_temp.check((select status = 'ok' and gia_khach = 1035 and tt_khach = 103500 and round(bien_nt, 4) = 0.035 and phan_hoi = 'CHỐT' from pg_temp.l('A1')), 'giá khách trong khung → chốt, tính lại');
select pg_temp.check((select (manual->'gia_khach'->>'goc')::numeric = 1030 and (manual->'gia_khach'->>'moi')::numeric = 1035 from pg_temp.l('A1')), 'lưu giá trị gốc của file');
select pg_temp.check(exists(select 1 from public.acc_events where line_id = (pg_temp.l('A1')).id and action = 'admin_edit' and note = 'Up nhầm giá khách'
  and (data->'thay_doi'->'gia_khach'->>'cu')::numeric = 1030), 'nhật ký cũ → mới + lý do');
-- sửa lần 2: giá gốc giữ nguyên là giá file; biên < 2,5% → trả lại sale + báo sale
select public.acc_line_admin_edit((pg_temp.l('A1')).id, '{"gia_khach":1010}', 'Giá chốt thật');
select pg_temp.check((select status = 'blocked' and phan_hoi like 'CHỜ SALE%' and due_at is not null and issues[array_upper(issues, 1)] like 'Biên NT 1.00%' and gia_de_xuat is not null from pg_temp.l('A1')), 'biên dưới khung → trả lại sale');
select pg_temp.check((select (manual->'gia_khach'->>'goc')::numeric = 1030 from pg_temp.l('A1')), 'sửa nhiều lần vẫn giữ giá gốc của file');
reset role;
select pg_temp.check(exists(select 1 from public.notifications where recipient_id = (select id from public.profiles where email='a@nt.vn') and title like 'Admin sửa dòng đối soát MD6001%'), 'báo sale');

-- 3) sửa theo cả đơn: Sale + Khách cho mọi dòng MD6001; trường riêng dòng (VAT) chỉ áp dòng đang sửa; sửa sale không đụng số tiền
select pg_temp.as_admin(); set role authenticated;
select public.acc_line_admin_edit((pg_temp.l('A2')).id, jsonb_build_object('sale_id', (select id from public.profiles where email='b@nt.vn'), 'ma_kh', ' khv60b ', 'vat', 0.1), 'Up nhầm sale + khách cả đơn', true);
reset role;
select pg_temp.check((select count(*) = 2 from public.acc_lines where truck_id = '00000000-0000-0000-0060-000000000001' and md = 'MD6001'
  and sale_id = (select id from public.profiles where email='b@nt.vn') and ma_kh = 'khv60b' and customer_id = '00000000-0000-0000-0060-0000000000c2'), 'cả đơn đổi sale + khách + gắn khách ERP');
select pg_temp.check((select vat = 0.1 from pg_temp.l('A2')) and (select vat = 0.08 from pg_temp.l('A1')), 'VAT chỉ áp dòng đang sửa');
select pg_temp.check((select l.tt_apt = g.tt_apt and l.tt_khach = g.tt_khach and l.status = 'ok' from pg_temp.l('A2') l, goc60 g where g.line_key = 'A2'), 'sửa sale/khách không đụng số tiền');
select pg_temp.check((select l.sale_id = g.sale_id and l.ma_kh = g.ma_kh and l.manual = '{}' and l.updated_at = g.updated_at from pg_temp.l('A3') l, goc60 g where g.line_key = 'A3'), 'đơn khác không bị đụng');
select pg_temp.check(exists(select 1 from public.notifications where recipient_id = (select id from public.profiles where email='a@nt.vn') and title like '%chuyển cho sale khác%'), 'báo sale cũ');

-- 4) HĐ chính thức đã về: giá HĐ khác nháp → khóa; Admin sửa giá nháp theo HĐ → tự mở khóa
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_items_import(('[
 {"ma_hang":"X0-1","src":"xml","stt_hd":1,"ten":"Cốc sứ V60","dvt":"Cái","vat":0.08,"sl_nhap":200,"dg_nhap":505,"so_hd_vao":"6001","ky_hieu":"C26TAA","ngay_vao":"2026-11-20","acc_line_id":"' || (pg_temp.l('A3')).id || '"},
 {"ma_hang":"X0-2","src":"xml","stt_hd":2,"ten":"Đĩa sứ V60","dvt":"Cái","vat":0.08,"sl_nhap":10,"dg_nhap":800,"so_hd_vao":"6001","ky_hieu":"C26TAA","ngay_vao":"2026-11-20"}]')::jsonb);
reset role;
select pg_temp.check((select lech and ma_hang = 'MD6002-1-6001' from public.out_items where so_hd_vao = '6001' and stt_hd = 1), 'giá HĐ 505 ≠ nháp 500 → khóa lệch');
select pg_temp.check((select acc_line_id is null from public.out_items where so_hd_vao = '6001' and stt_hd = 2), 'tên HĐ khác tên nháp → chưa ghép');
select pg_temp.as_admin(); set role authenticated;
select public.acc_line_admin_edit((pg_temp.l('A3')).id, '{"gia_nhap":505}', 'APT xuất giá 505 theo HĐ chính thức');
reset role;
select pg_temp.check((select not lech and lech_note is null from public.out_items where so_hd_vao = '6001' and stt_hd = 1), 'sửa giá nháp khớp HĐ → tự mở khóa');
select pg_temp.check((select round(bien_nt, 4) = round(515 / 505.0 - 1, 4) and tt_apt = 101000 from pg_temp.l('A3')), 'biên + tiền APT theo giá mới');
-- sửa tên nháp theo HĐ → dòng HĐ chưa ghép được tự ghép, nhận mã khai báo + sale + giá khách
select pg_temp.as_admin(); set role authenticated;
select public.acc_line_admin_edit((pg_temp.l('A4')).id, '{"ten_apt":"Đĩa sứ V60"}', 'Tên APT sửa theo HĐ');
reset role;
select pg_temp.check((select acc_line_id = (pg_temp.l('A4')).id and ma_hang = 'MD6002-2-6001' and gia_khach = 824 and not lech from public.out_items where so_hd_vao = '6001' and stt_hd = 2), 'tên khớp → tự ghép + mã hàng theo mã khai báo');
-- sửa mã khai báo → mã hàng ERP đổi theo
select pg_temp.as_admin(); set role authenticated;
select public.acc_line_admin_edit((pg_temp.l('A4')).id, '{"ma_dong":"md6002-9"}', 'Sai mã khai báo');
reset role;
select pg_temp.check((select ma_hang = 'MD6002-9-6001' and ma_kb = 'MD6002-9' from public.out_items where so_hd_vao = '6001' and stt_hd = 2), 'đổi mã khai báo → đổi mã hàng');
-- sửa giá khách → dòng sổ nhận giá mới
select pg_temp.as_admin(); set role authenticated;
select public.acc_line_admin_edit((pg_temp.l('A4')).id, '{"gia_khach":830}', 'Giá khách đúng');
reset role;
select pg_temp.check((select gia_khach = 830 from public.out_items where so_hd_vao = '6001' and stt_hd = 2), 'giá khách đẩy sang dòng sổ');

-- 5) phiếu xuất HĐ đã gửi kế toán / xuất nháp / ký → chặn; đang soạn → cho sửa + cảnh báo
insert into public.out_invoices(id, buyer_name, status) values ('00000000-0000-0000-0060-0000000000f1', 'HKD V60', 'soan');
insert into public.out_invoice_lines(invoice_id, item_id, sl, don_gia) select '00000000-0000-0000-0060-0000000000f1', id, 10, 830 from public.out_items where so_hd_vao = '6001' and stt_hd = 2;
select pg_temp.as_admin(); set role authenticated;
select pg_temp.check((select (public.acc_line_admin_edit((pg_temp.l('A4')).id, '{"gia_khach":835}', 'Giá khách', false))->>'warn' like '%đang soạn%'), 'phiếu đang soạn → sửa được + cảnh báo');
reset role;
update public.out_invoices set status = 'da_nhap' where id = '00000000-0000-0000-0060-0000000000f1';
select pg_temp.as_admin(); set role authenticated;
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A4')).id, '{"gia_khach":840}', 'x')$$, 'phiếu xuất HĐ');
-- sửa theo cả đơn MD6002: dòng A4 bị khóa → cả lệnh bị chặn, không dòng nào đổi
select pg_temp.err($$select public.acc_line_admin_edit((pg_temp.l('A3')).id, '{"md":"MD6099"}', 'x', true)$$, 'phiếu xuất HĐ');
reset role;
select pg_temp.check((select count(*) = 2 from public.acc_lines where truck_id = '00000000-0000-0000-0060-000000000001' and md = 'MD6002'), 'chặn → không đổi dòng nào');
update public.out_invoices set status = 'huy' where id = '00000000-0000-0000-0060-0000000000f1';

-- 6) nạp lại file (file vẫn số cũ) → giữ phần Admin sửa tay; file có số mới khác → ghi chú
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_truck_save('00000000-0000-0000-0060-000000000001', '{"name":"Xe V60"}', (select jsonb_agg(jsonb_build_object(
  'line_key', g.line_key, 'ma_dong', g.ma_dong, 'md', g.md, 'sale_name', 'Sale A', 'ma_kh', g.ma_kh, 'apt_stt', g.apt_stt, 'hh', g.hh,
  'ten_apt', case when g.line_key = 'A3' then 'Cốc sứ V60 (APT sửa tên)' else g.ten_apt end, 'sl_apt', g.sl_apt,
  'gia_nhap', case when g.line_key = 'A3' then 510 else g.gia_nhap end, 'gia_ap_dung', g.gia_nhap, 'gia_khach', g.gia_khach, 'vat', g.vat,
  'luong', 'A', 'status', 'ok', 'level', 3, 'issues', '[]'::jsonb, 'notes', '[]'::jsonb, 'phan_hoi', 'CHỐT')) from goc60 g));
reset role;
select pg_temp.check((select gia_khach = 1010 and sale_id = (select id from public.profiles where email='b@nt.vn') and ma_kh = 'khv60b' and manual ? 'gia_khach' from pg_temp.l('A1')), 'nạp lại giữ giá khách + sale + khách đã sửa');
select pg_temp.check((select status = 'blocked' and round(bien_nt, 4) = 0.01 from pg_temp.l('A1')), 'nạp lại tính lại biên theo giá đã sửa');
select pg_temp.check((select vat = 0.1 from pg_temp.l('A2')), 'nạp lại giữ VAT đã sửa');
select pg_temp.check((select gia_nhap = 505 and notes[1] like '%file mới khác ở: Giá APT nháp%' from pg_temp.l('A3')), 'file có giá mới khác → giữ sửa tay + ghi chú');
select pg_temp.check((select ten_apt = 'Cốc sứ V60 (APT sửa tên)' and not (manual ? 'ten_apt') from pg_temp.l('A3')), 'trường không sửa tay → theo file mới');
select pg_temp.check((select ma_dong = 'MD6002-9' and ten_apt = 'Đĩa sứ V60' from pg_temp.l('A4')), 'nạp lại giữ mã khai báo + tên đã sửa');
select pg_temp.check(exists(select 1 from public.acc_events where line_id = (pg_temp.l('A3')).id and action = 'giu_sua_tay'), 'nhật ký giữ sửa tay');

-- 7) xe khác / dòng không sửa tay: nạp lại như cũ (cột manual rỗng → không đổi hành vi)
select pg_temp.check(not exists(select 1 from public.acc_lines where truck_id <> '00000000-0000-0000-0060-000000000001' and manual <> '{}'), 'dữ liệu xe cũ không bị đụng');
select 'v60 OK';
