-- Bản 51b — dòng HĐ tồn (match_src = 'ton') không tính là "chưa ghép nháp"
--  · Lỗi: dòng HĐ tồn cố ý không ghép nháp APT (acc_line_id trống) nên rơi vào khu "Dòng HĐ cần kế toán xử lý" + đếm "Dòng HĐ chưa ghép nháp"
--  · Sửa: bộ lọc / đếm 'chua_ghep' loại dòng tồn. Dòng tồn vẫn hiện bình thường ở Sẵn sàng xuất của sale.

create or replace function public.out_items_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_mode text := coalesce(p->>'mode', 'acc'); v_f text := nullif(p->>'f', ''); v_q text := nullif(btrim(p->>'q'), '');
        v_hd text := nullif(p->>'hd', ''); v_xe text := nullif(p->>'xe', ''); v_sale text := nullif(p->>'sale', ''); v_kh text := nullif(p->>'kh', ''); v_sort text := coalesce(nullif(p->>'sort', ''), 'moi'); v_md text := nullif(p->>'md', '');
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
            or (v_f = 'nokhach' and t.customer_id is null and t.username is null)
            or (v_f = 'nhieu_gia' and t.gia_n > 1 and t.gia_khach is null and t.ton > 0.0001)
            or (v_f = 'lech' and t.lech and t.lech_ok_at is null) or (v_f = 'chua_ghep' and t.acc_line_id is null and t.ton > 0.0001 and t.match_src is distinct from 'ton'))
       and (v_md is null or t.md = v_md)
       and (v_hd is null or t.so_hd_vao = v_hd) and (v_xe is null or coalesce(t.xe, '—') = v_xe)
       and (v_sale is null or coalesce(t.sale_id::text, '—') = v_sale)
       and (v_kh is null or coalesce(t.customer_id::text, t.username, '—') = v_kh)
       and (v_q is null or concat_ws(' ', t.ma_hang, t.ten, t.md, t.nvkd, t.username, t.khach, t.so_hd_vao, t.xe) ilike '%' || v_q || '%')),
  o as (select f.*, row_number() over (order by
          case when v_sort = 'md' then f.md end asc nulls last, case when v_sort = 'kh' then lower(coalesce(f.khach, f.username)) end asc nulls last,
          case when v_sort in ('md', 'kh') then f.md end asc nulls last, f.stt_so desc nulls last, f.ma_hang, f.part) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r);
end $$;
grant execute on function public.out_items_page(jsonb) to authenticated;

create or replace function public.out_items_stats(p_mode text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb;
begin
  with s as (select * from app.out_items_scope(p_mode)),
  a as (select l.item_id, sum(l.sl) sl from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id
         where i.status <> 'huy' and l.item_id in (select id from s) group by l.item_id),
  b as (select s.id, s.sale_id, s.md, s.customer_id, s.username, s.gia_khach, s.gia_n, s.dg_nhap, s.so_hd_vao, s.sl_nhap - coalesce(a.sl, 0) ton, s.lech, s.lech_ok_at, s.acc_line_id, s.match_src,
               x.xe, coalesce(c.company_name, c.contact_name) khach
          from s left join a on a.item_id = s.id left join public.out_hd_xe x on x.so_hd = ltrim(s.so_hd_vao, '0') left join public.customers c on c.id = s.customer_id),
  v as (select * from b where p_mode = 'acc' or ton > 0.0001)
  select jsonb_build_object(
    'all', count(*), 'ton', count(*) filter (where ton > 0.0001), 'het', count(*) filter (where ton <= 0.0001),
    'nosale', count(*) filter (where sale_id is null and ton > 0.0001), 'daky_nosale', count(*) filter (where sale_id is null and ton <= 0.0001),
    'nomd', count(*) filter (where md is null), 'nogia', count(*) filter (where gia_khach is null and ton > 0.0001),
    'nokhach', count(*) filter (where customer_id is null and username is null),
    'nhieu_gia', count(*) filter (where gia_n > 1 and gia_khach is null and ton > 0.0001),
    'lech', count(*) filter (where lech and lech_ok_at is null), 'chua_ghep', count(*) filter (where acc_line_id is null and ton > 0.0001 and match_src is distinct from 'ton'),
    'gia_tri', coalesce(sum(ton * coalesce(gia_khach, dg_nhap, 0)) filter (where ton > 0.0001), 0),
    'hd', coalesce((select jsonb_agg(distinct so_hd_vao) from v where so_hd_vao is not null), '[]'),
    'xe', coalesce((select jsonb_agg(distinct coalesce(xe, '—')) from v), '[]'),
    'kh', coalesce((select jsonb_agg(jsonb_build_array(k, t) order by t) from (select distinct coalesce(customer_id::text, username) k, coalesce(khach, username) t from v where coalesce(customer_id::text, username) is not null) z), '[]'),
    'sale', coalesce((select jsonb_agg(distinct coalesce(sale_id::text, '—')) from v), '[]'))
  into r from v;
  return r;
end $$;
grant execute on function public.out_items_stats(text) to authenticated;
