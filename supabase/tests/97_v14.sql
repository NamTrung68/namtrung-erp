-- Kiểm thử bản 14: gửi giá đề xuất, nhầm sale/đơn, dòng thừa, nạp lại giữ xử lý tay; Xuất HĐ đầu ra
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.as_user('kt@nt.vn'); set role authenticated;
create temp table t14 as select public.acc_truck_save(null, '{"name":"Xe 14"}', '[
 {"line_key":"P1","md":"MD8101","apt_stt":1,"hh":"HH8101","sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"gia_khach":128700,"gia_nhap":123193,"gia_ap_dung":123193,"gia_de_xuat":124951,"sl_apt":30,"issues":["Biên NT 4.47% > 4%"],"notes":[]},
 {"line_key":"P2","md":"MD8102","apt_stt":2,"hh":"HH8102","sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"gia_khach":100,"gia_nhap":90,"sl_apt":5,"issues":["x"],"notes":[]},
 {"line_key":"P3","md":"MD8103","apt_stt":3,"hh":"HH8103","sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"gia_khach":100,"gia_nhap":97,"sl_apt":5,"issues":["x"],"notes":[]},
 {"line_key":"S1","md":"MD8104","sale_name":"trungdv22","luong":"E","status":"blocked","level":2,"gia_khach":100,"sl_ht":5,"issues":["Không lên xe"],"notes":[]}]') id;
reset role; grant select on t14 to authenticated;

select pg_temp.as_user('b@nt.vn'); set role authenticated;
select public.acc_line_reply((select id from public.acc_lines where line_key='P1' and truck_id=(select id from t14)), 'da_gui_gia', null, 'Đã gửi Zalo APT');
select public.acc_line_reply((select id from public.acc_lines where line_key='P2' and truck_id=(select id from t14)), 'nham', null, 'Hàng của chị Trang', null, null, 'khong_phai');
select public.acc_line_reply((select id from public.acc_lines where line_key='P3' and truck_id=(select id from t14)), 'nham', null, null, '8999', null, 'sai_md');
select public.acc_line_reply((select id from public.acc_lines where line_key='S1' and truck_id=(select id from t14)), 'dong_thua', null, 'Khai trùng', null, null, 'thua');
select pg_temp.check((select count(*) from public.acc_lines where line_key='P2') = 0, 'nhả xong sale B không còn thấy (đã nhả, không phải người khác nhận)') where false;
reset role;
select pg_temp.check((select status = 'ok' and gia_nhap = 124951 and gia_nhap_goc = 123193 and phan_hoi = 'XUẤT GIÁ 124951' and round(bien_nt, 4) = round(128700/124951.0 - 1, 4) from public.acc_lines where line_key='P1'), 'gửi giá đề xuất → tự chốt');
select pg_temp.check((select status = 'blocked' and sale_id is null and released_from is not null from public.acc_lines where line_key='P2'), 'nhầm sale → nhả dòng');
select pg_temp.check((select status = 'replied' and claim_md = 'MD8999' from public.acc_lines where line_key='P3'), 'sai MD → chờ kế toán');
-- Sale A thấy dòng nhả, nhận
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.acc_lines where line_key='P2') = 1, 'sale khác thấy dòng nhả');
select public.acc_line_claim((select id from public.acc_lines where line_key='P2'), 'MD8102', null);
reset role;
-- Kế toán chốt
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_line_set((select id from public.acc_lines where line_key='P3'), 'ok');
select public.acc_line_set((select id from public.acc_lines where line_key='S1'), 'ok');
-- Nạp lại file y như cũ: giữ xử lý tay
select public.acc_truck_save((select id from t14), '{"name":"Xe 14"}', '[
 {"line_key":"P1","md":"MD8101","apt_stt":1,"hh":"HH8101","sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"gia_khach":128700,"gia_nhap":123193,"gia_ap_dung":123193,"gia_de_xuat":124951,"sl_apt":30,"issues":["Biên NT 4.47% > 4%"],"notes":[]},
 {"line_key":"P2","md":"MD8102","apt_stt":2,"hh":"HH8102","sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"gia_khach":100,"gia_nhap":90,"sl_apt":5,"issues":["x"],"notes":[]},
 {"line_key":"P3","md":"MD8103","apt_stt":3,"hh":"HH8103","sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"gia_khach":100,"gia_nhap":97,"sl_apt":5,"issues":["x"],"notes":[]},
 {"line_key":"S1","md":"MD8104","sale_name":"trungdv22","luong":"E","status":"blocked","level":2,"gia_khach":100,"sl_ht":5,"issues":["Không lên xe"],"notes":[]}]');
reset role;
select pg_temp.check((select status = 'ok' and gia_nhap = 124951 from public.acc_lines where line_key='P1'), 'nạp lại giữ giá đã gửi');
select pg_temp.check((select status = 'replied' and sale_id = (select id from public.profiles where email='a@nt.vn') from public.acc_lines where line_key='P2'), 'nạp lại giữ sale đã nhận, không trả về sale nhả');
select pg_temp.check((select status = 'ok' and md = 'MD8999' from public.acc_lines where line_key='P3'), 'nạp lại giữ MD đúng');
select pg_temp.check((select status = 'info' from public.acc_lines where line_key='S1'), 'dòng thừa đóng');

-- ===== Xuất HĐ đầu ra =====
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_invoice_save('{"ky_hieu":"C26TYT","so_hd":"00008888","ngay":"2026-11-02","mst_ban":"0110746961"}',
  jsonb_build_array(jsonb_build_object('stt',1,'hh','HH8101','ten','Bộ ấm','sl',30,'dg',124951,'tt',3748530,'vat','8%','line_id',(select id from public.acc_lines where line_key='P1'),'result','khop')));
select pg_temp.check((public.out_items_import('[
  {"ma_hang":"HH0001-8888-2026","stt_so":1,"ten":"Bộ ấm","dvt":"Bộ","vat":0.08,"sl_nhap":30,"dg_nhap":124951,"so_hd_vao":"8888","ky_hieu":"C26TYT","stt_hd":1},
  {"ma_hang":"HH0002-8888-2026","stt_so":2,"ten":"Hàng lẻ","dvt":"Cái","vat":0.08,"sl_nhap":10,"dg_nhap":1000,"so_hd_vao":"8888","ky_hieu":"C26TYT","stt_hd":2},
  {"ma_hang":"HH0003-8888-2026","stt_so":3,"ten":"Hàng cũ","dvt":"Cái","vat":0.08,"sl_nhap":5,"dg_nhap":1000,"so_hd_vao":"8888","ky_hieu":"C26TYT","stt_hd":3,"md":"MD7777","nvkd":"trungdv22"}]',
  '[{"status":"da_ky","so_hd":"638","ngay":"2026-10-16","info":"CTY CŨ\nMST 0101","lines":[{"ma_hang":"HH0003-8888-2026","sl":5,"gia":1100}]}]')->>'legacy')::int = 1, 'nạp sổ + phiếu cũ');
reset role;
select pg_temp.check((select md = 'MD8101' and sale_id = (select id from public.profiles where email='b@nt.vn') and gia_khach = 128700 and match_src = 'hd_xml' from public.out_items where ma_hang='HH0001-8888-2026'), 'gắn đơn/sale theo HĐ XML');
select pg_temp.check((select sale_id is null from public.out_items where ma_hang='HH0002-8888-2026'), 'dòng chưa có sale');
select pg_temp.check((select ton = 0 from public.out_items_v where ma_hang='HH0003-8888-2026'), 'phiếu cũ trừ tồn');
-- Sale B lập phiếu chia 2 đơn vị
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.out_items) = 3, 'sale B thấy dòng của mình (2) + dòng chưa có sale');
do $$ begin perform public.out_invoice_save(null, '{"buyer_name":"HKD A"}', jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH0001-8888-2026'),'sl',31,'don_gia',128700))); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
create temp table tinv as select public.out_invoice_save(null, '{"buyer_name":"HKD Kim Hương","tax_code":"082195003202","address":"Thủ Đức","email":"a@x.vn","submit":true}',
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH0001-8888-2026'),'sl',20,'don_gia',128700))) id;
select public.out_invoice_save(null, '{"buyer_name":"HKD Hoài Vũ"}', jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH0001-8888-2026'),'sl',10,'don_gia',128700)));
select public.out_item_set((select id from public.out_items where ma_hang='HH0002-8888-2026'), 'MD8200', null);
reset role; grant select on tinv to authenticated;
select pg_temp.check((select ton = 0 from public.out_items_v where ma_hang='HH0001-8888-2026'), 'chia 2 đơn vị hết tồn');
select pg_temp.check((select status from public.out_invoices where id=(select id from tinv)) = 'cho_nhap', 'gửi kế toán');
select pg_temp.check((select count(*) from public.out_buyers) = 2, 'lưu đơn vị nhận HĐ');
select pg_temp.check((select sale_id = (select id from public.profiles where email='b@nt.vn') from public.out_items where ma_hang='HH0002-8888-2026'), 'sale nhận dòng');
-- Sale A không thấy phiếu của B
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.out_invoices) = 0, 'sale A không thấy phiếu B');
reset role;
-- Kế toán xuất nháp → sale xác nhận ký → kế toán ký
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_invoice_status(array[(select id from tinv)], 'da_nhap');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select public.out_comment((select id from tinv), 'Khách báo đổi địa chỉ');
select public.out_invoice_save((select id from tinv), '{"buyer_name":"HKD Kim Hương","tax_code":"082195003202","address":"Số 49 Đường 7, Thủ Đức"}',
  jsonb_build_array(jsonb_build_object('item_id',(select id from public.out_items where ma_hang='HH0001-8888-2026'),'sl',20,'don_gia',128700)));
reset role;
select pg_temp.check((select status = 'cho_nhap' and sua_sau_nhap from public.out_invoices where id=(select id from tinv)), 'sửa sau nháp → chờ xuất nháp lại');
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_invoice_status(array[(select id from tinv)], 'da_nhap');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select public.out_invoice_status(array[(select id from tinv)], 'xac_nhan_ky');
do $$ begin perform public.out_invoice_status(array[(select id from tinv)], 'da_ky', null, '700'); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
reset role;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
do $$ begin perform public.out_invoice_status(array[(select id from tinv)], 'da_ky'); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
select public.out_invoice_status(array[(select id from tinv)], 'da_ky', null, '700', '2026-11-05');
reset role;
select pg_temp.check((select status = 'da_ky' and so_hd = '700' from public.out_invoices where id=(select id from tinv)), 'đã ký');
select pg_temp.check((select count(*) from public.notifications where kind='acc' and title like 'Đã ký HĐ%') = 1, 'báo sale đã ký');
select 'V14 TESTS PASSED' as result;
