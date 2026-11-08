-- =====================================================================
-- 0043 · Bản 36 (08/11/2026)
--  A. Tra MST qua Xinvoice (miễn phí, 10 lần / 30 giây cho cả văn phòng): bộ nhớ đệm dùng chung mst_cache đọc / ghi từ trình duyệt
--  B. Pháp nhân nhận HĐ mở cho Sale / CSKH / TN / TP — chỉ khách mình phụ trách (không xem chéo); sửa / thêm được, mã HĐNT chỉ kế toán
--  C. Theo dõi hồ sơ chứng từ kèm HĐ đã ký: đã tải (loại nào, ai, lúc nào) → đã gửi khách → đã nhận bản ký (lưu file Drive)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 36');

-- ---------------- A. Bộ nhớ đệm MST dùng chung ----------------
/** Kết quả tra MST đã lưu (7 ngày) — tránh gọi lặp, vì giới hạn 10 lần / 30 giây tính chung cả văn phòng */
create or replace function public.mst_cache_get(p_mst text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when auth.uid() is not null and c.at > now() - interval '7 days' then c.data || jsonb_build_object('cached', true, 'cached_at', c.at) end
    from public.mst_cache c where c.mst = regexp_replace(coalesce(p_mst, ''), '\s', '', 'g')
$$;
grant execute on function public.mst_cache_get(text) to authenticated;
revoke execute on function public.mst_cache_get(text) from anon;

create or replace function public.mst_cache_put(p_mst text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare v text := regexp_replace(coalesce(p_mst, ''), '\s', '', 'g');
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id = auth.uid() and status = 'active') then raise exception 'Chưa đăng nhập'; end if;
  if v !~ '^(\d{10}|\d{10}-\d{3}|\d{12})$' then raise exception 'MST sai dạng'; end if;
  if coalesce(p_data->>'found', '') <> 'true' or coalesce(p_data->>'name', '') = '' or length(p_data::text) > 4000 then return; end if;
  insert into public.mst_cache(mst, provider, data, at) values (v, coalesce(p_data->>'provider', '?'), (p_data - 'cached' - 'cached_at') || jsonb_build_object('by', auth.uid()), now())
  on conflict (mst) do update set provider = excluded.provider, data = excluded.data, at = now();
end $$;
grant execute on function public.mst_cache_put(text, jsonb) to authenticated;
revoke execute on function public.mst_cache_put(text, jsonb) from anon;

-- ---------------- B. Pháp nhân theo phạm vi sale ----------------
create or replace function public.out_buyers_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_q text := nullif(btrim(p->>'q'), ''); v_flag text := nullif(p->>'flag', ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 200), 2000); r jsonb; n bigint; c jsonb;
        v_acc boolean := app.is_acc();
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  -- Bản 36: Sale / CSKH / TN / TP chỉ thấy pháp nhân của khách mình phụ trách (chủ khách trong phạm vi) — không xem chéo
  with b as materialized (
    select b.*, coalesce(b.username, cu.sys_username) uname, cu.code kh_code, cu.sys_code, coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name) kh_name, cu.owner_id sale_id,
           not app.mst_ok(b.tax_code) mst_sai,
           coalesce(btrim(b.address), '') = '' thieu_dc,
           exists(select 1 from public.out_buyers x where x.id <> b.id and btrim(x.tax_code) = btrim(b.tax_code) and lower(btrim(x.name)) <> lower(btrim(b.name))) trung_mst,
           b.customer_id is not null and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) khong_md,
           (select count(*) from public.out_invoices i where i.status <> 'huy' and (i.buyer_id = b.id or i.customer_id is not distinct from b.customer_id and btrim(i.tax_code) = btrim(b.tax_code))) so_phieu
      from public.out_buyers b left join public.customers cu on cu.id = b.customer_id
     where v_acc or (cu.id is not null and cu.deleted_at is null and app.in_tree(cu.owner_id)))
  select jsonb_build_object('tat_ca', count(*), 'chua_gan', count(*) filter (where customer_id is null), 'mst_sai', count(*) filter (where mst_sai),
           'thieu_dc', count(*) filter (where thieu_dc), 'trung_mst', count(*) filter (where trung_mst), 'khong_md', count(*) filter (where khong_md),
           'co_hdnt', count(*) filter (where ma_hdnt is not null), 'thieu_dd', count(*) filter (where dai_dien is null),
           'khach', count(distinct coalesce(customer_id::text, 'u:' || lower(coalesce(uname, '')))))
    into c from b;
  with b as materialized (
    select b.*, coalesce(b.username, cu.sys_username) uname, cu.code kh_code, cu.sys_code, coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name) kh_name, cu.owner_id sale_id,
           not app.mst_ok(b.tax_code) mst_sai, coalesce(btrim(b.address), '') = '' thieu_dc,
           exists(select 1 from public.out_buyers x where x.id <> b.id and btrim(x.tax_code) = btrim(b.tax_code) and lower(btrim(x.name)) <> lower(btrim(b.name))) trung_mst,
           b.customer_id is not null and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) khong_md,
           (select count(*) from public.out_invoices i where i.status <> 'huy' and (i.buyer_id = b.id or i.customer_id is not distinct from b.customer_id and btrim(i.tax_code) = btrim(b.tax_code))) so_phieu
      from public.out_buyers b left join public.customers cu on cu.id = b.customer_id
     where v_acc or (cu.id is not null and cu.deleted_at is null and app.in_tree(cu.owner_id))),
  f as (select * from b
         where (v_q is null or concat_ws(' ', name, tax_code, uname, address, email, kh_name, kh_code, sys_code, note, ma_hdnt, dai_dien) ilike '%' || v_q || '%')
           and (v_sale is null or sale_id = v_sale)
           and (v_flag is null or v_flag = 'chua_gan' and customer_id is null or v_flag = 'mst_sai' and mst_sai or v_flag = 'thieu_dc' and thieu_dc
                or v_flag = 'trung_mst' and trung_mst or v_flag = 'khong_md' and khong_md or v_flag = 'co_hdnt' and ma_hdnt is not null or v_flag = 'thieu_dd' and dai_dien is null)),
  o as (select f.*, row_number() over (order by lower(coalesce(uname, 'zzzz')), customer_id, is_default desc, created_at) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(jsonb_build_object('id', id, 'customer_id', customer_id, 'username', uname, 'own_username', username, 'name', name, 'tax_code', tax_code, 'address', address,
           'email', email, 'note', note, 'is_default', is_default, 'kh_name', kh_name, 'kh_code', coalesce(sys_code, kh_code), 'sale_id', sale_id, 'mst_sai', mst_sai, 'thieu_dc', thieu_dc,
           'trung_mst', trung_mst, 'khong_md', khong_md, 'so_phieu', so_phieu, 'created_at', created_at, 'updated_at', updated_at, 'updated_by', updated_by,
           'dai_dien', dai_dien, 'chuc_vu', chuc_vu, 'dia_chi_giao', dia_chi_giao, 'ma_hdnt', ma_hdnt, 'ngay_hdnt', ngay_hdnt) order by rn)
           filter (where rn > v_off and rn <= v_off + v_lim), '[]')
    into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'acc', v_acc);
