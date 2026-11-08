-- Kiểm thử bản 36: bộ nhớ đệm MST; pháp nhân theo phạm vi sale (không xem chéo); vết hồ sơ chứng từ
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- A. MST cache
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.mst_cache_put('0108195040', '{"found":true,"name":"CÔNG TY NAM TRUNG","address":"HN","status":"NNT đang hoạt động","provider":"xinvoice"}');
select public.mst_cache_put('0101248142', '{"found":false,"provider":"xinvoice"}');
select pg_temp.check((public.mst_cache_get('0108195040')->>'name') = 'CÔNG TY NAM TRUNG' and (public.mst_cache_get('0108195040')->>'cached')::boolean, 'đọc cache');
select pg_temp.check(public.mst_cache_get('0101248142') is null, 'không lưu kết quả không tìm thấy');
select pg_temp.err($$select public.mst_cache_put('123', '{"found":true,"name":"x"}')$$, 'MST sai dạng');
reset role;

-- B. Pháp nhân theo phạm vi: a@ thấy khách mình, b@ không thấy
insert into public.customers(id, code, company_name, contact_name, customer_type, source, phone, owner_id, sys_username)
  select '00000000-0000-0000-0036-0000000000c1', 'KHV36', 'Cty V36', 'Anh V36', 'nha_buon', 'tu_tim_zalo', '+84 912 360 036', id, 'khv36' from public.profiles where email='a@nt.vn';
insert into public.out_buyers(customer_id, username, name, tax_code, address) values ('00000000-0000-0000-0036-0000000000c1', 'khv36', 'CÔNG TY V36', '0101248141', 'Hà Nội');
insert into public.out_buyers(username, name, tax_code) values ('khongaicoV36', 'CÔNG TY LẠC V36', '0108195040');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select bool_and(x->>'username' is not null and x->>'customer_id' is not null) and count(*) >= 1 and bool_or(x->>'name' = 'CÔNG TY V36') and not bool_or(x->>'name' = 'CÔNG TY LẠC V36')
  from jsonb_array_elements(public.out_buyers_page('{"limit":2000}')->'rows') x), 'sale chỉ thấy pháp nhân khách mình');
select pg_temp.check(not (public.out_buyers_page('{}')->>'acc')::boolean, 'cờ không phải kế toán');
-- sửa được, nhưng không đổi được mã HĐNT
select public.out_buyer_save((select id from public.out_buyers where tax_code = '0101248141' and username = 'khv36'), '{"username":"khv36","name":"CÔNG TY CP V36","tax_code":"0101248141","address":"Hà Nội","ma_hdnt":"SALE-SUA"}');
reset role;
select pg_temp.check((select name = 'CÔNG TY CP V36' and ma_hdnt is null from public.out_buyers where tax_code = '0101248141' and username = 'khv36'), 'sale sửa tên, không sửa mã HĐNT');
select id as pnlac from public.out_buyers where username = 'khongaicoV36' \gset
select id as pn36 from public.out_buyers where username = 'khv36' \gset
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err(format('select public.out_buyer_save(%L, %L)', :'pnlac', '{"username":"khongaicoV36","name":"X","tax_code":"0108195040"}'), 'không');
select pg_temp.err($$select public.out_buyer_save(null, '{"username":"khongco_v36","name":"X","tax_code":"0108195040"}')$$, 'không phải khách bạn phụ trách');
select public.out_buyer_save(null, '{"username":"khv36","name":"HKD PHỤ V36","tax_code":"038098020305"}');
select pg_temp.check(public.out_buyer_delete(array(select id from public.out_buyers where username = 'khv36' and tax_code = '038098020305')) = 1, 'sale xóa pháp nhân chưa dùng');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check(not exists(select 1 from jsonb_array_elements(public.out_buyers_page('{"limit":2000}')->'rows') x where x->>'username' = 'khv36'), 'sale khác không thấy');
select pg_temp.err(format('select public.out_buyer_save(%L, %L)', :'pn36', '{"username":"khv36","name":"X","tax_code":"0101248141"}'), 'không thuộc khách');
select pg_temp.err(format('select public.out_buyer_delete(array[%L]::uuid[])', :'pn36'), 'Chỉ xóa được');
reset role;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check(exists(select 1 from jsonb_array_elements(public.out_buyers_page('{"limit":2000}')->'rows') x where x->>'username' = 'khongaicov36' or x->>'name' = 'CÔNG TY LẠC V36'), 'kế toán thấy tất cả');
reset role;

-- C. Vết hồ sơ chứng từ
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_invoice_save(null, jsonb_build_object('customer_id', '00000000-0000-0000-0036-0000000000c1', 'buyer_name', 'CÔNG TY CP V36', 'tax_code', '0101248141', 'address', 'Hà Nội', 'payment', 'CK', 'submit', true),
  jsonb_build_array(jsonb_build_object('item_id', (select id from public.out_items where ma_hang = 'M3433-5-2080'), 'sl', 1, 'don_gia', 52000, 'vat', 0.08)));
reset role;
update public.out_invoices set status = 'da_ky', so_hd = '3001', ngay_hd = '2026-11-08' where buyer_name = 'CÔNG TY CP V36';
select id as inv36 from public.out_invoices where buyer_name = 'CÔNG TY CP V36' \gset
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select public.out_doc_mark(array[:'inv36']::uuid[], 'tai', array['ddh', 'bbgn', 'xxx']);
select public.out_doc_mark(array[:'inv36']::uuid[], 'tai', array['ddh']);
select pg_temp.check((select (tai->'ddh'->>'n')::int = 2 and tai ? 'bbgn' and not tai ? 'xxx' and gui_at is null from public.out_doc_state where invoice_id = :'inv36'), 'ghi vết tải');
select public.out_doc_mark(array[:'inv36']::uuid[], 'ky', '{}', 'https://drive.google.com/file/d/abc');
select pg_temp.check((select ky_at is not null and gui_at is not null and ky_url like 'https://drive%' from public.out_doc_state where invoice_id = :'inv36'), 'đã ký kéo theo đã gửi');
select pg_temp.err(format('select public.out_doc_mark(array[%L]::uuid[], %L, %L, %L)', :'inv36', 'ky', '{}', 'javascript:alert(1)'), 'https');
select public.out_doc_mark(array[:'inv36']::uuid[], 'bo_ky');
select pg_temp.check((select ky_at is null and ky_url is null from public.out_doc_state where invoice_id = :'inv36'), 'bỏ đã ký');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.err(format('select public.out_doc_mark(array[%L]::uuid[], %L)', :'inv36', 'gui'), 'Không có quyền');
select pg_temp.check((select count(*) = 0 from public.out_doc_state where invoice_id = :'inv36'), 'sale khác không đọc được vết');
reset role;
select 'V36 TESTS PASSED' as result;
