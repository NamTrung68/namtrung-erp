-- Kiểm thử bản 40: chuyển phát HĐ đã ký (tạo phiếu gom theo khách, gửi, nhận, quá hạn, thu về, quyền, vết hồ sơ)
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- SĐT
select pg_temp.check(app.sdt_norm('+84 912.345.678') = '0912345678', 'chuẩn hóa +84');
select pg_temp.check(app.sdt_norm('0243 856 1234') = '02438561234', 'máy bàn 11 số');
select pg_temp.check(app.sdt_norm('12345') is null, 'SĐT sai dạng');

-- Dữ liệu: 3 HĐ đã ký của sale A (2 HĐ cùng MST 0101248141 với HĐ bản 38, 1 HĐ MST khác), 1 HĐ của sale B
insert into public.out_invoices(id, code, sale_id, buyer_name, tax_code, address, status, so_hd, ngay_hd, status_at)
select x.id::uuid, x.code, p.id, x.bn, x.mst, 'Số 1 Phố Huế, Hai Bà Trưng, Hà Nội', 'da_ky', x.so, app.vn_today() - 12, now()
  from (values ('00000000-0000-0000-0040-0000000000c1', 'XHD40001', 'Cty V38', '0101248141', '401', 'a@nt.vn'),
               ('00000000-0000-0000-0040-0000000000c2', 'XHD40002', 'Cty Khác', '0109999995', '402', 'a@nt.vn'),
               ('00000000-0000-0000-0040-0000000000c3', 'XHD40003', 'Cty B', '0108888880', '403', 'b@nt.vn')) x(id, code, bn, mst, so, em)
  join public.profiles p on p.email = x.em;
insert into public.out_buyers(id, name, tax_code, address) values ('00000000-0000-0000-0040-0000000000d1', 'Cty V38', '0101248141', 'Số 1 Phố Huế, Hai Bà Trưng, Hà Nội');
update public.out_invoices set buyer_id = '00000000-0000-0000-0040-0000000000d1' where id in ('00000000-0000-0000-0038-0000000000b1', '00000000-0000-0000-0040-0000000000c1');

select pg_temp.as_user('a@nt.vn'); set role authenticated;
-- chuẩn bị: 3 HĐ của A, gom 2 khách
select pg_temp.check(jsonb_array_length(public.out_ship_prep(array['00000000-0000-0000-0038-0000000000b1', '00000000-0000-0000-0040-0000000000c1', '00000000-0000-0000-0040-0000000000c2', '00000000-0000-0000-0040-0000000000c3']::uuid[])->'rows') = 3, 'prep chỉ trả HĐ của mình');
select pg_temp.check((select count(distinct r->>'kh_key') from jsonb_array_elements(public.out_ship_prep(array['00000000-0000-0000-0038-0000000000b1', '00000000-0000-0000-0040-0000000000c1', '00000000-0000-0000-0040-0000000000c2']::uuid[])->'rows') r) = 2, 'gom 2 khách');
select pg_temp.check((select count(*) from jsonb_array_elements(public.out_ship_candidates('{}')) r where r->>'id' like '00000000-0000-0000-00%') >= 3, 'danh sách HĐ chờ gửi');
-- lỗi
select pg_temp.err($$select public.out_ship_create('{"groups":[{"ids":["00000000-0000-0000-0038-0000000000b1","00000000-0000-0000-0040-0000000000c2"],"nguoi_nhan":"Anh A","sdt":"0912345678","dia_chi":"Số 1 Phố Huế, Hà Nội"}]}')$$, 'chỉ gửi cho 1 khách');
select pg_temp.err($$select public.out_ship_create('{"groups":[{"ids":["00000000-0000-0000-0038-0000000000b1"],"nguoi_nhan":"Anh A","sdt":"123","dia_chi":"Số 1 Phố Huế, Hà Nội"}]}')$$, 'sai dạng');
select pg_temp.err($$select public.out_ship_create('{"groups":[{"ids":["00000000-0000-0000-0038-0000000000b1"],"nguoi_nhan":"","sdt":"0912345678","dia_chi":"Số 1 Phố Huế, Hà Nội"}]}')$$, 'Nhập người nhận');
select pg_temp.err($$select public.out_ship_create('{"groups":[{"ids":["00000000-0000-0000-0038-0000000000b1"],"nguoi_nhan":"A","sdt":"0912345678","dia_chi":"HN"}]}')$$, 'quá ngắn');
select pg_temp.err($$select public.out_ship_create('{"groups":[{"ids":["00000000-0000-0000-0040-0000000000c3"],"nguoi_nhan":"A","sdt":"0912345678","dia_chi":"Số 1 Phố Huế, Hà Nội"}]}')$$, 'Không có quyền');
-- tạo 2 phiếu 1 lượt: khách V38 (2 HĐ, lưu người nhận vào pháp nhân) + khách khác (gửi luôn)
select pg_temp.check(jsonb_array_length(public.out_ship_create(jsonb_build_object('groups', jsonb_build_array(
  jsonb_build_object('ids', jsonb_build_array('00000000-0000-0000-0038-0000000000b1', '00000000-0000-0000-0040-0000000000c1'), 'buyer_id', '00000000-0000-0000-0040-0000000000d1',
                     'nguoi_nhan', 'Chị Lan  kế toán', 'sdt', '+84 912 345 678', 'dia_chi', 'Số 5 Láng Hạ, Đống Đa, Hà Nội', 'luu', true, 'note', 'V40-A'),
  jsonb_build_object('ids', jsonb_build_array('00000000-0000-0000-0040-0000000000c2'), 'nguoi_nhan', 'Anh Nam', 'sdt', '0987654321', 'dia_chi', 'Số 9 Trần Duy Hưng, Cầu Giấy, Hà Nội',
                     'gui', true, 'ngay_gui', app.vn_today() - 1, 'ma_van_don', 'vtp 001', 'note', 'V40-B'))))) = 2, 'tạo 2 phiếu');
