-- =====================================================================
-- 0030 · Bản 23: Kế toán – Hóa đơn viết lại theo đặc tả 02/11/2026
--  Chu kỳ 1 · ghép nháp APT ↔ file xe theo MÃ KHAI BÁO → mã đơn MD + SL (không theo tên); biên ngoài khung chỉ cảnh báo
--  Chu kỳ 2 · dòng HĐ chính thức APT (mã hàng MISA) ghép về dòng nháp theo TÊN + SL → mã khai báo, đơn, khách, sale;
--             đối chiếu chi tiết SL / đơn giá / thuế suất → lệch thì KHÓA dòng
--  Chu kỳ 3 · giá xuất: biên < 2% cấm, 2–4% tự do, > 4% "Chờ duyệt giá" (1 người: kế toán / quản lý / admin);
--             "Trả sửa"; sale không hủy sau khi kế toán đã export MISA; phiên bản yêu cầu; pháp nhân mặc định;
--             báo cáo tồn HĐ đầu vào theo sale
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 23');

-- ---------- Cấu hình ----------
update public.settings set value = value
  || jsonb_build_object('xuat_bien_cam', coalesce(value->'xuat_bien_cam', '0.02'::jsonb), 'xuat_bien_duyet', coalesce(value->'xuat_bien_duyet', '0.04'::jsonb),
                        'gia_de_xuat_lam_tron', coalesce(value->'gia_de_xuat_lam_tron', '100'::jsonb))
 where key = 'accounting';

-- ---------- Chu kỳ 1: cột mới ----------
alter table public.acc_lines add column if not exists ma_kb_apt text;
alter table public.acc_lines add column if not exists match_kind text;

create or replace function public.acc_truck_save(p_truck uuid, p_info jsonb, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := p_truck; r jsonb; v_keys text[] := '{}'; v_sale uuid; v_old public.acc_lines; v_status text; v_due timestamptz; v_lid uuid;
        h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); s record; n_block int; v_test boolean;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán được nạp đối soát'; end if;
  if v_id is null then
    insert into public.acc_trucks(name, truck_date, files, stats, warnings, is_test, md_xuat_thang, xt_keys)
    values (p_info->>'name', nullif(p_info->>'truck_date','')::date, coalesce(p_info->'files','{}'), coalesce(p_info->'stats','{}'),
            coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), '{}'), coalesce((p_info->>'is_test')::boolean, false),
            coalesce(array(select jsonb_array_elements_text(p_info->'md_xuat_thang')), '{}'), coalesce(array(select jsonb_array_elements_text(p_info->'xt_keys')), '{}'))
    returning id into v_id;
  else
    update public.acc_trucks set name = coalesce(p_info->>'name', name), truck_date = coalesce(nullif(p_info->>'truck_date','')::date, truck_date),
      files = coalesce(p_info->'files', files), stats = coalesce(p_info->'stats', stats),
      warnings = coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), warnings),
      md_xuat_thang = coalesce(array(select jsonb_array_elements_text(p_info->'md_xuat_thang')), md_xuat_thang),
      xt_keys = coalesce(array(select jsonb_array_elements_text(p_info->'xt_keys')), xt_keys), updated_at = now() where id = v_id;
  end if;
  select is_test into v_test from public.acc_trucks where id = v_id;
  for r in select * from jsonb_array_elements(p_lines) loop
    v_keys := v_keys || (r->>'line_key');
    v_sale := coalesce(nullif(r->>'sale_id','')::uuid, app.match_sale(r->>'sale_name'), app.match_sale(r->>'sale_acc'));
    select * into v_old from public.acc_lines where truck_id = v_id and line_key = r->>'line_key';
    v_status := r->>'status';
    v_due := case when v_status = 'blocked' then coalesce(v_old.due_at, now() + make_interval(hours => h)) else null end;
    insert into public.acc_lines as l(truck_id, line_key, ma_dong, md, sale_name, sale_acc, sale_id, ma_kh, sys_row, ten_ht, sl_ht, dvt_ht, gia_khach, nk_ht,
      apt_stt, hh, dh, sale_apt, ten_apt, sl_apt, dvt_apt, gia_nhap, gia_note, note_apt, nk_apt, vat, tk_row, ten_tk, hs, sl_tk, dvt_tk, gia_tk_nh, nk_tk, tnk_dv, md_header,
      luong, gia_ap_dung, gia_de_xuat, bien_nt, tt_apt, tt_khach, status, level, issues, notes, phan_hoi, match_score, due_at, updated_at, is_test, ma_kb_apt, match_kind)
    select v_id, x.line_key, x.ma_dong, x.md, x.sale_name, x.sale_acc, v_sale, x.ma_kh, x.sys_row, x.ten_ht, x.sl_ht, x.dvt_ht, x.gia_khach, x.nk_ht,
      x.apt_stt, x.hh, x.dh, x.sale_apt, x.ten_apt, x.sl_apt, x.dvt_apt, x.gia_nhap, x.gia_note, x.note_apt, x.nk_apt, x.vat, x.tk_row, x.ten_tk, x.hs, x.sl_tk, x.dvt_tk, x.gia_tk_nh, x.nk_tk, x.tnk_dv, x.md_header,
      x.luong, x.gia_ap_dung, x.gia_de_xuat, x.bien_nt, x.tt_apt, x.tt_khach, v_status, x.level, coalesce(x.issues, '{}'), coalesce(x.notes, '{}'), x.phan_hoi, x.match_score, v_due, now(), v_test,
      x.ma_kb_apt, x.match_kind
    from jsonb_populate_record(null::public.acc_lines, r) x
    on conflict (truck_id, line_key) do update set ma_dong = excluded.ma_dong, md = excluded.md, sale_name = excluded.sale_name, sale_acc = excluded.sale_acc, sale_id = excluded.sale_id,
      ma_kh = excluded.ma_kh, sys_row = excluded.sys_row, ten_ht = excluded.ten_ht, sl_ht = excluded.sl_ht, dvt_ht = excluded.dvt_ht, gia_khach = excluded.gia_khach, nk_ht = excluded.nk_ht,
      apt_stt = excluded.apt_stt, hh = excluded.hh, dh = excluded.dh, sale_apt = excluded.sale_apt, ten_apt = excluded.ten_apt, sl_apt = excluded.sl_apt, dvt_apt = excluded.dvt_apt,
      gia_nhap = excluded.gia_nhap, gia_note = excluded.gia_note, note_apt = excluded.note_apt, nk_apt = excluded.nk_apt, vat = excluded.vat, tk_row = excluded.tk_row, ten_tk = excluded.ten_tk,
      hs = excluded.hs, sl_tk = excluded.sl_tk, dvt_tk = excluded.dvt_tk, gia_tk_nh = excluded.gia_tk_nh, nk_tk = excluded.nk_tk, tnk_dv = excluded.tnk_dv, md_header = excluded.md_header,
      luong = excluded.luong, gia_ap_dung = excluded.gia_ap_dung, gia_de_xuat = excluded.gia_de_xuat, bien_nt = excluded.bien_nt, tt_apt = excluded.tt_apt, tt_khach = excluded.tt_khach,
      status = excluded.status, level = excluded.level, issues = excluded.issues, notes = excluded.notes, phan_hoi = excluded.phan_hoi, match_score = excluded.match_score,
      due_at = excluded.due_at, updated_at = now(), is_test = excluded.is_test, ma_kb_apt = excluded.ma_kb_apt, match_kind = excluded.match_kind
    returning id into v_lid;
    if v_old.id is not null then perform app.acc_keep_manual(v_old, v_lid); end if;
  end loop;
  delete from public.acc_lines where truck_id = v_id and line_key <> all(v_keys);
  insert into public.acc_events(truck_id, action, note, data) values (v_id, case when p_truck is null then 'import' else 'reimport' end, p_info->>'name', p_info->'stats');
  if v_test then return v_id; end if;
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', coalesce(p_info->>'name','') || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
  select count(*) into n_block from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is null;
  if n_block > 0 then perform app.notify_roles(array['ke_toan'], 'acc', n_block || ' dòng bị chặn chưa ghép được sale', p_info->>'name', '#/acc?truck=' || v_id); end if;
  return v_id;
