-- =====================================================================
-- ERP Nam Trung · 0008 Bản 2: loại đơn mở rộng, sổ phép đầu kỳ, Hôm nay,
-- bảng công + chuyên cần, chỉ đạo sale / nhờ hỗ trợ, claim & hỏi đáp,
-- báo cáo ngày có duyệt FB, đếm trạng thái khách
-- =====================================================================

-- ---------- Loại đơn (theo quy định chấm công) ----------
-- extra.group: nghi (vàng) | ra_ngoai (xanh, vẫn tính công) | gio (đỏ, vắng theo giờ)
insert into public.lookups(category, code, label, sort, extra) values
 ('leave_type','phep_nam','Nghỉ phép năm',1,'{"paid":true,"group":"nghi","notice_days":2,"balance":true}'),
 ('leave_type','che_do','Việc riêng có lương (cưới, tang)',2,'{"paid":true,"group":"nghi","notice_days":1}'),
 ('leave_type','om_dau','Nghỉ ốm',3,'{"paid":false,"group":"nghi"}'),
 ('leave_type','thai_san','Thai sản, khám thai',4,'{"paid":false,"group":"nghi"}'),
 ('leave_type','khong_luong','Nghỉ không lương',5,'{"paid":false,"group":"nghi","notice_days":2}'),
 ('leave_type','cong_tac','Công tác, gặp khách',6,'{"paid":true,"work":true,"group":"ra_ngoai"}'),
 ('leave_type','wfh','Làm việc từ xa',7,'{"paid":true,"work":true,"group":"ra_ngoai","notice_days":1}'),
 ('leave_type','muon_som','Đi muộn, về sớm, ra ngoài',8,'{"paid":true,"hours":true,"group":"gio"}'),
 ('leave_type','khong_phep','Nghỉ không phép',9,'{"paid":false,"group":"nghi","penalty":true}')
on conflict (category, code) do update set label = excluded.label, sort = excluded.sort, extra = excluded.extra;

alter table public.leave_requests drop constraint if exists leave_requests_part_check;
alter table public.leave_requests add constraint leave_requests_part_check check (part in ('full','am','pm','hours'));
alter table public.leave_requests add column if not exists from_time time;
alter table public.leave_requests add column if not exists to_time time;
alter table public.leave_requests add column if not exists backup_id uuid references public.profiles(id);
alter table public.leave_requests add column if not exists handover text;
alter table public.leave_requests add column if not exists late_notice boolean not null default false;

-- ---------- Sổ phép theo năm (nhập số dư khi bắt đầu dùng giữa năm) ----------
create table if not exists public.leave_entitlements(
  profile_id uuid not null references public.profiles(id) on delete cascade,
  year int not null,
  entitled numeric(5,1) not null default 12,      -- được hưởng năm nay
  carried numeric(5,1) not null default 0,        -- tồn năm trước (dùng đến 30/06)
  used_before numeric(5,1) not null default 0,    -- đã dùng trước khi lên hệ thống
  note text,
  updated_by uuid default auth.uid(),
  updated_at timestamptz default now(),
  primary key (profile_id, year)
);
alter table public.leave_entitlements enable row level security;
grant select, insert, update, delete on public.leave_entitlements to authenticated;
revoke all on public.leave_entitlements from anon;
drop policy if exists le_read on public.leave_entitlements;
drop policy if exists le_write on public.leave_entitlements;
create policy le_read on public.leave_entitlements for select to authenticated using (profile_id = auth.uid() or app.in_tree(profile_id) or app.can_see_hr());
create policy le_write on public.leave_entitlements for all to authenticated using (app.has_role('admin','bgd','hcns')) with check (app.has_role('admin','bgd','hcns'));
drop trigger if exists audit_le on public.leave_entitlements;
create trigger audit_le after insert or update or delete on public.leave_entitlements for each row execute function app.audit();

create or replace function app.leave_days(p_profile uuid, p_start date, p_end date, p_part text) returns numeric
language sql stable security definer set search_path = public, app as $$
  select case when p_part = 'hours' then 0 else coalesce(sum(case when p_part = 'full' then v else least(v, 0.5) end), 0) end
  from (select app.day_value(coalesce((select work_schedule from public.profiles where id = p_profile),'office'), d::date) v, d::date dd
        from generate_series(p_start, p_end, interval '1 day') d) x
  where not exists (select 1 from public.holidays h where h.day = x.dd)
$$;

