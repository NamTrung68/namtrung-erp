-- Kiểm thử bản 12: HĐ nhiều đợt / một phần, HĐ về trước xe nạp sau, biên APT
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.as_user('kt@nt.vn'); set role authenticated;
-- HĐ về trước khi nạp xe (HH60)
select public.acc_invoice_save('{"ky_hieu":"C26TYT","so_hd":"00009001","ngay":"2026-11-02","mst_ban":"0110746961"}',
  '[{"stt":1,"hh":"HH60","ten":"Hàng 60","sl":10,"dg":100,"tt":1000,"vat":"8%","line_id":null,"result":"khong_thuoc_xe"}]');
create temp table t12 as select public.acc_truck_save(null, '{"name":"Xe 12"}', '[
 {"line_key":"A1","md":"MD8000","apt_stt":1,"sale_name":"trungdv22","luong":"A","status":"ok","level":3,"hh":"HH50","gia_khach":103,"gia_nhap":100,"gia_ap_dung":100,"sl_apt":100,"sl_tk":100,"gia_tk_nh":95,"tnk_dv":2.5,"issues":[],"notes":[]},
 {"line_key":"A2","md":"MD8001","apt_stt":2,"sale_name":"trungdv22","luong":"A","status":"ok","level":3,"hh":"HH60","gia_khach":103,"gia_nhap":100,"gia_ap_dung":100,"sl_apt":10,"sl_tk":10,"issues":[],"notes":[]}]') id;
select pg_temp.check(public.acc_relink_truck((select id from t12)) = 1, 'ghép HĐ về trước');
reset role;
grant select on t12 to authenticated;
select pg_temp.check((select inv_no = '00009001' and inv_result = 'khop' from public.acc_lines where line_key = 'A2' and truck_id = (select id from t12)), 'dòng xe nạp sau nhận HĐ cũ');
select pg_temp.check((select (stats->>'khop')::int = 1 from public.acc_invoices where so_hd = '00009001'), 'thống kê HĐ cập nhật');
select pg_temp.check((select round(bien_apt, 4) = round(100 / 97.5 - 1, 4) and gia_von = 97.5 from public.acc_lines where line_key = 'A1' and truck_id = (select id from t12)), 'biên APT theo tờ khai');
-- HH50 xuất 2 đợt: 60 rồi 40
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_invoice_save('{"ky_hieu":"C26TYT","so_hd":"00009002","ngay":"2026-11-03","mst_ban":"0110746961"}',
  jsonb_build_array(jsonb_build_object('stt',1,'hh','HH50','ten','Hàng 50','sl',60,'dg',100,'tt',6000,'vat','8%','line_id',(select id from public.acc_lines where hh='HH50'),'result','khop')));
reset role;
select pg_temp.check((select inv_result = 'mot_phan' and inv_qty = 60 from public.acc_lines where hh = 'HH50'), 'đợt 1: xuất một phần');
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_invoice_save('{"ky_hieu":"C26TYT","so_hd":"00009003","ngay":"2026-11-05","mst_ban":"0110746961"}',
  jsonb_build_array(jsonb_build_object('stt',1,'hh','HH50','ten','Hàng 50','sl',40,'dg',100,'tt',4000,'vat','8%','line_id',(select id from public.acc_lines where hh='HH50'),'result','khop')));
reset role;
select pg_temp.check((select inv_result = 'khop' and inv_qty = 100 and inv_no = '00009002, 00009003' from public.acc_lines where hh = 'HH50'), 'đợt 2: đủ số lượng, ghi cả 2 HĐ');
select 'V12 TESTS PASSED' as result;
