-- =====================================================================
-- 0023 · Bản 16: rà soát khớp nối kế toán – hóa đơn
--  · HĐ XML / xe nạp sau → sổ HĐ đầu ra tự gắn lại ID đơn, sale, giá khách
--  · Kế toán/sale chốt, nhận dòng, sửa MD/giá khách ở đối soát → sổ đầu ra cập nhật theo
--  · Dòng sổ sửa tay giữ nguyên khi nạp lại; phiếu cũ (sổ cũ) tự gán sale khi dòng có sale
--  · Nhớ khách cho dòng hàng sau khi lập phiếu; giá xuất < giá nhập phải ghi lý do
--  · Dòng "chuyển xe sau" (không lên xe) kế toán chốt → đóng theo dõi
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 16');

create or replace function public.out_items_import(p_rows jsonb, p_legacy jsonb default '[]') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_id uuid; n_new int := 0; n_upd int := 0; n_leg int := 0; g jsonb; x jsonb; v_inv uuid; v_item uuid; v_st text; k int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select id into v_id from public.out_items where ma_hang = r->>'ma_hang';
    if v_id is null then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
    insert into public.out_items as t(ma_hang, stt_so, ten, dvt, vat, sl_nhap, dg_nhap, so_hd_vao, ky_hieu, ngay_vao, ncc, stt_hd, md, nvkd, username, legacy, updated_at, updated_by)
    values (r->>'ma_hang', (r->>'stt_so')::numeric, r->>'ten', r->>'dvt', (r->>'vat')::numeric, coalesce((r->>'sl_nhap')::numeric, 0), (r->>'dg_nhap')::numeric,
            r->>'so_hd_vao', r->>'ky_hieu', nullif(r->>'ngay_vao','')::date, r->>'ncc', (r->>'stt_hd')::int, case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end, nullif(btrim(r->>'nvkd'), ''), nullif(btrim(r->>'username'), ''),
            r->'legacy', now(), auth.uid())
    on conflict (ma_hang) do update set stt_so = excluded.stt_so, ten = excluded.ten, dvt = excluded.dvt, vat = excluded.vat, sl_nhap = excluded.sl_nhap, dg_nhap = excluded.dg_nhap,
      so_hd_vao = excluded.so_hd_vao, ky_hieu = excluded.ky_hieu, ngay_vao = excluded.ngay_vao, ncc = excluded.ncc, stt_hd = excluded.stt_hd,
      -- ID/NVKD/USER trên file có giá trị thì theo file; trống thì giữ phần đã gắn
      md = case when coalesce(t.match_src, '') = 'tay' then t.md else coalesce(excluded.md, t.md) end, nvkd = coalesce(excluded.nvkd, t.nvkd),
      username = case when coalesce(t.match_src, '') = 'tay' then t.username else coalesce(excluded.username, t.username) end,
      sale_id = case when coalesce(t.match_src, '') <> 'tay' and excluded.nvkd is not null and app.match_sale(excluded.nvkd) is not null then app.match_sale(excluded.nvkd) else t.sale_id end,
      legacy = excluded.legacy, updated_at = now(), updated_by = auth.uid()
    returning id into v_id;
    perform app.out_item_match(v_id);
  end loop;
  -- Phiếu cũ (đã nháp/đã ký trên file) → tạo phiếu "từ file cũ" để không phải làm lại; dòng đã có phiếu thì bỏ qua
  for g in select * from jsonb_array_elements(coalesce(p_legacy, '[]')) loop
    if exists(select 1 from jsonb_array_elements(g->'lines') e(v) join public.out_items t on t.ma_hang = e.v->>'ma_hang' join public.out_invoice_lines l on l.item_id = t.id) then continue; end if;
    v_st := g->>'status';
    insert into public.out_invoices(sale_id, customer_id, buyer_info, buyer_name, tax_code, address, email, status, so_hd, ngay_hd, legacy, note, status_at)
    select t.sale_id, t.customer_id, g->>'info', coalesce(nullif(btrim(g->>'buyer_name'), ''), left(split_part(coalesce(g->>'info', ''), E'\n', 1), 200)),
      nullif(btrim(g->>'tax_code'), ''), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), v_st, g->>'so_hd', nullif(g->>'ngay','')::date, true, 'Nhập từ sổ Excel cũ', now()
      from public.out_items t where t.ma_hang = g->'lines'->0->>'ma_hang' returning id into v_inv;
    if v_inv is null then continue; end if;
    -- đơn vị trên sổ cũ có MST → thêm vào danh sách tra MST
    if nullif(btrim(g->>'tax_code'), '') is not null and nullif(btrim(g->>'buyer_name'), '') is not null
       and not exists(select 1 from public.out_buyers where btrim(tax_code) = btrim(g->>'tax_code')) then
      insert into public.out_buyers(name, tax_code, address, email, note) values (btrim(g->>'buyer_name'), btrim(g->>'tax_code'), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), 'Từ sổ cũ');
    end if;
    k := 0;
    for x in select * from jsonb_array_elements(g->'lines') loop
      select id into v_item from public.out_items where ma_hang = x->>'ma_hang'; k := k + 1;
      if v_item is not null and coalesce((x->>'sl')::numeric, 0) > 0 then
        insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values (v_inv, v_item, k, (x->>'sl')::numeric, coalesce((x->>'gia')::numeric, 0), (x->>'vat')::numeric);
      end if;
    end loop;
    if not exists(select 1 from public.out_invoice_lines where invoice_id = v_inv) then delete from public.out_invoices where id = v_inv; else n_leg := n_leg + 1; end if;
  end loop;
  insert into public.out_events(action, data) values ('import', jsonb_build_object('new', n_new, 'upd', n_upd, 'legacy', n_leg));
  return jsonb_build_object('new', n_new, 'upd', n_upd, 'legacy', n_leg, 'no_sale', (select count(*) from public.out_items where sale_id is null));
