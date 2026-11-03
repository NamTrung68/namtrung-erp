-- =====================================================================
-- 0034 · Bản 27 (03/11/2026)
--  1. Bảng công: sửa lỗi "malformed array literal: G" khi tháng có đơn vắng theo giờ (tháng 11 không hiện bảng công)
--  2. Đối soát xe: biên NT dưới mức tối thiểu (kể cả âm) hoặc trên mức chặn (mặc định 7%) → CHẶN, vào "Cần xử lý" của sale
--     · thêm tham số accounting.bien_chan_max = 0.07
--     · chuyển các dòng đang "Tự chốt" mà biên ngoài khung sang "Bị chặn — chờ sale", báo sale
--  3. Sale trả lời "Sửa giá khách": biên mới trong khung → chốt luôn, không cần kế toán / admin duyệt
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 27');

-- 1) Bảng công
create or replace function app.day_info(p_id uuid, p_schedule text, p_hire date, d date)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('attendance'),'{}'); dv numeric; off numeric := 0; paid_off numeric := 0; work_leave boolean := false;
        lpart text; codes text[] := '{}'; first_in timestamptz; last_out timestamptz; attended boolean; late int := 0; s_start time; s_end time;
        hrs record; l record; forgot boolean := false; holiday record;
begin
  dv := app.day_value(p_schedule, d);
  if dv = 0 then return jsonb_build_object('dv', 0, 'code', 'CN'); end if;
  select * into holiday from public.holidays where day = d;
  if holiday.day is not null then return jsonb_build_object('dv', dv, 'code', 'Lễ', 'paid', case when holiday.paid then dv else 0 end, 'worked', 0); end if;
  if p_hire is not null and d < p_hire then return jsonb_build_object('dv', 0, 'code', ''); end if;
  for l in select r.*, lt.extra from public.leave_requests r left join public.lookups lt on lt.category = 'leave_type' and lt.code = r.leave_type
           where r.profile_id = p_id and r.status = 'da_duyet' and d between r.start_date and r.end_date loop
    if l.part = 'hours' then
      late := late + floor(extract(epoch from (l.to_time - l.from_time)) / 60)::int; codes := codes || 'G'::text;
    elsif coalesce((l.extra->>'work')::boolean, false) then
      work_leave := true; codes := codes || case l.leave_type when 'wfh' then 'WFH' else 'CT' end;
    else
      off := off + case when l.part = 'full' then dv else least(dv, 0.5) end; lpart := l.part;
      if coalesce((l.extra->>'paid')::boolean, false) then paid_off := paid_off + case when l.part = 'full' then dv else least(dv, 0.5) end; end if;
      codes := codes || case l.leave_type when 'phep_nam' then 'P' when 'khong_phep' then 'KP' when 'om_dau' then 'Ô' when 'khong_luong' then 'KL' when 'thai_san' then 'TS' else 'R' end;
    end if;
  end loop;
  off := least(off, dv); paid_off := least(paid_off, off);
  if p_schedule in ('warehouse','none') then
    attended := true;
  else
    select min(at) filter (where kind='in'), max(at) filter (where kind='out') into first_in, last_out
      from public.attendance_events where profile_id = p_id and work_date = d and status <> 'rejected';
    forgot := exists(select 1 from public.attendance_requests r where r.profile_id = p_id and r.work_date = d and r.status = 'da_duyet' and r.kind = 'xac_nhan_cong');
    attended := first_in is not null or work_leave or forgot
      or exists(select 1 from public.attendance_requests r where r.profile_id = p_id and r.work_date = d and r.status = 'da_duyet' and r.kind = 'cong_tac');
    if first_in is not null and off < dv and not work_leave then
      s_start := case when lpart = 'am' then coalesce((cfg->>'lunch_end')::time, '13:30') else coalesce((cfg->>'start')::time, '08:00') end;
      s_end := case when extract(isodow from d) = 6 then coalesce((cfg->>'saturday_end')::time, '12:00') when lpart = 'pm' then coalesce((cfg->>'lunch_start')::time, '12:00') else coalesce((cfg->>'end')::time, '17:30') end;
      late := late + greatest(0, floor(extract(epoch from ((first_in at time zone 'Asia/Ho_Chi_Minh')::time - s_start)) / 60))::int;
      if last_out is not null and d < app.vn_today() then
        late := late + greatest(0, floor(extract(epoch from (s_end - (last_out at time zone 'Asia/Ho_Chi_Minh')::time)) / 60))::int;
      end if;
    end if;
  end if;
  if d > app.vn_today() then
    return jsonb_build_object('dv', dv, 'code', array_to_string(codes, '+'), 'future', true, 'off', off, 'paid', paid_off, 'worked', 0, 'late', 0);
  end if;
  return jsonb_build_object('dv', dv, 'off', off, 'paid', paid_off, 'late', late, 'forgot', forgot,
    'worked', case when attended then dv - off else 0 end, 'absent', case when attended then 0 else dv - off end,
    'code', case when array_length(codes,1) > 0 and off >= dv then array_to_string(codes, '+')
                 when not attended and off < dv then array_to_string(codes || 'V'::text, '+')
                 when array_length(codes,1) > 0 then array_to_string(codes, '+') || case when dv - off = 0.5 then '½' else '' end
                 when dv = 0.5 then '½' else '✓' end);
