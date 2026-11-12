-- =====================================================================
-- 0051 · Bản 43 (12/11/2026) — sửa tính phút đi muộn / về sớm
--  1. Đơn "Đi muộn, về sớm, ra ngoài" theo giờ đã duyệt bị cộng 2 lần (cộng giờ xin + cộng thêm phút về sớm thực tế).
--     Nay gộp khoảng: phút vắng = (vắng thực tế ∪ giờ xin vắng) trong khung giờ làm — chỗ trùng chỉ tính 1 lần.
--  2. "Công tác, gặp khách" cho chọn THEO GIỜ (đi gặp khách rồi về thẳng): khoảng đó là giờ làm → không tính muộn / sớm.
--     Gặp khách buổi sáng / chiều: chỉ che buổi đó (trước đây che cả ngày, kể cả buổi còn lại đi muộn).
--  3. Màn "Chấm công của tôi" lấy phút muộn từ máy chủ (trước tự tính từ 08:00, bỏ qua đơn nghỉ nửa ngày / gặp khách).
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 43');

create or replace function app.tmin(t time) returns int language sql immutable as $$
  select (extract(hour from t) * 60 + extract(minute from t))::int
$$;

create or replace function app.day_info(p_id uuid, p_schedule text, p_hire date, d date)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('attendance'),'{}'); dv numeric; off numeric := 0; paid_off numeric := 0; work_leave boolean := false;
        lpart text; codes text[] := '{}'; first_in timestamptz; last_out timestamptz; attended boolean; late int := 0; s_start time; s_end time;
        hrs record; l record; forgot boolean := false; holiday record; ci time; co time; ci_v time; co_r time;
        wfull boolean := false; gio int4multirange := '{}'; phu int4multirange := '{}'; vang int4multirange := '{}'; sm int; em int; x int4range;
begin
  dv := app.day_value(p_schedule, d);
  if dv = 0 then return jsonb_build_object('dv', 0, 'code', 'CN'); end if;
  select * into holiday from public.holidays where day = d;
  if holiday.day is not null then return jsonb_build_object('dv', dv, 'code', 'Lễ', 'paid', case when holiday.paid then dv else 0 end, 'worked', 0); end if;
  if p_hire is not null and d < p_hire then return jsonb_build_object('dv', 0, 'code', ''); end if;
  for l in select r.*, lt.extra from public.leave_requests r left join public.lookups lt on lt.category = 'leave_type' and lt.code = r.leave_type
           where r.profile_id = p_id and r.status = 'da_duyet' and d between r.start_date and r.end_date loop
    -- Bản 43: đơn theo giờ ghi thành khoảng phút trong ngày. Gặp khách / công tác theo giờ = vẫn làm việc → che phút vắng;
    --         đi muộn / về sớm / ra ngoài theo giờ = vắng có báo → tính vào quỹ (gộp với giờ chấm thực tế, không cộng 2 lần)
    if l.part = 'hours' then
      if coalesce((l.extra->>'work')::boolean, false) then
        phu := phu + int4multirange(int4range(app.tmin(l.from_time), app.tmin(l.to_time))); work_leave := true; codes := codes || 'CT'::text;
      else
        gio := gio + int4multirange(int4range(app.tmin(l.from_time), app.tmin(l.to_time))); codes := codes || 'G'::text;
      end if;
    elsif coalesce((l.extra->>'work')::boolean, false) then
      work_leave := true; codes := codes || case l.leave_type when 'wfh' then 'WFH' else 'CT' end;
      if l.part = 'full' then wfull := true;
      elsif l.part = 'am' then phu := phu + int4multirange(int4range(0, app.tmin(coalesce((cfg->>'lunch_end')::time, '13:30'))));
      else phu := phu + int4multirange(int4range(app.tmin(coalesce((cfg->>'lunch_start')::time, '12:00')), 1440)); end if;
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
    if off < dv and not wfull and (first_in is not null or not isempty(gio)) then
      s_start := case when lpart = 'am' then coalesce((cfg->>'lunch_end')::time, '13:30') else coalesce((cfg->>'start')::time, '08:00') end;
      s_end := case when extract(isodow from d) = 6 then coalesce((cfg->>'saturday_end')::time, '12:00') when lpart = 'pm' then coalesce((cfg->>'lunch_start')::time, '12:00') else coalesce((cfg->>'end')::time, '17:30') end;
      sm := app.tmin(s_start); em := app.tmin(s_end);
      -- khoảng vắng thực tế: từ giờ bắt đầu tới lúc vào, từ lúc ra tới giờ kết thúc (chỉ tính ngày đã qua)
      if first_in is not null then vang := vang + int4multirange(int4range(sm, greatest(sm, app.tmin((first_in at time zone 'Asia/Ho_Chi_Minh')::time)))); end if;
      if last_out is not null and d < app.vn_today() then vang := vang + int4multirange(int4range(least(em, app.tmin((last_out at time zone 'Asia/Ho_Chi_Minh')::time)), em)); end if;
      -- + giờ xin vắng (gộp, không cộng trùng) − giờ đi gặp khách / công tác; chỉ trong khung giờ làm
      vang := ((vang + gio) - phu) * int4multirange(int4range(sm, em));
      for x in select unnest(vang) loop late := late + (upper(x) - lower(x)); end loop;
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