end $$;

create or replace function public.out_item_set(p_id uuid, p_md text, p_sale uuid, p_username text default null, p_note text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare t public.out_items;
begin
  select * into t from public.out_items where id = p_id for update; if t.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if not app.is_acc() then
    if not app.has_role('sale','tn_kd','tp_kd') or t.sale_id is not null then raise exception 'Dòng đã có sale — báo kế toán nếu nhầm'; end if;
    p_sale := auth.uid();
    if app.norm_md(p_md) is null then raise exception 'Nhập mã đơn (MD)'; end if;
  end if;
  update public.out_items set md = coalesce(app.norm_md(p_md), md), sale_id = p_sale, username = coalesce(nullif(btrim(p_username), ''), username),
    note = coalesce(nullif(btrim(p_note), ''), note), customer_id = case when p_username is not null then null else customer_id end, match_src = 'tay', updated_at = now(), updated_by = auth.uid() where id = p_id;
  perform app.out_item_match(p_id);
  insert into public.out_events(item_id, action, note, data) values (p_id, case when app.is_acc() then 'item_set' else 'item_claim' end, p_note, jsonb_build_object('md', p_md, 'sale', p_sale));
  if app.is_acc() and p_sale is not null and p_sale <> auth.uid() and p_sale is distinct from t.sale_id then
    perform app.notify(p_sale, 'acc', 'Có dòng HĐ chờ bạn lập phiếu xuất', left(t.ten, 80), '#/out');
  end if;
end $$;

create or replace function public.out_invoice_save(p_id uuid, p_data jsonb, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; v_id uuid := p_id; x jsonb; t public.out_items; k int := 0; v_buyer uuid; v_sale uuid; v_acc boolean := app.is_acc(); v_status text;
begin
  if p_id is not null then
    select * into v from public.out_invoices where id = p_id for update;
    if v.id is null then raise exception 'Không tìm thấy phiếu'; end if;
    if not (v_acc or app.in_tree(v.sale_id)) then raise exception 'Phiếu không thuộc bạn'; end if;
    if v.status in ('da_ky','huy') then raise exception 'Phiếu đã ký/đã hủy, không sửa được'; end if;
    if v.status = 'xac_nhan_ky' and not v_acc then raise exception 'Đã xác nhận ký — báo kế toán nếu cần sửa'; end if;
  end if;
  if jsonb_array_length(coalesce(p_lines, '[]')) = 0 then raise exception 'Chọn ít nhất 1 dòng hàng'; end if;
  if coalesce(btrim(p_data->>'buyer_name'), '') = '' then raise exception 'Nhập tên đơn vị mua hàng'; end if;
  -- lưu đơn vị nhận HĐ để dùng lại
  if coalesce((p_data->>'save_buyer')::boolean, true) then
    select id into v_buyer from public.out_buyers where coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(nullif(p_data->>'customer_id','')::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
       and lower(btrim(name)) = lower(btrim(p_data->>'buyer_name')) and coalesce(btrim(tax_code), '') = coalesce(btrim(p_data->>'tax_code'), '');
    if v_buyer is null then
      insert into public.out_buyers(customer_id, name, tax_code, address, email) values (nullif(p_data->>'customer_id','')::uuid, btrim(p_data->>'buyer_name'), nullif(btrim(p_data->>'tax_code'), ''),
        nullif(btrim(p_data->>'address'), ''), nullif(btrim(p_data->>'email'), '')) returning id into v_buyer;
    else update public.out_buyers set address = coalesce(nullif(btrim(p_data->>'address'), ''), address), email = coalesce(nullif(btrim(p_data->>'email'), ''), email) where id = v_buyer; end if;
  end if;
  -- dòng hàng: phải là dòng của sale, đủ tồn
  for x in select * from jsonb_array_elements(p_lines) loop
    select * into t from public.out_items where id = (x->>'item_id')::uuid;
    if t.id is null then raise exception 'Dòng hàng không tồn tại'; end if;
    if not v_acc and not app.in_tree(t.sale_id) then raise exception 'Dòng % không phải của bạn', t.ma_hang; end if;
    v_sale := coalesce(v_sale, t.sale_id);
    if coalesce((x->>'sl')::numeric, 0) <= 0 then raise exception 'Số lượng dòng % phải > 0', t.ma_hang; end if;
    if (x->>'sl')::numeric > t.sl_nhap - app.out_used(t.id, p_id) + 0.0001 then raise exception 'Dòng % chỉ còn tồn %', t.ma_hang, t.sl_nhap - app.out_used(t.id, p_id); end if;
    if coalesce((x->>'don_gia')::numeric, -1) < 0 then raise exception 'Nhập đơn giá dòng %', t.ma_hang; end if;
    if (x->>'don_gia')::numeric < coalesce(t.dg_nhap, 0) and coalesce(btrim(p_data->>'note'), '') = '' then
      raise exception 'Dòng % xuất giá % thấp hơn giá nhập % — ghi lý do vào Ghi chú cho kế toán', t.ma_hang, (x->>'don_gia')::numeric, t.dg_nhap; end if;
  end loop;
  v_status := case when p_id is null then case when coalesce((p_data->>'submit')::boolean, false) then 'cho_nhap' else 'soan' end
                   when v.status in ('da_nhap','xac_nhan_ky') then 'cho_nhap'
                   when coalesce((p_data->>'submit')::boolean, false) and v.status = 'soan' then 'cho_nhap' else v.status end;
  if p_id is null then
    insert into public.out_invoices(sale_id, customer_id, buyer_id, buyer_name, tax_code, address, email, payment, note, status, status_by)
    values (coalesce(v_sale, auth.uid()), nullif(p_data->>'customer_id','')::uuid, v_buyer, btrim(p_data->>'buyer_name'), nullif(btrim(p_data->>'tax_code'), ''), nullif(btrim(p_data->>'address'), ''),
            nullif(btrim(p_data->>'email'), ''), coalesce(nullif(p_data->>'payment', ''), 'TM/CK'), nullif(btrim(p_data->>'note'), ''), v_status, auth.uid())
    returning id into v_id;
  else
    update public.out_invoices set customer_id = nullif(p_data->>'customer_id','')::uuid, buyer_id = coalesce(v_buyer, buyer_id), buyer_name = btrim(p_data->>'buyer_name'),
      tax_code = nullif(btrim(p_data->>'tax_code'), ''), address = nullif(btrim(p_data->>'address'), ''), email = nullif(btrim(p_data->>'email'), ''),
      payment = coalesce(nullif(p_data->>'payment', ''), payment), note = nullif(btrim(p_data->>'note'), ''),
      sua_sau_nhap = sua_sau_nhap or v.status in ('da_nhap','xac_nhan_ky'), status = v_status,
      status_at = case when v_status <> v.status then now() else status_at end, updated_at = now() where id = v_id;
    delete from public.out_invoice_lines where invoice_id = v_id;
  end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    k := k + 1;
    insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat)
    select v_id, oi.id, k, (x->>'sl')::numeric, (x->>'don_gia')::numeric, coalesce((x->>'vat')::numeric, oi.vat) from public.out_items oi where oi.id = (x->>'item_id')::uuid;
  end loop;
  -- nhớ khách cho các dòng hàng (lần sau mở phiếu tự chọn khách)
  update public.out_items oi set customer_id = nullif(p_data->>'customer_id','')::uuid
   where oi.customer_id is null and nullif(p_data->>'customer_id','') is not null and oi.id in (select item_id from public.out_invoice_lines where invoice_id = v_id);
  insert into public.out_events(invoice_id, action, note, data) values (v_id, case when p_id is null then 'create' else 'edit' end, nullif(btrim(p_data->>'note'), ''), jsonb_build_object('status', v_status));
  if v_status = 'cho_nhap' and (p_id is null or v.status <> 'cho_nhap') then
    perform app.notify_roles(array['ke_toan'], 'acc', case when p_id is not null and v.status in ('da_nhap','xac_nhan_ky') then 'Sale sửa phiếu sau khi đã xuất nháp' else 'Phiếu xuất HĐ chờ xuất nháp' end,
      (select code from public.out_invoices where id = v_id) || ' · ' || btrim(p_data->>'buyer_name'), '#/out');
  end if;
  return v_id;
end $$;

create or replace function public.acc_line_set(p_id uuid, p_status text, p_note text default null, p_gia_khach numeric default null, p_md text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; c jsonb := coalesce(app.setting('accounting'), '{}'); v_gk numeric; v_md text; v_ga numeric; v_b numeric; v_de numeric; v_ph text;
        tgt numeric := coalesce((c->>'bien_muc_tieu')::numeric, 0.03); hi numeric := coalesce((c->>'bien_nt_max')::numeric, 0.04);
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if p_status not in ('ok','blocked') then raise exception 'Trạng thái không hợp lệ'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  if p_status = 'blocked' then
    update public.acc_lines set status = 'blocked', due_at = now() + interval '24 hours', phan_hoi = case when apt_stt is not null then 'CHỜ SALE — chưa xuất' end, updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'set_blocked', p_note);
    perform app.notify(l.sale_id, 'acc', 'Kế toán trả lại dòng HĐ: ' || coalesce(l.md, ''), p_note, '#/acc/mine');
    return;
  end if;
  if l.reply = 'chuyen_xe_sau' and l.apt_stt is null then
    update public.acc_lines set status = 'info', due_at = null, issues = '{}', phan_hoi = null,
      notes = array_prepend('Chuyển xe sau — kế toán xác nhận' || coalesce(': ' || nullif(btrim(p_note), ''), '') || '.', notes), updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'set_chuyen_xe_sau', p_note);
    return;
  end if;
  if l.reply = 'dong_thua' then
    update public.acc_lines set status = 'info', due_at = null, issues = '{}', phan_hoi = null,
      notes = array_prepend(case when l.reply_sub = 'khong_khai' then 'Không khai qua APT (đi đường khác)' else 'Dòng thừa trên hệ thống' end || ' — sale chốt, kế toán xác nhận' || coalesce(': ' || nullif(btrim(p_note), ''), '') || '.', notes),
      updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'set_dong_thua', p_note);
    return;
  end if;
  v_gk := coalesce(nullif(p_gia_khach, 0), nullif(l.gia_khach, 0), l.claim_gia);
  v_md := coalesce(app.norm_md(p_md), case when l.reply = 'nham' then l.claim_md end, l.md, l.claim_md);
  if l.luong in ('A','B') and coalesce(v_gk, 0) <= 0 then raise exception 'Nhập giá khách để chốt'; end if;
  v_ga := coalesce(l.gia_note, l.gia_nhap); v_b := case when v_gk > 0 and v_ga > 0 then v_gk / v_ga - 1 end;
  if l.reply = 'de_xuat_gia' and l.reply_price > 0 then v_de := l.reply_price;
  elsif v_b is not null and v_b > hi + 0.001 then v_de := round(v_gk / (1 + tgt)); end if;
  v_ph := case when l.apt_stt is null then null when l.luong = 'C' then 'XUẤT THẲNG'
               when v_de is not null then 'XUẤT GIÁ ' || round(v_de)::bigint::text
               when l.gia_note is not null and abs(l.gia_note - coalesce(l.gia_nhap, 0)) > 0.5 then 'XUẤT GIÁ ' || round(l.gia_note)::bigint::text else 'CHỐT' end;
  update public.acc_lines set status = 'ok', due_at = null, gia_khach = v_gk, md = v_md, ma_dong = case when md is distinct from v_md then v_md else coalesce(ma_dong, v_md) end,
    gia_de_xuat = coalesce(v_de, gia_de_xuat), gia_ap_dung = coalesce(v_de, gia_note, gia_nhap),
    bien_nt = case when v_gk > 0 and coalesce(v_de, v_ga) > 0 then v_gk / coalesce(v_de, v_ga) - 1 end,
    tt_khach = case when v_gk > 0 then round(v_gk * coalesce(sl_tk, sl_apt, sl_ht, 0)) end, tt_apt = round(coalesce(v_de, v_ga, 0) * coalesce(sl_tk, sl_apt, sl_ht, 0)),
    phan_hoi = v_ph, issues = '{}', notes = array_prepend('Kế toán chốt' || coalesce(': ' || nullif(btrim(p_note), ''), '') || '.', notes), updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'set_ok', p_note, jsonb_build_object('gia_khach', v_gk, 'md', v_md));
  if l.inv_id is not null then perform app.acc_line_inv_refresh(p_id); end if;
