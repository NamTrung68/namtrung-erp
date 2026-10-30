-- =====================================================================
-- 0016 · Bản 10: Kế toán – Hóa đơn (đợt 1: đối soát xe APT B1 + HĐ đầu vào B2) · Sao lưu hằng ngày lên Google Drive
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 10');

-- ---------- Cấu hình ----------
insert into public.settings(key, value) values ('accounting', jsonb_build_object(
  'bien_muc_tieu', 0.03, 'bien_nt_min', 0.025, 'bien_nt_max', 0.04, 'dung_sai_bien', 0.001, 'tien_bo_qua', 50000, 'nguong_ghep', 0.65,
  'sale_lanchi', '["huyennk29","yenttt","Yentth"]'::jsonb, 'md_xuat_thang', '["MD2421","MD2744","MD2784","MD2785"]'::jsonb,
  'hs_hop_quy_chuong', '["50","51","52","53","54","55","56","57","58","59","60","61","62","63"]'::jsonb, 'han_sale_gio', 24,
  'approver_ids', '[]'::jsonb,
  'sale_names', '[{"acc":"khoile","names":["Lê Thị Minh Khơi","Khơi Lê"]},{"acc":"trungdv22","names":["Đỗ Văn Trung","Trungdv22"]},
    {"acc":"trangdtk","names":["Đắc Thị Kiều Trang","Trang"]},{"acc":"Linhnt","names":["Nguyễn Thị Linh","Linh NT"]},{"acc":"huevt","names":["Vũ Thị Huệ","Huệ Vũ"]},
    {"acc":"thuyltp","names":["Lê Thị Phương Thúy","Phương Thúy"]},{"acc":"ngocdtb","names":["Đào Bích Ngọc"]},{"acc":"huyenttt","names":["Trần Thị Thanh Huyền","Huyền Trần"]},
    {"acc":"huyennk29","names":[]},{"acc":"yenttt","names":["Yentth"]}]'::jsonb
)) on conflict (key) do nothing;
insert into public.settings(key, value) values ('drive', '{}'::jsonb) on conflict (key) do nothing;

