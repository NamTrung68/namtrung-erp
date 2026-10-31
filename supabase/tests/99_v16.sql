-- Kiểm thử bản 16: khớp nối đối soát ↔ XML ↔ sổ đầu ra
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.as_user('kt@nt.vn'); set role authenticated;
-- Sổ nạp TRƯỚC, chưa có XML, chưa có xe
select public.out_items_import('[{"ma_hang":"HH0001-7001-2026","ten":"Ấm","dvt":"Bộ","vat":0.08,"sl_nhap":10,"dg_nhap":100,"so_hd_vao":"7001","ky_hieu":"C26TYT","stt_hd":1},
  {"ma_hang":"HH0002-7001-2026","ten":"Cốc","dvt":"Cái","vat":0.08,"sl_nhap":5,"dg_nhap":50,"so_hd_vao":"7001","ky_hieu":"C26TYT","stt_hd":2,"md":"MD7102"}]');
-- Xe nạp sau
create temp table t16 as select public.acc_truck_save(null, '{"name":"Xe 16"}', '[
 {"line_key":"Q1","md":"MD7101","apt_stt":1,"hh":"HH7101","sale_name":"trungdv22","luong":"A","status":"ok","level":3,"gia_khach":103,"gia_nhap":100,"sl_apt":10,"issues":[],"notes":[]},
 {"line_key":"Q2","md":"MD7102","apt_stt":2,"hh":"HH7102","sale_name":"trungdv22","luong":"A","status":"ok","level":3,"gia_khach":52,"gia_nhap":50,"sl_apt":5,"issues":[],"notes":[]}]') id;
reset role; grant select on t16 to authenticated;
select pg_temp.check((select acc_line_id is not null and gia_khach = 52 and sale_id is not null from public.out_items where ma_hang='HH0002-7001-2026'), 'xe nạp sau → sổ gắn theo MD');
select pg_temp.check((select acc_line_id is null from public.out_items where ma_hang='HH0001-7001-2026'), 'dòng chưa có MD chờ XML');
-- XML về sau
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_invoice_save('{"ky_hieu":"C26TYT","so_hd":"00007001","ngay":"2026-11-02","mst_ban":"0110746961"}',
  jsonb_build_array(jsonb_build_object('stt',1,'hh','HH7101','ten','Ấm','sl',10,'dg',100,'tt',1000,'vat','8%','line_id',(select id from public.acc_lines where line_key='Q1'),'result','khop')));
reset role;
select pg_temp.check((select md = 'MD7101' and gia_khach = 103 and match_src = 'hd_xml' from public.out_items where ma_hang='HH0001-7001-2026'), 'XML về sau → sổ gắn theo HĐ');
-- Kế toán sửa giá khách ở đối soát → sổ cập nhật
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_line_set((select id from public.acc_lines where line_key='Q1'), 'ok', null, 104);
-- Sửa tay dòng sổ, nạp lại sổ có ID khác → giữ sửa tay
select public.out_item_set((select id from public.out_items where ma_hang='HH0002-7001-2026'), 'MD7999', (select id from public.profiles where email='a@nt.vn'));
select public.out_items_import('[{"ma_hang":"HH0002-7001-2026","ten":"Cốc","dvt":"Cái","vat":0.08,"sl_nhap":5,"dg_nhap":50,"so_hd_vao":"7001","ky_hieu":"C26TYT","stt_hd":2,"md":"MD7102","nvkd":"trungdv22"}]');
reset role;
select pg_temp.check((select gia_khach = 104 from public.out_items where ma_hang='HH0001-7001-2026'), 'chốt lại giá khách → sổ cập nhật');
select pg_temp.check((select md = 'MD7999' and sale_id = (select id from public.profiles where email='a@nt.vn') from public.out_items where ma_hang='HH0002-7001-2026'), 'nạp lại giữ dòng sửa tay');
-- Giá xuất thấp hơn giá nhập phải ghi lý do; lập phiếu nhớ khách
insert into public.customers(source, customer_type, contact_name, phone, owner_id) values ('Khác','Cá nhân','Khách 16','0912000016',(select id from public.profiles where email='b@nt.vn'));
create temp table tc16 as select id from public.customers where contact_name='Khách 16'; grant select on tc16 to authenticated;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
do $$ begin perform public.out_invoice_save(null, '{"buyer_name":"HKD X"}', jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH0001-7001-2026'),'sl',1,'don_gia',90))); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
select public.out_invoice_save(null, jsonb_build_object('buyer_name','HKD X','note','Hàng lỗi giảm giá','customer_id',(select id from tc16)),
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH0001-7001-2026'),'sl',1,'don_gia',90)));
reset role;
select pg_temp.check((select customer_id = (select id from public.customers where contact_name='Khách 16') from public.out_items where ma_hang='HH0001-7001-2026'), 'nhớ khách cho dòng');
-- Chuyển xe sau (dòng không lên xe) → kế toán chốt → đóng
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_truck_save((select id from t16), '{"name":"Xe 16"}', '[
 {"line_key":"Q1","md":"MD7101","apt_stt":1,"hh":"HH7101","sale_name":"trungdv22","luong":"A","status":"ok","level":3,"gia_khach":103,"gia_nhap":100,"sl_apt":10,"issues":[],"notes":[]},
 {"line_key":"Q2","md":"MD7102","apt_stt":2,"hh":"HH7102","sale_name":"trungdv22","luong":"A","status":"ok","level":3,"gia_khach":52,"gia_nhap":50,"sl_apt":5,"issues":[],"notes":[]},
 {"line_key":"SQ3","md":"MD7103","sale_name":"trungdv22","luong":"E","status":"blocked","level":2,"gia_khach":10,"sl_ht":5,"issues":["Không lên xe"],"notes":[]}]');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select public.acc_line_reply((select id from public.acc_lines where line_key='SQ3'), 'chuyen_xe_sau', null, 'đi xe 5/11');
reset role;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_line_set((select id from public.acc_lines where line_key='SQ3'), 'ok');
reset role;
select pg_temp.check((select status from public.acc_lines where line_key='SQ3') = 'info', 'chuyển xe sau → đóng');
select 'V16 TESTS PASSED' as result;