drop function if exists public.leave_balance(uuid);
create or replace function public.leave_balance(p_profile uuid default null, p_year int default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare v_id uuid := coalesce(p_profile, auth.uid()); y int := coalesce(p_year, extract(year from app.vn_today())::int);
        e record; used_h1 numeric; used_h2 numeric; pending numeric; total_used numeric; carry_left numeric; remaining numeric;
        doy int := extract(doy from app.vn_today())::int; ndays int := extract(doy from make_date(y, 12, 31))::int;
begin
  if not (v_id = auth.uid() or app.can_see_hr() or app.in_tree(v_id)) then raise exception 'Không có quyền'; end if;
  select * into e from public.leave_entitlements where profile_id = v_id and year = y;
  if e is null then
    e := row(v_id, y, coalesce(app.setting_num('leave','annual_days'), 12), 0, 0, null, null, null)::public.leave_entitlements;
  end if;
  select coalesce(sum(days) filter (where start_date <= make_date(y,6,30)), 0), coalesce(sum(days) filter (where start_date > make_date(y,6,30)), 0)
    into used_h1, used_h2 from public.leave_requests where profile_id = v_id and leave_type = 'phep_nam' and status = 'da_duyet' and extract(year from start_date) = y;
  select coalesce(sum(days), 0) into pending from public.leave_requests where profile_id = v_id and leave_type = 'phep_nam' and status = 'cho_duyet' and extract(year from start_date) = y;
  used_h1 := used_h1 + e.used_before;
  total_used := used_h1 + used_h2;
  -- phép tồn năm trước chỉ dùng đến 30/06; dùng phép tồn trước
  if app.vn_today() > make_date(y, 6, 30) or y < extract(year from app.vn_today()) then
    carry_left := least(e.carried, used_h1);
  else
    carry_left := e.carried;
  end if;
  remaining := e.entitled + carry_left - total_used;
  return jsonb_build_object('year', y, 'entitled', e.entitled, 'carried', e.carried, 'used_before', e.used_before,
    'used', total_used, 'used_year', total_used, 'pending', pending, 'balance', remaining, 'available', remaining - pending,
    'accrued', round(e.entitled * least(doy, ndays) / ndays * 2) / 2, 'configured', exists(select 1 from public.leave_entitlements where profile_id = v_id and year = y));
end $$;

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

create or replace function app.leave_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare lbl text := (select label from public.lookups where category='leave_type' and code = new.leave_type);
        rng text := to_char(new.start_date,'DD/MM') || case when new.end_date > new.start_date then '–' || to_char(new.end_date,'DD/MM') else '' end
                    || case new.part when 'am' then ' (sáng)' when 'pm' then ' (chiều)' when 'hours' then ' ' || to_char(new.from_time,'HH24:MI') || '–' || to_char(new.to_time,'HH24:MI') else '' end;
begin
  if tg_op = 'INSERT' then
    if new.status = 'da_duyet' then
      perform app.notify(new.profile_id, 'approval', lbl || ' ' || rng || ' đã được ghi nhận', 'Tạo bởi ' || app.name_of(new.decided_by), '#/hr/leave');
    else
      perform app.notify_approvers(new.profile_id, 'approval', lbl || ': ' || app.name_of(new.profile_id), rng || ' · ' || new.days || ' ngày' || case when new.late_notice then ' · báo gấp' else '' end, '#/hr/approvals');
    end if;
    if new.backup_id is not null then
      perform app.notify(new.backup_id, 'leave', app.name_of(new.profile_id) || ' vắng ' || rng || ', nhờ bạn hỗ trợ việc gấp', new.handover, '#/');
    end if;
    perform app.telegram('leave_request', '🏖 <b>' || app.esc(coalesce(lbl, new.leave_type)) || '</b> · ' || app.esc(app.name_of(new.profile_id)) || E'\n' || rng
      || case when new.part <> 'hours' then ' · ' || new.days || ' ngày' else '' end || case when new.late_notice then ' · ⚠️ báo gấp' else '' end
      || case when new.status = 'da_duyet' then ' · đã duyệt' else ' · chờ duyệt' end);
  elsif new.status is distinct from old.status and new.status in ('da_duyet','tu_choi') then
    perform app.notify(new.profile_id, 'approval', lbl || ' ' || rng || case new.status when 'da_duyet' then ' đã được duyệt' else ' bị từ chối' end, new.decision_note, '#/hr/leave');
  end if;
  return new;
end $$;

-- ---------- Trạng thái 1 ngày công của 1 người (dùng chung cho Bảng công và Lương) ----------
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
      late := late + floor(extract(epoch from (l.to_time - l.from_time)) / 60)::int; codes := codes || 'G';
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

-- ---------- Bảng công + chuyên cần ----------
create or replace function public.timesheet(p_month date)
returns table(profile_id uuid, full_name text, employee_code text, org_unit_id uuid, days jsonb, summary jsonb)
language plpgsql stable security definer set search_path = public, app as $$
declare m0 date := date_trunc('month', p_month)::date; m1 date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
        p record; d date; info jsonb; arr jsonb; std numeric; worked numeric; paid numeric; absent numeric; late int; nphep numeric;
        nkp numeric; nkl numeric; ngap int; nforgot int; cc jsonb := coalesce(app.setting('attendance')->'chuyen_can', '{}');
        flex int := coalesce(app.setting_num('attendance','flex_minutes'), 100)::int; over int; score numeric;
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  for p in select * from public.profiles pr where pr.status = 'active' and (pr.id = auth.uid() or app.in_tree(pr.id) or app.can_see_hr()) order by pr.full_name loop
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
    select count(*) into nforgot from public.attendance_requests r where r.profile_id = p.id and r.kind = 'xac_nhan_cong' and r.status = 'da_duyet' and r.work_date between m0 and m1;
    over := greatest(0, late - flex);
    score := greatest(0, coalesce((cc->>'start')::numeric, 100)
      - (nkp + absent) * coalesce((cc->>'khong_phep')::numeric, 20)
      - ngap * coalesce((cc->>'bao_gap')::numeric, 5)
      - nforgot * coalesce((cc->>'quen_cham')::numeric, 3)
      - ceil(over / 10.0) * coalesce((cc->>'moi_10_phut_vuot')::numeric, 1));
    profile_id := p.id; full_name := p.full_name; employee_code := p.employee_code; org_unit_id := p.org_unit_id; days := arr;
    summary := jsonb_build_object('cong_chuan', std, 'di_lam', worked, 'nghi_co_luong', paid, 'cong_huong_luong', least(worked + paid, std),
      'phep_nam', nphep, 'khong_luong', nkl, 'khong_phep', nkp, 'vang_khong_don', absent, 'phut_muon_som', late, 'vuot_quy', over,
      'bao_gap', ngap, 'quen_cham', nforgot, 'chuyen_can', score,
      'xep_loai', case when score >= 95 then 'A' when score >= 85 then 'B' when score >= 70 then 'C' else 'D' end);
    return next;
  end loop;
end $$;

-- Lương dùng chung logic ngày công
create or replace function public.payroll_compute(p_period uuid)
returns int language plpgsql security definer set search_path = public, app as $$
declare
  per record; p record; pcfg jsonb := coalesce(app.setting('payroll'),'{}');
  m_start date; m_end date; d date; info jsonb;
  std numeric; paid numeric; worked numeric; pleave numeric; unpaid numeric; late int; over int;
  flex_min int := coalesce(app.setting_num('attendance','flex_minutes'), 100)::int; flex_from date := coalesce((app.setting('attendance')->>'flex_start')::date, '2026-11-01');
  base_pct numeric := coalesce((pcfg->>'commission_base_pct')::numeric, 60); max_off numeric := coalesce((pcfg->>'loss_offset_max_pct')::numeric, 50);
  priv record; lvl record; pos numeric; loss numeric; carry_in numeric; com numeric; off numeric; team numeric; adj numeric; sal numeric; flexded numeric; n int := 0; detail jsonb;
begin
  if not app.has_role('admin','bgd','hcns','ke_toan') then raise exception 'Không có quyền tính lương'; end if;
  select * into per from public.payroll_periods where id = p_period for update;
  if per.id is null then raise exception 'Kỳ lương không tồn tại'; end if;
  if per.status not in ('open','review') then raise exception 'Kỳ lương đang chờ duyệt hoặc đã chốt'; end if;
  m_start := per.month; m_end := (per.month + interval '1 month - 1 day')::date;
  for p in select * from public.profiles where status = 'active' loop
    std := 0; paid := 0; worked := 0; pleave := 0; unpaid := 0; late := 0;
    for d in select x::date from generate_series(m_start, m_end, interval '1 day') x loop
      info := app.day_info(p.id, p.work_schedule, p.hire_date, d);
      std := std + coalesce((info->>'dv')::numeric, 0);
      if coalesce((info->>'future')::boolean, false) then worked := worked + coalesce((info->>'dv')::numeric, 0) - coalesce((info->>'off')::numeric, 0); pleave := pleave + coalesce((info->>'paid')::numeric, 0); continue; end if;
      worked := worked + coalesce((info->>'worked')::numeric, 0); pleave := pleave + coalesce((info->>'paid')::numeric, 0);
      unpaid := unpaid + coalesce((info->>'absent')::numeric, 0) + coalesce((info->>'off')::numeric, 0) - coalesce((info->>'paid')::numeric, 0);
      late := late + coalesce((info->>'late')::int, 0);
    end loop;
    paid := worked + pleave;
    select * into priv from public.profile_private where profile_id = p.id;
    select * into lvl from public.job_levels where code = p.job_level;
    sal := case when std > 0 then round(coalesce(priv.base_salary,0) * least(paid, std) / std) else 0 end;
    over := case when m_start >= flex_from then greatest(0, late - flex_min) else 0 end;
    flexded := case when std > 0 then round(coalesce(priv.base_salary,0) / std / 8 / 60 * over) else 0 end;
    select coalesce(sum(round(order_profit * base_pct / 100)) filter (where order_profit > 0), 0),
           coalesce(-sum(round(order_profit * base_pct / 100)) filter (where order_profit < 0), 0)
      into pos, loss from public.order_results where period_id = p_period and profile_id = p.id;
    select coalesce(ps.carry_loss, 0) into carry_in from public.payslips ps join public.payroll_periods pp on pp.id = ps.period_id
      where ps.profile_id = p.id and pp.month = (m_start - interval '1 month')::date;
    carry_in := coalesce(carry_in, 0);
    com := app.tiered_commission(pos, coalesce(lvl.commission_pct, 0));
    off := least(loss + carry_in, round(com * max_off / 100));
    team := 0;
    if coalesce(lvl.team_bonus_pct, 0) > 0 then
      with recursive t as (select id from public.profiles where manager_id = p.id union select x.id from public.profiles x join t on x.manager_id = t.id)
      select coalesce(round(sum(round(o.order_profit * base_pct / 100)) * lvl.team_bonus_pct / 100), 0) into team
        from public.order_results o where o.period_id = p_period and o.profile_id in (select id from t);
      team := greatest(team, 0);
    end if;
    select coalesce(sum(a.amount),0) into adj from public.payslip_adjustments a join public.payslips ps on ps.id = a.payslip_id where ps.period_id = p_period and ps.profile_id = p.id;
    detail := jsonb_build_object('late_minutes', late, 'flex_minutes', flex_min, 'flex_active', m_start >= flex_from, 'commission_pct', coalesce(lvl.commission_pct,0),
      'commission_base_pct', base_pct, 'loss_this_month', loss, 'carry_in', carry_in, 'orders', (select count(*) from public.order_results where period_id = p_period and profile_id = p.id));
    insert into public.payslips as ps(period_id, profile_id, standard_days, paid_days, worked_days, paid_leave_days, unpaid_days, late_minutes, flex_over_minutes, base_salary,
      salary_by_days, allowance, profit_total, commission_base, commission, loss_offset, carry_loss, team_bonus, flex_deduction, insurance, adjustments, net, details, status, updated_at)
    values (p_period, p.id, std, least(paid, std), worked, pleave, greatest(unpaid, 0), late, over, coalesce(priv.base_salary,0), sal, coalesce(priv.allowance,0),
      (select coalesce(sum(order_profit),0) from public.order_results where period_id = p_period and profile_id = p.id),
      pos, com, off, loss + carry_in - off, team, flexded, coalesce(priv.insurance_deduction,0), adj,
      sal + coalesce(priv.allowance,0) + com - off + team - flexded - coalesce(priv.insurance_deduction,0) + adj, detail, 'draft', now())
    on conflict (period_id, profile_id) do update set standard_days = excluded.standard_days, paid_days = excluded.paid_days, worked_days = excluded.worked_days,
      paid_leave_days = excluded.paid_leave_days, unpaid_days = excluded.unpaid_days, late_minutes = excluded.late_minutes, flex_over_minutes = excluded.flex_over_minutes,
      base_salary = excluded.base_salary, salary_by_days = excluded.salary_by_days, allowance = excluded.allowance, profit_total = excluded.profit_total,
      commission_base = excluded.commission_base, commission = excluded.commission, loss_offset = excluded.loss_offset, carry_loss = excluded.carry_loss,
      team_bonus = excluded.team_bonus, flex_deduction = excluded.flex_deduction, insurance = excluded.insurance, adjustments = excluded.adjustments,
      net = excluded.net, details = excluded.details, status = 'draft', confirmed_at = null, updated_at = now()
    where ps.status <> 'closed';
    n := n + 1;
  end loop;
  update public.payroll_periods set computed_at = now(), status = 'open' where id = p_period;
  return n;
end $$;

-- ---------- Hôm nay: ai vắng / ra ngoài (không lộ lý do) ----------
create or replace function public.today_board(p_from date, p_to date)
returns table(day date, profile_id uuid, full_name text, org_unit_id uuid, category text, label text, part text, from_time time, to_time time, status text, backup_name text)
language sql stable security definer set search_path = public, app as $$
  select g::date, l.profile_id, p.full_name, p.org_unit_id, coalesce(lt.extra->>'group', 'nghi'),
         case when lt.extra->>'group' = 'nghi' then 'Nghỉ' else lt.label end, l.part, l.from_time, l.to_time, l.status, app.name_of(l.backup_id)
  from public.leave_requests l
  join public.profiles p on p.id = l.profile_id
  left join public.lookups lt on lt.category = 'leave_type' and lt.code = l.leave_type
  cross join lateral generate_series(greatest(l.start_date, p_from), least(l.end_date, p_to), interval '1 day') g
  where app.is_active() and l.status in ('cho_duyet','da_duyet') and l.start_date <= p_to and l.end_date >= p_from and extract(isodow from g) < 7
  order by 1, 3
$$;

-- ---------- Báo cáo ngày: link FB + duyệt ----------
alter table public.daily_reports add column if not exists fb_links text[] not null default '{}';
alter table public.daily_reports add column if not exists fb_status text check (fb_status in ('dat','khong_dat'));
alter table public.daily_reports add column if not exists reviewed_at timestamptz;
drop policy if exists dr_upd on public.daily_reports;
create policy dr_upd on public.daily_reports for update to authenticated using (app.can_approve(sale_id) or (sale_id = auth.uid() and reviewed_by is null));
create or replace function app.daily_guard() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if not app.can_approve(old.sale_id) then
    new.fb_status := old.fb_status; new.reviewed_by := old.reviewed_by; new.review_note := old.review_note; new.reviewed_at := old.reviewed_at;
    new.report_date := old.report_date; new.sale_id := old.sale_id; new.on_time := old.on_time;
  elsif (new.fb_status, new.review_note) is distinct from (old.fb_status, old.review_note) then
    new.reviewed_by := auth.uid(); new.reviewed_at := now();
    perform app.notify(old.sale_id, 'report', 'Báo cáo ngày ' || to_char(old.report_date,'DD/MM') || ' đã được nhận xét',
      case new.fb_status when 'dat' then 'FB: Đạt. ' when 'khong_dat' then 'FB: Không đạt. ' else '' end || coalesce(new.review_note,''), '#/crm/daily');
  end if;
  return new;
end $$;
drop trigger if exists daily_guard on public.daily_reports;
create trigger daily_guard before update on public.daily_reports for each row execute function app.daily_guard();

-- KPI: bài FB = link trong báo cáo ngày được duyệt "Đạt" (+ bài cũ đã xác nhận)
create or replace function public.kpi_report(p_from date, p_to date, p_all boolean default false)
returns table(profile_id uuid, full_name text, job_level text, is_new boolean, metrics jsonb, score numeric, grade text)
language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('kpi'), '{}'); days int := greatest(app.kpi_days(p_from, least(p_to, app.vn_today())), 1);
        t0 timestamptz := (p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'); t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh');