create or replace function public.set_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_old jsonb;
begin
  if not (app.is_admin() or (app.has_role('hcns') and p_key in ('attendance','leave','payroll'))
          or (app.has_role('ke_toan') and p_key in ('vietqr','payroll','quote_defaults','accounting'))) then
    raise exception 'Không có quyền sửa cấu hình %', p_key;
  end if;
  -- Kế toán không tự thêm người duyệt mở chặn: chỉ Admin/BGĐ
  if p_key = 'accounting' and not app.is_admin() then
    select value into v_old from public.settings where key = p_key;
    p_value := jsonb_set(p_value, '{approver_ids}', coalesce(v_old->'approver_ids', '[]'));
  end if;
  select value into v_old from public.settings where key = p_key;
  insert into public.settings(key, value, updated_by) values (p_key, p_value, auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  insert into public.settings_history(key, old_value, new_value, changed_by) values (p_key, v_old, p_value, auth.uid());
end $$;

create or replace function app.is_acc() returns boolean language sql stable security definer set search_path = public, app as $$
  select app.has_role('admin','bgd','ke_toan')
$$;
create or replace function app.is_acc_approver() returns boolean language sql stable security definer set search_path = public, app as $$
  select app.is_admin() or auth.uid()::text in (select jsonb_array_elements_text(coalesce(app.setting('accounting')->'approver_ids', '[]')))
$$;

-- ---------- Bảng ----------
create table if not exists public.acc_trucks(
  id uuid primary key default gen_random_uuid(),
  name text not null,                              -- VD: Xe 25/10/2026
  truck_date date,
  files jsonb not null default '{}',               -- tên file đã nạp
  stats jsonb not null default '{}',
  warnings text[] not null default '{}',
  status text not null default 'open' check (status in ('open','closed')),
  created_by uuid default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.acc_lines(
  id uuid primary key default gen_random_uuid(),
  truck_id uuid not null references public.acc_trucks(id) on delete cascade,
  line_key text not null,
  ma_dong text, md text, sale_name text, sale_acc text, sale_id uuid references public.profiles(id), ma_kh text,
  sys_row int, ten_ht text, sl_ht numeric, dvt_ht text, gia_khach numeric, nk_ht numeric,
  apt_stt int, hh text, dh text, sale_apt text, ten_apt text, sl_apt numeric, dvt_apt text, gia_nhap numeric, gia_note numeric, note_apt text, nk_apt numeric, vat numeric,
  tk_row int, ten_tk text, hs text, sl_tk numeric, dvt_tk text, gia_tk_nh numeric, nk_tk numeric, tnk_dv numeric, md_header text,
  luong text not null, gia_ap_dung numeric, gia_de_xuat numeric, bien_nt numeric, tt_apt numeric, tt_khach numeric,
  status text not null check (status in ('ok','blocked','replied','pending_approval','approved','info')),
  level int not null default 3, issues text[] not null default '{}', notes text[] not null default '{}', phan_hoi text, match_score numeric,
  due_at timestamptz,
  reply text check (reply in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet')), reply_price numeric, reply_note text, replied_by uuid references public.profiles(id), replied_at timestamptz,
  approved_by uuid references public.profiles(id), approved_at timestamptz, approve_note text,
  inv_id uuid, inv_no text, inv_stt int, inv_price numeric, inv_qty numeric, inv_amount numeric, inv_result text,
  updated_at timestamptz not null default now(),
  unique (truck_id, line_key)
);
create index if not exists acc_lines_sale on public.acc_lines(sale_id, status);
create index if not exists acc_lines_hh on public.acc_lines(hh);
create index if not exists acc_lines_md on public.acc_lines(md);
create table if not exists public.acc_invoices(
  id uuid primary key default gen_random_uuid(),
  ky_hieu text not null, so_hd text not null, ngay date, mst_ban text, ten_ban text, mst_mua text, ten_mua text,
  tong_truoc_thue numeric, tien_thue numeric, tong numeric, file_name text,
  stats jsonb not null default '{}',
  created_by uuid default auth.uid() references public.profiles(id), created_at timestamptz not null default now(),
  unique (mst_ban, ky_hieu, so_hd)
);
create table if not exists public.acc_invoice_lines(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.acc_invoices(id) on delete cascade,
  stt int not null, hh text, ten text, dvt text, sl numeric, dg numeric, tt numeric, vat text,
  line_id uuid references public.acc_lines(id) on delete set null, result text not null,
  unique (invoice_id, stt)
);
create table if not exists public.acc_events(
  id bigint generated always as identity primary key,
  line_id uuid references public.acc_lines(id) on delete cascade,
  truck_id uuid references public.acc_trucks(id) on delete cascade,
  action text not null, note text, data jsonb,
  actor uuid default auth.uid() references public.profiles(id), at timestamptz not null default now()
);
create index if not exists acc_events_line on public.acc_events(line_id, at desc);

alter table public.acc_trucks enable row level security;
alter table public.acc_lines enable row level security;
alter table public.acc_invoices enable row level security;
alter table public.acc_invoice_lines enable row level security;
alter table public.acc_events enable row level security;
drop policy if exists acc_trucks_read on public.acc_trucks;
create policy acc_trucks_read on public.acc_trucks for select to authenticated using (app.is_acc() or app.is_acc_approver() or exists(select 1 from public.acc_lines l where l.truck_id = acc_trucks.id and app.in_tree(l.sale_id)));
drop policy if exists acc_trucks_write on public.acc_trucks;
create policy acc_trucks_write on public.acc_trucks for all to authenticated using (app.is_acc()) with check (app.is_acc());
drop policy if exists acc_lines_read on public.acc_lines;
create policy acc_lines_read on public.acc_lines for select to authenticated using (app.is_acc() or app.in_tree(sale_id) or (app.is_acc_approver() and status = 'pending_approval'));
drop policy if exists acc_lines_write on public.acc_lines;
create policy acc_lines_write on public.acc_lines for all to authenticated using (app.is_acc()) with check (app.is_acc());
drop policy if exists acc_inv_all on public.acc_invoices;
create policy acc_inv_all on public.acc_invoices for all to authenticated using (app.is_acc()) with check (app.is_acc());
drop policy if exists acc_invl_all on public.acc_invoice_lines;
create policy acc_invl_all on public.acc_invoice_lines for all to authenticated using (app.is_acc()) with check (app.is_acc());
drop policy if exists acc_ev_read on public.acc_events;
create policy acc_ev_read on public.acc_events for select to authenticated using (app.is_acc() or exists(select 1 from public.acc_lines l where l.id = acc_events.line_id and (app.in_tree(l.sale_id) or app.is_acc_approver())));
grant select, insert, update, delete on public.acc_trucks, public.acc_lines, public.acc_invoices, public.acc_invoice_lines to authenticated;
grant select on public.acc_events to authenticated;

-- Ghép sale trong file với nhân sự: tên trong file / họ tên / mã NV (không dấu, không phân biệt hoa thường)
create or replace function app.match_sale(p_name text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.match_staff(p_name), (
    select p.id from public.profiles p where app.is_assigned(p_name)
       and app.norm_text(p_name) = any(select app.norm_text(x) from unnest(p.sale_aliases || p.full_name) x) limit 1))
$$;

-- ---------- Lưu kết quả đối soát 1 xe (nạp lại: giữ trả lời của sale theo line_key) ----------
create or replace function public.acc_truck_save(p_truck uuid, p_info jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := p_truck; r jsonb; v_sale uuid; v_old public.acc_lines; v_status text; v_due timestamptz;
        h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); n_block int; s record; v_keys text[] := '{}';
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán được nạp đối soát'; end if;
  if v_id is null then
    insert into public.acc_trucks(name, truck_date, files, stats, warnings)
    values (p_info->>'name', nullif(p_info->>'truck_date','')::date, coalesce(p_info->'files','{}'), coalesce(p_info->'stats','{}'),
            coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), '{}'))
    returning id into v_id;
  else
    update public.acc_trucks set name = coalesce(p_info->>'name', name), truck_date = coalesce(nullif(p_info->>'truck_date','')::date, truck_date),
      files = coalesce(p_info->'files', files), stats = coalesce(p_info->'stats', stats),
      warnings = coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), warnings), updated_at = now() where id = v_id;
  end if;
  for r in select * from jsonb_array_elements(p_lines) loop
    v_keys := v_keys || (r->>'line_key');
    v_sale := coalesce(nullif(r->>'sale_id','')::uuid, app.match_sale(r->>'sale_name'), app.match_sale(r->>'sale_acc'));
    select * into v_old from public.acc_lines where truck_id = v_id and line_key = r->>'line_key';
    v_status := r->>'status';
    -- Đã được duyệt mở chặn thì giữ; sale đã trả lời mà vẫn chặn → giữ trạng thái đã trả lời
    if v_old.id is not null and v_status = 'blocked' and v_old.status in ('approved','replied','pending_approval') then v_status := v_old.status; end if;
    v_due := case when v_status = 'blocked' then coalesce(v_old.due_at, now() + make_interval(hours => h)) else null end;
    insert into public.acc_lines as l(truck_id, line_key, ma_dong, md, sale_name, sale_acc, sale_id, ma_kh, sys_row, ten_ht, sl_ht, dvt_ht, gia_khach, nk_ht,
      apt_stt, hh, dh, sale_apt, ten_apt, sl_apt, dvt_apt, gia_nhap, gia_note, note_apt, nk_apt, vat, tk_row, ten_tk, hs, sl_tk, dvt_tk, gia_tk_nh, nk_tk, tnk_dv, md_header,
      luong, gia_ap_dung, gia_de_xuat, bien_nt, tt_apt, tt_khach, status, level, issues, notes, phan_hoi, match_score, due_at, updated_at)
    select v_id, x.line_key, x.ma_dong, x.md, x.sale_name, x.sale_acc, v_sale, x.ma_kh, x.sys_row, x.ten_ht, x.sl_ht, x.dvt_ht, x.gia_khach, x.nk_ht,
      x.apt_stt, x.hh, x.dh, x.sale_apt, x.ten_apt, x.sl_apt, x.dvt_apt, x.gia_nhap, x.gia_note, x.note_apt, x.nk_apt, x.vat, x.tk_row, x.ten_tk, x.hs, x.sl_tk, x.dvt_tk, x.gia_tk_nh, x.nk_tk, x.tnk_dv, x.md_header,
      x.luong, x.gia_ap_dung, x.gia_de_xuat, x.bien_nt, x.tt_apt, x.tt_khach, v_status, x.level, coalesce(x.issues, '{}'), coalesce(x.notes, '{}'), x.phan_hoi, x.match_score, v_due, now()
    from jsonb_populate_record(null::public.acc_lines, r) x
    on conflict (truck_id, line_key) do update set ma_dong = excluded.ma_dong, md = excluded.md, sale_name = excluded.sale_name, sale_acc = excluded.sale_acc, sale_id = excluded.sale_id,
      ma_kh = excluded.ma_kh, sys_row = excluded.sys_row, ten_ht = excluded.ten_ht, sl_ht = excluded.sl_ht, dvt_ht = excluded.dvt_ht, gia_khach = excluded.gia_khach, nk_ht = excluded.nk_ht,
      apt_stt = excluded.apt_stt, hh = excluded.hh, dh = excluded.dh, sale_apt = excluded.sale_apt, ten_apt = excluded.ten_apt, sl_apt = excluded.sl_apt, dvt_apt = excluded.dvt_apt,
      gia_nhap = excluded.gia_nhap, gia_note = excluded.gia_note, note_apt = excluded.note_apt, nk_apt = excluded.nk_apt, vat = excluded.vat, tk_row = excluded.tk_row, ten_tk = excluded.ten_tk,
      hs = excluded.hs, sl_tk = excluded.sl_tk, dvt_tk = excluded.dvt_tk, gia_tk_nh = excluded.gia_tk_nh, nk_tk = excluded.nk_tk, tnk_dv = excluded.tnk_dv, md_header = excluded.md_header,
      luong = excluded.luong, gia_ap_dung = excluded.gia_ap_dung, gia_de_xuat = excluded.gia_de_xuat, bien_nt = excluded.bien_nt, tt_apt = excluded.tt_apt, tt_khach = excluded.tt_khach,
      status = excluded.status, level = excluded.level, issues = excluded.issues, notes = excluded.notes, phan_hoi = excluded.phan_hoi, match_score = excluded.match_score,
      due_at = excluded.due_at, updated_at = now();
  end loop;
  -- Dòng cũ không còn trong lần nạp mới → xóa (đã có nhật ký)
  delete from public.acc_lines where truck_id = v_id and line_key <> all(v_keys);
  insert into public.acc_events(truck_id, action, note, data) values (v_id, case when p_truck is null then 'import' else 'reimport' end, p_info->>'name', p_info->'stats');
  -- Báo sale có dòng bị chặn
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', coalesce(p_info->>'name','') || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
  select count(*) into n_block from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is null;
  if n_block > 0 then perform app.notify_roles(array['ke_toan'], 'acc', n_block || ' dòng bị chặn chưa ghép được sale', p_info->>'name', '#/acc?truck=' || v_id); end if;
  return v_id;
