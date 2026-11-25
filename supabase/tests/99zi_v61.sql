-- Kiểm thử bản 61: nạp bù dòng thiếu vào xe đã nạp — chỉ thêm, không đụng dòng cũ; bỏ trùng; đánh số lại; dọn dòng "không lên xe"; HĐ ký ghép được
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into public.acc_trucks(id, name, stats) values ('00000000-0000-0000-0061-000000000001', 'Xe V61', '{"apt":3,"ok":2,"tt_apt":300000}');
insert into public.acc_lines(truck_id, line_key, ma_dong, ma_kb_apt, md, sale_id, sale_name, ma_kh, apt_stt, hh, ten_apt, sl_apt, gia_nhap, gia_ap_dung, gia_khach, bien_nt, tt_apt, tt_khach, vat, luong, status, phan_hoi, reply, reply_note) select
  '00000000-0000-0000-0061-000000000001', k, kb, kb, md, (select id from public.profiles where email='a@nt.vn'), 'Sale A', 'khv61', stt, hh, ten, sl, gia, gia, gk, gk / gia - 1, gia * sl, gk * sl, 0.08, 'A', st, 'CHỐT', rp, rn
from (values
  ('A5', 'MD6101-1', 'MD6101', 5, 'HH6105', 'Ấm V61', 100, 1000, 1030, 'ok', null, null),
  ('A6', 'MD6101-2', 'MD6101', 6, 'HH6106', 'Bình V61', 50, 2000, 2060, 'replied', 'da_sua_ht', 'đã sửa'),
  ('A100003', 'MD6102-1', 'MD6102', 100003, null, 'Hàng không STT V61', 10, 500, 515, 'ok', null, null)
) v(k, kb, md, stt, hh, ten, sl, gia, gk, st, rp, rn);
-- dòng "có trên hệ thống nhưng không lên xe" (thiếu trên nháp APT) — sẽ được nạp bù
insert into public.acc_lines(truck_id, line_key, ma_dong, md, sale_id, sale_name, ten_ht, sl_ht, gia_khach, luong, status, issues)
  select '00000000-0000-0000-0061-000000000001', 'SMD6103-1', 'MD6103-1', 'MD6103', id, 'Sale A', 'Quạt V61', 20, 3090, 'E', 'blocked', '{"Có trên hệ thống nhưng không có trên tờ khai/file APT xe này"}' from public.profiles where email='a@nt.vn';
create temp table goc61 as select * from public.acc_lines where truck_id = '00000000-0000-0000-0061-000000000001' and apt_stt is not null;
grant select on goc61 to authenticated;

-- quyền
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.acc_truck_append('00000000-0000-0000-0061-000000000001', '{}', '[{"line_key":"A9","apt_stt":9,"ten_apt":"x","luong":"A","status":"ok"}]')$$, 'Chỉ Kế toán');
reset role;

-- kế toán nạp bù file chỉ có mấy dòng thiếu (STT tự sinh của file bù bắt đầu lại từ 100000+)
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
create temp table r61 as select public.acc_truck_append('00000000-0000-0000-0061-000000000001', '{"file":"bu_xe_v61.xlsx","by":"KT"}', jsonb_build_array(
  -- 1) dòng mới thật, STT riêng
  jsonb_build_object('line_key','A7','apt_stt',7,'ma_dong','MD6103-1','ma_kb_apt','MD6103-1','md','MD6103','sale_name','Sale A','ma_kh','khv61','hh','HH6107','ten_apt','Quạt V61','sl_apt',20,'sl_ht',20,
    'gia_nhap',3000,'gia_ap_dung',3000,'gia_khach',3090,'bien_nt',0.03,'tt_apt',60000,'tt_khach',61800,'vat',0.08,'luong','A','status','ok','level',3,'phan_hoi','CHỐT','match_kind','ma'),
  -- 2) đã có trong xe (trùng mã khai báo + SL) → bỏ qua
  jsonb_build_object('line_key','A5','apt_stt',5,'ma_dong','MD6101-1','ma_kb_apt','MD6101-1','md','MD6101','sale_name','Sale A','ten_apt','Ấm V61 (gõ khác)','sl_apt',100,'gia_nhap',1000,'luong','A','status','ok'),
  -- 3) dòng không STT, số tự sinh 100003 trùng dòng cũ khác hàng → đánh số tiếp
  jsonb_build_object('line_key','A100003','apt_stt',100003,'ma_dong','MD6104-1','ma_kb_apt','MD6104-1','md','MD6104','sale_name','Sale A','ten_apt','Ổ cắm V61','sl_apt',30,
    'gia_nhap',700,'gia_ap_dung',700,'gia_khach',721,'tt_apt',21000,'luong','A','status','ok','phan_hoi','CHỐT'),
  -- 4) STT trùng dòng cũ (A6) nhưng hàng khác → giữ STT, mã dòng mới; sale chưa ghép → chặn
  jsonb_build_object('line_key','A6','apt_stt',6,'ma_dong','MD6105-1','ma_kb_apt','MD6105-1','md','MD6105','sale_name','Người Lạ','ten_apt','Đèn V61','sl_apt',5,
    'gia_nhap',900,'gia_ap_dung',900,'tt_apt',4500,'luong','A','status','blocked','level',1,'issues',jsonb_build_array('Tên sale "Người Lạ" trên hệ thống chưa ghép với nhân sự ERP'),'phan_hoi','CHỜ SALE — chưa xuất'),
  -- 5) dòng chỉ có trên hệ thống (không STT) → không nạp bù
  jsonb_build_object('line_key','SMD6106-1','ma_dong','MD6106-1','md','MD6106','ten_ht','Hàng không lên xe','luong','E','status','blocked')
)) r;
reset role;
select pg_temp.check((select (r->>'them')::int = 3 and jsonb_array_length(r->'bo_qua') = 2 and (r->>'bo_dong_e')::int = 1 from r61), 'thêm 3, bỏ qua 2 (trùng + không lên xe), dọn 1 dòng E');
select pg_temp.check((select r->'bo_qua'->0->>'ly_do' like 'Trùng mã khai báo MD6101-1%STT 5' from r61), 'lý do bỏ qua dòng trùng');
-- dòng cũ y nguyên (kể cả trả lời của sale)
select pg_temp.check((select count(*) = 3 from goc61 g join public.acc_lines l on l.id = g.id where to_jsonb(l) = to_jsonb(g)), 'dòng cũ không đổi 1 byte');
-- dòng mới
select pg_temp.check((select status = 'ok' and sale_id = (select id from public.profiles where email='a@nt.vn') and notes[array_upper(notes, 1)] like 'Nạp bù vào xe từ file bu_xe_v61.xlsx%'
  from public.acc_lines where truck_id = '00000000-0000-0000-0061-000000000001' and line_key = 'A7'), 'dòng mới: sale ghép theo tên, ghi chú nạp bù');
