-- Bản 29: CSKH không xem KPI / báo cáo / hỗ trợ khách; thấy hóa đơn sale được hỗ trợ; lọc số HĐ, mã hàng trên danh sách
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = p_email), false); end $$;
create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm not ilike '%' || p_like || '%' then raise exception 'Sai lỗi: % (mong đợi %)', sqlerrm, p_like; end if; return;
  end;
  raise exception 'Mong đợi lỗi "%"', p_like;
end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.check(app.hd_of(null, 'HH00044-2153-2026') = '2153' and app.hd_of('02153', 'x') = '2153' and app.hd_of(null, 'abc') is null, 'tách số HĐ từ mã hàng');

-- dữ liệu: dòng HĐ 2153 của sale A + phiếu
reset role;
insert into public.out_items(id, ma_hang, part, ten, vat, sl_nhap, dg_nhap, md, sale_id, gia_khach, so_hd_vao)
  select '00000000-0000-0000-0029-0000000000a1', 'HH00044-2153-2026', 1, 'Công tắc', 0.08, 10, 100, 'MD2461', id, 103, null from public.profiles where email = 'a@nt.vn';
insert into public.out_items(id, ma_hang, part, ten, vat, sl_nhap, dg_nhap, md, sale_id, gia_khach, so_hd_vao)
  select '00000000-0000-0000-0029-0000000000a2', 'HH00001-2080-2026', 1, 'Hộp', 0.08, 5, 100, 'MD2462', id, 103, '2080' from public.profiles where email = 'a@nt.vn';
insert into public.out_invoices(id, code, sale_id, buyer_name, status) select '00000000-0000-0000-0029-0000000000b1', 'XHD29001', id, 'Cty 2153', 'cho_nhap' from public.profiles where email = 'a@nt.vn';
insert into public.out_invoices(id, code, sale_id, buyer_name, status) select '00000000-0000-0000-0029-0000000000b2', 'XHD29002', id, 'Cty 2080', 'cho_nhap' from public.profiles where email = 'a@nt.vn';
insert into public.out_invoice_lines(invoice_id, item_id, sl, don_gia) values ('00000000-0000-0000-0029-0000000000b1', '00000000-0000-0000-0029-0000000000a1', 2, 103),
  ('00000000-0000-0000-0029-0000000000b2', '00000000-0000-0000-0029-0000000000a2', 1, 103);

-- CSKH (cskh1 hỗ trợ chính sale A từ test bản 28)
select pg_temp.as_user('cskh1@nt.vn'); set role authenticated;
select pg_temp.check(app.is_cskh_only(), 'cskh1 là CSKH thuần');
select pg_temp.check((select count(*) from public.kpi_report(app.vn_today(), app.vn_today())) = 0, 'CSKH không xem KPI');
select pg_temp.check((select count(*) from public.leaderboard(app.vn_today(), app.vn_today())) = 0, 'CSKH không xem Bảng Phong Thần');
select pg_temp.expect_error($$select public.crm_report('funnel', app.vn_today(), app.vn_today())$$, 'không xem báo cáo');
select pg_temp.check((select count(*) from public.daily_reports) = 0, 'CSKH không xem báo cáo ngày');
select pg_temp.check((public.out_invoices_page('{"status":"cho_nhap","limit":50}')->>'total')::int >= 2, 'CSKH thấy hóa đơn của sale A');
select pg_temp.check((select bool_and(r->>'mas' is not null) from jsonb_array_elements(public.out_invoices_page('{"status":"cho_nhap","limit":50,"q":"XHD29"}')->'rows') r), 'có mã hàng trên danh sách');
select pg_temp.check((select bool_or(r->>'code' = 'XHD29001') and not bool_or(r->>'code' = 'XHD29002') from jsonb_array_elements(public.out_invoices_page('{"status":"cho_nhap","limit":50,"hd":"2153"}')->'rows') r), 'lọc số HĐ 2153 (lấy từ mã hàng)');
select pg_temp.check((select bool_and(r->>'hds' like '%2080%') and bool_or(r->>'code' = 'XHD29002') and not bool_or(r->>'code' = 'XHD29001') from jsonb_array_elements(public.out_invoices_page('{"status":"cho_nhap","limit":50,"hd":"2080"}')->'rows') r), 'lọc số HĐ 2080');
select pg_temp.check(exists(select 1 from public.out_hd_opts() where hd = '2153') and exists(select 1 from public.out_hd_opts() where hd = '2080'), 'danh sách số HĐ để lọc');
select pg_temp.check(exists(select 1 from public.out_items_page('{"mode":"mine","limit":500}') x, jsonb_array_elements(x->'rows') r where r->>'ma_hang' = 'HH00044-2153-2026'), 'CSKH thấy hàng sẵn sàng xuất của sale A');
reset role;
-- Sale vẫn xem KPI bình thường
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check(not app.is_cskh_only(), 'sale không bị chặn');
reset role;
select 'V29 TESTS PASSED' as result;
