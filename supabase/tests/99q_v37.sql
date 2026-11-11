-- Kiểm thử bản 37: ảnh dòng báo giá; đơn quên chấm vào / quên chấm về
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- A. Ảnh báo giá: lưu cột image, dấu giá bỏ qua ảnh, nhân bản giữ ảnh
select pg_temp.check(app.quote_hash('{"a":1}', '[{"name":"x","qty":1}]') = app.quote_hash('{"a":1}', '[{"name":"x","qty":1,"image":"u/1.jpg"}]'), 'dấu giá bỏ qua ảnh');
select pg_temp.check(app.quote_hash('{"a":1}', '[{"name":"x","qty":1}]') = md5('{"a":1}'::jsonb::text || '[{"name":"x","qty":1}]'::jsonb::text), 'dấu giá cũ không đổi khi không có ảnh');
select pg_temp.check(app.quote_hash('{}', '[]') = md5('{}[]') and app.quote_hash('{}', null) = md5('{}[]'), 'dấu giá rỗng');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ declare v uuid; v2 uuid; begin
  v := public.save_quote(null, '00000000-0000-0000-0036-0000000000c1', '{"tyGia":4000,"phiUTPct":1,"phiDVPct":2,"soKhoi":2,"donGiaKhoi":1100000,"khoNhan":"HN"}'::jsonb,
    '[{"name":"Áo có ảnh","qty":2,"unit_price_cny":10,"image":"x/anh1.jpg"},{"name":"Quần không ảnh","qty":1,"unit_price_cny":5,"image":""}]'::jsonb, '{}'::jsonb, null);
  perform pg_temp.check((select array_agg(image order by line_no)::text from public.quotation_lines where quotation_id = v) = '{x/anh1.jpg,NULL}', 'lưu ảnh dòng (rỗng → null)');
  v2 := public.quote_clone(v);
  perform pg_temp.check((select image from public.quotation_lines where quotation_id = v2 and line_no = 1) = 'x/anh1.jpg', 'nhân bản giữ ảnh');
end $$;
reset role;

-- B. Đơn quên chấm vào / về
select pg_temp.as_user('lead@nt.vn'); set role authenticated;
select pg_temp.err($$insert into public.attendance_requests(kind, work_date, reason) values ('quen_cham_vao', app.vn_today() - 2, 'Quên chấm sáng')$$, 'Nhập giờ bạn vào làm');
select pg_temp.err($$insert into public.attendance_requests(kind, work_date, reason, req_time) values ('quen_cham_vao', app.vn_today() + 1, 'Quên chấm sáng', '08:00')$$, 'chưa tới');
select pg_temp.err($$insert into public.attendance_requests(kind, work_date, reason, req_time) values ('quen_cham_vao', app.vn_today() - 40, 'Quên chấm sáng', '08:00')$$, 'trong vòng 30 ngày');
insert into public.attendance_requests(id, kind, work_date, reason, req_time) values ('00000000-0000-0000-0037-0000000000a1', 'quen_cham_vao', app.vn_today() - 2, 'Quên chấm khi đến', '08:10');
insert into public.attendance_requests(id, kind, work_date, reason, req_time) values ('00000000-0000-0000-0037-0000000000a2', 'quen_cham_ra', app.vn_today() - 2, 'Quên chấm khi về', '17:45');
select pg_temp.err($$insert into public.attendance_requests(kind, work_date, reason, req_time) values ('quen_cham_ra', app.vn_today() - 2, 'Gửi trùng đơn', '17:45')$$, 'Đã có đơn loại này');
reset role;
-- người duyệt sửa giờ vào 08:20 (camera); giờ về để mặc định theo giờ nhân viên khai
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.decide_request('attendance', '00000000-0000-0000-0037-0000000000a1', true, null, '08:20', null);
select public.decide_request('attendance', '00000000-0000-0000-0037-0000000000a2', true, null, null, null);
reset role;
select pg_temp.check((select confirm_in = '08:20' and confirm_out is null from public.attendance_requests where id = '00000000-0000-0000-0037-0000000000a1'), 'giờ vào = giờ người duyệt chốt');
select pg_temp.check((select confirm_out = '17:45' and confirm_in is null from public.attendance_requests where id = '00000000-0000-0000-0037-0000000000a2'), 'giờ về mặc định = giờ nhân viên khai');
-- chấm vào muộn thật lúc 10:00 → đơn quên chấm đến đã duyệt 08:20 thay giờ vào
insert into public.attendance_events(profile_id, kind, at, work_date, status)
  select id, 'in', ((app.vn_today() - 2) + time '10:00') at time zone 'Asia/Ho_Chi_Minh', app.vn_today() - 2, 'valid' from public.profiles where email = 'lead@nt.vn';
select pg_temp.check((select app.day_value('office', app.vn_today() - 2) = 0 or exists(select 1 from public.holidays where day = app.vn_today() - 2)
    or (app.day_info(p.id, 'office', null, app.vn_today() - 2)->>'late')::int = 20
  from public.profiles p where p.email = 'lead@nt.vn'), 'đi muộn tính theo giờ vào đã duyệt (20 phút, về đúng giờ)');
select pg_temp.check((select (summary->>'quen_cham')::int >= 0 from public.timesheet(date_trunc('month', app.vn_today() - 2)::date) where employee_code = (select employee_code from public.profiles where email='lead@nt.vn') limit 1) is not false, 'bảng công chạy');
-- kỳ lương đã chốt → không gửi
insert into public.payroll_periods(month, status) values (date_trunc('month', app.vn_today() - 20)::date, 'closed') on conflict (month) do update set status = 'closed';
select pg_temp.as_user('lead@nt.vn'); set role authenticated;
select pg_temp.err($$insert into public.attendance_requests(kind, work_date, reason, req_time) values ('quen_cham_ra', app.vn_today() - 20, 'Quên chấm về', '17:30')$$, 'đã chốt');
reset role;
delete from public.payroll_periods where month = date_trunc('month', app.vn_today() - 20)::date and status = 'closed';

select 'V37 TESTS PASSED' as result;
