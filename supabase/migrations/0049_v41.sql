-- =====================================================================
-- 0049 · Bản 41 (11/11/2026) — Lưu trữ hồ sơ HĐ: bản scan (mềm) + bản cứng
--  · Khách gửi lại bản ký → scan → tải lên ERP → file lưu Google Drive công ty (Apps Script chạy bằng tài khoản của chủ Drive)
--    thư mục ERP_NAMTRUNG/Ho so khach hang/<MST> - <Tên>/HD <năm>/…  ·  HĐ nguyên tắc / mua bán: …/Hop dong NT-MB/…
--  · 1 file scan có thể gồm nhiều loại giấy (scan cả bộ 1 lần): kinds = {hd, ddh, bbgn, hdmb, hdnt, khac}
--  · Đủ hồ sơ mềm của 1 HĐ = HĐ đã ký + ĐĐH + BBGN + (HĐ nguyên tắc của pháp nhân nếu đã ký HĐNT, ngược lại HĐ mua bán của HĐ đó)
--  · Tải scan của HĐ đang nằm trong phiếu chuyển phát chưa thu về → tự xác nhận "Đã thu về"
--  · Bản cứng: đánh dấu đã cất + vị trí (tủ / bìa)
--  · Xem file: qua vé dùng 1 lần như PDF hóa đơn (drive_redeem tra cả bảng scan) — Apps Script không phải cập nhật
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 41');

-- ---------------- A. Bản cứng ----------------
alter table public.out_doc_state add column if not exists cung_at timestamptz;
alter table public.out_doc_state add column if not exists cung_by uuid references public.profiles(id);
alter table public.out_doc_state add column if not exists cung_vi_tri text;

-- ---------------- B. Bảng bản scan ----------------
create table if not exists public.ho_so_scans(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid references public.out_invoices(id) on delete cascade,
  buyer_id uuid references public.out_buyers(id) on delete set null,
  tax_code text,                                    -- MST pháp nhân (giữ khi pháp nhân bị xóa)
  kinds text[] not null check (kinds <@ array['hd', 'ddh', 'bbgn', 'hdmb', 'hdnt', 'khac'] and cardinality(kinds) > 0),
  drive_id text not null, url text,
  file_name text, size_kb int, so_trang int, note text,
  uploaded_by uuid default auth.uid() references public.profiles(id), uploaded_at timestamptz not null default now(),
  deleted_at timestamptz, deleted_by uuid references public.profiles(id),
  check (invoice_id is not null or buyer_id is not null or tax_code is not null)
);
create index if not exists ho_so_scans_inv on public.ho_so_scans(invoice_id) where deleted_at is null;
create index if not exists ho_so_scans_buyer on public.ho_so_scans(buyer_id) where deleted_at is null;
create index if not exists ho_so_scans_mst on public.ho_so_scans(btrim(tax_code)) where deleted_at is null;
alter table public.ho_so_scans enable row level security;
-- Không đọc thẳng bảng (mã file Drive không ra trình duyệt) — dùng ho_so_list / ho_so_status
revoke all on public.ho_so_scans from anon, authenticated;

/** Pháp nhân của 1 HĐ: pháp nhân gắn phiếu → cùng khách + cùng MST → bất kỳ pháp nhân cùng MST */
create or replace function app.hs_buyer(p_inv uuid) returns uuid language sql stable security definer set search_path = public, app as $$
  select b.id from public.out_invoices i join public.out_buyers b
      on b.id = i.buyer_id or btrim(b.tax_code) = btrim(i.tax_code)
   where i.id = p_inv
   order by coalesce(b.id = i.buyer_id, false) desc, (b.customer_id is not distinct from i.customer_id) desc, b.is_default desc, b.created_at limit 1
$$;

/** Quyền xem hồ sơ của 1 pháp nhân: kế toán / admin, sale phụ trách khách (theo cây), hoặc sale có HĐ của MST đó */
create or replace function app.hs_buyer_can(p_buyer uuid, p_mst text) returns boolean language sql stable security definer set search_path = public, app as $$
  select app.is_acc()
      or exists(select 1 from public.out_buyers b join public.customers c on c.id = b.customer_id where b.id = p_buyer and app.in_tree(c.owner_id))
      or exists(select 1 from public.out_invoices i where btrim(i.tax_code) = btrim(coalesce(p_mst, (select tax_code from public.out_buyers where id = p_buyer))) and app.in_tree(i.sale_id))
$$;

create or replace function app.hs_can(s public.ho_so_scans) returns boolean language sql stable security definer set search_path = public, app as $$
  select case when s.invoice_id is not null then exists(select 1 from public.out_invoices i where i.id = s.invoice_id and (app.is_acc() or app.in_tree(i.sale_id)))
              else app.hs_buyer_can(s.buyer_id, s.tax_code) end