begin
  return query
  with sales as (
    select p.id, p.full_name, p.job_level, p.is_new_hire from public.profiles p
    where p.status = 'active' and p.roles && array['sale','tn_kd','tp_kd'] and (p_all and app.is_active() or p.id = any(app.my_tree()) or app.is_admin())
  ), m as (
    select s.id, s.full_name, s.job_level, s.is_new_hire, jsonb_build_object(
      'kh_moi', (select count(*) from public.customers c where c.created_by = s.id and c.created_at >= t0 and c.created_at < t1),
      'tiep_can', (select count(distinct cl.customer_id) from public.care_logs cl where cl.sale_id = s.id and cl.purpose = 'tiep_can_lan_dau' and cl.created_at >= t0 and cl.created_at < t1),
      'ket_noi', (select count(*) from public.care_logs cl where cl.sale_id = s.id and cl.is_connected and cl.created_at >= t0 and cl.created_at < t1),
      'cham_cu', (select count(*) from public.care_logs cl where cl.sale_id = s.id and cl.purpose <> 'tiep_can_lan_dau' and cl.created_at >= t0 and cl.created_at < t1),
      'bao_gia', (select count(*) from public.quotations q where q.sale_id = s.id and q.sent_at >= t0 and q.sent_at < t1),
      'bai_fb', (select coalesce(sum(cardinality(r.fb_links)), 0) from public.daily_reports r where r.sale_id = s.id and r.report_date between p_from and p_to and r.fb_status = 'dat')
              + (select count(*) from public.fb_posts f where f.sale_id = s.id and f.post_date between p_from and p_to and f.verified_at is not null),
      'bao_cao', (select count(*) from public.daily_reports r where r.sale_id = s.id and r.report_date between p_from and p_to and r.on_time),
      'cuoc_goi_khai', (select coalesce(sum(r.calls),0) from public.daily_reports r where r.sale_id = s.id and r.report_date between p_from and p_to),
      'tin_nhan_khai', (select coalesce(sum(r.messages),0) from public.daily_reports r where r.sale_id = s.id and r.report_date between p_from and p_to),
      'cuoc_goi_nhat_ky', (select count(*) from public.care_logs cl where cl.sale_id = s.id and cl.channel = 'goi_dien' and cl.created_at >= t0 and cl.created_at < t1),
      'tin_nhan_nhat_ky', (select count(*) from public.care_logs cl where cl.sale_id = s.id and cl.channel in ('zalo','sms','facebook') and cl.created_at >= t0 and cl.created_at < t1),
      'khach_nong_am', (select count(distinct cl.customer_id) from public.care_logs cl where cl.sale_id = s.id and cl.temperature_after in ('nong','am') and cl.created_at >= t0 and cl.created_at < t1),
      'don_chot', (select count(*) from public.quotations q where q.sale_id = s.id and q.won_at >= t0 and q.won_at < t1),
      'qua_han', (select count(*) from public.customers c where c.owner_id = s.id and c.deleted_at is null and c.next_care_date < app.vn_today())
    ) mx from sales s
  ), sc as (
    select m.*, round(coalesce(sum(least(coalesce((m.mx->>k.key)::numeric,0) / nullif((k.value->>'day')::numeric * days * case when m.is_new_hire then coalesce((cfg->>'new_hire_factor')::numeric, 0.7) else 1 end, 0), 1.2)
          * (k.value->>'weight')::numeric), 0), 1) s
    from m cross join lateral jsonb_each(coalesce(cfg->'metrics', '{}')) k group by m.id, m.full_name, m.job_level, m.is_new_hire, m.mx
  )
  select sc.id, sc.full_name, sc.job_level, sc.is_new_hire, sc.mx || jsonb_build_object('days', days), sc.s,
    case when sc.s >= 100 then 'Xuất sắc' when sc.s >= 85 then 'Đạt' when sc.s >= 70 then 'Cần cải thiện' else 'Không đạt' end
  from sc order by 6 desc nulls last;
