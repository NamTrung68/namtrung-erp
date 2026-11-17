-- Bản 55 — Pháp nhân nhận HĐ: khi MỞ cập nhật, Sale / CSKH điền đầy đủ hồ sơ; lọc đã nhập / chưa nhập đủ hồ sơ
--  · Đang mở: Sale / CSKH / TN / TP sửa được cả mã + ngày HĐ nguyên tắc, tải / gỡ bản scan hồ sơ pháp nhân (HĐNT / HĐMB / giấy tờ khác) của khách mình
--    (gỡ: chỉ bản scan do chính mình tải). Đang khóa: như cũ, chỉ Kế toán / Admin.
--  · out_buyers_page: thieu_hs = danh sách mục còn thiếu; đếm + lọc 'du_hs' / 'thieu_hs'
--    Đủ hồ sơ = Tên, MST đúng dạng, Địa chỉ, Email, Người đại diện, Chức vụ, Người nhận + SĐT nhận chuyển phát; có mã HĐNT thì phải có bản scan HĐNT

/** Sale / CSKH ghi được pháp nhân này (đang mở + khách mình phụ trách) hoặc Kế toán / Admin */
create or replace function app.pn_can_write(p_buyer uuid) returns boolean language sql stable security definer set search_path = public, app as $$
  select app.is_acc() or app.pn_mo() and exists(select 1 from public.out_buyers b join public.customers c on c.id = b.customer_id where b.id = p_buyer and app.in_tree(c.owner_id))
$$;

-- out_buyer_save: bỏ chặn mã HĐNT với Sale (pn_guard đã chặn khi khóa)
do $$ declare s text; begin
  s := pg_get_functiondef('public.out_buyer_save(uuid, jsonb)'::regprocedure);
  if position('if not v_acc then p := p - ''ma_hdnt'' - ''ngay_hdnt''; end if;' in s) = 0 then raise exception 'out_buyer_save: không thấy đoạn chặn mã HĐNT'; end if;
  s := replace(s, 'if not v_acc then p := p - ''ma_hdnt'' - ''ngay_hdnt''; end if;', 'if not v_acc and not app.pn_mo() then p := p - ''ma_hdnt'' - ''ngay_hdnt''; end if;');
  execute s;
end $$;

create or replace function public.drive_upload_tickets(p_folders text[]) returns text[]
language plpgsql security definer set search_path = public, app as $$
declare f text; r text[] := '{}'; v_acc boolean := app.is_acc();
begin
  if not v_acc and not app.pn_mo() then raise exception 'Chỉ Kế toán / Admin được lưu file lên Drive'; end if;
  if coalesce(array_length(p_folders, 1), 0) = 0 or array_length(p_folders, 1) > 300 then raise exception 'Số file không hợp lệ'; end if;
  foreach f in array p_folders loop
    f := regexp_replace(coalesce(f, 'Khac'), '\.\.+', '', 'g');
    -- Sale / CSKH (khi mở cập nhật pháp nhân) chỉ được tải vào thư mục hồ sơ khách hàng
    if not v_acc and f not like 'Ho so khach hang/%' then raise exception 'Sale / CSKH chỉ tải được bản scan hồ sơ pháp nhân'; end if;
    r := r || app.drive_new_ticket('upload', null, left(f, 200), interval '30 minutes');
  end loop;
  return r;
end $$;
grant execute on function public.drive_upload_tickets(text[]) to authenticated;

