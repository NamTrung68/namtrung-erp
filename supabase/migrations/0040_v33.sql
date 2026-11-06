-- =====================================================================
-- 0040 · Bản 33 (06/11/2026): Menu "Pháp nhân" — nạp Excel, theo dõi, sửa trực tiếp, chuẩn hóa pháp nhân nhận HĐ
--  · Pháp nhân vẫn gắn khách theo USERNAME; 1 username có nhiều pháp nhân, 1 cái ★ mặc định
--  · Kế toán / Admin / BGĐ: thêm, sửa, xóa, đặt mặc định, đổi username (tự gắn lại khách)
--  · Phiếu lập nhanh theo ID đơn: chọn pháp nhân của khách (theo khách ERP hoặc username chưa gắn khách)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 33');

alter table public.out_buyers add column if not exists updated_at timestamptz;
alter table public.out_buyers add column if not exists updated_by uuid references public.profiles(id);

-- Danh sách pháp nhân + cờ chuẩn hóa. p: {q, flag, sale, offset, limit}
create or replace function public.out_buyers_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_q text := nullif(btrim(p->>'q'), ''); v_flag text := nullif(p->>'flag', ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 200), 2000); r jsonb; n bigint; c jsonb;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ'; end if;
  with b as materialized (
    select b.*, coalesce(b.username, cu.sys_username) uname, cu.code kh_code, cu.sys_code, coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name) kh_name, cu.owner_id sale_id,
           not app.mst_ok(b.tax_code) mst_sai,
           coalesce(btrim(b.address), '') = '' thieu_dc,
           exists(select 1 from public.out_buyers x where x.id <> b.id and btrim(x.tax_code) = btrim(b.tax_code) and lower(btrim(x.name)) <> lower(btrim(b.name))) trung_mst,
           b.customer_id is not null and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) khong_md,
           (select count(*) from public.out_invoices i where i.status <> 'huy' and (i.buyer_id = b.id or i.customer_id is not distinct from b.customer_id and btrim(i.tax_code) = btrim(b.tax_code))) so_phieu
      from public.out_buyers b left join public.customers cu on cu.id = b.customer_id)
  select jsonb_build_object('tat_ca', count(*), 'chua_gan', count(*) filter (where customer_id is null), 'mst_sai', count(*) filter (where mst_sai),
           'thieu_dc', count(*) filter (where thieu_dc), 'trung_mst', count(*) filter (where trung_mst), 'khong_md', count(*) filter (where khong_md),
           'khach', count(distinct coalesce(customer_id::text, 'u:' || lower(coalesce(uname, '')))))
    into c from b;
  with b as materialized (
    select b.*, coalesce(b.username, cu.sys_username) uname, cu.code kh_code, cu.sys_code, coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name) kh_name, cu.owner_id sale_id,
           not app.mst_ok(b.tax_code) mst_sai, coalesce(btrim(b.address), '') = '' thieu_dc,
           exists(select 1 from public.out_buyers x where x.id <> b.id and btrim(x.tax_code) = btrim(b.tax_code) and lower(btrim(x.name)) <> lower(btrim(b.name))) trung_mst,
           b.customer_id is not null and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) khong_md,
           (select count(*) from public.out_invoices i where i.status <> 'huy' and (i.buyer_id = b.id or i.customer_id is not distinct from b.customer_id and btrim(i.tax_code) = btrim(b.tax_code))) so_phieu
      from public.out_buyers b left join public.customers cu on cu.id = b.customer_id),
  f as (select * from b
         where (v_q is null or concat_ws(' ', name, tax_code, uname, address, email, kh_name, kh_code, sys_code, note) ilike '%' || v_q || '%')
           and (v_sale is null or sale_id = v_sale)
           and (v_flag is null or v_flag = 'chua_gan' and customer_id is null or v_flag = 'mst_sai' and mst_sai or v_flag = 'thieu_dc' and thieu_dc
                or v_flag = 'trung_mst' and trung_mst or v_flag = 'khong_md' and khong_md)),
  o as (select f.*, row_number() over (order by lower(coalesce(uname, 'zzzz')), customer_id, is_default desc, created_at) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(jsonb_build_object('id', id, 'customer_id', customer_id, 'username', uname, 'own_username', username, 'name', name, 'tax_code', tax_code, 'address', address,
           'email', email, 'note', note, 'is_default', is_default, 'kh_name', kh_name, 'kh_code', coalesce(sys_code, kh_code), 'sale_id', sale_id, 'mst_sai', mst_sai, 'thieu_dc', thieu_dc,
           'trung_mst', trung_mst, 'khong_md', khong_md, 'so_phieu', so_phieu, 'created_at', created_at, 'updated_at', updated_at, 'updated_by', updated_by) order by rn)
           filter (where rn > v_off and rn <= v_off + v_lim), '[]')
    into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c);
end $$;
grant execute on function public.out_buyers_page(jsonb) to authenticated;

