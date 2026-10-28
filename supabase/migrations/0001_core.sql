-- =====================================================================
-- ERP Nam Trung · 0001 Nền tảng: tổ chức, nhân sự, vai trò, cấu hình,
-- audit log, thông báo, Telegram
-- =====================================================================
create extension if not exists pgcrypto;
create schema if not exists app;
grant usage on schema app to anon, authenticated;

-- ---------- Cấu hình (không chứa secret) ----------
create table public.settings(
  key text primary key,
  value jsonb not null,
  description text,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create table public.settings_history(
  id bigint generated always as identity primary key,
  key text not null,
  old_value jsonb,
  new_value jsonb,
  changed_by uuid,
  changed_at timestamptz not null default now()
);
-- Secret (token Telegram...) – không ai SELECT trực tiếp được
create table app.secrets(
  key text primary key,
  value text,
  updated_at timestamptz default now(),
  updated_by uuid
);

create or replace function app.setting(p_key text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select value from public.settings where key = p_key
$$;
create or replace function app.setting_num(p_key text, p_path text) returns numeric
language sql stable security definer set search_path = public, app as $$
  select (value ->> p_path)::numeric from public.settings where key = p_key
$$;

-- ---------- Tổ chức ----------
create table public.org_units(
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.org_units(id),
  name text not null,
  kind text not null default 'phong' check (kind in ('cong_ty','khoi','phong','nhom')),
  sort int default 0,
  active boolean default true,
  created_at timestamptz default now()
);

create table public.job_levels(
  code text primary key,
  name text not null,
  rank int not null,
  base_salary numeric(18,0) not null default 0,
  commission_pct numeric(7,4) not null default 0,
  team_bonus_pct numeric(7,4) not null default 0,
  is_sales boolean not null default false
);

create table public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  employee_code text unique,
  full_name text not null default '',
  phone text,
  org_unit_id uuid references public.org_units(id),
  job_level text references public.job_levels(code),
  manager_id uuid references public.profiles(id),
  roles text[] not null default '{}',
  status text not null default 'active' check (status in ('active','inactive')),
  work_schedule text not null default 'office' check (work_schedule in ('office','warehouse','none')),
  hire_date date,
  is_new_hire boolean not null default false,
  sale_aliases text[] not null default '{}',   -- tên NV KD trong file Excel đơn hoàn thành
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint roles_valid check (roles <@ array['admin','bgd','hcns','ke_toan','tp_kd','tn_kd','sale','nhan_vien']::text[])
);
create index on public.profiles(manager_id);

-- Dữ liệu cá nhân nhạy cảm tách bảng
create table public.profile_private(
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  base_salary numeric(18,0),
  allowance numeric(18,0) default 0,
  insurance_deduction numeric(18,0) default 0,
  bank_bin text,
  bank_account text,
  bank_holder text,
  dob date,
  address text,
  selfie_consent_at timestamptz,
  updated_at timestamptz default now()
);

-- Lời mời: chỉ email có lời mời mới đăng ký được
create table public.invites(
  email text primary key,
  full_name text not null default '',
  roles text[] not null default '{nhan_vien}',
  job_level text references public.job_levels(code),
  manager_id uuid references public.profiles(id),
  org_unit_id uuid references public.org_units(id),
  work_schedule text not null default 'office',
  employee_code text,
  created_by uuid,
  created_at timestamptz default now(),
  used_at timestamptz
);

-- Ủy quyền duyệt
create table public.delegations(
  id uuid primary key default gen_random_uuid(),
  delegator_id uuid not null references public.profiles(id),
  delegate_id uuid not null references public.profiles(id),
  from_at timestamptz not null default now(),
  to_at timestamptz not null,
  reason text,
  revoked_at timestamptz,
  created_at timestamptz default now(),
  check (to_at > from_at and to_at <= from_at + interval '31 days'),
  check (delegator_id <> delegate_id)
);

-- ---------- Hàm quyền ----------
create or replace function app.uid() returns uuid language sql stable as $$ select auth.uid() $$;

create or replace function app.my_roles() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce((select roles from public.profiles where id = auth.uid() and status = 'active'), '{}')
$$;
create or replace function app.has_role(variadic p text[]) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.my_roles() && p
$$;
create or replace function app.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and status = 'active')
$$;
create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('admin','bgd')
$$;