end $$;

-- Dòng HĐ XML được ghép (nạp XML, xe nạp sau, ghép tay) → dòng sổ đầu ra cùng số HĐ + STT gắn lại
create or replace function app.trg_acc_invline_out() returns trigger language plpgsql security definer set search_path = public, app as $$
declare t record;
begin
  if new.line_id is null then return null; end if;
  for t in select oi.id from public.out_items oi join public.acc_invoices i on i.id = new.invoice_id
            where oi.stt_hd = new.stt and ltrim(oi.so_hd_vao, '0') = ltrim(i.so_hd, '0') and (oi.acc_line_id is null or oi.acc_line_id <> new.line_id) and coalesce(oi.match_src, '') <> 'tay' loop
    update public.out_items set acc_line_id = null, match_src = null where id = t.id;
    perform app.out_item_match(t.id);
  end loop;
  return null;
end $$;
drop trigger if exists acc_invline_out on public.acc_invoice_lines;
create trigger acc_invline_out after insert or update of line_id on public.acc_invoice_lines for each row execute function app.trg_acc_invline_out();

-- Dòng đối soát đổi MD / sale / giá khách / khách → dòng sổ đầu ra lấy theo (trừ dòng kế toán sửa tay)
create or replace function app.trg_acc_line_out() returns trigger language plpgsql security definer set search_path = public, app as $$
declare t record;
begin
  if new.is_test then return null; end if;
  update public.out_items set md = coalesce(new.md, md), sale_id = coalesce(new.sale_id, sale_id), gia_khach = coalesce(nullif(new.gia_khach, 0), gia_khach),
         customer_id = coalesce(new.customer_id, customer_id), updated_at = now()
   where acc_line_id = new.id and coalesce(match_src, '') <> 'tay'
     and (md is distinct from coalesce(new.md, md) or sale_id is distinct from coalesce(new.sale_id, sale_id) or gia_khach is distinct from coalesce(nullif(new.gia_khach, 0), gia_khach) or customer_id is distinct from coalesce(new.customer_id, customer_id));
  if new.md is not null then
    for t in select id from public.out_items where acc_line_id is null and md = new.md loop perform app.out_item_match(t.id); end loop;
  end if;
  return null;
