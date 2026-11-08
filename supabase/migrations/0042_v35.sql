-- =====================================================================
-- 0042 · Bản 35 (08/11/2026)
--  A. Nạp HĐ chính thức APT bằng file XML gốc: mã hàng ERP tự sinh = {mã khai báo}-{số HĐ} (VD M3433-2-2080)
--     · dòng XML chưa ghép được nháp → mã tạm CHUAKB-{số HĐ}-{STT}; ghép tay xong tự đổi sang mã chuẩn
--     · nạp lại cùng file: khớp theo số HĐ + ký hiệu + STT dòng → không tạo trùng
--  B. Tra cứu MST: bộ nhớ đệm mst_cache (hàm máy chủ "mst"), lưu kết quả tra cứu lên phiếu xuất HĐ (mst_check)
--  C. Bộ chứng từ đi kèm HĐ đã ký: pháp nhân có thêm Người đại diện, Chức vụ, Địa chỉ giao hàng, Mã + ngày HĐ nguyên tắc
--     · out_docs_data: dữ liệu ĐĐH / BBGN / HĐMB / HĐNT theo phiếu (đúng phạm vi xem phiếu)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 35');

-- ---------------- A. XML HĐ chính thức ----------------
alter table public.out_items add column if not exists ma_auto boolean not null default false;

