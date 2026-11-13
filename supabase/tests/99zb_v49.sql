-- Kiểm thử bản 49: nạp Excel pháp nhân đủ cột — ô trống giữ cũ, "-" xóa trắng, ★ mặc định
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into public.customers(id, code, contact_name, phone, customer_type, source, owner_id, sys_username)
  select '00000000-0000-0000-0049-0000000000c1', 'KHV49', 'Khách V49', '+84 912 490 049', 'nha_buon', 'tu_tim_zalo', id, 'khv49' from public.profiles where email = 'a@nt.vn';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
do $$ declare r jsonb; b public.out_buyers; begin
  -- mới: đủ cột
  r := public.out_buyers_import_v2('[{"tax_code":"0104949494","name":"Công ty V49","address":"Số 1 Hà Nội","email":"kt@v49.vn","username":"khv49","mac_dinh":"","note":"",
     "dai_dien":"Ông A","chuc_vu":"Giám đốc","dia_chi_giao":"Kho 2","ma_hdnt":"01/09/2026/HĐNTHH/NT/V49","ngay_hdnt":"","nguoi_nhan":"Chị B","sdt_nhan":"0912 345 678"}]');
  perform pg_temp.check((r->>'moi')::int = 1, 'thêm mới');
  select * into b from public.out_buyers where tax_code = '0104949494';
  perform pg_temp.check(b.note = 'Nạp Excel' and b.ngay_hdnt = '2026-09-01' and b.sdt_nhan is not null and b.nguoi_nhan = 'Chị B' and b.is_default, 'mặc định: ghi chú, ngày từ mã HĐNT, khách chưa có ★ → ★');
  -- cập nhật: tên trống giữ cũ, ô trống giữ cũ, "-" xóa email, đổi địa chỉ
  r := public.out_buyers_import_v2('[{"tax_code":"0104949494","name":"","address":"Số 9 Hà Nội","email":"-","username":"khv49","dai_dien":"","chuc_vu":"","nguoi_nhan":"","sdt_nhan":"","ma_hdnt":"","ngay_hdnt":""}]');
  perform pg_temp.check((r->>'sua')::int = 1, 'cập nhật');
  select * into b from public.out_buyers where tax_code = '0104949494';
  perform pg_temp.check(b.name = 'Công ty V49' and b.address = 'Số 9 Hà Nội' and b.email is null and b.dai_dien = 'Ông A' and b.nguoi_nhan = 'Chị B' and b.ma_hdnt is not null, 'trống giữ cũ, "-" xóa');
  -- "-" ở mã HĐNT xóa cả ngày
  r := public.out_buyers_import_v2('[{"tax_code":"0104949494","username":"khv49","ma_hdnt":"-"}]');
  select * into b from public.out_buyers where tax_code = '0104949494';
  perform pg_temp.check(b.ma_hdnt is null and b.ngay_hdnt is null, 'xóa mã HĐNT xóa ngày');
  -- pháp nhân thứ 2 có ★ → thành mặc định
  r := public.out_buyers_import_v2('[{"tax_code":"0104949495","name":"Công ty V49 B","username":"khv49","mac_dinh":"★"}]');
  perform pg_temp.check((select is_default from public.out_buyers where tax_code = '0104949495') and not (select is_default from public.out_buyers where tax_code = '0104949494'), '★ chuyển mặc định');
  -- lỗi: mới thiếu tên, SĐT sai, MST sai
  r := public.out_buyers_import_v2('[{"tax_code":"0104949496","name":"","username":"khv49"},{"tax_code":"0104949497","name":"X","username":"khv49","sdt_nhan":"123"},{"tax_code":"12","name":"Y"}]');
  perform pg_temp.check(jsonb_array_length(r->'loi') = 3, 'báo 3 dòng lỗi: ' || (r->'loi')::text);
end $$;
reset role;
select 'V49 TESTS PASSED' as result;