-- Đơn xin nghỉ: cho "Công tác, gặp khách" chọn theo giờ
create or replace function app.leave_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_avail numeric; lt record; v_on_behalf boolean;
begin
  if tg_op = 'INSERT' then
    v_on_behalf := new.profile_id is not null and new.profile_id <> auth.uid();
    if v_on_behalf and not (app.has_role('admin','bgd','hcns') or app.can_approve(new.profile_id)) then
      raise exception 'Chỉ quản lý hoặc HCNS được tạo đơn hộ';
    end if;
    if new.profile_id is null then new.profile_id := auth.uid(); end if;
    select * into lt from public.lookups where category = 'leave_type' and code = new.leave_type;
    if lt.code is null then raise exception 'Loại đơn không hợp lệ'; end if;
    if coalesce((lt.extra->>'hours')::boolean, false) then
      new.part := 'hours'; new.end_date := new.start_date;
      if new.from_time is null or new.to_time is null or new.to_time <= new.from_time then raise exception 'Nhập giờ đi và giờ về'; end if;
    elsif new.part = 'hours' and coalesce((lt.extra->>'work')::boolean, false) then
      -- Bản 43: công tác / gặp khách theo giờ (đi gặp khách rồi về thẳng)
      new.end_date := new.start_date;
      if new.from_time is null or new.to_time is null or new.to_time <= new.from_time then raise exception 'Nhập giờ đi và giờ về'; end if;
    elsif new.part = 'hours' then new.part := 'full';
    end if;
    if new.start_date < app.vn_today() and not v_on_behalf and new.leave_type not in ('om_dau','khong_phep') then
      raise exception 'Đơn cho ngày đã qua phải do quản lý/HCNS tạo hộ';
    end if;
    new.days := app.leave_days(new.profile_id, new.start_date, new.end_date, new.part);
    if new.days <= 0 and new.part <> 'hours' then raise exception 'Khoảng ngày không có ngày làm việc'; end if;
    new.late_notice := (lt.extra ? 'notice_days') and new.start_date < app.vn_today() + (lt.extra->>'notice_days')::int;
    if new.leave_type = 'phep_nam' then
      v_avail := (public.leave_balance(new.profile_id, extract(year from new.start_date)::int)->>'available')::numeric;
      if v_avail < new.days then
        raise exception 'Phép năm còn % ngày, không đủ cho % ngày. Chọn "Nghỉ không lương" cho phần thiếu.', v_avail, new.days;
      end if;
    end if;
    if new.part <> 'hours' and exists(select 1 from public.leave_requests l where l.profile_id = new.profile_id and l.status in ('cho_duyet','da_duyet') and l.part <> 'hours'
               and daterange(l.start_date, l.end_date, '[]') && daterange(new.start_date, new.end_date, '[]')
               and (l.part = 'full' or new.part = 'full' or l.part = new.part)) then
      raise exception 'Trùng với đơn khác';
    end if;
    if v_on_behalf then new.status := 'da_duyet'; new.decided_by := auth.uid(); new.decided_at := now(); end if;
  end if;
  return new;
end $$;

-- Màn "Chấm công của tôi": phút muộn / sớm từng ngày theo đúng cách tính bảng công (có đơn nghỉ nửa ngày, gặp khách…)
create or replace function public.att_my_month(p_month date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare p public.profiles; d date; out jsonb := '{}'; i jsonb;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null then raise exception 'Chưa đăng nhập'; end if;
  for d in select x::date from generate_series(date_trunc('month', p_month), least(date_trunc('month', p_month) + interval '1 month - 1 day', app.vn_today()::timestamp), interval '1 day') x loop
    i := app.day_info(p.id, p.work_schedule, p.hire_date, d);
    out := out || jsonb_build_object(to_char(d, 'YYYY-MM-DD'), jsonb_build_object('l', coalesce((i->>'late')::int, 0), 'c', i->>'code'));
  end loop;
  return out;
end $$;
grant execute on function public.att_my_month(date) to authenticated;

reset search_path;