$$;

-- ---------------- C. Ghi nhận bản scan (Kế toán / Admin / BGĐ — người được tải file lên Drive) ----------------
/** p: {invoice_id | buyer_id, kinds[], drive_id, url, file_name, size_kb, so_trang, note} */
create or replace function public.ho_so_scan_add(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_inv public.out_invoices; v_buyer uuid := nullif(p->>'buyer_id', '')::uuid; v_kinds text[]; v_id uuid; v_mst text; si record; n_thu int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ lưu bản scan lên Drive'; end if;
  select array_agg(distinct k) into v_kinds from jsonb_array_elements_text(coalesce(p->'kinds', '[]')) k;
  if v_kinds is null then raise exception 'Chọn loại giấy tờ trong file scan'; end if;
  if not v_kinds <@ array['hd', 'ddh', 'bbgn', 'hdmb', 'hdnt', 'khac'] then raise exception 'Loại giấy tờ không hợp lệ'; end if;
  if coalesce(btrim(p->>'drive_id'), '') = '' then raise exception 'Thiếu mã file Drive'; end if;
  if coalesce(p->>'url', '') <> '' and p->>'url' !~ '^https://' then raise exception 'Link file phải là https://'; end if;
  if nullif(p->>'invoice_id', '') is not null then
    select * into v_inv from public.out_invoices where id = (p->>'invoice_id')::uuid;
    if v_inv.id is null then raise exception 'Không thấy HĐ'; end if;
    if v_inv.status <> 'da_ky' then raise exception 'HĐ % chưa ký', coalesce(v_inv.so_hd, v_inv.code); end if;
    v_buyer := coalesce(v_buyer, app.hs_buyer(v_inv.id)); v_mst := btrim(v_inv.tax_code);
  else
    if v_buyer is null then raise exception 'Chọn HĐ hoặc pháp nhân'; end if;
    select btrim(tax_code) into v_mst from public.out_buyers where id = v_buyer;
    if v_mst is null then raise exception 'Không thấy pháp nhân'; end if;
    if not v_kinds <@ array['hdnt', 'hdmb', 'khac'] then raise exception 'Hồ sơ pháp nhân chỉ gồm HĐ nguyên tắc / HĐ mua bán / giấy tờ khác — bản scan của HĐ thì tải ở HĐ đó'; end if;
  end if;
  insert into public.ho_so_scans(invoice_id, buyer_id, tax_code, kinds, drive_id, url, file_name, size_kb, so_trang, note)
  values (v_inv.id, v_buyer, v_mst, v_kinds, btrim(p->>'drive_id'), nullif(p->>'url', ''), left(nullif(btrim(p->>'file_name'), ''), 200),
          nullif(p->>'size_kb', '')::int, nullif(p->>'so_trang', '')::int, nullif(btrim(coalesce(p->>'note', '')), ''))
  returning id into v_id;
  if v_inv.id is not null then
    insert into public.out_events(invoice_id, action, note, data) values (v_inv.id, 'scan', 'Lưu bản scan: ' || array_to_string(v_kinds, ', '), jsonb_build_object('scan', v_id, 'kinds', to_jsonb(v_kinds)));
    if v_kinds <> array['khac'] then
      perform app.cp_doc(array[v_inv.id], 'ky');
      -- HĐ đang trong phiếu chuyển phát chưa thu về → khách đã gửi lại → tự xác nhận thu về
      for si in select s.id from public.out_ship_items i join public.out_ships s on s.id = i.ship_id
                 where i.invoice_id = v_inv.id and i.thu_at is null and s.status in ('da_gui', 'da_nhan') loop
        perform public.out_ship_thu(si.id, array[v_inv.id], null, null, false); n_thu := n_thu + 1;
      end loop;
    end if;
  end if;
  return jsonb_build_object('id', v_id, 'thu', n_thu);
end $$;
grant execute on function public.ho_so_scan_add(jsonb) to authenticated;

/** Xóa bản scan khỏi ERP (file trên Drive giữ nguyên — xóa tay trên Drive nếu cần) */
create or replace function public.ho_so_scan_del(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare s public.ho_so_scans;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ'; end if;
  update public.ho_so_scans set deleted_at = now(), deleted_by = auth.uid() where id = p_id and deleted_at is null returning * into s;
  if s.id is null then raise exception 'Không thấy bản scan'; end if;
  if s.invoice_id is not null then
    insert into public.out_events(invoice_id, action, note, data) values (s.invoice_id, 'scan', 'Gỡ bản scan: ' || array_to_string(s.kinds, ', ') || coalesce(' (' || s.file_name || ')', ''), jsonb_build_object('scan', s.id, 'del', true));
  end if;
end $$;
grant execute on function public.ho_so_scan_del(uuid) to authenticated;

/** Vé xem 1 bản scan (dùng 1 lần, 2 phút) */
create or replace function public.ho_so_scan_ticket(p_id uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare s public.ho_so_scans;
begin
  select * into s from public.ho_so_scans where id = p_id and deleted_at is null;
  if s.id is null or not app.hs_can(s) then raise exception 'Không có quyền xem file này'; end if;
  return app.drive_new_ticket('view', p_id, null, interval '2 minutes');
end $$;
grant execute on function public.ho_so_scan_ticket(uuid) to authenticated;

-- Apps Script đổi vé xem: tra cả PDF hóa đơn lẫn bản scan
create or replace function public.drive_redeem(p_token text, p_ticket text) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
declare t app.drive_tickets; v_drive text; v_tbl text := 'out_invoice_files';
begin
  perform app.backup_check(p_token);
  update app.drive_tickets set used_at = now()
   where token_hash = encode(digest(coalesce(p_ticket, ''), 'sha256'), 'hex') and used_at is null and expires_at > now()
  returning * into t;
  if t.token_hash is null then raise exception 'Vé không hợp lệ hoặc đã hết hạn'; end if;
  if t.kind = 'upload' then return jsonb_build_object('kind', 'upload', 'folder', t.folder); end if;
  select drive_id into v_drive from public.out_invoice_files where id = t.file_id;
  if v_drive is null then select drive_id, 'ho_so_scans' into v_drive, v_tbl from public.ho_so_scans where id = t.file_id and deleted_at is null; end if;
  if v_drive is null then raise exception 'File không còn'; end if;
  insert into public.audit_logs(actor_id, action, table_name, record_id) values (t.user_id, case when v_tbl = 'ho_so_scans' then 'VIEW_SCAN' else 'VIEW_HD_FILE' end, v_tbl, t.file_id::text);
  return jsonb_build_object('kind', 'view', 'drive_id', v_drive);
end $$;
revoke all on function public.drive_redeem(text, text) from public;
grant execute on function public.drive_redeem(text, text) to anon, authenticated;

-- ---------------- D. Danh sách bản scan ----------------
/** p: {invoice_id} → scan của HĐ + HĐ nguyên tắc của pháp nhân · {buyer_id} → hồ sơ pháp nhân: HĐNT / HĐMB + scan mọi HĐ cùng MST */
create or replace function public.ho_so_list(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_inv uuid := nullif(p->>'invoice_id', '')::uuid; v_buyer uuid := nullif(p->>'buyer_id', '')::uuid; v_mst text; v_acc boolean := app.is_acc();
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  if v_inv is not null then
    if not exists(select 1 from public.out_invoices i where i.id = v_inv and (v_acc or app.in_tree(i.sale_id))) then raise exception 'Không có quyền với HĐ này'; end if;
    v_buyer := app.hs_buyer(v_inv); select btrim(tax_code) into v_mst from public.out_invoices where id = v_inv;
  elsif v_buyer is not null then
    select btrim(tax_code) into v_mst from public.out_buyers where id = v_buyer;
    if v_mst is null or not app.hs_buyer_can(v_buyer, v_mst) then raise exception 'Không có quyền với pháp nhân này'; end if;
  else raise exception 'Chọn HĐ hoặc pháp nhân';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'invoice_id', s.invoice_id, 'buyer_id', s.buyer_id, 'kinds', s.kinds, 'file_name', s.file_name, 'size_kb', s.size_kb,
           'so_trang', s.so_trang, 'note', s.note, 'uploaded_by', s.uploaded_by, 'uploaded_at', s.uploaded_at, 'url', case when v_acc then s.url end,
           'so_hd', i.so_hd, 'ngay_hd', i.ngay_hd, 'cap', case when s.invoice_id is null then 'phap_nhan' else 'hd' end) order by s.invoice_id is not null, i.so_hd, s.uploaded_at)
    from public.ho_so_scans s left join public.out_invoices i on i.id = s.invoice_id
   where s.deleted_at is null
     and (v_inv is not null and (s.invoice_id = v_inv or s.invoice_id is null and (s.buyer_id = v_buyer or btrim(s.tax_code) = v_mst) and s.kinds && array['hdnt'])
       or v_inv is null and (s.buyer_id = v_buyer or btrim(s.tax_code) = v_mst) and (s.invoice_id is null or v_acc or app.in_tree(i.sale_id)))), '[]');
