-- Bản 28: CSKH hỗ trợ sale (xem + thao tác, không duyệt), sửa giá dòng đã tự chốt, username SĐT, thông báo, phép theo tháng, lương tạm tính, giờ vào khi duyệt quên chấm
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = p_email), false); end $$;
create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not ilike '%' || p_like || '%' then raise exception 'Sai lỗi: % (mong đợi %)', sqlerrm, p_like; end if;
    return;
  end;
  raise exception 'Mong đợi lỗi "%" nhưng câu lệnh chạy thành công: %', p_like, p_sql;
end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- Dựng 2 CSKH
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.invite_user('cskh1@nt.vn', 'CSKH Lan', '{cskh}', 'nhan_vien', null, null);
select public.invite_user('cskh2@nt.vn', 'CSKH Mai', '{cskh}', 'nhan_vien', null, null);
reset role;
insert into auth.users(email) values ('cskh1@nt.vn'), ('cskh2@nt.vn');

-- 1) Phân công: chỉ Admin/BGĐ; sale A: chính Lan, dự phòng Mai
select pg_temp.as_user('lead@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.support_assign_save((select id from public.profiles where email='cskh1@nt.vn'), array[(select id from public.profiles where email='a@nt.vn')], null)$$, 'Chỉ Admin');
reset role;
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.support_assign_save((select id from public.profiles where email='cskh1@nt.vn'), array[(select id from public.profiles where email='a@nt.vn')], null);
select public.support_assign_save((select id from public.profiles where email='cskh2@nt.vn'), null, array[(select id from public.profiles where email='a@nt.vn')]);
select pg_temp.expect_error($$select public.support_assign_save((select id from public.profiles where email='cskh2@nt.vn'), array[(select id from public.profiles where email='a@nt.vn')], null)$$, 'đã có CSKH khác');
reset role;

-- 2) CSKH thấy khách / báo giá của sale A; không thấy của sale B; không thấy công, phép của A
select pg_temp.as_user('cskh1@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.customers) = (select count(*) from public.customers c where c.owner_id = (select id from public.profiles where email='a@nt.vn')) and (select count(*) from public.customers) > 0, 'CSKH thấy đúng khách của sale A');
select pg_temp.check((select count(*) from public.leave_requests) = 0, 'CSKH không thấy đơn nghỉ của sale');
select pg_temp.check(not exists(select 1 from public.timesheet('2026-11-01') where employee_code = (select employee_code from public.profiles where email='a@nt.vn')), 'CSKH không thấy bảng công của sale');
select pg_temp.check(exists(select 1 from public.out_sale_opts() where full_name = (select full_name from public.profiles where email='a@nt.vn')), 'CSKH có sale A trong danh sách lọc');
-- không duyệt đơn nghỉ của sale
reset role;
set session_replication_role = replica;
insert into public.leave_requests(id, profile_id, leave_type, start_date, end_date, reason, status, days)
  select '00000000-0000-0000-0028-0000000000b1', id, 'khong_luong', '2026-12-21', '2026-12-21', 'Việc nhà riêng', 'cho_duyet', 1 from public.profiles where email = 'a@nt.vn';
set session_replication_role = origin;
select pg_temp.as_user('cskh1@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.decide_request('leave', '00000000-0000-0000-0028-0000000000b1', true)$$, 'không có quyền');
-- lập báo giá cho khách của A → báo giá đứng tên sale A
select public.save_quote(null, (select id from public.customers where owner_id = (select id from public.profiles where email='a@nt.vn') limit 1),
  '{"tyGia":4015,"phiUTPct":1,"phiDVPct":2}', '[{"name":"Hàng CSKH lập","qty":10,"unit_price_cny":5}]', '{"tongSauVAT":100000}');
reset role;
select pg_temp.check((select sale_id = (select id from public.profiles where email='a@nt.vn') and created_by = (select id from public.profiles where email='cskh1@nt.vn')
  from public.quotations where id = (select quotation_id from public.quotation_lines where name = 'Hàng CSKH lập')), 'báo giá CSKH lập đứng tên sale A, ghi người lập');
-- không xóa khách
select pg_temp.as_user('cskh1@nt.vn'); set role authenticated;
select pg_temp.expect_error($$update public.customers set deleted_at = now() where owner_id = (select id from public.profiles where email='a@nt.vn')$$, 'không được xóa');
reset role;

-- 3) Sửa giá khách ở dòng đã tự chốt (biên 5% có giá đề xuất), CSKH làm thay sale
insert into public.acc_trucks(id, name) values ('00000000-0000-0000-0028-000000000001', 'Xe test bản 28');
insert into public.acc_lines(id, truck_id, line_key, luong, status, level, sale_id, md, apt_stt, gia_nhap, gia_ap_dung, gia_khach, bien_nt, gia_de_xuat, sl_apt, issues)
  select '00000000-0000-0000-0028-0000000000a1', '00000000-0000-0000-0028-000000000001', 'A1', 'A', 'ok', 3, id, 'MD2801', 1, 1000, 1000, 1050, 0.05, 1019, 10, '{}'
  from public.profiles where email = 'a@nt.vn';
select pg_temp.as_user('cskh1@nt.vn'); set role authenticated;
select public.acc_line_reply('00000000-0000-0000-0028-0000000000a1', 'sua_gia_khach', null, 'giá đúng', null, 1030);
reset role;
select pg_temp.check((select status = 'ok' and gia_khach = 1030 and gia_de_xuat is null and replied_by = (select id from public.profiles where email='cskh1@nt.vn') from public.acc_lines where id = '00000000-0000-0000-0028-0000000000a1'), 'CSKH sửa giá dòng đã chốt → hết đề xuất');
update public.acc_lines set inv_no = '2153' where id = '00000000-0000-0000-0028-0000000000a1';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.acc_line_reply('00000000-0000-0000-0028-0000000000a1', 'sua_gia_khach', null, null, null, 1040)$$, 'không ở trạng thái');
reset role;

