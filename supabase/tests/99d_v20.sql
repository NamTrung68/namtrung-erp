-- Kiểm thử bản 20: file PDF hóa đơn trên Drive — vé, ghép phiếu, phiên bản, quyền xem
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.fails(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- Dữ liệu: 2 phiếu của sale A (cùng MST, khác tiền), 1 phiếu của sale B
insert into public.out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap) values ('HH-V20-1', 'Hộp đựng giấy', 'Chiếc', 0.08, 1000, 50000);
insert into public.out_invoices(id, sale_id, buyer_name, tax_code, status) values
  ('00000000-0000-0000-0020-000000000001', (select id from public.profiles where email='a@nt.vn'), 'HỘ KINH DOANH TÀI ĐỨC', '040091011932', 'cho_nhap'),
  ('00000000-0000-0000-0020-000000000002', (select id from public.profiles where email='a@nt.vn'), 'HỘ KINH DOANH TÀI ĐỨC', '040091011932', 'cho_nhap'),
  ('00000000-0000-0000-0020-000000000003', (select id from public.profiles where email='b@nt.vn'), 'CÔNG TY B', '0700871570', 'cho_nhap');
insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values
  ('00000000-0000-0000-0020-000000000001', (select id from public.out_items where ma_hang='HH-V20-1'), 1, 400, 54000, 0.08),
  ('00000000-0000-0000-0020-000000000002', (select id from public.out_items where ma_hang='HH-V20-1'), 1, 100, 54000, 0.08),
  ('00000000-0000-0000-0020-000000000003', (select id from public.out_items where ma_hang='HH-V20-1'), 1, 200, 54000, 0.08);
select pg_temp.check(app.out_inv_total('00000000-0000-0000-0020-000000000001') = 23328000, 'tổng tiền phiếu = mẫu MISA 23.328.000');

-- Mã bí mật Apps Script
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.backup_set_token('apps-script-secret-0123456789abcdef0123456789');
select public.set_drive('{"url":"https://script.google.com/x","upload_key":"abc"}');
reset role;
select pg_temp.check((select value ? 'upload_key' from public.settings where key='drive') = false, 'không lưu khóa tải lên cố định');

-- Sale không xin được vé tải lên, không đọc bảng file
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check(pg_temp.fails($q$select public.drive_upload_tickets(array['HD nhap'])$q$), 'sale không xin vé tải lên');
select pg_temp.check(pg_temp.fails($q$select * from public.out_invoice_files$q$), 'sale không đọc trực tiếp bảng file');
select pg_temp.check(pg_temp.fails($q$select public.out_file_match('[]')$q$), 'sale không ghép file');
reset role;

-- Kế toán: vé tải lên → Apps Script đổi vé
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
create temp table tk as select unnest(public.drive_upload_tickets(array['HD nhap/2026-11/A', '../../x'])) t;
reset role;
grant select on tk to anon;
set role anon;
select pg_temp.check(pg_temp.fails($q$select public.drive_redeem('sai-ma', (select t from tk limit 1))$q$), 'Apps Script sai mã bí mật → từ chối');
select pg_temp.check((public.drive_redeem('apps-script-secret-0123456789abcdef0123456789', (select t from tk limit 1)))->>'folder' = 'HD nhap/2026-11/A', 'đổi vé tải lên → thư mục');
select pg_temp.check(pg_temp.fails($q$select public.drive_redeem('apps-script-secret-0123456789abcdef0123456789', (select t from tk limit 1))$q$), 'vé dùng 1 lần');
select pg_temp.check(position('..' in (public.drive_redeem('apps-script-secret-0123456789abcdef0123456789', (select t from tk offset 1 limit 1)))->>'folder') = 0, 'thư mục không có ..');
reset role;