/** Mã hàng chuẩn của dòng nạp từ XML: {mã khai báo}-{số HĐ}; chưa có mã khai báo → CHUAKB-{số HĐ}-{STT} */
create or replace function app.out_item_automa(p_id uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; v_kb text; v_ma text;
begin
  select * into t from public.out_items where id = p_id;
  if t.id is null or not t.ma_auto then return; end if;
  v_kb := t.ma_kb;
  if v_kb is null and t.acc_line_id is not null then
    select nullif(btrim(coalesce(l.ma_dong, l.ma_kb_apt)), '') into v_kb from public.acc_lines l where l.id = t.acc_line_id;
  end if;
  v_ma := case when v_kb is not null then upper(v_kb) || '-' || coalesce(nullif(ltrim(t.so_hd_vao, '0'), ''), '0')
               else 'CHUAKB-' || coalesce(nullif(ltrim(t.so_hd_vao, '0'), ''), '0') || '-' || coalesce(t.stt_hd::text, '0') end;
  if v_ma is distinct from t.ma_hang and not exists(select 1 from public.out_items x where x.ma_hang = v_ma and x.part = t.part and x.id <> t.id) then
    update public.out_items set ma_hang = v_ma, ma_kb = coalesce(ma_kb, v_kb) where id = p_id;
  end if;
end $$;

create or replace function public.out_items_import(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_id uuid; n_new int := 0; n_upd int := 0; v_ids uuid[] := '{}'; v_line uuid; t public.out_items; v_xml boolean; v_part int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_xml := coalesce(r->>'src', '') = 'xml'; v_part := coalesce((r->>'part')::int, 1); t := null;
    -- Bản 35: nạp lại XML → nhận dòng cũ theo số HĐ + ký hiệu + STT dòng (mã hàng có thể đã đổi do ghép lại)
    if v_xml and (r->>'stt_hd') is not null then
      select * into t from public.out_items x
       where x.ma_auto and ltrim(x.so_hd_vao, '0') = ltrim(r->>'so_hd_vao', '0') and coalesce(right(x.ky_hieu, 6), '') = coalesce(right(r->>'ky_hieu', 6), '')
         and x.stt_hd = (r->>'stt_hd')::int limit 1;
      if t.id is not null and t.ma_hang is distinct from r->>'ma_hang'
         and not exists(select 1 from public.out_items x where x.ma_hang = r->>'ma_hang' and x.part = v_part and x.id <> t.id) then
        update public.out_items set ma_hang = r->>'ma_hang', part = v_part where id = t.id;
        select * into t from public.out_items where id = t.id;
      end if;
    end if;
    if t.id is null then select * into t from public.out_items where ma_hang = r->>'ma_hang' and part = v_part; end if;
    v_id := t.id;
    if v_id is null then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
    v_line := nullif(r->>'acc_line_id', '')::uuid;
    if v_line is not null and not exists(select 1 from public.acc_lines where id = v_line) then v_line := null; end if;
    insert into public.out_items as x(ma_hang, part, stt_so, ten, dvt, vat, sl_nhap, dg_nhap, so_hd_vao, ky_hieu, ngay_vao, ncc, stt_hd, md, nvkd, username, gia_so, legacy, ma_auto, updated_at, updated_by)
    values (coalesce(t.ma_hang, r->>'ma_hang'), coalesce(t.part, v_part), (r->>'stt_so')::numeric, r->>'ten', r->>'dvt', (r->>'vat')::numeric, coalesce((r->>'sl_nhap')::numeric, 0), (r->>'dg_nhap')::numeric,
            r->>'so_hd_vao', r->>'ky_hieu', nullif(r->>'ngay_vao','')::date, r->>'ncc', (r->>'stt_hd')::int,
            case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end, nullif(btrim(r->>'nvkd'), ''), nullif(btrim(r->>'username'), ''),
            nullif((r->>'gia_so')::numeric, 0), r->'legacy', v_xml, now(), auth.uid())
    on conflict (ma_hang, part) do update set stt_so = excluded.stt_so, ten = excluded.ten, dvt = excluded.dvt, vat = excluded.vat, sl_nhap = excluded.sl_nhap, dg_nhap = excluded.dg_nhap,
      so_hd_vao = excluded.so_hd_vao, ky_hieu = excluded.ky_hieu, ngay_vao = excluded.ngay_vao, ncc = excluded.ncc, stt_hd = excluded.stt_hd,
      md = case when coalesce(x.match_src, '') = 'tay' then x.md else coalesce(excluded.md, x.md) end, nvkd = coalesce(excluded.nvkd, x.nvkd),
      username = case when coalesce(x.match_src, '') = 'tay' then x.username else coalesce(excluded.username, x.username) end,
      sale_id = case when coalesce(x.match_src, '') <> 'tay' and excluded.nvkd is not null and app.match_sale(excluded.nvkd) is not null then app.match_sale(excluded.nvkd) else x.sale_id end,
      gia_so = coalesce(excluded.gia_so, x.gia_so), legacy = excluded.legacy, ma_auto = x.ma_auto or excluded.ma_auto, updated_at = now(), updated_by = auth.uid()
    returning id into v_id;
    -- gắn đúng dòng nháp đã đối chiếu trên màn hình (trừ dòng kế toán đã ghép tay)
    if v_line is not null and coalesce(t.match_src, '') <> 'tay' and t.acc_line_id is distinct from v_line then
      if exists(select 1 from public.out_items o where o.acc_line_id = v_line and o.id <> v_id) then
        update public.out_items set acc_line_id = null where acc_line_id = v_line and id <> v_id and coalesce(match_src, '') <> 'tay';
      end if;
      update public.out_items set acc_line_id = v_line, match_src = 'ten', ma_kb = null,
        md = case when t.id is null or t.acc_line_id is null then md else null end,
        sale_id = case when t.id is null or t.acc_line_id is null then sale_id else null end,
        customer_id = case when t.id is null or t.acc_line_id is null then customer_id else null end,
        username = case when t.id is null or t.acc_line_id is null then username else null end,
        gia_khach = case when gia_src = 'sale' then gia_khach else null end, gia_src = case when gia_src = 'sale' then gia_src else null end,
        lech = false, lech_note = null, lech_ok_by = null, lech_ok_at = null, lech_ok_note = null
      where id = v_id;
    end if;
    perform app.out_item_match(v_id); perform app.out_item_automa(v_id); v_ids := v_ids || v_id;
  end loop;
  for v_id in select id from public.out_items where id = any(v_ids) and md is not null and (sale_id is null or username is null) loop perform app.out_item_match(v_id); end loop;
  insert into public.out_events(action, data) values ('import', jsonb_build_object('new', n_new, 'upd', n_upd, 'xml', exists(select 1 from jsonb_array_elements(p_rows) e where e->>'src' = 'xml')));
  return jsonb_build_object('new', n_new, 'upd', n_upd);
end $$;
grant execute on function public.out_items_import(jsonb) to authenticated;

-- Ghép tay sang dòng nháp khác → dòng XML đổi mã hàng theo mã khai báo mới
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
  perform app.out_item_automa(p_id);
  insert into public.out_events(item_id, action, data) values (p_id, 'relink', jsonb_build_object('line', p_line));
end $$;
grant execute on function public.out_item_relink(uuid, uuid) to authenticated;

-- ---------------- B. Tra cứu MST ----------------
create table if not exists public.mst_cache(
  mst text primary key, provider text not null, data jsonb not null, at timestamptz not null default now()
);
alter table public.mst_cache enable row level security;   -- chỉ hàm máy chủ (service role) đọc / ghi

alter table public.out_invoices add column if not exists mst_check jsonb;
/** Lưu kết quả tra cứu MST lên phiếu (sale / CSKH / cấp trên của phiếu, kế toán) — kế toán xem khi xuất nháp */
create or replace function public.out_invoice_mst(p_id uuid, p_check jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices;
begin
  select * into v from public.out_invoices where id = p_id;
  if v.id is null then raise exception 'Không thấy phiếu'; end if;
  if not (app.is_acc() or app.in_tree(v.sale_id) or v.created_by = auth.uid()) then raise exception 'Không có quyền với phiếu này'; end if;
  update public.out_invoices set mst_check = case when p_check is null or p_check = 'null'::jsonb then null else p_check || jsonb_build_object('by', auth.uid()) end where id = p_id;
end $$;
grant execute on function public.out_invoice_mst(uuid, jsonb) to authenticated;

-- ---------------- C. Bộ chứng từ ----------------
alter table public.out_buyers add column if not exists dai_dien text;
alter table public.out_buyers add column if not exists chuc_vu text;
alter table public.out_buyers add column if not exists dia_chi_giao text;
alter table public.out_buyers add column if not exists ma_hdnt text;
alter table public.out_buyers add column if not exists ngay_hdnt date;

/** Ngày ký HĐNT: điền tay, không thì đọc từ mã dạng 28/08/2026/HĐNTHH/... */
create or replace function app.hdnt_ngay(p_ma text, p_ngay date) returns date language plpgsql immutable as $$
declare m text[];
begin
  if p_ngay is not null then return p_ngay; end if;
  m := regexp_match(coalesce(p_ma, ''), '^\s*(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})');
  if m is null then return null; end if;
  begin return make_date(m[3]::int, m[2]::int, m[1]::int); exception when others then return null; end;
end $$;

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
           'co_hdnt', count(*) filter (where ma_hdnt is not null), 'thieu_dd', count(*) filter (where dai_dien is null),
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
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c);
end $$;
grant execute on function public.out_buyers_page(jsonb) to authenticated;

-- Thêm / sửa 1 pháp nhân. p: {username, name, tax_code, address, email, note, is_default, dai_dien, chuc_vu, dia_chi_giao, ma_hdnt, ngay_hdnt}
-- Trường chứng từ không gửi lên thì giữ nguyên
create or replace function public.out_buyer_save(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers; v_user text := app.norm_username(nullif(btrim(p->>'username'), '')); v_c uuid; v_mst text := nullif(regexp_replace(coalesce(p->>'tax_code', ''), '\s', '', 'g'), '');
        v_name text := nullif(regexp_replace(btrim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), ''); v_id uuid := p_id; v_ngay date;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ sửa pháp nhân'; end if;
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
  if exists(select 1 from public.out_buyers x where x.id is distinct from v_id and btrim(x.tax_code) = v_mst
              and (v_c is not null and x.customer_id = v_c or v_c is null and x.customer_id is null and lower(coalesce(x.username, '')) = lower(coalesce(v_user, '')))) then
    raise exception 'Username % đã có pháp nhân MST % — sửa dòng đó thay vì thêm mới', coalesce(v_user, '(trống)'), v_mst;
  end if;
  if v_id is null then
    insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note, dai_dien, chuc_vu, dia_chi_giao, ma_hdnt, ngay_hdnt, updated_at, updated_by)
    values (v_c, v_user, v_name, v_mst, nullif(btrim(p->>'address'), ''), nullif(btrim(p->>'email'), ''), coalesce(nullif(btrim(p->>'note'), ''), 'Nhập tay'),
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

-- Nạp Excel: thêm cột chứng từ (Người đại diện, Chức vụ, Địa chỉ giao hàng, Mã HĐ nguyên tắc, Ngày HĐNT) — ô trống thì giữ nguyên
create or replace function public.out_buyers_import_v2(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; k int := 0; n_moi int := 0; n_sua int := 0; loi jsonb := '[]'; v_id uuid; v_mst text; v_c uuid; v_user text; v_name text; v_ngay date;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    k := k + 1;
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), '');
    v_name := nullif(regexp_replace(btrim(coalesce(r->>'name', '')), '\s+', ' ', 'g'), '');
    if v_mst is null or v_name is null then continue; end if;
    begin
      v_c := null; v_id := null; v_user := app.norm_username(nullif(btrim(r->>'username'), ''));
      v_ngay := app.hdnt_ngay(r->>'ma_hdnt', nullif(btrim(r->>'ngay_hdnt'), '')::date);
      if v_user is not null then
        select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(v_user) or upper(btrim(sys_code)) = upper(v_user)) order by created_at limit 1;
      end if;
      select id into v_id from public.out_buyers b
       where btrim(b.tax_code) = v_mst and lower(btrim(b.name)) = lower(v_name)
         and (v_c is not null and b.customer_id = v_c or v_c is null and b.customer_id is null and lower(coalesce(b.username, '')) = lower(coalesce(v_user, '')))
       limit 1;
      if v_id is null then
        select id into v_id from public.out_buyers b
         where btrim(b.tax_code) = v_mst
           and (v_c is not null and b.customer_id = v_c or v_c is null and b.customer_id is null and lower(coalesce(b.username, '')) = lower(coalesce(v_user, '')))
         order by b.is_default desc, b.created_at desc limit 1;
      end if;
      if v_id is not null then
        update public.out_buyers set name = v_name, username = coalesce(v_user, username), address = coalesce(nullif(btrim(r->>'address'), ''), address),
          email = coalesce(nullif(btrim(r->>'email'), ''), email),
          dai_dien = coalesce(nullif(btrim(r->>'dai_dien'), ''), dai_dien), chuc_vu = coalesce(nullif(btrim(r->>'chuc_vu'), ''), chuc_vu),
          dia_chi_giao = coalesce(nullif(btrim(r->>'dia_chi_giao'), ''), dia_chi_giao), ma_hdnt = coalesce(nullif(btrim(r->>'ma_hdnt'), ''), ma_hdnt),
          ngay_hdnt = coalesce(v_ngay, ngay_hdnt), updated_at = now(), updated_by = auth.uid() where id = v_id;
        n_sua := n_sua + 1; continue;
      end if;
      insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note, dai_dien, chuc_vu, dia_chi_giao, ma_hdnt, ngay_hdnt, updated_at, updated_by)
      values (v_c, v_user, v_name, v_mst, nullif(btrim(r->>'address'), ''), nullif(btrim(r->>'email'), ''), 'Danh sách kế toán',
              nullif(btrim(r->>'dai_dien'), ''), nullif(btrim(r->>'chuc_vu'), ''), nullif(btrim(r->>'dia_chi_giao'), ''), nullif(btrim(r->>'ma_hdnt'), ''), v_ngay, now(), auth.uid());
      n_moi := n_moi + 1;
    exception when others then
      loi := loi || jsonb_build_object('dong', k, 'name', v_name, 'tax_code', v_mst, 'username', r->>'username',
        'error', case when sqlstate = '23505' then 'Trùng: khách / username này đã có pháp nhân cùng tên + MST' when sqlstate = '22007' or sqlstate = '22008' then 'Ngày HĐ nguyên tắc sai dạng' else sqlerrm end);
    end;
  end loop;
  perform app.out_buyers_relink();
  return jsonb_build_object('n', n_moi + n_sua, 'moi', n_moi, 'sua', n_sua, 'loi', loi);