end $$;
drop trigger if exists acc_line_out on public.acc_lines;
create trigger acc_line_out after insert or update of md, sale_id, gia_khach, customer_id on public.acc_lines for each row execute function app.trg_acc_line_out();

-- Dòng sổ có sale → phiếu cũ (sổ cũ) chưa có sale được gán theo
create or replace function app.trg_out_item_sale() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if new.sale_id is not null and new.sale_id is distinct from old.sale_id then
    update public.out_invoices set sale_id = new.sale_id where sale_id is null and id in (select invoice_id from public.out_invoice_lines where item_id = new.id);
  end if;
  return null;
end $$;
drop trigger if exists out_item_sale on public.out_items;
create trigger out_item_sale after update of sale_id on public.out_items for each row execute function app.trg_out_item_sale();

-- Phiếu sổ cũ đã tạo trước bản này: tách MST / email từ thông tin tự do
update public.out_invoices set tax_code = coalesce(tax_code, substring(buyer_info from '(?:MST|Mã số thuế|mã số thuế|Tax code)[^0-9]*([0-9]{12}|[0-9]{10}(?:-[0-9]{3})?)')),
  email = coalesce(email, substring(buyer_info from '([A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)'))
 where legacy and buyer_info is not null;

-- Ghép lại 1 lần cho dữ liệu đã có
do $$ declare t record; begin
  for t in select id from public.out_items where acc_line_id is null and coalesce(match_src, '') <> 'tay' loop perform app.out_item_match(t.id); end loop;
  update public.out_invoices v set sale_id = (select oi.sale_id from public.out_invoice_lines l join public.out_items oi on oi.id = l.item_id where l.invoice_id = v.id and oi.sale_id is not null limit 1) where v.sale_id is null;
end $$;

reset search_path;
