-- =====================================================================
-- 0029 · Bản 22: Lập phiếu nhanh theo ID đơn + kho giá xuất đối chiếu nhiều nguồn
--  · out_prices: mọi giá xuất anh / kế toán / sale đưa vào (đối soát xe, sổ HĐ, file đơn hàng, phiếu, sale nhập) theo ID đơn
--  · Mỗi dòng sổ tự chọn giá khớp nhất: đúng dòng (HĐ XML / mã hàng) > đúng SL > tên hàng giống > nguồn tin cậy hơn;
--    đơn có nhiều giá mà không phân biệt được → để trống, sale chọn trong danh sách giá của đơn (không đoán bừa)
--  · Sale nhận dòng: giá nhập chỉ gán cho đúng dòng đó (trước gán cho cả đơn)
--  · File đơn hàng nhận thêm cột Tên hàng / SL / Đơn giá xuất; file đơn vị nhận HĐ nhận thêm cột Username → gắn khách
--  · Gợi ý đơn vị nhận HĐ theo khách cho lập phiếu hàng loạt; danh sách phiếu thêm ID đơn, sắp xếp, lọc việc tiếp theo
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 22');

alter table public.out_items add column if not exists gia_src text;
alter table public.out_items add column if not exists gia_n int;

create table if not exists public.out_prices(
  id bigint generated always as identity primary key,
  md text not null, ten text, sl numeric, gia numeric not null check (gia > 0),
  src text not null check (src in ('doi_soat','so','don_hang','phieu','sale')), src_ref text, note text,
  at timestamptz not null default now(), by_user uuid default auth.uid()
);
create index if not exists out_prices_md on public.out_prices(md);
create unique index if not exists out_prices_ref on public.out_prices(src, src_ref) where src_ref is not null;
alter table public.out_prices enable row level security;
drop policy if exists out_prices_read on public.out_prices;
create policy out_prices_read on public.out_prices for select to authenticated using (app.is_acc());
grant select on public.out_prices to authenticated;