select pg_temp.check((select apt_stt = 100004 and line_key = 'A100004' from public.acc_lines where truck_id = '00000000-0000-0000-0061-000000000001' and ten_apt = 'Ổ cắm V61'), 'STT tự sinh trùng → đánh số tiếp');
select pg_temp.check((select apt_stt = 6 and line_key = 'A6-bu2' and status = 'blocked' and due_at is not null from public.acc_lines where truck_id = '00000000-0000-0000-0061-000000000001' and ten_apt = 'Đèn V61'), 'trùng mã dòng → mã mới, giữ STT');
select pg_temp.check(not exists(select 1 from public.acc_lines where truck_id = '00000000-0000-0000-0061-000000000001' and line_key = 'SMD6103-1'), 'dòng không lên xe đã có trên nháp bù → bỏ');
select pg_temp.check(not exists(select 1 from public.acc_lines where truck_id = '00000000-0000-0000-0061-000000000001' and ten_ht = 'Hàng không lên xe'), 'dòng chỉ có trên hệ thống không được nạp bù');
select pg_temp.check((select (stats->>'apt')::int = 6 and (stats->>'bu')::int = 3 and (stats->>'tt_apt')::numeric = 205000 + 60000 + 21000 + 4500 and files->'bu'->0->>'file' = 'bu_xe_v61.xlsx' from public.acc_trucks where id = '00000000-0000-0000-0061-000000000001'), 'thống kê xe cập nhật');
select pg_temp.check(exists(select 1 from public.notifications where title like '%dòng nạp bù bị chặn chưa ghép được sale%'), 'báo kế toán dòng bù chưa có sale');
-- nạp bù lại cùng file → không thêm gì
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select (public.acc_truck_append('00000000-0000-0000-0061-000000000001', '{"file":"bu_xe_v61.xlsx"}', jsonb_build_array(
  jsonb_build_object('line_key','A7','apt_stt',7,'ma_kb_apt','MD6103-1','ten_apt','Quạt V61','sl_apt',20,'luong','A','status','ok')))->>'them')::int = 0), 'nạp bù lại → không trùng');

-- HĐ chính thức về sau ghép được vào dòng nạp bù
select public.out_items_import(('[{"ma_hang":"X1-1","src":"xml","stt_hd":1,"ten":"Quạt V61","dvt":"Cái","vat":0.08,"sl_nhap":20,"dg_nhap":3000,"so_hd_vao":"6101","ky_hieu":"C26TBB","ngay_vao":"2026-11-26","acc_line_id":"'
  || (select id from public.acc_lines where truck_id = '00000000-0000-0000-0061-000000000001' and line_key = 'A7') || '"}]')::jsonb);
reset role;
select pg_temp.check((select ma_hang = 'MD6103-1-6101' and gia_khach = 3090 and not lech and sale_id = (select id from public.profiles where email='a@nt.vn') from public.out_items where so_hd_vao = '6101'), 'HĐ ký ghép dòng bù: mã hàng, giá khách, sale');
select 'v61 OK';