end $$;

-- ---------- Hỗ trợ khách: chỉ đạo sale / nhờ hỗ trợ ----------
alter table public.support_requests add column if not exists kind text not null default 'ho_tro';
alter table public.support_requests drop constraint if exists support_requests_kind_check;
alter table public.support_requests add constraint support_requests_kind_check check (kind in ('ho_tro','chi_dao','nho_ho_tro'));
alter table public.support_requests add column if not exists topic text;
alter table public.support_requests add column if not exists due_date date;
alter table public.support_requests add column if not exists response text;
alter table public.support_requests drop constraint if exists support_requests_priority_check;
alter table public.support_requests add constraint support_requests_priority_check check (priority in ('thap','thuong','gap','khan'));

create or replace function app.support_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare lbl text := case new.kind when 'chi_dao' then '🎯 Chỉ đạo từ ' when 'nho_ho_tro' then '🙋 Nhờ hỗ trợ từ ' else '🆘 Hỗ trợ từ ' end;
        cname text := (select coalesce(company_name, contact_name) from public.customers where id = new.customer_id);
begin
  if tg_op = 'INSERT' then
    if new.assignee_id is not null then
      perform app.notify(new.assignee_id, 'support', lbl || app.name_of(new.requester_id), coalesce(cname || ': ', '') || new.title, '#/support?id=' || new.id);
    elsif new.org_unit_id is not null then
      perform app.notify(p.id, 'support', lbl || app.name_of(new.requester_id), coalesce(cname || ': ', '') || new.title, '#/support?id=' || new.id)
        from public.profiles p where p.org_unit_id = new.org_unit_id and p.status='active';
    end if;
    perform app.telegram('support', lbl || '<b>' || app.esc(app.name_of(new.requester_id)) || '</b> → ' || app.esc(coalesce(app.name_of(new.assignee_id), 'phòng ban'))
      || coalesce(E'\nKhách: ' || app.esc(cname), '') || E'\n' || app.esc(new.title) || case when new.priority in ('gap','khan') then ' · ⚠️ ' || new.priority else '' end);
  elsif new.status is distinct from old.status then
    perform app.notify(case when auth.uid() = new.requester_id then new.assignee_id else new.requester_id end, 'support',
      new.code || ': ' || case new.status when 'da_nhan' then 'đã nhận' when 'dang_xu_ly' then 'đang xử lý' when 'xong' then 'đã xong' when 'dong' then 'đã đóng' else new.status end,
      coalesce(new.response, new.title), '#/support?id=' || new.id);
  end if;
  return new;
