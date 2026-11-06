-- Kiểm thử bản 32: file xe lệch cột ID ĐƠN ↔ USERNAME → sửa dòng đối soát thì dòng sổ theo; điền username; sale sửa trong phạm vi
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.check(app.kh_la_don('2689', 'MD2689') and app.kh_la_don('MD2707', 'MD2707') and app.kh_la_don('md 2445', 'MD2445'), 'username = số đơn → nghi lệch cột');
select pg_temp.check(not app.kh_la_don('tiendat2603', 'MD2603') and not app.kh_la_don('0866445988', 'MD2604') and not app.kh_la_don(null, 'MD1'), 'username thật (kể cả có số) không bị coi là số đơn');

insert into public.customers(id, code, company_name, contact_name, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0032-0000000000c1', 'KHV32A', 'HKD Bagu', 'Chị Bagu', 'nha_buon', 'tu_tim_zalo', '+84 912 320 001', id, 'bagu32' from public.profiles where email='a@nt.vn';
insert into public.customers(id, code, company_name, contact_name, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0032-0000000000c2', 'KHV32B', 'HKD Tiến Đạt', 'Anh Đạt', 'nha_buon', 'tu_tim_zalo', '+84 912 320 002', id, 'tien32' from public.profiles where email='a@nt.vn';
insert into public.acc_trucks(id, name) values ('00000000-0000-0000-0032-000000000001', 'XE3210');
-- Trạng thái do file xe lệch cột để lại: đơn trống / sai đơn, username = số đơn
insert into public.acc_lines(truck_id, line_key, ma_dong, ma_kb_apt, match_kind, md, sale_id, sale_name, ma_kh, apt_stt, ten_apt, sl_apt, gia_nhap, gia_khach, vat, luong, status) select
  '00000000-0000-0000-0032-000000000001', k, kb, kb, 'ma', md, (select id from public.profiles where email='a@nt.vn'), 'Sale A', kh, stt, ten, sl, gia, gk, 0.08, 'A', 'ok'
from (values
  ('A74', 'MD2689-1', null, '2689', 74, 'Ví tiền mini gấp 3 họa tiết mèo V32', 200, 18665, 19225),
  ('A93', 'MD2329-2', 'MD2603', '2329', 93, 'Tấm cách âm chất liệu nhựa Polypropylene V32', 4800, 9209, 9485)
) v(k, kb, md, kh, stt, ten, sl, gia, gk);

select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_items_import('[
 {"ma_hang":"HH00033-3210-2026","ten":"Ví tiền mini gấp 3 họa tiết mèo V32","dvt":"Chiếc","vat":0.08,"sl_nhap":200,"dg_nhap":18665,"so_hd_vao":"3210","ky_hieu":"C26TYT","ngay_vao":"2026-11-06"},
 {"ma_hang":"HH00052-3210-2026","ten":"Tấm cách âm chất liệu nhựa Polypropylene V32","dvt":"Chiếc","vat":0.08,"sl_nhap":4800,"dg_nhap":9209,"so_hd_vao":"3210","ky_hieu":"C26TYT","ngay_vao":"2026-11-06"}]');
reset role;
select pg_temp.check((select md is null and username = '2689' from public.out_items where ma_hang='HH00033-3210-2026'), 'tái hiện lỗi: không có đơn, username = số đơn');
select pg_temp.check((select md = 'MD2603' and username = '2329' from public.out_items where ma_hang='HH00052-3210-2026'), 'tái hiện lỗi: sai đơn MD2603');

-- 1) Sửa dòng đối soát (như nạp lại file xe đúng cột) → dòng sổ nhận đơn + username, tìm ra khách
update public.acc_lines set md = 'MD2689', ma_kh = 'bagu32' where line_key = 'A74' and truck_id = '00000000-0000-0000-0032-000000000001';
select pg_temp.check((select md = 'MD2689' and username = 'bagu32' and customer_id = '00000000-0000-0000-0032-0000000000c1' from public.out_items where ma_hang='HH00033-3210-2026'),
  'dòng đối soát đổi đơn + username → dòng sổ theo, gắn đúng khách');
select pg_temp.check(exists(select 1 from public.out_events e join public.out_items o on o.id = e.item_id where o.ma_hang='HH00033-3210-2026' and e.action = 'doi_don_kh' and e.data->>'username_cu' = '2689'), 'ghi nhật ký đổi đơn/khách');

-- 2) Nạp lại file xe mà file để trống username → giữ username đã có
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_truck_save('00000000-0000-0000-0032-000000000001', '{"name":"XE3210"}', (select jsonb_agg(jsonb_build_object('line_key', line_key, 'ma_dong', ma_dong, 'md', md, 'sale_name', 'Sale A',
  'ma_kh', case when line_key = 'A74' then '' else ma_kh end, 'apt_stt', apt_stt, 'ten_apt', ten_apt, 'sl_apt', sl_apt, 'gia_nhap', gia_nhap, 'gia_khach', gia_khach, 'vat', vat, 'luong', 'A', 'status', 'ok', 'level', 3))
  from public.acc_lines where truck_id = '00000000-0000-0000-0032-000000000001'));
