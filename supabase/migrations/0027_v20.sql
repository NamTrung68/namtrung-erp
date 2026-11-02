-- =====================================================================
-- 0027 · Bản 20: File PDF hóa đơn (nháp / đã ký) lưu trên Google Drive
--  · Kế toán / anh tải PDF hàng loạt → ghép phiếu xuất HĐ theo MST + tổng tiền (+ số HĐ khi đã ký)
--  · File nằm kín trên Drive (không chia sẻ). Supabase chỉ giữ mã file.
--  · Xem file bằng VÉ dùng 1 lần, hết hạn nhanh, gắn đúng file + người xin; Apps Script hỏi lại Supabase rồi mới trả file
--  · Tải file lên Drive cũng bằng vé → bỏ khóa tải lên cố định (upload_key) trong Cấu hình
--  · Nháp v1, v2…: bản mới → sale được báo, xác nhận "khách OK" của bản cũ tự hủy; bản đã ký → phiếu "Đã ký", điền số HĐ
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 20');

-- ---------- Bảng file ----------
create table if not exists public.out_invoice_files(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.out_invoices(id) on delete cascade,
  kind text not null check (kind in ('nhap','ky')),
  version int not null,
  drive_id text not null,
  file_name text, size_kb int, tong numeric, mst text, so_hd text, ky_hieu text, ngay date,
  note text,
  uploaded_by uuid default auth.uid() references public.profiles(id), uploaded_at timestamptz not null default now(),
  sent_at timestamptz, sent_by uuid references public.profiles(id),
  unique (invoice_id, kind, version)
);
create index if not exists out_invoice_files_inv on public.out_invoice_files(invoice_id, kind, version desc);
alter table public.out_invoice_files enable row level security;
-- Không cấp quyền đọc bảng trực tiếp: mọi truy cập qua hàm bên dưới (mã file Drive không lộ ra trình duyệt)
revoke all on public.out_invoice_files from anon, authenticated;

-- ---------- Vé truy cập Drive ----------
create table if not exists app.drive_tickets(
  token_hash text primary key,
  kind text not null check (kind in ('view','upload')),
  file_id uuid, folder text, user_id uuid,
  created_at timestamptz not null default now(), expires_at timestamptz not null, used_at timestamptz
);
create index if not exists drive_tickets_exp on app.drive_tickets(expires_at);
revoke all on app.drive_tickets from anon, authenticated;

create or replace function app.drive_new_ticket(p_kind text, p_file uuid, p_folder text, p_ttl interval) returns text
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_tok text := encode(gen_random_bytes(24), 'hex');
begin
  delete from app.drive_tickets where expires_at < now() - interval '1 day';
  insert into app.drive_tickets(token_hash, kind, file_id, folder, user_id, expires_at)
  values (encode(digest(v_tok, 'sha256'), 'hex'), p_kind, p_file, p_folder, auth.uid(), now() + p_ttl);
  return v_tok;
end $$;

-- Tổng tiền thanh toán của phiếu (tiền hàng + thuế, làm tròn từng dòng như mẫu MISA)
create or replace function app.out_inv_total(p_id uuid) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(round(l.sl * l.don_gia) + round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))), 0)
    from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = p_id
$$;

-- Vé tải lên (Kế toán / Admin / BGĐ). 1 vé cho 1 file, theo đúng thư mục xin
create or replace function public.drive_upload_tickets(p_folders text[]) returns text[]
language plpgsql security definer set search_path = public, app as $$
declare f text; r text[] := '{}';
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin được lưu file lên Drive'; end if;
  if coalesce(array_length(p_folders, 1), 0) = 0 or array_length(p_folders, 1) > 300 then raise exception 'Số file không hợp lệ'; end if;
  foreach f in array p_folders loop
    f := regexp_replace(coalesce(f, 'Khac'), '\.\.+', '', 'g');
    r := r || app.drive_new_ticket('upload', null, left(f, 200), interval '30 minutes');
  end loop;
  return r;
end $$;
grant execute on function public.drive_upload_tickets(text[]) to authenticated;

