-- Bản 26: Nhân sự & phân quyền chỉ Admin/BGĐ; nhân viên không tạo được ủy quyền duyệt
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

-- 1) Bảng công: đơn vắng theo giờ không làm hỏng bảng công tháng
set session_replication_role = replica; -- bỏ qua trigger kiểm đơn để dựng đúng dữ liệu đơn theo giờ
insert into public.leave_requests(profile_id, leave_type, start_date, end_date, part, from_time, to_time, status, days)
  select id, 'phep_nam', '2026-11-04', '2026-11-04', 'hours', '09:00', '10:30', 'da_duyet', 0 from public.profiles where email = 'b@nt.vn';
set session_replication_role = origin;
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select pg_temp.check((select count(*) from public.timesheet('2026-11-01')) > 0, 'bảng công tháng có đơn vắng theo giờ');
select pg_temp.check((select days->'04'->>'c' from public.timesheet('2026-11-01') where employee_code = (select employee_code from public.profiles where email='b@nt.vn')) like 'G%', 'ngày 04 có mã G');
reset role;

-- 2) Sale sửa giá khách: biên mới trong khung → chốt luôn; ngoài khung → báo lỗi
insert into public.acc_trucks(id, name) values ('00000000-0000-0000-0027-000000000001', 'Xe test bản 27');
insert into public.acc_lines(id, truck_id, line_key, luong, status, level, sale_id, md, apt_stt, gia_nhap, gia_ap_dung, gia_khach, bien_nt, sl_apt, issues)
  select '00000000-0000-0000-0027-0000000000a1', '00000000-0000-0000-0027-000000000001', 'A1', 'A', 'blocked', 1, id, 'MD2701', 1, 1000, 1000, 1100, 0.1, 10, '{"Biên NT 10%"}'
  from public.profiles where email = 'a@nt.vn';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.acc_line_reply('00000000-0000-0000-0027-0000000000a1', 'sua_gia_khach', null, null, null, 1200)$$, 'ngoài khung');
select public.acc_line_reply('00000000-0000-0000-0027-0000000000a1', 'sua_gia_khach', null, 'giá đúng theo hệ thống', null, 1040);
reset role;
select pg_temp.check((select status = 'ok' and gia_khach = 1040 and round(bien_nt, 4) = 0.04 and issues = '{}' and tt_khach = 10400 from public.acc_lines where id = '00000000-0000-0000-0027-0000000000a1'), 'sửa giá khách → chốt luôn');
select 'V27 TESTS PASSED' as result;
