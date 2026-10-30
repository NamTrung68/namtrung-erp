-- Kiểm thử bản 10: Kế toán – Hóa đơn (đối soát xe APT, sale trả lời, duyệt mở chặn, HĐ đầu vào) + sao lưu Drive
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

update public.profiles set sale_aliases = '{}' where email = 'b@nt.vn';
-- Kế toán ghép tên sale trong file với Sale B
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_set_sale_alias((select id from public.profiles where email = 'b@nt.vn'), array['Đỗ Văn Trung', 'trungdv22']);
create temp table t_truck as select public.acc_truck_save(null, '{"name":"Xe test 25/10","truck_date":"2026-10-25","stats":{"apt":3}}', '[
 {"line_key":"A1","md":"MD2411","ma_dong":"MD2411-1","sale_name":"Đỗ Văn Trung","sale_acc":"trungdv22","luong":"A","status":"ok","level":3,"hh":"HH1","gia_khach":103000,"gia_nhap":100000,"sl_apt":10,"phan_hoi":"CHỐT","issues":[],"notes":[]},
 {"line_key":"A2","sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"hh":"HH2","gia_nhap":50000,"sl_apt":5,"issues":["Không có đơn"],"notes":[]},
 {"line_key":"A3","md":"MD2500","sale_name":"Khơi Lê","luong":"A","status":"blocked","level":1,"hh":"HH3","gia_khach":10,"gia_nhap":9,"issues":["Biên thấp"],"notes":[]}
]') id;
reset role;
select pg_temp.check((select count(*) from public.acc_lines) = 3, '3 dòng');
select pg_temp.check((select sale_id from public.acc_lines where line_key = 'A2') = (select id from public.profiles where email = 'b@nt.vn'), 'ghép sale theo tài khoản');
select pg_temp.check((select due_at is not null from public.acc_lines where line_key = 'A2'), 'có hạn 24h');
select pg_temp.check((select count(*) from public.notifications where kind = 'acc' and recipient_id = (select id from public.profiles where email = 'b@nt.vn')) >= 1, 'báo sale');

-- Sale B chỉ thấy dòng của mình; không thấy giá của sale khác
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.acc_lines) = 2, 'sale B thấy 2 dòng của mình');
select pg_temp.check((select count(*) from public.acc_invoices) = 0, 'sale không xem HĐ đầu vào');
do $$ begin perform public.acc_line_reply((select id from public.acc_lines where line_key = 'A3'), 'da_sua_ht'); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
do $$ begin update public.acc_lines set status = 'ok' where line_key = 'A2'; if found then raise exception 'sale không được sửa trực tiếp'; end if; end $$;
select public.acc_line_reply((select id from public.acc_lines where line_key = 'A2'), 'xin_duyet', null, 'Hàng mẫu khách lấy, đã báo GĐ');
reset role;
select pg_temp.check((select status from public.acc_lines where line_key = 'A2') = 'pending_approval', 'chờ duyệt');