reset role;
select pg_temp.check((select ma_kh from public.acc_lines where line_key = 'A74' and truck_id = '00000000-0000-0000-0032-000000000001') = 'bagu32', 'nạp lại file thiếu username → giữ username đã điền');
select pg_temp.check((select username from public.out_items where ma_hang='HH00033-3210-2026') = 'bagu32', 'dòng sổ vẫn giữ khách sau khi nạp lại');

-- 3) Sale ngoài phạm vi không sửa được; username = số đơn bị chặn; sale chủ dòng sửa được
select id as id52 from public.out_items where ma_hang='HH00052-3210-2026' \gset
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.err(format('select public.out_items_fix_kh(array[%L::uuid], %L, %L)', :'id52', 'MD2329', 'tien32'), 'không thuộc phạm vi');
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_items_fix_kh(array(select id from public.out_items where ma_hang='HH00052-3210-2026'), 'MD2329', '2329')$$, 'trùng số đơn');
select pg_temp.check(public.out_items_fix_kh(array(select id from public.out_items where ma_hang='HH00052-3210-2026'), '2329', 'tien32') = 1, 'sale chủ dòng sửa đơn + username');
reset role;
select pg_temp.check((select md = 'MD2329' and username = 'tien32' and customer_id = '00000000-0000-0000-0032-0000000000c2' and sale_id = (select id from public.profiles where email='a@nt.vn')
  from public.out_items where ma_hang='HH00052-3210-2026'), 'dòng sổ đúng đơn, đúng khách, giữ sale');
select pg_temp.check((select md = 'MD2329' and ma_kh = 'tien32' from public.acc_lines where line_key = 'A93' and truck_id = '00000000-0000-0000-0032-000000000001'), 'dòng đối soát sửa theo');

-- 4) Kế toán điền username trên màn nạp HĐ (dòng đối soát) — chỉ kế toán
update public.acc_lines set ma_kh = null where line_key = 'A93' and truck_id = '00000000-0000-0000-0032-000000000001';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.acc_lines_set_kh(array(select id from public.acc_lines where line_key = 'A93'), 'tien32')$$, 'Chỉ Kế toán');
reset role;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check(public.acc_lines_set_kh(array(select id from public.acc_lines where line_key = 'A93' and truck_id = '00000000-0000-0000-0032-000000000001'), ' tien32 ') = 1, 'kế toán điền username');
reset role;
select pg_temp.check((select username = 'tien32' and customer_id = '00000000-0000-0000-0032-0000000000c2' from public.out_items where ma_hang='HH00052-3210-2026'), 'username điền ở dòng đối soát → dòng sổ theo');

select 'V32 TESTS PASSED';