end $$;
grant execute on function public.ho_so_list(jsonb) to authenticated;

-- ---------------- E. Tình trạng hồ sơ từng HĐ ----------------
/** Mỗi HĐ: loại đã có scan, loại cần, loại thiếu, đủ chưa, bản cứng. HĐ nguyên tắc tính theo pháp nhân (scan 1 lần dùng cho mọi HĐ) */
create or replace function public.ho_so_status(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('invoice_id', x.id, 'co', x.co, 'can', x.can,
            'thieu', (select coalesce(jsonb_agg(k), '[]') from unnest(x.can) k where not k = any(x.co)), 'du', x.can <@ x.co, 'n', x.n,
            'co_hdnt', x.co_hdnt, 'cung_at', x.cung_at, 'cung_vi_tri', x.cung_vi_tri))
    from (select i.id, d.cung_at, d.cung_vi_tri, b.ma_hdnt is not null co_hdnt,
                 (select count(*) from public.ho_so_scans s where s.invoice_id = i.id and s.deleted_at is null) n,
                 array['hd', 'ddh', 'bbgn', case when b.ma_hdnt is not null then 'hdnt' else 'hdmb' end] can,
                 array(select distinct k from public.ho_so_scans s, unnest(s.kinds) k
                        where s.deleted_at is null and (s.invoice_id = i.id
                              or s.invoice_id is null and 'hdnt' = k and (s.buyer_id = b.id or btrim(s.tax_code) = btrim(i.tax_code)))) co
            from public.out_invoices i
            left join public.out_buyers b on b.id = app.hs_buyer(i.id)
            left join public.out_doc_state d on d.invoice_id = i.id
           where i.id = any(p_ids) and (app.is_acc() or app.in_tree(i.sale_id))) x), '[]');