end $$;
grant execute on function public.acc_truck_save(uuid, jsonb, jsonb) to authenticated;

-- ---------- Sale trả lời dòng bị chặn ----------
create or replace function public.acc_line_reply(p_id uuid, p_reply text, p_price numeric default null, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; v_status text;
begin
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if not (app.is_acc() or app.in_tree(l.sale_id)) then raise exception 'Dòng này không thuộc khách của bạn'; end if;
  if l.status not in ('blocked','replied') then raise exception 'Dòng không ở trạng thái chờ sale'; end if;
  if p_reply not in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet') then raise exception 'Lựa chọn không hợp lệ'; end if;
  if p_reply = 'de_xuat_gia' and coalesce(p_price, 0) <= 0 then raise exception 'Nhập giá đề xuất'; end if;
  if p_reply = 'xin_duyet' and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do xin duyệt ngoại lệ'; end if;
  v_status := case when p_reply = 'xin_duyet' then 'pending_approval' else 'replied' end;
  update public.acc_lines set reply = p_reply, reply_price = p_price, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(), status = v_status, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'reply', p_note, jsonb_build_object('reply', p_reply, 'price', p_price));
  if p_reply = 'xin_duyet' then
    perform app.notify(x::uuid, 'acc', 'Xin duyệt ngoại lệ HĐ: ' || coalesce(l.md, 'dòng không có đơn'), left(coalesce(l.ten_apt, l.ten_ht, ''), 80) || ' — ' || p_note, '#/acc/approve')
      from jsonb_array_elements_text(coalesce(app.setting('accounting')->'approver_ids', '[]')) x;
  end if;
