-- Kiểm thử bản 17: tách dòng cùng mã hàng, đơn hàng lưu lại, MD dùng chung, nhận dòng, HĐ ↔ xe, view
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_items_import('[
 {"ma_hang":"HH00028-737-2026","part":1,"ten":"Giày búp bê","dvt":"Đôi","vat":0.08,"sl_nhap":231,"dg_nhap":77584,"so_hd_vao":"737","stt_hd":28,"md":"95823","nvkd":"trungdv22","username":"mguyenthuo","gia_so":80000},
 {"ma_hang":"HH00028-737-2026","part":2,"ten":"Giày búp bê","dvt":"Đôi","vat":0.08,"sl_nhap":110,"dg_nhap":77584,"so_hd_vao":"737","stt_hd":28,"md":"95906","nvkd":"trungdv22","gia_so":80000},
 {"ma_hang":"HH0001-738-2026","ten":"Ấm","dvt":"Bộ","vat":0.08,"sl_nhap":10,"dg_nhap":100,"so_hd_vao":"738","stt_hd":1,"md":"MD3001","gia_so":105},
 {"ma_hang":"HH0002-738-2026","ten":"Cốc","dvt":"Cái","vat":0.08,"sl_nhap":5,"dg_nhap":50,"so_hd_vao":"738","stt_hd":2,"md":"MD3001","nvkd":"trungdv22"},
 {"ma_hang":"HH0003-738-2026","ten":"Đĩa","dvt":"Cái","vat":0.08,"sl_nhap":5,"dg_nhap":50,"so_hd_vao":"738","stt_hd":3,"md":"MD3002"},
 {"ma_hang":"HH0004-738-2026","ten":"Thìa","dvt":"Cái","vat":0.08,"sl_nhap":7,"dg_nhap":50,"so_hd_vao":"738","stt_hd":4,"md":"MD3009"}]');
select public.out_legacy_import('[{"status":"da_ky","so_hd":"1333","ngay":"2026-07-23","info":"HỘ KINH DOANH NGUYỄN THỊ THƯƠNG","buyer_name":"HỘ KINH DOANH NGUYỄN THỊ THƯƠNG","lines":[{"ma_hang":"HH00028-737-2026","part":1,"sl":231,"gia":80000}]}]');
select public.out_orders_import('[{"md":"MD3002","username":"lethucphuong11","nvkd":"trungdv22"}]');
select public.out_hd_xe_set('[{"so_hd":"738","xe":"Xe 25/10"}]');
reset role;
select pg_temp.check((select count(*) from public.out_items where ma_hang='HH00028-737-2026') = 2, 'mã hàng chia 2 dòng không gộp');
select pg_temp.check((select ton from public.out_items_v where ma_hang='HH00028-737-2026' and part=1) = 0 and (select ton from public.out_items_v where ma_hang='HH00028-737-2026' and part=2) = 110, 'đã ký hết tồn, dòng kia còn');
select pg_temp.check((select gia_khach from public.out_items where ma_hang='HH00028-737-2026' and part=2) = 80000, 'giá xuất theo sổ');
select pg_temp.check((select sale_id is not null from public.out_items where ma_hang='HH0001-738-2026'), 'MD dùng chung sale với dòng cùng đơn');
select pg_temp.check((select username = 'lethucphuong11' and sale_id is not null from public.out_items where ma_hang='HH0003-738-2026'), 'file đơn hàng gắn khách + sale');
select pg_temp.check((select username from public.out_orders where md='MD3002') = 'lethucphuong11', 'lưu file đơn hàng');
select pg_temp.check((select xe from public.out_items_v where ma_hang='HH0001-738-2026') = 'Xe 25/10', 'HĐ vào ↔ xe');
-- Sale A nhận dòng MD3009, tra mã đơn
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((public.out_md_lookup('3002')->>'username') = 'lethucphuong11', 'tra mã đơn ra username');
select pg_temp.check(public.out_item_claim((select id from public.out_items where ma_hang='HH0004-738-2026'), 'md3009', 'khachmoi', 60) = 1, 'sale nhận dòng');
reset role;
select pg_temp.check((select sale_id = (select id from public.profiles where email='a@nt.vn') and username = 'khachmoi' and gia_khach = 60 from public.out_items where ma_hang='HH0004-738-2026'), 'nhận dòng lưu MD, user, giá');
-- Phiếu đã ký sổ cũ thuộc sale → sale thấy ở "Đã ký"
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.out_invoices where legacy and status='da_ky' and so_hd='1333') = 1, 'sale thấy phiếu đã ký sổ cũ');
reset role;
select 'V17 TESTS PASSED' as result;
