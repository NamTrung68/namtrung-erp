-- =====================================================================
-- ERP Nam Trung · 0003 HRM: chấm công selfie + IP, đơn công, nghỉ phép,
-- sổ phép, kỳ lương, phiếu lương, file đơn hoàn thành, hoa hồng
-- =====================================================================

create table public.holidays(
  day date primary key,
  name text not null,
  paid boolean not null default true
);

-- ---------- Chấm công ----------
create table public.attendance_events(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) default auth.uid(),
  kind text not null check (kind in ('in','out')),
  at timestamptz not null default now(),
  work_date date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  ip text,
  ip_ok boolean not null default false,
  selfie_path text,
  note text,
  status text not null default 'valid' check (status in ('valid','flagged','rejected')),
  hold boolean not null default false,            -- giữ ảnh, không xóa tự động
  purged_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index on public.attendance_events(profile_id, work_date);
create index on public.attendance_events(at) where purged_at is null;

create or replace function app.client_ip() returns text language sql stable as $$
  select btrim(split_part(coalesce(
    nullif(current_setting('request.headers', true), '')::json->>'cf-connecting-ip',
    nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for',
    nullif(current_setting('request.headers', true), '')::json->>'x-real-ip', ''), ',', 1))
$$;

create or replace function app.ip_allowed(p_ip text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := coalesce(app.setting('attendance')->'ip_whitelist', '[]'); x text;
begin
  if p_ip is null or p_ip = '' then return false; end if;
  for x in select jsonb_array_elements_text(v) loop
    begin
      if p_ip::inet <<= x::inet then return true; end if;
    exception when others then
      if p_ip = x then return true; end if;
    end;
  end loop;
  return false;
end $$;

create or replace function public.my_ip() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ip', app.client_ip(), 'ok', app.ip_allowed(app.client_ip()))
$$;

create or replace function public.attendance_check(p_kind text, p_selfie_path text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare v_ip text := app.client_ip(); v_ok boolean; v_id uuid; v_status text := 'valid'; v_cfg jsonb := coalesce(app.setting('attendance'),'{}');
        v_req boolean := coalesce((v_cfg->>'require_selfie')::boolean, true);
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  if p_kind not in ('in','out') then raise exception 'Loại chấm công không hợp lệ'; end if;
  if v_req and coalesce(p_selfie_path,'') = '' then raise exception 'Cần ảnh selfie'; end if;
  if p_selfie_path is not null and split_part(p_selfie_path, '/', 1) <> auth.uid()::text then
    raise exception 'Đường dẫn ảnh không hợp lệ';
  end if;
  if v_req and (select selfie_consent_at from public.profile_private where profile_id = auth.uid()) is null then
    raise exception 'Bạn cần đồng ý điều khoản lưu ảnh chấm công trước';
  end if;
  v_ok := app.ip_allowed(v_ip);
  if not v_ok and jsonb_array_length(coalesce(v_cfg->'ip_whitelist','[]')) > 0 then
    v_status := 'flagged';
  end if;
  insert into public.attendance_events(kind, ip, ip_ok, selfie_path, note, status)
  values (p_kind, v_ip, v_ok, p_selfie_path, p_note, v_status) returning id into v_id;
  if v_status = 'flagged' then
    perform app.notify_approvers(auth.uid(), 'attendance', '⚠️ ' || app.name_of(auth.uid()) || ' chấm công ngoài mạng công ty', 'IP ' || v_ip, '#/hr/attendance');
    perform app.telegram('attendance_flag', '⚠️ <b>Chấm công ngoài IP công ty</b>' || E'\n' || app.esc(app.name_of(auth.uid())) || ' · ' ||
      case p_kind when 'in' then 'vào' else 'ra' end || ' ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM') || ' · IP ' || coalesce(v_ip,'?'));
  end if;
  return jsonb_build_object('id', v_id, 'status', v_status, 'ip', v_ip, 'ip_ok', v_ok,
    'at', to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI:SS DD/MM/YYYY'));
end $$;

create or replace function public.selfie_consent() returns void
language sql security definer set search_path = public as $$
  insert into public.profile_private(profile_id, selfie_consent_at) values (auth.uid(), now())
  on conflict (profile_id) do update set selfie_consent_at = coalesce(public.profile_private.selfie_consent_at, now())
$$;

-- ---------- Đơn công: công tác, xác nhận công, xin đi muộn/về sớm ----------
create table public.attendance_requests(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) default auth.uid(),
  kind text not null check (kind in ('cong_tac','xac_nhan_cong','xin_muon_som')),
  work_date date not null,
  part text not null default 'full' check (part in ('full','am','pm')),
  minutes int,
  reason text not null check (length(btrim(reason)) >= 5),
  status text not null default 'cho_duyet' check (status in ('cho_duyet','da_duyet','tu_choi','huy')),
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz not null default now()
);

create or replace function app.att_req_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare n int; lim int := coalesce(app.setting_num('attendance','forgot_limit'), 3)::int;
begin
  new.profile_id := coalesce(auth.uid(), new.profile_id);
  if new.kind = 'xac_nhan_cong' then
    if new.work_date < app.vn_today() - 1 then raise exception 'Đơn xác nhận công phải gửi trong 24 giờ'; end if;
    select count(*) into n from public.attendance_requests
     where profile_id = new.profile_id and kind = 'xac_nhan_cong' and status <> 'huy' and status <> 'tu_choi'
       and date_trunc('month', work_date) = date_trunc('month', new.work_date);
    if n >= lim then raise exception 'Đã dùng hết % lần xác nhận công trong tháng', lim; end if;
  end if;
  return new;
end $$;
create trigger att_req_before before insert on public.attendance_requests for each row execute function app.att_req_before();

create or replace function app.att_req_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare lbl text := case new.kind when 'cong_tac' then 'Đơn công tác' when 'xac_nhan_cong' then 'Xác nhận công' else 'Xin đi muộn/về sớm' end;
begin
  if tg_op = 'INSERT' then
    perform app.notify_approvers(new.profile_id, 'approval', lbl || ': ' || app.name_of(new.profile_id), to_char(new.work_date,'DD/MM') || ' · ' || new.reason, '#/hr/approvals');
    perform app.telegram('leave_request', '📝 <b>' || lbl || '</b> · ' || app.esc(app.name_of(new.profile_id)) || ' · ' || to_char(new.work_date, 'DD/MM/YYYY'));
  elsif new.status is distinct from old.status and new.status in ('da_duyet','tu_choi') then
    perform app.notify(new.profile_id, 'approval', lbl || (case new.status when 'da_duyet' then ' đã được duyệt' else ' bị từ chối' end), new.decision_note, '#/hr/attendance');
  end if;
  return new;
end $$;
create trigger att_req_after after insert or update on public.attendance_requests for each row execute function app.att_req_after();

-- ---------- Nghỉ phép ----------
create table public.leave_requests(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) default auth.uid(),
  leave_type text not null,
  start_date date not null,
  end_date date not null,
  part text not null default 'full' check (part in ('full','am','pm')),
  days numeric(6,2) not null default 0,
  reason text,
  status text not null default 'cho_duyet' check (status in ('cho_duyet','da_duyet','tu_choi','huy')),
  decided_by uuid references public.profiles(id),
  decided_at timestamptz,
  decision_note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (end_date >= start_date),
  check (part = 'full' or start_date = end_date)
);
create index on public.leave_requests(profile_id, start_date);

