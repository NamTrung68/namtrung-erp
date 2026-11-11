-- =====================================================================
-- 0045 · Bản 38 (11/11/2026)
--  Tự tải PDF HĐ đã ký từ MISA meInvoice (link tra cứu công khai theo mã tra cứu) → lưu Google Drive (HD da ky/<tháng>/<sale>)
--  → gắn vào phiếu như file "ky". Sale bấm "⬇ Tải HĐ" hoặc "Cả bộ" (ĐĐH + BBGN + HĐ đã ký) lấy file từ Drive.
--  · Hàm máy chủ "hdky" (Supabase Edge Function) làm việc tải + lưu; trình duyệt không gọi thẳng meInvoice (bị chặn CORS).
--  · Kế toán điền mã tra cứu / MISA tự dò ra "Đã ký" → CSDL gọi ngay hàm hdky (pg_net); lịch 15 phút/lần quét lại HĐ còn thiếu.
--  · Mã file Drive không lộ ra trình duyệt; gắn file chỉ hàm máy chủ (service_role) làm được.
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 38');

-- Lần tải lỗi (tránh gọi lặp vô hạn khi mã tra cứu sai / meInvoice lỗi)
create table if not exists app.ky_fetch_fail(
  invoice_id uuid primary key references public.out_invoices(id) on delete cascade,
  n int not null default 0, last_at timestamptz not null default now(), error text
);
revoke all on app.ky_fetch_fail from anon, authenticated;

insert into app.secrets(key, value) values ('hdky_cron_key', encode(gen_random_bytes(24), 'hex')) on conflict (key) do nothing;

-- Thông tin để tải (dùng nội bộ hàm máy chủ)
create or replace function public.out_ky_info_sys(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', i.id, 'code', i.code, 'status', i.status, 'ma_tra_cuu', i.ma_tra_cuu, 'so_hd', i.so_hd, 'ngay_hd', i.ngay_hd,
      'tax_code', i.tax_code, 'buyer_name', i.buyer_name, 'tong', app.out_inv_total(i.id),
      'sale_name', coalesce((select full_name from public.profiles where id = i.sale_id), 'Khong ro sale'),
      'file_id', (select f.id from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'ky' order by f.version desc limit 1),
      'url_tpl', coalesce(nullif(app.setting('accounting')->>'tra_cuu_dl_url', ''),
                          nullif(replace(replace(coalesce(app.setting('accounting')->>'tra_cuu_url', ''), '&Viewer=1', ''), 'Viewer=1&', ''), ''),
                          'https://www.meinvoice.vn/tra-cuu/tra-cuu/DownloadHandler.ashx?Type=pdf&ext=QXVLM59J&Code={code}'))
    from public.out_invoices i where i.id = p_id
$$;

-- Người dùng ERP: kiểm quyền với phiếu (sale của phiếu, cấp trên, CSKH hỗ trợ theo cây, Kế toán / Admin)
create or replace function public.out_ky_info(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_sale uuid; v_st text;
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  select sale_id, status into v_sale, v_st from public.out_invoices where id = p_id;
  if v_st is null or not (app.is_acc() or app.in_tree(v_sale)) then raise exception 'Không có quyền với HĐ này'; end if;
  if v_st <> 'da_ky' then raise exception 'HĐ chưa ký'; end if;
  return public.out_ky_info_sys(p_id);
end $$;
grant execute on function public.out_ky_info(uuid) to authenticated;

create or replace function public.out_ky_upload_ticket(p_folder text) returns text
language sql security definer set search_path = public, app as $$
  select app.drive_new_ticket('upload', null, left(regexp_replace(coalesce(p_folder, 'HD da ky'), '\.\.+', '', 'g'), 200), interval '30 minutes')
$$;

-- Gắn PDF đã ký (hàm máy chủ đã lưu Drive). Đã có file "ky" thì trả file cũ, không tạo trùng
create or replace function public.out_ky_attach(p_id uuid, p_drive_id text, p_name text, p_size_kb int) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; fid uuid; v_ver int;
begin
  select * into v from public.out_invoices where id = p_id for update;
  if v.id is null or v.status <> 'da_ky' then raise exception 'HĐ chưa ký'; end if;
  if coalesce(btrim(p_drive_id), '') = '' then raise exception 'Thiếu mã file'; end if;
  select id into fid from public.out_invoice_files where invoice_id = p_id and kind = 'ky' order by version desc limit 1;
  if fid is not null then return fid; end if;
  select coalesce(max(version), 0) + 1 into v_ver from public.out_invoice_files where invoice_id = p_id and kind = 'ky';
  insert into public.out_invoice_files(invoice_id, kind, version, drive_id, file_name, size_kb, tong, mst, so_hd, ngay, uploaded_by, note)
  values (p_id, 'ky', v_ver, btrim(p_drive_id), left(p_name, 200), p_size_kb, app.out_inv_total(p_id), v.tax_code, v.so_hd, v.ngay_hd, null, 'Tự tải từ meInvoice theo mã tra cứu')
  returning id into fid;
  insert into public.out_events(invoice_id, action, note, data) values (p_id, 'file', 'Tự tải HĐ đã ký từ meInvoice (mã tra cứu ' || coalesce(v.ma_tra_cuu, '') || ')',
    jsonb_build_object('kind', 'ky', 'version', v_ver, 'auto', true));
  delete from app.ky_fetch_fail where invoice_id = p_id;
  return fid;
end $$;

create or replace function public.out_ky_fail(p_id uuid, p_error text) returns void
language sql security definer set search_path = public, app as $$
  insert into app.ky_fetch_fail(invoice_id, n, last_at, error) values (p_id, 1, now(), left(p_error, 500))
  on conflict (invoice_id) do update set n = app.ky_fetch_fail.n + 1, last_at = now(), error = left(p_error, 500)
$$;

-- HĐ đã ký có mã tra cứu mà chưa có PDF (bỏ qua HĐ lỗi ≥ 5 lần, hoặc vừa lỗi trong 1 giờ)
create or replace function public.out_ky_pending(p_limit int default 20) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select i.id from public.out_invoices i
   where i.status = 'da_ky' and coalesce(i.ma_tra_cuu, '') <> '' and i.status_at > now() - interval '120 days'
     and not exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'ky')
     and not exists(select 1 from app.ky_fetch_fail x where x.invoice_id = i.id and (x.n >= 5 or x.last_at > now() - interval '1 hour'))
   order by i.status_at desc limit greatest(1, least(coalesce(p_limit, 20), 50))
