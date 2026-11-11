-- =====================================================================
-- 0048 · Bản 40 (11/11/2026) — Chuyển phát HĐ đã ký (giai đoạn 1: nhập tay)
--  Luồng: chọn HĐ đã ký → gom theo khách → 1 phiếu chuyển phát / khách → Đã gửi (ngày gửi, mã vận đơn)
--         → Khách đã nhận (ngày nhận, báo sale nhắc khách gửi lại 1 bản) → hạn thu hồi = ngày nhận + 7 ngày
--         → quá hạn chưa thu về: cảnh báo sale + quản lý hằng ngày → xác nhận "Đã thu về" từng HĐ → xong.
--  Nối vết hồ sơ (out_doc_state): phiếu Đã gửi → HĐ "✉ đã gửi khách"; HĐ thu về → "✓ đã có bản ký".
--  Giai đoạn 2 (chưa làm): tạo vận đơn + nhận trạng thái qua API ViettelPost (cột api, hang = 'viettelpost').
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 40');

-- ---------------- A. Pháp nhân: người nhận + SĐT nhận chuyển phát ----------------
alter table public.out_buyers add column if not exists nguoi_nhan text;
alter table public.out_buyers add column if not exists sdt_nhan text;

-- ---------------- B. Cấu hình ----------------
insert into public.settings(key, value, description) values ('chuyen_phat', jsonb_build_object(
  'ten_gui', 'Công ty TNHH DV&TM Quốc tế Nam Trung', 'sdt_gui', '',
  'dia_chi_gui', 'Tầng 2, tòa G4, chung cư Fivestar, số 2 ngõ 460 Khương Đình, Thanh Xuân, Hà Nội',
  'so_ngay_thu', 7, 'nhac_lai', 3, 'sap_han', 2, 'hang', 'viettelpost'), 'Chuyển phát HĐ đã ký: địa chỉ gửi, hạn thu hồi bản ký')
on conflict (key) do nothing;

-- Kế toán được sửa cấu hình chuyển phát
create or replace function public.set_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_old jsonb;
begin
  if not (app.is_admin() or (app.has_role('hcns') and p_key in ('attendance','leave','payroll'))
          or (app.has_role('ke_toan') and p_key in ('vietqr','payroll','quote_defaults','accounting','chuyen_phat'))) then
    raise exception 'Không có quyền sửa cấu hình %', p_key;
  end if;
  -- Kế toán không tự thêm người duyệt mở chặn: chỉ Admin/BGĐ
  if p_key = 'accounting' and not app.is_admin() then
    select value into v_old from public.settings where key = p_key;
    p_value := jsonb_set(p_value, '{approver_ids}', coalesce(v_old->'approver_ids', '[]'));
  end if;
  if p_key = 'chuyen_phat' then
    if coalesce((p_value->>'so_ngay_thu')::int, 0) not between 1 and 60 then raise exception 'Hạn thu hồi phải từ 1 đến 60 ngày'; end if;
    if coalesce((p_value->>'nhac_lai')::int, 0) not between 1 and 30 then raise exception 'Nhắc lại phải từ 1 đến 30 ngày'; end if;
  end if;
  select value into v_old from public.settings where key = p_key;
  insert into public.settings(key, value, updated_by) values (p_key, p_value, auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  insert into public.settings_history(key, old_value, new_value, changed_by) values (p_key, v_old, p_value, auth.uid());
end $$;

-- ---------------- C. Bảng ----------------
create sequence if not exists public.out_ship_seq;
create table if not exists public.out_ships(
  id uuid primary key default gen_random_uuid(),
  code text unique not null default ('CP' || lpad(nextval('public.out_ship_seq')::text, 5, '0')),
  sale_id uuid references public.profiles(id),
  customer_id uuid references public.customers(id) on delete set null,
  buyer_id uuid references public.out_buyers(id) on delete set null,
  khach text,                                   -- tên đơn vị nhận HĐ (hiển thị)
  nguoi_nhan text not null, sdt text not null, dia_chi text not null,
  hang text not null default 'viettelpost' check (hang in ('viettelpost', 'khac', 'tay')),
  ma_van_don text,
  status text not null default 'cho_gui' check (status in ('cho_gui', 'da_gui', 'da_nhan', 'da_thu', 'hoan', 'huy')),
  ngay_gui date, ngay_nhan date, han_thu date, ngay_thu date,
  canh_bao_at timestamptz, canh_bao_n int not null default 0,
  note text,
  api jsonb,                                    -- giai đoạn 2: dữ liệu ViettelPost (mã đơn, trạng thái, cước…)
  created_by uuid default auth.uid() references public.profiles(id), created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), status_at timestamptz not null default now(), status_by uuid references public.profiles(id)
);
create index if not exists out_ships_sale on public.out_ships(sale_id, status);
create index if not exists out_ships_han on public.out_ships(han_thu) where status = 'da_nhan';
create unique index if not exists out_ships_mvd on public.out_ships(hang, upper(btrim(ma_van_don))) where ma_van_don is not null and status not in ('huy');

create table if not exists public.out_ship_items(
  ship_id uuid not null references public.out_ships(id) on delete cascade,
  invoice_id uuid not null references public.out_invoices(id) on delete cascade,
  thu_at timestamptz, thu_ngay date, thu_by uuid references public.profiles(id), thu_url text,
  primary key (ship_id, invoice_id)
);
create index if not exists out_ship_items_inv on public.out_ship_items(invoice_id);

create table if not exists public.out_ship_events(
  id bigint generated always as identity primary key,
  ship_id uuid not null references public.out_ships(id) on delete cascade,
  action text not null, note text, data jsonb,
  actor uuid default auth.uid() references public.profiles(id), at timestamptz not null default now()
);
create index if not exists out_ship_events_ship on public.out_ship_events(ship_id, at);

