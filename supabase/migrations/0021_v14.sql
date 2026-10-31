-- =====================================================================
-- 0021 · Bản 14
--  A. Đối soát: biên NT ngoài khung → chặn, sale gửi APT giá đề xuất rồi tự chốt; "Nhầm sale / nhầm đơn"; "Dòng thừa / Không khai";
--     nạp lại file giữ quyết định đã xử lý tay (nhận dòng, chốt, gửi giá…)
--  B. Xuất HĐ đầu ra (độc lập): kế toán nạp sổ Excel HĐ chính thức (mã hàng MISA) → gắn ID đơn/NVKD/USER →
--     sale lập phiếu xuất HĐ (giá + đơn vị nhận HĐ) → kế toán xuất file nháp → sale xác nhận ký → kế toán xác nhận đã ký
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 14');

-- ============ A. Đối soát ============
alter table public.acc_lines add column if not exists gia_nhap_goc numeric;
alter table public.acc_lines add column if not exists released_from uuid references public.profiles(id);
alter table public.acc_lines add column if not exists reply_sub text;
alter table public.acc_lines drop constraint if exists acc_lines_reply_check;
alter table public.acc_lines add constraint acc_lines_reply_check
  check (reply in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet','xuat_thang','da_gui_gia','nham','dong_thua'));

drop function if exists public.acc_line_reply(uuid, text, numeric, text, text, numeric);
create or replace function public.acc_line_reply(p_id uuid, p_reply text, p_price numeric default null, p_note text default null,
  p_md text default null, p_gia_khach numeric default null, p_sub text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; v_status text; v_md text := app.norm_md(p_md); v_gk numeric; v_g numeric;
        h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24);
begin
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if not (app.is_acc() or app.in_tree(l.sale_id)) then raise exception 'Dòng này không thuộc khách của bạn'; end if;
  if l.status not in ('blocked','replied') then raise exception 'Dòng không ở trạng thái chờ sale'; end if;
  if p_reply not in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet','xuat_thang','da_gui_gia','nham','dong_thua') then raise exception 'Lựa chọn không hợp lệ'; end if;
  if p_reply = 'de_xuat_gia' and coalesce(p_price, 0) <= 0 then raise exception 'Nhập giá đề xuất'; end if;
  if p_reply = 'xin_duyet' and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do xin duyệt ngoại lệ'; end if;
  if p_reply = 'da_sua_ht' and l.md is null and l.luong in ('A','B') and v_md is null then raise exception 'Nhập mã đơn (MD) đã tạo trên hệ thống'; end if;
  if p_reply = 'da_sua_ht' and coalesce(l.gia_khach, 0) = 0 and l.luong in ('A','B') and coalesce(p_gia_khach, 0) <= 0 then raise exception 'Nhập giá khách (giá xuất HĐ cho khách)'; end if;

  if p_reply = 'xuat_thang' then
    update public.acc_trucks set xt_keys = array(select distinct x from unnest(xt_keys || l.line_key) x),
      md_xuat_thang = case when l.md is null then md_xuat_thang else array(select distinct x from unnest(md_xuat_thang || l.md) x) end where id = l.truck_id;
    update public.acc_lines set reply = p_reply, reply_sub = null, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(), luong = 'C', status = 'info', due_at = null,
      phan_hoi = case when apt_stt is not null then 'XUẤT THẲNG' end, issues = '{}', notes = array_prepend('Sale báo APT xuất thẳng.', notes), updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'reply_xuat_thang', p_note);
    return;
  end if;

  -- Sale đã gửi APT giá đề xuất → đổi giá nháp APT theo giá đề xuất, dòng tự chốt (HĐ chính thức lệch giá sẽ báo đỏ)
  if p_reply = 'da_gui_gia' then
    if coalesce(l.gia_de_xuat, 0) <= 0 then raise exception 'Dòng không có giá đề xuất'; end if;
    v_gk := coalesce(nullif(l.gia_khach, 0), l.claim_gia); v_g := l.gia_de_xuat;
    if coalesce(v_gk, 0) <= 0 then raise exception 'Dòng chưa có giá khách'; end if;
    update public.acc_lines set reply = p_reply, reply_sub = null, reply_price = v_g, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(),
      gia_nhap_goc = coalesce(gia_nhap_goc, gia_nhap), gia_nhap = v_g, gia_note = null, gia_ap_dung = v_g, bien_nt = v_gk / v_g - 1,
      tt_apt = round(v_g * coalesce(sl_tk, sl_apt, sl_ht, 0)), status = 'ok', due_at = null, issues = '{}',
      phan_hoi = case when apt_stt is not null then 'XUẤT GIÁ ' || round(v_g)::bigint::text end,
      notes = array_prepend('Sale đã gửi APT giá đề xuất ' || round(v_g)::bigint::text || ' (giá nháp cũ ' || coalesce(round(l.gia_nhap)::bigint::text, '—') || ').', notes),
      updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'reply_da_gui_gia', p_note, jsonb_build_object('gia', v_g, 'gia_cu', l.gia_nhap));
    return;
  end if;

  -- Nhầm sale: nhả dòng về "Dòng chưa có chủ" · Nhầm đơn: ghi MD đúng, kế toán chốt
  if p_reply = 'nham' then
    if p_sub not in ('khong_phai','sai_md') then raise exception 'Chọn: không phải hàng của tôi / sai mã đơn'; end if;
    if p_sub = 'khong_phai' then
      update public.acc_lines set reply = p_reply, reply_sub = p_sub, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(),
        released_from = sale_id, sale_id = null, claimed_by = null, claimed_at = null, claim_md = null, claim_gia = null,
        status = 'blocked', due_at = now() + make_interval(hours => h),
        notes = array_prepend('Sale ' || coalesce((select full_name from public.profiles where id = auth.uid()), '') || ' báo không phải hàng của mình' || coalesce(': ' || nullif(btrim(p_note), ''), '') || '.', notes),
        updated_at = now() where id = p_id;
      perform app.notify_roles(array['ke_toan'], 'acc', 'Sale nhả dòng HĐ (nhầm sale)', coalesce(l.md, '') || ' · ' || left(coalesce(l.ten_apt, l.ten_ht, ''), 80) || coalesce(' — ' || p_note, ''), '#/acc?truck=' || l.truck_id);
    else
      if v_md is null then raise exception 'Nhập mã đơn (MD) đúng'; end if;
      update public.acc_lines set reply = p_reply, reply_sub = p_sub, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(),
        claim_md = v_md, claim_gia = coalesce(nullif(p_gia_khach, 0), claim_gia), status = 'replied', updated_at = now() where id = p_id;
    end if;
    insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'reply_nham', p_note, jsonb_build_object('sub', p_sub, 'md', v_md));
    return;
  end if;

  if p_reply = 'dong_thua' and p_sub not in ('thua','khong_khai') then raise exception 'Chọn: dòng thừa / không khai qua APT'; end if;
  v_status := case when p_reply = 'xin_duyet' then 'pending_approval' else 'replied' end;
  update public.acc_lines set reply = p_reply, reply_sub = case when p_reply = 'dong_thua' then p_sub end, reply_price = p_price, reply_note = nullif(btrim(p_note), ''),
    replied_by = auth.uid(), replied_at = now(), status = v_status,
    claim_md = coalesce(v_md, claim_md), claim_gia = coalesce(nullif(p_gia_khach, 0), claim_gia), updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'reply', p_note, jsonb_build_object('reply', p_reply, 'sub', p_sub, 'price', p_price, 'md', v_md, 'gia_khach', p_gia_khach));
  if p_reply = 'xin_duyet' then
    perform app.notify(x::uuid, 'acc', 'Xin duyệt ngoại lệ HĐ: ' || coalesce(l.md, 'dòng không có đơn'), left(coalesce(l.ten_apt, l.ten_ht, ''), 80) || ' — ' || p_note, '#/acc/approve')
      from jsonb_array_elements_text(coalesce(app.setting('accounting')->'approver_ids', '[]')) x;
  end if;
