\set ON_ERROR_STOP 1
-- Bản 31: tạo HĐ nháp MISA bằng API (chạy song song cách làm tay)
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = p_email), false); end $$;
create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin begin execute p_sql; exception when others then if sqlerrm not ilike '%' || p_like || '%' then raise exception 'Sai lỗi: % (mong đợi %)', sqlerrm, p_like; end if; return; end;
  raise exception 'Mong đợi lỗi "%"', p_like; end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$ begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

update public.settings set value = jsonb_set(value, '{misa}', '{"enabled":true,"template_id":"tpl-1","inv_series":"1C26TYY","with_code":true,"batch":10}') where key = 'accounting';
update public.profiles set employee_code = 'NV001' where email = 'a@nt.vn';

-- Dòng hàng + phiếu: M1 (sale A, 2 thuế suất), M2 (sale B), M3 (sale A, MST sai), M4 (sale A, đã xuất Excel tay)
insert into public.out_items(id, ma_hang, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id) values
 ('00000000-0000-0000-0031-0000000000a1', 'HH00001-3100-2026', 'Giày tập đi trẻ em', 'Đôi', 0.08, 300, 85000, 'MD3101', (select id from public.profiles where email='a@nt.vn')),
 ('00000000-0000-0000-0031-0000000000a2', 'HH00002-3100-2026', 'Cốc sứ trắng', 'Cái', 0.1, 10, 70000, 'MD3102', (select id from public.profiles where email='a@nt.vn')),
 ('00000000-0000-0000-0031-0000000000a3', 'HH00003-3100-2026', 'Hộp giấy', 'Chiếc', 0.08, 50, 10000, 'MD3103', (select id from public.profiles where email='b@nt.vn'));
insert into public.out_invoices(id, code, sale_id, buyer_name, tax_code, address, email, status, version) values
 ('00000000-0000-0000-0031-0000000000b1', 'XHD31001', (select id from public.profiles where email='a@nt.vn'), 'HỘ KINH DOANH THỦY', '001182015117', 'Phúc Lộc, Hà Nội', 'thuy@x.vn', 'cho_nhap', 1),
 ('00000000-0000-0000-0031-0000000000b2', 'XHD31002', (select id from public.profiles where email='b@nt.vn'), 'CÔNG TY B', '0101234567', 'Hà Nội', null, 'cho_nhap', 1),
 ('00000000-0000-0000-0031-0000000000b3', 'XHD31003', (select id from public.profiles where email='a@nt.vn'), 'Khách sai MST', '12345', 'Hà Nội', null, 'cho_nhap', 1),
 ('00000000-0000-0000-0031-0000000000b4', 'XHD31004', (select id from public.profiles where email='a@nt.vn'), 'Khách làm tay', '0109999999', 'Hà Nội', null, 'cho_nhap', 1);
insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values
 ('00000000-0000-0000-0031-0000000000b1', '00000000-0000-0000-0031-0000000000a1', 1, 300, 90000, 0.08),
 ('00000000-0000-0000-0031-0000000000b1', '00000000-0000-0000-0031-0000000000a2', 2, 3, 72333, 0.1),
 ('00000000-0000-0000-0031-0000000000b2', '00000000-0000-0000-0031-0000000000a3', 1, 50, 10500, 0.08),
 ('00000000-0000-0000-0031-0000000000b3', '00000000-0000-0000-0031-0000000000a2', 1, 2, 72000, 0.1),
 ('00000000-0000-0000-0031-0000000000b4', '00000000-0000-0000-0031-0000000000a2', 1, 1, 72000, 0.1);
update public.out_invoices set misa_at = now() where id = '00000000-0000-0000-0031-0000000000b4';

-- 1. Dữ liệu gửi MISA: làm tròn từng dòng, 2 thuế suất, thuế 0,08 → 8
select pg_temp.check((select (p->>'TotalSaleAmountOC')::numeric = 27216999 and (p->>'TotalVATAmountOC')::numeric = 2181700 and (p->>'TotalAmountOC')::numeric = 29398699
   and p->'InvoiceDetails'->0->>'VATRate' = '8' and p->'InvoiceDetails'->1->>'VATRate' = '10' and (p->'InvoiceDetails'->1->>'AmountOC')::numeric = 216999
   and not (p ? 'VATRate') and p->>'CustomField1' = 'XHD31001' and p->>'CustomField2' = 'NV001' and p->>'CustomField3' = 'MD3101, MD3102'
   and p->>'InvSeries' = '1C26TYY' and p->>'InvoiceTemplateID' = 'tpl-1' and p->>'AccountObjectTaxCode' = '001182015117'
   and (p->>'TotalAmountOC')::numeric = app.out_inv_total('00000000-0000-0000-0031-0000000000b1')
  from (select app.out_misa_payload('00000000-0000-0000-0031-0000000000b1', gen_random_uuid()) p) z), 'payload đúng tiền, 2 thuế suất, CustomField');

