-- Kiểm thử luồng nghiệp vụ + phân quyền (chạy bằng scripts/test-db.sh)
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = p_email), false);
end $$;
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

-- 1. Đăng ký không có lời mời bị chặn
select pg_temp.expect_error($$insert into auth.users(email) values ('la@x.com')$$, 'chưa được mời');
-- 2. Admin
insert into auth.users(email) values ('namtrung20266@gmail.com');
select pg_temp.check((select roles from public.profiles where email='namtrung20266@gmail.com') @> '{admin,bgd}', 'admin roles');

select pg_temp.as_user('namtrung20266@gmail.com');
set role authenticated;
select public.invite_user('lead@nt.vn', 'Trưởng nhóm L', '{tn_kd}', 'truong_nhom', null, null);
select public.invite_user('hr@nt.vn', 'HCNS H', '{hcns}', 'chuyen_vien', null, null);
select public.invite_user('kt@nt.vn', 'Kế toán K', '{ke_toan}', 'chuyen_vien', null, null);
select public.invite_user('tp@nt.vn', 'Trưởng phòng P', '{tp_kd}', 'truong_phong', null, null);
reset role;
insert into auth.users(email) values ('lead@nt.vn'), ('hr@nt.vn'), ('kt@nt.vn'), ('tp@nt.vn');
update public.profiles set manager_id = (select id from public.profiles where email='tp@nt.vn') where email = 'lead@nt.vn';
select pg_temp.as_user('namtrung20266@gmail.com');
set role authenticated;
select public.invite_user('a@nt.vn', 'Sale A', '{sale}', 'chuyen_vien', (select id from public.profiles where email='lead@nt.vn'), null);
select public.invite_user('b@nt.vn', 'Sale B', '{sale}', 'nhan_vien', null, null);
reset role;
insert into auth.users(email) values ('a@nt.vn'), ('b@nt.vn');
update public.profiles set sale_aliases = '{Khơi Lê}' where email = 'a@nt.vn';

-- 3. Khách hàng + chống trùng + phạm vi
select pg_temp.as_user('a@nt.vn');
set role authenticated;
insert into public.customers(contact_name, phone, customer_type, source) values ('Anh Huy', '+84 888 886 812', 'nha_buon', 'tu_tim_zalo');
select pg_temp.check((select phone_norm from public.customers where contact_name='Anh Huy') = '0888886812', 'chuẩn hóa SĐT');
select pg_temp.check((select code from public.customers where contact_name='Anh Huy') = 'KH000001', 'mã KH');
select pg_temp.expect_error($$update public.customers set order_count = 5 where contact_name='Anh Huy'$$, 'tự đếm');
select pg_temp.expect_error($$insert into public.customers(contact_name, phone, customer_type, source) values ('X', '123', 'nha_buon','khac')$$, 'phone_format');
select pg_temp.as_user('b@nt.vn');
select pg_temp.check((select count(*) from public.customers) = 0, 'B không thấy khách của A');
select pg_temp.expect_error($$insert into public.customers(contact_name, phone, customer_type, source) values ('Huy 2', '0888886812', 'nha_buon','khac')$$, 'sân chung');
select pg_temp.check((public.check_duplicate('0888886812')->>'status') = 'shared', 'check_duplicate shared');
select pg_temp.as_user('lead@nt.vn');
select pg_temp.check((select count(*) from public.customers) = 1, 'Trưởng nhóm thấy khách của A');
select pg_temp.as_user('tp@nt.vn');
select pg_temp.check((select count(*) from public.customers) = 1, 'Trưởng phòng thấy khách của cấp dưới gián tiếp');

-- 4. Chăm sóc
select pg_temp.as_user('a@nt.vn');
insert into public.care_logs(customer_id, channel, purpose, result, content)
select id, 'goi_dien', 'tiep_can_lan_dau', 'xin_bao_gia', 'Khách nhập ống phụt, xin báo giá chính ngạch' from public.customers;
select pg_temp.check((select stage from public.customers) = 'tiep_can' and (select care_count from public.customers) = 1, 'care cập nhật khách');
select pg_temp.expect_error($$insert into public.care_logs(customer_id, channel, purpose, result, content) select id, 'zalo', 'tiep_can_lan_dau', 'co_quan_tam', 'Gọi lại lần hai cho khách' from public.customers$$, 'chưa chăm lần nào');
select pg_temp.expect_error($$insert into public.care_logs(customer_id, channel, purpose, result, content) select id, 'zalo', 'khac', 'co_quan_tam', 'ngắn' from public.customers$$, 'check');

