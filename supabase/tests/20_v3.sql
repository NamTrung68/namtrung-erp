-- Kiểm thử bản 3: thông tin khách trong Hỗ trợ khách + hồ sơ nhân sự
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = p_email), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not ilike '%' || p_like || '%' then raise exception 'Sai lỗi: % (mong đợi %)', sqlerrm, p_like; end if; return;
  end;
  raise exception 'Mong đợi lỗi "%" nhưng chạy thành công: %', p_like, p_sql;
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- Sale A nhờ Sale B hỗ trợ khách của A; B (ngoài cây quản lý) xem được thông tin + lịch sử chăm sóc qua yêu cầu
select pg_temp.as_user('a@nt.vn'); set role authenticated;
insert into public.support_requests(kind, requester_id, assignee_id, customer_id, title)
select 'nho_ho_tro', (select id from public.profiles where email='a@nt.vn'), (select id from public.profiles where email='b@nt.vn'),
       (select id from public.customers where owner_id = (select id from public.profiles where email='a@nt.vn') limit 1), 'Nhờ tư vấn thuế';
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.customers where owner_id = (select id from public.profiles where email='a@nt.vn')) = 0, 'B không đọc trực tiếp khách của A');
select pg_temp.check((select public.support_customer(id)->>'code' from public.support_requests where title = 'Nhờ tư vấn thuế') is not null, 'B xem được thông tin khách qua yêu cầu');
select pg_temp.check(jsonb_typeof((select public.support_customer(id)->'care' from public.support_requests where title = 'Nhờ tư vấn thuế')) = 'array', 'có lịch sử chăm sóc');
reset role;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.support_requests where title = 'Nhờ tư vấn thuế') = 0, 'Kế toán không thấy yêu cầu');
reset role;

-- Hồ sơ nhân sự
select pg_temp.as_user('hr@nt.vn'); set role authenticated;
insert into public.hr_records(profile_id, id_number, current_address) values ((select id from public.profiles where email='a@nt.vn'), '001099000111', 'Hà Nội');
insert into public.hr_contracts(profile_id, contract_no, contract_type, start_date, end_date, base_salary)
  values ((select id from public.profiles where email='a@nt.vn'), 'HDTV-01', 'thu_viec', app.vn_today() - 10, app.vn_today() + 7, 8000000);
select pg_temp.check((select employment_status from public.hr_records where profile_id = (select id from public.profiles where email='a@nt.vn')) = 'thu_viec', 'HĐ thử việc cập nhật tình trạng');
insert into public.hr_agreements(profile_id, title, confidential) values ((select id from public.profiles where email='a@nt.vn'), 'Thưởng giữ chân', false);
select pg_temp.expect_error($$insert into public.hr_agreements(profile_id, title, confidential) values ((select id from public.profiles where email='a@nt.vn'), 'Mật', true)$$, 'row-level security');
select pg_temp.check((select docs_missing from public.hr_overview() where profile_id = (select id from public.profiles where email='a@nt.vn')) = 5, 'thiếu 5 giấy tờ bắt buộc');
reset role;
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
insert into public.hr_agreements(profile_id, title, confidential, kind, amount) values ((select id from public.profiles where email='a@nt.vn'), 'Hoa hồng riêng khách VIP', true, 'hoa_hong', 2000000);
reset role;
select pg_temp.as_user('hr@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.hr_agreements) = 1, 'HCNS không thấy thỏa thuận mật');
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.hr_agreements) = 2, 'Chính chủ thấy thỏa thuận của mình');
select pg_temp.check((select count(*) from public.hr_records) = 1, 'Chính chủ thấy hồ sơ mình');
select pg_temp.check((select count(*) from public.hr_overview()) = 0, 'Sale không xem tổng hợp hồ sơ');
select pg_temp.expect_error($$insert into public.hr_contracts(profile_id, contract_type, start_date) values (auth.uid(), 'ctv', current_date)$$, 'row-level security');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.hr_records) = 0, 'B không thấy hồ sơ A');
reset role;
select app.job_contract_expiry();
select pg_temp.check((select count(*) from public.notifications where kind = 'hr' and title like 'Hợp đồng sắp hết hạn%') >= 1, 'nhắc HĐ sắp hết hạn');
select 'V3 TESTS PASSED' as result;