$$;

create or replace function public.hdky_cron_ok(p_key text) returns boolean language sql stable security definer set search_path = public, app as $$
  select coalesce(p_key, '') <> '' and exists(select 1 from app.secrets where key = 'hdky_cron_key' and value = p_key)
$$;

revoke all on function public.out_ky_info_sys(uuid), public.out_ky_upload_ticket(text), public.out_ky_attach(uuid, text, text, int),
  public.out_ky_fail(uuid, text), public.out_ky_pending(int), public.hdky_cron_ok(text) from public, anon, authenticated;
grant execute on function public.out_ky_info_sys(uuid), public.out_ky_upload_ticket(text), public.out_ky_attach(uuid, text, text, int),
  public.out_ky_fail(uuid, text), public.out_ky_pending(int), public.hdky_cron_ok(text) to service_role;

-- Gọi hàm máy chủ hdky (pg_net, không chờ). Chỉ khi đã cấu hình Drive và biết địa chỉ hàm máy chủ (từ cấu hình push)
create or replace function app.hdky_kick(p_ids uuid[] default null) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_url text := replace(coalesce(app.setting('push')->>'url', ''), '/functions/v1/push', '/functions/v1/hdky');
begin
  if v_url not like 'https://%/functions/v1/hdky' or coalesce(app.setting('drive')->>'url', '') = '' then return; end if;
  if not exists(select 1 from pg_namespace where nspname = 'net') then return; end if;
  begin
    execute 'select net.http_post(url := $1, body := $2, headers := $3)'
      using v_url, jsonb_build_object('action', 'sweep', 'ids', to_jsonb(p_ids)),
            jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', (select value from app.secrets where key = 'hdky_cron_key'));
  exception when others then null; end;
end $$;

-- Có mã tra cứu + "Đã ký" → tải ngay
create or replace function app.trg_out_ky_fetch() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'da_ky' and coalesce(new.ma_tra_cuu, '') <> ''
     and (old.status is distinct from 'da_ky' or old.ma_tra_cuu is distinct from new.ma_tra_cuu) then
    if old.ma_tra_cuu is distinct from new.ma_tra_cuu then delete from app.ky_fetch_fail where invoice_id = new.id; end if;
    perform app.hdky_kick(array[new.id]);
  end if;
  return new;
end $$;
drop trigger if exists out_ky_fetch on public.out_invoices;
create trigger out_ky_fetch after update of status, ma_tra_cuu on public.out_invoices for each row execute function app.trg_out_ky_fetch();

create or replace function app.job_hdky() returns void language plpgsql security definer set search_path = public, app as $$
declare h int := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh');
begin
  if h < 7 or h > 22 then return; end if;
  if not exists(select 1 from public.out_ky_pending(1)) then return; end if;
  perform app.hdky_kick(null);
end $$;
do $$ begin perform cron.unschedule('nt_hdky'); exception when others then null; end $$;
select cron.schedule('nt_hdky', '7,22,37,52 * * * *', 'select app.job_hdky()');

-- Vết hồ sơ: ghi cả lần tải HĐ đã ký (PDF)
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
        if k not in ('ddh', 'bbgn', 'hdmb', 'hdnt', 'hd') then continue; end if;
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
