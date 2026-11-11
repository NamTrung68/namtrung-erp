-- =====================================================================
-- 0044 · Bản 37 (11/11/2026)
--  A. Báo giá: ảnh sản phẩm từng dòng hàng (không bắt buộc) — lưu bucket 'quote-images', hiện trên màn lập + bản in gửi khách.
--     Ảnh không tính vào dấu giá (đổi ảnh không phải duyệt giá lại).
--  B. Đơn công: thêm 2 loại
--     · quen_cham_vao — Xác nhận chấm công muộn (quên chấm đến): nhân viên khai ngày + giờ vào; người duyệt sửa/chốt giờ → giờ vào chính thức (tính đi muộn, lương)
--     · quen_cham_ra  — Xác nhận quên chấm công về: nhân viên khai ngày + giờ về; người duyệt sửa/chốt giờ → giờ ra chính thức
--     Gửi được cho ngày đã qua (mặc định tối đa 30 ngày, cấu hình attendance.forgot_back_days), không gửi cho kỳ lương đã chốt.
--     Vẫn tính vào giới hạn quên chấm / tháng và điểm chuyên cần như đơn xác nhận công cũ.
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 37');

-- ---------------- A. Ảnh sản phẩm trong báo giá ----------------
alter table public.quotation_lines add column if not exists image text;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('quote-images', 'quote-images', true, 3145728, array['image/jpeg','image/png','image/webp','image/gif']) on conflict (id) do nothing;
drop policy if exists qimg_ins on storage.objects;
create policy qimg_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'quote-images' and (storage.foldername(name))[1] = auth.uid()::text and app.is_active());
drop policy if exists qimg_read on storage.objects;
create policy qimg_read on storage.objects for select using (bucket_id = 'quote-images');
drop policy if exists qimg_del on storage.objects;
create policy qimg_del on storage.objects for delete to authenticated
  using (bucket_id = 'quote-images' and ((storage.foldername(name))[1] = auth.uid()::text or app.is_admin()));

-- Dấu giá bỏ qua ảnh: báo giá đã duyệt mà chỉ thêm / đổi ảnh thì không phải duyệt lại
create or replace function app.quote_hash(p_header jsonb, p_lines jsonb) returns text language sql immutable as $$
  select md5(coalesce(p_header,'{}')::text || coalesce(
    (select jsonb_agg(case when jsonb_typeof(e) = 'object' then e - 'image' else e end order by o) from jsonb_array_elements(case when jsonb_typeof(p_lines) = 'array' then p_lines else '[]'::jsonb end) with ordinality t(e, o)),
    '[]'::jsonb)::text)
$$;