alter table public.out_ships enable row level security;
alter table public.out_ship_items enable row level security;
alter table public.out_ship_events enable row level security;
drop policy if exists out_ships_read on public.out_ships;
create policy out_ships_read on public.out_ships for select to authenticated using (app.is_acc() or app.in_tree(sale_id));
drop policy if exists out_ship_items_read on public.out_ship_items;
create policy out_ship_items_read on public.out_ship_items for select to authenticated
  using (exists(select 1 from public.out_ships s where s.id = ship_id and (app.is_acc() or app.in_tree(s.sale_id))));
drop policy if exists out_ship_events_read on public.out_ship_events;
create policy out_ship_events_read on public.out_ship_events for select to authenticated
  using (exists(select 1 from public.out_ships s where s.id = ship_id and (app.is_acc() or app.in_tree(s.sale_id))));
grant select on public.out_ships, public.out_ship_items, public.out_ship_events to authenticated;
-- Ghi chỉ qua các hàm bên dưới (security definer)
revoke insert, update, delete on public.out_ships, public.out_ship_items, public.out_ship_events from authenticated, anon;

-- ---------------- D. Hàm phụ ----------------
/** Chuẩn hóa SĐT Việt Nam: bỏ dấu cách / chấm / gạch, +84 / 84 → 0. Sai dạng → null */
create or replace function app.sdt_norm(p text) returns text language sql immutable as $$
  select case when x ~ '^0[0-9]{9,10}$' then x end
    from (select regexp_replace(regexp_replace(regexp_replace(coalesce(p, ''), '[\s\.\-\(\)]', '', 'g'), '^\+?84', '0'), '^00', '0') x) t
$$;

create or replace function app.cp_cfg() returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('so_ngay_thu', 7, 'nhac_lai', 3, 'sap_han', 2) || coalesce(app.setting('chuyen_phat'), '{}')
$$;

/** Vết hồ sơ của HĐ theo phiếu chuyển phát: gui → ✉ đã gửi khách · ky → ✓ đã có bản ký · bo_ky → bỏ (chỉ khi chưa lưu file bản ký) */
create or replace function app.cp_doc(p_ids uuid[], p_act text, p_url text default null) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(array_length(p_ids, 1), 0) = 0 then return; end if;
  insert into public.out_doc_state(invoice_id) select distinct x from unnest(p_ids) x on conflict do nothing;
  if p_act = 'gui' then
    update public.out_doc_state set gui_at = coalesce(gui_at, now()), gui_by = coalesce(gui_by, auth.uid()), updated_at = now() where invoice_id = any(p_ids);
  elsif p_act = 'ky' then
    update public.out_doc_state set ky_at = coalesce(ky_at, now()), ky_by = coalesce(ky_by, auth.uid()), ky_url = coalesce(p_url, ky_url),
           gui_at = coalesce(gui_at, now()), gui_by = coalesce(gui_by, auth.uid()), updated_at = now() where invoice_id = any(p_ids);
  elsif p_act = 'bo_ky' then
    update public.out_doc_state set ky_at = null, ky_by = null, updated_at = now() where invoice_id = any(p_ids) and ky_url is null;
  end if;
end $$;

create or replace function app.cp_log(p_ship uuid, p_act text, p_note text default null, p_data jsonb default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_code text;
begin
  insert into public.out_ship_events(ship_id, action, note, data) values (p_ship, p_act, p_note, p_data);
  -- ghi cả vào lịch sử từng HĐ (hiện trong chi tiết phiếu xuất HĐ)
  select code into v_code from public.out_ships where id = p_ship;
  insert into public.out_events(invoice_id, action, note, data)
    select i.invoice_id, 'chuyen_phat', v_code || ': ' || coalesce(p_note, p_act), jsonb_build_object('ship', p_ship, 'act', p_act) || coalesce(p_data, '{}')
      from public.out_ship_items i where i.ship_id = p_ship;
end $$;

/** Người nhận cảnh báo của 1 phiếu: sale + CSKH đang hỗ trợ sale + quản lý trực tiếp */
create or replace function app.cp_notify(p_sale uuid, p_title text, p_body text, p_mgr boolean default false) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_cskh uuid; v_mgr uuid;
begin
  if p_sale is null then return; end if;
  perform app.notify(p_sale, 'chuyen_phat', p_title, p_body, '/hd?tab=cp');
  begin v_cskh := app.cskh_for(p_sale); exception when others then v_cskh := null; end;
  if v_cskh is not null and v_cskh <> p_sale then perform app.notify(v_cskh, 'chuyen_phat', p_title, p_body, '/hd?tab=cp'); end if;
  if p_mgr then
    select manager_id into v_mgr from public.profiles where id = p_sale;
    if v_mgr is not null and v_mgr is distinct from v_cskh then perform app.notify(v_mgr, 'chuyen_phat', p_title, p_body, '/hd/cp'); end if;
  end if;
end $$;

-- Pháp nhân: lưu thêm người nhận / SĐT nhận chuyển phát (dùng chung hàm bổ sung thông tin chứng từ)
create or replace function public.out_buyer_doc_info(p_id uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers;
begin
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
grant execute on function public.out_buyer_doc_info(uuid, jsonb) to authenticated;

-- Pháp nhân: trả thêm người nhận / SĐT nhận, lọc 'Thiếu thông tin nhận chuyển phát'
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
           'thieu_nhan', count(*) filter (where coalesce(btrim(sdt_nhan), '') = '' or coalesce(btrim(coalesce(dia_chi_giao, address)), '') = ''),
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
         where (v_q is null or concat_ws(' ', name, tax_code, uname, address, email, kh_name, kh_code, sys_code, note, ma_hdnt, dai_dien, nguoi_nhan, sdt_nhan, dia_chi_giao) ilike '%' || v_q || '%')
           and (v_sale is null or sale_id = v_sale)
           and (v_flag is null or v_flag = 'chua_gan' and customer_id is null or v_flag = 'mst_sai' and mst_sai or v_flag = 'thieu_dc' and thieu_dc
                or v_flag = 'trung_mst' and trung_mst or v_flag = 'khong_md' and khong_md or v_flag = 'co_hdnt' and ma_hdnt is not null or v_flag = 'thieu_dd' and dai_dien is null
                or v_flag = 'thieu_nhan' and (coalesce(btrim(sdt_nhan), '') = '' or coalesce(btrim(coalesce(dia_chi_giao, address)), '') = ''))),
  o as (select f.*, row_number() over (order by lower(coalesce(uname, 'zzzz')), customer_id, is_default desc, created_at) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(jsonb_build_object('id', id, 'customer_id', customer_id, 'username', uname, 'own_username', username, 'name', name, 'tax_code', tax_code, 'address', address,
           'email', email, 'note', note, 'is_default', is_default, 'kh_name', kh_name, 'kh_code', coalesce(sys_code, kh_code), 'sale_id', sale_id, 'mst_sai', mst_sai, 'thieu_dc', thieu_dc,
           'trung_mst', trung_mst, 'khong_md', khong_md, 'so_phieu', so_phieu, 'created_at', created_at, 'updated_at', updated_at, 'updated_by', updated_by,
           'dai_dien', dai_dien, 'chuc_vu', chuc_vu, 'dia_chi_giao', dia_chi_giao, 'ma_hdnt', ma_hdnt, 'ngay_hdnt', ngay_hdnt, 'nguoi_nhan', nguoi_nhan, 'sdt_nhan', sdt_nhan) order by rn)
           filter (where rn > v_off and rn <= v_off + v_lim), '[]')
    into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'acc', v_acc);
