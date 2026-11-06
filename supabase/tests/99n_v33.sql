\set ON_ERROR_STOP 1
-- Bản 33: menu Pháp nhân nhận HĐ — sửa trực tiếp, đổi username, chọn khi lập phiếu
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = p_email), false); end $$;
create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin begin execute p_sql; exception when others then if sqlerrm not ilike '%' || p_like || '%' then raise exception 'Sai lỗi: % (mong đợi %)', sqlerrm, p_like; end if; return; end;
  raise exception 'Mong đợi lỗi "%"', p_like; end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$ begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

update public.customers set sys_username = 'pn_khach1' where id = (select id from public.customers where owner_id = (select id from public.profiles where email='a@nt.vn') order by created_at limit 1);

-- Sale không sửa được; kế toán thêm 2 pháp nhân cho 1 username → pháp nhân đầu là ★
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.expect_error($$select public.out_buyer_save(null, '{"username":"pn_khach1","name":"X","tax_code":"0101234567"}')$$, 'Chỉ Kế toán');
select pg_temp.expect_error($$select public.out_buyers_page('{}')$$, 'Chỉ Kế toán');
reset role; select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_buyer_save(null, '{"username":"pn_khach1","name":"CÔNG TY A","tax_code":"0101234567","address":"Hà Nội","email":"a@a.vn"}');
select public.out_buyer_save(null, '{"username":"pn_khach1","name":"HỘ KINH DOANH B","tax_code":"001191048160","address":"HN"}');
select pg_temp.expect_error($$select public.out_buyer_save(null, '{"username":"pn_khach1","name":"Trùng","tax_code":"0101234567"}')$$, 'đã có pháp nhân MST');
select pg_temp.expect_error($$select public.out_buyer_save(null, '{"username":"pn_khach1","name":"Sai","tax_code":"12345"}')$$, 'sai dạng');
select public.out_buyer_save(null, '{"username":"pn_chua_co","name":"CÔNG TY C","tax_code":"0109999999"}');
reset role;
select pg_temp.check((select count(*) = 2 and count(*) filter (where is_default) = 1 and bool_and(customer_id is not null) from public.out_buyers where username = 'pn_khach1'), '2 pháp nhân, 1 mặc định, gắn khách');
select pg_temp.check((select is_default from public.out_buyers where tax_code = '0101234567' and username = 'pn_khach1'), 'pháp nhân đầu tiên là mặc định');
select pg_temp.check((select customer_id is null from public.out_buyers where username = 'pn_chua_co'), 'username chưa có khách → chưa gắn');

-- Danh sách + cờ chuẩn hóa
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select (r->'counts'->>'chua_gan')::int >= 1 and jsonb_array_length(r->'rows') >= 3 from (select public.out_buyers_page('{}') r) z), 'trang pháp nhân');
select pg_temp.check((select jsonb_array_length(public.out_buyers_page('{"q":"HỘ KINH DOANH B"}')->'rows') = 1), 'tìm theo tên');
-- Sửa trực tiếp: đổi tên + đặt mặc định
select public.out_buyer_save((select id from public.out_buyers where tax_code = '001191048160'), '{"username":"pn_khach1","name":"HỘ KINH DOANH NGUYỄN B","tax_code":"001191048160","address":"Hà Nội","is_default":true}');
reset role;
select pg_temp.check((select name = 'HỘ KINH DOANH NGUYỄN B' and is_default from public.out_buyers where tax_code = '001191048160'), 'sửa tên + đặt mặc định');
select pg_temp.check((select count(*) filter (where is_default) = 1 from public.out_buyers where username = 'pn_khach1'), 'chỉ 1 mặc định');
-- Đổi username → chuyển khách; khách cũ tự có mặc định còn lại
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_buyer_save((select id from public.out_buyers where tax_code = '001191048160'), '{"username":"pn_chua_co","name":"HỘ KINH DOANH NGUYỄN B","tax_code":"001191048160"}');
reset role;
select pg_temp.check((select customer_id is null and not is_default from public.out_buyers where tax_code = '001191048160'), 'chuyển sang username chưa có khách');
select pg_temp.check((select is_default from public.out_buyers where tax_code = '0101234567' and username = 'pn_khach1'), 'khách cũ có lại mặc định');
-- Chọn khi lập phiếu: theo khách + theo username chưa gắn; sale chỉ thấy khách mình
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select jsonb_array_length(public.out_buyers_for(array[(select id from public.customers where sys_username = 'pn_khach1')], array['PN_CHUA_CO'])) = 3), 'sale thấy pháp nhân theo khách + username');
reset role; select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.check((select jsonb_array_length(public.out_buyers_for(array[(select id from public.customers where sys_username = 'pn_khach1')], null)) = 0), 'sale B không thấy pháp nhân khách của A');
-- Xóa
reset role; select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.out_buyer_delete(array[(select id from public.out_buyers where tax_code = '0109999999')]);
reset role;
select pg_temp.check((select count(*) = 0 from public.out_buyers where tax_code = '0109999999'), 'đã xóa');
select 'V33 TESTS PASSED' as result;

-- Bản 34: 2 username chưa gắn khách có cùng pháp nhân (tên + MST) → không báo trùng; nạp đổi tên trùng dòng có sẵn → không hỏng cả lô
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select (r->>'moi')::int = 2 and jsonb_array_length(r->'loi') = 0 from (select public.out_buyers_import_v2('[{"username":"pn_u1","name":"CÔNG TY CHUNG","tax_code":"0108888888"},{"username":"pn_u2","name":"CÔNG TY CHUNG","tax_code":"0108888888"}]') r) z), '2 username cùng pháp nhân');
select public.out_buyer_save(null, '{"username":"pn_khach1","name":"TÊN CŨ","tax_code":"0107777777"}');
select public.out_buyers_import_v2('[{"username":"pn_khach1","name":"TÊN MỚI","tax_code":"0107777777"}]');
reset role;
select pg_temp.check((select count(*) = 2 from public.out_buyers where username in ('pn_u1','pn_u2') and tax_code = '0108888888'), 'lưu đủ 2 username');
select pg_temp.check((select count(*) = 1 and min(name) = 'TÊN MỚI' from public.out_buyers where tax_code = '0107777777'), 'đổi tên theo file');
-- dòng trùng y hệt 2 lần trong 1 file → lần 2 là cập nhật, không lỗi
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select jsonb_array_length(r->'loi') = 0 from (select public.out_buyers_import_v2('[{"username":"pn_u3","name":"X","tax_code":"0106666666"},{"username":"pn_u3","name":"X","tax_code":"0106666666"}]') r) z), 'dòng lặp trong file');
reset role;
select 'V34 TESTS PASSED' as result;