-- Ghép: nháp 23.328.000 MST 040091011932 → đúng phiếu 1
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
create temp table m1 as select public.out_file_match('[{"i":0,"kind":"nhap","mst":"040091011932","tong":23328000,"name":"NHAP_040091011932_23328000_20261031_1.pdf"},
  {"i":1,"kind":"nhap","mst":"0700871570","tong":11664000,"name":"NHAP_0700871570_11664000_20261102_1.pdf"},
  {"i":2,"kind":"nhap","mst":"040091011932","tong":999,"name":"x.pdf"}]') r;
select pg_temp.check((select r->0->>'auto' from m1) = '00000000-0000-0000-0020-000000000001', 'ghép tự động theo MST + tiền');
select pg_temp.check((select r->1->>'auto' from m1) = '00000000-0000-0000-0020-000000000003', 'ghép phiếu sale B');
select pg_temp.check((select r->2->>'auto' from m1) is null and jsonb_array_length((select r->2->'cands' from m1)) = 2, 'lệch tiền: không tự ghép, đưa 2 phiếu cùng MST để chọn tay');
select public.out_file_attach('00000000-0000-0000-0020-000000000001', 'nhap', 'DRIVE-A-v1', 'NHAP_040091011932_23328000_20261031_1.pdf', 514, 23328000, '040091011932', null, null, '2026-10-31');
select public.out_file_attach('00000000-0000-0000-0020-000000000003', 'nhap', 'DRIVE-B-v1', 'NHAP_0700871570_11664000_20261102_1.pdf', 514, 11664000, '0700871570', null, null, '2026-11-02');
select pg_temp.check((select status from public.out_invoices where id='00000000-0000-0000-0020-000000000001') = 'da_nhap', 'có nháp → Đã xuất nháp');
select pg_temp.check((public.out_file_match('[{"i":0,"kind":"nhap","mst":"040091011932","tong":23328000,"name":"NHAP_040091011932_23328000_20261031_1.pdf"}]'))->0->>'dup' = 'true', 'tải lại cùng file → báo trùng');
reset role;
select pg_temp.check((select count(*) from public.notifications where link = '#/out?inv=00000000-0000-0000-0020-000000000001'
  and recipient_id = (select id from public.profiles where email='a@nt.vn')) = 1, 'sale A được báo có nháp');

-- Quyền xem: sale A xem phiếu mình; sale B không; trưởng nhóm của A xem được
select pg_temp.as_user('a@nt.vn'); set role authenticated;
create temp table fa as select (x->>'id')::uuid id from jsonb_array_elements(public.out_files_list('00000000-0000-0000-0020-000000000001')) x;
select pg_temp.check((select count(*) from fa) = 1, 'sale A thấy file của mình');
select pg_temp.check(public.out_files_list('00000000-0000-0000-0020-000000000001')::text not like '%DRIVE-A%', 'danh sách không lộ mã Drive');
create temp table va as select public.out_file_ticket((select id from fa)) t;
grant select on va to anon;
select pg_temp.check(pg_temp.fails($q$select public.out_files_list('00000000-0000-0000-0020-000000000003')$q$), 'sale A không xem danh sách file của B');
select pg_temp.check(pg_temp.fails($q$select public.out_file_ticket((select f.id from public.out_invoice_files f where f.invoice_id='00000000-0000-0000-0020-000000000003'))$q$), 'sale A không xin vé xem file của B');
reset role;
create temp table fb as select id from public.out_invoice_files where invoice_id='00000000-0000-0000-0020-000000000003';
grant select on fa, fb, va, tk to authenticated, anon;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check(pg_temp.fails($q$select public.out_file_ticket((select id from fb))$q$), 'sale A không xin vé xem file của B (theo mã file)');
reset role;
select pg_temp.as_user('lead@nt.vn'); set role authenticated;
select pg_temp.check(public.out_file_ticket((select id from fa)) is not null, 'trưởng nhóm xem được file của sale trong nhóm');
select pg_temp.check(pg_temp.fails($q$select public.out_file_ticket((select id from fb))$q$), 'trưởng nhóm không xem file sale ngoài nhóm');
reset role;
set role anon;
select pg_temp.check((public.drive_redeem('apps-script-secret-0123456789abcdef0123456789', (select t from va)))->>'drive_id' = 'DRIVE-A-v1', 'Apps Script đổi vé xem → đúng file');
select pg_temp.check(pg_temp.fails($q$select public.drive_redeem('apps-script-secret-0123456789abcdef0123456789', (select t from va))$q$), 'vé xem dùng 1 lần');
reset role;
select pg_temp.check((select count(*) from public.audit_logs where action='VIEW_HD_FILE' and actor_id=(select id from public.profiles where email='a@nt.vn')) = 1, 'ghi nhật ký người xem');

