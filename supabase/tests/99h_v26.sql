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

-- HCNS không còn tạo tài khoản / lời mời
select pg_temp.as_user('hr@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.invite_user('x26@nt.vn', 'X', '{sale}', 'nhan_vien', null, null)$$, 'Chỉ Admin');
select pg_temp.expect_error($$insert into public.invites(email, full_name, roles) values ('y26@nt.vn', 'Y', '{sale}')$$, 'row-level security');
reset role;
-- Admin vẫn tạo được
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.invite_user('z26@nt.vn', 'Z', '{sale}', 'nhan_vien', null, null);
delete from public.invites where email = 'z26@nt.vn';
reset role;

-- Sale không có cấp dưới: không tạo được ủy quyền duyệt
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.expect_error(format($$insert into public.delegations(delegator_id, delegate_id, from_at, to_at) values (%L, %L, now(), now() + interval '1 day')$$,
  (select id from public.profiles where email='b@nt.vn'), (select id from public.profiles where email='a@nt.vn')), 'row-level security');
reset role;
-- Trưởng nhóm (có cấp dưới) vẫn ủy quyền được
select pg_temp.as_user('lead@nt.vn'); set role authenticated;
insert into public.delegations(delegator_id, delegate_id, from_at, to_at)
  select (select id from public.profiles where email='lead@nt.vn'), (select id from public.profiles where email='tp@nt.vn'), now(), now() + interval '1 day';
reset role;
select pg_temp.check((select count(*) from public.delegations where delegator_id = (select id from public.profiles where email='lead@nt.vn') and revoked_at is null) >= 1, 'TN ủy quyền được');
update public.delegations set revoked_at = now() where delegator_id = (select id from public.profiles where email='lead@nt.vn') and revoked_at is null;
select 'V26 TESTS PASSED' as result;