create or replace function app.out_price_put(p_md text, p_ten text, p_sl numeric, p_gia numeric, p_src text, p_ref text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_ref is not null then delete from public.out_prices where src = p_src and src_ref = p_ref; end if;
  if p_md is null or coalesce(p_gia, 0) <= 0 then return; end if;
  insert into public.out_prices(md, ten, sl, gia, src, src_ref) values (p_md, nullif(btrim(p_ten), ''), p_sl, p_gia, p_src, p_ref);
end $$;

-- Chọn giá khớp nhất cho 1 dòng sổ
create or replace function app.out_item_price(p_id uuid) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare t public.out_items; b record; n int;
begin
  select * into t from public.out_items where id = p_id;
  if t.id is null or t.md is null then return; end if;
  select count(distinct gia) into n from public.out_prices where md = t.md;
  if t.gia_src = 'sale' and t.gia_khach is not null then
    update public.out_items set gia_n = n where id = t.id and gia_n is distinct from n; return;
  end if;
  select p.gia, p.src,
         (case when (p.src = 'doi_soat' and t.acc_line_id is not null and p.src_ref = t.acc_line_id::text and t.match_src = 'hd_xml')
                 or (p.src = 'so' and p.src_ref = t.ma_hang || '#' || t.part) or (p.src in ('phieu','sale') and p.src_ref = t.id::text) then 100 else 0 end
          + case when p.sl is not null and abs(p.sl - t.sl_nhap) < 0.001 then 30 else 0 end
          + coalesce(similarity(lower(p.ten), lower(t.ten)), 0) * 50
          + case p.src when 'sale' then 8 when 'phieu' then 7 when 'doi_soat' then 6 when 'so' then 5 else 4 end) sc
    into b from public.out_prices p where p.md = t.md order by 3 desc, p.at desc limit 1;
  if b.gia is null then update public.out_items set gia_n = 0 where id = t.id and gia_n is distinct from 0; return; end if;
  if n > 1 and b.sc < 20 then
    -- đơn có nhiều giá, không biết dòng này giá nào → để sale chọn
    update public.out_items set gia_n = n, gia_khach = case when gia_src in ('phieu') then gia_khach end, gia_src = case when gia_src in ('phieu') then gia_src end where id = t.id;
    return;
  end if;
  update public.out_items set gia_khach = b.gia, gia_src = b.src, gia_n = n
   where id = t.id and (gia_khach is distinct from b.gia or gia_src is distinct from b.src or gia_n is distinct from n);
end $$;

create or replace function app.out_md_reprice(p_md text) returns void language plpgsql security definer set search_path = public, app as $$
declare t record;
begin
  if p_md is null then return; end if;
  for t in select id from public.out_items where md = p_md loop perform app.out_item_price(t.id); end loop;
end $$;

-- Đối soát xe: mỗi dòng có giá khách → 1 giá trong kho
create or replace function app.trg_acc_line_price() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'UPDATE' and old.md is distinct from new.md then perform app.out_price_put(null, null, null, null, 'doi_soat', new.id::text); perform app.out_md_reprice(old.md); end if;
  if new.is_test then return null; end if;
  perform app.out_price_put(new.md, coalesce(new.ten_ht, new.ten_apt), coalesce(new.sl_ht, new.sl_apt), coalesce(nullif(new.gia_khach, 0), new.claim_gia), 'doi_soat', new.id::text);
  perform app.out_md_reprice(new.md);
  return null;
end $$;
drop trigger if exists acc_line_price on public.acc_lines;
create trigger acc_line_price after insert or update of md, gia_khach, claim_gia, ten_ht, sl_ht on public.acc_lines for each row execute function app.trg_acc_line_price();

-- Sổ HĐ: cột Đơn giá xuất → 1 giá trong kho; đổi mã đơn → chọn lại giá
create or replace function app.trg_out_item_price() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  perform app.out_price_put(new.md, new.ten, new.sl_nhap, new.gia_so, 'so', new.ma_hang || '#' || new.part);
  if tg_op = 'UPDATE' and old.md is distinct from new.md then perform app.out_md_reprice(old.md); end if;
  perform app.out_md_reprice(new.md);
  return null;
end $$;
drop trigger if exists out_item_price on public.out_items;
create trigger out_item_price after insert or update of gia_so, md on public.out_items for each row execute function app.trg_out_item_price();

-- Phiếu: đơn giá sale chốt → 1 giá trong kho (dòng chưa có giá thì nhận luôn)
create or replace function app.trg_out_line_price() returns trigger language plpgsql security definer set search_path = public, app as $$
declare t public.out_items;
begin
  select * into t from public.out_items where id = new.item_id;
  if t.md is null or coalesce(new.don_gia, 0) <= 0 then return null; end if;
  perform app.out_price_put(t.md, t.ten, t.sl_nhap, new.don_gia, 'phieu', t.id::text);
  update public.out_items set gia_khach = new.don_gia, gia_src = 'phieu' where id = t.id and gia_khach is null;
  perform app.out_md_reprice(t.md);
  return null;
end $$;
drop trigger if exists out_line_price on public.out_invoice_lines;
create trigger out_line_price after insert or update of don_gia on public.out_invoice_lines for each row execute function app.trg_out_line_price();

-- Sale nhận dòng: giá chỉ gán cho đúng dòng sale bấm
drop function if exists public.out_item_claim(uuid, text, text, numeric);
create or replace function public.out_item_claim(p_id uuid, p_md text, p_username text default null, p_gia numeric default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; v_md text := app.out_md_norm(p_md); n int := 0; x record;
begin
  if not app.has_role('sale','tn_kd','tp_kd') and not app.is_acc() then raise exception 'Chỉ sale được nhận dòng'; end if;
  select * into t from public.out_items where id = p_id for update; if t.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if t.sale_id is not null and not app.is_acc() then raise exception 'Dòng đã có sale — báo kế toán nếu nhầm'; end if;
  if v_md is null then raise exception 'Nhập mã đơn (MD)'; end if;
  for x in select id from public.out_items where id = p_id or (md = v_md and sale_id is null) loop
    update public.out_items set md = v_md, sale_id = auth.uid(), username = coalesce(nullif(btrim(p_username), ''), username),
      match_src = 'tay', updated_at = now(), updated_by = auth.uid() where id = x.id;
    if x.id = p_id and coalesce(p_gia, 0) > 0 then
      update public.out_items set gia_khach = p_gia, gia_src = 'sale' where id = x.id;
      perform app.out_price_put(v_md, t.ten, t.sl_nhap, p_gia, 'sale', x.id::text);
    end if;
    perform app.out_item_match(x.id);
    insert into public.out_events(item_id, action, data) values (x.id, 'item_claim', jsonb_build_object('md', v_md, 'username', p_username, 'gia', case when x.id = p_id then p_gia end));
    n := n + 1;
  end loop;
  perform app.out_md_reprice(v_md);
  return n;
end $$;
grant execute on function public.out_item_claim(uuid, text, text, numeric) to authenticated;

-- Sale đặt giá xuất cho 1 dòng (chọn trong danh sách giá của đơn, hoặc gõ)
create or replace function public.out_item_set_price(p_id uuid, p_gia numeric) returns void
language plpgsql security definer set search_path = public, app as $$
declare t public.out_items;
begin
  select * into t from public.out_items where id = p_id;
  if t.id is null or not (app.is_acc() or app.in_tree(t.sale_id)) then raise exception 'Không có quyền'; end if;
  if coalesce(p_gia, 0) <= 0 then raise exception 'Giá phải > 0'; end if;
  update public.out_items set gia_khach = p_gia, gia_src = 'sale', updated_at = now(), updated_by = auth.uid() where id = p_id;
  perform app.out_price_put(t.md, t.ten, t.sl_nhap, p_gia, 'sale', t.id::text);
  perform app.out_md_reprice(t.md);
end $$;
grant execute on function public.out_item_set_price(uuid, numeric) to authenticated;

-- Các giá đã biết của đơn (để sale chọn), xếp theo độ khớp với dòng
create or replace function public.out_item_prices(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, extensions as $$
declare t public.out_items;
begin
  select * into t from public.out_items where id = p_id;
  if t.id is null or not (app.is_acc() or app.in_tree(t.sale_id) or t.sale_id is null) then raise exception 'Không có quyền'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('gia', gia, 'ten', ten, 'sl', sl, 'src', src, 'at', at) order by sc desc), '[]') from (
    select distinct on (p.gia, coalesce(p.ten, '')) p.*, coalesce(similarity(lower(p.ten), lower(t.ten)), 0) + case when p.sl is not null and abs(p.sl - t.sl_nhap) < 0.001 then 0.6 else 0 end sc
      from public.out_prices p where p.md = t.md order by p.gia, coalesce(p.ten, ''), p.at desc) z);