create or replace function public.save_quote(p_id uuid, p_customer uuid, p_header jsonb, p_lines jsonb, p_totals jsonb, p_note text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare q record; v_id uuid; v_viol text[]; v_hash text; v_header jsonb; v_owner uuid;
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  perform app.assert_customer_open(p_customer);
  -- chụp lại giá vốn tại thời điểm lập
  v_header := p_header || jsonb_build_object(
    'tyGiaVon', coalesce(app.current_rate('von'), 3955),
    'tyGiaSan', coalesce(app.current_rate('san'), 4015));
  v_viol := app.quote_check(v_header, p_lines);
  v_hash := app.quote_hash(p_header, p_lines);
  select owner_id into v_owner from public.customers where id = p_customer;
  if p_id is null then
    insert into public.quotations(code, sale_id, customer_id, header, totals, total_after_vat, est_profit, violations, price_hash, note)
    values ('BG' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'YYMM') || '-' || lpad(nextval('public.quote_code_seq')::text, 4, '0'),
            case when app.is_support_of(v_owner) and v_owner <> auth.uid() then v_owner else auth.uid() end,
            p_customer, v_header, coalesce(p_totals,'{}'), coalesce((p_totals->>'tongSauVAT')::numeric,0),
            coalesce((p_totals->>'lnUocTinh')::numeric,0), v_viol, v_hash, p_note)
    returning id into v_id;
    update public.quotations set root_id = id where id = v_id;
  else
    select * into q from public.quotations where id = p_id for update;
    if q.id is null then raise exception 'Không tìm thấy báo giá'; end if;
    if not (q.sale_id = auth.uid() or app.is_admin() or app.is_support_of(q.sale_id)) then raise exception 'Chỉ người lập (hoặc CSKH hỗ trợ) được sửa báo giá'; end if;
    if q.status in ('da_chot','tu_choi','het_han','da_thay_the') then raise exception 'Báo giá đã khóa — dùng Nhân bản'; end if;
    if q.status in ('da_gui','can_nhac') then
      insert into public.quotations(code, version, root_id, customer_id, sale_id, header, totals, total_after_vat, est_profit, violations, price_hash, note)
      values (q.code, (select max(version)+1 from public.quotations where root_id = q.root_id), q.root_id, p_customer, q.sale_id,
              v_header, coalesce(p_totals,'{}'), coalesce((p_totals->>'tongSauVAT')::numeric,0), coalesce((p_totals->>'lnUocTinh')::numeric,0), v_viol, v_hash, p_note)
      returning id into v_id;
      update public.quotations set status = 'da_thay_the', superseded_by = v_id, updated_at = now() where id = q.id;
    else
      v_id := q.id;
      update public.quotations set customer_id = p_customer, header = v_header, totals = coalesce(p_totals,'{}'),
        total_after_vat = coalesce((p_totals->>'tongSauVAT')::numeric,0), est_profit = coalesce((p_totals->>'lnUocTinh')::numeric,0),
        violations = v_viol, price_hash = v_hash, note = p_note, status = 'nhap', updated_at = now()
      where id = q.id;
    end if;
  end if;
  delete from public.quotation_lines where quotation_id = v_id;
  insert into public.quotation_lines(quotation_id, line_no, name, spec, hs_code, unit, qty, unit_price_cny, duty_pct, vat_pct, freight_pct, manual_price, computed, image)
  select v_id, ord, l->>'name', l->>'spec', l->>'hs_code', l->>'unit', (l->>'qty')::numeric, coalesce((l->>'unit_price_cny')::numeric,0),
         coalesce((l->>'duty_pct')::numeric,0), (l->>'vat_pct')::numeric, (l->>'freight_pct')::numeric, (l->>'manual_price')::numeric, coalesce(l->'computed','{}'),
         nullif(btrim(l->>'image'), '')
  from jsonb_array_elements(p_lines) with ordinality t(l, ord)
  where coalesce(btrim(l->>'name'),'') <> '' and coalesce((l->>'qty')::numeric, 0) > 0;
  return v_id;
end $$;