end $$;

create or replace function app.support_msg_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare r record;
begin
  select * into r from public.support_requests where id = new.request_id;
  perform app.notify(x, 'support', '💬 ' || app.name_of(new.author_id) || ' trả lời ' || r.code, left(new.body, 200), '#/support?id=' || r.id)
    from unnest(array[r.requester_id, r.assignee_id]) x where x is not null and x <> new.author_id;
  return new;
end $$;
drop trigger if exists support_msg_after on public.support_messages;
create trigger support_msg_after after insert on public.support_messages for each row execute function app.support_msg_after();

insert into public.lookups(category, code, label, sort) values
 ('directive_topic','goi_lai','Gọi lại / chăm lại khách',1),('directive_topic','bao_gia','Làm / sửa báo giá',2),('directive_topic','chot_don','Đẩy chốt đơn',3),
 ('directive_topic','xu_ly_kn','Xử lý phản ánh, khiếu nại',4),('directive_topic','cap_nhat','Cập nhật thông tin khách',5),('directive_topic','khac','Khác',9),
 ('help_topic','gia','Cần hỗ trợ giá / phá khung',1),('help_topic','gap_khach','Cần quản lý gặp / gọi khách cùng',2),('help_topic','nghiep_vu','Hỏi nghiệp vụ XNK, HS, giấy phép',3),
 ('help_topic','van_hanh','Phối hợp kho, mua hàng, CSKH',4),('help_topic','khac','Khác',9)