end $$;
grant execute on function public.out_item_prices(uuid) to authenticated;

-- File đơn hàng: thêm Tên hàng / SL / Đơn giá xuất (tùy chọn) → kho giá
create or replace function public.out_orders_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; r jsonb; t record; v_md text; v_mds text[] := '{}'; k int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  -- giá theo đơn: thay cả bộ giá của đơn trong file mới
  delete from public.out_prices where src = 'don_hang' and md in (
    select case when e->>'md' ~* 'md' then app.norm_md(e->>'md') else nullif(btrim(e->>'md'), '') end from jsonb_array_elements(p_rows) e where coalesce((e->>'gia')::numeric, 0) > 0);
  for r in select * from jsonb_array_elements(p_rows) loop
    k := k + 1;
    v_md := case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end; if v_md is null then continue; end if;
    if nullif(btrim(r->>'username'), '') is not null or nullif(btrim(r->>'nvkd'), '') is not null then
      insert into public.out_orders(md, username, nvkd) values (v_md, nullif(btrim(r->>'username'), ''), nullif(btrim(r->>'nvkd'), ''))
      on conflict (md) do update set username = coalesce(excluded.username, out_orders.username), nvkd = coalesce(excluded.nvkd, out_orders.nvkd), updated_at = now();
    end if;
    if coalesce((r->>'gia')::numeric, 0) > 0 then
      insert into public.out_prices(md, ten, sl, gia, src) values (v_md, nullif(btrim(r->>'ten'), ''), nullif(r->>'sl', '')::numeric, (r->>'gia')::numeric, 'don_hang');
    end if;
    if not v_md = any(v_mds) then v_mds := v_mds || v_md; end if;
  end loop;
  for t in select id from public.out_items where md = any(v_mds) loop
    perform app.out_item_match(t.id); perform app.out_item_price(t.id); n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_orders_import(jsonb) to authenticated;

