-- =====================================================================
-- 0024 · Bản 17: Xuất HĐ đầu ra
--  · 1 mã hàng chia nhiều dòng trên sổ (nhiều khách) → tách thành nhiều phần, không gộp
--  · Sổ cũ: chỉ dòng "Đã ký" mới hết tồn (vào phiếu Đã ký của sale); nháp vẫn còn tồn
--  · Giá xuất khách: lấy theo đối soát, không có thì theo sổ (cột Đơn giá xuất)
--  · Lưu file đơn hàng (mã đơn → khách, sale) để dùng mãi; MD đã biết sale/khách ở dòng khác thì dùng chung
--  · HĐ vào ↔ xe (tự theo XML, kế toán sửa được); xem nhanh hơn
--  · Sale nhận dòng: nhập MD (+ username, giá xuất khách nếu hệ thống chưa có)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 17');

-- ---------- Bảng / cột mới ----------
alter table public.out_items add column if not exists part int not null default 1;
alter table public.out_items add column if not exists gia_so numeric;
alter table public.out_items drop constraint if exists out_items_ma_hang_key;
create unique index if not exists out_items_ma_part on public.out_items(ma_hang, part);

create table if not exists public.out_orders(
  md text primary key, username text, nvkd text, updated_at timestamptz not null default now()
);
alter table public.out_orders enable row level security;
drop policy if exists out_orders_read on public.out_orders;
create policy out_orders_read on public.out_orders for select to authenticated using (true);
grant select on public.out_orders to authenticated;

create table if not exists public.out_hd_xe(
  so_hd text primary key, xe text not null, tu_dong boolean not null default false, updated_at timestamptz not null default now(), updated_by uuid default auth.uid()
);
alter table public.out_hd_xe enable row level security;
drop policy if exists out_hd_xe_read on public.out_hd_xe;
create policy out_hd_xe_read on public.out_hd_xe for select to authenticated using (true);
grant select on public.out_hd_xe to authenticated;

-- ---------- Gắn đơn / sale / khách / giá ----------
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
    gia_khach = coalesce(nullif(al.gia_khach, 0), al.claim_gia, gia_khach, gia_so),
    sale_id = coalesce(sale_id, al.sale_id, app.match_sale(t.nvkd), app.match_sale(o.nvkd), s_sale, v_owner),
    customer_id = coalesce(customer_id, al.customer_id, v_c),
    match_src = coalesce(match_src, v_src, case when t.nvkd is not null then 'nvkd' when o.md is not null then 'don_hang' when v_owner is not null then 'user' end)
  where id = p_id;
end $$;

