-- Kiểm thử bản 44: khung giá riêng theo khách
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
-- khách KHV36 (của a@): báo giá UT 0%, DV 0.2%, cước khối 500k
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.save_quote(null, '00000000-0000-0000-0036-0000000000c1', '{"tyGia":4100,"phiUTPct":0,"phiDVPct":0.2,"soKhoi":2,"donGiaKhoi":500000,"khoNhan":"HN"}'::jsonb, '[{"name":"Hàng A","qty":10,"unit_price_cny":5}]', '{}')$$, 'CẤM');
select pg_temp.err($$select public.customer_price_floor_set('00000000-0000-0000-0036-0000000000c1', '{"phi_ut_min":0}')$$, 'Chỉ Admin');
reset role;
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.customer_price_floor_set('00000000-0000-0000-0036-0000000000c1', '{"phi_ut_min":0,"phi_dv_min":0,"cuoc_khoi_min":400000,"note":"Khách thân"}');
reset role;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select phi_ut_min = 0 and cuoc_khoi_min = 400000 from public.customer_price_floor where customer_id = '00000000-0000-0000-0036-0000000000c1'), 'sale đọc được khung riêng');
select pg_temp.err($$update public.customer_price_floor set phi_ut_min = 0 where customer_id = '00000000-0000-0000-0036-0000000000c1'$$, 'permission denied');
do $$ declare v uuid; begin
  v := public.save_quote(null, '00000000-0000-0000-0036-0000000000c1', '{"tyGia":4100,"phiUTPct":0,"phiDVPct":0.2,"soKhoi":2,"donGiaKhoi":500000,"khoNhan":"HN"}', '[{"name":"Hàng A","qty":10,"unit_price_cny":5}]', '{}');
  perform pg_temp.check((select cardinality(violations) = 0 from public.quotations where id = v), 'trong khung riêng → không phải duyệt');
  perform pg_temp.check(public.quote_submit(v) = 'da_gui', 'gửi luôn');
end $$;
-- khách khác vẫn theo mức chung
select pg_temp.check(cardinality(app.quote_check('{"tyGia":4100,"phiUTPct":1,"phiDVPct":0.2,"soKhoi":2,"donGiaKhoi":500000,"khoNhan":"HN"}', '[{"name":"x","qty":1,"unit_price_cny":1}]')) = 2, 'khách khác: DV + cước phải duyệt');
reset role;
-- xóa khung riêng
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select public.customer_price_floor_set('00000000-0000-0000-0036-0000000000c1', '{}');
reset role;
select pg_temp.check(not exists(select 1 from public.customer_price_floor where customer_id = '00000000-0000-0000-0036-0000000000c1'), 'xóa khung riêng');
select 'V44 TESTS PASSED' as result;