on conflict do nothing;

-- ---------- Claim & hỏi đáp (thay "Ý tưởng · Lỗi") ----------
alter table public.tickets drop constraint if exists tickets_type_check;
alter table public.tickets add constraint tickets_type_check check (type in ('claim_hang','claim_giao_hang','claim_hoa_hong','hoi_dap','de_xuat','loi_he_thong','khac','y_tuong','loi','cai_tien'));
alter table public.tickets drop constraint if exists tickets_priority_check;
alter table public.tickets add constraint tickets_priority_check check (priority in ('binh_thuong','gap','khan','thap','trung_binh','cao'));
alter table public.tickets alter column priority set default 'binh_thuong';
alter table public.tickets add column if not exists customer_text text;
alter table public.tickets add column if not exists order_code text;
alter table public.tickets add column if not exists attachments text[] not null default '{}';
alter table public.tickets add column if not exists answer text;
alter table public.tickets add column if not exists is_public boolean not null default false;
alter table public.tickets add column if not exists answered_at timestamptz;
drop policy if exists tk_read on public.tickets;
create policy tk_read on public.tickets for select to authenticated using (reporter_id = auth.uid() or assignee_id = auth.uid() or app.is_admin() or is_public
  or (type = 'claim_hoa_hong' and app.has_role('ke_toan')));
