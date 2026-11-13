-- Kiểm thử bản 48: Mở / Khóa cập nhật pháp nhân
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.check(app.pn_mo(), 'mặc định sau bản 48: đang mở');
insert into public.customers(id, code, contact_name, phone, customer_type, source, owner_id, sys_username)
  select '00000000-0000-0000-0048-0000000000c1', 'KHV48', 'Khách V48', '+84 912 480 048', 'nha_buon', 'tu_tim_zalo', id, 'khv48' from public.profiles where email = 'a@nt.vn';

-- sale không khóa / mở được
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_pn_lock_set(false)$$, 'Chỉ Kế toán / Admin');
-- đang mở: sale thêm pháp nhân cho khách mình
select public.out_buyer_save(null, '{"username":"khv48","name":"Công ty V48","tax_code":"0104848484","address":"Hà Nội"}');
reset role;

-- kế toán khóa
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_pn_lock_set(false);
reset role;
select pg_temp.check(not app.pn_mo(), 'đã khóa');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_buyer_save((select id from public.out_buyers where tax_code = '0104848484'), '{"username":"khv48","name":"Công ty V48 sửa","tax_code":"0104848484","address":"Hà Nội"}')$$, 'đang khóa');
select pg_temp.err($$select public.out_buyer_delete(array(select id from public.out_buyers where tax_code = '0104848484'))$$, 'đang khóa');
select pg_temp.err($$select public.out_buyer_doc_info((select id from public.out_buyers where tax_code = '0104848484'), '{"dai_dien":"Ông A"}')$$, 'đang khóa');
select pg_temp.err($$select public.out_buyer_set_default((select id from public.out_buyers where tax_code = '0104848484'))$$, 'đang khóa');
-- vẫn xem được
select pg_temp.check(jsonb_array_length(public.out_buyers_page('{"q":"0104848484"}')->'rows') = 1, 'đang khóa vẫn xem được');
reset role;
-- kế toán vẫn sửa được khi khóa
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_buyer_save((select id from public.out_buyers where tax_code = '0104848484'), '{"username":"khv48","name":"Công ty V48 chuẩn","tax_code":"0104848484","address":"Hà Nội"}');
reset role;
select pg_temp.check((select name = 'Công ty V48 chuẩn' from public.out_buyers where tax_code = '0104848484'), 'kế toán sửa khi khóa');
-- mở lại: sale có thông báo
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_pn_lock_set(true);
reset role;
select pg_temp.check(exists(select 1 from public.notifications n join public.profiles p on p.id = n.recipient_id where p.email = 'a@nt.vn' and n.title like 'Mở cập nhật Pháp nhân%'), 'mở → báo sale');
select 'V48 TESTS PASSED' as result;