end $$;
grant execute on function public.acc_line_reply(uuid, text, numeric, text, text, numeric, text) to authenticated;

-- Nhận dòng chưa có chủ: sale vừa nhả thì không tự nhận lại
create or replace function public.acc_line_claim(p_id uuid, p_md text, p_gia_khach numeric, p_note text default null, p_sale uuid default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; v_sale uuid := coalesce(p_sale, auth.uid()); v_md text := app.norm_md(p_md);
begin
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if p_sale is not null and not app.is_acc() then raise exception 'Chỉ Kế toán/Admin được gán cho sale khác'; end if;
  if not app.is_acc() then
    if not app.has_role('sale','tn_kd','tp_kd') then raise exception 'Chỉ sale được nhận dòng'; end if;
    if l.is_test then raise exception 'Xe nạp thử'; end if;
    if l.sale_id is not null then raise exception 'Dòng đã có sale phụ trách — báo kế toán nếu nhầm'; end if;
  end if;
  if v_md is null and l.md is null then raise exception 'Nhập mã đơn (MD)'; end if;
  if coalesce(p_gia_khach, 0) <= 0 and coalesce(l.gia_khach, 0) = 0 and l.luong in ('A','B') then raise exception 'Nhập giá khách'; end if;
  update public.acc_lines set sale_id = v_sale, claimed_by = auth.uid(), claimed_at = now(), claim_md = coalesce(v_md, claim_md), claim_gia = coalesce(nullif(p_gia_khach, 0), claim_gia),
    reply = 'da_sua_ht', reply_sub = null, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(),
    status = case when status in ('blocked','replied') then 'replied' else status end, due_at = null, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, case when p_sale is null then 'claim' else 'assign' end, p_note,
    jsonb_build_object('md', v_md, 'gia_khach', p_gia_khach, 'sale', v_sale));
  if p_sale is not null and p_sale <> auth.uid() then perform app.notify(p_sale, 'acc', 'Kế toán gán cho bạn 1 dòng HĐ APT', coalesce(v_md, '') || ' · ' || left(coalesce(l.ten_apt, ''), 80), '#/acc/mine'); end if;
