-- =====================================================================
-- 0022 · Bản 15: danh sách đơn vị nhận HĐ (sheet "Thong tin KH") + tra MST khi lập phiếu; file nháp đúng mẫu MISA
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 15');

create index if not exists out_buyers_mst on public.out_buyers(btrim(tax_code)) where tax_code is not null;

-- Kế toán nạp danh sách đơn vị nhận HĐ (MST, tên, địa chỉ, email) — cập nhật theo MST
create or replace function public.out_buyers_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n int := 0; v_id uuid; v_mst text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), ''); if v_mst is null or coalesce(btrim(r->>'name'), '') = '' then continue; end if;
    select id into v_id from public.out_buyers where customer_id is null and btrim(tax_code) = v_mst limit 1;
    if v_id is null then
      insert into public.out_buyers(name, tax_code, address, email, note) values (btrim(r->>'name'), v_mst, nullif(btrim(r->>'address'), ''), nullif(btrim(r->>'email'), ''), 'Danh sách kế toán');
    else
      update public.out_buyers set name = btrim(r->>'name'), address = coalesce(nullif(btrim(r->>'address'), ''), address), email = coalesce(nullif(btrim(r->>'email'), ''), email) where id = v_id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_buyers_import(jsonb) to authenticated;

-- Sale tra 1 MST cụ thể (không xem được cả danh sách)
create or replace function public.out_buyer_lookup(p_mst text) returns table(name text, address text, email text)
language sql stable security definer set search_path = public as $$
  select b.name, b.address, b.email from public.out_buyers b
   where length(btrim(coalesce(p_mst, ''))) >= 10 and btrim(b.tax_code) = regexp_replace(p_mst, '\s', '', 'g')
   order by (b.customer_id is null), b.created_at desc limit 1
$$;
grant execute on function public.out_buyer_lookup(text) to authenticated;

-- File đơn hàng: dòng chưa có username thì lấy theo mã đơn, rồi gắn khách → sale (chủ khách)
create or replace function public.out_orders_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; r jsonb; t record; v_md text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_md := case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end; if v_md is null then continue; end if;
    for t in select id from public.out_items where md = v_md and (sale_id is null or username is null or customer_id is null) loop
      update public.out_items set nvkd = coalesce(nvkd, nullif(btrim(r->>'nvkd'), '')), username = coalesce(username, nullif(btrim(r->>'username'), '')),
        sale_id = coalesce(sale_id, app.match_sale(nullif(btrim(r->>'nvkd'), ''))) where id = t.id;
      perform app.out_item_match(t.id); n := n + 1;
    end loop;
  end loop;
  return n;
end $$;
reset search_path;