end $$;
grant execute on function public.ho_so_status(uuid[]) to authenticated;

/** Tình trạng HĐ nguyên tắc của các pháp nhân (màn Pháp nhân nhận HĐ) */
create or replace function public.ho_so_buyer_status(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  return coalesce((select jsonb_object_agg(b.id, jsonb_build_object(
            'hdnt', (select count(*) from public.ho_so_scans s where s.deleted_at is null and s.invoice_id is null and 'hdnt' = any(s.kinds) and (s.buyer_id = b.id or btrim(s.tax_code) = btrim(b.tax_code))),
            'hdmb', (select count(*) from public.ho_so_scans s where s.deleted_at is null and 'hdmb' = any(s.kinds) and (s.buyer_id = b.id or btrim(s.tax_code) = btrim(b.tax_code))),
            'tong', (select count(*) from public.ho_so_scans s where s.deleted_at is null and (s.buyer_id = b.id or btrim(s.tax_code) = btrim(b.tax_code)))))
    from public.out_buyers b where b.id = any(p_ids) and app.hs_buyer_can(b.id, b.tax_code)), '{}');
end $$;
grant execute on function public.ho_so_buyer_status(uuid[]) to authenticated;

-- ---------------- F. Bản cứng ----------------
/** Đánh dấu đã cất bản cứng (kèm vị trí: tủ / bìa / hộp) cho nhiều HĐ. p_undo = bỏ đánh dấu */
create or replace function public.out_doc_cung(p_ids uuid[], p_vi_tri text, p_undo boolean default false) returns int
language plpgsql security definer set search_path = public, app as $$
declare v_ids uuid[]; v_vt text := nullif(regexp_replace(btrim(coalesce(p_vi_tri, '')), '\s+', ' ', 'g'), ''); n int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ'; end if;
  select array_agg(id) into v_ids from public.out_invoices where id = any(p_ids) and status = 'da_ky';
  if v_ids is null then raise exception 'Chưa chọn HĐ đã ký nào'; end if;
  insert into public.out_doc_state(invoice_id) select x from unnest(v_ids) x on conflict do nothing;
  if p_undo then
    update public.out_doc_state set cung_at = null, cung_by = null, cung_vi_tri = null, updated_at = now() where invoice_id = any(v_ids);
  else
    if v_vt is null then raise exception 'Ghi vị trí cất bản cứng (VD: Tủ 1 · Bìa T11/2026)'; end if;
    update public.out_doc_state set cung_at = coalesce(cung_at, now()), cung_by = coalesce(cung_by, auth.uid()), cung_vi_tri = left(v_vt, 120), updated_at = now() where invoice_id = any(v_ids);
  end if;
  get diagnostics n = row_count;
  insert into public.out_events(invoice_id, action, note) select x, 'ban_cung', case when p_undo then 'Bỏ đánh dấu đã cất bản cứng' else 'Cất bản cứng: ' || v_vt end from unnest(v_ids) x;
  return n;
end $$;
grant execute on function public.out_doc_cung(uuid[], text, boolean) to authenticated;

reset search_path;