-- Kế toán không tự thêm mình vào người duyệt
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.set_setting('accounting', (select value from public.settings where key = 'accounting') || jsonb_build_object('approver_ids', jsonb_build_array((select id::text from public.profiles where email = 'kt@nt.vn'))));
reset role;
select pg_temp.check((select value->'approver_ids' from public.settings where key = 'accounting') = '[]'::jsonb, 'kế toán không tự cấp quyền duyệt');
-- Admin cấp quyền duyệt cho Trưởng phòng
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.set_setting('accounting', (select value from public.settings where key = 'accounting') || jsonb_build_object('approver_ids', jsonb_build_array((select id::text from public.profiles where email = 'tp@nt.vn'))));
reset role;
select pg_temp.as_user('tp@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.acc_lines where status = 'pending_approval') = 1, 'người duyệt thấy dòng chờ duyệt');
select public.acc_line_approve((select id from public.acc_lines where line_key = 'A2'), true, 'Đồng ý');
reset role;
select pg_temp.check((select status from public.acc_lines where line_key = 'A2') = 'approved', 'đã duyệt');

-- Nạp lại xe: dòng đã duyệt giữ trạng thái
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_truck_save((select id from t_truck), '{"name":"Xe test 25/10"}', '[
 {"line_key":"A1","md":"MD2411","sale_name":"Đỗ Văn Trung","luong":"A","status":"ok","level":3,"hh":"HH1","gia_khach":103000,"gia_nhap":100000,"sl_apt":10,"sl_tk":10},
 {"line_key":"A2","sale_name":"trungdv22","luong":"A","status":"blocked","level":1,"hh":"HH2","gia_nhap":50000,"sl_apt":5}
]');
select pg_temp.check((select status from public.acc_lines where line_key = 'A2') = 'approved', 'nạp lại giữ dòng đã duyệt');
select pg_temp.check((select count(*) from public.acc_lines) = 2, 'dòng không còn trong file mới bị xóa');
-- HĐ đầu vào
select public.acc_invoice_save('{"ky_hieu":"C26TYT","so_hd":"00002080","ngay":"2026-10-30","mst_ban":"0110746961","tong_truoc_thue":1250000}',
  jsonb_build_array(jsonb_build_object('stt',1,'hh','HH1','ten','Hàng 1','sl',10,'dg',100000,'tt',1000000,'vat','8%','line_id',(select id from public.acc_lines where line_key='A1'),'result','khop'),
                    jsonb_build_object('stt',2,'hh','HH2','ten','Hàng 2','sl',5,'dg',50000,'tt',250000,'vat','8%','line_id',(select id from public.acc_lines where line_key='A2'),'result','khong_don')));
reset role;
select pg_temp.check((select inv_no from public.acc_lines where line_key = 'A1') = '00002080', 'ghi số HĐ vào dòng');
select pg_temp.check((select count(*) from public.acc_invoice_lines) = 2, 'lưu dòng HĐ');

-- Sao lưu Drive bằng mã bí mật
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.backup_set_token('test-token-0123456789-abcdefghijklmnop');
reset role;
set role anon;
select pg_temp.check(public.backup_tables('test-token-0123456789-abcdefghijklmnop') ? 'acc_lines', 'danh sách bảng sao lưu');
select pg_temp.check(jsonb_array_length(public.backup_page('test-token-0123456789-abcdefghijklmnop', 'acc_lines', 0, 1)) = 1, 'trang sao lưu');
do $$ begin perform public.backup_tables('sai'); raise exception 'phải chặn'; exception when others then if sqlerrm like '%phải chặn%' then raise; end if; end $$;
reset role;
create temp table t_bk as select jsonb_agg(to_jsonb(t) || '{"name":"Đã khôi phục"}') j from public.acc_trucks t;
grant select on t_bk to authenticated;
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select pg_temp.check(public.backup_restore_json('acc_trucks', (select j from t_bk)) = 1, 'khôi phục từ file Drive');
reset role;
select pg_temp.check((select name from public.acc_trucks limit 1) = 'Đã khôi phục', 'dữ liệu khôi phục');
-- Ghép tên sale sau khi đã nạp: dòng tự gắn sale, hết lỗi thì tự chốt
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.acc_truck_save(null, '{"name":"Xe 2"}', '[{"line_key":"A9","md":"MD9","apt_stt":9,"sale_name":"Nguyễn Văn Mới","luong":"A","status":"blocked","level":1,"gia_khach":103,"gia_nhap":100,"gia_de_xuat":100,"issues":["Tên sale \"Nguyễn Văn Mới\" trên hệ thống chưa ghép với nhân sự ERP → vào Cấu hình kế toán ghép tên."],"notes":[]}]');
select public.acc_set_sale_alias((select id from public.profiles where email = 'a@nt.vn'), array['Nguyễn Văn Mới']);
reset role;
select pg_temp.check((select status = 'ok' and sale_id is not null and phan_hoi like 'XUẤT GIÁ%' from public.acc_lines where line_key = 'A9'), 'ghép tên xong tự chốt');
select 'V10 TESTS PASSED' as result;