end $$;
grant execute on function public.out_buyers_page(jsonb) to authenticated;

-- ---------------- E. Chuẩn bị tạo phiếu: HĐ đã chọn + người nhận gợi ý ----------------
/** Người nhận gợi ý: pháp nhân của HĐ (người nhận / SĐT nhận / địa chỉ giao) → khách (người liên hệ, SĐT, địa chỉ) */
create or replace function public.out_ship_prep(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  return jsonb_build_object('cfg', app.cp_cfg(), 'rows', coalesce((select jsonb_agg(x order by x->>'kh_key', x->>'so_hd') from (
    select jsonb_build_object('id', i.id, 'code', i.code, 'so_hd', i.so_hd, 'ngay_hd', i.ngay_hd, 'sale_id', i.sale_id, 'customer_id', i.customer_id,
             'buyer_id', b.id, 'buyer_name', i.buyer_name, 'tax_code', i.tax_code,
             'kh_key', coalesce(i.customer_id::text, 'mst:' || btrim(coalesce(i.tax_code, ''))) || '|' || coalesce(i.sale_id::text, ''),
             'kh_name', coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name), 'username', cu.sys_username,
             'nguoi_nhan', coalesce(b.nguoi_nhan, nullif(btrim(cu.contact_name), ''), b.dai_dien),
             'sdt', coalesce(b.sdt_nhan, app.sdt_norm(cu.phone)),
             'dia_chi', coalesce(nullif(btrim(b.dia_chi_giao), ''), nullif(btrim(b.address), ''), nullif(btrim(i.address), ''), nullif(btrim(cu.address), '')),
             'tu_phap_nhan', b.nguoi_nhan is not null and b.sdt_nhan is not null,
             'ship_code', (select s.code from public.out_ship_items si join public.out_ships s on s.id = si.ship_id
                            where si.invoice_id = i.id and s.status not in ('huy', 'hoan') limit 1)) x
      from public.out_invoices i
      left join public.customers cu on cu.id = i.customer_id
      left join lateral (select b.* from public.out_buyers b
                          where b.id = i.buyer_id or (i.customer_id is not null and b.customer_id = i.customer_id and (btrim(b.tax_code) = btrim(i.tax_code) or b.is_default))
                          order by coalesce(b.id = i.buyer_id, false) desc, coalesce(btrim(b.tax_code) = btrim(i.tax_code), false) desc, b.is_default desc limit 1) b on true
     where i.id = any(p_ids) and i.status = 'da_ky' and (app.is_acc() or app.in_tree(i.sale_id))) t), '[]'));
end $$;
grant execute on function public.out_ship_prep(uuid[]) to authenticated;

/** HĐ đã ký chưa nằm trong phiếu chuyển phát nào đang mở (chọn để tạo phiếu ở màn Chuyển phát) */
create or replace function public.out_ship_candidates(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid; v_lim int := least(coalesce((p->>'limit')::int, 300), 1000);
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('id', i.id, 'code', i.code, 'so_hd', i.so_hd, 'ngay_hd', i.ngay_hd, 'sale_id', i.sale_id, 'buyer_name', i.buyer_name, 'tax_code', i.tax_code,
             'username', cu.sys_username, 'kh_name', coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name),
             'mds', (select string_agg(distinct it.md, ', ') from public.out_invoice_lines l join public.out_items it on it.id = l.item_id where l.invoice_id = i.id),
             'gui_at', d.gui_at, 'ky_at', d.ky_at) x
      from public.out_invoices i
      left join public.customers cu on cu.id = i.customer_id
      left join public.out_doc_state d on d.invoice_id = i.id
     where i.status = 'da_ky' and (app.is_acc() or app.in_tree(i.sale_id))
       and (v_sale is null or i.sale_id = v_sale)
       and not exists(select 1 from public.out_ship_items si join public.out_ships s on s.id = si.ship_id where si.invoice_id = i.id and s.status not in ('huy', 'hoan'))
       and (coalesce((p->>'all')::boolean, false) or d.ky_at is null)
       and (v_q is null or concat_ws(' ', i.code, i.so_hd, i.buyer_name, i.tax_code, cu.sys_username, cu.code, cu.sys_code, cu.company_name, cu.contact_name,
                                    (select string_agg(distinct it.md, ' ') from public.out_invoice_lines l join public.out_items it on it.id = l.item_id where l.invoice_id = i.id)) ilike '%' || v_q || '%')
     order by i.ngay_hd desc nulls last, i.so_hd desc limit v_lim) t), '[]');