create table public.leave_ledger(
  id bigint generated always as identity primary key,
  profile_id uuid not null references public.profiles(id),
  entry_date date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  kind text not null check (kind in ('accrue','use','expire','adjust','opening')),
  days numeric(6,2) not null,
  ref_id uuid,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);
create index on public.leave_ledger(profile_id, entry_date);

-- Giá trị công của 1 ngày theo lịch
create or replace function app.day_value(p_schedule text, p_day date) returns numeric
language sql stable security definer set search_path = public, app as $$
  select case
    when p_schedule = 'office' then case extract(isodow from p_day) when 7 then 0 when 6 then coalesce(app.setting_num('attendance','saturday_value'), 0.5) else 1 end
    when p_schedule in ('warehouse','none') then case extract(isodow from p_day) when 7 then 0 else 1 end
    else 0 end
$$;

create or replace function app.leave_days(p_profile uuid, p_start date, p_end date, p_part text) returns numeric
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(case when p_part = 'full' then v else least(v, 0.5) end), 0)
  from (select app.day_value(coalesce((select work_schedule from public.profiles where id = p_profile),'office'), d::date) v, d::date dd
        from generate_series(p_start, p_end, interval '1 day') d) x
  where not exists (select 1 from public.holidays h where h.day = x.dd)
$$;

