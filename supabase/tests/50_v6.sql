-- Kiểm thử bản 6: sinh nhật, đặt lại mật khẩu
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.as_user('b@nt.vn'); set role authenticated;
select public.set_my_dob((make_date(1995, extract(month from app.vn_today())::int, extract(day from app.vn_today())::int)));
do $$ begin perform public.set_my_dob('1990-01-01'); raise exception 'phải chặn'; exception when others then if sqlerrm not like 'Ngày sinh đã có%' then raise; end if; end $$;
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.birthdays() where is_today and full_name = 'Sale B') = 1, 'A thấy sinh nhật B hôm nay');
reset role;
select app.job_birthdays();
select pg_temp.check((select count(*) from public.notifications where kind = 'birthday') >= 2, 'báo sinh nhật');

select pg_temp.as_user('hr@nt.vn'); set role authenticated;
select public.admin_set_password((select id from public.profiles where email = 'a@nt.vn'), 'MatKhauMoi123');
do $$ begin perform public.admin_set_password((select id from public.profiles where email = 'namtrung20266@gmail.com'), 'MatKhauMoi123'); raise exception 'phải chặn'; exception when others then if sqlerrm not like 'Không có quyền%' then raise; end if; end $$;
reset role;
select pg_temp.check((select encrypted_password like '$2%' from auth.users where email = 'a@nt.vn'), 'mật khẩu mới đúng');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ begin perform public.admin_set_password((select id from public.profiles where email = 'b@nt.vn'), 'MatKhauMoi123'); raise exception 'phải chặn'; exception when others then if sqlerrm not like 'Không có quyền%' then raise; end if; end $$;
reset role;
select 'V6 TESTS PASSED' as result;