reset role;
select pg_temp.check((select status = 'cho_gui' and sdt = '0912345678' and nguoi_nhan = 'Chị Lan kế toán' from public.out_ships where note = 'V40-A'), 'phiếu 1 chờ gửi, chuẩn hóa SĐT + tên');
select pg_temp.check((select status = 'da_gui' and ma_van_don = 'VTP001' and ngay_gui = app.vn_today() - 1 from public.out_ships where note = 'V40-B'), 'phiếu 2 gửi luôn');
select pg_temp.check((select nguoi_nhan = 'Chị Lan kế toán' and sdt_nhan = '0912345678' and dia_chi_giao = 'Số 5 Láng Hạ, Đống Đa, Hà Nội' from public.out_buyers where id = '00000000-0000-0000-0040-0000000000d1'), 'lưu người nhận vào pháp nhân');
select pg_temp.check((select gui_at is not null from public.out_doc_state where invoice_id = '00000000-0000-0000-0040-0000000000c2'), 'phiếu đã gửi → HĐ đánh dấu đã gửi khách');
select pg_temp.check((select count(*) = 1 from public.out_events where invoice_id = '00000000-0000-0000-0040-0000000000c2' and action = 'chuyen_phat' and note like '%Đã gửi%'), 'ghi lịch sử HĐ');
-- prep lần 2: lấy người nhận từ pháp nhân
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select r->>'sdt' = '0912345678' and r->>'ship_code' is not null from jsonb_array_elements(public.out_ship_prep(array['00000000-0000-0000-0040-0000000000c1']::uuid[])->'rows') r), 'gợi ý từ pháp nhân + báo đã có phiếu');
select pg_temp.err($$select public.out_ship_create('{"groups":[{"ids":["00000000-0000-0000-0038-0000000000b1"],"nguoi_nhan":"A","sdt":"0912345678","dia_chi":"Số 1 Phố Huế, Hà Nội"}]}')$$, 'đã nằm trong phiếu');
select pg_temp.check(not exists(select 1 from jsonb_array_elements(public.out_ship_candidates('{"all":true}')) r where r->>'id' = '00000000-0000-0000-0040-0000000000c1'), 'HĐ đã có phiếu không còn trong danh sách chờ gửi');