-- Tập id: chính mình + mọi cấp dưới (theo manager_id), + cấp dưới của người đã ủy quyền cho mình
create or replace function app.my_tree() returns uuid[]
language sql stable security definer set search_path = public as $$
  with recursive roots as (
    select auth.uid() as id
    union
    select d.delegator_id from public.delegations d
     where d.delegate_id = auth.uid() and d.revoked_at is null and now() between d.from_at and d.to_at
  ), t as (
    select id from roots
    union
    select p.id from public.profiles p join t on p.manager_id = t.id
  )
  select coalesce(array_agg(distinct id), '{}') from t
$$;

create or replace function app.in_tree(p_id uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_id = any(app.my_tree())
$$;

-- Có quyền duyệt việc của p_id: là cấp trên (trực tiếp/gián tiếp, hoặc qua ủy quyền), không phải chính mình
create or replace function app.can_approve(p_id uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_id <> auth.uid() and (app.is_admin() or p_id = any(app.my_tree()))
$$;

create or replace function app.can_see_hr() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('admin','bgd','hcns','ke_toan')
$$;

-- ---------- Audit log ----------
create table public.audit_logs(
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor_id uuid,
  action text not null,
  table_name text,
  record_id text,
  diff jsonb
);
create index on public.audit_logs(table_name, record_id);
create index on public.audit_logs(at desc);

create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_old jsonb; v_new jsonb; v_diff jsonb; v_id text;
begin
  if tg_op = 'DELETE' then v_old := to_jsonb(old); v_id := v_old->>'id';
  elsif tg_op = 'INSERT' then v_new := to_jsonb(new); v_id := v_new->>'id';
  else
    v_old := to_jsonb(old); v_new := to_jsonb(new); v_id := v_new->>'id';
    select jsonb_object_agg(k, jsonb_build_array(v_old->k, v_new->k)) into v_diff
      from jsonb_object_keys(v_new) k
     where (v_old->k) is distinct from (v_new->k) and k not in ('updated_at');
    if v_diff is null then return new; end if;
  end if;
  insert into public.audit_logs(actor_id, action, table_name, record_id, diff)
  values (auth.uid(), tg_op, tg_table_name, coalesce(v_id, (coalesce(v_new,v_old)->>'key')),
          case tg_op when 'UPDATE' then v_diff when 'INSERT' then v_new else v_old end);
  return coalesce(new, old);
end $$;

create or replace function app.touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create or replace function app.log(p_action text, p_table text, p_id text, p_data jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs(actor_id, action, table_name, record_id, diff) values (auth.uid(), p_action, p_table, p_id, p_data)
$$;

-- ---------- Thông báo trong ứng dụng ----------
create table public.notifications(
  id bigint generated always as identity primary key,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  title text not null,
  body text,
  link text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on public.notifications(recipient_id, created_at desc);

-- ---------- Telegram ----------
create table public.telegram_outbox(
  id bigint generated always as identity primary key,
  event text not null,
  message text not null,
  request_id bigint,
  error text,
  created_at timestamptz default now()
);

create or replace function app.telegram(p_event text, p_text text)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_cfg jsonb := coalesce(app.setting('telegram'), '{}');
  v_token text; v_chat text; v_req bigint;
begin
  if coalesce((v_cfg->>'enabled')::boolean, false) is not true then return; end if;
  if v_cfg ? 'events' and not (v_cfg->'events') ? p_event then return; end if;
  select value into v_token from app.secrets where key = 'telegram_bot_token';
  v_chat := v_cfg->>'chat_id';
  if coalesce(v_token,'') = '' or coalesce(v_chat,'') = '' then return; end if;
  begin
    select net.http_post(
      url := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body := jsonb_build_object('chat_id', v_chat, 'text', left(p_text, 3900), 'parse_mode', 'HTML', 'disable_web_page_preview', true),
      headers := '{"Content-Type":"application/json"}'::jsonb
    ) into v_req;
    insert into public.telegram_outbox(event, message, request_id) values (p_event, p_text, v_req);
  exception when others then
    insert into public.telegram_outbox(event, message, error) values (p_event, p_text, sqlerrm);
  end;
end $$;

create or replace function app.esc(t text) returns text language sql immutable as $$
  select replace(replace(replace(coalesce(t,''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

-- Gửi thông báo cho 1 người
create or replace function app.notify(p_to uuid, p_kind text, p_title text, p_body text default null, p_link text default null)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications(recipient_id, kind, title, body, link)
  select p_to, p_kind, p_title, p_body, p_link where p_to is not null
$$;

-- Gửi cho mọi người có 1 trong các vai trò
create or replace function app.notify_roles(p_roles text[], p_kind text, p_title text, p_body text default null, p_link text default null)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications(recipient_id, kind, title, body, link)
  select id, p_kind, p_title, p_body, p_link from public.profiles where status='active' and roles && p_roles
$$;

-- Người duyệt mặc định = quản lý trực tiếp, nếu không có thì admin/bgd
create or replace function app.approver_of(p_id uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select array[manager_id] from public.profiles where id = p_id and manager_id is not null),
    (select array_agg(id) from public.profiles where status='active' and roles && array['admin','bgd'])
  ) || coalesce((select array_agg(d.delegate_id) from public.delegations d
                   where d.revoked_at is null and now() between d.from_at and d.to_at
                     and d.delegator_id = (select manager_id from public.profiles where id = p_id)), '{}')
$$;

create or replace function app.notify_approvers(p_id uuid, p_kind text, p_title text, p_body text default null, p_link text default null)
returns void language sql security definer set search_path = public, app as $$
  select app.notify(x, p_kind, p_title, p_body, p_link) from unnest(app.approver_of(p_id)) x
$$;

create or replace function app.name_of(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(full_name,''), email) from public.profiles where id = p_id
$$;

-- ---------- Đăng ký: chỉ email có lời mời ----------
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_inv public.invites%rowtype;
begin
  select * into v_inv from public.invites where lower(email) = lower(new.email);
  if not found then
    raise exception 'Email % chưa được mời vào hệ thống. Liên hệ quản trị.', new.email;
  end if;
  insert into public.profiles(id, email, full_name, roles, job_level, manager_id, org_unit_id, work_schedule, employee_code, hire_date)
  values (new.id, lower(new.email), coalesce(nullif(v_inv.full_name,''), split_part(new.email,'@',1)), v_inv.roles,
          v_inv.job_level, v_inv.manager_id, v_inv.org_unit_id, v_inv.work_schedule,
          coalesce(v_inv.employee_code, 'NV' || lpad(nextval('public.employee_code_seq')::text, 4, '0')), current_date);
  insert into public.profile_private(profile_id, base_salary)
  values (new.id, (select base_salary from public.job_levels where code = v_inv.job_level));
  update public.invites set used_at = now() where email = v_inv.email;
  return new;
end $$;
create sequence public.employee_code_seq;
create trigger on_auth_user_created after insert on auth.users for each row execute function app.handle_new_user();

-- ---------- Danh mục chung (thay sheet CAU_HINH) ----------
create table public.lookups(
  category text not null,
  code text not null,
  label text not null,
  sort int not null default 0,
  extra jsonb,
  active boolean not null default true,
  primary key (category, code)
);

-- ---------- Tỷ giá ----------
create table public.exchange_rates(
  id uuid primary key default gen_random_uuid(),
  rate_type text not null check (rate_type in ('ban','san','von')),
  rate numeric(12,2) not null check (rate > 0),
  effective_from timestamptz not null default now(),
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);
create or replace function app.current_rate(p_type text) returns numeric
language sql stable security definer set search_path = public as $$
  select rate from public.exchange_rates where rate_type = p_type and effective_from <= now()
  order by effective_from desc limit 1
$$;

-- ---------- RPC cấu hình ----------
create or replace function public.set_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_old jsonb;
begin
  if not (app.is_admin() or (app.has_role('hcns') and p_key in ('attendance','leave','payroll'))
          or (app.has_role('ke_toan') and p_key in ('vietqr','payroll','quote_defaults'))) then
    raise exception 'Không có quyền sửa cấu hình %', p_key;
  end if;
  select value into v_old from public.settings where key = p_key;
  insert into public.settings(key, value, updated_by) values (p_key, p_value, auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  insert into public.settings_history(key, old_value, new_value, changed_by) values (p_key, v_old, p_value, auth.uid());
end $$;

create or replace function public.set_secret(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ được đổi secret'; end if;
  if p_key not in ('telegram_bot_token') then raise exception 'Secret không hợp lệ'; end if;
  insert into app.secrets(key, value, updated_by) values (p_key, p_value, auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform app.log('SECRET', 'secrets', p_key, jsonb_build_object('changed', true));
end $$;

create or replace function public.secret_status()
returns table(key text, is_set boolean, masked text, updated_at timestamptz)
language sql security definer set search_path = public, app as $$
  select s.key, coalesce(s.value,'') <> '', case when length(s.value) > 8 then left(s.value,4) || '…' || right(s.value,3) else '' end, s.updated_at
  from app.secrets s where app.is_admin()
$$;

create or replace function public.telegram_test(p_text text default null)
returns text language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  perform app.telegram('test', coalesce(p_text, '✅ ERP Nam Trung: kết nối Telegram thành công lúc ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY')));
  return coalesce((select coalesce(error, 'đã gửi (request ' || request_id || ')') from public.telegram_outbox order by id desc limit 1), 'Telegram chưa bật hoặc thiếu token/chat_id');
end $$;

-- Thông tin phiên của tôi
create or replace function public.me()
returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'id', p.id, 'email', p.email, 'full_name', p.full_name, 'employee_code', p.employee_code,
    'roles', p.roles, 'job_level', p.job_level, 'job_level_name', j.name, 'level_rank', j.rank,
    'manager_id', p.manager_id, 'manager_name', app.name_of(p.manager_id),
    'work_schedule', p.work_schedule, 'is_manager', exists(select 1 from public.profiles c where c.manager_id = p.id),
    'unread', (select count(*) from public.notifications n where n.recipient_id = p.id and n.read_at is null),
    'selfie_consent', (select selfie_consent_at is not null from public.profile_private where profile_id = p.id)
  ) from public.profiles p left join public.job_levels j on j.code = p.job_level
  where p.id = auth.uid() and p.status = 'active'
$$;

-- Danh sách nhân sự rút gọn (ai đăng nhập cũng xem được tên – phục vụ chọn người)
create or replace function public.people_directory()
returns table(id uuid, full_name text, employee_code text, job_level text, org_unit_id uuid, manager_id uuid, roles text[], status text)
language sql stable security definer set search_path = public, app as $$
  select id, full_name, employee_code, job_level, org_unit_id, manager_id,
         case when app.can_see_hr() or app.is_admin() then roles else '{}'::text[] end, status
  from public.profiles where app.is_active() order by full_name
$$;

-- Tạo lời mời
create or replace function public.invite_user(p_email text, p_full_name text, p_roles text[], p_job_level text,
  p_manager uuid, p_org uuid, p_schedule text default 'office', p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not app.has_role('admin','bgd','hcns') then raise exception 'Không có quyền mời nhân sự'; end if;
  if ('admin' = any(p_roles) or 'bgd' = any(p_roles)) and not app.is_admin() then
    raise exception 'Chỉ Admin/BGĐ được cấp quyền Admin/BGĐ';
  end if;
  insert into public.invites(email, full_name, roles, job_level, manager_id, org_unit_id, work_schedule, employee_code, created_by)
  values (lower(trim(p_email)), p_full_name, p_roles, p_job_level, p_manager, p_org, p_schedule, nullif(p_code,''), auth.uid())
  on conflict (email) do update set full_name = excluded.full_name, roles = excluded.roles, job_level = excluded.job_level,
     manager_id = excluded.manager_id, org_unit_id = excluded.org_unit_id, work_schedule = excluded.work_schedule,
     employee_code = excluded.employee_code;
  perform app.log('INVITE', 'invites', lower(p_email), jsonb_build_object('roles', p_roles));
end $$;

-- Không cho tự nâng quyền: chỉ admin/bgd đổi roles, hcns đổi được thông tin tổ chức
create or replace function app.guard_profile() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if auth.uid() is null then return new; end if; -- chạy từ hệ thống
  if new.roles is distinct from old.roles and not app.is_admin() then
    if not app.has_role('hcns') or new.roles && array['admin','bgd'] or old.roles && array['admin','bgd'] then
      raise exception 'Không có quyền đổi vai trò';
    end if;
  end if;
  if (new.manager_id, new.job_level, new.org_unit_id, new.status, new.email, new.employee_code, new.sale_aliases, new.work_schedule, new.is_new_hire)
     is distinct from (old.manager_id, old.job_level, old.org_unit_id, old.status, old.email, old.employee_code, old.sale_aliases, old.work_schedule, old.is_new_hire)
     and not app.has_role('admin','bgd','hcns') then
    raise exception 'Chỉ HCNS/Admin được sửa thông tin tổ chức';
  end if;
  if new.manager_id = new.id then raise exception 'Không thể tự làm quản lý của mình'; end if;
  return new;
end $$;
create trigger guard_profile before update on public.profiles for each row execute function app.guard_profile();
create trigger touch_profile before update on public.profiles for each row execute function app.touch();
create trigger audit_profiles after insert or update or delete on public.profiles for each row execute function app.audit();
create trigger audit_private after insert or update or delete on public.profile_private for each row execute function app.audit();
create trigger audit_settings after insert or update on public.settings for each row execute function app.audit();
create trigger audit_rates after insert or update or delete on public.exchange_rates for each row execute function app.audit();
create trigger audit_delegations after insert or update on public.delegations for each row execute function app.audit();
create trigger audit_invites after insert or update or delete on public.invites for each row execute function app.audit();