-- ---------- Nạp sổ ----------
drop function if exists public.out_items_import(jsonb, jsonb);
create or replace function public.out_items_import(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_id uuid; n_new int := 0; n_upd int := 0; v_ids uuid[] := '{}';
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select id into v_id from public.out_items where ma_hang = r->>'ma_hang' and part = coalesce((r->>'part')::int, 1);
    if v_id is null then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
    insert into public.out_items as t(ma_hang, part, stt_so, ten, dvt, vat, sl_nhap, dg_nhap, so_hd_vao, ky_hieu, ngay_vao, ncc, stt_hd, md, nvkd, username, gia_so, legacy, updated_at, updated_by)
    values (r->>'ma_hang', coalesce((r->>'part')::int, 1), (r->>'stt_so')::numeric, r->>'ten', r->>'dvt', (r->>'vat')::numeric, coalesce((r->>'sl_nhap')::numeric, 0), (r->>'dg_nhap')::numeric,
            r->>'so_hd_vao', r->>'ky_hieu', nullif(r->>'ngay_vao','')::date, r->>'ncc', (r->>'stt_hd')::int,
            case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end, nullif(btrim(r->>'nvkd'), ''), nullif(btrim(r->>'username'), ''),
            nullif((r->>'gia_so')::numeric, 0), r->'legacy', now(), auth.uid())
    on conflict (ma_hang, part) do update set stt_so = excluded.stt_so, ten = excluded.ten, dvt = excluded.dvt, vat = excluded.vat, sl_nhap = excluded.sl_nhap, dg_nhap = excluded.dg_nhap,
      so_hd_vao = excluded.so_hd_vao, ky_hieu = excluded.ky_hieu, ngay_vao = excluded.ngay_vao, ncc = excluded.ncc, stt_hd = excluded.stt_hd,
      md = case when coalesce(t.match_src, '') = 'tay' then t.md else coalesce(excluded.md, t.md) end, nvkd = coalesce(excluded.nvkd, t.nvkd),
      username = case when coalesce(t.match_src, '') = 'tay' then t.username else coalesce(excluded.username, t.username) end,
      sale_id = case when coalesce(t.match_src, '') <> 'tay' and excluded.nvkd is not null and app.match_sale(excluded.nvkd) is not null then app.match_sale(excluded.nvkd) else t.sale_id end,
      gia_so = coalesce(excluded.gia_so, t.gia_so), legacy = excluded.legacy, updated_at = now(), updated_by = auth.uid()
    returning id into v_id;
    perform app.out_item_match(v_id); v_ids := v_ids || v_id;
  end loop;
  -- lượt 2: dòng cùng mã đơn nằm sau trong file đã có sale/khách → dùng chung
  for v_id in select id from public.out_items where id = any(v_ids) and md is not null and (sale_id is null or username is null) loop perform app.out_item_match(v_id); end loop;
  insert into public.out_events(action, data) values ('import', jsonb_build_object('new', n_new, 'upd', n_upd));
  return jsonb_build_object('new', n_new, 'upd', n_upd);
end $$;
grant execute on function public.out_items_import(jsonb) to authenticated;

-- Dòng đã ký trên sổ cũ → phiếu "Đã ký" của sale, hết tồn. Gọi theo từng nhóm nhỏ.
create or replace function public.out_legacy_import(p_legacy jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare g jsonb; x jsonb; v_inv uuid; t public.out_items; k int; n int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for g in select * from jsonb_array_elements(coalesce(p_legacy, '[]')) loop
    if g->>'status' <> 'da_ky' then continue; end if;
    if exists(select 1 from jsonb_array_elements(g->'lines') e(v) join public.out_items oi on oi.ma_hang = e.v->>'ma_hang' and oi.part = coalesce((e.v->>'part')::int, 1)
              join public.out_invoice_lines l on l.item_id = oi.id) then continue; end if;
    select * into t from public.out_items where ma_hang = g->'lines'->0->>'ma_hang' and part = coalesce((g->'lines'->0->>'part')::int, 1);
    if t.id is null then continue; end if;
    insert into public.out_invoices(sale_id, customer_id, buyer_info, buyer_name, tax_code, address, email, status, so_hd, ngay_hd, legacy, note, status_at)
    values (t.sale_id, t.customer_id, g->>'info', coalesce(nullif(btrim(g->>'buyer_name'), ''), left(split_part(coalesce(g->>'info', ''), E'\n', 1), 200)),
      nullif(btrim(g->>'tax_code'), ''), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), 'da_ky', nullif(g->>'so_hd', ''), nullif(g->>'ngay','')::date, true, 'Nhập từ sổ Excel cũ', now())
    returning id into v_inv;
    if nullif(btrim(g->>'tax_code'), '') is not null and nullif(btrim(g->>'buyer_name'), '') is not null
       and not exists(select 1 from public.out_buyers where btrim(tax_code) = btrim(g->>'tax_code')) then
      insert into public.out_buyers(name, tax_code, address, email, note) values (btrim(g->>'buyer_name'), btrim(g->>'tax_code'), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), 'Từ sổ cũ');
    end if;
    k := 0;
    for x in select * from jsonb_array_elements(g->'lines') loop
      select * into t from public.out_items where ma_hang = x->>'ma_hang' and part = coalesce((x->>'part')::int, 1); k := k + 1;
      -- đã ký = xuất hết phần của dòng đó
      if t.id is not null and t.sl_nhap > 0 then
        insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values (v_inv, t.id, k, t.sl_nhap, coalesce(nullif((x->>'gia')::numeric, 0), t.gia_khach, 0), coalesce((x->>'vat')::numeric, t.vat));
      end if;
    end loop;
    if not exists(select 1 from public.out_invoice_lines where invoice_id = v_inv) then delete from public.out_invoices where id = v_inv; else n := n + 1; end if;
  end loop;
  return n;