end $$;

-- 2) Tham số mức chặn biên
update public.settings set value = value || '{"bien_chan_max": 0.07}'::jsonb where key = 'accounting' and not (value ? 'bien_chan_max');

-- 3) Lựa chọn mới của sale
alter table public.acc_lines drop constraint if exists acc_lines_reply_check;
alter table public.acc_lines add constraint acc_lines_reply_check
  check (reply in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet','xuat_thang','da_gui_gia','nham','dong_thua','sua_gia_khach'));

create or replace function public.acc_line_reply(p_id uuid, p_reply text, p_price numeric default null, p_note text default null,
  p_md text default null, p_gia_khach numeric default null, p_sub text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; v_status text; v_md text := app.norm_md(p_md); v_gk numeric; v_g numeric; v_bien numeric;
        v_cfg jsonb := coalesce(app.setting('accounting'), '{}');
        v_lo numeric := coalesce((v_cfg->>'bien_nt_min')::numeric, 0.025); v_hi numeric := coalesce((v_cfg->>'bien_nt_max')::numeric, 0.04);
        v_tgt numeric := coalesce((v_cfg->>'bien_muc_tieu')::numeric, 0.03);
        v_chan numeric := greatest(coalesce((v_cfg->>'bien_nt_max')::numeric, 0.04), coalesce((v_cfg->>'bien_chan_max')::numeric, 0.07));
        h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24);
begin
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if not (app.is_acc() or app.in_tree(l.sale_id)) then raise exception 'Dòng này không thuộc khách của bạn'; end if;
  if l.status not in ('blocked','replied') then raise exception 'Dòng không ở trạng thái chờ sale'; end if;
  if p_reply not in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet','xuat_thang','da_gui_gia','nham','dong_thua','sua_gia_khach') then raise exception 'Lựa chọn không hợp lệ'; end if;
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

  -- Bản 27: sale sửa giá khách (giá trên dòng sai so với hệ thống). Biên mới trong khung [tối thiểu, mức chặn] → chốt luôn, không cần duyệt
  if p_reply = 'sua_gia_khach' then
    if l.luong not in ('A','B') then raise exception 'Chỉ sửa giá khách cho hàng qua Nam Trung'; end if;
    if coalesce(p_gia_khach, 0) <= 0 then raise exception 'Nhập giá khách đúng'; end if;
    v_g := coalesce(nullif(l.gia_note, 0), nullif(l.gia_nhap, 0));
    if coalesce(v_g, 0) <= 0 then raise exception 'Dòng chưa có giá APT — không tính được biên'; end if;
    v_bien := p_gia_khach / v_g - 1;
    if v_bien < v_lo - 0.001 or v_bien > v_chan + 0.001 then
      raise exception 'Biên NT sau khi sửa là % %% — vẫn ngoài khung % %%–% %%. Chọn “Đã gửi APT giá đề xuất” hoặc xin duyệt.',
        round(v_bien * 100, 2), round(v_lo * 100, 2), round(v_chan * 100, 2);
    end if;
    update public.acc_lines set reply = p_reply, reply_sub = null, reply_price = null, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(),
      gia_khach = p_gia_khach, gia_ap_dung = v_g, bien_nt = v_bien, tt_khach = round(p_gia_khach * coalesce(sl_tk, sl_apt, sl_ht, 0)),
      gia_de_xuat = case when v_bien > v_hi + 0.001 then round(p_gia_khach / (1 + v_tgt)) end,
      status = 'ok', level = 3, due_at = null, issues = '{}',
      phan_hoi = case when apt_stt is not null and luong = 'A' then 'CHỐT' else phan_hoi end,
      notes = array_prepend('Sale sửa giá khách ' || coalesce(round(l.gia_khach)::bigint::text, '—') || ' → ' || round(p_gia_khach)::bigint::text
        || ' (biên ' || replace(round(v_bien * 100, 2)::text, '.', ',') || '%), tự chốt.', notes),
      updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'reply_sua_gia_khach', p_note,
      jsonb_build_object('gia_cu', l.gia_khach, 'gia_moi', p_gia_khach, 'bien', v_bien));
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