-- 2. Sale không được tạo nháp; kế toán kiểm tra: MST sai bị chặn, phiếu đã xuất Excel bị chặn
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.out_misa_check(array['00000000-0000-0000-0031-0000000000b1'::uuid])$$, 'Chỉ Kế toán');
select pg_temp.expect_error($$select public.out_misa_claim(array['00000000-0000-0000-0031-0000000000b1'::uuid])$$, 'Chỉ Kế toán');
reset role; select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select (x->>'ok')::boolean from jsonb_array_elements(public.out_misa_check(array['00000000-0000-0000-0031-0000000000b1'::uuid])) x), 'phiếu đủ thông tin → đạt');
select pg_temp.check((select x->>'errors' like '%sai dạng%' from jsonb_array_elements(public.out_misa_check(array['00000000-0000-0000-0031-0000000000b3'::uuid])) x), 'MST sai → chặn');
select pg_temp.check((select x->>'errors' like '%Đã xuất Excel%' from jsonb_array_elements(public.out_misa_check(array['00000000-0000-0000-0031-0000000000b4'::uuid])) x), 'đã xuất Excel tay → chặn API');

-- 3. Bấm 2 lần → chỉ 1 nháp
select public.out_misa_claim(array['00000000-0000-0000-0031-0000000000b1'::uuid, '00000000-0000-0000-0031-0000000000b2'::uuid]);
select pg_temp.check((select x->>'errors' like '%Đang tạo%' from jsonb_array_elements(public.out_misa_claim(array['00000000-0000-0000-0031-0000000000b1'::uuid])) x), 'bấm lần 2 → bị chặn');
reset role;
select pg_temp.check((select count(*) = 1 from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1'), 'chỉ 1 dòng nháp');
select pg_temp.expect_error($$insert into public.out_misa(invoice_id, lan, trang_thai) values ('00000000-0000-0000-0031-0000000000b1', 9, 'dang_tao')$$, 'duplicate');
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_misa_result((select jsonb_agg(jsonb_build_object('hd_id', id, 'ok', true, 'misa_tong_tt', tong_tt, 'misa_tien_thue', tien_thue)) from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1'));
select public.out_misa_result((select jsonb_agg(jsonb_build_object('hd_id', id, 'ok', false, 'loi_ma', 'InvalidTaxCode', 'loi_text', 'InvalidTaxCode: Mã số thuế không hợp lệ')) from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b2'));
reset role;
select pg_temp.check((select trang_thai = 'da_tao' and khop from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1'), 'tạo xong, khớp tiền');
select pg_temp.check((select misa_at is not null from public.out_invoices where id = '00000000-0000-0000-0031-0000000000b1'), 'ghi mốc export');
select pg_temp.check((select trang_thai = 'loi' and loi_text like 'InvalidTaxCode%' from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b2'), 'lỗi MISA lưu nguyên văn');
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select x->>'errors' like '%Đã có nháp MISA%' from jsonb_array_elements(public.out_misa_claim(array['00000000-0000-0000-0031-0000000000b1'::uuid])) x), 'đã có nháp → không tạo thêm');
-- phiếu lỗi được tạo lại với RefID mới
select public.out_misa_claim(array['00000000-0000-0000-0031-0000000000b2'::uuid]);
reset role;
select pg_temp.check((select count(distinct ref_id) = 2 and max(lan) = 2 from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b2'), 'tạo lại → lần 2, RefID mới');

-- 4. Phân quyền xem: sale A không thấy của B; CSKH của A thấy A; trưởng nhóm thấy A
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) = 1 from public.out_misa), 'sale A chỉ thấy nháp của mình');
reset role; select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) = 2 and bool_and(sale_id = (select id from public.profiles where email='b@nt.vn')) from public.out_misa), 'sale B chỉ thấy của B');
select pg_temp.expect_error($$insert into public.out_misa(invoice_id, lan) values ('00000000-0000-0000-0031-0000000000b2', 5)$$, 'permission');
reset role; select pg_temp.as_user('cskh1@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) = 1 from public.out_misa), 'CSKH thấy nháp của sale mình hỗ trợ');
reset role; select pg_temp.as_user('lead@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) = 1 from public.out_misa), 'trưởng nhóm thấy nháp của cấp dưới');
reset role;

-- 5. Không hủy phiếu khi còn nháp sống trên MISA; xóa nháp → hủy được
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.out_invoice_status(array['00000000-0000-0000-0031-0000000000b1'::uuid], 'huy', 'thử')$$, 'đang có nháp trên MISA');
-- 6. Làm tay → bỏ mốc export → tạo API được
select public.out_misa_clear_export(array['00000000-0000-0000-0031-0000000000b4'::uuid]);
select pg_temp.check((select (x->>'ok')::boolean from jsonb_array_elements(public.out_misa_check(array['00000000-0000-0000-0031-0000000000b4'::uuid])) x), 'bỏ mốc export → tạo API được');
reset role;

-- 7. Sale sửa phiếu sau nháp → nháp thành bản cũ → claim trả need_delete; xóa → phiếu về chờ export
update public.out_invoices set version = 2 where id = '00000000-0000-0000-0031-0000000000b1';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select x ? 'need_delete' from jsonb_array_elements(public.out_misa_claim(array['00000000-0000-0000-0031-0000000000b1'::uuid])) x), 'nháp cũ → yêu cầu xóa trước');
select public.out_misa_deleted((select id from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1' and lan = 1), 'Tạo lại nháp');
select public.out_misa_claim(array['00000000-0000-0000-0031-0000000000b1'::uuid]);
reset role;
select pg_temp.check((select trang_thai = 'dang_tao' and invoice_version = 2 from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1' and lan = 2), 'tạo lại lần 2 theo phiên bản mới');

-- 8. Dò MISA (máy chủ): đã ký có mã tra cứu → phiếu Đã ký; token chỉ máy chủ đọc được
update public.out_invoices set misa_at = null where id = '00000000-0000-0000-0031-0000000000b1';
set role service_role;
select public.out_misa_sync_result((select jsonb_agg(jsonb_build_object('hd_id', id, 'found', true, 'inv_no', '<Chưa cấp số>')) from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1' and lan = 2));
reset role;
select pg_temp.check((select trang_thai = 'da_tao' from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1' and lan = 2), 'đang tạo + có trên MISA → đã tạo');
update public.out_invoices set status = 'xac_nhan_ky' where id = '00000000-0000-0000-0031-0000000000b1';
set role service_role;
select public.out_misa_sync_result((select jsonb_agg(jsonb_build_object('hd_id', id, 'found', true, 'inv_no', '00000123', 'ma_tra_cuu', 'abc12345xyz')) from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1' and lan = 2));
select public.misa_token_put('tok-1');
select pg_temp.check((select public.misa_token_get()->>'token' = 'tok-1'), 'máy chủ đọc token');
reset role;
select pg_temp.check((select status = 'da_ky' and so_hd = '00000123' and ma_tra_cuu = 'ABC12345XYZ' from public.out_invoices where id = '00000000-0000-0000-0031-0000000000b1'), 'tự chuyển Đã ký + mã tra cứu');
select pg_temp.check((select trang_thai = 'da_phat_hanh' from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1' and lan = 2), 'nháp → đã phát hành');
select pg_temp.check((select count(*) = 1 from public.notifications where title = 'Đã ký HĐ: XHD31001'), 'báo sale đã ký');
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.misa_token_get()$$, 'permission');
select pg_temp.expect_error($$select public.out_misa_deleted((select id from public.out_misa where invoice_id = '00000000-0000-0000-0031-0000000000b1' and lan = 2))$$, 'đã phát hành');
reset role;
select pg_temp.check((select count(*) = 1 from cron.job where jobname = 'nt_misa_sync'), 'có lịch dò MISA');
select pg_temp.check((select (r->'mf'->>'api_loi')::int >= 0 from (select public.out_invoices_page('{"limit":0}') r) z), 'danh sách phiếu trả đếm MISA');
select 'V31 TESTS PASSED' as result;