-- gửi / nhận phiếu 1
do $$ declare v uuid := (select id from public.out_ships where note = 'V40-A'); begin
  perform pg_temp.err(format($f$select public.out_ship_act(%L, 'nhan', '{}')$f$, v), 'chưa ở trạng thái Đã gửi');
  perform pg_temp.err(format($f$select public.out_ship_act(%L, 'gui', jsonb_build_object('ngay', app.vn_today() + 1))$f$, v), 'không hợp lệ');
  perform pg_temp.err(format($f$select public.out_ship_act(%L, 'gui', '{"ma_van_don":"VTP001"}')$f$, v), 'đã dùng ở phiếu khác');
  perform public.out_ship_act(v, 'gui', jsonb_build_object('ngay', app.vn_today() - 10, 'ma_van_don', 'VTP002'));
  perform pg_temp.err(format($f$select public.out_ship_act(%L, 'nhan', jsonb_build_object('ngay', app.vn_today() - 11))$f$, v), 'không hợp lệ');
  perform public.out_ship_act(v, 'nhan', jsonb_build_object('ngay', app.vn_today() - 8));
end $$;
reset role;
select pg_temp.check((select status = 'da_nhan' and han_thu = app.vn_today() - 1 from public.out_ships where note = 'V40-A'), 'nhận → hạn thu = ngày nhận + 7');
select pg_temp.check(exists(select 1 from public.notifications n join public.profiles p on p.id = n.recipient_id where p.email = 'a@nt.vn' and n.kind = 'chuyen_phat' and n.title like '%đã nhận HĐ%'), 'báo sale khách đã nhận');

-- sale B không thấy, không sửa được
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((public.out_ships_page('{}')->>'total')::int = 0, 'sale B không thấy phiếu của A');
select pg_temp.check((select count(*) from public.out_ships) = 0, 'RLS chặn đọc');
select pg_temp.err(format($f$select public.out_ship_act(%L, 'sua', '{"note":"x"}')$f$, (select id from public.out_ships where note = 'V40-A' limit 1)), 'Không thấy phiếu');
select pg_temp.err($$insert into public.out_ships(nguoi_nhan, sdt, dia_chi) values ('x', '0912345678', 'Số 1 Phố Huế, Hà Nội')$$, 'permission denied');
reset role;

-- kế toán thấy cả, lọc quá hạn
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((public.out_ships_page('{}')->'counts'->>'qua_han')::int >= 1, 'đếm quá hạn');
select pg_temp.check((select bool_and((r->>'qua_han')::boolean) and min((r->>'tre')::int) = 1 from jsonb_array_elements(public.out_ships_page('{"st":"qua_han"}')->'rows') r), 'lọc quá hạn, trễ 1 ngày');
select pg_temp.check((public.out_ships_page('{"q":"VTP002"}')->>'total')::int = 1, 'tìm theo mã vận đơn');
select pg_temp.check((public.out_ships_page('{"q":"401"}')->>'total')::int = 1, 'tìm theo số HĐ');
select pg_temp.check((public.out_ships_page(jsonb_build_object('field', 'nhan', 'tu', app.vn_today() - 8, 'den', app.vn_today() - 8))->>'total')::int = 1, 'lọc theo ngày nhận');
select pg_temp.check((public.out_ships_page(jsonb_build_object('st', 'da_gui'))->>'total')::int = 1, 'lọc đã gửi');
select public.set_setting('chuyen_phat', app.cp_cfg() || '{"sdt_gui":"0904000000"}');
select pg_temp.err($$select public.set_setting('chuyen_phat', '{"so_ngay_thu":0,"nhac_lai":3}')$$, 'Hạn thu hồi');
reset role;

-- cảnh báo quá hạn: sale + quản lý trực tiếp; không nhắc lại ngay hôm sau
select pg_temp.check(app.job_ship_remind() = 1, 'cảnh báo 1 phiếu');
select pg_temp.check(app.job_ship_remind() = 0, 'không cảnh báo lặp trong ngày');
select pg_temp.check(exists(select 1 from public.notifications n join public.profiles p on p.id = n.recipient_id where p.email = 'lead@nt.vn' and n.title like '⏰ Quá hạn%'), 'báo quản lý trực tiếp');
select pg_temp.check((select canh_bao_n = 1 from public.out_ships where note = 'V40-A'), 'đếm lần cảnh báo');
update public.out_ships set canh_bao_at = now() - interval '3 days' where note = 'V40-A';
select pg_temp.check(app.job_ship_remind() = 1, 'nhắc lại sau 3 ngày');