-- 4) Chấm lại các dòng đang "Tự chốt" mà biên ngoài khung → chặn, báo sale
do $$
declare v_cfg jsonb := coalesce(app.setting('accounting'), '{}');
        v_lo numeric := coalesce((v_cfg->>'bien_nt_min')::numeric, 0.025);
        v_chan numeric := greatest(coalesce((v_cfg->>'bien_nt_max')::numeric, 0.04), coalesce((v_cfg->>'bien_chan_max')::numeric, 0.07));
        v_tgt numeric := coalesce((v_cfg->>'bien_muc_tieu')::numeric, 0.03);
        h int := coalesce((v_cfg->>'han_sale_gio')::int, 24); s record;
begin
  create temp table _b27 on commit drop as
    select id, sale_id from public.acc_lines
     where not is_test and status = 'ok' and luong = 'A' and reply is null
       and coalesce(gia_khach, 0) > 0 and coalesce(gia_ap_dung, gia_note, gia_nhap, 0) > 0 and bien_nt is not null
       and (bien_nt < v_lo - 0.001 or bien_nt > v_chan + 0.001);
  update public.acc_lines l set status = 'blocked', level = 1, due_at = now() + make_interval(hours => h),
    gia_de_xuat = coalesce(l.gia_de_xuat, round(l.gia_khach / (1 + v_tgt))),
    phan_hoi = case when l.apt_stt is not null then 'CHỜ SALE — chưa xuất' else l.phan_hoi end,
    issues = array_prepend('Biên NT ' || replace(round(l.bien_nt * 100, 2)::text, '.', ',') || '% ngoài khung ' || replace(round(v_lo * 100, 2)::text, '.', ',') || '%–' || replace(round(v_chan * 100, 2)::text, '.', ',')
      || '% → đề xuất APT xuất giá ' || coalesce(round(l.gia_de_xuat), round(l.gia_khach / (1 + v_tgt)))::bigint::text || '. Sale: sửa giá khách (nếu sai) hoặc gửi APT giá đề xuất.', l.issues),
    updated_at = now()
   where l.id in (select id from _b27);
  insert into public.acc_events(line_id, truck_id, action, note)
    select l.id, l.truck_id, 'rechan_bien', 'Bản 27: biên ngoài khung → chặn' from public.acc_lines l where l.id in (select id from _b27);
  for s in select sale_id, count(*) c from _b27 where sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng biên NT ngoài khung cần bạn xử lý', 'Biên dưới ' || replace(round(v_lo * 100, 1)::text, '.', ',') || '% hoặc trên ' || replace(round(v_chan * 100, 1)::text, '.', ',') || '% · hạn ' || h || 'h', '#/acc/mine');
  end loop;
  insert into public.audit_logs(action, table_name, diff) select 'RECLASSIFY', 'acc_lines', jsonb_build_object('ban', 27, 'rows', (select count(*) from _b27));
end $$;