-- Vé xem 1 file: chỉ người có quyền với phiếu (sale của phiếu, cấp trên theo cây nhân sự, Kế toán / Admin)
create or replace function public.out_file_ticket(p_file uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare v_sale uuid; v_ok boolean;
begin
  select i.sale_id, true into v_sale, v_ok from public.out_invoice_files f join public.out_invoices i on i.id = f.invoice_id where f.id = p_file;
  if v_ok is null or not (app.is_acc() or app.in_tree(v_sale)) then raise exception 'Không có quyền xem file này'; end if;
  return app.drive_new_ticket('view', p_file, null, interval '2 minutes');
end $$;
grant execute on function public.out_file_ticket(uuid) to authenticated;

-- Apps Script đổi vé (kèm mã bí mật của Apps Script). Vé dùng 1 lần.
create or replace function public.drive_redeem(p_token text, p_ticket text) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
declare t app.drive_tickets; v_drive text;
begin
  perform app.backup_check(p_token);
  update app.drive_tickets set used_at = now()
   where token_hash = encode(digest(coalesce(p_ticket, ''), 'sha256'), 'hex') and used_at is null and expires_at > now()
  returning * into t;
  if t.token_hash is null then raise exception 'Vé không hợp lệ hoặc đã hết hạn'; end if;
  if t.kind = 'upload' then return jsonb_build_object('kind', 'upload', 'folder', t.folder); end if;
  select drive_id into v_drive from public.out_invoice_files where id = t.file_id;
  if v_drive is null then raise exception 'File không còn'; end if;
  insert into public.audit_logs(actor_id, action, table_name, record_id) values (t.user_id, 'VIEW_HD_FILE', 'out_invoice_files', t.file_id::text);
  return jsonb_build_object('kind', 'view', 'drive_id', v_drive);
end $$;
revoke all on function public.drive_redeem(text, text) from public;
grant execute on function public.drive_redeem(text, text) to anon, authenticated;

-- ---------- Khóa tải lên cố định: bỏ ----------
update public.settings set value = value - 'upload_key' where key = 'drive';
create or replace function public.set_drive(p_value jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  insert into public.settings(key, value, updated_by) values ('drive', coalesce(p_value, '{}') - 'upload_key', auth.uid())
    on conflict (key) do update set value = (public.settings.value || excluded.value) - 'upload_key', updated_at = now(), updated_by = auth.uid();
end $$;
grant execute on function public.set_drive(jsonb) to authenticated;

-- ---------- Ghép file với phiếu ----------
-- p_rows: [{i, kind:'nhap'|'ky', mst, tong, so_hd, ky_hieu, name}]
create or replace function public.out_file_match(p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb; out jsonb := '[]'; v_mst text; v_tong numeric; v_kind text; v_so text; cands jsonb; v_auto uuid; v_dup boolean; n_ok int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    v_kind := r->>'kind'; v_mst := regexp_replace(coalesce(r->>'mst', ''), '\D', '', 'g'); v_tong := nullif(r->>'tong', '')::numeric;
    v_so := nullif(ltrim(regexp_replace(coalesce(r->>'so_hd', ''), '\D', '', 'g'), '0'), '');
    with inv as (
      select v.id, v.code, v.status, coalesce(v.buyer_name, left(v.buyer_info, 120)) buyer_name, v.sale_id, v.so_hd,
             app.out_inv_total(v.id) tong,
             (select f.tong from public.out_invoice_files f where f.invoice_id = v.id and f.kind = 'nhap' order by f.version desc limit 1) nhap_tong,
             (select f.file_name from public.out_invoice_files f where f.invoice_id = v.id and f.kind = 'nhap' order by f.version desc limit 1) nhap_name,
             (select max(f.version) from public.out_invoice_files f where f.invoice_id = v.id and f.kind = 'nhap') nhap_v,
             (select f.so_hd from public.out_invoice_files f where f.invoice_id = v.id and f.kind = 'ky' order by f.version desc limit 1) ky_so
        from public.out_invoices v
       where v.status <> 'huy' and (
             (v_mst <> '' and (regexp_replace(coalesce(v.tax_code, ''), '\D', '', 'g') = v_mst or v.buyer_info like '%' || v_mst || '%'))
          or (v_kind = 'ky' and v_so is not null and ltrim(v.so_hd, '0') = v_so))
    ), sc as (
      select inv.*,
        case when v_kind = 'nhap' then inv.status in ('cho_nhap','da_nhap','xac_nhan_ky')
             else inv.status in ('da_nhap','xac_nhan_ky') or (inv.status = 'da_ky' and (inv.so_hd is null or ltrim(inv.so_hd, '0') = v_so)) end ok,
        coalesce(v_tong is not null and (abs(inv.tong - v_tong) <= 100 or inv.nhap_tong = v_tong), false) tien_khop,
        coalesce(v_kind = 'ky' and v_so is not null and ltrim(coalesce(inv.so_hd, inv.ky_so, ''), '0') = v_so, false) so_khop
      from inv
    )
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'status', status, 'buyer_name', buyer_name, 'sale_id', sale_id, 'tong', tong,
             'nhap_tong', nhap_tong, 'nhap_v', nhap_v, 'ky_so', ky_so, 'so_hd', so_hd, 'ok', ok, 'khop', so_khop or tien_khop,
             'dup', case when v_kind = 'nhap' then nhap_name is not null and nhap_name = r->>'name' else ky_so is not null and ltrim(ky_so, '0') = v_so end)
             order by so_khop desc, (ok and tien_khop) desc, ok desc, abs(tong - coalesce(v_tong, tong))), '[]'),
           count(*) filter (where ok and (so_khop or tien_khop))
      into cands, n_ok from sc;
    v_auto := null; v_dup := false;
    if n_ok = 1 then
      select (e->>'id')::uuid, (e->>'dup')::boolean into v_auto, v_dup from jsonb_array_elements(cands) e where (e->>'ok')::boolean and (e->>'khop')::boolean limit 1;
    elsif n_ok > 1 and v_kind = 'ky' then  -- nhiều phiếu cùng MST + tiền: ưu tiên phiếu đúng số HĐ
      select (e->>'id')::uuid, (e->>'dup')::boolean into v_auto, v_dup from jsonb_array_elements(cands) e
       where (e->>'ok')::boolean and v_so is not null and ltrim(coalesce(e->>'so_hd', e->>'ky_so', ''), '0') = v_so limit 1;
    end if;
    out := out || jsonb_build_object('i', r->'i', 'auto', v_auto, 'dup', v_dup, 'n_khop', n_ok, 'cands', (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(cands) x limit 8) z));
  end loop;
  return out;
