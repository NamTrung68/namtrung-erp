-- Bản 48 — Công tắc Mở / Khóa cập nhật Pháp nhân nhận HĐ
--  · Khóa (mặc định): chỉ Kế toán / Admin thêm, sửa, xóa, đặt ★ pháp nhân
--  · Mở: Sale / CSKH / TN / TP thêm, sửa pháp nhân của khách mình phụ trách (như bản 36); mã HĐ nguyên tắc vẫn chỉ kế toán
--  · Kế toán / Admin bật tắt bằng out_pn_lock_set; mở thì báo Sale / CSKH, ghi nhật ký
--  · Lưu ở settings.accounting.pn_mo (true = đang mở)

create or replace function app.pn_mo() returns boolean language sql stable security definer set search_path = public, app as $$
  select coalesce((app.setting('accounting')->>'pn_mo')::boolean, false)
$$;
/** Chặn ghi pháp nhân khi đang khóa, trừ Kế toán / Admin */
create or replace function app.pn_guard() returns void language plpgsql stable security definer set search_path = public, app as $$
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  if not app.pn_mo() and not app.has_role('admin', 'ke_toan') then
    raise exception 'Pháp nhân nhận HĐ đang khóa — chỉ Kế toán / Admin sửa. Cần sửa thông tin thì báo kế toán.';
  end if;
end $$;

create or replace function public.out_pn_lock_set(p_open boolean) returns boolean
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.has_role('admin', 'ke_toan') then raise exception 'Chỉ Kế toán / Admin mở, khóa cập nhật pháp nhân'; end if;
  insert into public.settings(key, value) values ('accounting', jsonb_build_object('pn_mo', p_open))
  on conflict (key) do update set value = coalesce(public.settings.value, '{}'::jsonb) || jsonb_build_object('pn_mo', p_open);
  perform app.log(case when p_open then 'PN_MO' else 'PN_KHOA' end, 'out_buyers', null, null);
  if p_open then
    perform app.notify_roles(array['sale', 'tn_kd', 'tp_kd', 'cskh'], 'acc', 'Mở cập nhật Pháp nhân nhận HĐ',
      'Vào Pháp nhân nhận HĐ, bổ sung / sửa tên, MST, địa chỉ, email, người đại diện cho khách mình phụ trách.', '#/hd/phap-nhan');
  end if;
  return p_open;
end $$;
grant execute on function public.out_pn_lock_set(boolean) to authenticated;

create or replace function public.out_buyer_save(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers; v_user text := app.norm_username(nullif(btrim(p->>'username'), '')); v_c uuid; v_mst text := nullif(regexp_replace(coalesce(p->>'tax_code', ''), '\s', '', 'g'), '');
        v_name text := nullif(regexp_replace(btrim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), ''); v_id uuid := p_id; v_ngay date;
        v_acc boolean := app.is_acc();
begin
  perform app.pn_guard();
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  -- Bản 36: sale / CSKH sửa pháp nhân của khách mình; mã + ngày HĐ nguyên tắc chỉ kế toán / admin / BGĐ
  if not v_acc then p := p - 'ma_hdnt' - 'ngay_hdnt'; end if;
  if v_name is null then raise exception 'Nhập tên đơn vị'; end if;
  if v_mst is null then raise exception 'Nhập MST / CCCD'; end if;
  if not app.mst_ok(v_mst) then raise exception 'MST "%" sai dạng — 10 số, 10-3 số hoặc CCCD 12 số', v_mst; end if;
  if coalesce(btrim(p->>'email'), '') <> '' and btrim(p->>'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Email "%" sai dạng', p->>'email'; end if;
  begin v_ngay := nullif(btrim(p->>'ngay_hdnt'), '')::date; exception when others then raise exception 'Ngày HĐ nguyên tắc "%" sai dạng', p->>'ngay_hdnt'; end;
  if v_id is not null then select * into b from public.out_buyers where id = v_id for update; if b.id is null then raise exception 'Không thấy pháp nhân'; end if; end if;
  if v_user is not null then
    select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(v_user) or upper(btrim(sys_code)) = upper(v_user)) order by created_at limit 1;
  elsif b.id is not null then v_c := b.customer_id; v_user := b.username;
  end if;
  if not v_acc then
    if b.id is not null and not exists(select 1 from public.customers c where c.id = b.customer_id and app.in_tree(c.owner_id)) then raise exception 'Pháp nhân này không thuộc khách bạn phụ trách'; end if;
    if v_c is null or not exists(select 1 from public.customers c where c.id = v_c and app.in_tree(c.owner_id)) then raise exception 'Username "%" không phải khách bạn phụ trách', coalesce(v_user, ''); end if;
  end if;
  if exists(select 1 from public.out_buyers x where x.id is distinct from v_id and btrim(x.tax_code) = v_mst
              and (v_c is not null and x.customer_id = v_c or v_c is null and x.customer_id is null and lower(coalesce(x.username, '')) = lower(coalesce(v_user, '')))) then
    raise exception 'Username % đã có pháp nhân MST % — sửa dòng đó thay vì thêm mới', coalesce(v_user, '(trống)'), v_mst;
  end if;
  if v_id is null then
    insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note, dai_dien, chuc_vu, dia_chi_giao, ma_hdnt, ngay_hdnt, updated_at, updated_by)
    values (v_c, v_user, v_name, v_mst, nullif(btrim(p->>'address'), ''), nullif(btrim(p->>'email'), ''), coalesce(nullif(btrim(p->>'note'), ''), case when v_acc then 'Nhập tay' else 'Sale / CSKH nhập' end),
            nullif(btrim(p->>'dai_dien'), ''), nullif(btrim(p->>'chuc_vu'), ''), nullif(btrim(p->>'dia_chi_giao'), ''), nullif(btrim(p->>'ma_hdnt'), ''), app.hdnt_ngay(p->>'ma_hdnt', v_ngay), now(), auth.uid())
    returning id into v_id;
  else
    update public.out_buyers set customer_id = v_c, username = v_user, name = v_name, tax_code = v_mst, address = nullif(btrim(p->>'address'), ''), email = nullif(btrim(p->>'email'), ''),
      note = nullif(btrim(p->>'note'), ''), is_default = case when v_c is distinct from b.customer_id then false else is_default end,
      dai_dien = case when p ? 'dai_dien' then nullif(btrim(p->>'dai_dien'), '') else dai_dien end,
      chuc_vu = case when p ? 'chuc_vu' then nullif(btrim(p->>'chuc_vu'), '') else chuc_vu end,
      dia_chi_giao = case when p ? 'dia_chi_giao' then nullif(btrim(p->>'dia_chi_giao'), '') else dia_chi_giao end,
      ma_hdnt = case when p ? 'ma_hdnt' then nullif(btrim(p->>'ma_hdnt'), '') else ma_hdnt end,
      ngay_hdnt = case when p ? 'ma_hdnt' or p ? 'ngay_hdnt' then app.hdnt_ngay(case when p ? 'ma_hdnt' then p->>'ma_hdnt' else ma_hdnt end, v_ngay) else ngay_hdnt end,
      updated_at = now(), updated_by = auth.uid()
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