-- 5. Báo giá: phá khung → chờ duyệt → duyệt → gửi → sửa thành v2 → chốt
select pg_temp.expect_error($$select public.save_quote(null, (select id from public.customers), '{"tyGia":3900,"phiUTPct":1,"phiDVPct":2}', '[{"name":"Ống","qty":10,"unit_price_cny":5}]', '{}')$$, 'CẤM');
select pg_temp.expect_error($$select public.save_quote(null, (select id from public.customers), '{"tyGia":4015,"phiUTPct":0.5,"phiDVPct":2}', '[{"name":"Ống","qty":10,"unit_price_cny":5}]', '{}')$$, 'CẤM');
select public.save_quote(null, (select id from public.customers), '{"tyGia":4000,"phiUTPct":1,"phiDVPct":2,"soKhoi":2,"donGiaKhoi":1100000,"khoNhan":"HN"}',
  '[{"name":"Ống phụt","qty":1000,"unit_price_cny":2}]', '{"tongSauVAT":9000000,"lnUocTinh":500000}');
select pg_temp.check((select cardinality(violations) from public.quotations) = 1, 'vi phạm tỷ giá < 4015');
select public.quote_submit((select id from public.quotations));
select pg_temp.check((select status from public.quotations) = 'cho_duyet', 'chờ duyệt');
select pg_temp.expect_error($$select public.quote_decide((select id from public.quotations), true)$$, 'Không tự duyệt');
select pg_temp.as_user('lead@nt.vn');
select pg_temp.expect_error($$select public.quote_decide((select id from public.quotations), true)$$, 'Trưởng phòng');
select pg_temp.as_user('tp@nt.vn');
select public.quote_decide((select id from public.quotations), true, 'OK khách lớn');
select pg_temp.as_user('a@nt.vn');
select pg_temp.check((select status from public.quotations) = 'nhap' and (select approved_hash = price_hash from public.quotations), 'đã duyệt');
select public.quote_submit((select id from public.quotations));
select pg_temp.check((select status from public.quotations) = 'da_gui', 'đã gửi');
select pg_temp.check((select stage from public.customers) = 'da_bao_gia' and (select quote_count from public.customers) = 1, 'khách lên Đã gửi BG');
select public.save_quote((select id from public.quotations), (select id from public.customers), '{"tyGia":4015,"phiUTPct":1,"phiDVPct":2}',
  '[{"name":"Ống phụt","qty":1200,"unit_price_cny":2}]', '{"tongSauVAT":9500000}');
select pg_temp.check((select count(*) from public.quotations) = 2 and (select count(*) from public.quotations where status='da_thay_the') = 1, 'tạo v2');
select public.quote_submit((select id from public.quotations where version = 2));
select pg_temp.expect_error($$select public.quote_set_status((select id from public.quotations where version = 2), 'da_chot')$$, 'Mã đơn');
select public.quote_set_status((select id from public.quotations where version = 2), 'da_chot', 'md2217');
select pg_temp.check((select ownership from public.customers) = 'owned' and (select stage from public.customers) = 'don_dau' and (select first_order_code from public.customers) = 'MD2217', 'xác lập chủ khách');
select pg_temp.as_user('b@nt.vn');
select pg_temp.check((public.check_duplicate('0888886812')->>'status') = 'owned_by_other', 'đã có chủ');
select pg_temp.check((select count(*) from public.quotations) = 0, 'B không thấy báo giá của A');

-- 6. Nghỉ phép
select pg_temp.as_user('a@nt.vn');
select pg_temp.expect_error($$insert into public.leave_requests(leave_type, start_date, end_date) values ('phep_nam', current_date + 3, current_date + 3)$$, 'Phép năm còn');
select pg_temp.as_user('hr@nt.vn');
insert into public.leave_ledger(profile_id, kind, days, note) select id, 'opening', 5, 'Số dư đầu kỳ' from public.profiles where email = 'a@nt.vn';
select pg_temp.as_user('a@nt.vn');
insert into public.leave_requests(leave_type, start_date, end_date, reason) values ('phep_nam', date '2026-11-02', date '2026-11-03', 'Việc gia đình');
select pg_temp.check((select days from public.leave_requests) = 2, '2 ngày phép');
select pg_temp.expect_error($$select public.decide_request('leave', (select id from public.leave_requests), true)$$, 'không có quyền');
select pg_temp.as_user('b@nt.vn');
select pg_temp.check((select count(*) from public.leave_requests) = 0, 'B không thấy đơn của A');
select pg_temp.check((select count(*) from public.leave_board(date '2026-11-01', date '2026-11-30')) = 1, 'bảng ai nghỉ');
select pg_temp.as_user('lead@nt.vn');
select public.decide_request('leave', (select id from public.leave_requests), true, null);
select pg_temp.check((public.leave_balance((select id from public.profiles where email='a@nt.vn'))->>'balance')::numeric = 3, 'trừ phép còn 3');

-- 7. Chấm công
select pg_temp.as_user('a@nt.vn');
select pg_temp.expect_error($$select public.attendance_check('in', (select id::text from public.profiles where email='a@nt.vn') || '/x.jpg')$$, 'đồng ý');
select public.selfie_consent();
select pg_temp.expect_error($$select public.attendance_check('in', 'abc/x.jpg')$$, 'không hợp lệ');
select (public.attendance_check('in', (select id::text from public.profiles where email='a@nt.vn') || '/2026-10/1.jpg'))->>'status';