-- Thêm / sửa 1 pháp nhân. p: {username, name, tax_code, address, email, note, is_default}
create or replace function public.out_buyer_save(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers; v_user text := app.norm_username(nullif(btrim(p->>'username'), '')); v_c uuid; v_mst text := nullif(regexp_replace(coalesce(p->>'tax_code', ''), '\s', '', 'g'), '');
        v_name text := nullif(regexp_replace(btrim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), ''); v_id uuid := p_id;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ sửa pháp nhân'; end if;
  if v_name is null then raise exception 'Nhập tên đơn vị'; end if;
  if v_mst is null then raise exception 'Nhập MST / CCCD'; end if;
  if not app.mst_ok(v_mst) then raise exception 'MST "%" sai dạng — 10 số, 10-3 số hoặc CCCD 12 số', v_mst; end if;
  if coalesce(btrim(p->>'email'), '') <> '' and btrim(p->>'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Email "%" sai dạng', p->>'email'; end if;
  if v_id is not null then select * into b from public.out_buyers where id = v_id for update; if b.id is null then raise exception 'Không thấy pháp nhân'; end if; end if;
  -- username → khách ERP; không gõ username thì giữ khách đang gắn
  if v_user is not null then
    select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(v_user) or upper(btrim(sys_code)) = upper(v_user)) order by created_at limit 1;
  elsif b.id is not null then v_c := b.customer_id; v_user := b.username;
  end if;
  if exists(select 1 from public.out_buyers x where x.id is distinct from v_id and btrim(x.tax_code) = v_mst
              and (v_c is not null and x.customer_id = v_c or v_c is null and x.customer_id is null and lower(coalesce(x.username, '')) = lower(coalesce(v_user, '')))) then
    raise exception 'Username % đã có pháp nhân MST % — sửa dòng đó thay vì thêm mới', coalesce(v_user, '(trống)'), v_mst;
  end if;
  if v_id is null then
    insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note, updated_at, updated_by)
    values (v_c, v_user, v_name, v_mst, nullif(btrim(p->>'address'), ''), nullif(btrim(p->>'email'), ''), coalesce(nullif(btrim(p->>'note'), ''), 'Nhập tay'), now(), auth.uid())
    returning id into v_id;
  else
    update public.out_buyers set customer_id = v_c, username = v_user, name = v_name, tax_code = v_mst, address = nullif(btrim(p->>'address'), ''), email = nullif(btrim(p->>'email'), ''),
      note = nullif(btrim(p->>'note'), ''), is_default = case when v_c is distinct from b.customer_id then false else is_default end, updated_at = now(), updated_by = auth.uid()
     where id = v_id;
  end if;
  if v_c is not null and (coalesce((p->>'is_default')::boolean, false) or not exists(select 1 from public.out_buyers x where x.customer_id = v_c and x.is_default)) then
    update public.out_buyers set is_default = (id = v_id) where customer_id = v_c and (is_default or id = v_id);
  end if;
  if b.customer_id is not null and b.customer_id is distinct from v_c and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) then
    update public.out_buyers set is_default = true where id = (select id from public.out_buyers where customer_id = b.customer_id order by created_at desc limit 1);
  end if;
  return v_id;
end $$;
grant execute on function public.out_buyer_save(uuid, jsonb) to authenticated;

create or replace function public.out_buyer_delete(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int; cs uuid[];
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ xóa pháp nhân'; end if;
  select array_agg(distinct customer_id) into cs from public.out_buyers where id = any(p_ids) and customer_id is not null;
  delete from public.out_buyers where id = any(p_ids);
  get diagnostics n = row_count;
  -- khách mất pháp nhân mặc định → pháp nhân mới nhất còn lại làm mặc định
  update public.out_buyers b set is_default = true
   where b.id in (select distinct on (customer_id) id from public.out_buyers where customer_id = any(coalesce(cs, '{}')) order by customer_id, created_at desc)
     and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default);
  return n;
end $$;
grant execute on function public.out_buyer_delete(uuid[]) to authenticated;

-- Pháp nhân để chọn khi lập phiếu: theo khách ERP hoặc theo username chưa gắn khách
create or replace function public.out_buyers_for(p_customers uuid[], p_usernames text[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'customer_id', b.customer_id, 'username', b.username, 'name', b.name, 'tax_code', b.tax_code, 'address', b.address,
            'email', b.email, 'is_default', b.is_default) order by b.is_default desc, b.created_at desc), '[]')
    from public.out_buyers b
   where (b.customer_id = any(coalesce(p_customers, '{}')) and (app.is_acc() or exists(select 1 from public.customers c where c.id = b.customer_id and app.in_tree(c.owner_id))))
      or (b.customer_id is null and b.username is not null and lower(b.username) = any(select lower(app.norm_username(x)) from unnest(coalesce(p_usernames, '{}')) x)));
end $$;
grant execute on function public.out_buyers_for(uuid[], text[]) to authenticated;

reset search_path;
