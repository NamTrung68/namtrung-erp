\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = p_email), false); end $$;
create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin begin execute p_sql; exception when others then if sqlerrm not ilike '%' || p_like || '%' then raise exception 'Sai lỗi: % (mong đợi %)', sqlerrm, p_like; end if; return; end;
  raise exception 'Mong đợi lỗi "%"', p_like; end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$ begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into public.out_invoices(id, code, sale_id, buyer_name, status) select '00000000-0000-0000-0030-0000000000b1', 'XHD30001', id, 'Trần Văn Diệm', 'xac_nhan_ky' from public.profiles where email = 'a@nt.vn';
insert into public.out_invoices(id, code, sale_id, buyer_name, status) select '00000000-0000-0000-0030-0000000000b2', 'XHD30002', id, 'Khách 2', 'xac_nhan_ky' from public.profiles where email = 'a@nt.vn';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.out_mark_signed('00000000-0000-0000-0030-0000000000b1', '1ZF8CQ372VL3')$$, 'Chỉ Kế toán');
reset role; select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.out_mark_signed('00000000-0000-0000-0030-0000000000b1', 'ab')$$, 'không hợp lệ');
select public.out_mark_signed('00000000-0000-0000-0030-0000000000b1', ' 1zf8cq372vl3 ');
select pg_temp.check((select status = 'da_ky' and ma_tra_cuu = '1ZF8CQ372VL3' from public.out_invoices where id = '00000000-0000-0000-0030-0000000000b1'), 'nhập mã → đã ký, chuẩn hóa mã');
select pg_temp.expect_error($$select public.out_mark_signed('00000000-0000-0000-0030-0000000000b2', '1ZF8CQ372VL3')$$, 'đã gắn cho phiếu');
select public.out_mark_signed('00000000-0000-0000-0030-0000000000b1', 'Q_F4CP7LK33M');
select pg_temp.check((select ma_tra_cuu = 'Q_F4CP7LK33M' from public.out_invoices where id = '00000000-0000-0000-0030-0000000000b1'), 'sửa mã sau khi ký');
reset role;
select pg_temp.check((select count(*) = 1 from public.notifications where title = 'Đã ký HĐ: XHD30001'), 'báo sale 1 lần');
select 'V30 TESTS PASSED' as result;
