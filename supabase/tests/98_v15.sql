-- Kiểm thử bản 15: danh sách đơn vị nhận HĐ, tra MST, file đơn hàng gắn khách → sale
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into public.customers(source, customer_type, contact_name, sys_username, owner_id) values ('Khác','Cá nhân','Chị Phương','lethucphuong11',(select id from public.profiles where email='a@nt.vn'));
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check(public.out_buyers_import('[{"tax_code":"0110250411","name":"CÔNG TY TNHH TM VÀ XNK CHÂN TRỜI MỚI","address":"Hà Nội","email":"kt@ctm.vn"},{"tax_code":"0110250411","name":"CÔNG TY TNHH TM VÀ XNK CHÂN TRỜI MỚI","address":"Hà Nội 2"}]') = 2, 'nạp đơn vị');
select public.out_items_import('[{"ma_hang":"HH0009-9001-2026","ten":"Hàng X","dvt":"Cái","vat":0.08,"sl_nhap":10,"so_hd_vao":"9001","stt_hd":9,"md":"MD2943"}]');
select pg_temp.check(public.out_orders_import('[{"md":"MD2943","username":"lethucphuong11","nvkd":""}]') = 1, 'file đơn hàng');
reset role;
select pg_temp.check((select count(*) from public.out_buyers where tax_code='0110250411') = 1 and (select address from public.out_buyers where tax_code='0110250411') = 'Hà Nội 2', 'cập nhật theo MST, không trùng');
select pg_temp.check((select username = 'lethucphuong11' and customer_id is not null and sale_id = (select id from public.profiles where email='a@nt.vn') from public.out_items where ma_hang='HH0009-9001-2026'), 'mã đơn → khách → sale');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select name from public.out_buyer_lookup('0110250411')) like 'CÔNG TY TNHH TM%', 'sale tra MST');
select pg_temp.check((select count(*) from public.out_buyer_lookup('011')) = 0, 'không tra MST ngắn');
reset role;
select 'V15 TESTS PASSED' as result;