end $$;
grant execute on function public.acc_truck_save(uuid, jsonb, jsonb) to authenticated;

-- ---------- Chu kỳ 2: bảng gốc theo mã hàng MISA ----------
alter table public.out_items add column if not exists ma_kb text;
alter table public.out_items add column if not exists lech boolean not null default false;
alter table public.out_items add column if not exists lech_note text;
alter table public.out_items add column if not exists lech_ok_by uuid references public.profiles(id);
alter table public.out_items add column if not exists lech_ok_at timestamptz;
alter table public.out_items add column if not exists lech_ok_note text;
create index if not exists out_items_lech on public.out_items(lech) where lech;

-- Tên so khớp: bỏ dấu câu cuối, gộp khoảng trắng, không phân biệt hoa thường (giữ dấu tiếng Việt — tên HĐ ký chép từ nháp)
create or replace function app.hd_ten(t text) returns text language sql immutable parallel safe as $$
  select btrim(regexp_replace(regexp_replace(lower(coalesce(t, '')), '\s+', ' ', 'g'), '[\s.,;:]+$', ''))
$$;
create index if not exists acc_lines_ten_apt on public.acc_lines(app.hd_ten(ten_apt)) where apt_stt is not null;

-- Đối chiếu chi tiết 1 dòng HĐ ký với dòng nháp đã đối soát: SL, đơn giá (giá nháp / NOTE / đề xuất ± làm tròn), thuế suất
create or replace function app.out_item_check(t public.out_items, al public.acc_lines) returns text
language plpgsql stable set search_path = public, app as $$
declare v_tron numeric := coalesce((app.setting('accounting')->>'gia_de_xuat_lam_tron')::numeric, 100); v text[] := '{}';
begin
  if al.id is null then return null; end if;
  if al.sl_apt is not null and abs(coalesce(t.sl_nhap, 0) - al.sl_apt) > 0.0001 then v := v || ('SL HĐ ' || t.sl_nhap || ' ≠ nháp ' || al.sl_apt); end if;
  if t.dg_nhap is not null and not (
       abs(t.dg_nhap - coalesce(al.gia_nhap, -1)) <= 0.5 or abs(t.dg_nhap - coalesce(al.gia_note, -1)) <= 0.5
       or (al.gia_de_xuat is not null and abs(t.dg_nhap - al.gia_de_xuat) < v_tron)) then
    v := v || ('Đơn giá HĐ ' || t.dg_nhap || ' ≠ nháp ' || coalesce(al.gia_note, al.gia_nhap)::text || coalesce(' / đề xuất ' || al.gia_de_xuat, ''));
  end if;
  if t.vat is not null and al.vat is not null and abs(t.vat - al.vat) > 0.0001 then v := v || ('Thuế suất HĐ ' || round(t.vat * 100) || '% ≠ nháp ' || round(al.vat * 100) || '%'); end if;
  return nullif(array_to_string(v, ' · '), '');
end $$;