end $$;

-- Kế toán chốt: dòng thừa/không khai → đóng theo dõi; nhầm đơn → lấy MD sale ghi
drop function if exists public.acc_line_set(uuid, text, text, numeric, text);
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
grant execute on function public.acc_line_set(uuid, text, text, numeric, text) to authenticated;

-- Nạp lại file: giữ quyết định đã xử lý tay nếu file mới chưa tự giải quyết được dòng đó
create or replace function app.acc_keep_manual(p_old public.acc_lines, p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare n public.acc_lines;
begin
  select * into n from public.acc_lines where id = p_id;
  -- sale/MD/giá khách đã nhận/gán/chốt tay mà file vẫn trống → giữ
  update public.acc_lines set
    sale_id = case when n.sale_id is null or n.sale_id = p_old.released_from then case when p_old.reply = 'nham' and p_old.reply_sub = 'khong_phai' then p_old.sale_id else coalesce(p_old.sale_id, n.sale_id) end else n.sale_id end,
    md = case when p_old.reply = 'nham' or p_old.claimed_at is not null then coalesce(p_old.md, n.md) else coalesce(n.md, p_old.md) end,
    ma_dong = case when p_old.reply = 'nham' or p_old.claimed_at is not null then coalesce(p_old.ma_dong, n.ma_dong) else n.ma_dong end, gia_khach = coalesce(nullif(n.gia_khach, 0), nullif(p_old.gia_khach, 0), n.gia_khach),
    released_from = p_old.released_from, claim_md = p_old.claim_md, claim_gia = p_old.claim_gia, claimed_by = p_old.claimed_by, claimed_at = p_old.claimed_at,
    reply = p_old.reply, reply_sub = p_old.reply_sub, reply_price = p_old.reply_price, reply_note = p_old.reply_note, replied_by = p_old.replied_by, replied_at = p_old.replied_at
  where id = p_id;
  if n.status = 'ok' then return; end if; -- file mới đã sạch → theo file
  if p_old.reply is not null or p_old.claimed_at is not null or p_old.status in ('approved','pending_approval') then
    update public.acc_lines set status = p_old.status, luong = p_old.luong, phan_hoi = p_old.phan_hoi, issues = p_old.issues, due_at = p_old.due_at,
      gia_nhap = case when p_old.reply = 'da_gui_gia' then p_old.gia_nhap else gia_nhap end, gia_nhap_goc = p_old.gia_nhap_goc,
      gia_ap_dung = p_old.gia_ap_dung, gia_de_xuat = p_old.gia_de_xuat, bien_nt = p_old.bien_nt, tt_apt = p_old.tt_apt, tt_khach = p_old.tt_khach
    where id = p_id;
  end if;
end $$;

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
      luong, gia_ap_dung, gia_de_xuat, bien_nt, tt_apt, tt_khach, status, level, issues, notes, phan_hoi, match_score, due_at, updated_at, is_test)
    select v_id, x.line_key, x.ma_dong, x.md, x.sale_name, x.sale_acc, v_sale, x.ma_kh, x.sys_row, x.ten_ht, x.sl_ht, x.dvt_ht, x.gia_khach, x.nk_ht,
      x.apt_stt, x.hh, x.dh, x.sale_apt, x.ten_apt, x.sl_apt, x.dvt_apt, x.gia_nhap, x.gia_note, x.note_apt, x.nk_apt, x.vat, x.tk_row, x.ten_tk, x.hs, x.sl_tk, x.dvt_tk, x.gia_tk_nh, x.nk_tk, x.tnk_dv, x.md_header,
      x.luong, x.gia_ap_dung, x.gia_de_xuat, x.bien_nt, x.tt_apt, x.tt_khach, v_status, x.level, coalesce(x.issues, '{}'), coalesce(x.notes, '{}'), x.phan_hoi, x.match_score, v_due, now(), v_test
    from jsonb_populate_record(null::public.acc_lines, r) x
    on conflict (truck_id, line_key) do update set ma_dong = excluded.ma_dong, md = excluded.md, sale_name = excluded.sale_name, sale_acc = excluded.sale_acc, sale_id = excluded.sale_id,
      ma_kh = excluded.ma_kh, sys_row = excluded.sys_row, ten_ht = excluded.ten_ht, sl_ht = excluded.sl_ht, dvt_ht = excluded.dvt_ht, gia_khach = excluded.gia_khach, nk_ht = excluded.nk_ht,
      apt_stt = excluded.apt_stt, hh = excluded.hh, dh = excluded.dh, sale_apt = excluded.sale_apt, ten_apt = excluded.ten_apt, sl_apt = excluded.sl_apt, dvt_apt = excluded.dvt_apt,
      gia_nhap = excluded.gia_nhap, gia_note = excluded.gia_note, note_apt = excluded.note_apt, nk_apt = excluded.nk_apt, vat = excluded.vat, tk_row = excluded.tk_row, ten_tk = excluded.ten_tk,
      hs = excluded.hs, sl_tk = excluded.sl_tk, dvt_tk = excluded.dvt_tk, gia_tk_nh = excluded.gia_tk_nh, nk_tk = excluded.nk_tk, tnk_dv = excluded.tnk_dv, md_header = excluded.md_header,
      luong = excluded.luong, gia_ap_dung = excluded.gia_ap_dung, gia_de_xuat = excluded.gia_de_xuat, bien_nt = excluded.bien_nt, tt_apt = excluded.tt_apt, tt_khach = excluded.tt_khach,
      status = excluded.status, level = excluded.level, issues = excluded.issues, notes = excluded.notes, phan_hoi = excluded.phan_hoi, match_score = excluded.match_score,
      due_at = excluded.due_at, updated_at = now(), is_test = excluded.is_test
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