end $$;
grant execute on function public.acc_line_reply(uuid, text, numeric, text) to authenticated;

-- ---------- Người được cấp quyền duyệt mở chặn ----------
create or replace function public.acc_line_approve(p_id uuid, p_ok boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines;
begin
  if not app.is_acc_approver() then raise exception 'Bạn không có quyền duyệt mở chặn'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if l.status not in ('pending_approval','blocked','replied') then raise exception 'Dòng không chờ duyệt'; end if;
  if not p_ok and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do từ chối'; end if;
  update public.acc_lines set status = case when p_ok then 'approved' else 'blocked' end, approved_by = auth.uid(), approved_at = now(), approve_note = nullif(btrim(p_note), ''),
    phan_hoi = case when p_ok then coalesce(case when l.reply_price > 0 then 'XUẤT GIÁ ' || to_char(l.reply_price, 'FM999G999G999') end, 'CHỐT (duyệt ngoại lệ)') else phan_hoi end,
    due_at = case when p_ok then null else now() + interval '24 hours' end, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, case when p_ok then 'approve' else 'reject' end, p_note);
  perform app.notify(l.sale_id, 'acc', case when p_ok then 'Đã duyệt mở chặn: ' else 'Từ chối mở chặn: ' end || coalesce(l.md, ''), p_note, '#/acc/mine');
