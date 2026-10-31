-- Kiểm thử bản 13: dòng chưa có chủ (sale nhận / kế toán gán), chốt kèm giá khách, xuất thẳng, ghép dòng HĐ, mã KH
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into public.customers(source, customer_type, contact_name, company_name, sys_code, owner_id) values ('Khác', 'Doanh nghiệp', 'Anh Test', 'Cty Test 13', 'NT93844', (select id from public.profiles where email = 'b@nt.vn'));
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
create temp table t13 as select public.acc_truck_save(null, '{"name":"Xe 13"}', '[
 {"line_key":"U1","apt_stt":1,"luong":"A","status":"blocked","level":1,"hh":"HH71","gia_nhap":19000,"sl_apt":10,"issues":["Không có đơn"],"notes":[]},
 {"line_key":"U2","md":"MD7002","apt_stt":2,"sale_name":"trungdv22","ma_kh":"nt93844","luong":"A","status":"blocked","level":1,"hh":"HH72","gia_khach":0,"gia_nhap":100,"sl_apt":5,"issues":["Giá khách = 0"],"notes":[]},
 {"line_key":"U3","md":"MD7003","apt_stt":3,"sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"hh":"HH73","gia_khach":110,"gia_nhap":100,"sl_apt":5,"issues":["x"],"notes":[]}]') id;
reset role; grant select on t13 to authenticated;
select pg_temp.check((select customer_id is not null from public.acc_lines where line_key = 'U2' and truck_id = (select id from t13)), 'mã KH → khách ERP');

-- Sale A thấy dòng chưa có chủ, nhận dòng
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.acc_lines where line_key = 'U1') = 1, 'sale khác thấy dòng chưa có chủ');
select pg_temp.check((select count(*) from public.acc_lines where line_key = 'U3') = 0, 'không thấy dòng của sale khác');
do $$ begin perform public.acc_line_claim((select id from public.acc_lines where line_key = 'U1'), 'MD7001', null); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
select public.acc_line_claim((select id from public.acc_lines where line_key = 'U1'), 'md 7001', 20000, 'Đơn của khách em');
reset role;
select pg_temp.check((select status = 'replied' and claim_md = 'MD7001' and claim_gia = 20000 and sale_id = (select id from public.profiles where email = 'a@nt.vn') from public.acc_lines where line_key = 'U1'), 'nhận dòng → chờ kế toán');
-- Sale B không nhận chồng
select pg_temp.as_user('b@nt.vn'); set role authenticated;
do $$ begin perform public.acc_line_claim((select id from public.acc_lines where line_key = 'U2'), 'MD1', 1); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
-- Sale B: đã sửa hệ thống thiếu giá khách → chặn; có giá → ok
do $$ begin perform public.acc_line_reply((select id from public.acc_lines where line_key = 'U2'), 'da_sua_ht'); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
select public.acc_line_reply((select id from public.acc_lines where line_key = 'U2'), 'da_sua_ht', null, null, null, 103);
select public.acc_line_reply((select id from public.acc_lines where line_key = 'U3'), 'xuat_thang', null, 'APT xuất thẳng cho khách');
reset role;
select pg_temp.check((select luong = 'C' and status = 'info' and phan_hoi = 'XUẤT THẲNG' from public.acc_lines where line_key = 'U3'), 'xuất thẳng đổi luồng ngay');
select pg_temp.check((select 'U3' = any(xt_keys) and 'MD7003' = any(md_xuat_thang) from public.acc_trucks where id = (select id from t13)), 'ghi xuất thẳng vào xe');

-- Kế toán chốt: giá lấy từ sale, biên > max → XUẤT GIÁ số liền
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_line_set((select id from public.acc_lines where line_key = 'U1'), 'ok', 'Đã kiểm');
select public.acc_line_set((select id from public.acc_lines where line_key = 'U2'), 'ok', null, 103);
reset role;
select pg_temp.check((select status = 'ok' and md = 'MD7001' and gia_khach = 20000 and phan_hoi = 'XUẤT GIÁ 19417' and issues = '{}' from public.acc_lines where line_key = 'U1'), 'chốt: MD + giá khách + đề xuất số liền');
select pg_temp.check((select status = 'ok' and phan_hoi = 'CHỐT' from public.acc_lines where line_key = 'U2'), 'chốt dòng giá 0 sau khi nhập giá');

-- Ghép tay dòng HĐ chưa thuộc xe
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_invoice_save('{"ky_hieu":"C26TYT","so_hd":"00013001","ngay":"2026-11-06","mst_ban":"0110746961"}',
  '[{"stt":1,"hh":"HH99","ten":"Hàng lạ","sl":5,"dg":100,"tt":500,"vat":"8%","line_id":null,"result":"khong_thuoc_xe"}]');
select public.acc_invoice_line_link((select l.id from public.acc_invoice_lines l join public.acc_invoices i on i.id = l.invoice_id where i.so_hd = '00013001'), (select id from public.acc_lines where line_key = 'U2'));
reset role;
select pg_temp.check((select inv_no = '00013001' from public.acc_lines where line_key = 'U2'), 'ghép tay dòng HĐ');
select 'V13 TESTS PASSED' as result;