end $$;
grant execute on function public.out_legacy_import(jsonb) to authenticated;

-- File đơn hàng: lưu lại (mã đơn → khách, sale) rồi gắn cho các dòng
drop function if exists public.out_orders_import(jsonb);
create or replace function public.out_orders_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; r jsonb; t record; v_md text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_md := case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end; if v_md is null then continue; end if;
    insert into public.out_orders(md, username, nvkd) values (v_md, nullif(btrim(r->>'username'), ''), nullif(btrim(r->>'nvkd'), ''))
    on conflict (md) do update set username = coalesce(excluded.username, out_orders.username), nvkd = coalesce(excluded.nvkd, out_orders.nvkd), updated_at = now();
    for t in select id from public.out_items where md = v_md and (sale_id is null or username is null or customer_id is null) loop
      perform app.out_item_match(t.id); n := n + 1;
    end loop;
  end loop;
  return n;
end $$;
grant execute on function public.out_orders_import(jsonb) to authenticated;

-- Gắn lại toàn bộ dòng còn thiếu (sau khi ghép tên sale, thêm username khách…)
create or replace function public.out_rematch() returns int
language plpgsql security definer set search_path = public, app as $$
declare t record; n int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for t in select id, nvkd from public.out_items where (sale_id is null or customer_id is null or gia_khach is null) and coalesce(match_src, '') <> 'tay' loop
    update public.out_items set sale_id = coalesce(sale_id, app.match_sale(t.nvkd)) where id = t.id;
    perform app.out_item_match(t.id); n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_rematch() to authenticated;

-- Mã đơn sale gõ: "md 2943", "2943" → MD2943 nếu đơn đó có trong hệ thống; ID dạng số (Lanchi) giữ nguyên
create or replace function app.out_md_norm(p text) returns text language sql stable security definer set search_path = public, app as $$
  select case when coalesce(btrim(p), '') = '' then null
              when p ~* 'md' then app.norm_md(p)
              when btrim(p) ~ '^\d+$' and (exists(select 1 from public.out_orders where md = app.norm_md(p)) or exists(select 1 from public.out_items where md = app.norm_md(p))
                                          or exists(select 1 from public.acc_lines where md = app.norm_md(p))) then app.norm_md(p)
              else btrim(p) end
$$;