create or replace function public.out_buyer_delete(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int; cs uuid[];
begin
  perform app.pn_guard();
  if not app.is_acc() then
    if exists(select 1 from public.out_buyers b where b.id = any(p_ids)
                and (not exists(select 1 from public.customers c where c.id = b.customer_id and app.in_tree(c.owner_id))
                     or exists(select 1 from public.out_invoices i where i.status <> 'huy' and (i.buyer_id = b.id or i.customer_id is not distinct from b.customer_id and btrim(i.tax_code) = btrim(b.tax_code))))) then
      raise exception 'Chỉ xóa được pháp nhân chưa dùng ở phiếu nào, của khách bạn phụ trách — đã dùng thì nhờ kế toán';
    end if;
  end if;
  select array_agg(distinct customer_id) into cs from public.out_buyers where id = any(p_ids) and customer_id is not null;
  delete from public.out_buyers where id = any(p_ids);
  get diagnostics n = row_count;
  update public.out_buyers b set is_default = true
   where b.id in (select distinct on (customer_id) id from public.out_buyers where customer_id = any(coalesce(cs, '{}')) order by customer_id, created_at desc)
     and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default);
  return n;
end $$;

create or replace function public.out_buyer_doc_info(p_id uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers;
begin
  perform app.pn_guard();
  select * into b from public.out_buyers where id = p_id;
  if b.id is null then raise exception 'Không thấy pháp nhân'; end if;
  if not (app.is_acc() or app.in_tree(b.created_by) or exists(select 1 from public.customers c where c.id = b.customer_id and app.in_tree(c.owner_id))
          or exists(select 1 from public.out_invoices i where (i.buyer_id = b.id or btrim(i.tax_code) = btrim(b.tax_code)) and app.in_tree(i.sale_id))) then
    raise exception 'Không có quyền sửa pháp nhân này';
  end if;
  if coalesce(btrim(p->>'sdt_nhan'), '') <> '' and app.sdt_norm(p->>'sdt_nhan') is null then raise exception 'SĐT nhận "%" sai dạng', p->>'sdt_nhan'; end if;
  update public.out_buyers set
    dai_dien = case when p ? 'dai_dien' then nullif(btrim(p->>'dai_dien'), '') else dai_dien end,
    chuc_vu = case when p ? 'chuc_vu' then nullif(btrim(p->>'chuc_vu'), '') else chuc_vu end,
    dia_chi_giao = case when p ? 'dia_chi_giao' then nullif(btrim(p->>'dia_chi_giao'), '') else dia_chi_giao end,
    nguoi_nhan = case when p ? 'nguoi_nhan' then nullif(btrim(p->>'nguoi_nhan'), '') else nguoi_nhan end,
    sdt_nhan = case when p ? 'sdt_nhan' then app.sdt_norm(p->>'sdt_nhan') else sdt_nhan end,
    updated_at = now(), updated_by = auth.uid()
   where id = p_id;
end $$;

create or replace function public.out_buyer_set_default(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers;
begin
  perform app.pn_guard();
  select * into b from public.out_buyers where id = p_id;
  if b.id is null or b.customer_id is null then raise exception 'Pháp nhân chưa gắn khách'; end if;
  if not (app.is_acc() or exists(select 1 from public.customers c where c.id = b.customer_id and app.in_tree(c.owner_id))) then raise exception 'Không có quyền'; end if;
  update public.out_buyers set is_default = false where customer_id = b.customer_id and is_default and id <> p_id;
  update public.out_buyers set is_default = true where id = p_id;
end $$;

-- Bản 48: theo yêu cầu, mở ngay để Sale / CSKH bổ sung thông tin (chỉ đặt lần đầu, không đè nếu đã có)
update public.settings set value = value || '{"pn_mo": true}'::jsonb where key = 'accounting' and not (value ? 'pn_mo');
insert into public.settings(key, value) values ('accounting', '{"pn_mo": true}') on conflict (key) do nothing;