-- 4) Thông báo việc của sale A sao cho CSKH chính; link cũ #/out → màn mới
select app.notify((select id from public.profiles where email='a@nt.vn'), 'acc', 'Có dòng chờ bạn', 'xe test', '#/out?inv=abc');
select pg_temp.check((select link from public.notifications where title = 'Có dòng chờ bạn' and copy_of is null) = '#/hd?inv=abc', 'link sale → #/hd');
select pg_temp.check((select recipient_id from public.notifications where copy_of is not null and title like '%Có dòng chờ bạn') = (select id from public.profiles where email='cskh1@nt.vn'), 'CSKH chính nhận bản sao');
select app.notify((select id from public.profiles where email='kt@nt.vn'), 'acc', 'KT test link', null, '#/out');
select pg_temp.check((select link from public.notifications where title = 'KT test link') = '#/hd/kt', 'link kế toán → #/hd/kt');
-- CSKH chính nghỉ cả ngày → dự phòng nhận
set session_replication_role = replica;
insert into public.leave_requests(profile_id, leave_type, start_date, end_date, reason, status, days, part)
  select id, 'khong_luong', app.vn_today(), app.vn_today(), 'Nghỉ hôm nay', 'da_duyet', 1, 'full' from public.profiles where email = 'cskh1@nt.vn';
select pg_temp.check(app.cskh_for((select id from public.profiles where email='a@nt.vn')) = (select id from public.profiles where email='cskh2@nt.vn'), 'chính nghỉ → dự phòng');
delete from public.leave_requests where reason = 'Nghỉ hôm nay';
set session_replication_role = origin;

-- 5) Username SĐT: mất số 0 / dấu ' → chuẩn; hồ sơ khách có username → dòng HĐ tự gắn khách
select pg_temp.check(app.norm_username('''906099063') = '0906099063' and app.norm_username('84906099063') = '0906099063' and app.norm_username(' 0906 099 063 ') = '0906099063'
  and app.norm_username('manhhuynh') = 'manhhuynh' and app.norm_username('123') = '123', 'chuẩn hóa username');
insert into public.out_items(ma_hang, part, ten, sl_nhap, dg_nhap, username) values ('HH09999-2153-2026', 1, 'Hàng SĐT', 5, 100, '912345678');
select pg_temp.check((select username from public.out_items where ma_hang = 'HH09999-2153-2026') = '0912345678', 'dòng HĐ lưu username có số 0');
update public.customers set sys_username = '''0912345678' where id = (select id from public.customers where owner_id = (select id from public.profiles where email='a@nt.vn') limit 1);
select pg_temp.check((select customer_id is not null from public.out_items where ma_hang = 'HH09999-2153-2026'), 'khách có username → dòng HĐ tự gắn khách');

-- 6) Quên chấm: duyệt phải nhập giờ vào → tính đi muộn
select pg_temp.as_user('b@nt.vn');
insert into public.attendance_requests(id, profile_id, kind, work_date, reason)
  select '00000000-0000-0000-0028-0000000000c1', id, 'xac_nhan_cong', app.vn_today(), 'Quên chấm công sáng' from public.profiles where email = 'b@nt.vn';
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select pg_temp.expect_error($$select public.decide_request('attendance', '00000000-0000-0000-0028-0000000000c1', true)$$, 'giờ vào');
select public.decide_request('attendance', '00000000-0000-0000-0028-0000000000c1', true, null, '08:25', null);
reset role;
select pg_temp.check((select confirm_in = '08:25' from public.attendance_requests where id = '00000000-0000-0000-0028-0000000000c1'), 'lưu giờ vào');
select pg_temp.check((select (app.day_info(p.id, 'office', null, app.vn_today())->>'late')::int >= 25 or app.day_value('office', app.vn_today()) = 0
  from public.profiles p where p.email = 'b@nt.vn'), 'đi muộn tính từ giờ vào xác nhận');

-- 7) Phép năm cộng dồn: vào làm 20/03 → tính từ tháng 4
reset role;
update public.profiles set hire_date = make_date(extract(year from app.vn_today())::int, 3, 20) where email = 'b@nt.vn';
delete from public.leave_entitlements where profile_id = (select id from public.profiles where email = 'b@nt.vn');
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((public.leave_balance()->>'months')::int = greatest(extract(month from app.vn_today())::int - 3, 0), 'tháng tích lũy tính từ tháng sau khi vào làm sau ngày 15');
-- 8) Lương tạm tính: chính mình thấy, người khác (cùng cấp) không
select pg_temp.check((select summary ? 'luong_tam_tinh' and summary->>'luong_tam_tinh' is not null from public.timesheet(date_trunc('month', app.vn_today())::date) where employee_code = (select employee_code from public.profiles where email='b@nt.vn')), 'thấy lương tạm tính của mình');
reset role;
select pg_temp.as_user('lead@nt.vn'); set role authenticated;
select pg_temp.check((select summary->>'luong_tam_tinh' is not null from public.timesheet(date_trunc('month', app.vn_today())::date) where employee_code = (select employee_code from public.profiles where email='a@nt.vn')), 'quản lý thấy lương tạm tính cấp dưới');
reset role;
select 'V28 TESTS PASSED' as result;