-- ============ B. Xuất HĐ đầu ra ============
-- Dòng hàng trong sổ HĐ đầu vào của kế toán (1 dòng = 1 mã hàng MISA, VD HH00036-2027-2026)
create table if not exists public.out_items(
  id uuid primary key default gen_random_uuid(),
  ma_hang text not null unique, stt_so numeric, ten text not null, dvt text, vat numeric, sl_nhap numeric not null default 0, dg_nhap numeric,
  so_hd_vao text, ky_hieu text, ngay_vao date, ncc text, stt_hd int,
  md text, nvkd text, username text, sale_id uuid references public.profiles(id), customer_id uuid references public.customers(id) on delete set null,
  acc_line_id uuid references public.acc_lines(id) on delete set null, gia_khach numeric, match_src text,
  legacy jsonb, note text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), updated_by uuid default auth.uid() references public.profiles(id)
);
create index if not exists out_items_sale on public.out_items(sale_id);
create index if not exists out_items_md on public.out_items(md);
create index if not exists out_items_hd on public.out_items(so_hd_vao);
-- Đơn vị nhận HĐ (hộ KD / công ty / cá nhân) của từng khách — lưu dùng lại
create table if not exists public.out_buyers(
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers(id) on delete cascade,
  name text not null, tax_code text, address text, email text, note text,
  created_by uuid default auth.uid() references public.profiles(id), created_at timestamptz not null default now()
);
create unique index if not exists out_buyers_uq on public.out_buyers(coalesce(customer_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(name)), coalesce(btrim(tax_code), ''));
create sequence if not exists public.out_invoice_seq;
-- Phiếu xuất HĐ = 1 HĐ đầu ra cho 1 đơn vị mua
create table if not exists public.out_invoices(
  id uuid primary key default gen_random_uuid(),
  code text unique not null default ('XHD' || lpad(nextval('public.out_invoice_seq')::text, 5, '0')),
  sale_id uuid references public.profiles(id), customer_id uuid references public.customers(id) on delete set null, buyer_id uuid references public.out_buyers(id) on delete set null,
  buyer_name text, tax_code text, address text, email text, payment text not null default 'TM/CK', buyer_info text,
  status text not null default 'soan' check (status in ('soan','cho_nhap','da_nhap','xac_nhan_ky','da_ky','huy')),
  so_hd text, ngay_hd date, note text, legacy boolean not null default false, sua_sau_nhap boolean not null default false,
  created_by uuid default auth.uid() references public.profiles(id), created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), status_at timestamptz not null default now(), status_by uuid references public.profiles(id)
);
create index if not exists out_invoices_sale on public.out_invoices(sale_id, status);
create table if not exists public.out_invoice_lines(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.out_invoices(id) on delete cascade,
  item_id uuid not null references public.out_items(id) on delete restrict,
  stt int not null default 1, sl numeric not null check (sl > 0), don_gia numeric not null check (don_gia >= 0), vat numeric
);
create index if not exists out_invoice_lines_item on public.out_invoice_lines(item_id);
create index if not exists out_invoice_lines_inv on public.out_invoice_lines(invoice_id);
create table if not exists public.out_events(
  id bigint generated always as identity primary key,
  invoice_id uuid references public.out_invoices(id) on delete cascade, item_id uuid references public.out_items(id) on delete cascade,
  action text not null, note text, data jsonb, actor uuid default auth.uid() references public.profiles(id), at timestamptz not null default now()
);
create index if not exists out_events_inv on public.out_events(invoice_id, at);