end $$;
grant execute on function public.out_ship_candidates(jsonb) to authenticated;

-- ---------------- F. Tạo phiếu (mỗi nhóm = 1 khách = 1 phiếu) ----------------
/** p = {groups: [{ids, buyer_id, khach, nguoi_nhan, sdt, dia_chi, hang, ma_van_don, gui, ngay_gui, note, luu}]}
    gui = true → tạo xong là "Đã gửi" luôn (ngày gửi mặc định hôm nay). luu = true → lưu người nhận vào pháp nhân để lần sau tự điền. */
create or replace function public.out_ship_create(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare g jsonb; v_ids uuid[]; v_sale uuid; v_cus uuid; n_key int; n_sale int; v_buyer uuid; v_khach text; v_bad text;
        v_nn text; v_sdt text; v_dc text; v_hang text; v_mvd text; v_gui date; v_id uuid; v_code text; v_out jsonb := '[]'; v_cfg jsonb := app.cp_cfg(); t date := app.vn_today();
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  if jsonb_typeof(p->'groups') is distinct from 'array' or jsonb_array_length(p->'groups') = 0 then raise exception 'Chưa chọn HĐ nào'; end if;
  for g in select * from jsonb_array_elements(p->'groups') loop
    select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(coalesce(g->'ids', '[]')) x;
    if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'Phiếu chưa có HĐ nào'; end if;
    perform 1 from public.out_invoices where id = any(v_ids) for update;
    if (select count(*) from public.out_invoices where id = any(v_ids)) <> array_length(v_ids, 1) then raise exception 'Có HĐ không tồn tại'; end if;
    if exists(select 1 from public.out_invoices where id = any(v_ids) and not (app.is_acc() or app.in_tree(sale_id))) then raise exception 'Không có quyền với HĐ này'; end if;
    select string_agg(coalesce(so_hd, code), ', ') into v_bad from public.out_invoices where id = any(v_ids) and status <> 'da_ky';
    if v_bad is not null then raise exception 'HĐ chưa ký, chưa gửi được: %', v_bad; end if;
    select string_agg(coalesce(i.so_hd, i.code) || ' (' || s.code || ')', ', ') into v_bad
      from public.out_ship_items si join public.out_ships s on s.id = si.ship_id join public.out_invoices i on i.id = si.invoice_id
     where si.invoice_id = any(v_ids) and s.status not in ('huy', 'hoan');
    if v_bad is not null then raise exception 'HĐ đã nằm trong phiếu chuyển phát khác: %', v_bad; end if;
    select count(distinct coalesce(customer_id::text, 'mst:' || btrim(coalesce(tax_code, '')))), count(distinct coalesce(sale_id::text, '-')),
           min(sale_id::text)::uuid, min(customer_id::text)::uuid, min(buyer_name)
      into n_key, n_sale, v_sale, v_cus, v_khach from public.out_invoices where id = any(v_ids);
    if n_key > 1 then raise exception 'Mỗi phiếu chỉ gửi cho 1 khách — HĐ của nhiều khách thì tạo nhiều phiếu'; end if;
    if n_sale > 1 then raise exception 'Các HĐ thuộc nhiều sale khác nhau — tách phiếu theo sale'; end if;
    v_khach := coalesce(nullif(btrim(g->>'khach'), ''), v_khach);
    v_buyer := nullif(g->>'buyer_id', '')::uuid;
    if v_buyer is not null and not exists(select 1 from public.out_buyers where id = v_buyer) then v_buyer := null; end if;
    v_nn := nullif(regexp_replace(btrim(coalesce(g->>'nguoi_nhan', '')), '\s+', ' ', 'g'), '');
    v_sdt := app.sdt_norm(g->>'sdt');
    v_dc := nullif(regexp_replace(btrim(coalesce(g->>'dia_chi', '')), '\s+', ' ', 'g'), '');
    if v_nn is null then raise exception 'Nhập người nhận cho %', coalesce(v_khach, 'phiếu'); end if;
    if v_sdt is null then raise exception 'SĐT người nhận "%" sai dạng (%)', coalesce(g->>'sdt', ''), coalesce(v_khach, 'phiếu'); end if;
    if v_dc is null or length(v_dc) < 10 then raise exception 'Địa chỉ nhận của % quá ngắn', coalesce(v_khach, 'phiếu'); end if;
    v_hang := coalesce(nullif(g->>'hang', ''), nullif(v_cfg->>'hang', ''), 'viettelpost');
    if v_hang not in ('viettelpost', 'khac', 'tay') then raise exception 'Hãng chuyển phát không hợp lệ'; end if;
    v_mvd := nullif(upper(regexp_replace(coalesce(g->>'ma_van_don', ''), '\s', '', 'g')), '');
    v_gui := null;
    if coalesce((g->>'gui')::boolean, false) then
      v_gui := coalesce(nullif(g->>'ngay_gui', '')::date, t);
      if v_gui > t or v_gui < t - 60 then raise exception 'Ngày gửi % không hợp lệ', to_char(v_gui, 'DD/MM/YYYY'); end if;
    end if;
    if v_mvd is not null and exists(select 1 from public.out_ships where hang = v_hang and upper(btrim(ma_van_don)) = v_mvd and status <> 'huy') then
      raise exception 'Mã vận đơn % đã dùng ở phiếu khác', v_mvd; end if;
    insert into public.out_ships(sale_id, customer_id, buyer_id, khach, nguoi_nhan, sdt, dia_chi, hang, ma_van_don, status, ngay_gui, note, status_by)
    values (v_sale, v_cus, v_buyer, v_khach, v_nn, v_sdt, v_dc, v_hang, v_mvd, case when v_gui is null then 'cho_gui' else 'da_gui' end, v_gui,
            nullif(btrim(coalesce(g->>'note', '')), ''), auth.uid())
    returning id, code into v_id, v_code;
    insert into public.out_ship_items(ship_id, invoice_id) select v_id, x from unnest(v_ids) x;
    perform app.cp_log(v_id, 'tao', 'Tạo phiếu chuyển phát · ' || array_length(v_ids, 1) || ' HĐ · ' || v_nn || ' ' || v_sdt);
    if v_gui is not null then
      perform app.cp_log(v_id, 'gui', 'Đã gửi ngày ' || to_char(v_gui, 'DD/MM/YYYY') || coalesce(' · vận đơn ' || v_mvd, ''));
      perform app.cp_doc(v_ids, 'gui');
    end if;
    -- lưu người nhận vào pháp nhân (lần sau tự điền)
    if coalesce((g->>'luu')::boolean, false) and v_buyer is not null then
      update public.out_buyers b set nguoi_nhan = v_nn, sdt_nhan = v_sdt,
             dia_chi_giao = case when lower(btrim(coalesce(b.address, ''))) = lower(v_dc) then b.dia_chi_giao else v_dc end,
             updated_at = now(), updated_by = auth.uid()
       where b.id = v_buyer and (b.nguoi_nhan is distinct from v_nn or b.sdt_nhan is distinct from v_sdt
                                 or coalesce(b.dia_chi_giao, b.address, '') is distinct from v_dc);
    end if;
    v_out := v_out || jsonb_build_object('id', v_id, 'code', v_code, 'n', array_length(v_ids, 1), 'khach', v_khach);
  end loop;
  return v_out;
end $$;
grant execute on function public.out_ship_create(jsonb) to authenticated;

-- ---------------- G. Cập nhật trạng thái phiếu ----------------
/** p_act: sua (người nhận / SĐT / địa chỉ / hãng / mã vận đơn / ghi chú) · gui (ngay, ma_van_don) · nhan (ngay) · hoan (note) · huy (note) · lui (lùi 1 bước khi bấm nhầm) */
create or replace function public.out_ship_act(p_id uuid, p_act text, p jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare s public.out_ships; t date := app.vn_today(); v_ngay date; v_cfg jsonb := app.cp_cfg(); v_mvd text; v_ids uuid[]; v_note text := nullif(btrim(coalesce(p->>'note', '')), '');
        v_sdt text; v_han date;
begin
  select * into s from public.out_ships where id = p_id for update;
  if s.id is null then raise exception 'Không thấy phiếu chuyển phát'; end if;
  if not (app.is_acc() or app.in_tree(s.sale_id)) then raise exception 'Không có quyền với phiếu này'; end if;
  select array_agg(invoice_id) into v_ids from public.out_ship_items where ship_id = p_id;
  begin v_ngay := nullif(p->>'ngay', '')::date; exception when others then raise exception 'Ngày "%" sai dạng', p->>'ngay'; end;
  if p ? 'ma_van_don' then v_mvd := nullif(upper(regexp_replace(coalesce(p->>'ma_van_don', ''), '\s', '', 'g')), ''); else v_mvd := s.ma_van_don; end if;
  if v_mvd is not null and v_mvd is distinct from s.ma_van_don
     and exists(select 1 from public.out_ships where id <> p_id and hang = coalesce(nullif(p->>'hang', ''), s.hang) and upper(btrim(ma_van_don)) = v_mvd and status <> 'huy') then
    raise exception 'Mã vận đơn % đã dùng ở phiếu khác', v_mvd; end if;

  if p_act = 'sua' then
    if s.status in ('huy') then raise exception 'Phiếu đã hủy'; end if;
    v_sdt := case when p ? 'sdt' then app.sdt_norm(p->>'sdt') else s.sdt end;
    if v_sdt is null then raise exception 'SĐT người nhận "%" sai dạng', p->>'sdt'; end if;
    if p ? 'nguoi_nhan' and coalesce(btrim(p->>'nguoi_nhan'), '') = '' then raise exception 'Nhập người nhận'; end if;
    if p ? 'dia_chi' and length(btrim(coalesce(p->>'dia_chi', ''))) < 10 then raise exception 'Địa chỉ nhận quá ngắn'; end if;
    if p ? 'hang' and p->>'hang' not in ('viettelpost', 'khac', 'tay') then raise exception 'Hãng chuyển phát không hợp lệ'; end if;
    update public.out_ships set
      nguoi_nhan = case when p ? 'nguoi_nhan' then regexp_replace(btrim(p->>'nguoi_nhan'), '\s+', ' ', 'g') else nguoi_nhan end,
      sdt = v_sdt,
      dia_chi = case when p ? 'dia_chi' then regexp_replace(btrim(p->>'dia_chi'), '\s+', ' ', 'g') else dia_chi end,
      hang = coalesce(nullif(p->>'hang', ''), hang), ma_van_don = v_mvd,
      note = case when p ? 'note' then v_note else note end, updated_at = now()
     where id = p_id;
    perform app.cp_log(p_id, 'sua', 'Sửa thông tin phiếu', p);

  elsif p_act = 'gui' then
    if s.status <> 'cho_gui' then raise exception 'Phiếu không ở trạng thái Chờ gửi'; end if;
    v_ngay := coalesce(v_ngay, t);
    if v_ngay > t or v_ngay < (s.created_at at time zone 'Asia/Ho_Chi_Minh')::date - 60 then raise exception 'Ngày gửi % không hợp lệ', to_char(v_ngay, 'DD/MM/YYYY'); end if;
    update public.out_ships set status = 'da_gui', ngay_gui = v_ngay, ma_van_don = v_mvd, hang = coalesce(nullif(p->>'hang', ''), hang),
           status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    perform app.cp_log(p_id, 'gui', 'Đã gửi ngày ' || to_char(v_ngay, 'DD/MM/YYYY') || coalesce(' · vận đơn ' || v_mvd, ''));
    perform app.cp_doc(v_ids, 'gui');

  elsif p_act = 'nhan' then
    if s.status <> 'da_gui' then raise exception 'Phiếu chưa ở trạng thái Đã gửi'; end if;
    v_ngay := coalesce(v_ngay, t);
    if v_ngay > t or v_ngay < s.ngay_gui then raise exception 'Ngày khách nhận % không hợp lệ (gửi ngày %)', to_char(v_ngay, 'DD/MM/YYYY'), to_char(s.ngay_gui, 'DD/MM/YYYY'); end if;
    v_han := v_ngay + (v_cfg->>'so_ngay_thu')::int;
    update public.out_ships set status = case when exists(select 1 from public.out_ship_items where ship_id = p_id and thu_at is null) then 'da_nhan' else 'da_thu' end,
           ngay_nhan = v_ngay, han_thu = v_han, ma_van_don = v_mvd, status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    perform app.cp_log(p_id, 'nhan', 'Khách nhận ngày ' || to_char(v_ngay, 'DD/MM/YYYY') || ' · hạn thu về bản ký ' || to_char(v_han, 'DD/MM/YYYY'));
    perform app.cp_notify(s.sale_id, '📬 ' || coalesce(s.khach, s.nguoi_nhan) || ' đã nhận HĐ (' || s.code || ')',
      'Khách nhận ' || array_length(v_ids, 1) || ' HĐ ngày ' || to_char(v_ngay, 'DD/MM/YYYY') || '. Nhắc khách ký và gửi lại 1 bản trước ' || to_char(v_han, 'DD/MM/YYYY') || '.');

  elsif p_act = 'hoan' then
    if s.status not in ('da_gui', 'da_nhan') then raise exception 'Chỉ báo hoàn / thất lạc khi phiếu đã gửi'; end if;
    if v_note is null then raise exception 'Ghi lý do hoàn / thất lạc'; end if;
    update public.out_ships set status = 'hoan', note = concat_ws(' · ', note, 'Hoàn: ' || v_note), status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    perform app.cp_log(p_id, 'hoan', 'Hoàn / thất lạc: ' || v_note);
    perform app.cp_notify(s.sale_id, '↩ Phiếu ' || s.code || ' bị hoàn / thất lạc', coalesce(s.khach, '') || ': ' || v_note || '. Các HĐ đã mở lại để gửi phiếu mới.');

  elsif p_act = 'huy' then
    if s.status not in ('cho_gui', 'da_gui') then raise exception 'Chỉ hủy được phiếu Chờ gửi / Đã gửi (khách nhận rồi thì báo hoàn)'; end if;
    if s.status = 'da_gui' and not app.is_acc() and s.created_by is distinct from auth.uid() then raise exception 'Phiếu đã gửi chỉ người tạo hoặc kế toán hủy'; end if;
    update public.out_ships set status = 'huy', note = concat_ws(' · ', note, 'Hủy' || coalesce(': ' || v_note, '')), status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    perform app.cp_log(p_id, 'huy', 'Hủy phiếu' || coalesce(': ' || v_note, ''));

  elsif p_act = 'lui' then
    if s.status = 'da_gui' then
      update public.out_ships set status = 'cho_gui', ngay_gui = null, status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    elsif s.status = 'da_nhan' then
      update public.out_ships set status = 'da_gui', ngay_nhan = null, han_thu = null, canh_bao_at = null, canh_bao_n = 0, status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    elsif s.status in ('hoan', 'huy') then
      if exists(select 1 from public.out_ship_items si join public.out_ships x on x.id = si.ship_id
                 where si.invoice_id = any(v_ids) and x.id <> p_id and x.status not in ('huy', 'hoan')) then
        raise exception 'HĐ của phiếu này đã được gửi ở phiếu khác — không mở lại được'; end if;
      update public.out_ships set status = case when ngay_nhan is not null then 'da_nhan' when ngay_gui is not null then 'da_gui' else 'cho_gui' end,
             status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    else raise exception 'Phiếu % không lùi được — bỏ xác nhận thu về từng HĐ nếu bấm nhầm', s.code;
    end if;
    perform app.cp_log(p_id, 'lui', 'Lùi trạng thái (bấm nhầm)' || coalesce(': ' || v_note, ''), jsonb_build_object('from', s.status));
  else raise exception 'Thao tác không hợp lệ';
  end if;
  return (select to_jsonb(x) from public.out_ships x where x.id = p_id);
end $$;
grant execute on function public.out_ship_act(uuid, text, jsonb) to authenticated;

-- ---------------- H. Xác nhận thu về bản ký (từng HĐ / cả phiếu) ----------------
/** p_ids null = mọi HĐ của phiếu. p_undo = bỏ xác nhận (bấm nhầm). Đủ HĐ thu về → phiếu "Đã thu về". */
create or replace function public.out_ship_thu(p_id uuid, p_ids uuid[] default null, p_ngay date default null, p_url text default null, p_undo boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare s public.out_ships; t date := app.vn_today(); v_ids uuid[]; v_ngay date := coalesce(p_ngay, app.vn_today()); n int;
begin
  select * into s from public.out_ships where id = p_id for update;
  if s.id is null then raise exception 'Không thấy phiếu chuyển phát'; end if;
  if not (app.is_acc() or app.in_tree(s.sale_id)) then raise exception 'Không có quyền với phiếu này'; end if;
  if p_url is not null and p_url !~ '^https://' then raise exception 'Link file phải là https://'; end if;
  select array_agg(invoice_id) into v_ids from public.out_ship_items where ship_id = p_id and (p_ids is null or invoice_id = any(p_ids));
  if v_ids is null then raise exception 'HĐ không thuộc phiếu này'; end if;
  if not p_undo then
    if s.status not in ('da_gui', 'da_nhan', 'da_thu') then raise exception 'Phiếu chưa gửi — chưa thu về được'; end if;
    if v_ngay > t or v_ngay < coalesce(s.ngay_gui, t) then raise exception 'Ngày thu về % không hợp lệ', to_char(v_ngay, 'DD/MM/YYYY'); end if;
    update public.out_ship_items set thu_at = now(), thu_ngay = v_ngay, thu_by = auth.uid(), thu_url = coalesce(p_url, thu_url)
     where ship_id = p_id and invoice_id = any(v_ids) and thu_at is null;
    get diagnostics n = row_count;
    perform app.cp_doc(v_ids, 'ky', p_url);
    if not exists(select 1 from public.out_ship_items where ship_id = p_id and thu_at is null) then
      update public.out_ships set status = 'da_thu', ngay_thu = (select max(thu_ngay) from public.out_ship_items where ship_id = p_id),
             status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    end if;
    if n > 0 then perform app.cp_log(p_id, 'thu', 'Đã thu về bản ký ' || n || ' HĐ ngày ' || to_char(v_ngay, 'DD/MM/YYYY'), jsonb_build_object('ids', to_jsonb(v_ids), 'url', p_url)); end if;
  else
    update public.out_ship_items set thu_at = null, thu_ngay = null, thu_by = null, thu_url = null where ship_id = p_id and invoice_id = any(v_ids) and thu_at is not null;
    get diagnostics n = row_count;
    perform app.cp_doc(v_ids, 'bo_ky');
    if s.status = 'da_thu' then
      update public.out_ships set status = case when ngay_nhan is not null then 'da_nhan' else 'da_gui' end, ngay_thu = null,
             status_at = now(), status_by = auth.uid(), updated_at = now() where id = p_id;
    end if;
    if n > 0 then perform app.cp_log(p_id, 'bo_thu', 'Bỏ xác nhận thu về ' || n || ' HĐ (bấm nhầm)'); end if;
  end if;
  return (select to_jsonb(x) from public.out_ships x where x.id = p_id);
end $$;
grant execute on function public.out_ship_thu(uuid, uuid[], date, text, boolean) to authenticated;

-- ---------------- I. Danh sách + bộ lọc ----------------
/** p: st (''|mo|cho_gui|da_gui|da_nhan|sap_han|qua_han|da_thu|hoan|huy), sale, q, field (tao|gui|nhan|thu), tu, den, offset, limit */
create or replace function public.out_ships_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := coalesce(nullif(p->>'st', ''), ''); v_sale uuid := nullif(p->>'sale', '')::uuid; v_q text := nullif(btrim(p->>'q'), '');
        v_field text := coalesce(nullif(p->>'field', ''), 'gui'); v_tu date := nullif(p->>'tu', '')::date; v_den date := nullif(p->>'den', '')::date;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 100), 1000);
        t date := app.vn_today(); v_sap int := coalesce((app.cp_cfg()->>'sap_han')::int, 2); c jsonb; r jsonb; n bigint;
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  with b as materialized (
    select s.*, (s.status = 'da_nhan' and s.han_thu <= t) qua_han, (s.status = 'da_nhan' and s.han_thu > t and s.han_thu <= t + v_sap) sap_han,
           case when s.status = 'da_nhan' and s.han_thu <= t then t - s.han_thu end tre
      from public.out_ships s
     where (app.is_acc() or app.in_tree(s.sale_id)) and (v_sale is null or s.sale_id = v_sale)
       and (v_q is null or concat_ws(' ', s.code, s.ma_van_don, s.khach, s.nguoi_nhan, s.sdt, s.dia_chi, s.note,
              (select string_agg(concat_ws(' ', i.code, i.so_hd, i.buyer_name, i.tax_code), ' ') from public.out_ship_items si join public.out_invoices i on i.id = si.invoice_id where si.ship_id = s.id),
              (select concat_ws(' ', cu.sys_username, cu.code, cu.sys_code) from public.customers cu where cu.id = s.customer_id)) ilike '%' || v_q || '%')
       and (v_tu is null and v_den is null or
            (case v_field when 'tao' then (s.created_at at time zone 'Asia/Ho_Chi_Minh')::date when 'nhan' then s.ngay_nhan when 'thu' then s.ngay_thu else s.ngay_gui end)
              between coalesce(v_tu, '2000-01-01') and coalesce(v_den, '2100-01-01')))
  select jsonb_build_object('tat_ca', count(*), 'mo', count(*) filter (where status in ('cho_gui', 'da_gui', 'da_nhan')),
           'cho_gui', count(*) filter (where status = 'cho_gui'), 'da_gui', count(*) filter (where status = 'da_gui'), 'da_nhan', count(*) filter (where status = 'da_nhan'),
           'sap_han', count(*) filter (where sap_han), 'qua_han', count(*) filter (where qua_han), 'da_thu', count(*) filter (where status = 'da_thu'),
           'hoan', count(*) filter (where status = 'hoan'), 'huy', count(*) filter (where status = 'huy')) into c from b;
  with b as materialized (
    select s.*, (s.status = 'da_nhan' and s.han_thu <= t) qua_han, (s.status = 'da_nhan' and s.han_thu > t and s.han_thu <= t + v_sap) sap_han,
           case when s.status = 'da_nhan' and s.han_thu <= t then t - s.han_thu end tre
      from public.out_ships s
     where (app.is_acc() or app.in_tree(s.sale_id)) and (v_sale is null or s.sale_id = v_sale)
       and (v_q is null or concat_ws(' ', s.code, s.ma_van_don, s.khach, s.nguoi_nhan, s.sdt, s.dia_chi, s.note,
              (select string_agg(concat_ws(' ', i.code, i.so_hd, i.buyer_name, i.tax_code), ' ') from public.out_ship_items si join public.out_invoices i on i.id = si.invoice_id where si.ship_id = s.id),
              (select concat_ws(' ', cu.sys_username, cu.code, cu.sys_code) from public.customers cu where cu.id = s.customer_id)) ilike '%' || v_q || '%')
       and (v_tu is null and v_den is null or
            (case v_field when 'tao' then (s.created_at at time zone 'Asia/Ho_Chi_Minh')::date when 'nhan' then s.ngay_nhan when 'thu' then s.ngay_thu else s.ngay_gui end)
              between coalesce(v_tu, '2000-01-01') and coalesce(v_den, '2100-01-01'))),
  f as (select * from b where v_st = '' or v_st = 'mo' and status in ('cho_gui', 'da_gui', 'da_nhan') or v_st = 'qua_han' and qua_han or v_st = 'sap_han' and sap_han
                         or v_st in ('cho_gui', 'da_gui', 'da_nhan', 'da_thu', 'hoan', 'huy') and status = v_st),
  o as (select f.*, row_number() over (order by qua_han desc, tre desc nulls last, (status in ('cho_gui', 'da_gui', 'da_nhan')) desc,
                                         case when status = 'da_nhan' then han_thu end asc nulls last, status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'sale_id', o.sale_id, 'customer_id', o.customer_id, 'buyer_id', o.buyer_id, 'khach', o.khach,
           'nguoi_nhan', o.nguoi_nhan, 'sdt', o.sdt, 'dia_chi', o.dia_chi, 'hang', o.hang, 'ma_van_don', o.ma_van_don, 'status', o.status,
           'ngay_gui', o.ngay_gui, 'ngay_nhan', o.ngay_nhan, 'han_thu', o.han_thu, 'ngay_thu', o.ngay_thu, 'qua_han', o.qua_han, 'sap_han', o.sap_han, 'tre', o.tre,
           'canh_bao_at', o.canh_bao_at, 'canh_bao_n', o.canh_bao_n, 'note', o.note, 'created_by', o.created_by, 'created_at', o.created_at, 'status_at', o.status_at, 'status_by', o.status_by,
           'username', (select cu.sys_username from public.customers cu where cu.id = o.customer_id),
           'items', (select coalesce(jsonb_agg(jsonb_build_object('invoice_id', i.id, 'code', i.code, 'so_hd', i.so_hd, 'ngay_hd', i.ngay_hd, 'buyer_name', i.buyer_name, 'tax_code', i.tax_code,
                       'thu_at', si.thu_at, 'thu_ngay', si.thu_ngay, 'thu_by', si.thu_by, 'thu_url', si.thu_url) order by i.so_hd, i.code), '[]')
                       from public.out_ship_items si join public.out_invoices i on i.id = si.invoice_id where si.ship_id = o.id)) order by o.rn)
           filter (where o.rn > v_off and o.rn <= v_off + v_lim), '[]')
    into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'cfg', app.cp_cfg(), 'today', t);