end $$;
grant execute on function public.out_buyers_import_v2(jsonb) to authenticated;

/** Sale / CSKH / cấp trên điền Người đại diện, Chức vụ, Địa chỉ giao hàng cho pháp nhân của khách mình (mã HĐNT chỉ kế toán) */
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
  update public.out_buyers set
    dai_dien = case when p ? 'dai_dien' then nullif(btrim(p->>'dai_dien'), '') else dai_dien end,
    chuc_vu = case when p ? 'chuc_vu' then nullif(btrim(p->>'chuc_vu'), '') else chuc_vu end,
    dia_chi_giao = case when p ? 'dia_chi_giao' then nullif(btrim(p->>'dia_chi_giao'), '') else dia_chi_giao end,
    updated_at = now(), updated_by = auth.uid()
   where id = p_id;
end $$;
grant execute on function public.out_buyer_doc_info(uuid, jsonb) to authenticated;

/** Dữ liệu bộ chứng từ (ĐĐH, BBGN, HĐMB, HĐNT) theo phiếu — đúng phạm vi xem phiếu */
create or replace function public.out_docs_data(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return (select coalesce(jsonb_agg(x order by x->>'so_hd', x->>'code'), '[]') from (
    select jsonb_build_object(
      'id', i.id, 'code', i.code, 'status', i.status, 'so_hd', i.so_hd, 'sale_id', i.sale_id, 'customer_id', i.customer_id,
      'ngay_hd', coalesce(i.ngay_hd, (i.status_at at time zone 'Asia/Ho_Chi_Minh')::date),
      'buyer_name', i.buyer_name, 'tax_code', i.tax_code, 'address', i.address, 'payment', i.payment,
      'buyer', (select jsonb_build_object('id', b.id, 'dai_dien', b.dai_dien, 'chuc_vu', b.chuc_vu, 'dia_chi_giao', b.dia_chi_giao,
                         'ma_hdnt', b.ma_hdnt, 'ngay_hdnt', app.hdnt_ngay(b.ma_hdnt, b.ngay_hdnt))
                  from public.out_buyers b
                 where b.id = i.buyer_id or (coalesce(btrim(i.tax_code), '') <> '' and btrim(b.tax_code) = btrim(i.tax_code))
                 order by coalesce(b.id = i.buyer_id, false) desc, (b.customer_id is not distinct from i.customer_id) desc, (b.ma_hdnt is not null) desc,
                          (b.dai_dien is not null) desc, b.updated_at desc nulls last limit 1),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('ten', it.ten, 'dvt', it.dvt, 'sl', l.sl, 'don_gia', l.don_gia, 'vat', coalesce(l.vat, it.vat), 'ma_hang', it.ma_hang) order by l.stt, l.id), '[]')
                  from public.out_invoice_lines l join public.out_items it on it.id = l.item_id where l.invoice_id = i.id)) x
      from public.out_invoices i
     where i.id = any(p_ids) and i.status <> 'huy' and (app.is_acc() or app.in_tree(i.sale_id))) s);
end $$;
grant execute on function public.out_docs_data(uuid[]) to authenticated;

reset search_path;
