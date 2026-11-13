-- Kiểm thử bản 51: nạp HĐ tồn
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;
insert into public.customers(id, code, contact_name, phone, customer_type, source, owner_id, sys_username)
  select '00000000-0000-0000-0051-0000000000c1', 'KHV51', 'Khách V51', '+84 912 510 051', 'nha_buon', 'tu_tim_zalo', id, 'khv51' from public.profiles where email = 'a@nt.vn';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_items_import_ton('[]', true)$$, 'Chỉ Kế toán');
reset role;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_items_import_ton('[]', true, 1.0103)$$, 'Hệ số');
do $$ declare r jsonb; v jsonb := '[{"ma_hang":"HH00001-5101-2026","ten":"Hàng tồn A","sl_nhap":10,"dg_nhap":1000,"vat":0.08,"so_hd_vao":"5101","md":"MD5101","username":"khv51","nvkd":"Sale A"},{"ma_hang":"HH00002-5101-2026","ten":"Hàng tồn B","sl_nhap":5,"dg_nhap":1746,"so_hd_vao":"5101","md":"MD5102","username":"","nvkd":"Sale A"},{"ma_hang":"HH00003-5101-2026","ten":"Hàng tồn C","sl_nhap":5,"dg_nhap":100,"so_hd_vao":"5101","nvkd":""},{"ma_hang":"HH00004-5101-2026","ten":"Hàng tồn D","sl_nhap":5,"dg_nhap":100,"so_hd_vao":"5101","nvkd":"Người Lạ"},{"ma_hang":"HH00005-5101-2026","ten":"Hàng tồn E","sl_nhap":0,"dg_nhap":100,"nvkd":"Sale A"}]'; t public.out_items; begin
  r := public.out_items_import_ton(v, true);
  perform pg_temp.check((r->>'moi')::int = 2 and (r->>'thieu_sale')::int = 2 and (r->>'loi')::int = 1, 'kiểm thử: ' || r::text);
  perform pg_temp.check(not exists(select 1 from public.out_items where ma_hang like 'HH0000%-5101-2026'), 'chạy thử không ghi');
  r := public.out_items_import_ton(v, false);
  perform pg_temp.check((r->>'moi')::int = 2, 'nạp 2 dòng');
  select * into t from public.out_items where ma_hang = 'HH00001-5101-2026';
  perform pg_temp.check(t.gia_khach = 1030 and t.gia_src = 'ton' and t.match_src = 'ton' and t.sale_id is not null and t.customer_id = '00000000-0000-0000-0051-0000000000c1' and t.md = 'MD5101', 'dòng có username: giá ×1,03, sale, khách');
  select * into t from public.out_items where ma_hang = 'HH00002-5101-2026';
  perform pg_temp.check(t.gia_khach = 1798 and t.customer_id is null and t.username is null and t.sale_id is not null, 'không username vẫn nạp, giá làm tròn đồng');
  perform pg_temp.check(not exists(select 1 from public.out_items where ma_hang in ('HH00003-5101-2026', 'HH00004-5101-2026', 'HH00005-5101-2026')), 'không sale / sale lạ / SL 0 → không nạp');
  -- nạp lại: đã có → bỏ qua
  r := public.out_items_import_ton(v, false);
  perform pg_temp.check((r->>'moi')::int = 0 and (r->>'da_co')::int = 2, 'nạp lại bỏ qua');
  -- điền username sau → gắn khách, giữ giá tồn
  perform public.out_items_fix_kh(array(select id from public.out_items where ma_hang = 'HH00002-5101-2026'), null, 'khv51');
  select * into t from public.out_items where ma_hang = 'HH00002-5101-2026';
  perform pg_temp.check(t.customer_id = '00000000-0000-0000-0051-0000000000c1' and t.gia_khach = 1798 and t.acc_line_id is null, 'điền username sau: gắn khách, giữ giá, không ghép nháp');
end $$;
reset role;
select 'V51 TESTS PASSED' as result;