-- 8. Lương + hoa hồng: Chuyên viên, LN đơn 200tr → LN tính thưởng 120tr → HH 22.200.000
select pg_temp.as_user('kt@nt.vn');
select public.payroll_open(date '2026-10-01');
select public.import_order_results((select id from public.payroll_periods), '[{"ext_order_code":"MD2045","sale_name":"Khơi Lê","order_profit":200000000,"completed_at":"2026-10-27"},{"ext_order_code":"MD9","sale_name":"Ai Đó","order_profit":1000}]');
select pg_temp.check((public.import_order_results((select id from public.payroll_periods), '[{"ext_order_code":"MD9","sale_name":"Ai Đó","order_profit":1}]', false)->'unmapped') = '["Ai Đó"]', 'báo tên chưa khớp');
select public.payroll_compute((select id from public.payroll_periods));
select pg_temp.check((select commission from public.payslips s join public.profiles p on p.id = s.profile_id where p.email='a@nt.vn') = 22200000, 'hoa hồng lũy tiến 22.200.000');
select pg_temp.check((select team_bonus from public.payslips s join public.profiles p on p.id = s.profile_id where p.email='lead@nt.vn') = 3600000, 'thưởng đội 3% × 120tr');
select pg_temp.check((select team_bonus from public.payslips s join public.profiles p on p.id = s.profile_id where p.email='tp@nt.vn') = 3600000, 'thưởng phòng 3% × 120tr');
select pg_temp.as_user('b@nt.vn');
select pg_temp.check((select count(*) from public.payslips) = 1, 'B chỉ thấy phiếu lương của mình');
select pg_temp.check((select count(*) from public.profile_private) = 1, 'B chỉ thấy dữ liệu riêng của mình');
select pg_temp.expect_error($$update public.profile_private set base_salary = 99999999$$, 'sửa lương');
select pg_temp.as_user('lead@nt.vn');
select pg_temp.check((select count(*) from public.payslips) = 2, 'TN thấy phiếu của mình + A');
select pg_temp.as_user('kt@nt.vn');
select public.payroll_send_review((select id from public.payroll_periods));
select pg_temp.as_user('namtrung20266@gmail.com');
select public.payroll_close((select id from public.payroll_periods));
update public.payslips set net = 1;
select pg_temp.check((select count(*) from public.payslips where net = 1) = 0, 'không sửa trực tiếp phiếu lương');
reset role;
select pg_temp.expect_error($$update public.payslips set net = 1$$, 'đã chốt');
set role authenticated;
select pg_temp.check((select count(*) from public.kpi_snapshots) >= 3, 'snapshot KPI khi chốt lương');

-- 9. Telegram + secret
select pg_temp.expect_error($$select * from app.secrets$$, 'permission');
select public.set_secret('telegram_bot_token', '123456:ABCDEF-test');
select public.set_setting('telegram', '{"enabled":true,"chat_id":"-100123","events":["test","quote_won"]}');
select public.telegram_test();
reset role;
select pg_temp.check((select count(*) from net.calls where url like '%api.telegram.org/bot123456:ABCDEF-test/sendMessage') = 1, 'gọi Telegram');
set role authenticated;
select pg_temp.as_user('b@nt.vn');
select pg_temp.expect_error($$select public.set_secret('telegram_bot_token', 'x')$$, 'Admin');
select pg_temp.expect_error($$update public.profiles set roles = '{admin}' where email = 'b@nt.vn'$$, 'quyền');
select pg_temp.check((select count(*) from public.secret_status()) = 0, 'B không xem secret');

-- 10. KPI, dashboard, báo cáo, tài liệu
select pg_temp.as_user('a@nt.vn');
select pg_temp.check((select (metrics->>'tiep_can')::int from public.kpi_report(current_date - 1, current_date + 1) where full_name = 'Sale A') = 1, 'KPI đếm tiếp cận');
select pg_temp.check(public.dashboard() ? 'care_today', 'dashboard');
select pg_temp.check(jsonb_typeof(public.crm_report('retention', current_date - 30, current_date)) = 'object', 'báo cáo giữ khách');
select pg_temp.check((select count(*) from public.leaderboard(current_date - 30, current_date)) >= 1, 'bảng phong thần');
select pg_temp.as_user('b@nt.vn');
select pg_temp.check((select count(*) from public.doc_categories) = 0, 'Nhân viên không xem danh mục chứng từ');
select pg_temp.as_user('a@nt.vn');
select pg_temp.check((select count(*) from public.doc_categories) = 5, 'Chuyên viên xem được chứng từ');
reset role;
select app.job_daily_crm();
select 'TESTS PASSED' as result;