-- Sale gửi khách, khách OK v1 → kế toán tải v2 → xác nhận cũ hủy, sale phải xác nhận lại
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_file_sent((select id from fa));
select public.out_confirm_sign('00000000-0000-0000-0020-000000000001', 1);
reset role;
select pg_temp.check((select status from public.out_invoices where id='00000000-0000-0000-0020-000000000001') = 'xac_nhan_ky', 'khách OK → xác nhận ký');
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((public.out_file_attach('00000000-0000-0000-0020-000000000001', 'nhap', 'DRIVE-A-v2', 'NHAP_040091011932_23328000_20261102_7.pdf', 515, 23328000, '040091011932'))->>'version' = '2', 'bản nháp v2');
select pg_temp.check((public.out_invoices_page('{"status":"da_nhap","limit":50}')->>'chua_gui')::int >= 1, 'đếm nháp chưa gửi khách');
reset role;
select pg_temp.check((select status from public.out_invoices where id='00000000-0000-0000-0020-000000000001') = 'da_nhap', 'bản mới → xác nhận ký cũ hủy');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check(pg_temp.fails($q$select public.out_confirm_sign('00000000-0000-0000-0020-000000000001', 1)$q$), 'không xác nhận ký theo bản cũ');
select pg_temp.check((select (x->>'nhap_v')::int = 2 and (x->>'nhap_sent')::boolean = false from jsonb_array_elements(public.out_invoices_page('{"status":"da_nhap","limit":50}')->'rows') x
  where x->>'id' = '00000000-0000-0000-0020-000000000001'), 'danh sách: v2 chưa gửi');
select public.out_confirm_sign('00000000-0000-0000-0020-000000000001', 2);
reset role;

-- Bản đã ký: ghép theo MST + tiền, điền số HĐ, phiếu Đã ký
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((public.out_file_match('[{"i":0,"kind":"ky","mst":"040091011932","tong":23328000,"so_hd":"00000928","ky_hieu":"1C26TYY"}]'))->0->>'auto' = '00000000-0000-0000-0020-000000000001', 'ghép bản đã ký');
select public.out_file_attach('00000000-0000-0000-0020-000000000001', 'ky', 'DRIVE-A-KY', 'KY_1C26TYY-00000928_040091011932_23328000.pdf', 507, 23328000, '040091011932', '00000928', '1C26TYY', '2026-11-02');
select pg_temp.check((public.out_file_match('[{"i":0,"kind":"ky","mst":"040091011932","tong":23328000,"so_hd":"928"}]'))->0->>'dup' = 'true', 'bản ký đã tải → báo trùng');
select pg_temp.check(pg_temp.fails($q$select public.out_file_attach('00000000-0000-0000-0020-000000000001', 'nhap', 'X', 'x.pdf', 1, 1, '1')$q$), 'đã ký thì không gắn nháp mới');
select pg_temp.check(pg_temp.fails($q$select public.out_file_attach('00000000-0000-0000-0020-000000000001', 'ky', 'X', 'x.pdf', 1, 1, '1', '999')$q$), 'đã ký số khác → chặn');
reset role;
select pg_temp.check((select status = 'da_ky' and so_hd = '00000928' from public.out_invoices where id='00000000-0000-0000-0020-000000000001'), 'phiếu Đã ký, có số HĐ');
select pg_temp.check((select count(*) from public.notifications where title like 'HĐ đã ký số 00000928%') = 1, 'sale được báo bản đã ký');

select 'V20 TESTS PASSED' as result;
