-- Kiểm thử bản 47: chuẩn hóa địa chỉ, nguồn chứng thực HĐNT, cờ pháp nhân
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.check(app.dc_norm('Phường Tây Hồ, TP Hà Nội, Việt Nam') = app.dc_norm('Phường Tây Hồ, Thành phố Hà Nội'), 'TP = Thành phố, bỏ đuôi Việt Nam');
select pg_temp.check(app.dc_norm('TDP HOA VÔI, Xã Quốc Oai') = app.dc_norm('Tổ dân phố Hoa Vôi, Xã Quốc Oai'), 'TDP = Tổ dân phố');
select pg_temp.check(app.dc_norm('Số nhà 70 đường X') = app.dc_norm('Số 70, đường X'), 'Số nhà = Số');
select pg_temp.check(app.dc_norm('Phường Đạo Thạnh, Đồng Tháp') = app.dc_norm('Phường Đạo Thạnh, Tỉnh Đồng Tháp'), 'bỏ tiền tố Tỉnh');
select pg_temp.check(app.dc_norm('Thôn Hoa Vôi, Xã Quốc Oai') <> app.dc_norm('TDP Hoa Vôi, Xã Quốc Oai'), 'Thôn ≠ Tổ dân phố');
select pg_temp.check(app.dc_norm('Thị Trấn Hậu Lộc') <> app.dc_norm('Xã Hậu Lộc'), 'Thị trấn ≠ Xã');
select pg_temp.check(app.dc_norm('50/59/13 Đặng Thai Mai') <> app.dc_norm('50/59/31 Đặng Thai Mai'), 'giữ số nhà có dấu /');

-- pháp nhân đã ký HĐNT là nguồn chứng thực
insert into public.out_buyers(id, customer_id, name, tax_code, address, ma_hdnt, ngay_hdnt)
values ('00000000-0000-0000-0047-0000000000b1', null, 'Công ty TNHH Lan Anh', '0108888888', 'Số 5 Trần Phú, TP Hà Nội', 'HDNT-47', '2026-10-01');
insert into public.out_invoices(id, code, sale_id, buyer_name, tax_code, address, status)
select x.id::uuid, x.code, p.id, x.ten, x.mst, x.dc, 'cho_nhap' from public.profiles p,
 (values ('00000000-0000-0000-0047-0000000000c1', 'XHD47001', 'CÔNG TY TNHH LAN ANH', '0108888888', 'Số nhà 5, Trần Phú, Thành phố Hà Nội, Việt Nam'),
         ('00000000-0000-0000-0047-0000000000c2', 'XHD47002', 'Công ty TNHH Lan Anh', '0108888888', 'Số 7 Trần Phú, Hà Nội'),
         ('00000000-0000-0000-0047-0000000000c3', 'XHD47003', 'Công ty X', '12345', 'Hà Nội')) x(id, code, ten, mst, dc)
 where p.email = 'a@nt.vn';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
do $$ declare r jsonb; begin
  r := public.out_pn_check(array['00000000-0000-0000-0047-0000000000c1', '00000000-0000-0000-0047-0000000000c2', '00000000-0000-0000-0047-0000000000c3']::uuid[]);
  perform pg_temp.check(r->'00000000-0000-0000-0047-0000000000c1'->>'st' = 'khop', 'khớp pháp nhân HĐNT dù viết khác (Số nhà / TP / Việt Nam)');
  perform pg_temp.check(r->'00000000-0000-0000-0047-0000000000c1'->'src'->>'loai' = 'hdnt', 'nguồn = HĐNT');
  perform pg_temp.check(r->'00000000-0000-0000-0047-0000000000c2'->>'st' = 'lech' and r->'00000000-0000-0000-0047-0000000000c2'->'diff' = '["dia_chi"]', 'khác số nhà → lệch địa chỉ');
  perform pg_temp.check(r->'00000000-0000-0000-0047-0000000000c3'->>'st' = 'mst_sai', 'MST sai dạng');
end $$;
select pg_temp.check((public.out_buyers_page('{"flag":"hdnt"}')->'counts'->>'hdnt')::int >= 1, 'đếm pháp nhân đã ký HĐNT');
select pg_temp.check((select bool_and((x->>'hdnt')::boolean) from jsonb_array_elements(public.out_buyers_page('{"flag":"hdnt"}')->'rows') x), 'lọc HĐNT chỉ ra pháp nhân có HĐNT');
reset role;
select pg_temp.check(to_regclass('app.out_buyers_bak_v47') is not null, 'đã tạo bảng sao lưu');
select 'V47 TESTS PASSED' as result;