do $$ declare s text; begin
  s := pg_get_functiondef('public.ho_so_scan_add(jsonb)'::regprocedure);
  s := replace(s, 'if not app.is_acc() then raise exception ''Chỉ Kế toán / Admin / BGĐ lưu bản scan lên Drive''; end if;',
    'if not app.is_acc() and not (app.pn_mo() and nullif(p->>''invoice_id'', '''') is null and app.pn_can_write(v_buyer)) then raise exception ''Chỉ Kế toán / Admin / BGĐ lưu bản scan — Sale / CSKH chỉ tải hồ sơ pháp nhân của khách mình khi kế toán mở cập nhật''; end if;');
  if position('pn_can_write' in s) = 0 then raise exception 'ho_so_scan_add: không vá được'; end if;
  execute s;
end $$;

create or replace function public.ho_so_scan_del(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare s public.ho_so_scans;
begin
  select * into s from public.ho_so_scans where id = p_id and deleted_at is null;
  if not app.is_acc() and not coalesce(s.invoice_id is null and s.uploaded_by = auth.uid() and app.pn_can_write(s.buyer_id), false) then
    raise exception 'Chỉ Kế toán / Admin / BGĐ gỡ bản scan — Sale / CSKH chỉ gỡ bản scan hồ sơ pháp nhân do mình tải, khi đang mở cập nhật';
  end if;
  if s.id is null then raise exception 'Không thấy bản scan'; end if;
  update public.ho_so_scans set deleted_at = now(), deleted_by = auth.uid() where id = p_id;
  if s.invoice_id is not null then
    insert into public.out_events(invoice_id, action, note, data) values (s.invoice_id, 'scan', 'Gỡ bản scan: ' || array_to_string(s.kinds, ', ') || coalesce(' (' || s.file_name || ')', ''), jsonb_build_object('scan', s.id, 'del', true));
  end if;
end $$;
grant execute on function public.ho_so_scan_del(uuid) to authenticated;

/** Các mục hồ sơ pháp nhân còn thiếu */
create or replace function app.pn_thieu(b public.out_buyers) returns text[] language sql stable security definer set search_path = public, app as $$
  select array_remove(array[
    case when coalesce(btrim(b.name), '') = '' then 'Tên' end,
    case when not coalesce(app.mst_ok(b.tax_code), false) then 'MST' end,
    case when coalesce(btrim(b.address), '') = '' then 'Địa chỉ' end,
    case when coalesce(btrim(b.email), '') = '' then 'Email' end,
    case when coalesce(btrim(b.dai_dien), '') = '' then 'Người đại diện' end,
    case when coalesce(btrim(b.chuc_vu), '') = '' then 'Chức vụ' end,
    case when coalesce(btrim(b.nguoi_nhan), '') = '' then 'Người nhận' end,
    case when coalesce(btrim(b.sdt_nhan), '') = '' then 'SĐT nhận' end,
    case when nullif(btrim(b.ma_hdnt), '') is not null and not exists(select 1 from public.ho_so_scans s where s.deleted_at is null and s.invoice_id is null and 'hdnt' = any(s.kinds)
                                                                       and (s.buyer_id = b.id or btrim(s.tax_code) = btrim(b.tax_code))) then 'Scan HĐNT' end], null)
$$;

-- out_buyers_page: thêm thieu_hs + lọc / đếm du_hs, thieu_hs
do $$ declare s text; begin
  s := pg_get_functiondef('public.out_buyers_page(jsonb)'::regprocedure);
  s := replace(s, 'nullif(btrim(b.ma_hdnt), '''') is not null hdnt,', 'nullif(btrim(b.ma_hdnt), '''') is not null hdnt, app.pn_thieu(b) thieu_hs,');
  s := replace(s, '''thieu_dd'', count(*) filter (where dai_dien is null),',
    '''thieu_dd'', count(*) filter (where dai_dien is null), ''du_hs'', count(*) filter (where cardinality(thieu_hs) = 0), ''thieu_hs'', count(*) filter (where cardinality(thieu_hs) > 0),');
  s := replace(s, 'or v_flag = ''thieu_dd'' and dai_dien is null',
    'or v_flag = ''thieu_dd'' and dai_dien is null or v_flag = ''du_hs'' and cardinality(thieu_hs) = 0 or v_flag = ''thieu_hs'' and cardinality(thieu_hs) > 0');
  s := replace(s, '''lech_mau'', lech_mau)', '''lech_mau'', lech_mau, ''thieu_hs'', to_jsonb(thieu_hs))');
  if (length(s) - length(replace(s, 'thieu_hs', ''))) / 8 < 7 then raise exception 'out_buyers_page: không vá đủ (%)', (length(s) - length(replace(s, 'thieu_hs', ''))) / 8; end if;
  execute s;
end $$;