create or replace function public.leave_balance(p_profile uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare v_id uuid := coalesce(p_profile, auth.uid()); v_bal numeric; v_pending numeric;
begin
  if not (v_id = auth.uid() or app.can_see_hr() or app.in_tree(v_id)) then raise exception 'Không có quyền'; end if;
  select coalesce(sum(days),0) into v_bal from public.leave_ledger where profile_id = v_id;
  select coalesce(sum(days),0) into v_pending from public.leave_requests where profile_id = v_id and leave_type = 'phep_nam' and status = 'cho_duyet';
  return jsonb_build_object('balance', v_bal, 'pending', v_pending, 'available', v_bal - v_pending,
    'used_year', (select coalesce(-sum(days),0) from public.leave_ledger where profile_id = v_id and kind='use' and extract(year from entry_date) = extract(year from app.vn_today())));
end $$;

create or replace function app.leave_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_avail numeric;
begin
  if tg_op = 'INSERT' then
    if new.profile_id is null or not app.has_role('admin','bgd','hcns') then new.profile_id := auth.uid(); end if;
    if new.start_date < app.vn_today() and not app.has_role('admin','bgd','hcns') then
      raise exception 'Đơn nghỉ phải gửi trước ngày nghỉ (nghỉ đột xuất: báo HCNS tạo hộ)';
    end if;
    new.days := app.leave_days(new.profile_id, new.start_date, new.end_date, new.part);
    if new.days <= 0 then raise exception 'Khoảng ngày nghỉ không có ngày làm việc'; end if;
    if new.leave_type = 'phep_nam' then
      v_avail := (public.leave_balance(new.profile_id)->>'available')::numeric;
      if v_avail < new.days then
        raise exception 'Phép năm còn % ngày, không đủ cho % ngày. Chọn "Nghỉ không lương" cho phần thiếu.', v_avail, new.days;
      end if;
    end if;
    if exists(select 1 from public.leave_requests l where l.profile_id = new.profile_id and l.status in ('cho_duyet','da_duyet')
               and daterange(l.start_date, l.end_date, '[]') && daterange(new.start_date, new.end_date, '[]')
               and (l.part = 'full' or new.part = 'full' or l.part = new.part)) then
      raise exception 'Trùng với đơn nghỉ khác';
    end if;
  end if;
  return new;
end $$;
create trigger leave_before before insert on public.leave_requests for each row execute function app.leave_before();

create or replace function app.leave_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare lbl text := (select label from public.lookups where category='leave_type' and code = new.leave_type);
begin
  if tg_op = 'INSERT' then
    perform app.notify_approvers(new.profile_id, 'approval', 'Đơn nghỉ: ' || app.name_of(new.profile_id),
      to_char(new.start_date,'DD/MM') || case when new.end_date > new.start_date then '–' || to_char(new.end_date,'DD/MM') else '' end || ' · ' || new.days || ' ngày', '#/hr/approvals');
    perform app.telegram('leave_request', '🏖 <b>Đơn nghỉ</b> · ' || app.esc(app.name_of(new.profile_id)) || E'\n' || app.esc(coalesce(lbl, new.leave_type)) || ': '
      || to_char(new.start_date,'DD/MM') || case when new.end_date > new.start_date then '–' || to_char(new.end_date,'DD/MM') else '' end
      || case new.part when 'am' then ' (sáng)' when 'pm' then ' (chiều)' else '' end || ' · ' || new.days || ' ngày');
  elsif new.status is distinct from old.status then
    if new.status = 'da_duyet' and new.leave_type = 'phep_nam' then
      insert into public.leave_ledger(profile_id, entry_date, kind, days, ref_id, note) values (new.profile_id, new.start_date, 'use', -new.days, new.id, 'Đơn nghỉ phép năm');
    elsif old.status = 'da_duyet' and new.status = 'huy' and new.leave_type = 'phep_nam' then
      insert into public.leave_ledger(profile_id, entry_date, kind, days, ref_id, note) values (new.profile_id, new.start_date, 'adjust', new.days, new.id, 'Hoàn phép do hủy đơn');
    end if;
    if new.status in ('da_duyet','tu_choi') then
      perform app.notify(new.profile_id, 'approval', 'Đơn nghỉ ' || to_char(new.start_date,'DD/MM') || case new.status when 'da_duyet' then ' đã được duyệt' else ' bị từ chối' end, new.decision_note, '#/hr/leave');
    end if;
  end if;
  return new;
end $$;
create trigger leave_after after insert or update on public.leave_requests for each row execute function app.leave_after();
create trigger audit_leave after insert or update on public.leave_requests for each row execute function app.audit();

-- Duyệt chung cho đơn nghỉ và đơn công
create or replace function public.decide_request(p_table text, p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_owner uuid; v_status text; v_lock boolean;
begin
  if p_table = 'leave' then
    select profile_id, status into v_owner, v_status from public.leave_requests where id = p_id for update;
  elsif p_table = 'attendance' then
    select profile_id, status into v_owner, v_status from public.attendance_requests where id = p_id for update;
  else raise exception 'Loại đơn không hợp lệ'; end if;
  if v_owner is null then raise exception 'Không tìm thấy đơn'; end if;
  if v_status <> 'cho_duyet' then raise exception 'Đơn đã được xử lý'; end if;
  if not (app.can_approve(v_owner) or (app.has_role('hcns') and v_owner <> auth.uid())) then raise exception 'Bạn không có quyền duyệt đơn này'; end if;
  if not p_approve and coalesce(btrim(p_note),'') = '' then raise exception 'Từ chối phải ghi lý do'; end if;
  if p_table = 'leave' then
    update public.leave_requests set status = case when p_approve then 'da_duyet' else 'tu_choi' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  else
    update public.attendance_requests set status = case when p_approve then 'da_duyet' else 'tu_choi' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  end if;
  perform app.log(case when p_approve then 'APPROVE' else 'REJECT' end, p_table || '_requests', p_id::text, jsonb_build_object('note', p_note));
end $$;

create or replace function public.cancel_request(p_table text, p_id uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_owner uuid; v_status text; v_start date;
begin
  if p_table = 'leave' then
    select profile_id, status, start_date into v_owner, v_status, v_start from public.leave_requests where id = p_id for update;
  else
    select profile_id, status, work_date into v_owner, v_status, v_start from public.attendance_requests where id = p_id for update;
  end if;
  if v_owner is null then raise exception 'Không tìm thấy đơn'; end if;
  if not (v_owner = auth.uid() or app.has_role('admin','bgd','hcns')) then raise exception 'Không có quyền'; end if;
  if v_status not in ('cho_duyet','da_duyet') then raise exception 'Đơn không hủy được'; end if;
  if v_status = 'da_duyet' and v_start <= app.vn_today() and not app.has_role('admin','bgd','hcns') then raise exception 'Đơn đã tới ngày, liên hệ HCNS để hủy'; end if;
  if p_table = 'leave' then update public.leave_requests set status = 'huy' where id = p_id;
  else update public.attendance_requests set status = 'huy' where id = p_id; end if;
end $$;

-- Bảng ai nghỉ: không lộ lý do, loại nghỉ
create or replace function public.leave_board(p_from date, p_to date)
returns table(full_name text, start_date date, end_date date, part text, days numeric, status text)
language sql stable security definer set search_path = public, app as $$
  select p.full_name, l.start_date, l.end_date, l.part, l.days, l.status
  from public.leave_requests l join public.profiles p on p.id = l.profile_id
  where app.is_active() and l.status in ('cho_duyet','da_duyet') and l.start_date <= p_to and l.end_date >= p_from
  order by l.start_date, p.full_name
$$;

-- ---------- Kỳ lương ----------
create table public.payroll_periods(
  id uuid primary key default gen_random_uuid(),
  month date not null unique check (extract(day from month) = 1),
  status text not null default 'open' check (status in ('open','review','approval','closed')),
  note text,
  computed_at timestamptz,
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  created_at timestamptz default now()
);

create table public.order_results(
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.payroll_periods(id) on delete cascade,
  ext_order_code text not null,
  sale_name text,
  profile_id uuid references public.profiles(id),
  customer_ext text,
  warehouse text,
  order_type text,
  completed_at date,
  goods_value numeric(18,0) default 0,
  order_profit numeric(18,0) not null default 0,
  raw jsonb,
  imported_by uuid default auth.uid(),
  imported_at timestamptz default now(),
  unique (period_id, ext_order_code)
);
create index on public.order_results(profile_id);

create table public.payslips(
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.payroll_periods(id) on delete cascade,
  profile_id uuid not null references public.profiles(id),
  status text not null default 'draft' check (status in ('draft','sent','confirmed','disputed','closed')),
  standard_days numeric(6,2) not null default 0,
  paid_days numeric(6,2) not null default 0,
  worked_days numeric(6,2) not null default 0,
  paid_leave_days numeric(6,2) not null default 0,
  unpaid_days numeric(6,2) not null default 0,
  late_minutes int not null default 0,
  flex_over_minutes int not null default 0,
  base_salary numeric(18,0) not null default 0,
  salary_by_days numeric(18,0) not null default 0,
  allowance numeric(18,0) not null default 0,
  profit_total numeric(18,0) not null default 0,
  commission_base numeric(18,0) not null default 0,
  commission numeric(18,0) not null default 0,
  loss_offset numeric(18,0) not null default 0,
  carry_loss numeric(18,0) not null default 0,
  team_bonus numeric(18,0) not null default 0,
  flex_deduction numeric(18,0) not null default 0,
  insurance numeric(18,0) not null default 0,
  adjustments numeric(18,0) not null default 0,
  net numeric(18,0) not null default 0,
  details jsonb not null default '{}',
  confirmed_at timestamptz,
  dispute_note text,
  updated_at timestamptz default now(),
  unique (period_id, profile_id)
);

create table public.payslip_adjustments(
  id uuid primary key default gen_random_uuid(),
  payslip_id uuid not null references public.payslips(id) on delete cascade,
  label text not null,
  amount numeric(18,0) not null,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);
create trigger audit_payslips after update on public.payslips for each row execute function app.audit();
create trigger audit_adj after insert or update or delete on public.payslip_adjustments for each row execute function app.audit();
create trigger audit_orders after insert or delete on public.order_results for each row execute function app.audit();

create or replace function public.payroll_open(p_month date)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v uuid;
begin
  if not app.has_role('admin','bgd','hcns','ke_toan') then raise exception 'Không có quyền'; end if;
  insert into public.payroll_periods(month) values (date_trunc('month', p_month)::date)
  on conflict (month) do update set month = excluded.month returning id into v;
  return v;
end $$;

-- Nhập file đơn hoàn thành (kế toán)
create or replace function public.import_order_results(p_period uuid, p_rows jsonb, p_replace boolean default true)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_pid uuid; n int := 0; unmapped text[] := '{}'; st text;
begin
  if not app.has_role('admin','bgd','ke_toan') then raise exception 'Chỉ Kế toán/BGĐ được nhập file đơn'; end if;
  select status into st from public.payroll_periods where id = p_period;
  if st is null then raise exception 'Kỳ lương không tồn tại'; end if;
  if st = 'closed' then raise exception 'Kỳ lương đã chốt'; end if;
  if p_replace then delete from public.order_results where period_id = p_period; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(r->>'ext_order_code'),'') = '' then continue; end if;
    select id into v_pid from public.profiles p
     where lower(btrim(r->>'sale_name')) = any(select lower(btrim(x)) from unnest(p.sale_aliases || p.full_name || p.employee_code) x)
     limit 1;
    if v_pid is null and coalesce(r->>'sale_name','') <> '' then unmapped := unmapped || (r->>'sale_name'); end if;
    insert into public.order_results(period_id, ext_order_code, sale_name, profile_id, customer_ext, warehouse, order_type, completed_at, goods_value, order_profit, raw)
    values (p_period, btrim(r->>'ext_order_code'), r->>'sale_name', v_pid, r->>'customer_ext', r->>'warehouse', r->>'order_type',
            (r->>'completed_at')::date, coalesce((r->>'goods_value')::numeric,0), coalesce((r->>'order_profit')::numeric,0), r->'raw')
    on conflict (period_id, ext_order_code) do update set sale_name = excluded.sale_name, profile_id = excluded.profile_id,
       completed_at = excluded.completed_at, goods_value = excluded.goods_value, order_profit = excluded.order_profit, raw = excluded.raw;
    n := n + 1;
  end loop;
  return jsonb_build_object('imported', n, 'unmapped', (select coalesce(jsonb_agg(distinct x), '[]') from unnest(unmapped) x));
end $$;

-- Hoa hồng lũy tiến: tỷ lệ cơ bản theo cấp + 0/3/5/7 điểm % cho các bậc 0–30, 30–65, 65–100, >100 triệu
create or replace function app.tiered_commission(p_base numeric, p_pct numeric)
returns numeric language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('payroll')->'tiers', '[[0,0],[30000000,3],[65000000,5],[100000000,7]]'::jsonb);
        i int; lo numeric; hi numeric; addp numeric; tot numeric := 0;
begin
  if p_base <= 0 then return 0; end if;
  for i in 0 .. jsonb_array_length(cfg) - 1 loop
    lo := (cfg->i->>0)::numeric; addp := (cfg->i->>1)::numeric;
    hi := case when i < jsonb_array_length(cfg) - 1 then (cfg->(i+1)->>0)::numeric else null end;
    if p_base > lo then
      tot := tot + (least(p_base, coalesce(hi, p_base)) - lo) * (p_pct + addp) / 100;
    end if;
  end loop;
  return round(tot);
end $$;

-- Tính lương 1 kỳ
create or replace function public.payroll_compute(p_period uuid)
returns int language plpgsql security definer set search_path = public, app as $$
declare
  per record; p record; cfg jsonb := coalesce(app.setting('attendance'),'{}'); pcfg jsonb := coalesce(app.setting('payroll'),'{}');
  m_start date; m_end date; d date; dv numeric; lv numeric; lpart text; attended boolean; first_in timestamptz; last_out timestamptz;
  std numeric; paid numeric; worked numeric; pleave numeric; unpaid numeric; late int; over int;
  t_start time := coalesce((cfg->>'start')::time, '08:00'); t_end time := coalesce((cfg->>'end')::time, '17:30');
  t_sat_end time := coalesce((cfg->>'saturday_end')::time, '12:00');
  t_lunch_s time := coalesce((cfg->>'lunch_start')::time, '12:00'); t_lunch_e time := coalesce((cfg->>'lunch_end')::time, '13:30');
  flex_min int := coalesce((cfg->>'flex_minutes')::int, 100); flex_from date := coalesce((cfg->>'flex_start')::date, '2026-11-01');
  base_pct numeric := coalesce((pcfg->>'commission_base_pct')::numeric, 60);
  priv record; lvl record; pos numeric; loss numeric; carry_in numeric; com numeric; off numeric; team numeric; adj numeric;
  sal numeric; flexded numeric; n int := 0; s_start time; s_end time; detail jsonb;
begin
  if not app.has_role('admin','bgd','hcns','ke_toan') then raise exception 'Không có quyền tính lương'; end if;
  select * into per from public.payroll_periods where id = p_period for update;
  if per.id is null then raise exception 'Kỳ lương không tồn tại'; end if;
  if per.status not in ('open','review') then raise exception 'Kỳ lương đang chờ duyệt hoặc đã chốt'; end if;
  m_start := per.month; m_end := (per.month + interval '1 month - 1 day')::date;

  for p in select * from public.profiles where status = 'active' and roles && array['admin','bgd','hcns','ke_toan','tp_kd','tn_kd','sale','nhan_vien'] loop
    std := 0; paid := 0; worked := 0; pleave := 0; unpaid := 0; late := 0;
    for d in select x::date from generate_series(m_start, m_end, interval '1 day') x loop
      dv := app.day_value(p.work_schedule, d);
      if dv = 0 then continue; end if;
      std := std + dv;
      if exists(select 1 from public.holidays h where h.day = d and h.paid) then paid := paid + dv; continue; end if;
      if p.hire_date is not null and d < p.hire_date then std := std - dv; continue; end if;
      -- nghỉ phép đã duyệt
      select coalesce(sum(case when l.part='full' then dv else least(dv,0.5) end),0), max(l.part)
        into lv, lpart
        from public.leave_requests l
        where l.profile_id = p.id and l.status = 'da_duyet' and d between l.start_date and l.end_date;
      lv := least(lv, dv);
      pleave := pleave + coalesce((select sum(case when lt.extra->>'paid' = 'true' then (case when l.part='full' then dv else least(dv,0.5) end) else 0 end)
                         from public.leave_requests l left join public.lookups lt on lt.category='leave_type' and lt.code = l.leave_type
                         where l.profile_id = p.id and l.status = 'da_duyet' and d between l.start_date and l.end_date), 0);
      if p.work_schedule in ('warehouse','none') then
        attended := true;
      else
        select min(at) filter (where kind='in'), max(at) filter (where kind='out') into first_in, last_out
          from public.attendance_events where profile_id = p.id and work_date = d and status <> 'rejected';
        attended := first_in is not null or exists(select 1 from public.attendance_requests r where r.profile_id = p.id and r.work_date = d
                                                   and r.status = 'da_duyet' and r.kind in ('cong_tac','xac_nhan_cong'));
        if first_in is not null and lv < dv then
          s_start := case when lpart = 'am' then t_lunch_e else t_start end;
          s_end := case when extract(isodow from d) = 6 then t_sat_end when lpart = 'pm' then t_lunch_s else t_end end;
          late := late + greatest(0, floor(extract(epoch from ((first_in at time zone 'Asia/Ho_Chi_Minh')::time - s_start)) / 60))::int;
          if last_out is not null then
            late := late + greatest(0, floor(extract(epoch from (s_end - (last_out at time zone 'Asia/Ho_Chi_Minh')::time)) / 60))::int;
          end if;
        end if;
      end if;
      if attended then worked := worked + (dv - lv); else unpaid := unpaid + (dv - lv); end if;
    end loop;
    paid := paid + worked + pleave;

    select * into priv from public.profile_private where profile_id = p.id;
    select * into lvl from public.job_levels where code = p.job_level;
    sal := case when std > 0 then round(coalesce(priv.base_salary,0) * least(paid, std) / std) else 0 end;
    over := case when m_start >= flex_from then greatest(0, late - flex_min) else 0 end;
    flexded := case when std > 0 then round(coalesce(priv.base_salary,0) / std / 8 / 60 * over) else 0 end;

    -- Hoa hồng
    select coalesce(sum(round(order_profit * base_pct / 100)) filter (where order_profit > 0), 0),
           coalesce(-sum(round(order_profit * base_pct / 100)) filter (where order_profit < 0), 0)
      into pos, loss from public.order_results where period_id = p_period and profile_id = p.id;
    select coalesce(ps.carry_loss, 0) into carry_in from public.payslips ps join public.payroll_periods pp on pp.id = ps.period_id
      where ps.profile_id = p.id and pp.month = (m_start - interval '1 month')::date;
    carry_in := coalesce(carry_in, 0);
    com := app.tiered_commission(pos, coalesce(lvl.commission_pct, 0));
    off := least(loss + carry_in, round(com * 0.5));
    -- Thưởng quản lý đội: % LN tính thưởng của cấp dưới (trừ đơn của chính mình)
    team := 0;
    if coalesce(lvl.team_bonus_pct, 0) > 0 then
      with recursive t as (select id from public.profiles where manager_id = p.id
                           union select x.id from public.profiles x join t on x.manager_id = t.id)
      select coalesce(round(sum(round(o.order_profit * base_pct / 100)) * lvl.team_bonus_pct / 100), 0) into team
        from public.order_results o where o.period_id = p_period and o.profile_id in (select id from t);
      team := greatest(team, 0);
    end if;
    select coalesce(sum(a.amount),0) into adj from public.payslip_adjustments a join public.payslips ps on ps.id = a.payslip_id
      where ps.period_id = p_period and ps.profile_id = p.id;

    detail := jsonb_build_object('late_minutes', late, 'flex_minutes', flex_min, 'flex_active', m_start >= flex_from,
      'commission_pct', coalesce(lvl.commission_pct,0), 'commission_base_pct', base_pct, 'loss_this_month', loss, 'carry_in', carry_in,
      'orders', (select count(*) from public.order_results where period_id = p_period and profile_id = p.id));

    insert into public.payslips as ps(period_id, profile_id, standard_days, paid_days, worked_days, paid_leave_days, unpaid_days, late_minutes,
      flex_over_minutes, base_salary, salary_by_days, allowance, profit_total, commission_base, commission, loss_offset, carry_loss, team_bonus,
      flex_deduction, insurance, adjustments, net, details, status, updated_at)
    values (p_period, p.id, std, least(paid, std), worked, pleave, unpaid, late, over, coalesce(priv.base_salary,0), sal, coalesce(priv.allowance,0),
      (select coalesce(sum(order_profit),0) from public.order_results where period_id = p_period and profile_id = p.id),
      pos, com, off, loss + carry_in - off, team, flexded, coalesce(priv.insurance_deduction,0), adj,
      sal + coalesce(priv.allowance,0) + com - off + team - flexded - coalesce(priv.insurance_deduction,0) + adj, detail, 'draft', now())
    on conflict (period_id, profile_id) do update set standard_days = excluded.standard_days, paid_days = excluded.paid_days,
      worked_days = excluded.worked_days, paid_leave_days = excluded.paid_leave_days, unpaid_days = excluded.unpaid_days,
      late_minutes = excluded.late_minutes, flex_over_minutes = excluded.flex_over_minutes, base_salary = excluded.base_salary,
      salary_by_days = excluded.salary_by_days, allowance = excluded.allowance, profit_total = excluded.profit_total,
      commission_base = excluded.commission_base, commission = excluded.commission, loss_offset = excluded.loss_offset,
      carry_loss = excluded.carry_loss, team_bonus = excluded.team_bonus, flex_deduction = excluded.flex_deduction,
      insurance = excluded.insurance, adjustments = excluded.adjustments, net = excluded.net, details = excluded.details,
      status = case when ps.status = 'closed' then 'closed' else 'draft' end, confirmed_at = null, updated_at = now()
    where ps.status <> 'closed';
    n := n + 1;
  end loop;
  update public.payroll_periods set computed_at = now(), status = 'open' where id = p_period;
  return n;
end $$;

create or replace function public.payroll_send_review(p_period uuid)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not app.has_role('admin','bgd','hcns','ke_toan') then raise exception 'Không có quyền'; end if;
  update public.payroll_periods set status = 'review' where id = p_period and status = 'open';
  if not found then raise exception 'Kỳ lương không ở trạng thái mở'; end if;
  update public.payslips set status = 'sent' where period_id = p_period and status = 'draft';
  perform app.notify(profile_id, 'payroll', 'Phiếu lương tháng ' || to_char((select month from public.payroll_periods where id = p_period), 'MM/YYYY') || ' đã có',
                     'Kiểm tra và xác nhận trong 3 ngày', '#/hr/payslip?id=' || id)
    from public.payslips where period_id = p_period;
end $$;

create or replace function public.payslip_respond(p_id uuid, p_agree boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare s record;
begin
  select * into s from public.payslips where id = p_id for update;
  if s.profile_id <> auth.uid() then raise exception 'Chỉ chính chủ xác nhận phiếu lương'; end if;
  if s.status not in ('sent','disputed','confirmed') then raise exception 'Phiếu lương chưa gửi hoặc đã chốt'; end if;
  if not p_agree and coalesce(btrim(p_note),'') = '' then raise exception 'Ghi rõ dòng chưa đúng'; end if;
  update public.payslips set status = case when p_agree then 'confirmed' else 'disputed' end,
    confirmed_at = case when p_agree then now() end, dispute_note = p_note where id = p_id;
  if not p_agree then
    perform app.notify_roles(array['hcns','ke_toan'], 'payroll', 'Khiếu nại phiếu lương: ' || app.name_of(s.profile_id), p_note, '#/hr/payroll');
  end if;
end $$;

create or replace function public.payroll_close(p_period uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare per record; tot numeric; cnt int;
begin
  if not app.is_admin() then raise exception 'Chỉ BGĐ/Admin chốt lương'; end if;
  select * into per from public.payroll_periods where id = p_period for update;
  if per.status not in ('review','approval') then raise exception 'Kỳ lương phải qua bước gửi nhân sự xác nhận'; end if;
  if exists(select 1 from public.payslips where period_id = p_period and status = 'disputed') then
    raise exception 'Còn phiếu lương đang khiếu nại';
  end if;
  update public.payslips set status = 'closed' where period_id = p_period;
  update public.payroll_periods set status = 'closed', closed_by = auth.uid(), closed_at = now() where id = p_period;
  select sum(net), count(*) into tot, cnt from public.payslips where period_id = p_period;
  perform public.kpi_close_month(per.month);
  perform app.telegram('payroll', '💰 <b>Đã chốt lương</b> tháng ' || to_char(per.month,'MM/YYYY') || E'\n' || cnt || ' phiếu · tổng thực lĩnh ' || to_char(tot, 'FM999G999G999G999') || 'đ');
end $$;

-- Không sửa phiếu lương đã chốt
create or replace function app.payslip_guard() returns trigger language plpgsql as $$
begin
  if old.status = 'closed' then raise exception 'Phiếu lương đã chốt, không sửa được. Tạo điều chỉnh ở kỳ sau.'; end if;
  return new;
end $$;
create trigger payslip_guard before update on public.payslips for each row execute function app.payslip_guard();
create or replace function app.adj_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select status from public.payslips where id = coalesce(new.payslip_id, old.payslip_id)) = 'closed' then
    raise exception 'Phiếu lương đã chốt';
  end if;
  return coalesce(new, old);
end $$;
create trigger adj_guard before insert or update or delete on public.payslip_adjustments for each row execute function app.adj_guard();

-- Ảnh selfie hết hạn (để dọn trên Storage)
create or replace function public.selfies_expired(p_limit int default 500)
returns table(id uuid, selfie_path text) language sql stable security definer set search_path = public, app as $$
  select e.id, e.selfie_path from public.attendance_events e
  where app.has_role('admin','bgd','hcns') and e.selfie_path is not null and e.purged_at is null and not e.hold
    and e.at < now() - make_interval(days => coalesce(app.setting_num('attendance','selfie_retention_days'), 60)::int)
  order by e.at limit p_limit
$$;
create or replace function public.selfies_mark_purged(p_ids uuid[])
returns int language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.has_role('admin','bgd','hcns') then raise exception 'Không có quyền'; end if;
  update public.attendance_events set purged_at = now() where id = any(p_ids) and purged_at is null;
  get diagnostics n = row_count;
  perform app.log('PURGE', 'attendance_events', null, jsonb_build_object('count', n));
  return n;
end $$;