-- File đơn vị nhận HĐ: thêm cột Username → gắn đơn vị cho đúng khách
create or replace function public.out_buyers_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n int := 0; v_id uuid; v_mst text; v_c uuid;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), ''); if v_mst is null or coalesce(btrim(r->>'name'), '') = '' then continue; end if;
    v_c := null;
    if nullif(btrim(r->>'username'), '') is not null then
      select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(btrim(r->>'username')) or upper(btrim(sys_code)) = upper(btrim(r->>'username'))) limit 1;
    end if;
    select id into v_id from public.out_buyers where customer_id is not distinct from v_c and btrim(tax_code) = v_mst limit 1;
    if v_id is null then
      insert into public.out_buyers(customer_id, name, tax_code, address, email, note) values (v_c, btrim(r->>'name'), v_mst, nullif(btrim(r->>'address'), ''), nullif(btrim(r->>'email'), ''), 'Danh sách kế toán')
      on conflict do nothing;
    else
      update public.out_buyers set name = btrim(r->>'name'), address = coalesce(nullif(btrim(r->>'address'), ''), address), email = coalesce(nullif(btrim(r->>'email'), ''), email) where id = v_id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_buyers_import(jsonb) to authenticated;

-- Gợi ý đơn vị nhận HĐ cho nhiều khách 1 lần (lập phiếu hàng loạt): phiếu gần nhất → danh sách đơn vị → hồ sơ khách
create or replace function public.out_buyer_suggest(p_customers uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare c record; out jsonb := '{}'; v jsonb;
begin
  for c in select * from public.customers where id = any(p_customers) and deleted_at is null and (app.is_acc() or app.in_tree(owner_id)) loop
    select jsonb_build_object('name', buyer_name, 'tax_code', tax_code, 'address', address, 'email', email, 'payment', payment, 'src', 'phiếu ' || code) into v
      from public.out_invoices where customer_id = c.id and status <> 'huy' and coalesce(btrim(buyer_name), '') <> '' order by created_at desc limit 1;
    if v is null then
      select jsonb_build_object('name', name, 'tax_code', tax_code, 'address', address, 'email', email, 'src', 'danh sách đơn vị') into v
        from public.out_buyers where customer_id = c.id order by created_at desc limit 1;
    end if;
    if v is null and coalesce(btrim(coalesce(c.company_name, '')), '') <> '' then
      v := jsonb_build_object('name', c.company_name, 'tax_code', c.tax_code, 'address', coalesce(c.legal_address, c.address), 'email', c.email, 'src', 'hồ sơ khách');
    end if;
    if v is null then v := jsonb_build_object('name', coalesce(c.contact_name, ''), 'tax_code', c.tax_code, 'address', coalesce(c.legal_address, c.address), 'email', c.email, 'src', 'tên liên hệ', 'weak', true); end if;
    out := out || jsonb_build_object(c.id::text, v); v := null;
  end loop;
  return out;
end $$;
grant execute on function public.out_buyer_suggest(uuid[]) to authenticated;

-- Danh sách dòng: sắp theo ID đơn / khách, lọc đơn nhiều giá, lọc 1 ID đơn
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
            or (v_f = 'nhieu_gia' and t.gia_n > 1 and t.gia_khach is null and t.ton > 0.0001))
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
  b as (select s.id, s.sale_id, s.md, s.customer_id, s.username, s.gia_khach, s.gia_n, s.dg_nhap, s.so_hd_vao, s.sl_nhap - coalesce(a.sl, 0) ton,
               x.xe, coalesce(c.company_name, c.contact_name) khach
          from s left join a on a.item_id = s.id left join public.out_hd_xe x on x.so_hd = ltrim(s.so_hd_vao, '0') left join public.customers c on c.id = s.customer_id),
  v as (select * from b where p_mode = 'acc' or ton > 0.0001)
  select jsonb_build_object(
    'all', count(*), 'ton', count(*) filter (where ton > 0.0001), 'het', count(*) filter (where ton <= 0.0001),
    'nosale', count(*) filter (where sale_id is null and ton > 0.0001), 'daky_nosale', count(*) filter (where sale_id is null and ton <= 0.0001),
    'nomd', count(*) filter (where md is null), 'nogia', count(*) filter (where gia_khach is null and ton > 0.0001),
    'nokhach', count(*) filter (where customer_id is null and username is null),
    'nhieu_gia', count(*) filter (where gia_n > 1 and gia_khach is null and ton > 0.0001),
    'gia_tri', coalesce(sum(ton * coalesce(gia_khach, dg_nhap, 0)) filter (where ton > 0.0001), 0),
    'hd', coalesce((select jsonb_agg(distinct so_hd_vao) from v where so_hd_vao is not null), '[]'),
    'xe', coalesce((select jsonb_agg(distinct coalesce(xe, '—')) from v), '[]'),
    'kh', coalesce((select jsonb_agg(jsonb_build_array(k, t) order by t) from (select distinct coalesce(customer_id::text, username) k, coalesce(khach, username) t from v where coalesce(customer_id::text, username) is not null) z), '[]'),
    'sale', coalesce((select jsonb_agg(distinct coalesce(sale_id::text, '—')) from v), '[]'))
  into r from v;
  return r;