create or replace function app.out_item_match(p_id uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; al public.acc_lines; v_c uuid; v_owner uuid; v_src text; o public.out_orders; s_sale uuid; s_user text; n int; v_lech text;
begin
  select * into t from public.out_items where id = p_id;
  if t.acc_line_id is not null then select * into al from public.acc_lines where id = t.acc_line_id; v_src := t.match_src; end if;
  if al.id is null and t.stt_hd is not null and t.so_hd_vao is not null then
    select l.* into al from public.acc_invoice_lines il join public.acc_invoices i on i.id = il.invoice_id join public.acc_lines l on l.id = il.line_id
     where ltrim(i.so_hd, '0') = ltrim(t.so_hd_vao, '0') and (t.ky_hieu is null or right(i.ky_hieu, 6) = right(t.ky_hieu, 6)) and il.stt = t.stt_hd limit 1;
    if al.id is not null then v_src := 'hd_xml'; end if;
  end if;
  -- Bản 23: tên HĐ ký = tên nháp (trừ sai số copy) + cùng SL → dòng nháp chưa thuộc dòng sổ nào khác
  if al.id is null then
    select count(*) into n from public.acc_lines l where not l.is_test and l.apt_stt is not null and app.hd_ten(l.ten_apt) = app.hd_ten(t.ten)
       and not exists(select 1 from public.out_items x where x.acc_line_id = l.id and x.id <> t.id);
    if n > 1 then
      select l.* into al from public.acc_lines l where not l.is_test and l.apt_stt is not null and app.hd_ten(l.ten_apt) = app.hd_ten(t.ten)
         and not exists(select 1 from public.out_items x where x.acc_line_id = l.id and x.id <> t.id)
       order by (abs(coalesce(l.sl_apt, -1) - t.sl_nhap) < 0.0001) desc, (abs(coalesce(l.gia_nhap, -1) - coalesce(t.dg_nhap, -2)) <= 0.5) desc, l.updated_at desc limit 1;
      if al.id is not null and abs(coalesce(al.sl_apt, -1) - t.sl_nhap) >= 0.0001 then al := null; end if;
    elsif n = 1 then
      select l.* into al from public.acc_lines l where not l.is_test and l.apt_stt is not null and app.hd_ten(l.ten_apt) = app.hd_ten(t.ten)
         and not exists(select 1 from public.out_items x where x.acc_line_id = l.id and x.id <> t.id);
    end if;
    if al.id is not null then v_src := 'ten'; end if;
  end if;
  if al.id is null and t.md is not null then
    select * into al from public.acc_lines where md = t.md and not is_test order by (sl_apt = t.sl_nhap) desc nulls last, updated_at desc limit 1;
    if al.id is not null then v_src := 'md'; end if;
  end if;
  if t.md is not null or al.md is not null then select * into o from public.out_orders where md = coalesce(t.md, al.md); end if;
  if coalesce(t.md, al.md) is not null and (t.sale_id is null or t.username is null) then
    select sale_id, username into s_sale, s_user from public.out_items where md = coalesce(t.md, al.md) and id <> t.id and (sale_id is not null or username is not null)
     order by (sale_id is not null) desc, (username is not null) desc limit 1;
  end if;
  t.username := coalesce(t.username, nullif(al.ma_kh, ''), o.username, s_user);
  if t.username is not null then
    select id, owner_id into v_c, v_owner from public.customers where deleted_at is null
      and (lower(btrim(sys_username)) = lower(btrim(t.username)) or upper(btrim(sys_code)) = upper(btrim(t.username))) limit 1;
  end if;
  -- đối chiếu chi tiết chỉ cho dòng ghép đúng dòng (XML / tên); ghép theo mã đơn là ước lượng, không khóa
  v_lech := case when v_src in ('ten','hd_xml') then app.out_item_check(t, al) end;
  update public.out_items set acc_line_id = coalesce(acc_line_id, al.id), ma_kb = coalesce(ma_kb, case when v_src in ('ten','hd_xml') then al.ma_dong end),
    md = coalesce(md, al.md), username = t.username, nvkd = coalesce(nvkd, o.nvkd),
    gia_khach = case when v_src in ('hd_xml','ten') and gia_src is distinct from 'sale' then coalesce(nullif(al.gia_khach, 0), al.claim_gia, gia_khach) else gia_khach end,
    gia_src = case when v_src in ('hd_xml','ten') and gia_src is distinct from 'sale' and coalesce(nullif(al.gia_khach, 0), al.claim_gia) is not null then 'doi_soat' else gia_src end,
    sale_id = coalesce(sale_id, al.sale_id, app.match_sale(t.nvkd), app.match_sale(o.nvkd), s_sale, v_owner),
    customer_id = coalesce(customer_id, al.customer_id, v_c),
    match_src = coalesce(match_src, v_src, case when t.nvkd is not null then 'nvkd' when o.md is not null then 'don_hang' when v_owner is not null then 'user' end),
    lech = case when lech_ok_at is not null then lech else v_lech is not null end,
    lech_note = case when lech_ok_at is not null then lech_note else v_lech end
  where id = p_id;
  perform app.out_item_price(p_id);
end $$;

-- Kế toán xử lý dòng lệch: chấp nhận kèm lý do (mở khóa) hoặc ghép lại sang dòng nháp khác
create or replace function public.out_item_lech_ok(p_ids uuid[], p_note text) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do chấp nhận'; end if;
  update public.out_items set lech_ok_by = auth.uid(), lech_ok_at = now(), lech_ok_note = btrim(p_note), updated_at = now() where id = any(p_ids) and lech;
  get diagnostics n = row_count;
  insert into public.out_events(item_id, action, note) select unnest(p_ids), 'lech_ok', btrim(p_note);
  return n;
end $$;
grant execute on function public.out_item_lech_ok(uuid[], text) to authenticated;

create or replace function public.out_item_relink(p_id uuid, p_line uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if exists(select 1 from public.out_items where acc_line_id = p_line and id <> p_id) then raise exception 'Dòng nháp này đã thuộc dòng HĐ khác'; end if;
  update public.out_items set acc_line_id = p_line, match_src = 'tay', ma_kb = null, md = null, sale_id = null, customer_id = null, username = null,
    lech = false, lech_note = null, lech_ok_by = null, lech_ok_at = null, lech_ok_note = null where id = p_id;
  update public.out_items set match_src = 'ten' where id = p_id;  -- để bước đối chiếu chi tiết chạy như dòng ghép theo tên
  perform app.out_item_match(p_id);
  update public.out_items set match_src = 'tay' where id = p_id;
  insert into public.out_events(item_id, action, data) values (p_id, 'relink', jsonb_build_object('line', p_line));
end $$;
grant execute on function public.out_item_relink(uuid, uuid) to authenticated;

-- Gợi ý dòng nháp cho 1 dòng HĐ chưa ghép: cùng SL, tên giống nhất (đếm từ chung)
create or replace function public.out_item_suggest(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare t public.out_items;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  select * into t from public.out_items where id = p_id;
  return (select coalesce(jsonb_agg(z order by z.diem desc), '[]') from (
    select l.id, l.ma_dong, l.md, l.ten_apt, l.sl_apt, l.gia_nhap, l.gia_khach, l.sale_id,
      (select count(*) from unnest(string_to_array(app.hd_ten(l.ten_apt), ' ')) w where w = any(string_to_array(app.hd_ten(t.ten), ' ')))::numeric
        / greatest(1, array_length(string_to_array(app.hd_ten(t.ten), ' '), 1)) diem
    from public.acc_lines l
    where not l.is_test and l.apt_stt is not null and abs(coalesce(l.sl_apt, -1) - t.sl_nhap) < 0.0001
      and not exists(select 1 from public.out_items x where x.acc_line_id = l.id and x.id <> t.id)
    order by diem desc limit 5) z);
end $$;
grant execute on function public.out_item_suggest(uuid) to authenticated;

-- ---------- Chu kỳ 3: yêu cầu xuất HĐ ----------
alter table public.out_invoices drop constraint if exists out_invoices_status_check;
alter table public.out_invoices add constraint out_invoices_status_check
  check (status in ('soan','cho_duyet_gia','cho_nhap','da_nhap','tra_sua','xac_nhan_ky','da_ky','huy'));
alter table public.out_invoices add column if not exists version int not null default 1;
alter table public.out_invoices add column if not exists price_ok_by uuid references public.profiles(id);
alter table public.out_invoices add column if not exists price_ok_at timestamptz;
alter table public.out_invoices add column if not exists bien_min numeric;
alter table public.out_invoices add column if not exists bien_max numeric;

alter table public.out_buyers add column if not exists is_default boolean not null default false;
create unique index if not exists out_buyers_default on public.out_buyers(customer_id) where is_default and customer_id is not null;

-- Người duyệt giá: Kế toán / Admin / BGĐ / Trưởng phòng KD / người duyệt trong cấu hình
create or replace function app.is_price_approver() returns boolean language sql stable security definer set search_path = public, app as $$
  select app.is_acc() or app.is_acc_approver() or app.has_role('tp_kd')
$$;

-- Biên 1 dòng xuất so với giá APT trên HĐ ký
create or replace function app.out_bien(p_gia numeric, p_dg_nhap numeric) returns numeric language sql immutable as $$
  select case when coalesce(p_dg_nhap, 0) > 0 then p_gia / p_dg_nhap - 1 end
$$;

create or replace function public.out_invoice_save(p_id uuid, p_data jsonb, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; v_id uuid := p_id; x jsonb; t public.out_items; k int := 0; v_buyer uuid; v_sale uuid; v_cust uuid; v_acc boolean := app.is_acc(); v_status text;
        v_submit boolean := coalesce((p_data->>'submit')::boolean, false); v_b numeric; v_min numeric; v_max numeric;
        c_cam numeric := coalesce((app.setting('accounting')->>'xuat_bien_cam')::numeric, 0.02);
        c_duyet numeric := coalesce((app.setting('accounting')->>'xuat_bien_duyet')::numeric, 0.04);
        v_exported boolean := false; v_ver int := 1;
begin
  if p_id is not null then
    select * into v from public.out_invoices where id = p_id for update;
    if v.id is null then raise exception 'Không tìm thấy yêu cầu'; end if;
    if not (v_acc or app.in_tree(v.sale_id)) then raise exception 'Yêu cầu không thuộc bạn'; end if;
    if v.status in ('da_ky','huy') then raise exception 'Yêu cầu đã ký/đã hủy, không sửa được'; end if;
    if v.status = 'xac_nhan_ky' and not v_acc then raise exception 'Đã chốt — báo kế toán nếu cần sửa'; end if;
    v_exported := v.misa_at is not null or v.status in ('da_nhap','tra_sua','xac_nhan_ky');
    v_ver := v.version + case when v_exported then 1 else 0 end;
  end if;
  if jsonb_array_length(coalesce(p_lines, '[]')) = 0 then raise exception 'Chọn ít nhất 1 dòng hàng'; end if;
  if coalesce(btrim(p_data->>'buyer_name'), '') = '' then raise exception 'Nhập tên đơn vị mua hàng'; end if;
  if coalesce((p_data->>'save_buyer')::boolean, true) then
    select id into v_buyer from public.out_buyers where coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(nullif(p_data->>'customer_id','')::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
       and lower(btrim(name)) = lower(btrim(p_data->>'buyer_name')) and coalesce(btrim(tax_code), '') = coalesce(btrim(p_data->>'tax_code'), '');
    if v_buyer is null then
      insert into public.out_buyers(customer_id, name, tax_code, address, email, is_default)
      values (nullif(p_data->>'customer_id','')::uuid, btrim(p_data->>'buyer_name'), nullif(btrim(p_data->>'tax_code'), ''), nullif(btrim(p_data->>'address'), ''), nullif(btrim(p_data->>'email'), ''),
              nullif(p_data->>'customer_id','') is not null and not exists(select 1 from public.out_buyers b where b.customer_id = nullif(p_data->>'customer_id','')::uuid and b.is_default))
      returning id into v_buyer;
    else update public.out_buyers set address = coalesce(nullif(btrim(p_data->>'address'), ''), address), email = coalesce(nullif(btrim(p_data->>'email'), ''), email) where id = v_buyer; end if;
  end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    select * into t from public.out_items where id = (x->>'item_id')::uuid;
    if t.id is null then raise exception 'Dòng hàng không tồn tại'; end if;
    if not v_acc and not app.in_tree(t.sale_id) then raise exception 'Dòng % không phải của bạn', t.ma_hang; end if;
    if t.lech and t.lech_ok_at is null then raise exception 'Dòng % đang lệch so với nháp (%) — chờ kế toán xử lý', t.ma_hang, t.lech_note; end if;
    -- 1 yêu cầu = 1 khách
    if v_cust is not null and t.customer_id is not null and t.customer_id <> v_cust then raise exception 'Không gộp hàng của 2 khách vào 1 HĐ (dòng %)', t.ma_hang; end if;
    v_cust := coalesce(v_cust, t.customer_id);
    v_sale := coalesce(v_sale, t.sale_id);
    if coalesce((x->>'sl')::numeric, 0) <= 0 then raise exception 'Số lượng dòng % phải > 0', t.ma_hang; end if;
    if (x->>'sl')::numeric > t.sl_nhap - app.out_used(t.id, p_id) + 0.0001 then raise exception 'Dòng % chỉ còn tồn %', t.ma_hang, t.sl_nhap - app.out_used(t.id, p_id); end if;
    if coalesce((x->>'don_gia')::numeric, -1) < 0 then raise exception 'Nhập đơn giá dòng %', t.ma_hang; end if;
    v_b := app.out_bien((x->>'don_gia')::numeric, t.dg_nhap);
    if v_b is not null then
      if v_b < c_cam - 0.000001 then raise exception 'Dòng %: giá % chỉ cao hơn giá APT % là % — dưới % không được xuất', t.ma_hang, (x->>'don_gia')::numeric, t.dg_nhap, round(v_b * 100, 2) || '%', round(c_cam * 100, 2) || '%'; end if;
      v_min := least(coalesce(v_min, v_b), v_b); v_max := greatest(coalesce(v_max, v_b), v_b);
    end if;
  end loop;
  v_status := case when p_id is null then case when v_submit then 'cho_nhap' else 'soan' end
                   when v.status in ('da_nhap','xac_nhan_ky','tra_sua','cho_duyet_gia') then 'cho_nhap'
                   when v_submit and v.status = 'soan' then 'cho_nhap' else v.status end;
  if v_status = 'cho_nhap' and coalesce(v_max, 0) > c_duyet + 0.000001 then v_status := 'cho_duyet_gia'; end if;
  if p_id is null then
    insert into public.out_invoices(sale_id, customer_id, buyer_id, buyer_name, tax_code, address, email, payment, note, status, status_by, bien_min, bien_max)
    values (coalesce(v_sale, auth.uid()), coalesce(nullif(p_data->>'customer_id','')::uuid, v_cust), v_buyer, btrim(p_data->>'buyer_name'), nullif(btrim(p_data->>'tax_code'), ''), nullif(btrim(p_data->>'address'), ''),
            nullif(btrim(p_data->>'email'), ''), coalesce(nullif(p_data->>'payment', ''), 'TM/CK'), nullif(btrim(p_data->>'note'), ''), v_status, auth.uid(), v_min, v_max)
    returning id into v_id;
  else
    update public.out_invoices set customer_id = coalesce(nullif(p_data->>'customer_id','')::uuid, v_cust), buyer_id = coalesce(v_buyer, buyer_id), buyer_name = btrim(p_data->>'buyer_name'),
      tax_code = nullif(btrim(p_data->>'tax_code'), ''), address = nullif(btrim(p_data->>'address'), ''), email = nullif(btrim(p_data->>'email'), ''),
      payment = coalesce(nullif(p_data->>'payment', ''), payment), note = nullif(btrim(p_data->>'note'), ''),
      sua_sau_nhap = sua_sau_nhap or v_exported, status = v_status, version = v_ver, bien_min = v_min, bien_max = v_max,
      price_ok_by = null, price_ok_at = null, misa_at = case when v_exported then null else misa_at end, misa_by = case when v_exported then null else misa_by end,
      status_at = case when v_status <> v.status then now() else status_at end, status_by = auth.uid(), updated_at = now() where id = v_id;
    delete from public.out_invoice_lines where invoice_id = v_id;
  end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    k := k + 1;
    insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat)
    select v_id, oi.id, k, (x->>'sl')::numeric, (x->>'don_gia')::numeric, coalesce((x->>'vat')::numeric, oi.vat) from public.out_items oi where oi.id = (x->>'item_id')::uuid;
  end loop;
  update public.out_items oi set customer_id = nullif(p_data->>'customer_id','')::uuid
   where oi.customer_id is null and nullif(p_data->>'customer_id','') is not null and oi.id in (select item_id from public.out_invoice_lines where invoice_id = v_id);
  insert into public.out_events(invoice_id, action, note, data) values (v_id, case when p_id is null then 'create' else 'edit' end, nullif(btrim(p_data->>'note'), ''),
    jsonb_build_object('status', v_status, 'version', v_ver, 'bien_max', v_max));
  if v_status = 'cho_duyet_gia' and (p_id is null or v.status <> 'cho_duyet_gia') then
    perform app.notify_roles(array['ke_toan','tp_kd'], 'acc', 'Yêu cầu xuất HĐ chờ duyệt giá (biên ' || round(v_max * 100, 1) || '%)',
      (select code from public.out_invoices where id = v_id) || ' · ' || btrim(p_data->>'buyer_name'), '#/out?inv=' || v_id);
  elsif v_status = 'cho_nhap' and (p_id is null or v.status <> 'cho_nhap') then
    perform app.notify_roles(array['ke_toan'], 'acc', case when v_exported then 'Sale sửa yêu cầu sau khi đã export (v' || v_ver || ') — tạo lại nháp MISA' else 'Yêu cầu xuất HĐ mới' end,
      (select code from public.out_invoices where id = v_id) || ' · ' || btrim(p_data->>'buyer_name'), '#/out');
  end if;
  return v_id;
end $$;
grant execute on function public.out_invoice_save(uuid, jsonb, jsonb) to authenticated;

-- Duyệt giá (1 người là đủ)
create or replace function public.out_price_approve(p_ids uuid[], p_note text default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; n int := 0;
begin
  if not app.is_price_approver() then raise exception 'Chỉ Kế toán / Quản lý / Admin duyệt giá'; end if;
  for v in select * from public.out_invoices where id = any(p_ids) and status = 'cho_duyet_gia' for update loop
    update public.out_invoices set status = 'cho_nhap', price_ok_by = auth.uid(), price_ok_at = now(), status_at = now(), status_by = auth.uid(), updated_at = now() where id = v.id;
    insert into public.out_events(invoice_id, action, note, data) values (v.id, 'price_ok', p_note, jsonb_build_object('bien_max', v.bien_max));
    perform app.notify(v.sale_id, 'acc', 'Đã duyệt giá: ' || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out?inv=' || v.id);
    perform app.notify_roles(array['ke_toan'], 'acc', 'Yêu cầu xuất HĐ mới (đã duyệt giá): ' || v.code, coalesce(v.buyer_name, ''), '#/out');
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_price_approve(uuid[], text) to authenticated;

create or replace function public.out_invoice_status(p_ids uuid[], p_status text, p_note text default null, p_so_hd text default null, p_ngay date default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; n int := 0; v_acc boolean := app.is_acc(); ok boolean;
begin
  for v in select * from public.out_invoices where id = any(p_ids) for update loop
    if not (v_acc or app.in_tree(v.sale_id)) then raise exception 'Yêu cầu % không thuộc bạn', v.code; end if;
    ok := case p_status
      when 'cho_nhap' then v.status in ('soan','da_nhap','xac_nhan_ky','tra_sua') and not (v.status = 'soan' and coalesce(v.bien_max, 0) > coalesce((app.setting('accounting')->>'xuat_bien_duyet')::numeric, 0.04) + 0.000001)
      when 'cho_duyet_gia' then v.status = 'soan'
      when 'tra_sua' then v.status in ('da_nhap','xac_nhan_ky')
      when 'xac_nhan_ky' then v.status = 'da_nhap'
      when 'da_nhap' then v_acc and v.status in ('cho_nhap','xac_nhan_ky')
      when 'da_ky' then v_acc and v.status in ('xac_nhan_ky','da_nhap')
      when 'soan' then v_acc and v.status in ('cho_nhap','cho_duyet_gia','da_nhap','xac_nhan_ky','tra_sua')
      -- sale chỉ hủy được khi kế toán CHƯA export MISA
      when 'huy' then v.status <> 'da_ky' and (v_acc or (v.status in ('soan','cho_nhap','cho_duyet_gia') and v.misa_at is null))
      else false end;
    if not ok then
      if p_status = 'huy' and not v_acc and v.misa_at is not null then raise exception 'Yêu cầu % kế toán đã export MISA — không hủy được, chỉ sửa và gửi lại', v.code; end if;
      if p_status = 'cho_nhap' and v.status = 'soan' then raise exception 'Yêu cầu % có giá trên khung biên — lưu lại để vào Chờ duyệt giá', v.code; end if;
      raise exception 'Yêu cầu % đang "%", không chuyển sang "%" được', v.code, v.status, p_status;
    end if;
    if p_status = 'da_ky' and coalesce(btrim(coalesce(p_so_hd, v.so_hd)), '') = '' then raise exception 'Nhập số HĐ đã ký cho yêu cầu %', v.code; end if;
    if p_status in ('soan','huy') and v_acc and not app.in_tree(v.sale_id) and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do'; end if;
    if p_status in ('tra_sua') and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi nội dung cần sửa'; end if;
    if p_status = 'cho_nhap' and v.status in ('da_nhap','xac_nhan_ky') and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi nội dung cần sửa'; end if;
    update public.out_invoices set status = p_status, status_at = now(), status_by = auth.uid(), updated_at = now(),
      so_hd = case when p_status = 'da_ky' then coalesce(nullif(btrim(p_so_hd), ''), so_hd) else so_hd end,
      ngay_hd = case when p_status = 'da_ky' then coalesce(p_ngay, ngay_hd, current_date) else ngay_hd end,
      version = case when p_status = 'cho_nhap' and v.status in ('da_nhap','xac_nhan_ky','tra_sua') then version + 1 else version end,
      sua_sau_nhap = case when p_status = 'da_nhap' then false when p_status = 'cho_nhap' and v.status in ('da_nhap','xac_nhan_ky','tra_sua') then true else sua_sau_nhap end
    where id = v.id;
    insert into public.out_events(invoice_id, action, note, data) values (v.id, 'status', p_note, jsonb_build_object('from', v.status, 'to', p_status, 'so_hd', p_so_hd));
    if p_status in ('cho_nhap','xac_nhan_ky') then
      perform app.notify_roles(array['ke_toan'], 'acc', case when p_status = 'xac_nhan_ky' then 'Sale đã chốt — chờ ký: ' when v.status in ('da_nhap','xac_nhan_ky','tra_sua') then 'Yêu cầu sửa nháp: ' else 'Yêu cầu xuất HĐ mới: ' end || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out?inv=' || v.id);
    elsif p_status = 'tra_sua' then
      perform app.notify_roles(array['ke_toan'], 'acc', 'Sale trả sửa nháp: ' || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out?inv=' || v.id);
    elsif p_status in ('da_nhap','da_ky','soan') or (p_status = 'huy' and v_acc) then
      perform app.notify(v.sale_id, 'acc', case p_status when 'da_nhap' then 'Có HĐ nháp — gửi khách: ' when 'da_ky' then 'Đã ký HĐ — báo khách kiểm tra email: '
        when 'soan' then 'Kế toán trả lại yêu cầu: ' else 'Kế toán hủy yêu cầu: ' end || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out?inv=' || v.id);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_invoice_status(uuid[], text, text, text, date) to authenticated;

-- Pháp nhân mặc định của khách
create or replace function public.out_buyer_set_default(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers;
begin
  select * into b from public.out_buyers where id = p_id;
  if b.id is null or b.customer_id is null then raise exception 'Pháp nhân chưa gắn khách'; end if;
  if not (app.is_acc() or exists(select 1 from public.customers c where c.id = b.customer_id and app.in_tree(c.owner_id))) then raise exception 'Không có quyền'; end if;
  update public.out_buyers set is_default = false where customer_id = b.customer_id and is_default and id <> p_id;
  update public.out_buyers set is_default = true where id = p_id;
end $$;
grant execute on function public.out_buyer_set_default(uuid) to authenticated;

-- Đơn "sạch" để xuất hàng loạt: đủ HĐ vào, không lệch, không chờ, khách có pháp nhân mặc định
create or replace function public.out_clean_orders(p_mds text[] default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return (select coalesce(jsonb_agg(z order by z.md), '[]') from (
    select t.md, min(t.customer_id::text)::uuid customer_id, min(t.sale_id::text)::uuid sale_id, count(*) n,
      sum((t.sl_nhap - app.out_used(t.id)) * coalesce(t.gia_khach, 0)) tien,
      case when bool_or(t.lech and t.lech_ok_at is null) then 'Có dòng lệch đang khóa'
           when bool_or(t.gia_khach is null or t.gia_khach <= 0) then 'Có dòng chưa có giá khách'
           when count(distinct t.customer_id) > 1 or bool_or(t.customer_id is null) then 'Chưa xác định 1 khách'
           when not exists(select 1 from public.out_buyers b where b.customer_id = min(t.customer_id::text)::uuid and b.is_default) then 'Khách chưa có pháp nhân mặc định'
           when bool_or(app.out_bien(t.gia_khach, t.dg_nhap) < coalesce((app.setting('accounting')->>'xuat_bien_cam')::numeric, 0.02) - 0.000001) then 'Giá khách dưới biên 2%'
           when bool_or(app.out_bien(t.gia_khach, t.dg_nhap) > coalesce((app.setting('accounting')->>'xuat_bien_duyet')::numeric, 0.04) + 0.000001) then 'Giá khách trên biên 4% — cần duyệt'
           when bool_or(app.out_used(t.id) > 0) then 'Đơn đã có yêu cầu một phần'
           when exists(select 1 from public.acc_lines l where l.md = t.md and not l.is_test and l.apt_stt is not null and l.luong in ('A','B')
                         and not exists(select 1 from public.out_items x where x.acc_line_id = l.id)) then 'Đơn chưa đủ HĐ vào'
      end ly_do
    from public.out_items t
    where t.md is not null and (app.is_acc() or app.in_tree(t.sale_id)) and (p_mds is null or t.md = any(p_mds))
      and t.sl_nhap - app.out_used(t.id) > 0.0001
    group by t.md) z);
end $$;
grant execute on function public.out_clean_orders(text[]) to authenticated;

-- Báo cáo tồn HĐ đầu vào chưa xuất, theo sale
create or replace function public.out_ton_report(p_den date default current_date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return (select coalesce(jsonb_agg(z order by z.tien desc), '[]') from (
    select t.sale_id, count(*) so_dong, count(distinct t.md) so_don, sum(t.sl_nhap - app.out_used(t.id)) sl_ton,
      round(sum((t.sl_nhap - app.out_used(t.id)) * coalesce(t.dg_nhap, 0))) tien,
      max(p_den - t.ngay_vao) ngay_ton_max, count(*) filter (where p_den - t.ngay_vao > 15) qua_15
    from public.out_items t
    where (app.is_acc() or app.in_tree(t.sale_id)) and t.sl_nhap - app.out_used(t.id) > 0.0001 and (t.ngay_vao is null or t.ngay_vao <= p_den)
    group by t.sale_id) z);
end $$;
grant execute on function public.out_ton_report(date) to authenticated;

-- Gợi ý pháp nhân nhận HĐ (bản 23): pháp nhân MẶC ĐỊNH → phiếu gần nhất → danh sách đơn vị → hồ sơ khách
create or replace function public.out_buyer_suggest(p_customers uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare c record; out jsonb := '{}'; v jsonb;
begin
  for c in select * from public.customers where id = any(p_customers) and deleted_at is null and (app.is_acc() or app.in_tree(owner_id)) loop
    select jsonb_build_object('name', name, 'tax_code', tax_code, 'address', address, 'email', email, 'src', 'pháp nhân mặc định', 'buyer_id', id) into v
      from public.out_buyers where customer_id = c.id and is_default limit 1;
    if v is null then
    select jsonb_build_object('name', buyer_name, 'tax_code', tax_code, 'address', address, 'email', email, 'payment', payment, 'src', 'phiếu ' || code) into v
      from public.out_invoices where customer_id = c.id and status <> 'huy' and coalesce(btrim(buyer_name), '') <> '' order by created_at desc limit 1;
    end if;
    if v is null then
      select jsonb_build_object('name', name, 'tax_code', tax_code, 'address', address, 'email', email, 'src', 'danh sách đơn vị') into v
        from public.out_buyers where customer_id = c.id order by created_at desc limit 1;
    end if;
    if v is null and coalesce(btrim(coalesce(c.company_name, '')), '') <> '' then
      v := jsonb_build_object('name', c.company_name, 'tax_code', c.tax_code, 'address', coalesce(c.legal_address, c.address), 'email', c.email, 'src', 'hồ sơ khách');
    end if;
    if v is null then v := jsonb_build_object('name', coalesce(c.contact_name, ''), 'tax_code', c.tax_code, 'address', coalesce(c.legal_address, c.address), 'email', c.email, 'src', 'tên liên hệ', 'weak', true); end if;
    out := out || jsonb_build_object(c.id::text, v); v := null;
  end loop;
  return out;
end $$;
grant execute on function public.out_buyer_suggest(uuid[]) to authenticated;

-- Danh sách pháp nhân nhận HĐ của 1 khách (sale chọn khi tạo yêu cầu, đặt mặc định)
create or replace function public.out_buyers_of(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.is_acc() or exists(select 1 from public.customers c where c.id = p_customer and app.in_tree(c.owner_id))) then raise exception 'Không có quyền'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'tax_code', tax_code, 'address', address, 'email', email, 'is_default', is_default) order by is_default desc, created_at desc), '[]')
    from public.out_buyers where customer_id = p_customer);
end $$;
grant execute on function public.out_buyers_of(uuid) to authenticated;

-- ---------- Sổ / bảng gốc: lọc dòng lệch đang khóa, dòng chưa ghép ----------
create or replace function public.out_items_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_mode text := coalesce(p->>'mode', 'acc'); v_f text := nullif(p->>'f', ''); v_q text := nullif(btrim(p->>'q'), '');
        v_hd text := nullif(p->>'hd', ''); v_xe text := nullif(p->>'xe', ''); v_sale text := nullif(p->>'sale', ''); v_kh text := nullif(p->>'kh', ''); v_sort text := coalesce(nullif(p->>'sort', ''), 'moi'); v_md text := nullif(p->>'md', '');
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint;
begin
  with s as (select * from app.out_items_scope(v_mode)),
  a as (select l.item_id, sum(l.sl) sl, string_agg(i.code || ':' || i.status, ',' order by i.code) phieu
          from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id
         where i.status <> 'huy' and l.item_id in (select id from s) group by l.item_id),
  b as (select s.*, coalesce(a.sl, 0) sl_xuat, s.sl_nhap - coalesce(a.sl, 0) ton, a.phieu, coalesce(c.company_name, c.contact_name) khach, x.xe
          from s left join a on a.item_id = s.id left join public.customers c on c.id = s.customer_id left join public.out_hd_xe x on x.so_hd = ltrim(s.so_hd_vao, '0')),
  f as (select * from b t
     where (v_mode = 'acc' or t.ton > 0.0001)
       and (v_f is null or (v_f = 'ton' and t.ton > 0.0001) or (v_f = 'het' and t.ton <= 0.0001)
            or (v_f = 'nosale' and t.sale_id is null and t.ton > 0.0001) or (v_f = 'daky_nosale' and t.sale_id is null and t.ton <= 0.0001)
            or (v_f = 'nomd' and t.md is null) or (v_f = 'nogia' and t.gia_khach is null and t.ton > 0.0001)
            or (v_f = 'nokhach' and t.customer_id is null and t.username is null)
            or (v_f = 'nhieu_gia' and t.gia_n > 1 and t.gia_khach is null and t.ton > 0.0001)
            or (v_f = 'lech' and t.lech and t.lech_ok_at is null) or (v_f = 'chua_ghep' and t.acc_line_id is null and t.ton > 0.0001))
       and (v_md is null or t.md = v_md)
       and (v_hd is null or t.so_hd_vao = v_hd) and (v_xe is null or coalesce(t.xe, '—') = v_xe)
       and (v_sale is null or coalesce(t.sale_id::text, '—') = v_sale)
       and (v_kh is null or coalesce(t.customer_id::text, t.username, '—') = v_kh)
       and (v_q is null or concat_ws(' ', t.ma_hang, t.ten, t.md, t.nvkd, t.username, t.khach, t.so_hd_vao, t.xe) ilike '%' || v_q || '%')),
  o as (select f.*, row_number() over (order by
          case when v_sort = 'md' then f.md end asc nulls last, case when v_sort = 'kh' then lower(coalesce(f.khach, f.username)) end asc nulls last,
          case when v_sort in ('md', 'kh') then f.md end asc nulls last, f.stt_so desc nulls last, f.ma_hang, f.part) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r);
end $$;
grant execute on function public.out_items_page(jsonb) to authenticated;

create or replace function public.out_items_stats(p_mode text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb;
begin
  with s as (select * from app.out_items_scope(p_mode)),
  a as (select l.item_id, sum(l.sl) sl from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id
         where i.status <> 'huy' and l.item_id in (select id from s) group by l.item_id),
  b as (select s.id, s.sale_id, s.md, s.customer_id, s.username, s.gia_khach, s.gia_n, s.dg_nhap, s.so_hd_vao, s.sl_nhap - coalesce(a.sl, 0) ton, s.lech, s.lech_ok_at, s.acc_line_id,
               x.xe, coalesce(c.company_name, c.contact_name) khach
          from s left join a on a.item_id = s.id left join public.out_hd_xe x on x.so_hd = ltrim(s.so_hd_vao, '0') left join public.customers c on c.id = s.customer_id),
  v as (select * from b where p_mode = 'acc' or ton > 0.0001)
  select jsonb_build_object(
    'all', count(*), 'ton', count(*) filter (where ton > 0.0001), 'het', count(*) filter (where ton <= 0.0001),
    'nosale', count(*) filter (where sale_id is null and ton > 0.0001), 'daky_nosale', count(*) filter (where sale_id is null and ton <= 0.0001),
    'nomd', count(*) filter (where md is null), 'nogia', count(*) filter (where gia_khach is null and ton > 0.0001),
    'nokhach', count(*) filter (where customer_id is null and username is null),
    'nhieu_gia', count(*) filter (where gia_n > 1 and gia_khach is null and ton > 0.0001),
    'lech', count(*) filter (where lech and lech_ok_at is null), 'chua_ghep', count(*) filter (where acc_line_id is null and ton > 0.0001),
    'gia_tri', coalesce(sum(ton * coalesce(gia_khach, dg_nhap, 0)) filter (where ton > 0.0001), 0),
    'hd', coalesce((select jsonb_agg(distinct so_hd_vao) from v where so_hd_vao is not null), '[]'),
    'xe', coalesce((select jsonb_agg(distinct coalesce(xe, '—')) from v), '[]'),
    'kh', coalesce((select jsonb_agg(jsonb_build_array(k, t) order by t) from (select distinct coalesce(customer_id::text, username) k, coalesce(khach, username) t from v where coalesce(customer_id::text, username) is not null) z), '[]'),
    'sale', coalesce((select jsonb_agg(distinct coalesce(sale_id::text, '—')) from v), '[]'))
  into r from v;
  return r;
end $$;
grant execute on function public.out_items_stats(text) to authenticated;

reset search_path;
