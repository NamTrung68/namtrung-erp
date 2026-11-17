-- Kiểm thử bản 55: mở cập nhật → Sale điền đủ hồ sơ pháp nhân (cả mã HĐNT, bản scan); lọc đủ / thiếu hồ sơ
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into public.customers(id, code, contact_name, phone, customer_type, source, owner_id, sys_username)
  select '00000000-0000-0000-0055-0000000000c1', 'KHV55', 'Khách V55', '+84 912 550 055', 'nha_buon', 'tu_tim_zalo', id, 'khv55' from public.profiles where email = 'a@nt.vn';
insert into public.out_buyers(id, customer_id, username, name, tax_code, address, is_default) values
  ('00000000-0000-0000-0055-0000000000b1', '00000000-0000-0000-0055-0000000000c1', 'khv55', 'CÔNG TY V55', '0105500001', 'Số 1', true);
select pg_temp.as_user('kt@nt.vn'); set role authenticated; select public.out_pn_lock_set(true); reset role;

select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ declare r jsonb; begin
  r := public.out_buyers_page('{"q":"0105500001"}');
  perform pg_temp.check((r->'rows'->0->'thieu_hs') ?& array['Email', 'Người đại diện', 'Chức vụ', 'Người nhận', 'SĐT nhận'], 'liệt kê mục thiếu: ' || (r->'rows'->0->'thieu_hs')::text);
  perform pg_temp.check(jsonb_array_length(public.out_buyers_page('{"q":"0105500001","flag":"thieu_hs"}')->'rows') = 1, 'lọc chưa nhập đủ');
  perform pg_temp.check(jsonb_array_length(public.out_buyers_page('{"q":"0105500001","flag":"du_hs"}')->'rows') = 0, 'chưa đủ thì không ở lọc đủ');
  -- đang mở: sale điền mã + ngày HĐNT và đủ thông tin
  perform public.out_buyer_save('00000000-0000-0000-0055-0000000000b1', '{"username":"khv55","name":"CÔNG TY V55","tax_code":"0105500001","address":"Số 1","email":"v55@x.vn","dai_dien":"Ông A","chuc_vu":"Giám đốc","ma_hdnt":"05/05/2026/HĐNT/NT/V55","ngay_hdnt":"2026-05-05"}');
  perform public.out_buyer_doc_info('00000000-0000-0000-0055-0000000000b1', '{"nguoi_nhan":"Chị B","sdt_nhan":"0912550055"}');
  perform pg_temp.check((select ma_hdnt = '05/05/2026/HĐNT/NT/V55' and ngay_hdnt = '2026-05-05' from public.out_buyers where id = '00000000-0000-0000-0055-0000000000b1'), 'sale lưu được mã HĐNT khi mở');
  r := public.out_buyers_page('{"q":"0105500001"}');
  perform pg_temp.check(r->'rows'->0->'thieu_hs' = '["Scan HĐNT"]', 'có HĐNT thì cần scan: ' || (r->'rows'->0->'thieu_hs')::text);
  -- sale tải scan HĐNT của pháp nhân khách mình
  r := public.ho_so_scan_add('{"buyer_id":"00000000-0000-0000-0055-0000000000b1","kinds":["hdnt"],"drive_id":"drv55","file_name":"hdnt.pdf"}');
  perform pg_temp.check(jsonb_array_length(public.out_buyers_page('{"q":"0105500001","flag":"du_hs"}')->'rows') = 1, 'đủ hồ sơ sau khi tải scan');
  perform pg_temp.check((public.out_buyers_page('{}')->'counts'->>'du_hs')::int >= 1, 'đếm đủ hồ sơ');
  perform pg_temp.err($q$select public.drive_upload_tickets(array['Ke toan/Doi soat/2026-11'])$q$, 'chỉ tải được bản scan hồ sơ pháp nhân');
end $$;
reset role;
select id as scan55 from public.ho_so_scans where drive_id = 'drv55' \gset
-- sale khác không tải scan cho khách không phụ trách
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.err($$select public.ho_so_scan_add('{"buyer_id":"00000000-0000-0000-0055-0000000000b1","kinds":["hdnt"],"drive_id":"x"}')$$, 'Chỉ Kế toán');
select pg_temp.err(format('select public.ho_so_scan_del(%L::uuid)', :'scan55'), 'Chỉ Kế toán');
reset role;
-- khóa: sale không tải / gỡ / sửa mã HĐNT nữa
select pg_temp.as_user('kt@nt.vn'); set role authenticated; select public.out_pn_lock_set(false); reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err(format('select public.ho_so_scan_del(%L::uuid)', :'scan55'), 'Chỉ Kế toán');
select pg_temp.err($$select public.drive_upload_tickets(array['Ho so khach hang/x/Hop dong NT-MB'])$$, 'Chỉ Kế toán');
reset role;
select pg_temp.as_user('kt@nt.vn'); set role authenticated; select public.out_pn_lock_set(true); reset role;
-- mở lại: sale gỡ được bản scan do chính mình tải
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.ho_so_scan_del(:'scan55'::uuid);
reset role;
select pg_temp.check((select deleted_at is not null from public.ho_so_scans where drive_id = 'drv55'), 'sale gỡ scan của mình');
select 'V55 TESTS PASSED' as result;
