-- =====================================================================
-- 0026 · Bản 19: tăng tốc cho tài khoản sale / quản lý sale
--  · app.in_tree: tính cây nhân sự 1 lần mỗi lượt gọi (trước đây tính lại cho TỪNG dòng → rất chậm với sale)
--  · Trang Xuất HĐ đầu ra: hàm đọc riêng, gom 1 lần, lọc theo quyền ngay từ đầu
--  · Lọc theo khách / chưa gắn khách / chưa gắn đơn / chưa có giá xuất; danh sách sale theo nhóm
--  · Sổ cũ "Đã xuất nháp" → phiếu "Đã xuất nháp – chờ sale" của từng sale
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 19');

-- ---------- Cây nhân sự: nhớ trong 1 lượt gọi ----------
create or replace function app.in_tree(p_id uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare k text := coalesce(auth.uid()::text, '-'); c text := current_setting('nt.tree', true); t uuid[];
begin
  if p_id is null then return false; end if;
  if c is not null and c <> '' and split_part(c, '|', 1) = k then t := split_part(c, '|', 2)::uuid[];
  else t := app.my_tree(); perform set_config('nt.tree', k || '|' || t::text, true); end if;
  return p_id = any(t);
end $$;

-- ---------- Dòng sổ (đọc nhanh, đúng quyền) ----------
create index if not exists out_invoice_lines_item_inv on public.out_invoice_lines(item_id, invoice_id);

create or replace function app.out_items_scope(p_mode text) returns setof public.out_items
language plpgsql stable security definer set search_path = public, app as $$
declare v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree(); v_sale boolean := app.has_role('sale','tn_kd','tp_kd');
begin
  if p_mode = 'acc' then
    if not v_acc then return; end if;
    return query select * from public.out_items;
  elsif p_mode = 'free' then
    if not (v_acc or v_sale) then return; end if;
    return query select * from public.out_items where sale_id is null;
  else
    return query select * from public.out_items where sale_id = any(v_tree);
  end if;
end $$;

drop function if exists public.out_items_page(jsonb);
create or replace function public.out_items_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_mode text := coalesce(p->>'mode', 'acc'); v_f text := nullif(p->>'f', ''); v_q text := nullif(btrim(p->>'q'), '');
        v_hd text := nullif(p->>'hd', ''); v_xe text := nullif(p->>'xe', ''); v_sale text := nullif(p->>'sale', ''); v_kh text := nullif(p->>'kh', '');
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint;
begin
  with s as (select * from app.out_items_scope(v_mode)),
  a as (select l.item_id, sum(l.sl) sl, string_agg(i.code || ':' || i.status, ',' order by i.code) phieu
          from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id
         where i.status <> 'huy' and l.item_id in (select id from s) group by l.item_id),
  b as (select s.*, coalesce(a.sl, 0) sl_xuat, s.sl_nhap - coalesce(a.sl, 0) ton, a.phieu, coalesce(c.company_name, c.contact_name) khach, x.xe
          from s left join a on a.item_id = s.id left join public.customers c on c.id = s.customer_id left join public.out_hd_xe x on x.so_hd = ltrim(s.so_hd_vao, '0')),
  f as (select * from b t
     where (v_mode = 'acc' or t.ton > 0.0001)
       and (v_f is null or (v_f = 'ton' and t.ton > 0.0001) or (v_f = 'het' and t.ton <= 0.0001)
            or (v_f = 'nosale' and t.sale_id is null and t.ton > 0.0001) or (v_f = 'daky_nosale' and t.sale_id is null and t.ton <= 0.0001)
            or (v_f = 'nomd' and t.md is null) or (v_f = 'nogia' and t.gia_khach is null and t.ton > 0.0001)
            or (v_f = 'nokhach' and t.customer_id is null and t.username is null))
       and (v_hd is null or t.so_hd_vao = v_hd) and (v_xe is null or coalesce(t.xe, '—') = v_xe)
       and (v_sale is null or coalesce(t.sale_id::text, '—') = v_sale)
       and (v_kh is null or coalesce(t.customer_id::text, t.username, '—') = v_kh)
       and (v_q is null or concat_ws(' ', t.ma_hang, t.ten, t.md, t.nvkd, t.username, t.khach, t.so_hd_vao, t.xe) ilike '%' || v_q || '%')),
  o as (select f.*, row_number() over (order by f.stt_so desc nulls last, f.ma_hang, f.part) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r);
end $$;
grant execute on function public.out_items_page(jsonb) to authenticated;

drop function if exists public.out_items_stats(text);
create or replace function public.out_items_stats(p_mode text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb;
begin
  with s as (select * from app.out_items_scope(p_mode)),
  a as (select l.item_id, sum(l.sl) sl from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id
         where i.status <> 'huy' and l.item_id in (select id from s) group by l.item_id),
  b as (select s.id, s.sale_id, s.md, s.customer_id, s.username, s.gia_khach, s.dg_nhap, s.so_hd_vao, s.sl_nhap - coalesce(a.sl, 0) ton,
               x.xe, coalesce(c.company_name, c.contact_name) khach
          from s left join a on a.item_id = s.id left join public.out_hd_xe x on x.so_hd = ltrim(s.so_hd_vao, '0') left join public.customers c on c.id = s.customer_id),
  v as (select * from b where p_mode = 'acc' or ton > 0.0001)
  select jsonb_build_object(
    'all', count(*), 'ton', count(*) filter (where ton > 0.0001), 'het', count(*) filter (where ton <= 0.0001),
    'nosale', count(*) filter (where sale_id is null and ton > 0.0001), 'daky_nosale', count(*) filter (where sale_id is null and ton <= 0.0001),
    'nomd', count(*) filter (where md is null), 'nogia', count(*) filter (where gia_khach is null and ton > 0.0001),
    'nokhach', count(*) filter (where customer_id is null and username is null),
    'gia_tri', coalesce(sum(ton * coalesce(gia_khach, dg_nhap, 0)) filter (where ton > 0.0001), 0),
    'hd', coalesce((select jsonb_agg(distinct so_hd_vao) from v where so_hd_vao is not null), '[]'),
    'xe', coalesce((select jsonb_agg(distinct coalesce(xe, '—')) from v), '[]'),
    'kh', coalesce((select jsonb_agg(jsonb_build_array(k, t) order by t) from (select distinct coalesce(customer_id::text, username) k, coalesce(khach, username) t from v where coalesce(customer_id::text, username) is not null) z), '[]'),
    'sale', coalesce((select jsonb_agg(distinct coalesce(sale_id::text, '—')) from v), '[]'))
  into r from v;
  return r;
end $$;
grant execute on function public.out_items_stats(text) to authenticated;

-- Danh sách sale được xem: kế toán/admin = mọi sale; quản lý = cả nhóm; sale = chính mình
create or replace function public.out_sale_opts() returns table(id uuid, full_name text)
language sql stable security definer set search_path = public, app as $$
  select p.id, p.full_name from public.profiles p
   where p.status = 'active' and p.roles && array['sale','tn_kd','tp_kd']
     and (app.is_acc() or p.id = any(app.my_tree()))
   order by p.full_name
$$;
grant execute on function public.out_sale_opts() to authenticated;

-- ---------- Phiếu (đọc nhanh, đúng quyền) ----------
drop function if exists public.out_invoices_page(jsonb);
create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree();
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale) group by status) z;
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia
          from base b left join a on a.invoice_id = b.id
         where v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%'),
  o as (select f.*, row_number() over (order by f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

-- ---------- Sổ cũ: dòng đã xuất nháp → phiếu "Đã xuất nháp – chờ sale" ----------
create or replace function public.out_legacy_import(p_legacy jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare g jsonb; x jsonb; v_inv uuid; t public.out_items; k int; n int := 0; v_st text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for g in select * from jsonb_array_elements(coalesce(p_legacy, '[]')) loop
    v_st := g->>'status'; if v_st not in ('da_ky','da_nhap','xac_nhan_ky') then continue; end if;
    if exists(select 1 from jsonb_array_elements(g->'lines') e(v) join public.out_items oi on oi.ma_hang = e.v->>'ma_hang' and oi.part = coalesce((e.v->>'part')::int, 1)
              join public.out_invoice_lines l on l.item_id = oi.id) then continue; end if;
    select * into t from public.out_items where ma_hang = g->'lines'->0->>'ma_hang' and part = coalesce((g->'lines'->0->>'part')::int, 1);
    if t.id is null then continue; end if;
    insert into public.out_invoices(sale_id, customer_id, buyer_info, buyer_name, tax_code, address, email, status, so_hd, ngay_hd, legacy, note, status_at)
    values (t.sale_id, t.customer_id, g->>'info', coalesce(nullif(btrim(g->>'buyer_name'), ''), left(split_part(coalesce(g->>'info', ''), E'\n', 1), 200)),
      nullif(btrim(g->>'tax_code'), ''), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), v_st,
      case when v_st = 'da_ky' then nullif(g->>'so_hd', '') end, case when v_st = 'da_ky' then nullif(g->>'ngay','')::date end, true,
      case when v_st = 'da_ky' then 'Nhập từ sổ Excel cũ' else 'Sổ cũ: đã xuất nháp — sale kiểm tra, xác nhận ký' end, now())
    returning id into v_inv;
    if nullif(btrim(g->>'tax_code'), '') is not null and nullif(btrim(g->>'buyer_name'), '') is not null
       and not exists(select 1 from public.out_buyers where btrim(tax_code) = btrim(g->>'tax_code')) then
      insert into public.out_buyers(name, tax_code, address, email, note) values (btrim(g->>'buyer_name'), btrim(g->>'tax_code'), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), 'Từ sổ cũ');
    end if;
    k := 0;
    for x in select * from jsonb_array_elements(g->'lines') loop
      select * into t from public.out_items where ma_hang = x->>'ma_hang' and part = coalesce((x->>'part')::int, 1); k := k + 1;
      if t.id is not null and t.sl_nhap > 0 then
        insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values (v_inv, t.id, k, t.sl_nhap, coalesce(nullif((x->>'gia')::numeric, 0), t.gia_khach, 0), coalesce((x->>'vat')::numeric, t.vat));
      end if;
    end loop;
    if not exists(select 1 from public.out_invoice_lines where invoice_id = v_inv) then delete from public.out_invoices where id = v_inv; else n := n + 1; end if;
  end loop;
  return n;
end $$;

-- Chuyển dữ liệu đã nạp: dòng sổ cũ "đã xuất nháp / KD xác nhận ký" chưa có phiếu → tạo phiếu theo nhóm thông tin xuất HĐ
do $$
declare g record; v_inv uuid; k int; t record; v_name text;
begin
  for g in select legacy->>'status' st, coalesce(legacy->>'info', '') info, coalesce(legacy->>'so_hd_ra', '') sohd,
                  array_agg(id order by stt_so, ma_hang, part) ids
             from public.out_items oi
            where legacy->>'status' in ('da_nhap', 'xac_nhan_ky') and not exists(select 1 from public.out_invoice_lines l where l.item_id = oi.id)
            group by 1, 2, 3 loop
    select ln into v_name from unnest(string_to_array(g.info, E'\n')) ln
     where ln ~* '(CÔNG TY|CTY|HỘ KINH DOANH|HKD|DOANH NGHIỆP|CHI NHÁNH)' and ln !~* 'xuất giá' limit 1;
    insert into public.out_invoices(sale_id, customer_id, buyer_info, buyer_name, tax_code, email, status, legacy, note, status_at)
    select oi.sale_id, oi.customer_id, nullif(g.info, ''), coalesce(nullif(btrim(regexp_replace(regexp_replace(v_name, '^[^:]*:\s*', ''), '["“”]', '', 'g')), ''), left(split_part(g.info, E'\n', 1), 200)),
           substring(g.info from '(?:MST|Mã số thuế|mã số thuế|Tax code)[^0-9]*([0-9]{12}|[0-9]{10}(?:-[0-9]{3})?)'),
           substring(g.info from '([A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)'),
           g.st, true, 'Sổ cũ: đã xuất nháp — sale kiểm tra, xác nhận ký', now()
      from public.out_items oi where oi.id = g.ids[1] returning id into v_inv;
    k := 0;
    for t in select * from public.out_items where id = any(g.ids) order by stt_so, ma_hang, part loop
      k := k + 1;
      if t.sl_nhap > 0 then
        insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat)
        values (v_inv, t.id, k, t.sl_nhap, coalesce(nullif((t.legacy->>'dg_xuat')::numeric, 0), t.gia_khach, 0), t.vat);
      end if;
    end loop;
    if not exists(select 1 from public.out_invoice_lines where invoice_id = v_inv) then delete from public.out_invoices where id = v_inv; end if;
  end loop;
end $$;

reset search_path;