end $$;
grant execute on function public.out_file_match(jsonb) to authenticated;

-- Gắn 1 file đã lưu Drive vào phiếu
create or replace function public.out_file_attach(p_invoice uuid, p_kind text, p_drive_id text, p_name text, p_size_kb int, p_tong numeric,
  p_mst text, p_so_hd text default null, p_ky_hieu text default null, p_ngay date default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; v_ver int; v_note text; v_so text := nullif(btrim(p_so_hd), ''); v_new text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin'; end if;
  if p_kind not in ('nhap','ky') or coalesce(btrim(p_drive_id), '') = '' then raise exception 'Thiếu thông tin file'; end if;
  select * into v from public.out_invoices where id = p_invoice for update;
  if v.id is null then raise exception 'Không có phiếu'; end if;
  if p_kind = 'nhap' and v.status not in ('cho_nhap','da_nhap','xac_nhan_ky') then
    raise exception 'Phiếu % đang "%" — không gắn bản nháp được', v.code, v.status; end if;
  if p_kind = 'ky' then
    if v_so is null then raise exception 'Thiếu số HĐ đã ký cho phiếu %', v.code; end if;
    if v.status not in ('da_nhap','xac_nhan_ky','da_ky') then raise exception 'Phiếu % đang "%" — không gắn bản đã ký được', v.code, v.status; end if;
    if v.status = 'da_ky' and v.so_hd is not null and ltrim(v.so_hd, '0') <> ltrim(v_so, '0') then
      raise exception 'Phiếu % đã ký số HĐ %, file là số %', v.code, v.so_hd, v_so; end if;
  end if;
  select coalesce(max(version), 0) + 1 into v_ver from public.out_invoice_files where invoice_id = v.id and kind = p_kind;
  insert into public.out_invoice_files(invoice_id, kind, version, drive_id, file_name, size_kb, tong, mst, so_hd, ky_hieu, ngay)
  values (v.id, p_kind, v_ver, btrim(p_drive_id), left(p_name, 200), p_size_kb, p_tong, nullif(btrim(p_mst), ''), v_so, nullif(btrim(p_ky_hieu), ''), p_ngay);

  if p_kind = 'nhap' then
    v_new := case when v.status = 'cho_nhap' then 'da_nhap' when v.status = 'xac_nhan_ky' then 'da_nhap' else v.status end;
    v_note := 'Tải HĐ nháp v' || v_ver || case when v.status = 'xac_nhan_ky' then ' — bản mới, xác nhận ký của bản cũ đã hủy' else '' end;
    update public.out_invoices set status = v_new, sua_sau_nhap = false, updated_at = now(),
      status_at = case when v_new <> v.status then now() else status_at end, status_by = case when v_new <> v.status then auth.uid() else status_by end
     where id = v.id;
    insert into public.out_events(invoice_id, action, note, data) values (v.id, 'file', v_note, jsonb_build_object('kind', 'nhap', 'version', v_ver, 'from', v.status, 'to', v_new));
    perform app.notify(v.sale_id, 'acc',
      case when v_ver = 1 then 'Đã có HĐ nháp — xem, gửi khách: ' else 'HĐ nháp mới v' || v_ver || ' — gửi lại khách: ' end || v.code,
      coalesce(v.buyer_name, '') || case when v.status = 'xac_nhan_ky' then ' — khách cần xác nhận lại bản mới' else '' end, '#/out?inv=' || v.id);
  else
    update public.out_invoices set status = 'da_ky', so_hd = coalesce(so_hd, v_so), ngay_hd = coalesce(ngay_hd, p_ngay, current_date), updated_at = now(),
      status_at = case when v.status <> 'da_ky' then now() else status_at end, status_by = case when v.status <> 'da_ky' then auth.uid() else status_by end
     where id = v.id;
    insert into public.out_events(invoice_id, action, note, data) values (v.id, 'file', 'Tải HĐ đã ký số ' || v_so || case when v_ver > 1 then ' (bản ' || v_ver || ')' else '' end,
      jsonb_build_object('kind', 'ky', 'version', v_ver, 'from', v.status, 'to', 'da_ky', 'so_hd', v_so));
    perform app.notify(v.sale_id, 'acc', 'HĐ đã ký số ' || v_so || ' — in làm hợp đồng, báo khách: ' || v.code, coalesce(v.buyer_name, ''), '#/out?inv=' || v.id);
  end if;
  return jsonb_build_object('version', v_ver, 'status', case when p_kind = 'ky' then 'da_ky' else v_new end);
end $$;
grant execute on function public.out_file_attach(uuid, text, text, text, int, numeric, text, text, text, date) to authenticated;

-- Danh sách file của phiếu (không trả mã Drive)
create or replace function public.out_files_list(p_invoice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_sale uuid; v_ok boolean;
begin
  select sale_id, true into v_sale, v_ok from public.out_invoices where id = p_invoice;
  if v_ok is null or not (app.is_acc() or app.in_tree(v_sale)) then raise exception 'Không có quyền'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'version', f.version, 'file_name', f.file_name, 'size_kb', f.size_kb, 'tong', f.tong,
      'so_hd', f.so_hd, 'ky_hieu', f.ky_hieu, 'ngay', f.ngay, 'uploaded_at', f.uploaded_at, 'uploaded_by', f.uploaded_by, 'sent_at', f.sent_at, 'sent_by', f.sent_by,
      'latest', f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = f.invoice_id and x.kind = f.kind))
      order by (f.kind = 'ky') desc, f.version desc), '[]')
    from public.out_invoice_files f where f.invoice_id = p_invoice);