end $$;
grant execute on function public.acc_line_approve(uuid, boolean, text) to authenticated;

-- ---------- Kế toán chốt / trả lại dòng ----------
create or replace function public.acc_line_set(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if p_status not in ('ok','blocked') then raise exception 'Trạng thái không hợp lệ'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  update public.acc_lines set status = p_status, due_at = case when p_status = 'blocked' then now() + interval '24 hours' end,
    phan_hoi = case when p_status = 'ok' then coalesce(case when l.reply = 'de_xuat_gia' and l.reply_price > 0 then 'XUẤT GIÁ ' || to_char(l.reply_price, 'FM999G999G999') end,
                    case when l.phan_hoi like 'CHỜ SALE%' then 'CHỐT' else l.phan_hoi end) else 'CHỜ SALE — chưa xuất' end,
    updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'set_' || p_status, p_note);
  if p_status = 'blocked' then perform app.notify(l.sale_id, 'acc', 'Kế toán trả lại dòng HĐ: ' || coalesce(l.md, ''), p_note, '#/acc/mine'); end if;
end $$;
grant execute on function public.acc_line_set(uuid, text, text) to authenticated;

-- ---------- HĐ đầu vào (XML): lưu + ghi kết quả vào dòng đối soát ----------
create or replace function public.acc_invoice_save(p_inv jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_id uuid; r jsonb;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  insert into public.acc_invoices as i(ky_hieu, so_hd, ngay, mst_ban, ten_ban, mst_mua, ten_mua, tong_truoc_thue, tien_thue, tong, file_name, stats)
  values (p_inv->>'ky_hieu', p_inv->>'so_hd', nullif(p_inv->>'ngay','')::date, p_inv->>'mst_ban', p_inv->>'ten_ban', p_inv->>'mst_mua', p_inv->>'ten_mua',
          (p_inv->>'tong_truoc_thue')::numeric, (p_inv->>'tien_thue')::numeric, (p_inv->>'tong')::numeric, p_inv->>'file_name', coalesce(p_inv->'stats','{}'))
  on conflict (mst_ban, ky_hieu, so_hd) do update set ngay = excluded.ngay, tong_truoc_thue = excluded.tong_truoc_thue, tien_thue = excluded.tien_thue, tong = excluded.tong,
    file_name = excluded.file_name, stats = excluded.stats
  returning id into v_id;
  update public.acc_lines set inv_id = null, inv_no = null, inv_stt = null, inv_price = null, inv_qty = null, inv_amount = null, inv_result = null where inv_id = v_id;
  delete from public.acc_invoice_lines where invoice_id = v_id;
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into public.acc_invoice_lines(invoice_id, stt, hh, ten, dvt, sl, dg, tt, vat, line_id, result)
    values (v_id, (r->>'stt')::int, r->>'hh', r->>'ten', r->>'dvt', (r->>'sl')::numeric, (r->>'dg')::numeric, (r->>'tt')::numeric, r->>'vat', nullif(r->>'line_id','')::uuid, r->>'result');
    if nullif(r->>'line_id','') is not null then
      update public.acc_lines set inv_id = v_id, inv_no = p_inv->>'so_hd', inv_stt = (r->>'stt')::int, inv_price = (r->>'dg')::numeric, inv_qty = (r->>'sl')::numeric,
        inv_amount = (r->>'tt')::numeric, inv_result = r->>'result', updated_at = now() where id = (r->>'line_id')::uuid;
    end if;
  end loop;
  if exists(select 1 from public.acc_invoice_lines where invoice_id = v_id and result in ('khong_don','gia_khach_0','lech')) then
    perform app.telegram('acc_invoice', '🧾 HĐ APT <b>' || app.esc(p_inv->>'so_hd') || '</b>: ' ||
      (select count(*) from public.acc_invoice_lines where invoice_id = v_id and result in ('khong_don','gia_khach_0')) || ' dòng chưa có đơn/giá khách, ' ||
      (select count(*) from public.acc_invoice_lines where invoice_id = v_id and result = 'lech') || ' dòng lệch giá/SL.');
  end if;
  return v_id;
end $$;
grant execute on function public.acc_invoice_save(jsonb, jsonb) to authenticated;

-- Cho phép Kế toán ghép "tên trong file" qua hàm acc_set_sale_alias (chỉ đổi sale_aliases)
create or replace function app.guard_profile() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if auth.uid() is null then return new; end if; -- chạy từ hệ thống
  if new.roles is distinct from old.roles and not app.is_admin() then
    if not app.has_role('hcns') or new.roles && array['admin','bgd'] or old.roles && array['admin','bgd'] then
      raise exception 'Không có quyền đổi vai trò';
    end if;
  end if;
  if (new.manager_id, new.job_level, new.org_unit_id, new.status, new.email, new.employee_code, new.work_schedule, new.is_new_hire)
     is distinct from (old.manager_id, old.job_level, old.org_unit_id, old.status, old.email, old.employee_code, old.work_schedule, old.is_new_hire)
     and not app.has_role('admin','bgd','hcns') then
    raise exception 'Chỉ HCNS/Admin được sửa thông tin tổ chức';
  end if;
  if new.sale_aliases is distinct from old.sale_aliases and not app.has_role('admin','bgd','hcns')
     and coalesce(current_setting('nt.alias_ok', true), '') <> '1' then
    raise exception 'Chỉ HCNS/Admin/Kế toán được sửa tên trong file';
  end if;
  if new.manager_id = new.id then raise exception 'Không thể tự làm quản lý của mình'; end if;
  return new;
end $$;

-- ---------- Ghép tên sale trong file với nhân sự (kế toán tự làm) ----------
create or replace function public.acc_set_sale_alias(p_profile uuid, p_names text[])
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.is_acc() or app.has_role('hcns')) then raise exception 'Không có quyền'; end if;
  perform set_config('nt.alias_ok', '1', true);
  -- gỡ tên này khỏi người khác để không trùng
  update public.profiles set sale_aliases = array(select x from unnest(sale_aliases) x where app.norm_text(x) <> all(select app.norm_text(y) from unnest(p_names) y))
   where id <> p_profile and sale_aliases && p_names;
  update public.profiles set sale_aliases = array(select distinct x from unnest(sale_aliases || p_names) x where btrim(x) <> '') where id = p_profile;
  perform set_config('nt.alias_ok', '', true);
  -- Gắn lại các dòng đối soát mang tên này (không cần nạp lại file); bỏ lỗi "chưa ghép", hết lỗi thì tự chốt
  update public.acc_lines l set sale_id = p_profile, updated_at = now(),
    issues = array(select x from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%'),
    status = case when l.status = 'blocked' and not exists(select 1 from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%')
                  then case when l.luong in ('A','E') then 'ok' else 'info' end else l.status end,
    due_at = case when l.status = 'blocked' and not exists(select 1 from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%') then null else l.due_at end,
    phan_hoi = case when l.status = 'blocked' and l.apt_stt is not null and l.luong = 'A' and not exists(select 1 from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%')
                    then case when l.gia_note is not null and abs(l.gia_note - coalesce(l.gia_nhap, 0)) > 0.5 then 'XUẤT GIÁ ' || to_char(l.gia_note, 'FM999G999G999')
                              when l.gia_de_xuat is not null then 'XUẤT GIÁ ' || to_char(l.gia_de_xuat, 'FM999G999G999') else 'CHỐT' end
                    else l.phan_hoi end
   where (l.sale_id is null or l.sale_id <> p_profile)
     and app.norm_text(coalesce(l.sale_name, '')) = any(select app.norm_text(y) from unnest(p_names) y);
end $$;
grant execute on function public.acc_set_sale_alias(uuid, text[]) to authenticated;

create or replace function public.acc_sale_directory()
returns table(id uuid, full_name text, sale_aliases text[]) language sql stable security definer set search_path = public, app as $$
  select id, full_name, sale_aliases from public.profiles where status = 'active' and (app.is_acc() or app.has_role('hcns')) order by full_name
$$;
grant execute on function public.acc_sale_directory() to authenticated;

-- ---------- Nhắc hạn: dòng chặn quá hạn ----------
create or replace function app.job_acc_remind() returns void language plpgsql security definer set search_path = public, app as $$
declare s record; n int;
begin
  for s in select sale_id, count(*) c from public.acc_lines where status = 'blocked' and due_at < now() and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Quá hạn: ' || s.c || ' dòng HĐ APT chưa xử lý', 'Mở Kế toán – Hóa đơn → Việc của tôi', '#/acc/mine');
  end loop;
  select count(*) into n from public.acc_lines where status = 'blocked' and due_at < now();
  if n > 0 then perform app.telegram('acc_overdue', '⏰ ' || n || ' dòng HĐ APT quá hạn sale chưa xử lý.'); end if;
end $$;
do $$ begin perform cron.unschedule('nt_acc_remind'); exception when others then null; end $$;
select cron.schedule('nt_acc_remind', '30 1,7 * * 1-6', 'select app.job_acc_remind()');

-- ---------- Sao lưu hằng ngày lên Google Drive (Apps Script gọi bằng mã bí mật) ----------
create or replace function public.backup_set_token(p_token text) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  if length(coalesce(p_token, '')) < 32 then raise exception 'Mã quá ngắn'; end if;
  insert into app.secrets(key, value, updated_by) values ('backup_token_hash', encode(digest(p_token, 'sha256'), 'hex'), auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;
grant execute on function public.backup_set_token(text) to authenticated;

create or replace function public.backup_export(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_hash text; t record; out jsonb := '{}'; v jsonb;
begin
  select value into v_hash from app.secrets where key = 'backup_token_hash';
  if v_hash is null or encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') <> v_hash then
    perform pg_sleep(1); raise exception 'Sai mã sao lưu';
  end if;
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' order by 1 loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x', t.relname) into v;
    out := out || jsonb_build_object(t.relname, v);
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('BACKUP_DRIVE', 'all', jsonb_build_object('tables', (select count(*) from jsonb_object_keys(out))));
  update public.settings set value = value || jsonb_build_object('last_backup_at', now()) where key = 'drive';
  return jsonb_build_object('generated_at', now(), 'version', 1, 'tables', out);
end $$;
revoke all on function public.backup_export(text) from public;
grant execute on function public.backup_export(text) to anon, authenticated;

-- Khôi phục 1 bảng từ file sao lưu Drive (Admin; ghi đè theo khóa chính, dòng mới tạo sau giữ nguyên)
create or replace function public.backup_restore_json(p_table text, p_rows jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare cols text; pk text; upd text; n bigint;
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  if to_regclass(format('public.%I', p_table)) is null then raise exception 'Không có bảng %', p_table; end if;
  select string_agg(format('%I', a.attname), ', ' order by a.attnum) into cols
    from pg_attribute a where a.attrelid = format('public.%I', p_table)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
  select string_agg(format('%I', a.attname), ', ') into pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = format('public.%I', p_table)::regclass and i.indisprimary;
  if pk is null then raise exception 'Bảng % không có khóa chính', p_table; end if;
  select string_agg(format('%1$I = excluded.%1$I', x), ', ') into upd
    from unnest(string_to_array(replace(cols, '"', ''), ', ')) x where x <> all(string_to_array(replace(pk, '"', ''), ', '));
  execute format('alter table public.%I disable trigger user', p_table);
  execute format('insert into public.%I (%s) overriding system value select %s from jsonb_populate_recordset(null::public.%I, $1) on conflict (%s) do %s',
                 p_table, cols, cols, p_table, pk, case when upd is null then 'nothing' else 'update set ' || upd end) using p_rows;
  get diagnostics n = row_count;
  execute format('alter table public.%I enable trigger user', p_table);
  insert into public.audit_logs(action, table_name, diff) values ('RESTORE_DRIVE', p_table, jsonb_build_object('rows', n));
  return n;
end $$;
revoke all on function public.backup_restore_json(text, jsonb) from public, anon;
grant execute on function public.backup_restore_json(text, jsonb) to authenticated;

create or replace function public.set_drive(p_value jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  insert into public.settings(key, value, updated_by) values ('drive', p_value, auth.uid())
    on conflict (key) do update set value = public.settings.value || excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;
grant execute on function public.set_drive(jsonb) to authenticated;

reset search_path;