drop policy if exists tc_read on public.ticket_comments;
create policy tc_read on public.ticket_comments for select to authenticated using (exists(select 1 from public.tickets t where t.id = ticket_id));

create or replace function app.ticket_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare lbl text := (select label from public.lookups where category = 'claim_type' and code = new.type);
begin
  if tg_op = 'INSERT' then
    perform app.notify_roles(case when new.type = 'claim_hoa_hong' then array['admin','ke_toan'] else array['admin'] end, 'ticket',
      '📮 ' || coalesce(lbl, new.type) || ': ' || app.name_of(new.reporter_id), new.title, '#/tickets?id=' || new.id);
    perform app.telegram('ticket', '📮 <b>' || app.esc(coalesce(lbl, new.type)) || '</b> ' || new.code || case when new.priority in ('gap','khan') then ' ⚠️ ' || new.priority else '' end
      || E'\n' || app.esc(new.title) || E'\nNgười gửi: ' || app.esc(app.name_of(new.reporter_id)));
  else
    if new.assignee_id is distinct from old.assignee_id then
      perform app.notify(new.assignee_id, 'ticket', 'Bạn được giao xử lý ' || new.code, new.title, '#/tickets?id=' || new.id);
    end if;
    if new.status is distinct from old.status or new.answer is distinct from old.answer then
      perform app.notify(new.reporter_id, 'ticket', new.code || case when new.answer is distinct from old.answer then ' đã có trả lời' else ': ' || new.status end, coalesce(left(new.answer, 200), new.title), '#/tickets?id=' || new.id);
    end if;
  end if;
  return new;
