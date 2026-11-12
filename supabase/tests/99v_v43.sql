-- Kiểm thử bản 43: phút muộn / sớm — gộp khoảng, gặp khách theo giờ / theo buổi, nghỉ nửa ngày
\set ON_ERROR_STOP 1
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
-- ngày thường gần nhất đã qua (không phải T7, CN, lễ)
create temp table d43 as select x::date d from generate_series(app.vn_today() - 14, app.vn_today() - 1, interval '1 day') x
  where extract(isodow from x) between 1 and 5 and not exists(select 1 from public.holidays h where h.day = x::date) order by x desc limit 1;
create temp table p43 as select id, email from public.profiles where email in ('b@nt.vn', 'hr@nt.vn', 'kt@nt.vn');
set session_replication_role = replica;  -- bỏ qua trigger thông báo / hạn gửi đơn khi dựng dữ liệu
delete from public.leave_requests where start_date = (select d from d43) and profile_id in (select id from p43);
delete from public.attendance_events where work_date = (select d from d43) and profile_id in (select id from p43);
delete from public.attendance_requests where work_date = (select d from d43) and profile_id in (select id from p43);
insert into public.attendance_events(profile_id, kind, at, work_date, status)
  select id, k, ((select d from d43) + t::time) at time zone 'Asia/Ho_Chi_Minh', (select d from d43), 'valid'
  from p43, (values ('b@nt.vn', 'in', '08:14'), ('b@nt.vn', 'out', '14:39'),     -- vào muộn 14′, về 14:39
                    ('hr@nt.vn', 'in', '13:28'), ('hr@nt.vn', 'out', '17:32'),   -- nghỉ sáng, vào 13:28
                    ('kt@nt.vn', 'in', '08:01'), ('kt@nt.vn', 'out', '14:41')) v(e, k, t) where p43.email = v.e;
-- b@: xin "đi muộn, về sớm, ra ngoài" 14:41–17:30 đã duyệt
insert into public.leave_requests(profile_id, leave_type, start_date, end_date, part, from_time, to_time, reason, status, days)
  select id, 'muon_som', (select d from d43), (select d from d43), 'hours', '14:41', '17:30', 'Ra ngoài', 'da_duyet', 0 from p43 where email = 'b@nt.vn';
-- hr@: nghỉ không lương buổi sáng
insert into public.leave_requests(profile_id, leave_type, start_date, end_date, part, reason, status, days)
  select id, 'khong_luong', (select d from d43), (select d from d43), 'am', 'Đau đầu', 'da_duyet', 0.5 from p43 where email = 'hr@nt.vn';
set session_replication_role = origin;
create temp table r43 as select p.email, app.day_info(p.id, 'office', null, (select d from d43)) i from p43 p;
-- b@: 14′ muộn + (14:39 → 17:30 = 171′) gộp với giờ xin 14:41–17:30 → 185′ (trước đây 14 + 171 + 169 = 354)
select pg_temp.check((select (i->>'late')::int from r43 where email = 'b@nt.vn') = 185, 'xin về sớm: không cộng trùng (185′): ' || (select i::text from r43 where email = 'b@nt.vn'));
select pg_temp.check((select (i->>'late')::int from r43 where email = 'hr@nt.vn') = 0 and (select i->>'code' from r43 where email = 'hr@nt.vn') = 'KL½', 'nghỉ sáng, vào 13:28 → không muộn');
-- kt@: ra gặp khách 14:41 không về → chưa có đơn: 169′ về sớm
select pg_temp.check((select (i->>'late')::int from r43 where email = 'kt@nt.vn') = 170, 'chưa có đơn: 1′ muộn + 169′ về sớm');
-- kt@: đơn "Công tác, gặp khách" theo giờ 14:40–17:30 → 0′, vẫn tính đủ công
set session_replication_role = replica;
insert into public.leave_requests(profile_id, leave_type, start_date, end_date, part, from_time, to_time, reason, status, days)
  select id, 'cong_tac', (select d from d43), (select d from d43), 'hours', '14:40', '17:30', 'Gặp khách', 'da_duyet', 0 from p43 where email = 'kt@nt.vn';
set session_replication_role = origin;
select pg_temp.check((select (app.day_info(id, 'office', null, (select d from d43))->>'late')::int = 1 and (app.day_info(id, 'office', null, (select d from d43))->>'worked')::numeric = 1 from p43 where email = 'kt@nt.vn'), 'gặp khách theo giờ → chỉ còn 1′ vào muộn, đủ công');
-- đổi thành gặp khách buổi chiều: vẫn 0′; nhưng vào muộn buổi sáng vẫn bị tính
set session_replication_role = replica;
update public.leave_requests set part = 'pm', from_time = null, to_time = null where profile_id = (select id from p43 where email = 'kt@nt.vn') and start_date = (select d from d43);
update public.attendance_events set at = ((select d from d43) + time '08:20') at time zone 'Asia/Ho_Chi_Minh' where profile_id = (select id from p43 where email = 'kt@nt.vn') and work_date = (select d from d43) and kind = 'in';
set session_replication_role = origin;
select pg_temp.check((select (app.day_info(id, 'office', null, (select d from d43))->>'late')::int from p43 where email = 'kt@nt.vn') = 20, 'gặp khách chiều: chỉ che buổi chiều, sáng muộn 20′ vẫn tính');
-- dọn
set session_replication_role = replica;
delete from public.leave_requests where start_date = (select d from d43) and profile_id in (select id from p43);
delete from public.attendance_events where work_date = (select d from d43) and profile_id in (select id from p43);
set session_replication_role = origin;
select 'V43 TESTS PASSED' as result;
-- Tạo đơn "Công tác, gặp khách" theo giờ (quản lý tạo hộ cho ngày đã qua)
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = 'namtrung20266@gmail.com'), false);
select d as d43v from d43 \gset
set role authenticated;
insert into public.leave_requests(profile_id, leave_type, start_date, end_date, part, from_time, to_time, reason)
  select id, 'cong_tac', :'d43v'::date, :'d43v'::date + 3, 'hours', '14:40', '17:30', 'Gặp khách' from public.profiles where email = 'kt@nt.vn';
reset role;
select pg_temp.check((select part = 'hours' and end_date = start_date and status = 'da_duyet' from public.leave_requests where profile_id = (select id from p43 where email = 'kt@nt.vn') and start_date = (select d from d43)), 'tạo hộ gặp khách theo giờ');
set session_replication_role = replica;
delete from public.leave_requests where start_date = (select d from d43) and profile_id in (select id from p43);
set session_replication_role = origin;