end $$;
grant execute on function public.out_buyers_page(jsonb) to authenticated;

create or replace function public.out_buyer_save(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers; v_user text := app.norm_username(nullif(btrim(p->>'username'), '')); v_c uuid; v_mst text := nullif(regexp_replace(coalesce(p->>'tax_code', ''), '\s', '', 'g'), '');
        v_name text := nullif(regexp_replace(btrim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), ''); v_id uuid := p_id; v_ngay date;
        v_acc boolean := app.is_acc();
begin
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
grant execute on function public.out_buyer_save(uuid, jsonb) to authenticated;

-- Xóa: kế toán xóa mọi pháp nhân; sale / CSKH chỉ xóa pháp nhân CHƯA dùng ở phiếu nào, của khách mình
create or replace function public.out_buyer_delete(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int; cs uuid[];
begin
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
grant execute on function public.out_buyer_delete(uuid[]) to authenticated;

-- ---------------- C. Hồ sơ chứng từ ----------------
create table if not exists public.out_doc_state(
  invoice_id uuid primary key references public.out_invoices(id) on delete cascade,
  tai jsonb not null default '{}',          -- {"ddh": {"at":..., "by":..., "n": 2}, "bbgn": ...}
  gui_at timestamptz, gui_by uuid references public.profiles(id),
  ky_at timestamptz, ky_by uuid references public.profiles(id), ky_url text,
  note text, updated_at timestamptz not null default now()
);
alter table public.out_doc_state enable row level security;
drop policy if exists out_doc_state_read on public.out_doc_state;
create policy out_doc_state_read on public.out_doc_state for select to authenticated
  using (exists(select 1 from public.out_invoices i where i.id = invoice_id and (app.is_acc() or app.in_tree(i.sale_id))));
grant select on public.out_doc_state to authenticated;

/** Ghi vết hồ sơ: tai (tự ghi khi tải, kèm loại) · gui (đã gửi khách) · ky (đã nhận bản ký, kèm link file) · bo_gui / bo_ky (đánh dấu nhầm) */
create or replace function public.out_doc_mark(p_ids uuid[], p_act text, p_kinds text[] default '{}', p_url text default null, p_note text default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid; n int := 0; k text;
begin
  if p_act not in ('tai', 'gui', 'ky', 'bo_gui', 'bo_ky') then raise exception 'Thao tác không hợp lệ'; end if;
  if p_url is not null and p_url !~ '^https://' then raise exception 'Link file phải là https://'; end if;
  for v_id in select i.id from public.out_invoices i where i.id = any(p_ids) and i.status = 'da_ky' loop
    if not exists(select 1 from public.out_invoices i where i.id = v_id and (app.is_acc() or app.in_tree(i.sale_id))) then raise exception 'Không có quyền với HĐ này'; end if;
    insert into public.out_doc_state(invoice_id) values (v_id) on conflict do nothing;
    if p_act = 'tai' then
      foreach k in array coalesce(p_kinds, '{}') loop
        if k not in ('ddh', 'bbgn', 'hdmb', 'hdnt') then continue; end if;
        update public.out_doc_state set tai = jsonb_set(tai, array[k], jsonb_build_object('at', now(), 'by', auth.uid(), 'n', coalesce((tai->k->>'n')::int, 0) + 1)), updated_at = now() where invoice_id = v_id;
      end loop;
    elsif p_act = 'gui' then update public.out_doc_state set gui_at = now(), gui_by = auth.uid(), note = coalesce(nullif(btrim(p_note), ''), note), updated_at = now() where invoice_id = v_id;
    elsif p_act = 'ky' then update public.out_doc_state set ky_at = now(), ky_by = auth.uid(), ky_url = coalesce(p_url, ky_url), gui_at = coalesce(gui_at, now()), gui_by = coalesce(gui_by, auth.uid()),
                              note = coalesce(nullif(btrim(p_note), ''), note), updated_at = now() where invoice_id = v_id;
    elsif p_act = 'bo_gui' then update public.out_doc_state set gui_at = null, gui_by = null, updated_at = now() where invoice_id = v_id;
    else update public.out_doc_state set ky_at = null, ky_by = null, ky_url = null, updated_at = now() where invoice_id = v_id;
    end if;
    if p_act <> 'tai' then insert into public.out_events(invoice_id, action, data) values (v_id, 'chung_tu', jsonb_build_object('act', p_act, 'url', p_url, 'note', p_note)); end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_doc_mark(uuid[], text, text[], text, text) to authenticated;

reset search_path;