end $$;
grant execute on function public.out_files_list(uuid) to authenticated;

-- Sale đánh dấu đã gửi khách bản nháp mới nhất
create or replace function public.out_file_sent(p_file uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare f public.out_invoice_files; v public.out_invoices;
begin
  select * into f from public.out_invoice_files where id = p_file;
  select * into v from public.out_invoices where id = f.invoice_id;
  if v.id is null or not (app.is_acc() or app.in_tree(v.sale_id)) then raise exception 'Không có quyền'; end if;
  if f.sent_at is not null then return; end if;
  update public.out_invoice_files set sent_at = now(), sent_by = auth.uid() where id = p_file;
  insert into public.out_events(invoice_id, action, note, data) values (v.id, 'sent', 'Đã gửi khách ' || case f.kind when 'ky' then 'HĐ đã ký' else 'bản nháp v' || f.version end, jsonb_build_object('kind', f.kind, 'version', f.version));
end $$;
grant execute on function public.out_file_sent(uuid) to authenticated;

-- ---------- Danh sách phiếu: thêm trạng thái file ----------
create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree();
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%'),
  o as (select f.*, row_number() over (order by f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

-- Sale xác nhận ký: ghi lại bản nháp khách đã OK
create or replace function public.out_confirm_sign(p_invoice uuid, p_version int) returns void
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; v_max int;
begin
  select * into v from public.out_invoices where id = p_invoice;
  if v.id is null or not (app.is_acc() or app.in_tree(v.sale_id)) then raise exception 'Không có quyền'; end if;
  select max(version) into v_max from public.out_invoice_files where invoice_id = v.id and kind = 'nhap';
  if v_max is not null and coalesce(p_version, 0) <> v_max then raise exception 'Đã có bản nháp mới v% — mở bản mới, gửi khách rồi xác nhận lại', v_max; end if;
  perform public.out_invoice_status(array[v.id], 'xac_nhan_ky', case when v_max is not null then 'Khách OK bản nháp v' || v_max end);
end $$;
grant execute on function public.out_confirm_sign(uuid, int) to authenticated;

reset search_path;