alter table public.out_items enable row level security;
alter table public.out_buyers enable row level security;
alter table public.out_invoices enable row level security;
alter table public.out_invoice_lines enable row level security;
alter table public.out_events enable row level security;
drop policy if exists out_items_read on public.out_items;
create policy out_items_read on public.out_items for select to authenticated
  using (app.is_acc() or app.in_tree(sale_id) or (sale_id is null and app.has_role('sale','tn_kd','tp_kd')));
drop policy if exists out_invoices_read on public.out_invoices;
create policy out_invoices_read on public.out_invoices for select to authenticated using (app.is_acc() or app.in_tree(sale_id));
drop policy if exists out_invoice_lines_read on public.out_invoice_lines;
create policy out_invoice_lines_read on public.out_invoice_lines for select to authenticated
  using (exists(select 1 from public.out_invoices i where i.id = invoice_id and (app.is_acc() or app.in_tree(i.sale_id))));
drop policy if exists out_buyers_read on public.out_buyers;
create policy out_buyers_read on public.out_buyers for select to authenticated
  using (app.is_acc() or app.in_tree(created_by) or exists(select 1 from public.customers c where c.id = customer_id and app.in_tree(c.owner_id)));
drop policy if exists out_events_read on public.out_events;
create policy out_events_read on public.out_events for select to authenticated
  using (app.is_acc() or exists(select 1 from public.out_invoices i where i.id = invoice_id and app.in_tree(i.sale_id))
         or exists(select 1 from public.out_items t where t.id = item_id and app.in_tree(t.sale_id)));