end $$;
create or replace function app.ticket_guard() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() and auth.uid() is distinct from old.assignee_id and not (old.type = 'claim_hoa_hong' and app.has_role('ke_toan')) then
    if (new.assignee_id, new.priority, new.answer, new.is_public) is distinct from (old.assignee_id, old.priority, old.answer, old.is_public) then raise exception 'Chỉ người xử lý được trả lời / phân công'; end if;
    if new.status not in ('moi','dong') and new.status is distinct from old.status then raise exception 'Người gửi chỉ đóng được yêu cầu'; end if;
  end if;
  if new.answer is distinct from old.answer and new.answer is not null then new.answered_at := now(); end if;
  if new.status = 'dong' and old.status <> 'dong' then new.closed_at := now(); end if;
  return new;
end $$;
drop policy if exists tk_upd on public.tickets;
create policy tk_upd on public.tickets for update to authenticated using (assignee_id = auth.uid() or app.is_admin() or reporter_id = auth.uid() or (type = 'claim_hoa_hong' and app.has_role('ke_toan')));

insert into public.lookups(category, code, label, sort) values
 ('claim_type','claim_hang','Claim hàng hóa (thiếu / hỏng / sai)',1),('claim_type','claim_giao_hang','Claim thời gian giao hàng',2),
 ('claim_type','claim_hoa_hong','Claim hoa hồng / thu nhập',3),('claim_type','hoi_dap','Hỏi đáp quy trình / chính sách',4),
 ('claim_type','de_xuat','Đề xuất cải tiến',5),('claim_type','loi_he_thong','Báo lỗi hệ thống',6),('claim_type','khac','Khác',9)
on conflict do nothing;

-- Ảnh đính kèm (claim, hỗ trợ): thư mục {uid}/...
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', false, 5242880, array['image/jpeg','image/png','image/webp','image/gif']) on conflict (id) do nothing;
drop policy if exists att_ins on storage.objects;
drop policy if exists att_read on storage.objects;
create policy att_ins on storage.objects for insert to authenticated with check (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text);
create policy att_read on storage.objects for select to authenticated using (bucket_id = 'attachments' and app.is_active());

-- ---------- Khách hàng: đếm theo giai đoạn, trùng khách đang chạy ----------
create or replace function public.customer_stage_counts(p_owner uuid default null)
returns table(stage text, n bigint) language sql stable security definer set search_path = public, app as $$
  select c.stage, count(*) from public.customers c
  where c.deleted_at is null and (app.is_admin() or app.in_tree(c.owner_id)) and (p_owner is null or c.owner_id = p_owner)
    and (app.is_admin() or app.has_role('tn_kd','tp_kd') or c.owner_id = auth.uid() or p_owner is not null)
  group by c.stage
$$;

create or replace function public.company_conflicts()
returns table(customer_id uuid, code text, customer text, owner_name text, company_name text, company_owner text, last_order_date date, status text)
language sql stable security definer set search_path = public, app as $$
  select c.id, c.code, coalesce(c.company_name, c.contact_name), app.name_of(c.owner_id), l.name, l.owner_text, l.last_order_date, l.status
  from public.customers c cross join lateral app.company_lock(c.phone_norm, c.zalo_norm, c.tax_code) l
  where c.deleted_at is null and (app.is_admin() or app.in_tree(c.owner_id)) and l.status is not null
$$;

-- Chuyên cần: tham số trừ điểm
update public.settings set value = value || '{"chuyen_can":{"start":100,"khong_phep":20,"bao_gap":5,"quen_cham":3,"moi_10_phut_vuot":1}}'::jsonb
 where key = 'attendance' and not (value ? 'chuyen_can');
update public.settings set value = value || '{"annual_days":12}'::jsonb where key = 'leave' and not (value ? 'annual_days');

grant execute on all functions in schema public to authenticated;
revoke execute on all functions in schema public from anon;

drop policy if exists lv_ins on public.leave_requests;
create policy lv_ins on public.leave_requests for insert to authenticated with check (profile_id = auth.uid() or app.has_role('admin','bgd','hcns') or app.can_approve(profile_id));

-- Sổ phép tính theo leave_entitlements: bỏ job cộng phép/hủy phép theo sổ cái
do $$ begin perform cron.unschedule('nt_leave_accrue'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('nt_leave_expire'); exception when others then null; end $$;