create or replace function public.quote_template(p_source text, p_ref uuid, p_all boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare l public.quotation_lines; q public.quotations; a public.quote_archive; h jsonb; ls jsonb;
begin
  if not app.is_active() then raise exception 'Không có quyền'; end if;
  if p_source = 'he_thong' then
    select * into l from public.quotation_lines where id = p_ref;
    select * into q from public.quotations where id = l.quotation_id and status = 'da_chot';
    if q.id is null then raise exception 'Không tìm thấy báo giá đã chốt'; end if;
    h := q.header - 'maDonHeThong' - 'tyGia' - 'tyGiaVon';
    if not app.can_see_freight() then h := h - 'donGiaKg' - 'donGiaKhoi'; end if;
    select jsonb_agg(jsonb_build_object('name', x.name, 'hs_code', x.hs_code, 'unit', x.unit, 'qty', x.qty, 'unit_price_cny', x.unit_price_cny,
                                        'duty_pct', x.duty_pct, 'vat_pct', x.vat_pct, 'freight_pct', x.freight_pct, 'image', x.image) order by x.line_no)
      into ls from public.quotation_lines x where x.quotation_id = q.id and (p_all or x.id = p_ref);
    return jsonb_build_object('header', h, 'lines', ls, 'from', q.code);
  else
    select * into a from public.quote_archive where id = p_ref;
    if a.id is null then raise exception 'Không tìm thấy dòng lưu trữ'; end if;
    return jsonb_build_object('header', jsonb_strip_nulls(jsonb_build_object('hinhThucNK', a.import_method)), 'from', coalesce(a.src_code, 'lưu trữ'),
      'lines', jsonb_build_array(jsonb_build_object('name', a.item_name, 'hs_code', a.hs_code, 'unit', a.unit, 'qty', coalesce(a.qty, 0), 'unit_price_cny', coalesce(a.price_cny, 0),
                                                    'duty_pct', coalesce(a.duty_pct, 0), 'vat_pct', a.vat_pct)));
  end if;
end $$;

-- ---------------- B. Đơn quên chấm vào / quên chấm về ----------------
alter table public.attendance_requests add column if not exists req_time time;
alter table public.attendance_requests drop constraint if exists attendance_requests_kind_check;
alter table public.attendance_requests add constraint attendance_requests_kind_check
  check (kind in ('cong_tac','xac_nhan_cong','xin_muon_som','quen_cham_vao','quen_cham_ra'));

create or replace function app.att_req_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare n int; lim int := coalesce(app.setting_num('attendance','forgot_limit'), 3)::int;
        back int := coalesce(app.setting_num('attendance','forgot_back_days'), 30)::int;
begin
  new.profile_id := coalesce(auth.uid(), new.profile_id);
  if new.kind in ('quen_cham_vao','quen_cham_ra') then
    new.part := 'full'; new.minutes := null;
    if new.req_time is null then raise exception '%', case when new.kind = 'quen_cham_vao' then 'Nhập giờ bạn vào làm' else 'Nhập giờ bạn về' end; end if;
    if new.work_date > app.vn_today() then raise exception 'Không gửi đơn cho ngày chưa tới'; end if;
    if new.work_date < app.vn_today() - back then raise exception 'Chỉ gửi được đơn trong vòng % ngày', back; end if;
    if exists(select 1 from public.payroll_periods pp where pp.month = date_trunc('month', new.work_date)::date and pp.status = 'closed') then
      raise exception 'Kỳ lương tháng % đã chốt — liên hệ HCNS', to_char(new.work_date, 'MM/YYYY'); end if;
    if exists(select 1 from public.attendance_requests r where r.profile_id = new.profile_id and r.kind = new.kind and r.work_date = new.work_date and r.status in ('cho_duyet','da_duyet')) then
      raise exception 'Đã có đơn loại này cho ngày %', to_char(new.work_date, 'DD/MM/YYYY'); end if;
  elsif new.kind = 'xac_nhan_cong' then
    if new.work_date < app.vn_today() - 1 then raise exception 'Đơn xác nhận công phải gửi trong 24 giờ'; end if;
  end if;
  if new.kind in ('xac_nhan_cong','quen_cham_vao','quen_cham_ra') then
    select count(*) into n from public.attendance_requests
     where profile_id = new.profile_id and kind in ('xac_nhan_cong','quen_cham_vao','quen_cham_ra') and status <> 'huy' and status <> 'tu_choi'
       and date_trunc('month', work_date) = date_trunc('month', new.work_date);
    if n >= lim then raise exception 'Đã dùng hết % lần xác nhận công (quên chấm) trong tháng', lim; end if;
  end if;
  return new;
end $$;

create or replace function app.att_req_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare lbl text := case new.kind when 'cong_tac' then 'Đơn công tác' when 'xac_nhan_cong' then 'Xác nhận công'
                     when 'quen_cham_vao' then 'Quên chấm công đến' when 'quen_cham_ra' then 'Quên chấm công về' else 'Xin đi muộn/về sớm' end;
        tm text := case when new.req_time is not null then ' · ' || case when new.kind = 'quen_cham_vao' then 'vào ' else 'về ' end || to_char(new.req_time, 'HH24:MI') else '' end;
        dt text := case when new.status = 'da_duyet' and coalesce(new.confirm_in, new.confirm_out) is not null
                     then 'Giờ chốt: ' || to_char(coalesce(new.confirm_in, new.confirm_out), 'HH24:MI') || coalesce(' · ' || new.decision_note, '') else new.decision_note end;
begin
  if tg_op = 'INSERT' then
    perform app.notify_approvers(new.profile_id, 'approval', lbl || ': ' || app.name_of(new.profile_id), to_char(new.work_date,'DD/MM') || tm || ' · ' || new.reason, '#/hr/approvals');
    perform app.telegram('leave_request', '📝 <b>' || lbl || '</b> · ' || app.esc(app.name_of(new.profile_id)) || ' · ' || to_char(new.work_date, 'DD/MM/YYYY') || tm);
  elsif new.status is distinct from old.status and new.status in ('da_duyet','tu_choi') then
    perform app.notify(new.profile_id, 'approval', lbl || ' ' || to_char(new.work_date,'DD/MM') || (case new.status when 'da_duyet' then ' đã được duyệt' else ' bị từ chối' end), dt, '#/hr/attendance');
  end if;
  return new;
end $$;

create or replace function public.decide_request(p_table text, p_id uuid, p_approve boolean, p_note text default null, p_in time default null, p_out time default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_owner uuid; v_status text; v_lock boolean; v_kind text; v_date date; v_has_in boolean; v_req time;
begin
  if p_table = 'leave' then
    select profile_id, status into v_owner, v_status from public.leave_requests where id = p_id for update;
  elsif p_table = 'attendance' then
    select profile_id, status, kind, work_date, req_time into v_owner, v_status, v_kind, v_date, v_req from public.attendance_requests where id = p_id for update;
  else raise exception 'Loại đơn không hợp lệ'; end if;
  if v_owner is null then raise exception 'Không tìm thấy đơn'; end if;
  if v_status <> 'cho_duyet' then raise exception 'Đơn đã được xử lý'; end if;
  if not (app.can_approve(v_owner) or (app.has_role('hcns') and v_owner <> auth.uid())) then raise exception 'Bạn không có quyền duyệt đơn này'; end if;
  if not p_approve and coalesce(btrim(p_note),'') = '' then raise exception 'Từ chối phải ghi lý do'; end if;
  -- Bản 28: duyệt xác nhận công (quên chấm) phải ghi giờ vào thực tế (xem camera) nếu hôm đó không có lần chấm vào nào
  if p_table = 'attendance' and p_approve and v_kind = 'xac_nhan_cong' then
    v_has_in := exists(select 1 from public.attendance_events e where e.profile_id = v_owner and e.work_date = v_date and e.kind = 'in' and e.status <> 'rejected');
    if p_in is null and not v_has_in then raise exception 'Nhập giờ vào thực tế (xem camera) để tính đi muộn và chuyên cần'; end if;
    if p_in is not null and p_out is not null and p_out <= p_in then raise exception 'Giờ ra phải sau giờ vào'; end if;
  end if;
  -- Bản 37: quên chấm vào → giờ vào = giờ người duyệt chốt (mặc định giờ nhân viên khai); quên chấm về → giờ ra
  if p_table = 'attendance' and p_approve and v_kind = 'quen_cham_vao' then
    p_in := coalesce(p_in, v_req); p_out := null;
    if p_in is null then raise exception 'Nhập giờ vào làm để duyệt'; end if;
  elsif p_table = 'attendance' and p_approve and v_kind = 'quen_cham_ra' then
    p_out := coalesce(p_out, v_req); p_in := null;
    if p_out is null then raise exception 'Nhập giờ về để duyệt'; end if;
  end if;
  if p_table = 'leave' then
    update public.leave_requests set status = case when p_approve then 'da_duyet' else 'tu_choi' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  else
    update public.attendance_requests set status = case when p_approve then 'da_duyet' else 'tu_choi' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note,
      confirm_in = case when p_approve then p_in end, confirm_out = case when p_approve then p_out end where id = p_id;
  end if;
  perform app.log(case when p_approve then 'APPROVE' else 'REJECT' end, p_table || '_requests', p_id::text, jsonb_build_object('note', p_note, 'in', p_in, 'out', p_out));
end $$;

create or replace function app.day_info(p_id uuid, p_schedule text, p_hire date, d date)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('attendance'),'{}'); dv numeric; off numeric := 0; paid_off numeric := 0; work_leave boolean := false;
        lpart text; codes text[] := '{}'; first_in timestamptz; last_out timestamptz; attended boolean; late int := 0; s_start time; s_end time;
        hrs record; l record; forgot boolean := false; holiday record; ci time; co time; ci_v time; co_r time;
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
    select bool_or(true), min(r.confirm_in) filter (where r.kind = 'xac_nhan_cong'), max(r.confirm_out) filter (where r.kind = 'xac_nhan_cong'),
           min(r.confirm_in) filter (where r.kind = 'quen_cham_vao'), max(r.confirm_out) filter (where r.kind = 'quen_cham_ra')
      into forgot, ci, co, ci_v, co_r from public.attendance_requests r
     where r.profile_id = p_id and r.work_date = d and r.status = 'da_duyet' and r.kind in ('xac_nhan_cong','quen_cham_vao','quen_cham_ra');
    forgot := coalesce(forgot, false);
    -- Bản 37: đơn quên chấm vào / về đã duyệt → giờ người duyệt chốt là giờ vào / ra chính thức (thay cả lần chấm muộn)
    if ci_v is not null then first_in := (d + ci_v) at time zone 'Asia/Ho_Chi_Minh'; end if;
    if co_r is not null then last_out := (d + co_r) at time zone 'Asia/Ho_Chi_Minh'; end if;
    -- Bản 28: giờ vào / ra người duyệt xác nhận (xem camera) thay cho lần chấm bị quên
    if first_in is null and ci is not null then first_in := (d + ci) at time zone 'Asia/Ho_Chi_Minh'; end if;
    if last_out is null and co is not null then last_out := (d + co) at time zone 'Asia/Ho_Chi_Minh'; end if;
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

create or replace function public.timesheet(p_month date)
returns table(profile_id uuid, full_name text, employee_code text, org_unit_id uuid, days jsonb, summary jsonb)
language plpgsql stable security definer set search_path = public, app as $$
declare m0 date := date_trunc('month', p_month)::date; m1 date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
        p record; d date; info jsonb; arr jsonb; std numeric; worked numeric; paid numeric; absent numeric; late int; nphep numeric;
        nkp numeric; nkl numeric; ngap int; nforgot int; cc jsonb := coalesce(app.setting('attendance')->'chuyen_can', '{}');
        flex int := coalesce(app.setting_num('attendance','flex_minutes'), 100)::int; over int; score numeric;
        flex_from date := coalesce((app.setting('attendance')->>'flex_start')::date, '2026-11-01'); priv record; see boolean; luong numeric; pc numeric; ded numeric; cong numeric;
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  for p in select * from public.profiles pr where pr.status = 'active' and (pr.id = auth.uid() or app.in_mgmt(pr.id) or app.can_see_hr()) order by pr.full_name loop
    arr := '{}'; std := 0; worked := 0; paid := 0; absent := 0; late := 0;
    for d in select x::date from generate_series(m0, m1, interval '1 day') x loop
      info := app.day_info(p.id, p.work_schedule, p.hire_date, d);
      arr := arr || jsonb_build_object(to_char(d, 'DD'), jsonb_build_object('c', info->>'code', 'l', nullif((info->>'late')::int, 0)));
      std := std + coalesce((info->>'dv')::numeric, 0);
      worked := worked + coalesce((info->>'worked')::numeric, 0); paid := paid + coalesce((info->>'paid')::numeric, 0);
      absent := absent + coalesce((info->>'absent')::numeric, 0); late := late + coalesce((info->>'late')::int, 0);
    end loop;
    select coalesce(sum(l.days) filter (where l.leave_type = 'phep_nam'), 0), coalesce(sum(l.days) filter (where l.leave_type = 'khong_phep'), 0),
           coalesce(sum(l.days) filter (where l.leave_type = 'khong_luong'), 0), count(*) filter (where l.late_notice)
      into nphep, nkp, nkl, ngap from public.leave_requests l where l.profile_id = p.id and l.status = 'da_duyet' and l.start_date between m0 and m1;
    select count(*) into nforgot from public.attendance_requests r where r.profile_id = p.id and r.kind in ('xac_nhan_cong','quen_cham_vao','quen_cham_ra') and r.status = 'da_duyet' and r.work_date between m0 and m1;
    over := greatest(0, late - flex);
    score := greatest(0, coalesce((cc->>'start')::numeric, 100)
      - (nkp + absent) * coalesce((cc->>'khong_phep')::numeric, 20)
      - ngap * coalesce((cc->>'bao_gap')::numeric, 5)
      - nforgot * coalesce((cc->>'quen_cham')::numeric, 3)
      - ceil(over / 10.0) * coalesce((cc->>'moi_10_phut_vuot')::numeric, 1));
    -- Bản 28: lương tạm tính theo công đến hôm nay = lương cơ bản × công hưởng lương ÷ công chuẩn cả tháng + phụ cấp (cùng tỷ lệ) − trừ phút vượt quỹ
    --         (chưa gồm hoa hồng, thưởng — tính khi chốt bảng lương). Chỉ hiện cho chính người đó, HCNS/Kế toán/BGĐ và quản lý trực tiếp.
    see := p.id = auth.uid() or app.can_see_hr() or app.can_approve(p.id);
    luong := null; pc := null; ded := null; cong := least(worked + paid, std);
    if see then
      select pp.* into priv from public.profile_private pp where pp.profile_id = p.id;
      if std > 0 then
        luong := round(coalesce(priv.base_salary, 0) * cong / std); pc := round(coalesce(priv.allowance, 0) * cong / std);
        ded := case when m0 >= flex_from then round(coalesce(priv.base_salary, 0) / std / 8 / 60 * over) else 0 end;
      else luong := 0; pc := 0; ded := 0; end if;
    end if;
    profile_id := p.id; full_name := p.full_name; employee_code := p.employee_code; org_unit_id := p.org_unit_id; days := arr;
    summary := jsonb_build_object('cong_chuan', std, 'di_lam', worked, 'nghi_co_luong', paid, 'cong_huong_luong', least(worked + paid, std),
      'phep_nam', nphep, 'khong_luong', nkl, 'khong_phep', nkp, 'vang_khong_don', absent, 'phut_muon_som', late, 'vuot_quy', over,
      'bao_gap', ngap, 'quen_cham', nforgot, 'chuyen_can', score,
      'luong_co_ban', case when see then coalesce(priv.base_salary, 0) end, 'luong_cong', luong, 'phu_cap', pc, 'tru_vuot_quy', ded,
      'luong_tam_tinh', case when see then luong + pc - ded end,
      'xep_loai', case when score >= 95 then 'A' when score >= 85 then 'B' when score >= 70 then 'C' else 'D' end);
    return next;
  end loop;
end $$;

reset search_path;