end $$;
grant execute on function public.out_items_stats(text) to authenticated;

-- Danh sách phiếu: ID đơn, sắp xếp theo cột, lọc việc tiếp theo
create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_flag text := nullif(p->>'flag', ''); v_next text := nullif(p->>'next', ''); v_sort text := coalesce(nullif(p->>'sort', ''), 'at'); v_dir text := coalesce(nullif(p->>'dir', ''), 'desc'); v_sua int; v_misa int; v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree();
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  select count(*) filter (where i.sua_sau_nhap), count(*) filter (where i.misa_at is null) into v_sua, v_misa from public.out_invoices i
   where i.status = 'cho_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale);
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)
                               and (v_flag is null or v_flag = 'sua' and v.sua_sau_nhap or v_flag = 'misa_chua' and v.misa_at is null)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim,
               string_agg(distinct t.md, ', ') mds, bool_or(coalesce(l.vat, t.vat) >= 0.095) vat10
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia, a.mds, coalesce(a.vat10, false) vat10,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where (v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%')
           and (v_next is null or b.status = 'da_nhap' and fn.version is not null and (v_next = 'chua_gui' and fn.sent_at is null or v_next = 'cho_khach' and fn.sent_at is not null))),
  o as (select f.*, row_number() over (order by
          case when v_dir = 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end asc nulls last,
          case when v_dir <> 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end desc nulls last,
          case when v_sort = 'tien' and v_dir = 'asc' then f.tien_hang + f.tien_thue end asc nulls last,
          case when v_sort = 'tien' and v_dir <> 'asc' then f.tien_hang + f.tien_thue end desc nulls last,
          case when v_dir = 'asc' and v_sort = 'at' then f.status_at end asc, f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

-- Gắn đơn / sale / khách: giá giao cho kho giá
create or replace function app.out_item_match(p_id uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; al public.acc_lines; v_c uuid; v_owner uuid; v_src text; o public.out_orders; s_sale uuid; s_user text;
begin
  select * into t from public.out_items where id = p_id;
  if t.stt_hd is not null and t.so_hd_vao is not null then
    select l.* into al from public.acc_invoice_lines il join public.acc_invoices i on i.id = il.invoice_id join public.acc_lines l on l.id = il.line_id
     where ltrim(i.so_hd, '0') = ltrim(t.so_hd_vao, '0') and (t.ky_hieu is null or right(i.ky_hieu, 6) = right(t.ky_hieu, 6)) and il.stt = t.stt_hd limit 1;
    if al.id is not null then v_src := 'hd_xml'; end if;
  end if;
  if al.id is null and t.md is not null then
    select * into al from public.acc_lines where md = t.md and not is_test order by (sl_apt = t.sl_nhap) desc nulls last, updated_at desc limit 1;
    if al.id is not null then v_src := 'md'; end if;
  end if;
  if t.md is not null then select * into o from public.out_orders where md = t.md; end if;
  -- cùng mã đơn ở dòng khác của sổ đã biết sale / khách → dùng chung
  if t.md is not null and (t.sale_id is null or t.username is null) then
    select sale_id, username into s_sale, s_user from public.out_items where md = t.md and id <> t.id and (sale_id is not null or username is not null)
     order by (sale_id is not null) desc, (username is not null) desc limit 1;
  end if;
  t.username := coalesce(t.username, o.username, s_user);
  if t.username is not null then
    select id, owner_id into v_c, v_owner from public.customers where deleted_at is null
      and (lower(btrim(sys_username)) = lower(btrim(t.username)) or upper(btrim(sys_code)) = upper(btrim(t.username))) limit 1;
  end if;
  update public.out_items set acc_line_id = coalesce(acc_line_id, al.id),
    md = coalesce(md, al.md), username = t.username, nvkd = coalesce(nvkd, o.nvkd),
    -- giá: chỉ lấy thẳng khi khớp đúng dòng HĐ XML; còn lại để kho giá chọn (app.out_item_price)
    gia_khach = case when v_src = 'hd_xml' and gia_src is distinct from 'sale' then coalesce(nullif(al.gia_khach, 0), al.claim_gia, gia_khach) else gia_khach end,
    gia_src = case when v_src = 'hd_xml' and gia_src is distinct from 'sale' and coalesce(nullif(al.gia_khach, 0), al.claim_gia) is not null then 'doi_soat' else gia_src end,
    sale_id = coalesce(sale_id, al.sale_id, app.match_sale(t.nvkd), app.match_sale(o.nvkd), s_sale, v_owner),
    customer_id = coalesce(customer_id, al.customer_id, v_c),
    match_src = coalesce(match_src, v_src, case when t.nvkd is not null then 'nvkd' when o.md is not null then 'don_hang' when v_owner is not null then 'user' end)
  where id = p_id;
  perform app.out_item_price(p_id);
end $$;

-- Đổ kho giá từ dữ liệu đã có, rồi chọn lại giá cho mọi dòng
insert into public.out_prices(md, ten, sl, gia, src, src_ref)
select md, coalesce(ten_ht, ten_apt), coalesce(sl_ht, sl_apt), coalesce(nullif(gia_khach, 0), claim_gia), 'doi_soat', id::text
  from public.acc_lines where md is not null and not is_test and coalesce(nullif(gia_khach, 0), claim_gia) > 0
on conflict do nothing;
insert into public.out_prices(md, ten, sl, gia, src, src_ref)
select md, ten, sl_nhap, gia_so, 'so', ma_hang || '#' || part from public.out_items where md is not null and coalesce(gia_so, 0) > 0
on conflict do nothing;
insert into public.out_prices(md, ten, sl, gia, src, src_ref)
select distinct on (t.id) t.md, t.ten, t.sl_nhap, l.don_gia, 'phieu', t.id::text
  from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id join public.out_items t on t.id = l.item_id
 where i.status <> 'huy' and t.md is not null and l.don_gia > 0 order by t.id, i.created_at desc
on conflict do nothing;
update public.out_items set gia_src = 'sale' where match_src = 'tay' and gia_khach is not null and gia_src is null;
do $$ declare t record; begin for t in select id from public.out_items where md is not null loop perform app.out_item_price(t.id); end loop; end $$;

reset search_path;