end $$;
grant execute on function public.out_ships_page(jsonb) to authenticated;

-- ---------------- J. Cảnh báo quá hạn thu về (8:15 sáng, thứ 2 – thứ 7) ----------------
create or replace function app.job_ship_remind() returns int
language plpgsql security definer set search_path = public, app as $$
declare s record; t date := app.vn_today(); v_cfg jsonb := app.cp_cfg(); v_lai int := greatest(coalesce((app.cp_cfg()->>'nhac_lai')::int, 3), 1); n int := 0;
begin
  for s in select x.*, (select count(*) from public.out_ship_items i where i.ship_id = x.id and i.thu_at is null) con
             from public.out_ships x
            where x.status = 'da_nhan' and x.han_thu <= t
              and (x.canh_bao_at is null or (x.canh_bao_at at time zone 'Asia/Ho_Chi_Minh')::date <= t - v_lai) loop
    perform app.cp_notify(s.sale_id, '⏰ Quá hạn thu bản ký HĐ — ' || coalesce(s.khach, s.nguoi_nhan) || ' (' || s.code || ')',
      'Khách nhận ngày ' || to_char(s.ngay_nhan, 'DD/MM/YYYY') || ', hạn ' || to_char(s.han_thu, 'DD/MM/YYYY') || ' (trễ ' || (t - s.han_thu) || ' ngày). Còn '
        || s.con || ' HĐ chưa gửi lại bản ký — liên hệ khách đòi. Nhận được thì bấm "Đã thu về".', true);
    update public.out_ships set canh_bao_at = now(), canh_bao_n = canh_bao_n + 1 where id = s.id;
    insert into public.out_ship_events(ship_id, action, note, actor) values (s.id, 'canh_bao', 'Cảnh báo quá hạn lần ' || (s.canh_bao_n + 1) || ' · trễ ' || (t - s.han_thu) || ' ngày', null);
    n := n + 1;
  end loop;
  return n;
end $$;
do $$ begin perform cron.unschedule('nt_ship_remind'); exception when others then null; end $$;
select cron.schedule('nt_ship_remind', '15 1 * * 1-6', 'select app.job_ship_remind()');

reset search_path;