-- ---------- Sale tra mã đơn / nhận dòng ----------
create or replace function public.out_md_lookup(p_md text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_md text := app.out_md_norm(p_md); v_user text; v_gk numeric; v_kh text;
begin
  if v_md is null then return null; end if;
  select coalesce((select username from public.out_items where md = v_md and username is not null limit 1), (select username from public.out_orders where md = v_md)) into v_user;
  select coalesce((select nullif(gia_khach, 0) from public.acc_lines where md = v_md and not is_test order by updated_at desc limit 1),
                  (select gia_khach from public.out_items where md = v_md and gia_khach is not null limit 1)) into v_gk;
  if v_user is not null then select coalesce(company_name, contact_name) into v_kh from public.customers where deleted_at is null and lower(btrim(sys_username)) = lower(btrim(v_user)) limit 1; end if;
  return jsonb_build_object('md', v_md, 'username', v_user, 'khach', v_kh, 'gia_khach', v_gk);
end $$;
grant execute on function public.out_md_lookup(text) to authenticated;

-- Sale nhận dòng (và các dòng chưa có sale cùng mã đơn); kế toán gán cho sale
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
      gia_khach = coalesce(nullif(p_gia, 0), gia_khach), match_src = 'tay', updated_at = now(), updated_by = auth.uid() where id = x.id;
    perform app.out_item_match(x.id);
    insert into public.out_events(item_id, action, data) values (x.id, 'item_claim', jsonb_build_object('md', v_md, 'username', p_username, 'gia', p_gia));
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_item_claim(uuid, text, text, numeric) to authenticated;

-- ---------- HĐ vào ↔ xe ----------
create or replace function public.out_hd_xe_set(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(r->>'so_hd'), '') = '' then continue; end if;
    if coalesce(btrim(r->>'xe'), '') = '' then delete from public.out_hd_xe where so_hd = ltrim(btrim(r->>'so_hd'), '0');
    else insert into public.out_hd_xe(so_hd, xe, tu_dong) values (ltrim(btrim(r->>'so_hd'), '0'), btrim(r->>'xe'), false)
      on conflict (so_hd) do update set xe = excluded.xe, tu_dong = false, updated_at = now(), updated_by = auth.uid(); end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_hd_xe_set(jsonb) to authenticated;

-- Tự gắn xe khi dòng HĐ XML ghép được vào dòng đối soát (kế toán đã sửa tay thì giữ)
create or replace function app.trg_acc_invline_xe() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if new.line_id is null then return null; end if;
  insert into public.out_hd_xe(so_hd, xe, tu_dong)
  select ltrim(i.so_hd, '0'), tr.name, true from public.acc_invoices i, public.acc_lines l join public.acc_trucks tr on tr.id = l.truck_id
   where i.id = new.invoice_id and l.id = new.line_id and not tr.is_test
  on conflict (so_hd) do nothing;
  return null;
end $$;
drop trigger if exists acc_invline_xe on public.acc_invoice_lines;
create trigger acc_invline_xe after insert or update of line_id on public.acc_invoice_lines for each row execute function app.trg_acc_invline_xe();
insert into public.out_hd_xe(so_hd, xe, tu_dong)
select distinct on (ltrim(i.so_hd, '0')) ltrim(i.so_hd, '0'), tr.name, true
  from public.acc_invoice_lines il join public.acc_invoices i on i.id = il.invoice_id join public.acc_lines l on l.id = il.line_id join public.acc_trucks tr on tr.id = l.truck_id
 where not tr.is_test order by ltrim(i.so_hd, '0'), tr.created_at
on conflict (so_hd) do nothing;

-- ---------- View nhanh (1 lần gộp, không gọi hàm từng dòng) ----------
drop view if exists public.out_items_v;
create view public.out_items_v with (security_invoker = true) as
  select t.*, coalesce(u.sl, 0) as sl_xuat, t.sl_nhap - coalesce(u.sl, 0) as ton, u.phieu,
    coalesce(c.company_name, c.contact_name) as khach, x.xe
  from public.out_items t
  left join (select l.item_id, sum(l.sl) sl, string_agg(i.code || ':' || i.status, ',' order by i.code) phieu
               from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id where i.status <> 'huy' group by l.item_id) u on u.item_id = t.id
  left join public.customers c on c.id = t.customer_id
  left join public.out_hd_xe x on x.so_hd = ltrim(t.so_hd_vao, '0');
grant select on public.out_items_v to authenticated;

-- ---------- Dọn dữ liệu đã nạp ----------
-- Phiếu sổ cũ: chỉ giữ phiếu Đã ký, dòng đã ký trừ hết tồn
delete from public.out_invoices where legacy and status <> 'da_ky';
update public.out_invoice_lines l set sl = oi.sl_nhap from public.out_items oi, public.out_invoices i
 where oi.id = l.item_id and i.id = l.invoice_id and i.legacy and l.sl <> oi.sl_nhap;
-- Giá xuất theo sổ cho dòng đã nạp
update public.out_items set gia_so = nullif((legacy->>'dg_xuat')::numeric, 0) where gia_so is null and legacy ? 'dg_xuat';
update public.out_items set gia_khach = coalesce(gia_khach, gia_so) where gia_khach is null and gia_so is not null;

reset search_path;