-- thu về từng HĐ
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_ship_thu((select id from public.out_ships where note = 'V40-A'), array['00000000-0000-0000-0038-0000000000b1']::uuid[], null, 'https://drive.google.com/x');
reset role;
select pg_temp.check((select status = 'da_nhan' from public.out_ships where note = 'V40-A'), 'thu 1/2 → còn chờ');
select pg_temp.check((select ky_at is not null and ky_url = 'https://drive.google.com/x' from public.out_doc_state where invoice_id = '00000000-0000-0000-0038-0000000000b1'), 'HĐ thu về → hồ sơ có bản ký');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_ship_thu((select id from public.out_ships where note = 'V40-A'));
reset role;
select pg_temp.check((select status = 'da_thu' and ngay_thu = app.vn_today() from public.out_ships where note = 'V40-A'), 'đủ HĐ → đã thu về');
select pg_temp.check(app.job_ship_remind() = 0, 'đã thu về thì hết cảnh báo');
-- bỏ xác nhận (bấm nhầm) — chỉ bỏ "đã có bản ký" ở HĐ chưa lưu file
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_ship_thu((select id from public.out_ships where note = 'V40-A'), null, null, null, true);
reset role;
select pg_temp.check((select status = 'da_nhan' and ngay_thu is null from public.out_ships where note = 'V40-A'), 'bỏ thu về → quay lại đã nhận');
select pg_temp.check((select ky_at is null from public.out_doc_state where invoice_id = '00000000-0000-0000-0040-0000000000c1'), 'bỏ đánh dấu bản ký (không có file)');
select pg_temp.check((select ky_at is not null from public.out_doc_state where invoice_id = '00000000-0000-0000-0038-0000000000b1'), 'giữ bản ký đã lưu file');

-- hoàn / hủy / lùi
select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ declare v uuid := (select id from public.out_ships where note = 'V40-B'); begin
  perform pg_temp.err(format($f$select public.out_ship_act(%L, 'hoan', '{}')$f$, v), 'lý do');
  perform public.out_ship_act(v, 'hoan', '{"note":"Sai địa chỉ"}');
end $$;
-- HĐ của phiếu hoàn được gửi lại ở phiếu mới
select pg_temp.check(jsonb_array_length(public.out_ship_create('{"groups":[{"ids":["00000000-0000-0000-0040-0000000000c2"],"nguoi_nhan":"Anh Nam","sdt":"0987654321","dia_chi":"Số 10 Trần Duy Hưng, Cầu Giấy, Hà Nội","note":"V40-C"}]}')) = 1, 'gửi lại sau khi hoàn');
select pg_temp.err(format($f$select public.out_ship_act(%L, 'lui', '{}')$f$, (select id from public.out_ships where note like 'V40-B%' limit 1)), 'đã được gửi ở phiếu khác');
do $$ declare v uuid := (select id from public.out_ships where note = 'V40-C'); begin
  perform public.out_ship_act(v, 'sua', '{"sdt":"0911111111","ma_van_don":"vtp 003"}');
  perform public.out_ship_act(v, 'huy', '{"note":"gửi chung đợt sau"}');
  perform pg_temp.err(format($f$select public.out_ship_act(%L, 'gui', '{}')$f$, v), 'Chờ gửi');
  perform public.out_ship_act(v, 'lui', '{}');
end $$;
reset role;
select pg_temp.check((select status = 'cho_gui' and sdt = '0911111111' and ma_van_don = 'VTP003' from public.out_ships where note like 'V40-C%'), 'sửa + hủy + mở lại');
select pg_temp.check((select count(*) >= 4 from public.out_ship_events e join public.out_ships s on s.id = e.ship_id where s.note like 'V40-C%'), 'nhật ký phiếu');
select 'V40 TESTS PASSED' as result;