grant select on public.out_items, public.out_buyers, public.out_invoices, public.out_invoice_lines, public.out_events to authenticated;

-- SL đã đưa vào phiếu (trừ phiếu hủy)
create or replace function app.out_used(p_item uuid, p_except uuid default null) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(l.sl), 0) from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id
   where l.item_id = p_item and i.status <> 'huy' and (p_except is null or i.id <> p_except)
$$;
create or replace view public.out_items_v with (security_invoker = true) as
  select t.*, app.out_used(t.id) as sl_xuat, t.sl_nhap - app.out_used(t.id) as ton,
    (select string_agg(distinct i.code || ':' || i.status, ',') from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id where l.item_id = t.id and i.status <> 'huy') as phieu
  from public.out_items t;
grant select on public.out_items_v to authenticated;

-- Gắn ID đơn / sale / khách cho 1 dòng sổ (theo HĐ XML đã đối chiếu → MD trên file → NVKD → USER)
create or replace function app.out_item_match(p_id uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; al public.acc_lines; v_c uuid; v_owner uuid; v_src text;
begin
  select * into t from public.out_items where id = p_id;
  if t.stt_hd is not null and t.so_hd_vao is not null then
    select l.* into al from public.acc_invoice_lines il join public.acc_invoices i on i.id = il.invoice_id join public.acc_lines l on l.id = il.line_id
     where ltrim(i.so_hd, '0') = ltrim(t.so_hd_vao, '0') and (t.ky_hieu is null or right(i.ky_hieu, 6) = right(t.ky_hieu, 6)) and il.stt = t.stt_hd limit 1;
    if al.id is not null then v_src := 'hd_xml'; end if;
  end if;
  if al.id is null and t.md is not null then
    select * into al from public.acc_lines where md = t.md and not is_test order by (sl_apt = t.sl_nhap) desc nulls last, updated_at desc limit 1;
    if al.id is not null then v_src := 'md'; end if;
  end if;
  if t.username is not null then
    select id, owner_id into v_c, v_owner from public.customers where deleted_at is null and (lower(sys_username) = lower(t.username) or upper(sys_code) = upper(t.username)) limit 1;
  end if;
  update public.out_items set acc_line_id = coalesce(acc_line_id, al.id),
    md = coalesce(md, al.md), gia_khach = coalesce(gia_khach, nullif(al.gia_khach, 0), al.claim_gia),
    sale_id = coalesce(sale_id, al.sale_id, app.match_sale(t.nvkd), v_owner),
    customer_id = coalesce(customer_id, al.customer_id, v_c),
    match_src = coalesce(match_src, v_src, case when t.nvkd is not null then 'nvkd' when v_owner is not null then 'user' end)
  where id = p_id;
end $$;

-- Kế toán nạp sổ Excel (cập nhật theo mã hàng; giữ phần sale/kế toán đã xử lý). p_legacy: phiếu đã ký/đã nháp trên file cũ
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
      md = coalesce(excluded.md, t.md), nvkd = coalesce(excluded.nvkd, t.nvkd), username = coalesce(excluded.username, t.username),
      sale_id = case when excluded.nvkd is not null and app.match_sale(excluded.nvkd) is not null then app.match_sale(excluded.nvkd) else t.sale_id end,
      legacy = excluded.legacy, updated_at = now(), updated_by = auth.uid()
    returning id into v_id;
    perform app.out_item_match(v_id);
  end loop;
  -- Phiếu cũ (đã nháp/đã ký trên file) → tạo phiếu "từ file cũ" để không phải làm lại; dòng đã có phiếu thì bỏ qua
  for g in select * from jsonb_array_elements(coalesce(p_legacy, '[]')) loop
    if exists(select 1 from jsonb_array_elements(g->'lines') e(v) join public.out_items t on t.ma_hang = e.v->>'ma_hang' join public.out_invoice_lines l on l.item_id = t.id) then continue; end if;
    v_st := g->>'status';
    insert into public.out_invoices(sale_id, customer_id, buyer_info, buyer_name, status, so_hd, ngay_hd, legacy, note, status_at)
    select t.sale_id, t.customer_id, g->>'info', left(split_part(coalesce(g->>'info', ''), E'\n', 1), 200), v_st, g->>'so_hd', nullif(g->>'ngay','')::date, true, 'Nhập từ sổ Excel cũ', now()
      from public.out_items t where t.ma_hang = g->'lines'->0->>'ma_hang' returning id into v_inv;
    if v_inv is null then continue; end if;
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
grant execute on function public.out_items_import(jsonb, jsonb) to authenticated;

-- File danh sách đơn hàng (MD → NVKD, username) để gắn sale/khách cho dòng còn trống
create or replace function public.out_orders_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; r jsonb; t record;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    for t in select id from public.out_items where md = app.norm_md(r->>'md') and (sale_id is null or username is null) loop
      update public.out_items set nvkd = coalesce(nvkd, nullif(btrim(r->>'nvkd'), '')), username = coalesce(username, nullif(btrim(r->>'username'), '')),
        sale_id = coalesce(sale_id, app.match_sale(r->>'nvkd')) where id = t.id;
      perform app.out_item_match(t.id); n := n + 1;
    end loop;
  end loop;
  return n;
end $$;
grant execute on function public.out_orders_import(jsonb) to authenticated;

-- Kế toán sửa ID/sale/khách 1 dòng; sale nhận dòng chưa có sale (nhập MD)
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
    note = coalesce(nullif(btrim(p_note), ''), note), customer_id = case when p_username is not null then null else customer_id end, updated_at = now(), updated_by = auth.uid() where id = p_id;
  perform app.out_item_match(p_id);
  insert into public.out_events(item_id, action, note, data) values (p_id, case when app.is_acc() then 'item_set' else 'item_claim' end, p_note, jsonb_build_object('md', p_md, 'sale', p_sale));
  if app.is_acc() and p_sale is not null and p_sale <> auth.uid() and p_sale is distinct from t.sale_id then
    perform app.notify(p_sale, 'acc', 'Có dòng HĐ chờ bạn lập phiếu xuất', left(t.ten, 80), '#/out');
  end if;
end $$;
grant execute on function public.out_item_set(uuid, text, uuid, text, text) to authenticated;

-- Lập / sửa phiếu xuất HĐ (sale của dòng hoặc kế toán). Sửa sau khi đã xuất nháp → quay lại "Chờ xuất nháp"
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
  insert into public.out_events(invoice_id, action, note, data) values (v_id, case when p_id is null then 'create' else 'edit' end, nullif(btrim(p_data->>'note'), ''), jsonb_build_object('status', v_status));
  if v_status = 'cho_nhap' and (p_id is null or v.status <> 'cho_nhap') then
    perform app.notify_roles(array['ke_toan'], 'acc', case when p_id is not null and v.status in ('da_nhap','xac_nhan_ky') then 'Sale sửa phiếu sau khi đã xuất nháp' else 'Phiếu xuất HĐ chờ xuất nháp' end,
      (select code from public.out_invoices where id = v_id) || ' · ' || btrim(p_data->>'buyer_name'), '#/out');
  end if;
  return v_id;
end $$;
grant execute on function public.out_invoice_save(uuid, jsonb, jsonb) to authenticated;

-- Chuyển trạng thái phiếu
--  sale: soan→cho_nhap (gửi kế toán) · da_nhap→xac_nhan_ky (khách đã OK nháp) · da_nhap→cho_nhap (yêu cầu sửa) · soan/cho_nhap→huy
--  kế toán: cho_nhap→da_nhap (đã tạo nháp) · xac_nhan_ky→da_ky (đã ký, có số HĐ) · →soan (trả lại sale) · hủy (chưa ký)
create or replace function public.out_invoice_status(p_ids uuid[], p_status text, p_note text default null, p_so_hd text default null, p_ngay date default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; n int := 0; v_acc boolean := app.is_acc(); ok boolean;
begin
  for v in select * from public.out_invoices where id = any(p_ids) for update loop
    if not (v_acc or app.in_tree(v.sale_id)) then raise exception 'Phiếu % không thuộc bạn', v.code; end if;
    ok := case p_status
      when 'cho_nhap' then v.status in ('soan','da_nhap','xac_nhan_ky')
      when 'xac_nhan_ky' then v.status = 'da_nhap'
      when 'da_nhap' then v_acc and v.status in ('cho_nhap','xac_nhan_ky')
      when 'da_ky' then v_acc and v.status in ('xac_nhan_ky','da_nhap')
      when 'soan' then v_acc and v.status in ('cho_nhap','da_nhap','xac_nhan_ky')
      when 'huy' then v.status <> 'da_ky' and (v_acc or v.status in ('soan','cho_nhap'))
      else false end;
    if not ok then raise exception 'Phiếu % đang "%", không chuyển sang "%" được', v.code, v.status, p_status; end if;
    if p_status = 'da_ky' and coalesce(btrim(coalesce(p_so_hd, v.so_hd)), '') = '' then raise exception 'Nhập số HĐ đã ký cho phiếu %', v.code; end if;
    if p_status in ('soan','huy') and v_acc and not app.in_tree(v.sale_id) and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do'; end if;
    if p_status = 'cho_nhap' and v.status in ('da_nhap','xac_nhan_ky') and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi nội dung cần sửa'; end if;
    update public.out_invoices set status = p_status, status_at = now(), status_by = auth.uid(), updated_at = now(),
      so_hd = case when p_status = 'da_ky' then coalesce(nullif(btrim(p_so_hd), ''), so_hd) else so_hd end,
      ngay_hd = case when p_status = 'da_ky' then coalesce(p_ngay, ngay_hd, current_date) else ngay_hd end,
      sua_sau_nhap = case when p_status = 'da_nhap' then false when p_status = 'cho_nhap' and v.status in ('da_nhap','xac_nhan_ky') then true else sua_sau_nhap end
    where id = v.id;
    insert into public.out_events(invoice_id, action, note, data) values (v.id, 'status', p_note, jsonb_build_object('from', v.status, 'to', p_status, 'so_hd', p_so_hd));
    if p_status in ('cho_nhap','xac_nhan_ky') then
      perform app.notify_roles(array['ke_toan'], 'acc', case p_status when 'xac_nhan_ky' then 'Sale xác nhận ký: ' else 'Phiếu chờ xuất nháp: ' end || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out');
    elsif p_status in ('da_nhap','da_ky','soan') or (p_status = 'huy' and v_acc) then
      perform app.notify(v.sale_id, 'acc', case p_status when 'da_nhap' then 'Đã có HĐ nháp — kiểm tra, gửi khách, xác nhận ký: ' when 'da_ky' then 'Đã ký HĐ — báo khách kiểm tra email: '
        when 'soan' then 'Kế toán trả lại phiếu: ' else 'Kế toán hủy phiếu: ' end || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_invoice_status(uuid[], text, text, text, date) to authenticated;

-- Trao đổi trên phiếu
create or replace function public.out_comment(p_invoice uuid, p_note text) returns void
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices;
begin
  select * into v from public.out_invoices where id = p_invoice;
  if v.id is null or not (app.is_acc() or app.in_tree(v.sale_id)) then raise exception 'Không có quyền'; end if;
  if coalesce(btrim(p_note), '') = '' then return; end if;
  insert into public.out_events(invoice_id, action, note) values (p_invoice, 'comment', btrim(p_note));
  if app.is_acc() then perform app.notify(v.sale_id, 'acc', 'Kế toán nhắn trên phiếu ' || v.code, left(p_note, 160), '#/out');
  else perform app.notify_roles(array['ke_toan'], 'acc', 'Sale nhắn trên phiếu ' || v.code, left(p_note, 160), '#/out'); end if;
end $$;
grant execute on function public.out_comment(uuid, text) to authenticated;

reset search_path;
