-- >>>>> supabase/00_extensions.sql
-- Chạy trên Supabase (không chạy trong test cục bộ)
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;


-- >>>>> supabase/migrations/0001_core.sql
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


-- >>>>> supabase/migrations/0002_crm.sql
-- =====================================================================
-- ERP Nam Trung · 0002 CRM: khách hàng, chăm sóc, chống trùng, chuyển
-- khách, KH đang chạy, báo giá, hỗ trợ, báo cáo ngày, bài FB
-- =====================================================================

create sequence public.customer_code_seq;
create sequence public.quote_code_seq;
create sequence public.support_code_seq;

create or replace function app.norm_phone(p text) returns text language sql immutable as $$
  select case
    when p is null or btrim(p) = '' then null
    else (select case when d like '84%' and length(d) >= 11 then '0' || substr(d, 3) else d end
          from (select regexp_replace(p, '[^0-9]', '', 'g') d) x)
  end
$$;
create or replace function app.norm_tax(p text) returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(p,''), '[^0-9-]', '', 'g'), '')
$$;
create or replace function app.vn_today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Ho_Chi_Minh')::date
$$;

-- Nhịp chăm gợi ý: min(nhịp giai đoạn, nhịp mức độ), Chủ nhật dời sang thứ Hai
create or replace function app.suggest_next_care(p_stage text, p_temp text, p_from date default null)
returns date language plpgsql stable security definer set search_path = public, app as $$
declare a int; b int; d int; r date;
begin
  if p_stage in ('khong_tiem_nang') then return null; end if;
  select (extra->>'cadence')::int into a from public.lookups where category='stage' and code=p_stage;
  select (extra->>'cadence')::int into b from public.lookups where category='temperature' and code=p_temp;
  d := least(coalesce(a, 99), coalesce(b, 99));
  if d = 99 then d := 3; end if;
  r := coalesce(p_from, app.vn_today()) + d;
  if extract(isodow from r) = 7 then r := r + 1; end if;
  return r;
end $$;

create or replace function app.stage_order(p_stage text) returns int
language sql stable security definer set search_path = public as $$
  select sort from public.lookups where category='stage' and code=p_stage
$$;

-- ---------- Khách hàng ----------
create table public.customers(
  id uuid primary key default gen_random_uuid(),
  code text unique not null default ('KH' || lpad(nextval('public.customer_code_seq')::text, 6, '0')),
  contact_name text not null check (length(btrim(contact_name)) > 0),
  position text,
  company_name text,
  phone text, phone_norm text,
  zalo text, zalo_norm text,
  tax_code text,
  email text,
  facebook text,
  province text,
  address text,
  group_root_id uuid references public.customers(id),
  customer_type text not null,
  source text not null,
  industry text,
  goods text,
  services text[] not null default '{}',
  goods_traits text[] not null default '{}',
  import_method text,
  legal_entity text,
  invoice_need text,
  frequency text,
  monthly_value text,
  current_provider text,
  stage text not null default 'moi',
  temperature text not null default 'lanh',
  next_care_date date default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  birthday date,
  note text,
  owner_id uuid not null references public.profiles(id) default auth.uid(),
  ownership text not null default 'following' check (ownership in ('following','owned')),
  owned_at timestamptz,
  care_count int not null default 0,
  quote_count int not null default 0,
  order_count int not null default 0,
  first_order_code text,
  first_order_at timestamptz,
  last_order_at timestamptz,
  last_contact_at timestamptz,
  last_result text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint phone_or_zalo check (phone_norm is not null or zalo_norm is not null),
  constraint tax_format check (tax_code is null or tax_code ~ '^[0-9]{10}(-[0-9]{3})?$'),
  constraint phone_format check (phone_norm is null or phone_norm ~ '^0[0-9]{9,10}$')
);
create index on public.customers(owner_id) where deleted_at is null;
create index on public.customers(next_care_date) where deleted_at is null;
create index on public.customers(phone_norm);
create index on public.customers(zalo_norm);
create index on public.customers(tax_code);

-- Danh sách khách đang chạy của công ty (Admin dán hằng tháng)
create table public.company_customers(
  id bigint generated always as identity primary key,
  batch_id uuid not null,
  ext_code text, name text,
  phone_norm text, phone2_norm text, tax_code text,
  last_order_date date, owner_text text, note text,
  imported_at timestamptz default now(),
  imported_by uuid default auth.uid()
);
create index on public.company_customers(phone_norm);
create index on public.company_customers(phone2_norm);
create index on public.company_customers(tax_code);

-- Trạng thái khóa theo KH đang chạy: 'active' (≤ 60 ngày có đơn) | 'sleep' | null
create or replace function app.company_lock(p_phone text, p_zalo text, p_tax text)
returns table(status text, name text, owner_text text, last_order_date date)
language sql stable security definer set search_path = public, app as $$
  with cur as (select batch_id from public.company_customers order by imported_at desc limit 1)
  select case when c.last_order_date >= app.vn_today() - coalesce(app.setting_num('crm','company_active_days'), 60)::int
              then 'active' else 'sleep' end, c.name, c.owner_text, c.last_order_date
  from public.company_customers c join cur on c.batch_id = cur.batch_id
  where (p_phone is not null and p_phone in (c.phone_norm, c.phone2_norm))
     or (p_zalo is not null and p_zalo in (c.phone_norm, c.phone2_norm))
     or (p_tax is not null and p_tax = c.tax_code)
  order by c.last_order_date desc nulls last limit 1
$$;

-- Kiểm tra trùng toàn công ty (chỉ trả về thông tin tối thiểu)
create or replace function public.check_duplicate(p_phone text default null, p_tax text default null, p_exclude uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare v_phone text := app.norm_phone(p_phone); v_tax text := app.norm_tax(p_tax);
        c record; l record;
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  select * into l from app.company_lock(v_phone, v_phone, v_tax);
  if l.status is not null then
    return jsonb_build_object('status', 'company_' || l.status, 'name', l.name, 'owner', l.owner_text, 'last_order', l.last_order_date);
  end if;
  select cu.id, cu.code, cu.owner_id, cu.ownership, cu.contact_name, cu.company_name into c
  from public.customers cu
  where cu.deleted_at is null and (p_exclude is null or cu.id <> p_exclude)
    and ((v_phone is not null and v_phone in (cu.phone_norm, cu.zalo_norm)) or (v_tax is not null and cu.tax_code = v_tax))
  limit 1;
  if c.id is null then return jsonb_build_object('status','none'); end if;
  if app.in_tree(c.owner_id) or app.is_admin() then
    return jsonb_build_object('status','visible', 'id', c.id, 'code', c.code, 'owner', app.name_of(c.owner_id),
                              'ownership', c.ownership, 'name', coalesce(c.company_name, c.contact_name));
  end if;
  return jsonb_build_object('status', case when c.ownership='owned' then 'owned_by_other' else 'shared' end,
                            'code', c.code, 'owner', app.name_of(c.owner_id));
end $$;

create or replace function app.customers_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_dup record; v_lock record;
begin
  new.phone_norm := app.norm_phone(new.phone);
  new.zalo_norm := app.norm_phone(new.zalo);
  new.tax_code := app.norm_tax(new.tax_code);
  if new.zalo_norm is not null and new.zalo_norm !~ '^0[0-9]{9,10}$' then new.zalo_norm := null; end if;
  if tg_op = 'INSERT' or (new.phone_norm, new.zalo_norm, new.tax_code) is distinct from (old.phone_norm, old.zalo_norm, old.tax_code) then
    select * into v_lock from app.company_lock(new.phone_norm, new.zalo_norm, new.tax_code);
    if v_lock.status = 'active' then
      raise exception 'KHÁCH ĐANG CHẠY CỦA CÔNG TY (%: phụ trách %). Không được tạo hồ sơ.', v_lock.name, coalesce(v_lock.owner_text,'?');
    end if;
    if tg_op = 'INSERT' and v_lock.status = 'sleep' then new.source := 'kho_khach_ngu'; end if;
    select cu.code, cu.owner_id, cu.ownership into v_dup from public.customers cu
     where cu.deleted_at is null and cu.id <> new.id
       and ((new.phone_norm is not null and new.phone_norm in (cu.phone_norm, cu.zalo_norm))
         or (new.zalo_norm is not null and new.zalo_norm in (cu.phone_norm, cu.zalo_norm))
         or (new.tax_code is not null and new.tax_code = cu.tax_code))
     limit 1;
    if v_dup.code is not null then
      if v_dup.ownership = 'owned' then
        raise exception 'TRÙNG KHÁCH: % đã có chủ (%). Không được tiếp cận.', v_dup.code, app.name_of(v_dup.owner_id);
      else
        raise exception 'TRÙNG KHÁCH: % đang được % theo (sân chung). Báo Trưởng nhóm thống nhất 1 đầu mối.', v_dup.code, app.name_of(v_dup.owner_id);
      end if;
    end if;
  end if;
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    if new.owner_id is distinct from old.owner_id and coalesce(current_setting('app.transfer', true), '') <> '1' and auth.uid() is not null then
      raise exception 'Đổi người phụ trách phải dùng chức năng Chuyển khách';
    end if;
    if (new.ownership, new.owned_at, new.order_count, new.quote_count, new.care_count, new.first_order_code)
       is distinct from (old.ownership, old.owned_at, old.order_count, old.quote_count, old.care_count, old.first_order_code)
       and coalesce(current_setting('app.system', true), '') <> '1' and auth.uid() is not null then
      raise exception 'Các trường hệ thống tự đếm không sửa tay được';
    end if;
  else
    if auth.uid() is not null and new.owner_id <> auth.uid() and not app.can_approve(new.owner_id) then
      new.owner_id := auth.uid();
    end if;
  end if;
  return new;
end $$;
create trigger customers_before before insert or update on public.customers for each row execute function app.customers_before();
create trigger audit_customers after insert or update or delete on public.customers for each row execute function app.audit();

create or replace function app.assert_customer_open(p_customer uuid)
returns void language plpgsql stable security definer set search_path = public, app as $$
declare c record; l record;
begin
  select * into c from public.customers where id = p_customer and deleted_at is null;
  if c.id is null then raise exception 'Không tìm thấy khách'; end if;
  if not (app.in_tree(c.owner_id) or app.is_admin()) then raise exception 'Khách không thuộc phạm vi của bạn'; end if;
  select * into l from app.company_lock(c.phone_norm, c.zalo_norm, c.tax_code);
  if l.status = 'active' and not app.is_admin() then
    raise exception 'Khách đang chạy của công ty (%). Bị khóa chăm sóc và báo giá.', l.owner_text;
  end if;
end $$;

-- ---------- Nhật ký chăm sóc ----------
create table public.care_logs(
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  sale_id uuid not null references public.profiles(id) default auth.uid(),
  channel text not null,
  purpose text not null,
  result text not null,
  is_connected boolean not null default true,
  content text not null check (length(btrim(content)) >= 15),
  stage_after text,
  temperature_after text,
  next_care_date date,
  quotation_code text,
  created_at timestamptz not null default now()
);
create index on public.care_logs(customer_id, created_at desc);
create index on public.care_logs(sale_id, created_at desc);

create or replace function app.care_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare c record;
begin
  perform app.assert_customer_open(new.customer_id);
  select * into c from public.customers where id = new.customer_id;
  new.sale_id := coalesce(auth.uid(), new.sale_id);
  if new.purpose = 'tiep_can_lan_dau' and c.care_count > 0 then
    raise exception '"Tiếp cận lần đầu" chỉ dùng cho khách chưa chăm lần nào';
  end if;
  new.is_connected := new.result not in (select code from public.lookups where category='care_result' and (extra->>'fail')::boolean);
  new.stage_after := coalesce(new.stage_after, c.stage);
  if new.is_connected and new.stage_after = 'moi' then new.stage_after := 'tiep_can'; end if;
  new.temperature_after := coalesce(new.temperature_after, c.temperature);
  if new.next_care_date is null then
    new.next_care_date := app.suggest_next_care(new.stage_after, new.temperature_after);
  elsif new.next_care_date < app.vn_today() then
    raise exception 'Ngày hẹn chăm tiếp không được ở quá khứ';
  end if;
  return new;
end $$;
create or replace function app.care_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('app.system', '1', true);
  update public.customers set
    care_count = care_count + 1,
    stage = new.stage_after,
    temperature = new.temperature_after,
    next_care_date = new.next_care_date,
    last_contact_at = new.created_at,
    last_result = new.result
  where id = new.customer_id;
  perform set_config('app.system', '', true);
  return new;
end $$;
create trigger care_before before insert on public.care_logs for each row execute function app.care_before();
create trigger care_after after insert on public.care_logs for each row execute function app.care_after();
-- Chỉ được sửa nhật ký trong 24 giờ
create or replace function app.care_guard_update() returns trigger language plpgsql as $$
begin
  if old.created_at < now() - interval '24 hours' then raise exception 'Nhật ký đã khóa sau 24 giờ'; end if;
  if new.customer_id <> old.customer_id or new.sale_id <> old.sale_id then raise exception 'Không đổi khách/người ghi'; end if;
  return new;
end $$;
create trigger care_guard before update on public.care_logs for each row execute function app.care_guard_update();

-- ---------- Chuyển khách ----------
create table public.customer_transfers(
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  from_id uuid references public.profiles(id),
  to_id uuid not null references public.profiles(id),
  reason text not null,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);

create or replace function public.transfer_customer(p_customer uuid, p_to uuid, p_reason text, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare c record;
begin
  select * into c from public.customers where id = p_customer and deleted_at is null;
  if c.id is null then raise exception 'Không tìm thấy khách'; end if;
  if coalesce(btrim(p_reason),'') = '' then raise exception 'Bắt buộc lý do chuyển'; end if;
  if not app.is_admin() then
    if not app.has_role('tn_kd','tp_kd') then raise exception 'Sale không tự chuyển khách'; end if;
    if p_to = auth.uid() then raise exception 'Quản lý không tự nhận khách về mình (cần Admin/BGĐ)'; end if;
    if not (app.can_approve(c.owner_id) or c.owner_id = auth.uid()) or not app.can_approve(p_to) then
      raise exception 'Chỉ chuyển trong nhóm bạn quản lý';
    end if;
    if c.stage in ('hoat_dong','vip') and p_reason not in ('nghi_viec','chu_cu_dong_y') then
      raise exception 'Khách đang hoạt động: cần chủ cũ đồng ý hoặc BGĐ quyết định';
    end if;
  end if;
  perform set_config('app.transfer', '1', true);
  update public.customers set owner_id = p_to where id = p_customer;
  perform set_config('app.transfer', '', true);
  insert into public.customer_transfers(customer_id, from_id, to_id, reason, note) values (p_customer, c.owner_id, p_to, p_reason, p_note);
  perform app.notify(p_to, 'customer', 'Bạn được giao khách ' || c.code, coalesce(c.company_name, c.contact_name), '#/crm/customer?id=' || c.id);
  perform app.notify(c.owner_id, 'customer', 'Khách ' || c.code || ' đã chuyển sang ' || app.name_of(p_to), p_note, null);
end $$;

-- ---------- Báo giá ----------
create table public.quotations(
  id uuid primary key default gen_random_uuid(),
  code text not null,
  version int not null default 1,
  root_id uuid,
  superseded_by uuid references public.quotations(id),
  customer_id uuid not null references public.customers(id),
  sale_id uuid not null references public.profiles(id) default auth.uid(),
  status text not null default 'nhap' check (status in ('nhap','cho_duyet','da_gui','can_nhac','da_chot','tu_choi','het_han','da_thay_the')),
  order_code text,
  header jsonb not null,         -- toàn bộ tham số đầu báo giá (đã chụp tỷ giá, giá vốn)
  totals jsonb not null default '{}',
  total_after_vat numeric(18,0) default 0,
  est_profit numeric(18,0) default 0,
  violations text[] not null default '{}',
  price_hash text,
  approved_hash text,
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  approval_note text,
  sent_at timestamptz,
  valid_until date,
  reject_reason text,
  reject_note text,
  won_at timestamptz,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (code, version)
);
create index on public.quotations(customer_id);
create index on public.quotations(sale_id, created_at desc);
create index on public.quotations(status);

create table public.quotation_lines(
  id uuid primary key default gen_random_uuid(),
  quotation_id uuid not null references public.quotations(id) on delete cascade,
  line_no int not null,
  name text not null,
  spec text,
  hs_code text,
  unit text,
  qty numeric(18,3) not null check (qty > 0),
  unit_price_cny numeric(18,4) not null default 0,
  duty_pct numeric(7,4) default 0,
  vat_pct numeric(7,4),
  freight_pct numeric(7,4),
  manual_price numeric(18,2),
  computed jsonb default '{}'
);
create index on public.quotation_lines(quotation_id);
create trigger audit_quotes after insert or update or delete on public.quotations for each row execute function app.audit();

-- Kiểm tra khung giá phía server (không tin số liệu từ trình duyệt)
create or replace function app.quote_check(p_header jsonb, p_lines jsonb)
returns text[] language plpgsql stable security definer set search_path = public, app as $$
declare
  v text[] := '{}';
  rate numeric := (p_header->>'tyGia')::numeric;
  dv numeric := coalesce((p_header->>'phiDVPct')::numeric, 0);
  dv_fixed numeric := coalesce((p_header->>'phiDVCoDinh')::numeric, 0);
  ut numeric := coalesce((p_header->>'phiUTPct')::numeric, 0);
  kg numeric := coalesce((p_header->>'soKg')::numeric, 0);
  m3 numeric := coalesce((p_header->>'soKhoi')::numeric, 0);
  dg_kg numeric := coalesce((p_header->>'donGiaKg')::numeric, 0);
  dg_m3 numeric := coalesce((p_header->>'donGiaKhoi')::numeric, 0);
  mode text := coalesce(p_header->>'cheDoXuat', 'du');
  pct numeric := coalesce((p_header->>'pctXuat')::numeric, 100);
  kho text := coalesce(p_header->>'khoNhan', 'HN');
  cfg jsonb := coalesce(app.setting('quote_defaults'), '{}');
  rate_von numeric := coalesce(app.current_rate('von'), (cfg->>'tyGiaVon')::numeric, 3955);
  rate_san numeric := coalesce(app.current_rate('san'), (cfg->>'tyGiaSan')::numeric, 4015);
  ut_min numeric := coalesce((cfg->>'phiUTSan')::numeric, 0.8);
  dv_min numeric := coalesce((cfg->>'phiDVSan')::numeric, 1.2);
  xuat_min numeric := coalesce((cfg->>'tyLeXuatMin')::numeric, 70);
  von_m3 numeric := coalesce((cfg->'giaVonKhoi'->>kho)::numeric, (cfg->>'giaVonKhoiHN')::numeric, 800000);
  tien_hang numeric;
  cuoc numeric;
begin
  if rate is null or rate <= 0 then raise exception 'Thiếu tỷ giá'; end if;
  if jsonb_array_length(coalesce(p_lines, '[]')) = 0 then raise exception 'Báo giá phải có ít nhất 1 dòng hàng'; end if;
  -- CẤM
  if rate < rate_von then raise exception 'CẤM: tỷ giá % thấp hơn tỷ giá vốn %', rate, rate_von; end if;
  if ut < ut_min then raise exception 'CẤM: phí ủy thác % thấp hơn sàn %', ut, ut_min; end if;
  -- DUYỆT
  select sum((l->>'qty')::numeric * coalesce((l->>'unit_price_cny')::numeric,0)) * rate into tien_hang from jsonb_array_elements(p_lines) l;
  if rate < rate_san then v := v || ('Tỷ giá ' || rate || ' < ' || rate_san); end if;
  if dv_fixed > 0 then
    if dv_fixed < round(tien_hang * dv_min / 100) then v := v || ('Phí dịch vụ cố định < ' || dv_min || '% tiền hàng'); end if;
  elsif dv < dv_min then v := v || ('Phí dịch vụ ' || dv || '% < ' || dv_min || '%'); end if;
  cuoc := greatest(kg * dg_kg, m3 * dg_m3);
  if m3 > 0 and cuoc / m3 < von_m3 then v := v || ('Cước ' || round(cuoc/m3) || 'đ/m³ < giá vốn ' || von_m3); end if;
  if mode = 'thap' and pct < xuat_min then v := v || ('Xuất thấp ' || pct || '% < ' || xuat_min || '%'); end if;
  return v;
end $$;

create or replace function app.quote_hash(p_header jsonb, p_lines jsonb) returns text language sql immutable as $$
  select md5(coalesce(p_header,'{}')::text || coalesce(p_lines,'[]')::text)
$$;

-- Lưu báo giá (tạo mới / sửa / tạo phiên bản mới khi đã gửi)
create or replace function public.save_quote(p_id uuid, p_customer uuid, p_header jsonb, p_lines jsonb, p_totals jsonb, p_note text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare q record; v_id uuid; v_viol text[]; v_hash text; v_header jsonb;
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  perform app.assert_customer_open(p_customer);
  -- chụp lại giá vốn tại thời điểm lập
  v_header := p_header || jsonb_build_object(
    'tyGiaVon', coalesce(app.current_rate('von'), 3955),
    'tyGiaSan', coalesce(app.current_rate('san'), 4015));
  v_viol := app.quote_check(v_header, p_lines);
  v_hash := app.quote_hash(p_header, p_lines);
  if p_id is null then
    insert into public.quotations(code, customer_id, header, totals, total_after_vat, est_profit, violations, price_hash, note)
    values ('BG' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'YYMM') || '-' || lpad(nextval('public.quote_code_seq')::text, 4, '0'),
            p_customer, v_header, coalesce(p_totals,'{}'), coalesce((p_totals->>'tongSauVAT')::numeric,0),
            coalesce((p_totals->>'lnUocTinh')::numeric,0), v_viol, v_hash, p_note)
    returning id into v_id;
    update public.quotations set root_id = id where id = v_id;
  else
    select * into q from public.quotations where id = p_id for update;
    if q.id is null then raise exception 'Không tìm thấy báo giá'; end if;
    if not (q.sale_id = auth.uid() or app.is_admin()) then raise exception 'Chỉ người lập được sửa báo giá'; end if;
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
  insert into public.quotation_lines(quotation_id, line_no, name, spec, hs_code, unit, qty, unit_price_cny, duty_pct, vat_pct, freight_pct, manual_price, computed)
  select v_id, ord, l->>'name', l->>'spec', l->>'hs_code', l->>'unit', (l->>'qty')::numeric, coalesce((l->>'unit_price_cny')::numeric,0),
         coalesce((l->>'duty_pct')::numeric,0), (l->>'vat_pct')::numeric, (l->>'freight_pct')::numeric, (l->>'manual_price')::numeric, coalesce(l->'computed','{}')
  from jsonb_array_elements(p_lines) with ordinality t(l, ord)
  where coalesce(btrim(l->>'name'),'') <> '' and coalesce((l->>'qty')::numeric, 0) > 0;
  return v_id;
end $$;

create or replace function app.quote_approvers(p_sale uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  with recursive up as (
    select manager_id id from public.profiles where id = p_sale
    union select p.manager_id from public.profiles p join up on p.id = up.id where p.manager_id is not null
  )
  select p.id from public.profiles p where p.status='active' and p.id <> p_sale and (
    p.roles && array['admin','bgd'] or (p.roles && array['tp_kd'] and p.id in (select id from up)))
$$;

create or replace function public.quote_submit(p_id uuid)
returns text language plpgsql security definer set search_path = public, app as $$
declare q record; c record; v_days int;
begin
  select * into q from public.quotations where id = p_id for update;
  if q.id is null or not (q.sale_id = auth.uid() or app.is_admin()) then raise exception 'Không có quyền'; end if;
  if q.status <> 'nhap' then raise exception 'Chỉ gửi được báo giá ở trạng thái Nháp'; end if;
  perform app.assert_customer_open(q.customer_id);
  if cardinality(q.violations) > 0 and q.approved_hash is distinct from q.price_hash then
    update public.quotations set status = 'cho_duyet', updated_at = now() where id = p_id;
    perform app.notify(x, 'quote', 'Duyệt giá ' || q.code || ' v' || q.version, array_to_string(q.violations, '; '), '#/crm/quote?id=' || q.id)
      from app.quote_approvers(q.sale_id) x;
    perform app.telegram('quote_approval', '🟠 <b>Chờ duyệt giá</b> ' || q.code || ' v' || q.version || E'\nSale: ' || app.esc(app.name_of(q.sale_id))
      || E'\nVi phạm: ' || app.esc(array_to_string(q.violations, '; ')) || E'\nTổng sau VAT: ' || to_char(q.total_after_vat, 'FM999G999G999G999') || 'đ');
    return 'cho_duyet';
  end if;
  v_days := coalesce(app.setting_num('crm','quote_valid_days'), 5)::int;
  update public.quotations set status = 'da_gui', sent_at = now(), valid_until = app.vn_today() + v_days, updated_at = now() where id = p_id;
  select * into c from public.customers where id = q.customer_id;
  perform set_config('app.system', '1', true);
  update public.customers set quote_count = quote_count + 1,
    stage = case when app.stage_order(stage) < app.stage_order('da_bao_gia') then 'da_bao_gia' else stage end,
    next_care_date = app.suggest_next_care(case when app.stage_order(stage) < app.stage_order('da_bao_gia') then 'da_bao_gia' else stage end, temperature)
  where id = q.customer_id;
  perform set_config('app.system', '', true);
  return 'da_gui';
end $$;

create or replace function public.quote_decide(p_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare q record;
begin
  select * into q from public.quotations where id = p_id for update;
  if q.status <> 'cho_duyet' then raise exception 'Báo giá không ở trạng thái chờ duyệt'; end if;
  if q.sale_id = auth.uid() then raise exception 'Không tự duyệt báo giá của mình'; end if;
  if not (app.is_admin() or (app.has_role('tp_kd') and app.in_tree(q.sale_id))) then
    raise exception 'Chỉ Trưởng phòng KD trở lên được duyệt phá khung';
  end if;
  if not p_approve and coalesce(btrim(p_note),'') = '' then raise exception 'Từ chối phải có lý do'; end if;
  update public.quotations set status = 'nhap',
    approved_hash = case when p_approve then price_hash end,
    approved_by = case when p_approve then auth.uid() end,
    approved_at = case when p_approve then now() end,
    approval_note = p_note, updated_at = now()
  where id = p_id;
  perform app.notify(q.sale_id, 'quote', case when p_approve then '✅ Đã duyệt giá ' else '❌ Không duyệt giá ' end || q.code, p_note, '#/crm/quote?id=' || q.id);
end $$;

create or replace function public.quote_set_status(p_id uuid, p_status text, p_order_code text default null, p_reason text default null, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare q record; c record; v_first boolean;
begin
  select * into q from public.quotations where id = p_id for update;
  if q.id is null or not (q.sale_id = auth.uid() or app.is_admin()) then raise exception 'Không có quyền'; end if;
  if q.status not in ('da_gui','can_nhac') then raise exception 'Chỉ cập nhật kết quả cho báo giá đã gửi'; end if;
  if p_status = 'can_nhac' then
    update public.quotations set status = 'can_nhac', updated_at = now() where id = p_id;
  elsif p_status = 'da_chot' then
    if coalesce(btrim(p_order_code),'') = '' then raise exception 'Chốt đơn bắt buộc nhập Mã đơn'; end if;
    update public.quotations set status = 'da_chot', order_code = upper(btrim(p_order_code)), won_at = now(), updated_at = now() where id = p_id;
    select * into c from public.customers where id = q.customer_id for update;
    v_first := c.order_count = 0;
    perform set_config('app.system', '1', true);
    update public.customers set
      order_count = order_count + 1,
      first_order_code = coalesce(first_order_code, upper(btrim(p_order_code))),
      first_order_at = coalesce(first_order_at, now()),
      last_order_at = now(),
      ownership = 'owned',
      owned_at = coalesce(owned_at, now()),
      stage = case when v_first then 'don_dau' when stage = 'vip' then 'vip' else 'hoat_dong' end,
      temperature = 'nong',
      next_care_date = app.suggest_next_care(case when v_first then 'don_dau' when stage='vip' then 'vip' else 'hoat_dong' end, 'nong')
    where id = q.customer_id;
    perform set_config('app.system', '', true);
    perform app.telegram('quote_won', '🟢 <b>Chốt đơn</b> ' || app.esc(upper(p_order_code)) || ' · ' || q.code
      || E'\nKhách: ' || app.esc(coalesce(c.company_name, c.contact_name)) || case when v_first then ' (đơn đầu – xác lập chủ khách)' else '' end
      || E'\nSale: ' || app.esc(app.name_of(q.sale_id)) || E'\nGiá trị: ' || to_char(q.total_after_vat, 'FM999G999G999G999') || 'đ · LN ước tính ' || to_char(q.est_profit, 'FM999G999G999G999') || 'đ');
  elsif p_status = 'tu_choi' then
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Bắt buộc lý do từ chối'; end if;
    update public.quotations set status = 'tu_choi', reject_reason = p_reason, reject_note = p_note, updated_at = now() where id = p_id;
  else
    raise exception 'Trạng thái không hợp lệ';
  end if;
end $$;

create or replace function public.quote_clone(p_id uuid)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare q record; v_header jsonb; v_lines jsonb;
begin
  select * into q from public.quotations where id = p_id;
  if q.id is null or not (app.in_tree(q.sale_id) or app.is_admin()) then raise exception 'Không có quyền'; end if;
  v_header := q.header || jsonb_build_object('tyGia', coalesce(app.current_rate('ban'), (q.header->>'tyGia')::numeric));
  select jsonb_agg(to_jsonb(l) - 'id' - 'quotation_id' order by line_no) into v_lines from public.quotation_lines l where quotation_id = p_id;
  return public.save_quote(null, q.customer_id, v_header, v_lines, '{}'::jsonb, q.note);
end $$;

-- ---------- Gọi hỗ trợ ----------
create table public.support_requests(
  id uuid primary key default gen_random_uuid(),
  code text unique not null default ('HT' || lpad(nextval('public.support_code_seq')::text, 5, '0')),
  requester_id uuid not null references public.profiles(id) default auth.uid(),
  assignee_id uuid references public.profiles(id),
  org_unit_id uuid references public.org_units(id),
  customer_id uuid references public.customers(id),
  title text not null,
  content text,
  priority text not null default 'thuong' check (priority in ('thap','thuong','gap')),
  status text not null default 'moi' check (status in ('moi','da_nhan','dang_xu_ly','xong','dong')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);
create table public.support_messages(
  id bigint generated always as identity primary key,
  request_id uuid not null references public.support_requests(id) on delete cascade,
  author_id uuid not null references public.profiles(id) default auth.uid(),
  body text not null,
  created_at timestamptz default now()
);

create or replace function app.support_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' then
    if new.assignee_id is not null then
      perform app.notify(new.assignee_id, 'support', '🆘 ' || app.name_of(new.requester_id) || ' gọi hỗ trợ', new.title, '#/support?id=' || new.id);
    elsif new.org_unit_id is not null then
      perform app.notify(p.id, 'support', '🆘 Yêu cầu hỗ trợ cho phòng', new.title, '#/support?id=' || new.id)
        from public.profiles p where p.org_unit_id = new.org_unit_id and p.status='active';
    end if;
    perform app.telegram('support', '🆘 <b>Gọi hỗ trợ</b> ' || new.code || ' (' || new.priority || E')\nTừ: ' || app.esc(app.name_of(new.requester_id))
      || coalesce(E'\nGửi: ' || app.esc(app.name_of(new.assignee_id)), '') || E'\n' || app.esc(new.title));
  elsif new.status is distinct from old.status then
    perform app.notify(new.requester_id, 'support', 'Hỗ trợ ' || new.code || ': ' || new.status, new.title, '#/support?id=' || new.id);
  end if;
  return new;
end $$;
create trigger support_after after insert or update on public.support_requests for each row execute function app.support_after();
create trigger support_touch before update on public.support_requests for each row execute function app.touch();

-- ---------- Báo cáo ngày & bài FB ----------
create table public.daily_reports(
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.profiles(id) default auth.uid(),
  report_date date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  calls int not null default 0 check (calls >= 0),
  messages int not null default 0 check (messages >= 0),
  content text not null,
  plan_tomorrow text,
  submitted_at timestamptz not null default now(),
  on_time boolean not null default true,
  reviewed_by uuid references public.profiles(id),
  review_note text,
  unique (sale_id, report_date)
);
create or replace function app.daily_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  new.sale_id := coalesce(auth.uid(), new.sale_id);
  new.submitted_at := now();
  new.on_time := (now() at time zone 'Asia/Ho_Chi_Minh') <= (new.report_date + make_time(coalesce(app.setting_num('crm','report_deadline_hour'),18)::int, 0, 0));
  return new;
end $$;
create trigger daily_before before insert on public.daily_reports for each row execute function app.daily_before();

create table public.fb_posts(
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.profiles(id) default auth.uid(),
  post_date date not null default (now() at time zone 'Asia/Ho_Chi_Minh')::date,
  url text not null unique check (url ~* '^https?://'),
  verified_by uuid references public.profiles(id),
  verified_at timestamptz,
  created_at timestamptz default now()
);


-- >>>>> supabase/migrations/0003_hr.sql
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


-- >>>>> supabase/migrations/0004_ops.sql
-- =====================================================================
-- ERP Nam Trung · 0004 Tài liệu chứng từ, Bảng tin, Ticket, KPI,
-- Bảng Phong Thần, snapshot, Dashboard, báo cáo CRM
-- =====================================================================

create or replace function app.my_rank() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select j.rank from public.profiles p join public.job_levels j on j.code = p.job_level
                   where p.id = auth.uid() and p.status='active'), 0)
$$;

-- ---------- Tài liệu chứng từ ----------
create table public.doc_categories(
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  min_rank int not null default 3,          -- 3 = Chuyên viên trở lên
  extra_roles text[] not null default '{ke_toan}',
  sort int default 0
);
create table public.documents(
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.doc_categories(id),
  title text not null,
  kind text not null check (kind in ('link','file')),
  url text,
  storage_path text,
  file_name text,
  file_size bigint,
  customer_id uuid references public.customers(id),
  ext_order_code text,
  owner_id uuid references public.profiles(id) default auth.uid(),
  note text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  deleted_at timestamptz,
  check ((kind = 'link' and url ~* '^https?://') or (kind = 'file' and storage_path is not null))
);
create table public.document_access_logs(
  id bigint generated always as identity primary key,
  document_id uuid references public.documents(id),
  user_id uuid default auth.uid(),
  action text not null,
  at timestamptz default now()
);
create or replace function app.can_doc_category(p_cat uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_admin() or exists(select 1 from public.doc_categories c where c.id = p_cat
           and (app.my_rank() >= c.min_rank or app.my_roles() && c.extra_roles))
$$;
create or replace function public.doc_open(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare d record;
begin
  select * into d from public.documents where id = p_id and deleted_at is null;
  if d.id is null or not app.can_doc_category(d.category_id) then raise exception 'Không có quyền xem tài liệu'; end if;
  insert into public.document_access_logs(document_id, action) values (p_id, 'open');
  return jsonb_build_object('kind', d.kind, 'url', d.url, 'storage_path', d.storage_path, 'file_name', d.file_name);
end $$;
create trigger audit_docs after insert or update or delete on public.documents for each row execute function app.audit();
create trigger touch_docs before update on public.documents for each row execute function app.touch();

-- ---------- Bảng tin ----------
create table public.announcements(
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  category text not null default 'chung',
  audience text not null default 'all' check (audience in ('all','units','team')),
  unit_ids uuid[] not null default '{}',
  pinned boolean not null default false,
  publish_at timestamptz not null default now(),
  expires_at timestamptz,
  created_by uuid not null references public.profiles(id) default auth.uid(),
  created_at timestamptz default now()
);
create table public.announcement_reads(
  announcement_id uuid references public.announcements(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade default auth.uid(),
  read_at timestamptz default now(),
  primary key (announcement_id, user_id)
);
create or replace function app.tree_of(p_id uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  with recursive t as (select p_id id union select p.id from public.profiles p join t on p.manager_id = t.id)
  select array_agg(id) from t
$$;
create or replace function app.announcement_visible(a public.announcements) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_active() and (a.created_by = auth.uid() or app.is_admin() or (a.publish_at <= now() and (a.expires_at is null or a.expires_at > now()) and (
    a.audience = 'all'
    or (a.audience = 'units' and (select org_unit_id from public.profiles where id = auth.uid()) = any(a.unit_ids))
    or (a.audience = 'team' and auth.uid() in (select unnest(x) from (select app.tree_of(a.created_by) x) t))
  )))
$$;
create or replace function app.announce_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  new.created_by := coalesce(auth.uid(), new.created_by);
  if not (app.is_admin() or app.has_role('hcns')) then
    if app.has_role('tp_kd','tn_kd') then new.audience := 'team';
    else raise exception 'Bạn không có quyền đăng bảng tin'; end if;
  end if;
  return new;
end $$;
create or replace function app.announce_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  insert into public.notifications(recipient_id, kind, title, body, link)
  select p.id, 'news', '📢 ' || new.title, left(new.body, 200), '#/news?id=' || new.id
  from public.profiles p where p.status = 'active' and p.id <> new.created_by and (
    new.audience = 'all' or (new.audience = 'units' and p.org_unit_id = any(new.unit_ids))
    or (new.audience = 'team' and p.id = any(app.tree_of(new.created_by))));
  if new.audience = 'all' then
    perform app.telegram('announcement', '📢 <b>' || app.esc(new.title) || '</b>' || E'\n' || app.esc(left(new.body, 500)));
  end if;
  return new;
end $$;
create trigger announce_before before insert on public.announcements for each row execute function app.announce_before();
create trigger announce_after after insert on public.announcements for each row execute function app.announce_after();

-- ---------- Ticket nội bộ ----------
create sequence public.ticket_code_seq;
create table public.tickets(
  id uuid primary key default gen_random_uuid(),
  code text unique not null default ('TK' || lpad(nextval('public.ticket_code_seq')::text, 5, '0')),
  type text not null check (type in ('y_tuong','loi','cai_tien','khac')),
  title text not null,
  description text not null,
  priority text not null default 'trung_binh' check (priority in ('thap','trung_binh','cao','khan')),
  status text not null default 'moi' check (status in ('moi','dang_xu_ly','cho_phan_hoi','xong','dong')),
  reporter_id uuid not null references public.profiles(id) default auth.uid(),
  assignee_id uuid references public.profiles(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  closed_at timestamptz
);
create table public.ticket_comments(
  id bigint generated always as identity primary key,
  ticket_id uuid not null references public.tickets(id) on delete cascade,
  author_id uuid not null references public.profiles(id) default auth.uid(),
  body text not null,
  created_at timestamptz default now()
);
create or replace function app.ticket_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' then
    perform app.notify_roles(array['admin'], 'ticket', 'Ticket mới ' || new.code, new.title, '#/tickets?id=' || new.id);
    perform app.telegram('ticket', '🎫 <b>Ticket ' || new.code || '</b> (' || new.type || ', ' || new.priority || ')' || E'\n' || app.esc(new.title) || E'\nNgười gửi: ' || app.esc(app.name_of(new.reporter_id)));
  else
    if new.assignee_id is distinct from old.assignee_id then
      perform app.notify(new.assignee_id, 'ticket', 'Bạn được giao ticket ' || new.code, new.title, '#/tickets?id=' || new.id);
    end if;
    if new.status is distinct from old.status then
      perform app.notify(new.reporter_id, 'ticket', 'Ticket ' || new.code || ': ' || new.status, new.title, '#/tickets?id=' || new.id);
    end if;
  end if;
  return new;
end $$;
create trigger ticket_after after insert or update on public.tickets for each row execute function app.ticket_after();
create trigger ticket_touch before update on public.tickets for each row execute function app.touch();

-- ---------- KPI hoạt động sale ----------
create table public.kpi_snapshots(
  id uuid primary key default gen_random_uuid(),
  period text not null,                  -- 'YYYY-MM'
  profile_id uuid not null references public.profiles(id),
  data jsonb not null,
  score numeric(7,2),
  rank int,
  profit numeric(18,0),
  profit_rank int,
  locked_at timestamptz not null default now(),
  unique (period, profile_id)
);
create table public.kpi_adjustments(
  id uuid primary key default gen_random_uuid(),
  snapshot_id uuid not null references public.kpi_snapshots(id),
  field text not null, old_value text, new_value text,
  reason text not null,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);
create or replace function app.snapshot_guard() returns trigger language plpgsql as $$
begin raise exception 'Snapshot đã chốt không sửa/xóa được. Dùng điều chỉnh có lý do.'; end $$;
create trigger snapshot_guard before update or delete on public.kpi_snapshots for each row execute function app.snapshot_guard();

-- Số ngày làm việc KPI trong khoảng (tuần 6 ngày, trừ lễ)
create or replace function app.kpi_days(p_from date, p_to date) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') d
  where extract(isodow from d) < 7 and not exists (select 1 from public.holidays h where h.day = d::date)
$$;

create or replace function public.kpi_report(p_from date, p_to date, p_all boolean default false)
returns table(profile_id uuid, full_name text, job_level text, is_new boolean, metrics jsonb, score numeric, grade text)
language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('kpi'), '{}'); days int := greatest(app.kpi_days(p_from, least(p_to, app.vn_today())), 1);
        t0 timestamptz := (p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'); t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh');
begin
  return query
  with sales as (
    select p.id, p.full_name, p.job_level, p.is_new_hire from public.profiles p
    where p.status = 'active' and p.roles && array['sale','tn_kd','tp_kd']
      and (p_all and app.is_active() or p.id = any(app.my_tree()) or app.is_admin())
  ), m as (
    select s.id, s.full_name, s.job_level, s.is_new_hire, jsonb_build_object(
      'kh_moi', (select count(*) from public.customers c where c.created_by = s.id and c.created_at >= t0 and c.created_at < t1),
      'tiep_can', (select count(distinct cl.customer_id) from public.care_logs cl where cl.sale_id = s.id and cl.purpose = 'tiep_can_lan_dau' and cl.created_at >= t0 and cl.created_at < t1),
      'ket_noi', (select count(*) from public.care_logs cl where cl.sale_id = s.id and cl.is_connected and cl.created_at >= t0 and cl.created_at < t1),
      'cham_cu', (select count(*) from public.care_logs cl where cl.sale_id = s.id and cl.purpose <> 'tiep_can_lan_dau' and cl.created_at >= t0 and cl.created_at < t1),
      'bao_gia', (select count(*) from public.quotations q where q.sale_id = s.id and q.sent_at >= t0 and q.sent_at < t1),
      'bai_fb', (select count(*) from public.fb_posts f where f.sale_id = s.id and f.post_date between p_from and p_to and f.verified_at is not null),
      'bao_cao', (select count(*) from public.daily_reports r where r.sale_id = s.id and r.report_date between p_from and p_to and r.on_time),
      'cuoc_goi_khai', (select coalesce(sum(r.calls),0) from public.daily_reports r where r.sale_id = s.id and r.report_date between p_from and p_to),
      'tin_nhan_khai', (select coalesce(sum(r.messages),0) from public.daily_reports r where r.sale_id = s.id and r.report_date between p_from and p_to),
      'cuoc_goi_nhat_ky', (select count(*) from public.care_logs cl where cl.sale_id = s.id and cl.channel = 'goi_dien' and cl.created_at >= t0 and cl.created_at < t1),
      'khach_nong_am', (select count(*) from public.customers c where c.owner_id = s.id and c.deleted_at is null and c.temperature in ('nong','am')),
      'don_chot', (select count(*) from public.quotations q where q.sale_id = s.id and q.won_at >= t0 and q.won_at < t1),
      'qua_han', (select count(*) from public.customers c where c.owner_id = s.id and c.deleted_at is null and c.next_care_date < app.vn_today())
    ) mx from sales s
  )
  select m.id, m.full_name, m.job_level, m.is_new_hire, m.mx || jsonb_build_object('days', days),
    round(sum(least(coalesce((m.mx->>k.key)::numeric,0) / nullif((k.value->>'day')::numeric * days * case when m.is_new_hire then coalesce((cfg->>'new_hire_factor')::numeric, 0.7) else 1 end, 0), 1.2)
          * (k.value->>'weight')::numeric), 1),
    case when round(sum(least(coalesce((m.mx->>k.key)::numeric,0) / nullif((k.value->>'day')::numeric * days * case when m.is_new_hire then coalesce((cfg->>'new_hire_factor')::numeric, 0.7) else 1 end, 0), 1.2) * (k.value->>'weight')::numeric), 1) >= 100 then 'Xuất sắc'
         when round(sum(least(coalesce((m.mx->>k.key)::numeric,0) / nullif((k.value->>'day')::numeric * days * case when m.is_new_hire then coalesce((cfg->>'new_hire_factor')::numeric, 0.7) else 1 end, 0), 1.2) * (k.value->>'weight')::numeric), 1) >= 85 then 'Đạt'
         when round(sum(least(coalesce((m.mx->>k.key)::numeric,0) / nullif((k.value->>'day')::numeric * days * case when m.is_new_hire then coalesce((cfg->>'new_hire_factor')::numeric, 0.7) else 1 end, 0), 1.2) * (k.value->>'weight')::numeric), 1) >= 70 then 'Cần cải thiện'
         else 'Chưa đạt' end
  from m cross join lateral jsonb_each(coalesce(cfg->'metrics', '{}')) k
  group by m.id, m.full_name, m.job_level, m.is_new_hire, m.mx
  order by 6 desc nulls last;
end $$;

-- Bảng Phong Thần: ai cũng xem được tên + điểm/xếp hạng (không lộ chi tiết lương)
create or replace function public.leaderboard(p_from date, p_to date)
returns table(full_name text, score numeric, grade text, profit numeric, rank_score bigint, rank_profit bigint)
language sql stable security definer set search_path = public, app as $$
  with k as (select * from public.kpi_report(p_from, p_to, true)),
  pr as (select o.profile_id, sum(o.order_profit) profit from public.order_results o
           join public.payroll_periods pp on pp.id = o.period_id
          where pp.month between date_trunc('month', p_from)::date and date_trunc('month', p_to)::date group by 1)
  select k.full_name, k.score, k.grade, coalesce(pr.profit, 0),
         rank() over (order by k.score desc nulls last), rank() over (order by coalesce(pr.profit,0) desc)
  from k left join pr on pr.profile_id = k.profile_id
  where app.is_active()
  order by 5
$$;

create or replace function public.kpi_close_month(p_month date)
returns int language plpgsql security definer set search_path = public, app as $$
declare v_from date := date_trunc('month', p_month)::date; v_to date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date; n int;
begin
  if not app.is_admin() then raise exception 'Chỉ BGĐ/Admin chốt KPI'; end if;
  insert into public.kpi_snapshots(period, profile_id, data, score, rank, profit, profit_rank)
  select to_char(v_from, 'YYYY-MM'), k.profile_id, k.metrics || jsonb_build_object('grade', k.grade), k.score,
         rank() over (order by k.score desc nulls last), coalesce(pr.profit,0), rank() over (order by coalesce(pr.profit,0) desc)
  from public.kpi_report(v_from, v_to, true) k
  left join (select o.profile_id, sum(o.order_profit) profit from public.order_results o join public.payroll_periods pp on pp.id = o.period_id
             where pp.month = v_from group by 1) pr on pr.profile_id = k.profile_id
  on conflict (period, profile_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- Dashboard ----------
create or replace function public.dashboard()
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare me uuid := auth.uid(); tree uuid[] := app.my_tree(); r jsonb; today date := app.vn_today();
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  r := jsonb_build_object(
    'today', today,
    'care_overdue', (select count(*) from public.customers where owner_id = me and deleted_at is null and next_care_date < today and stage <> 'khong_tiem_nang'),
    'care_today', (select count(*) from public.customers where owner_id = me and deleted_at is null and next_care_date = today),
    'team_overdue', (select count(*) from public.customers where owner_id = any(tree) and owner_id <> me and deleted_at is null and next_care_date < today),
    'my_customers', (select count(*) from public.customers where owner_id = me and deleted_at is null),
    'quotes_pending_me', (select count(*) from public.quotations q where q.status = 'cho_duyet' and q.sale_id <> me
                           and (app.is_admin() or (app.has_role('tp_kd') and q.sale_id = any(tree)))),
    'my_quotes_open', (select count(*) from public.quotations where sale_id = me and status in ('nhap','cho_duyet','da_gui','can_nhac')),
    'approvals_pending', (select count(*) from public.leave_requests l where l.status = 'cho_duyet' and app.can_approve(l.profile_id))
                       + (select count(*) from public.attendance_requests a where a.status = 'cho_duyet' and app.can_approve(a.profile_id)),
    'my_checkin', (select to_char(min(at) at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI') from public.attendance_events where profile_id = me and work_date = today and kind='in'),
    'my_checkout', (select to_char(max(at) at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI') from public.attendance_events where profile_id = me and work_date = today and kind='out'),
    'leave', public.leave_balance(me),
    'off_today', (select coalesce(jsonb_agg(jsonb_build_object('name', full_name, 'part', part)), '[]') from public.leave_board(today, today) where status = 'da_duyet'),
    'report_today', exists(select 1 from public.daily_reports where sale_id = me and report_date = today),
    'support_open', (select count(*) from public.support_requests where (assignee_id = me or requester_id = me) and status in ('moi','da_nhan','dang_xu_ly')),
    'news', (select coalesce(jsonb_agg(x order by x.pinned desc, x.publish_at desc), '[]') from (
              select a.id, a.title, a.pinned, a.publish_at, exists(select 1 from public.announcement_reads r where r.announcement_id = a.id and r.user_id = me) is_read
              from public.announcements a where app.announcement_visible(a) order by a.pinned desc, a.publish_at desc limit 5) x)
  );
  return r;
end $$;

-- ---------- Báo cáo CRM ----------
create or replace function public.crm_report(p_kind text, p_from date, p_to date, p_sale uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare tree uuid[] := case when p_sale is not null and app.in_tree(p_sale) then array[p_sale] else app.my_tree() end;
        t0 timestamptz := (p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'); t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh');
        adm boolean := app.is_admin() and p_sale is null;
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  if p_kind = 'funnel' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select app.name_of(c.owner_id) sale, c.stage, count(*) n from public.customers c
      where c.deleted_at is null and (adm or c.owner_id = any(tree)) group by 1, 2 order by 1, 2) x);
  elsif p_kind = 'quotes' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select app.name_of(q.sale_id) sale, q.status, count(*) n, sum(q.total_after_vat) value, sum(q.est_profit) profit
      from public.quotations q where q.created_at >= t0 and q.created_at < t1 and (adm or q.sale_id = any(tree)) group by 1, 2 order by 1, 2) x);
  elsif p_kind = 'reject_reasons' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select coalesce(l.label, q.reject_reason) reason, count(*) n from public.quotations q
      left join public.lookups l on l.category='reject_reason' and l.code = q.reject_reason
      where q.status = 'tu_choi' and q.updated_at >= t0 and q.updated_at < t1 and (adm or q.sale_id = any(tree)) group by 1 order by 2 desc) x);
  elsif p_kind = 'sources' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select coalesce(l.label, c.source) source, count(*) n, count(*) filter (where c.order_count > 0) won from public.customers c
      left join public.lookups l on l.category='source' and l.code = c.source
      where c.deleted_at is null and c.created_at >= t0 and c.created_at < t1 and (adm or c.owner_id = any(tree)) group by 1 order by 2 desc) x);
  elsif p_kind = 'retention' then
    return (select jsonb_build_object(
      'buyers', count(*) filter (where order_count >= 1),
      'repeat', count(*) filter (where order_count >= 2),
      'rate', round(100.0 * count(*) filter (where order_count >= 2) / nullif(count(*) filter (where order_count >= 1), 0), 1),
      'sleeping', count(*) filter (where stage = 'kho_ngu'),
      'lost', count(*) filter (where stage = 'mat_khach'))
      from public.customers where deleted_at is null and (adm or owner_id = any(tree)));
  elsif p_kind = 'care_due' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select app.name_of(owner_id) sale, count(*) filter (where next_care_date < app.vn_today()) overdue,
             count(*) filter (where next_care_date = app.vn_today()) today,
             count(*) filter (where last_contact_at < now() - interval '30 days' or last_contact_at is null) forgotten
      from public.customers where deleted_at is null and stage not in ('khong_tiem_nang','mat_khach') and (adm or owner_id = any(tree)) group by 1 order by 2 desc) x);
  elsif p_kind = 'reports' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select app.name_of(s.id) sale, count(r.*) submitted, count(r.*) filter (where r.on_time) on_time, app.kpi_days(p_from, least(p_to, app.vn_today())) days
      from public.profiles s left join public.daily_reports r on r.sale_id = s.id and r.report_date between p_from and p_to
      where s.status='active' and s.roles && array['sale','tn_kd','tp_kd'] and (adm or s.id = any(tree)) group by s.id order by 1) x);
  elsif p_kind = 'transfers' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select to_char(t.created_at at time zone 'Asia/Ho_Chi_Minh', 'DD/MM/YYYY HH24:MI') at, c.code, coalesce(c.company_name, c.contact_name) customer,
             app.name_of(t.from_id) from_sale, app.name_of(t.to_id) to_sale, t.reason, t.note, app.name_of(t.created_by) by
      from public.customer_transfers t join public.customers c on c.id = t.customer_id
      where t.created_at >= t0 and t.created_at < t1 and (adm or t.to_id = any(tree) or t.from_id = any(tree)) order by t.created_at desc) x);
  end if;
  raise exception 'Loại báo cáo không hợp lệ';
end $$;

-- ---------- Nhập danh sách KH đang chạy ----------
create or replace function public.import_company_customers(p_rows jsonb)
returns int language plpgsql security definer set search_path = public, app as $$
declare v_batch uuid := gen_random_uuid(); n int;
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  insert into public.company_customers(batch_id, ext_code, name, phone_norm, phone2_norm, tax_code, last_order_date, owner_text, note)
  select v_batch, r->>'ext_code', r->>'name', app.norm_phone(r->>'phone'), app.norm_phone(r->>'phone2'), app.norm_tax(r->>'tax_code'),
         nullif(r->>'last_order_date','')::date, r->>'owner_text', r->>'note'
  from jsonb_array_elements(p_rows) r;
  get diagnostics n = row_count;
  delete from public.company_customers where batch_id <> v_batch and imported_at < now() - interval '400 days';
  perform app.log('IMPORT', 'company_customers', v_batch::text, jsonb_build_object('rows', n));
  return n;
end $$;


-- >>>>> supabase/migrations/0005_rls.sql
-- =====================================================================
-- ERP Nam Trung · 0005 Row Level Security + quyền truy cập
-- Nguyên tắc: bảng nào cũng bật RLS; anon không đọc được gì.
-- =====================================================================
do $$ declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
grant usage on all sequences in schema public to authenticated;
revoke all on all tables in schema app from anon, authenticated;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated;

-- settings: ai đăng nhập cũng đọc được (không có secret); sửa qua RPC set_setting
create policy settings_read on public.settings for select to authenticated using (app.is_active());
create policy settings_hist on public.settings_history for select to authenticated using (app.is_admin());

-- tổ chức, cấp bậc, danh mục, tỷ giá, ngày lễ: đọc chung, sửa admin/hcns
create policy org_read on public.org_units for select to authenticated using (app.is_active());
create policy org_write on public.org_units for all to authenticated using (app.has_role('admin','bgd','hcns')) with check (app.has_role('admin','bgd','hcns'));
create policy lvl_read on public.job_levels for select to authenticated using (app.is_active());
create policy lvl_write on public.job_levels for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy lk_read on public.lookups for select to authenticated using (app.is_active());
create policy lk_write on public.lookups for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy fx_read on public.exchange_rates for select to authenticated using (app.is_active());
create policy fx_write on public.exchange_rates for insert to authenticated with check (app.has_role('admin','bgd','ke_toan'));
create policy hol_read on public.holidays for select to authenticated using (app.is_active());
create policy hol_write on public.holidays for all to authenticated using (app.has_role('admin','bgd','hcns')) with check (app.has_role('admin','bgd','hcns'));

-- hồ sơ nhân sự
create policy prof_read on public.profiles for select to authenticated
  using (id = auth.uid() or app.can_see_hr() or app.in_tree(id) or app.is_active());
create policy prof_update on public.profiles for update to authenticated
  using (id = auth.uid() or app.has_role('admin','bgd','hcns')) with check (id = auth.uid() or app.has_role('admin','bgd','hcns'));
create policy priv_read on public.profile_private for select to authenticated
  using (profile_id = auth.uid() or app.can_see_hr() or app.can_approve(profile_id));
create policy priv_write on public.profile_private for update to authenticated
  using (profile_id = auth.uid() or app.has_role('admin','bgd','hcns','ke_toan'))
  with check (profile_id = auth.uid() or app.has_role('admin','bgd','hcns','ke_toan'));
create policy priv_ins on public.profile_private for insert to authenticated with check (app.has_role('admin','bgd','hcns'));
-- nhân viên chỉ sửa được tài khoản ngân hàng/địa chỉ của mình, không sửa lương
create or replace function app.private_guard() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if auth.uid() is not null and not app.has_role('admin','bgd','hcns','ke_toan')
     and (new.base_salary, new.allowance, new.insurance_deduction) is distinct from (old.base_salary, old.allowance, old.insurance_deduction) then
    raise exception 'Không có quyền sửa lương';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger private_guard before update on public.profile_private for each row execute function app.private_guard();

create policy inv_all on public.invites for all to authenticated using (app.has_role('admin','bgd','hcns')) with check (app.has_role('admin','bgd','hcns'));
create policy del_read on public.delegations for select to authenticated using (delegator_id = auth.uid() or delegate_id = auth.uid() or app.is_admin());
create policy del_ins on public.delegations for insert to authenticated with check (delegator_id = auth.uid() or app.is_admin());
create policy del_upd on public.delegations for update to authenticated using (delegator_id = auth.uid() or app.is_admin());

create policy audit_read on public.audit_logs for select to authenticated using (app.is_admin() or (app.has_role('hcns') and table_name in ('profiles','profile_private','leave_requests','payslips','payslip_adjustments')));
create policy notif_own on public.notifications for select to authenticated using (recipient_id = auth.uid());
create policy notif_upd on public.notifications for update to authenticated using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
create policy tg_read on public.telegram_outbox for select to authenticated using (app.is_admin());

-- CRM
create policy cus_read on public.customers for select to authenticated using (deleted_at is null and (app.in_tree(owner_id) or app.is_admin()));
create policy cus_ins on public.customers for insert to authenticated with check (app.is_active() and app.has_role('admin','bgd','tp_kd','tn_kd','sale'));
create policy cus_upd on public.customers for update to authenticated using (app.in_tree(owner_id) or app.is_admin()) with check (app.in_tree(owner_id) or app.is_admin());
create policy care_read on public.care_logs for select to authenticated using (app.in_tree(sale_id) or app.is_admin()
  or exists(select 1 from public.customers c where c.id = customer_id and app.in_tree(c.owner_id)));
create policy care_ins on public.care_logs for insert to authenticated with check (app.is_active());
create policy care_upd on public.care_logs for update to authenticated using (sale_id = auth.uid());
create policy tr_read on public.customer_transfers for select to authenticated using (app.in_tree(from_id) or app.in_tree(to_id) or app.is_admin());
create policy cc_read on public.company_customers for select to authenticated using (app.is_admin());
create policy q_read on public.quotations for select to authenticated using (app.in_tree(sale_id) or app.is_admin());
create policy ql_read on public.quotation_lines for select to authenticated using (exists(select 1 from public.quotations q where q.id = quotation_id and (app.in_tree(q.sale_id) or app.is_admin())));
-- báo giá chỉ ghi qua RPC (save_quote...)
create policy sup_read on public.support_requests for select to authenticated using (requester_id = auth.uid() or assignee_id = auth.uid() or app.is_admin()
  or org_unit_id = (select org_unit_id from public.profiles where id = auth.uid()) or app.in_tree(requester_id));
create policy sup_ins on public.support_requests for insert to authenticated with check (requester_id = auth.uid());
create policy sup_upd on public.support_requests for update to authenticated using (requester_id = auth.uid() or assignee_id = auth.uid() or app.is_admin()
  or org_unit_id = (select org_unit_id from public.profiles where id = auth.uid()));
create policy supm_read on public.support_messages for select to authenticated using (exists(select 1 from public.support_requests r where r.id = request_id));
create policy supm_ins on public.support_messages for insert to authenticated with check (author_id = auth.uid() and exists(select 1 from public.support_requests r where r.id = request_id));
create policy dr_read on public.daily_reports for select to authenticated using (app.in_tree(sale_id) or app.is_admin());
create policy dr_ins on public.daily_reports for insert to authenticated with check (app.is_active());
create policy dr_upd on public.daily_reports for update to authenticated using (app.can_approve(sale_id));
create policy fb_read on public.fb_posts for select to authenticated using (app.in_tree(sale_id) or app.is_admin());
create policy fb_ins on public.fb_posts for insert to authenticated with check (sale_id = auth.uid());
create policy fb_upd on public.fb_posts for update to authenticated using (app.can_approve(sale_id));
create policy fb_del on public.fb_posts for delete to authenticated using (sale_id = auth.uid() and verified_at is null);

-- HRM
create policy att_read on public.attendance_events for select to authenticated using (profile_id = auth.uid() or app.in_tree(profile_id) or app.has_role('admin','bgd','hcns','ke_toan'));
create policy att_upd on public.attendance_events for update to authenticated using (app.has_role('admin','bgd','hcns') or app.can_approve(profile_id));
create policy attr_read on public.attendance_requests for select to authenticated using (profile_id = auth.uid() or app.in_tree(profile_id) or app.has_role('admin','bgd','hcns','ke_toan'));
create policy attr_ins on public.attendance_requests for insert to authenticated with check (profile_id = auth.uid());
create policy lv_read on public.leave_requests for select to authenticated using (profile_id = auth.uid() or app.in_tree(profile_id) or app.has_role('admin','bgd','hcns','ke_toan'));
create policy lv_ins on public.leave_requests for insert to authenticated with check (profile_id = auth.uid() or app.has_role('admin','bgd','hcns'));
create policy ll_read on public.leave_ledger for select to authenticated using (profile_id = auth.uid() or app.in_tree(profile_id) or app.can_see_hr());
create policy ll_ins on public.leave_ledger for insert to authenticated with check (app.has_role('admin','bgd','hcns') and kind in ('adjust','opening'));
create policy pp_read on public.payroll_periods for select to authenticated using (app.is_active());
create policy or_read on public.order_results for select to authenticated using (app.can_see_hr() or app.in_tree(profile_id));
create policy ps_read on public.payslips for select to authenticated using (profile_id = auth.uid() or app.can_see_hr() or app.can_approve(profile_id));
create policy pa_read on public.payslip_adjustments for select to authenticated using (exists(select 1 from public.payslips s where s.id = payslip_id));
create policy pa_write on public.payslip_adjustments for all to authenticated using (app.has_role('admin','bgd','hcns','ke_toan')) with check (app.has_role('admin','bgd','hcns','ke_toan'));

-- Tài liệu: Nhân viên/Thử việc không xem; Chuyên viên trở lên + Kế toán
create policy dc_read on public.doc_categories for select to authenticated using (app.is_admin() or app.my_rank() >= min_rank or app.my_roles() && extra_roles);
create policy dc_write on public.doc_categories for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy doc_read on public.documents for select to authenticated using (deleted_at is null and app.can_doc_category(category_id));
create policy doc_ins on public.documents for insert to authenticated with check (app.can_doc_category(category_id) and owner_id = auth.uid());
create policy doc_upd on public.documents for update to authenticated using (owner_id = auth.uid() or app.is_admin());
create policy dal_read on public.document_access_logs for select to authenticated using (app.is_admin());

-- Bảng tin, ticket
create policy an_read on public.announcements for select to authenticated using (app.announcement_visible(announcements));
create policy an_ins on public.announcements for insert to authenticated with check (app.is_active());
create policy an_upd on public.announcements for update to authenticated using (created_by = auth.uid() or app.is_admin());
create policy an_del on public.announcements for delete to authenticated using (created_by = auth.uid() or app.is_admin());
create policy ar_own on public.announcement_reads for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy tk_read on public.tickets for select to authenticated using (reporter_id = auth.uid() or assignee_id = auth.uid() or app.is_admin());
create policy tk_ins on public.tickets for insert to authenticated with check (reporter_id = auth.uid());
create policy tk_upd on public.tickets for update to authenticated using (assignee_id = auth.uid() or app.is_admin() or reporter_id = auth.uid());
create policy tc_read on public.ticket_comments for select to authenticated using (exists(select 1 from public.tickets t where t.id = ticket_id));
create policy tc_ins on public.ticket_comments for insert to authenticated with check (author_id = auth.uid() and exists(select 1 from public.tickets t where t.id = ticket_id));
create policy ks_read on public.kpi_snapshots for select to authenticated using (app.in_tree(profile_id) or app.can_see_hr());
create policy ka_read on public.kpi_adjustments for select to authenticated using (app.is_admin());
create policy ka_ins on public.kpi_adjustments for insert to authenticated with check (app.is_admin());

-- Báo giá/khách: chặn ghi trực tiếp các trường nhạy cảm của ticket người gửi
create or replace function app.ticket_guard() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() and auth.uid() <> coalesce(old.assignee_id, '00000000-0000-0000-0000-000000000000') then
    if (new.assignee_id, new.priority) is distinct from (old.assignee_id, old.priority) then raise exception 'Chỉ Admin phân công ticket'; end if;
    if new.status not in ('moi','dong') and new.status is distinct from old.status then raise exception 'Người gửi chỉ đóng được ticket'; end if;
  end if;
  if new.status = 'dong' and old.status <> 'dong' then new.closed_at := now(); end if;
  return new;
end $$;
create trigger ticket_guard before update on public.tickets for each row execute function app.ticket_guard();


-- >>>>> supabase/migrations/0006_jobs_storage.sql
-- =====================================================================
-- ERP Nam Trung · 0006 Tác vụ định kỳ (pg_cron) + Storage
-- =====================================================================

-- ---------- Tác vụ hằng ngày CRM: 05:00 giờ VN ----------
create or replace function app.job_daily_crm() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare n_sleep int; n_exp int; ndays int := coalesce(app.setting_num('crm','dormant_days'), 90)::int;
begin
  perform set_config('app.system', '1', true);
  update public.customers set stage = 'kho_ngu', next_care_date = app.suggest_next_care('kho_ngu', temperature)
   where deleted_at is null and stage in ('don_dau','hoat_dong','vip') and last_order_at < now() - make_interval(days => ndays);
  get diagnostics n_sleep = row_count;
  update public.quotations set status = 'het_han', updated_at = now()
   where status in ('da_gui','can_nhac') and valid_until + coalesce(app.setting_num('crm','quote_expire_grace_days'), 14)::int < app.vn_today();
  get diagnostics n_exp = row_count;
  perform set_config('app.system', '', true);
  insert into public.audit_logs(action, table_name, diff) values ('JOB', 'job_daily_crm', jsonb_build_object('kho_ngu', n_sleep, 'het_han', n_exp));
  return jsonb_build_object('kho_ngu', n_sleep, 'het_han', n_exp);
end $$;

-- ---------- Tóm tắt buổi sáng gửi Telegram: 09:00 giờ VN ----------
create or replace function app.job_morning() returns void
language plpgsql security definer set search_path = public, app as $$
declare today date := app.vn_today(); off text; nin int; nflag int; noverdue int; nq int;
begin
  if extract(isodow from today) = 7 then return; end if;
  select string_agg(p.full_name || case l.part when 'am' then ' (sáng)' when 'pm' then ' (chiều)' else '' end, ', ') into off
    from public.leave_requests l join public.profiles p on p.id = l.profile_id
   where l.status = 'da_duyet' and today between l.start_date and l.end_date;
  select count(distinct profile_id) into nin from public.attendance_events where work_date = today and kind = 'in';
  select count(*) into nflag from public.attendance_events where work_date = today and status = 'flagged';
  select count(*) into noverdue from public.customers where deleted_at is null and next_care_date < today and stage not in ('khong_tiem_nang','mat_khach');
  select count(*) into nq from public.quotations where status = 'cho_duyet';
  perform app.telegram('daily_summary', '☀️ <b>Tóm tắt sáng ' || to_char(today, 'DD/MM') || '</b>'
    || E'\nĐã chấm công vào: ' || nin || ' người' || case when nflag > 0 then ' · ⚠️ ' || nflag || ' lượt ngoài IP' else '' end
    || E'\nNghỉ hôm nay: ' || coalesce(app.esc(off), 'không có')
    || E'\nKhách quá hạn chăm: ' || noverdue || E'\nBáo giá chờ duyệt: ' || nq);
end $$;

-- ---------- Nhắc báo cáo ngày: 18:05 giờ VN ----------
create or replace function app.job_report_reminder() returns void
language plpgsql security definer set search_path = public, app as $$
declare today date := app.vn_today(); missing text;
begin
  if extract(isodow from today) = 7 then return; end if;
  select string_agg(p.full_name, ', ' order by p.full_name) into missing from public.profiles p
   where p.status = 'active' and p.roles && array['sale','tn_kd']
     and not exists(select 1 from public.daily_reports r where r.sale_id = p.id and r.report_date = today)
     and not exists(select 1 from public.leave_requests l where l.profile_id = p.id and l.status='da_duyet' and today between l.start_date and l.end_date and l.part='full');
  if missing is not null then
    perform app.telegram('report_missing', '📋 <b>Chưa nộp báo cáo ngày ' || to_char(today,'DD/MM') || '</b>' || E'\n' || app.esc(missing));
    insert into public.notifications(recipient_id, kind, title, link)
    select p.id, 'report', 'Bạn chưa nộp báo cáo ngày ' || to_char(today,'DD/MM'), '#/crm/daily' from public.profiles p
     where p.status = 'active' and p.roles && array['sale','tn_kd'] and not exists(select 1 from public.daily_reports r where r.sale_id = p.id and r.report_date = today);
  end if;
end $$;

-- ---------- Cộng phép tháng: ngày 1 hằng tháng ----------
create or replace function app.job_leave_accrue() returns int
language plpgsql security definer set search_path = public, app as $$
declare n int; m date := date_trunc('month', app.vn_today())::date;
begin
  insert into public.leave_ledger(profile_id, entry_date, kind, days, note)
  select p.id, m, 'accrue', coalesce(app.setting_num('leave','monthly_accrual'), 1), 'Cộng phép tháng ' || to_char(m - 1, 'MM/YYYY')
  from public.profiles p
  where p.status = 'active' and coalesce(p.job_level,'') <> 'thu_viec' and coalesce(p.hire_date, m - 40) <= m - 28
    and not exists(select 1 from public.leave_ledger l where l.profile_id = p.id and l.kind = 'accrue' and l.entry_date = m);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- Hủy phép năm cũ còn dư sau 30/06 ----------
create or replace function app.job_leave_expire() returns int
language plpgsql security definer set search_path = public, app as $$
declare y int := extract(year from app.vn_today())::int; n int;
begin
  insert into public.leave_ledger(profile_id, entry_date, kind, days, note)
  select profile_id, make_date(y, 7, 1), 'expire', -remain, 'Hủy phép năm ' || (y-1) || ' chưa dùng (hết 30/06)'
  from (
    select l.profile_id,
      greatest(0, sum(l.days) filter (where l.entry_date < make_date(y,1,1))
                + coalesce(sum(l.days) filter (where l.kind in ('use') and l.entry_date between make_date(y,1,1) and make_date(y,6,30)), 0)) remain
    from public.leave_ledger l group by l.profile_id
  ) x
  where remain > 0 and not exists(select 1 from public.leave_ledger e where e.profile_id = x.profile_id and e.kind = 'expire' and e.entry_date = make_date(y,7,1));
  get diagnostics n = row_count;
  return n;
end $$;

-- Lên lịch (giờ UTC = giờ VN − 7)
select cron.schedule('nt_daily_crm',       '0 22 * * *',   'select app.job_daily_crm()');
select cron.schedule('nt_morning',         '0 2 * * 1-6',  'select app.job_morning()');
select cron.schedule('nt_report_reminder', '5 11 * * 1-6', 'select app.job_report_reminder()');
select cron.schedule('nt_leave_accrue',    '10 0 1 * *',   'select app.job_leave_accrue()');
select cron.schedule('nt_leave_expire',    '20 0 1 7 *',   'select app.job_leave_expire()');

-- ---------- Storage ----------
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('selfies', 'selfies', false, 1048576, array['image/jpeg','image/webp','image/png']),
       ('docs', 'docs', false, 20971520, null)
on conflict (id) do nothing;

-- selfie: mỗi người chỉ ghi vào thư mục {uid}/...; HCNS/Admin/quản lý xem
create policy selfie_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'selfies' and (storage.foldername(name))[1] = auth.uid()::text);
create policy selfie_read on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and ((storage.foldername(name))[1] = auth.uid()::text
         or app.has_role('admin','bgd','hcns') or app.can_approve(((storage.foldername(name))[1])::uuid)));
create policy selfie_del on storage.objects for delete to authenticated
  using (bucket_id = 'selfies' and app.has_role('admin','bgd','hcns'));
-- tài liệu: thư mục {category_id}/...
create policy docs_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'docs' and app.can_doc_category(((storage.foldername(name))[1])::uuid));
create policy docs_read on storage.objects for select to authenticated
  using (bucket_id = 'docs' and app.can_doc_category(((storage.foldername(name))[1])::uuid));
create policy docs_del on storage.objects for delete to authenticated
  using (bucket_id = 'docs' and app.is_admin());


-- >>>>> supabase/migrations/0007_seed.sql
-- =====================================================================
-- ERP Nam Trung · 0007 Dữ liệu cấu hình ban đầu (giữ nguyên danh mục CRM)
-- =====================================================================

insert into public.job_levels(code, name, rank, base_salary, commission_pct, team_bonus_pct, is_sales) values
 ('thu_viec',    'Thử việc',        1,  6000000,  8, 0, true),
 ('nhan_vien',   'Nhân viên',       2,  7000000, 12, 0, true),
 ('chuyen_vien', 'Chuyên viên',     3,  8000000, 15, 0, true),
 ('truong_nhom', 'Trưởng nhóm',     4, 12000000, 17, 3, true),
 ('truong_phong','Trưởng phòng',    5, 18000000, 17, 3, true),
 ('giam_doc',    'Giám đốc',        6, 25000000, 17, 3, true)
on conflict (code) do nothing;

insert into public.org_units(id, name, kind, sort) values ('00000000-0000-0000-0000-000000000001', 'Công ty Nam Trung', 'cong_ty', 0) on conflict do nothing;
insert into public.org_units(parent_id, name, kind, sort)
select '00000000-0000-0000-0000-000000000001', x.name, 'phong', x.sort from (values
 ('Kinh doanh',1),('Kế toán',2),('CSKH',3),('XNK',4),('Điều vận',5),('Mua hàng',6),('Kho',7),('Marketing',8),('Hành chính nhân sự',9)) x(name, sort)
where not exists (select 1 from public.org_units o where o.name = x.name);

-- Giai đoạn (extra.cadence = nhịp chăm theo giai đoạn)
insert into public.lookups(category, code, label, sort, extra) values
 ('stage','moi','Mới - Chưa liên hệ',1,'{"cadence":1}'),
 ('stage','tiep_can','Đã tiếp cận',2,'{"cadence":3}'),
 ('stage','khai_thac','Khai thác nhu cầu',3,'{"cadence":3}'),
 ('stage','da_bao_gia','Đã gửi báo giá',4,'{"cadence":2}'),
 ('stage','dam_phan','Đàm phán - Chờ quyết định',5,'{"cadence":2}'),
 ('stage','don_dau','Khách mới (đơn đầu)',6,'{"cadence":3}'),
 ('stage','hoat_dong','Khách đang hoạt động',7,'{"cadence":7}'),
 ('stage','vip','Khách VIP',8,'{"cadence":5}'),
 ('stage','kho_ngu','Kho khách ngủ',9,'{"cadence":14}'),
 ('stage','mat_khach','Mất khách',10,'{"cadence":30}'),
 ('stage','khong_tiem_nang','Không tiềm năng',11,'{"cadence":null}'),
 ('temperature','nong','Nóng',1,'{"cadence":2}'),
 ('temperature','am','Ấm',2,'{"cadence":5}'),
 ('temperature','lanh','Lạnh',3,'{"cadence":14}'),
 ('channel','goi_dien','Gọi điện',1,null),('channel','zalo','Zalo',2,null),('channel','sms','SMS',3,null),
 ('channel','facebook','Facebook/Messenger',4,null),('channel','email','Email',5,null),('channel','gap_truc_tiep','Gặp trực tiếp',6,null),('channel','khac','Khác',7,null),
 ('care_purpose','tiep_can_lan_dau','Tiếp cận lần đầu',1,null),
 ('care_purpose','khai_thac_nhu_cau','Khai thác nhu cầu',2,null),
 ('care_purpose','gui_bao_gia','Gửi báo giá',3,null),
 ('care_purpose','theo_doi_bao_gia','Theo dõi báo giá',4,null),
 ('care_purpose','cham_soc_khach_cu','Chăm sóc khách cũ',5,null),
 ('care_purpose','sau_ban','Chăm sóc sau bán',6,null),
 ('care_purpose','nhac_dat_hang','Nhắc đặt hàng lại',7,null),
 ('care_purpose','khieu_nai','Xử lý phản ánh',8,null),
 ('care_purpose','khac','Khác',9,null),
 ('care_result','khong_nghe_may','Không nghe máy',1,'{"fail":true}'),
 ('care_result','sai_so','Thuê bao/Sai số',2,'{"fail":true}'),
 ('care_result','chua_phan_hoi','Đã nhắn - chưa phản hồi',3,'{"fail":true}'),
 ('care_result','ket_ban_zalo','Đã kết bạn Zalo',4,'{}'),
 ('care_result','co_quan_tam','Trao đổi được - có quan tâm',5,'{"stage":"khai_thac","temp":"am"}'),
 ('care_result','chua_nhu_cau','Trao đổi được - chưa có nhu cầu',6,'{"temp":"lanh"}'),
 ('care_result','dung_don_vi_khac','Đang dùng đơn vị khác',7,'{"temp":"lanh"}'),
 ('care_result','hen_goi_lai','Hẹn gọi lại',8,'{"temp":"am"}'),
 ('care_result','xin_bao_gia','Xin báo giá',9,'{"stage":"khai_thac","temp":"nong"}'),
 ('care_result','che_gia_cao','Chê giá cao',10,'{"stage":"dam_phan","temp":"am"}'),
 ('care_result','dong_y_chot','Đồng ý chốt đơn',11,'{"temp":"nong","hint":"Nhớ chuyển báo giá sang Đã chốt đơn"}'),
 ('care_result','phan_anh','Phản ánh/Khiếu nại',12,'{}'),
 ('care_result','hai_long','Hài lòng sau giao hàng',13,'{}'),
 ('care_result','tu_choi_han','Từ chối hẳn',14,'{"temp":"lanh"}'),
 ('customer_type','shop_tmdt','Shop TMĐT',1,null),('customer_type','shop_offline','Shop offline',2,null),
 ('customer_type','nha_buon','Nhà bán buôn',3,null),('customer_type','nha_may','Nhà máy/Xưởng sản xuất',4,null),
 ('customer_type','cong_ty_nk','Công ty nhập khẩu/Thương mại',5,null),('customer_type','sme','Doanh nghiệp SME',6,null),
 ('customer_type','co_so_sx','Cơ sở sản xuất nhỏ',7,null),('customer_type','ca_nhan','Cá nhân',8,null),('customer_type','dai_ly','Đối tác/Đại lý',9,null),
 ('source','tu_tim_zalo','Tự tìm - Zalo/Group',1,null),('source','tu_tim_fb','Tự tìm - Facebook',2,null),('source','tu_tim_khac','Tự tìm - Khác',3,null),
 ('source','marketing','Marketing (inbox/hotline)',4,null),('source','gioi_thieu','Khách giới thiệu',5,null),('source','cong_ty_giao','Công ty giao',6,null),
 ('source','kho_khach_ngu','Kho khách ngủ',7,null),('source','su_kien','Sự kiện/Hội chợ',8,null),('source','khac','Khác',9,null),
 ('import_method','tron_goi_cn','Trọn gói chính ngạch - Nam Trung xuất HĐ VAT',1,null),
 ('import_method','uy_thac','Ủy thác nhập khẩu',2,null),
 ('import_method','tu_dung_ten','KH tự đứng tên NK (thuê VC + khai HQ)',3,null),
 ('import_method','mua_ho','Chỉ mua hộ/thanh toán hộ',4,null),
 ('import_method','vc_khong_hd','Vận chuyển không hóa đơn',5,null),
 ('import_method','tieu_ngach','Tiểu ngạch (đang chuyển dịch)',6,null),
 ('import_method','chua_xac_dinh','Chưa xác định',7,null),
 ('legal_entity','ca_nhan','Cá nhân',1,null),('legal_entity','ho_kinh_doanh','Hộ kinh doanh',2,null),('legal_entity','doanh_nghiep','Doanh nghiệp',3,null),
 ('invoice_need','can_vat','Cần HĐ VAT',1,null),('invoice_need','khong_can','Không cần hóa đơn',2,null),('invoice_need','chua_ro','Chưa rõ',3,null),
 ('frequency','chua_ro','Chưa rõ',1,null),('frequency','hang_tuan','Hằng tuần',2,null),('frequency','hang_thang','Hằng tháng',3,null),('frequency','theo_mua','Theo mùa',4,null),('frequency','le','Lẻ tẻ',5,null),
 ('monthly_value','duoi_50','Dưới 50 triệu',1,null),('monthly_value','50_200','50-200 triệu',2,null),('monthly_value','200_500','200-500 triệu',3,null),
 ('monthly_value','500_1ty','500 triệu - 1 tỷ',4,null),('monthly_value','tren_1ty','Trên 1 tỷ',5,null),
 ('industry','thoi_trang','Thời trang - Phụ kiện',1,null),('industry','gia_dung','Gia dụng',2,null),('industry','dien_tu','Điện tử - Phụ kiện',3,null),
 ('industry','may_moc','Máy móc - Thiết bị',4,null),('industry','nguyen_lieu','Nguyên phụ liệu sản xuất',5,null),('industry','vpp','Văn phòng phẩm',6,null),
 ('industry','my_pham','Mỹ phẩm',7,null),('industry','do_choi','Đồ chơi',8,null),('industry','noi_that','Nội thất',9,null),('industry','khac','Khác',10,null),
 ('service','mua_ho','Mua hộ',1,null),('service','thanh_toan_ho','Thanh toán hộ',2,null),('service','nk_chinh_ngach','Nhập khẩu chính ngạch',3,null),
 ('service','nk_tieu_ngach','Nhập khẩu tiểu ngạch',4,null),('service','van_chuyen','Vận chuyển TQ-VN',5,null),('service','khai_hq','Khai báo hải quan',6,null),
 ('service','logistics','Logistics trọn gói',7,null),('service','tim_nguon','Tìm nguồn hàng',8,null),('service','ky_gui_cn','Ký gửi chính ngạch',9,null),('service','ky_gui_tn','Ký gửi TN',10,null),
 ('goods_trait','thong_thuong','Hàng thông thường',1,null),('goods_trait','hop_quy','Cần hợp quy/công bố',2,null),('goods_trait','kiem_dich','Kiểm dịch/ATTP',3,null),
 ('goods_trait','giay_phep','Cần giấy phép NK',4,null),('goods_trait','thuong_hieu','Hàng có thương hiệu',5,null),('goods_trait','mau_duoi_100kg','Hàng mẫu < 100kg',6,null),
 ('goods_trait','cong_kenh','Hàng cồng kềnh',7,null),('goods_trait','de_vo','Hàng dễ vỡ',8,null),
 ('reject_reason','gia_cao','Giá cao hơn đối thủ',1,null),('reject_reason','thoi_gian_vc','Thời gian vận chuyển',2,null),
 ('reject_reason','chua_tin','Chưa tin tưởng',3,null),('reject_reason','huy_ke_hoach','Hủy/đổi kế hoạch',4,null),
 ('reject_reason','don_vi_khac','Chọn đơn vị khác',5,null),('reject_reason','giay_phep','Vướng giấy phép',6,null),
 ('reject_reason','khong_phan_hoi','Không phản hồi',7,null),('reject_reason','khac','Khác',8,null),
 ('transfer_reason','nghi_viec','Sale nghỉ việc',1,null),('transfer_reason','can_tai','Cân tải',2,null),('transfer_reason','bo_be','Bỏ bê khách',3,null),
 ('transfer_reason','tu_nha','Sale tự nhả khách',4,null),('transfer_reason','phan_bo_kho_ngu','Phân bổ Kho khách ngủ',5,null),
 ('transfer_reason','chu_cu_dong_y','Chủ cũ đồng ý',6,null),('transfer_reason','khac','Khác',7,null),
 ('leave_type','phep_nam','Phép năm',1,'{"paid":true}'),
 ('leave_type','khong_luong','Nghỉ không lương',2,'{"paid":false}'),
 ('leave_type','om_dau','Nghỉ ốm (BHXH)',3,'{"paid":false}'),
 ('leave_type','che_do','Nghỉ chế độ (cưới, tang...) có lương',4,'{"paid":true}'),
 ('warehouse','HN','Kho Hà Nội',1,null),('warehouse','HCM','Kho HCM',2,null)
on conflict (category, code) do nothing;

insert into public.doc_categories(name, min_rank, sort) values
 ('Tờ khai hải quan',3,1),('Hóa đơn VAT',3,2),('Hợp đồng',3,3),('Hợp quy/Công bố',3,4),('Khác',3,9)
on conflict (name) do nothing;

insert into public.exchange_rates(rate_type, rate, note, created_by) values
 ('ban', 4015, 'Tỷ giá bán chuẩn ban đầu', null),
 ('san', 4015, 'Tỷ giá sàn (dưới mức này cần duyệt)', null),
 ('von', 3955, 'Tỷ giá vốn (dưới mức này cấm)', null);

insert into public.settings(key, value, description) values
 ('quote_defaults', '{"tyGia":4015,"phiDVPct":2,"phiUTPct":1,"vatPct":8,"donGiaKg":7000,"donGiaKhoi":1100000,"lamTron":1,"lamTronKieu":"gan","heSoToKhai":0.9425,"tyLeXuatMin":70,"tndnPct":20,"coSoThueNK":"toKhai","coSoUyThac":"giaXuat","phiUTSan":0.8,"phiDVSan":1.2,"giaVonKhoi":{"HN":800000,"HCM":1300000},"tyLeCoc":80,"hieuLuc":5}', 'Tham số mặc định báo giá'),
 ('crm', '{"company_active_days":60,"dormant_days":90,"quote_valid_days":5,"quote_expire_grace_days":14,"report_deadline_hour":18,"forgotten_days":30}', 'Tham số CRM'),
 ('kpi', '{"new_hire_factor":0.7,"metrics":{"kh_moi":{"label":"KH mới nhập hệ thống","day":15,"weight":15},"tiep_can":{"label":"Tiếp cận lần đầu","day":15,"weight":20},"ket_noi":{"label":"Kết nối thành công","day":6,"weight":20},"cham_cu":{"label":"Chăm sóc khách cũ","day":10,"weight":15},"bao_gia":{"label":"Báo giá gửi khách","day":1,"weight":10},"bai_fb":{"label":"Bài FB chính ngạch","day":2,"weight":10},"bao_cao":{"label":"Báo cáo ngày đúng hạn","day":1,"weight":10}}}', 'Chỉ tiêu KPI giai đoạn tích lũy'),
 ('attendance', '{"start":"08:00","end":"17:30","saturday_end":"12:00","lunch_start":"12:00","lunch_end":"13:30","saturday_value":0.5,"flex_minutes":100,"flex_start":"2026-11-01","forgot_limit":3,"ip_whitelist":[],"require_selfie":true,"selfie_retention_days":60}', 'Chấm công'),
 ('leave', '{"monthly_accrual":1,"annual_days":12,"carry_until":"06-30"}', 'Phép năm'),
 ('payroll', '{"commission_base_pct":60,"tiers":[[0,0],[30000000,3],[65000000,5],[100000000,7]],"loss_offset_max_pct":50}', 'Lương & hoa hồng'),
 ('company', '{"name":"CÔNG TY TNHH DỊCH VỤ VÀ THƯƠNG MẠI QUỐC TẾ NAM TRUNG","short":"Nam Trung","address":"Tòa G4, CC Five Star, 460 Khương Đình, Thanh Xuân, HN","hotline":"0859.59.1688","email":"info@namtrunglog.com","tax_code":"0108195040","website":"namtrunglog.com"}', 'Thông tin công ty in trên báo giá'),
 ('vietqr', '{"bank_bin":"970415","bank_name":"VietinBank - Hà Nội","account":"117634318888","holder":"CONG TY TNHH DV VA TM QUOC TE NAM TRUNG","template":"compact2"}', 'Tài khoản nhận tiền khách (QR báo giá)'),
 ('telegram', '{"enabled":false,"chat_id":"","events":["test","leave_request","attendance_flag","quote_approval","quote_won","support","ticket","announcement","payroll","daily_summary","report_missing"]}', 'Bot Telegram báo cho BGĐ')
on conflict (key) do nothing;

insert into app.secrets(key, value) values ('telegram_bot_token', '') on conflict do nothing;

-- Tài khoản quản trị đầu tiên: đăng ký bằng đúng email này sẽ có quyền Admin + BGĐ
insert into public.invites(email, full_name, roles, job_level) values
 ('namtrung20266@gmail.com', 'Giám đốc', '{admin,bgd}', 'giam_doc'),
 ('hatrieuphong93@gmail.com', 'Giám đốc', '{admin,bgd}', 'giam_doc')
on conflict (email) do nothing;


-- >>>>> supabase/migrations/0008_v2.sql
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


-- >>>>> supabase/migrations/0009_v3.sql
-- =====================================================================
-- 0009 · Bản 3: thông tin khách trong Hỗ trợ khách, hồ sơ nhân sự,
--        hợp đồng lao động, thỏa thuận riêng, giấy tờ nhân sự
-- =====================================================================

-- ---------- Hỗ trợ khách: người xử lý xem được thông tin + lịch sử khách ----------
create or replace function public.support_customer(p_req uuid)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare r public.support_requests; c public.customers; res jsonb;
begin
  select * into r from public.support_requests where id = p_req;
  if r.id is null or r.customer_id is null then return null; end if;
  if not (r.requester_id = auth.uid() or r.assignee_id = auth.uid() or app.is_admin() or app.in_tree(r.requester_id)
          or r.org_unit_id = (select org_unit_id from public.profiles where id = auth.uid())) then
    raise exception 'Không có quyền xem yêu cầu này';
  end if;
  select * into c from public.customers where id = r.customer_id;
  res := jsonb_build_object(
    'id', c.id, 'code', c.code, 'contact_name', c.contact_name, 'company_name', c.company_name, 'position', c.position,
    'phone', c.phone, 'zalo', c.zalo, 'email', c.email, 'tax_code', c.tax_code, 'province', c.province, 'address', c.address,
    'customer_type', c.customer_type, 'industry', c.industry, 'goods', c.goods, 'import_method', c.import_method,
    'current_provider', c.current_provider, 'monthly_value', c.monthly_value, 'stage', c.stage, 'temperature', c.temperature,
    'next_care_date', c.next_care_date, 'care_count', c.care_count, 'quote_count', c.quote_count, 'order_count', c.order_count,
    'note', c.note, 'owner_id', c.owner_id, 'owner_name', app.name_of(c.owner_id), 'services', c.services, 'goods_traits', c.goods_traits,
    'can_open', app.is_admin() or app.in_tree(c.owner_id),
    'care', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select cl.id, cl.created_at, cl.channel, cl.purpose, cl.result, cl.is_connected, cl.content, cl.stage_after, cl.temperature_after,
               cl.next_care_date, cl.quotation_code, app.name_of(cl.sale_id) sale_name
        from public.care_logs cl where cl.customer_id = c.id order by cl.created_at desc limit 30) x), '[]'),
    'quotes', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select q.id, q.code, q.version, q.status, q.total_after_vat, q.created_at, q.order_code
        from public.quotations q where q.customer_id = c.id and q.status <> 'da_thay_the' order by q.created_at desc limit 10) x), '[]'));
  return res;
end $$;
grant execute on function public.support_customer(uuid) to authenticated;

-- ---------- Hồ sơ nhân sự ----------
create or replace function app.is_hr_admin() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.has_role('admin','bgd','hcns') $$;

create table if not exists public.hr_records(
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  gender text check (gender in ('nam','nu','khac')),
  dob date,
  id_number text,               -- số CCCD
  id_issued_on date,
  id_issued_by text,
  permanent_address text,
  current_address text,
  personal_email text,
  personal_tax_code text,
  social_insurance_no text,
  marital_status text,
  dependants int not null default 0,
  education text,
  major text,
  school text,
  emergency_name text,
  emergency_relation text,
  emergency_phone text,
  position_title text,
  employment_status text not null default 'chinh_thuc' check (employment_status in ('thu_viec','chinh_thuc','ctv','thoi_vu','nghi_viec')),
  probation_from date,
  probation_to date,
  official_date date,
  leave_date date,
  leave_reason text,
  note text,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.hr_contracts(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  contract_no text,
  contract_type text not null check (contract_type in ('thu_viec','xac_dinh','khong_xac_dinh','ctv','thoi_vu','phu_luc')),
  title text,
  position_title text,
  start_date date not null,
  end_date date,
  base_salary numeric(18,0),
  insurance_salary numeric(18,0),
  allowance numeric(18,0),
  status text not null default 'hieu_luc' check (status in ('nhap','hieu_luc','het_han','thanh_ly')),
  signed_on date,
  file_path text,
  note text,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists hr_contracts_profile on public.hr_contracts(profile_id, start_date desc);

create table if not exists public.hr_agreements(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'khac' check (kind in ('luong_thuong','hoa_hong','phu_cap','cam_ket','dao_tao','bao_mat','khac')),
  title text not null,
  content text,
  amount numeric(18,0),
  effective_from date,
  effective_to date,
  confidential boolean not null default true,   -- chỉ BGĐ/Admin + chính chủ xem
  file_path text,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists hr_agreements_profile on public.hr_agreements(profile_id);

create table if not exists public.hr_documents(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  doc_type text not null,
  title text,
  file_path text not null,
  file_name text,
  note text,
  uploaded_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists hr_documents_profile on public.hr_documents(profile_id);

insert into public.lookups(category, code, label, sort, extra) values
 ('hr_doc','cccd','CCCD 2 mặt',1,'{"required":true}'),
 ('hr_doc','so_yeu_ly_lich','Sơ yếu lý lịch',2,'{"required":true}'),
 ('hr_doc','bang_cap','Bằng cấp / chứng chỉ',3,'{"required":true}'),
 ('hr_doc','kham_suc_khoe','Giấy khám sức khỏe',4,'{"required":true}'),
 ('hr_doc','anh_the','Ảnh thẻ 3x4',5,'{"required":true}'),
 ('hr_doc','giay_khai_sinh','Giấy khai sinh',6,'{"required":false}'),
 ('hr_doc','so_bhxh','Sổ BHXH / tờ rời',7,'{"required":false}'),
 ('hr_doc','hop_dong_ky','Hợp đồng đã ký (bản scan)',8,'{"required":false}'),
 ('hr_doc','quyet_dinh','Quyết định (bổ nhiệm, tăng lương, kỷ luật…)',9,'{"required":false}'),
 ('hr_doc','khac','Giấy tờ khác',10,'{"required":false}')
on conflict (category, code) do nothing;

-- updated_at + audit
create or replace function app.touch_updated() returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists hr_records_touch on public.hr_records;
create trigger hr_records_touch before update on public.hr_records for each row execute function app.touch_updated();
drop trigger if exists hr_contracts_touch on public.hr_contracts;
create trigger hr_contracts_touch before update on public.hr_contracts for each row execute function app.touch_updated();
drop trigger if exists hr_agreements_touch on public.hr_agreements;
create trigger hr_agreements_touch before update on public.hr_agreements for each row execute function app.touch_updated();
drop trigger if exists audit_hr_records on public.hr_records;
create trigger audit_hr_records after insert or update or delete on public.hr_records for each row execute function app.audit();
drop trigger if exists audit_hr_contracts on public.hr_contracts;
create trigger audit_hr_contracts after insert or update or delete on public.hr_contracts for each row execute function app.audit();
drop trigger if exists audit_hr_agreements on public.hr_agreements;
create trigger audit_hr_agreements after insert or update or delete on public.hr_agreements for each row execute function app.audit();

-- Hợp đồng ký mới: cập nhật tình trạng làm việc + báo chính chủ
create or replace function app.hr_contract_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' and new.status = 'hieu_luc' then
    insert into public.hr_records(profile_id) values (new.profile_id) on conflict do nothing;
    update public.hr_records set
      employment_status = case new.contract_type when 'thu_viec' then 'thu_viec' when 'ctv' then 'ctv' when 'thoi_vu' then 'thoi_vu' when 'phu_luc' then employment_status else 'chinh_thuc' end,
      probation_from = case when new.contract_type = 'thu_viec' then new.start_date else probation_from end,
      probation_to = case when new.contract_type = 'thu_viec' then new.end_date else probation_to end,
      official_date = case when new.contract_type in ('xac_dinh','khong_xac_dinh') then coalesce(official_date, new.start_date) else official_date end,
      position_title = coalesce(new.position_title, position_title)
    where profile_id = new.profile_id;
    perform app.notify(new.profile_id, 'hr', 'Hợp đồng mới: ' || coalesce(new.contract_no, new.title, ''), 'Hiệu lực từ ' || to_char(new.start_date, 'DD/MM/YYYY'), '#/hr/staff');
  end if;
  return new;
end $$;
drop trigger if exists hr_contract_after on public.hr_contracts;
create trigger hr_contract_after after insert on public.hr_contracts for each row execute function app.hr_contract_after();

-- RLS
alter table public.hr_records enable row level security;
alter table public.hr_contracts enable row level security;
alter table public.hr_agreements enable row level security;
alter table public.hr_documents enable row level security;
drop policy if exists hrr_read on public.hr_records;
create policy hrr_read on public.hr_records for select to authenticated using (profile_id = auth.uid() or app.is_hr_admin());
drop policy if exists hrr_write on public.hr_records;
create policy hrr_write on public.hr_records for all to authenticated using (app.is_hr_admin()) with check (app.is_hr_admin());
drop policy if exists hrc_read on public.hr_contracts;
create policy hrc_read on public.hr_contracts for select to authenticated using (profile_id = auth.uid() or app.is_hr_admin());
drop policy if exists hrc_write on public.hr_contracts;
create policy hrc_write on public.hr_contracts for all to authenticated using (app.is_hr_admin()) with check (app.is_hr_admin());
drop policy if exists hra_read on public.hr_agreements;
create policy hra_read on public.hr_agreements for select to authenticated
  using (profile_id = auth.uid() or app.has_role('admin','bgd') or (app.has_role('hcns') and not confidential));
drop policy if exists hra_write on public.hr_agreements;
create policy hra_write on public.hr_agreements for all to authenticated
  using (app.has_role('admin','bgd') or (app.has_role('hcns') and not confidential))
  with check (app.has_role('admin','bgd') or (app.has_role('hcns') and not confidential));
drop policy if exists hrd_read on public.hr_documents;
create policy hrd_read on public.hr_documents for select to authenticated using (profile_id = auth.uid() or app.is_hr_admin());
drop policy if exists hrd_write on public.hr_documents;
create policy hrd_write on public.hr_documents for all to authenticated using (app.is_hr_admin()) with check (app.is_hr_admin());
grant select, insert, update, delete on public.hr_records, public.hr_contracts, public.hr_agreements, public.hr_documents to authenticated;

-- Tổng hợp danh sách hồ sơ cho HCNS
create or replace function public.hr_overview()
returns table(profile_id uuid, employment_status text, position_title text, official_date date, probation_to date,
              contract_type text, contract_end date, contract_status text, docs_have text[], docs_missing int, agreements int)
language sql stable security definer set search_path = public, app as $$
  select p.id, coalesce(r.employment_status, case when p.status = 'inactive' then 'nghi_viec' else 'chinh_thuc' end), r.position_title, r.official_date, r.probation_to,
         c.contract_type, c.end_date, c.status,
         coalesce((select array_agg(distinct d.doc_type) from public.hr_documents d where d.profile_id = p.id), '{}'),
         (select count(*) from public.lookups l where l.category = 'hr_doc' and l.active and (l.extra->>'required')::boolean
            and not exists (select 1 from public.hr_documents d where d.profile_id = p.id and d.doc_type = l.code))::int,
         (select count(*) from public.hr_agreements a where a.profile_id = p.id and (a.effective_to is null or a.effective_to >= app.vn_today()))::int
  from public.profiles p
  left join public.hr_records r on r.profile_id = p.id
  left join lateral (select * from public.hr_contracts k where k.profile_id = p.id and k.status in ('hieu_luc','het_han') and k.contract_type <> 'phu_luc'
                     order by k.start_date desc limit 1) c on true
  where app.is_hr_admin()
$$;
grant execute on function public.hr_overview() to authenticated;

-- Nhắc hợp đồng sắp hết hạn (30 và 7 ngày) + tự chuyển hết hạn
create or replace function app.job_contract_expiry() returns void
language plpgsql security definer set search_path = public, app as $$
declare k record; t date := app.vn_today();
begin
  update public.hr_contracts set status = 'het_han' where status = 'hieu_luc' and end_date < t;
  for k in select c.*, app.name_of(c.profile_id) nm from public.hr_contracts c
           where c.status = 'hieu_luc' and c.end_date in (t + 30, t + 7) loop
    perform app.notify(p.id, 'hr', 'Hợp đồng sắp hết hạn: ' || k.nm, 'Hết hạn ' || to_char(k.end_date, 'DD/MM/YYYY') || ' (còn ' || (k.end_date - t) || ' ngày)', '#/hr/staff?id=' || k.profile_id)
      from public.profiles p where p.status = 'active' and p.roles && array['hcns','admin'];
    perform app.telegram('hr', '📄 Hợp đồng của <b>' || app.esc(k.nm) || '</b> hết hạn ' || to_char(k.end_date, 'DD/MM/YYYY') || ' (còn ' || (k.end_date - t) || ' ngày)');
  end loop;
end $$;
select cron.schedule('nt_contract_expiry', '15 1 * * *', 'select app.job_contract_expiry()');

-- Kho giấy tờ nhân sự: thư mục {profile_id}/...
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('hr', 'hr', false, 15728640, null) on conflict (id) do nothing;
drop policy if exists hr_obj_ins on storage.objects;
create policy hr_obj_ins on storage.objects for insert to authenticated with check (bucket_id = 'hr' and app.is_hr_admin());
drop policy if exists hr_obj_read on storage.objects;
create policy hr_obj_read on storage.objects for select to authenticated
  using (bucket_id = 'hr' and (app.is_hr_admin() or (storage.foldername(name))[1] = auth.uid()::text));
drop policy if exists hr_obj_del on storage.objects;
create policy hr_obj_del on storage.objects for delete to authenticated using (bucket_id = 'hr' and app.is_hr_admin());

-- Bật sự kiện Telegram 'hr' (nhắc hợp đồng) cho cấu hình đang có
update public.settings set value = jsonb_set(value, '{events}', coalesce(value->'events', '[]'::jsonb) || '"hr"'::jsonb)
 where key = 'telegram' and not coalesce(value->'events', '[]'::jsonb) ? 'hr';


-- >>>>> supabase/migrations/0010_v4.sql
-- =====================================================================
-- 0010 · Bản 4: KPI cấu hình đầy đủ, màn hình đăng nhập tích cực,
--        mã KH hệ thống + đồng bộ/nhập khách, kho báo giá tham khảo,
--        nhập dữ liệu báo giá cũ, tồn kho + cảnh báo trùng hàng
-- =====================================================================
create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;
grant usage on schema extensions to authenticated, anon;
set search_path = public, app, extensions;

-- Chuẩn hóa tên hàng: bỏ dấu, chữ thường, gộp khoảng trắng
create or replace function app.norm_text(t text) returns text
language sql immutable parallel safe set search_path = public, extensions, pg_catalog as $$
  select btrim(regexp_replace(lower(unaccent('unaccent'::regdictionary, coalesce(t, ''))), '[^a-z0-9]+', ' ', 'g'))
$$;

-- ---------- 1. KPI: đưa chỉ số cuộc gọi / tin nhắn có nhật ký vào cấu hình ----------
update public.settings set value = jsonb_set(value, '{metrics}',
  coalesce(value->'metrics', '{}'::jsonb)
  || case when value->'metrics' ? 'cuoc_goi_nhat_ky' then '{}'::jsonb else '{"cuoc_goi_nhat_ky":{"label":"Cuộc gọi có ghi nhật ký","day":10,"weight":0}}'::jsonb end
  || case when value->'metrics' ? 'tin_nhan_nhat_ky' then '{}'::jsonb else '{"tin_nhan_nhat_ky":{"label":"Tin nhắn có ghi nhật ký","day":10,"weight":0}}'::jsonb end)
 where key = 'kpi';

-- ---------- 2. Màn hình đăng nhập ----------
insert into public.settings(key, value, description) values ('login_screen', jsonb_build_object(
  'headlines', jsonb_build_array('Chào ngày mới, chiến binh Nam Trung!', 'Hôm nay mình chốt đơn thật đẹp nhé!', 'Mỗi cuộc gọi là một cơ hội.', 'Cùng nhau đi xa hơn.', 'Khách hài lòng, mình hạnh phúc.'),
  'messages', jsonb_build_array(
    'Thành công không phải là đích đến, mà là hành trình mỗi ngày bạn bước tiếp.',
    'Một lời cảm ơn chân thành có thể giữ chân khách hàng cả đời.',
    'Bạn đã làm rất tốt — hôm nay hãy làm tốt hơn hôm qua một chút thôi.',
    'Khách hàng nhớ cách bạn khiến họ cảm thấy, hơn là những gì bạn nói.',
    'Gieo một cuộc gọi, gặt một cơ hội.',
    '“Người đi nhiều, đường thành lối” — cứ bước, đường sẽ mở.',
    'Mỗi lời từ chối đưa bạn gần hơn tới một lời đồng ý.',
    'Cảm ơn bạn đã là một phần của Nam Trung.',
    'Nụ cười của bạn khi gọi điện, khách hàng nghe thấy được đấy!',
    'Không có việc gì khó, chỉ sợ lòng không bền.',
    'Đi một mình thì nhanh, đi cùng nhau thì xa.',
    'Làm việc chăm chỉ trong im lặng, để thành công lên tiếng.',
    'Hôm nay là ngày tuyệt vời để chốt một đơn hàng tuyệt vời.',
    'Kiên nhẫn là chìa khóa mở mọi cánh cửa.',
    'Bạn mạnh mẽ hơn bạn nghĩ, và giỏi hơn bạn tưởng.',
    'Một hành động nhỏ hôm nay, một thay đổi lớn ngày mai.',
    'Chăm sóc khách như chăm một cái cây — đều đặn sẽ ra quả ngọt.',
    'Đồng đội tốt là món quà quý nhất ở nơi làm việc.',
    'Hãy tự hào về những gì bạn đã làm được tuần này.',
    'Có công mài sắt, có ngày nên kim.',
    'Thái độ quyết định độ cao.',
    'Giữ lửa đam mê, mọi việc sẽ nhẹ nhàng hơn.',
    'Uống đủ nước, hít thở sâu, rồi gọi cuộc gọi đầu tiên nào!',
    'Bạn là lý do khách hàng quay lại.',
    'Mỗi ngày học một điều mới, một năm thành người khác.',
    '“Muốn đi nhanh hãy đi một mình, muốn đi xa hãy đi cùng nhau.”',
    'Hôm nay đừng quên khen một đồng nghiệp nhé.',
    'Chất lượng dịch vụ là lợi thế không ai sao chép được.',
    'Dữ liệu tốt hôm nay, quyết định đúng ngày mai.',
    'Cảm ơn vì đã cố gắng — mọi nỗ lực đều được ghi nhận.'),
  'cards', jsonb_build_array(
    jsonb_build_object('emoji','🏆','name','Chiến binh tuần','sub','Phòng Kinh doanh','tag','Chốt đơn đẹp','tag2','Tuần này','color','sun'),
    jsonb_build_object('emoji','💜','name','Khách hàng khen','sub','“Dịch vụ rất chu đáo”','tag','5 sao','tag2','Hôm qua','color','mint'),
    jsonb_build_object('emoji','🚚','name','Đội Kho vận','sub','Giao hàng đúng hẹn','tag','Tuyệt vời','tag2','Cả tuần','color','aqua')),
  'image', null
), 'Nội dung màn hình đăng nhập (câu chào, lời chúc, thẻ tích cực)') on conflict (key) do nothing;

create or replace function public.login_content() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select value from public.settings where key = 'login_screen'), '{}'::jsonb)
$$;
grant execute on function public.login_content() to anon, authenticated;

create or replace function public.set_login_screen(p_value jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.has_role('admin','bgd','hcns') then raise exception 'Không có quyền sửa màn hình đăng nhập'; end if;
  insert into public.settings(key, value) values ('login_screen', p_value) on conflict (key) do update set value = excluded.value;
end $$;
grant execute on function public.set_login_screen(jsonb) to authenticated;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('branding', 'branding', true, 5242880, array['image/jpeg','image/png','image/webp','image/gif']) on conflict (id) do nothing;
drop policy if exists brand_ins on storage.objects;
create policy brand_ins on storage.objects for insert to authenticated with check (bucket_id = 'branding' and app.has_role('admin','bgd','hcns'));
drop policy if exists brand_read on storage.objects;
create policy brand_read on storage.objects for select using (bucket_id = 'branding');
drop policy if exists brand_del on storage.objects;
create policy brand_del on storage.objects for delete to authenticated using (bucket_id = 'branding' and app.has_role('admin','bgd','hcns'));

-- ---------- 3. Mã KH hệ thống + đồng bộ từ hệ thống đơn hàng ----------
alter table public.customers add column if not exists sys_code text;
alter table public.customers add column if not exists sys_last_order_date date;
alter table public.customers add column if not exists sys_order_count int;
alter table public.customers add column if not exists sys_revenue numeric(18,0);
alter table public.customers add column if not exists sys_synced_at timestamptz;
create unique index if not exists customers_sys_code_uq on public.customers (upper(btrim(sys_code))) where sys_code is not null and deleted_at is null;

create or replace function app.customers_sys_before() returns trigger language plpgsql as $$
begin
  new.sys_code := nullif(upper(btrim(new.sys_code)), '');
  return new;
end $$;
drop trigger if exists customers_sys_before on public.customers;
create trigger customers_sys_before before insert or update of sys_code on public.customers for each row execute function app.customers_sys_before();

-- Nhập / đồng bộ khách hàng. Mỗi dòng: sys_code, phone, zalo, tax_code, contact_name, company_name, customer_type, source,
-- industry, goods, province, address, note, sale (tên/email/mã NV), days_no_order, last_order_date, order_count, revenue
create or replace function public.import_customers(p_rows jsonb, p_create boolean default false)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare r jsonb; i int := 0; c record; v_owner uuid; v_last date; v_phone text; v_tax text; v_id uuid;
        n_upd int := 0; n_new int := 0; n_skip int := 0; errs jsonb := '[]'; v_type text; v_src text;
begin
  if not app.has_role('admin','bgd','tp_kd') then raise exception 'Chỉ Admin, BGĐ, Trưởng phòng KD được nhập dữ liệu khách'; end if;
  perform set_config('app.system', '1', true);
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    begin
      v_phone := app.norm_phone(nullif(r->>'phone', '')); v_tax := app.norm_tax(nullif(r->>'tax_code', ''));
      v_last := coalesce(nullif(r->>'last_order_date', '')::date,
                         case when nullif(r->>'days_no_order', '') is not null then app.vn_today() - round((r->>'days_no_order')::numeric)::int end);
      select * into c from public.customers cu where cu.deleted_at is null and (
          (nullif(btrim(r->>'sys_code'), '') is not null and upper(btrim(cu.sys_code)) = upper(btrim(r->>'sys_code')))
       or (v_phone is not null and v_phone in (cu.phone_norm, cu.zalo_norm))
       or (v_tax is not null and v_tax = cu.tax_code))
       order by (upper(btrim(cu.sys_code)) = upper(btrim(r->>'sys_code'))) desc nulls last limit 1;
      if c.id is not null then
        update public.customers set
          sys_code = coalesce(nullif(btrim(r->>'sys_code'), ''), sys_code),
          sys_last_order_date = coalesce(v_last, sys_last_order_date),
          sys_order_count = coalesce(nullif(r->>'order_count', '')::numeric::int, sys_order_count),
          sys_revenue = coalesce(nullif(r->>'revenue', '')::numeric, sys_revenue),
          sys_synced_at = now(),
          last_order_at = greatest(last_order_at, (v_last::timestamp at time zone 'Asia/Ho_Chi_Minh'))
        where id = c.id;
        n_upd := n_upd + 1;
      elsif p_create then
        if coalesce(r->>'contact_name', r->>'company_name', '') = '' or (v_phone is null and nullif(r->>'zalo','') is null) then
          raise exception 'Thiếu tên hoặc số điện thoại';
        end if;
        v_owner := null;
        if nullif(r->>'sale', '') is not null then
          select p.id into v_owner from public.profiles p
           where p.status = 'active' and (lower(p.email) = lower(btrim(r->>'sale')) or upper(p.employee_code) = upper(btrim(r->>'sale'))
              or app.norm_text(p.full_name) = app.norm_text(r->>'sale') or app.norm_text(r->>'sale') = any(select app.norm_text(x) from unnest(p.sale_aliases) x))
           limit 1;
        end if;
        v_type := coalesce((select code from public.lookups where category = 'customer_type' and (code = r->>'customer_type' or app.norm_text(label) = app.norm_text(r->>'customer_type')) limit 1),
                           (select code from public.lookups where category = 'customer_type' and active order by sort limit 1));
        v_src := coalesce((select code from public.lookups where category = 'source' and (code = r->>'source' or app.norm_text(label) = app.norm_text(r->>'source')) limit 1), 'du_lieu_cu');
        insert into public.customers(contact_name, company_name, phone, zalo, tax_code, email, customer_type, source, industry, goods, province, address, note,
                                     owner_id, created_by, sys_code, sys_last_order_date, sys_order_count, sys_revenue, sys_synced_at, last_order_at, stage)
        values (coalesce(nullif(r->>'contact_name', ''), r->>'company_name'), nullif(r->>'company_name', ''), nullif(r->>'phone', ''), nullif(r->>'zalo', ''), nullif(r->>'tax_code', ''),
                nullif(r->>'email', ''), v_type, v_src,
                (select code from public.lookups where category = 'industry' and (code = r->>'industry' or app.norm_text(label) = app.norm_text(r->>'industry')) limit 1),
                nullif(r->>'goods', ''), nullif(r->>'province', ''), nullif(r->>'address', ''), nullif(r->>'note', ''),
                coalesce(v_owner, auth.uid()), auth.uid(), nullif(btrim(r->>'sys_code'), ''), v_last, nullif(r->>'order_count', '')::numeric::int, nullif(r->>'revenue', '')::numeric,
                now(), (v_last::timestamp at time zone 'Asia/Ho_Chi_Minh'),
                case when v_last is null then 'moi' when v_last >= app.vn_today() - coalesce((app.setting('crm')->>'dormant_days')::int, 60) then 'hoat_dong' else 'kho_ngu' end)
        returning id into v_id;
        n_new := n_new + 1;
      else
        n_skip := n_skip + 1;
        if jsonb_array_length(errs) < 200 then errs := errs || jsonb_build_object('row', i, 'msg', 'Không tìm thấy khách khớp mã / SĐT / MST'); end if;
      end if;
    exception when others then
      n_skip := n_skip + 1;
      if jsonb_array_length(errs) < 200 then errs := errs || jsonb_build_object('row', i, 'msg', sqlerrm); end if;
    end;
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('IMPORT', 'customers', jsonb_build_object('updated', n_upd, 'created', n_new, 'skipped', n_skip));
  return jsonb_build_object('updated', n_upd, 'created', n_new, 'skipped', n_skip, 'errors', errs);
end $$;
grant execute on function public.import_customers(jsonb, boolean) to authenticated;

insert into public.lookups(category, code, label, sort) values ('source', 'du_lieu_cu', 'Dữ liệu cũ (nhập file)', 99) on conflict do nothing;

-- ---------- 4. Kho báo giá tham khảo + dữ liệu báo giá cũ ----------
create table if not exists public.quote_archive(
  id uuid primary key default gen_random_uuid(),
  src_code text,
  quote_date date,
  item_name text not null,
  name_norm text generated always as (app.norm_text(item_name)) stored,
  hs_code text,
  unit text,
  qty numeric(18,3),
  price_cny numeric(18,4),
  duty_pct numeric(7,4),
  vat_pct numeric(7,4),
  export_price numeric(18,2),
  rate numeric(12,2),
  import_method text,
  warehouse text,
  freight text,
  sale_name text,
  note text,
  imported_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists quote_archive_trgm on public.quote_archive using gin (name_norm gin_trgm_ops);
alter table public.quote_archive enable row level security;
drop policy if exists qa_read on public.quote_archive;
create policy qa_read on public.quote_archive for select to authenticated using (app.is_active());
drop policy if exists qa_write on public.quote_archive;
create policy qa_write on public.quote_archive for all to authenticated using (app.has_role('admin','bgd','tp_kd')) with check (app.has_role('admin','bgd','tp_kd'));
grant select, insert, update, delete on public.quote_archive to authenticated;

alter table public.quotation_lines add column if not exists name_norm text generated always as (app.norm_text(name)) stored;
create index if not exists quotation_lines_trgm on public.quotation_lines using gin (name_norm gin_trgm_ops);

-- Tra cứu toàn bộ dòng hàng đã báo giá (không lộ thông tin khách) — ai đang làm việc cũng xem được
create or replace function public.quote_library(p_q text default null, p_source text default null, p_limit int default 100, p_offset int default 0)
returns table(source text, code text, quote_date date, status text, item_name text, hs_code text, unit text, qty numeric, price_cny numeric,
              duty_pct numeric, vat_pct numeric, export_price numeric, rate numeric, import_method text, warehouse text, freight text, sale_name text, score real, total bigint)
language plpgsql stable security definer set search_path = public, app, extensions as $$
declare q text := app.norm_text(p_q);
begin
  if not app.is_active() then raise exception 'Không có quyền'; end if;
  return query
  with s as (
    select 'he_thong'::text src, qt.code || case when qt.version > 1 then '-v' || qt.version else '' end cd, (qt.created_at at time zone 'Asia/Ho_Chi_Minh')::date dt, qt.status st,
           l.name nm, l.hs_code hs, l.unit un, l.qty qy, l.unit_price_cny pc, l.duty_pct dp, coalesce(l.vat_pct, (qt.header->>'vatPct')::numeric) vp,
           (l.computed->>'giaXuat')::numeric ep, (qt.header->>'tyGia')::numeric rt, qt.header->>'hinhThucNK' im, qt.header->>'khoNhan' wh,
           nullif(concat_ws(' · ', case when (qt.header->>'donGiaKg')::numeric > 0 then to_char((qt.header->>'donGiaKg')::numeric, 'FM999G999G999') || 'đ/kg' end,
                                   case when (qt.header->>'donGiaKhoi')::numeric > 0 then to_char((qt.header->>'donGiaKhoi')::numeric, 'FM999G999G999') || 'đ/m³' end), '') fr,
           app.name_of(qt.sale_id) sn, l.name_norm nn
      from public.quotation_lines l join public.quotations qt on qt.id = l.quotation_id
     where qt.status not in ('da_thay_the')
    union all
    select 'luu_tru', a.src_code, a.quote_date, null, a.item_name, a.hs_code, a.unit, a.qty, a.price_cny, a.duty_pct, a.vat_pct, a.export_price, a.rate, a.import_method,
           a.warehouse, a.freight, a.sale_name, a.name_norm
      from public.quote_archive a
  ), f as (
    select s.*, case when q = '' then 1::real else greatest(similarity(s.nn, q), word_similarity(q, s.nn)) end sc
      from s where (p_source is null or s.src = p_source)
       and (q = '' or s.nn like '%' || q || '%' or s.hs like p_q || '%' or word_similarity(q, s.nn) >= 0.45)
  )
  select f.src, f.cd, f.dt, f.st, f.nm, f.hs, f.un, f.qy, f.pc, f.dp, f.vp, f.ep, f.rt, f.im, f.wh, f.fr, f.sn, f.sc, count(*) over ()
    from f order by f.sc desc, f.dt desc nulls last limit greatest(1, least(p_limit, 2000)) offset greatest(p_offset, 0);
end $$;
grant execute on function public.quote_library(text, text, int, int) to authenticated;

-- ---------- 5. Tồn kho + cảnh báo trùng hàng khi báo giá ----------
create table if not exists public.inventory_items(
  id uuid primary key default gen_random_uuid(),
  sku text,
  name text not null,
  name_norm text generated always as (app.norm_text(name)) stored,
  unit text,
  qty numeric(18,3),
  warehouse text,
  note text,
  updated_at timestamptz not null default now()
);
create index if not exists inventory_trgm on public.inventory_items using gin (name_norm gin_trgm_ops);
create unique index if not exists inventory_sku_uq on public.inventory_items (upper(sku)) where sku is not null;
alter table public.inventory_items enable row level security;
drop policy if exists inv_read on public.inventory_items;
create policy inv_read on public.inventory_items for select to authenticated using (app.is_active());
drop policy if exists inv_write on public.inventory_items;
create policy inv_write on public.inventory_items for all to authenticated using (app.has_role('admin','bgd','ke_toan')) with check (app.has_role('admin','bgd','ke_toan'));
grant select, insert, update, delete on public.inventory_items to authenticated;

insert into public.settings(key, value, description) values ('inventory', '{"match_threshold":0.5}', 'Ngưỡng cảnh báo trùng hàng tồn kho (0–1)') on conflict (key) do nothing;

create or replace function public.import_inventory(p_rows jsonb, p_replace boolean default true) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.has_role('admin','bgd','ke_toan') then raise exception 'Chỉ Admin, BGĐ, Kế toán được nhập tồn kho'; end if;
  if p_replace then delete from public.inventory_items where true; end if;
  insert into public.inventory_items(sku, name, unit, qty, warehouse, note)
  select distinct on (upper(btrim(x->>'sku'))) btrim(x->>'sku'), btrim(x->>'name'), nullif(x->>'unit', ''), nullif(x->>'qty', '')::numeric, nullif(x->>'warehouse', ''), nullif(x->>'note', '')
    from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') <> ''
  on conflict (upper(sku)) where sku is not null do update set name = excluded.name, unit = excluded.unit, qty = excluded.qty, warehouse = excluded.warehouse, note = excluded.note, updated_at = now();
  get diagnostics n = row_count;
  insert into public.inventory_items(name, unit, qty, warehouse, note)
  select btrim(x->>'name'), nullif(x->>'unit', ''), nullif(x->>'qty', '')::numeric, nullif(x->>'warehouse', ''), nullif(x->>'note', '')
    from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') = '';
  n := n + (select count(*) from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') = '');
  insert into public.audit_logs(action, table_name, diff) values ('IMPORT', 'inventory_items', jsonb_build_object('rows', n, 'replace', p_replace));
  return n;
end $$;
grant execute on function public.import_inventory(jsonb, boolean) to authenticated;

-- Tìm hàng tồn kho giống tên hàng (trả tối đa 3 kết quả / dòng)
create or replace function public.inventory_match(p_names text[])
returns table(idx int, sku text, name text, unit text, qty numeric, warehouse text, score real)
language sql stable security definer set search_path = public, app, extensions as $$
  select n.i::int, m.sku, m.name, m.unit, m.qty, m.warehouse, m.sc
  from unnest(p_names) with ordinality n(t, i)
  cross join lateral (
    select it.sku, it.name, it.unit, it.qty, it.warehouse,
           greatest(similarity(it.name_norm, app.norm_text(n.t)), word_similarity(it.name_norm, app.norm_text(n.t))) sc
      from public.inventory_items it
     where app.is_active() and length(app.norm_text(n.t)) >= 4
       and greatest(similarity(it.name_norm, app.norm_text(n.t)), word_similarity(it.name_norm, app.norm_text(n.t)))
           >= coalesce((app.setting('inventory')->>'match_threshold')::real, 0.5)
     order by sc desc limit 3) m
$$;
grant execute on function public.inventory_match(text[]) to authenticated;

alter table public.quotations add column if not exists inventory_flags jsonb;

-- Gọi sau khi lưu báo giá: ghi cảnh báo vào báo giá + báo quản lý trực tiếp (1 lần cho mỗi bộ cảnh báo mới)
create or replace function public.quote_inventory_check(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare q public.quotations; v jsonb; mgr uuid;
begin
  select * into q from public.quotations where id = p_id;
  if q.id is null or not (app.in_tree(q.sale_id) or app.is_admin()) then raise exception 'Không có quyền'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('line', l.line_no, 'item', l.name, 'sku', m.sku, 'stock', m.name, 'qty', m.qty, 'unit', m.unit, 'score', round(m.score::numeric, 2)) order by l.line_no, m.score desc), '[]')
    into v
    from public.quotation_lines l
    cross join lateral public.inventory_match(array[l.name]) m
   where l.quotation_id = p_id;
  if jsonb_array_length(v) = 0 then v := null; end if;
  if v is not null and v is distinct from q.inventory_flags then
    select manager_id into mgr from public.profiles where id = q.sale_id;
    if mgr is not null then
      perform app.notify(mgr, 'quote', '📦 ' || q.code || ' có hàng giống tồn kho', jsonb_array_length(v) || ' dòng cần xem: ' || (v->0->>'stock'), '#/crm/quote?id=' || q.id);
    end if;
  end if;
  update public.quotations set inventory_flags = v where id = p_id;
  return v;
end $$;
grant execute on function public.quote_inventory_check(uuid) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0011_v5.sql
-- =====================================================================
-- 0011 · Bản 5: sao lưu dữ liệu, khách hàng theo file hệ thống (username,
--        mã KH, kho, ngày cọc), MST 12 số, kho báo giá chỉ đơn đã chốt +
--        quyền xem cước + tạo báo giá tương tự, chặn chấm công ngoài IP,
--        link Drive cho hồ sơ nhân sự
-- =====================================================================
set search_path = public, app, extensions;

-- ---------- 0. Sao lưu dữ liệu ngay trong database ----------
-- Mỗi bản sao lưu là 1 schema bk_YYYYMMDD_HH24MI chứa bản sao mọi bảng public. Giữ 5 bản gần nhất.
create or replace function public.backup_create(p_note text default null) returns text
language plpgsql security definer set search_path = public, app as $$
declare s text := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS'); t record; old record;
begin
  if auth.uid() is not null and not app.is_admin() then raise exception 'Chỉ Admin được tạo bản sao lưu'; end if;
  execute format('create schema %I', s);
  execute format('revoke all on schema %I from public, anon, authenticated', s);
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' loop
    execute format('create table %I.%I as table public.%I', s, t.relname, t.relname);
  end loop;
  execute format('comment on schema %I is %L', s, coalesce(p_note, 'Sao lưu') || ' · ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'));
  for old in select nspname from pg_namespace where nspname ~ '^bk_[0-9]{8}_[0-9]{6}$' order by nspname desc offset 5 loop
    execute format('drop schema %I cascade', old.nspname);
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('BACKUP', s, jsonb_build_object('note', p_note));
  return s;
end $$;
revoke all on function public.backup_create(text) from public, anon;
grant execute on function public.backup_create(text) to authenticated;

create or replace function public.backup_list()
returns table(name text, note text, tables int, rows_total bigint, size_mb numeric)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin'; end if;
  return query
  select n.nspname::text, obj_description(n.oid, 'pg_namespace'),
         (select count(*)::int from pg_class c where c.relnamespace = n.oid and c.relkind = 'r'),
         (select coalesce(sum(c.reltuples), 0)::bigint from pg_class c where c.relnamespace = n.oid and c.relkind = 'r'),
         round((select coalesce(sum(pg_total_relation_size(c.oid)), 0) from pg_class c where c.relnamespace = n.oid and c.relkind = 'r') / 1048576.0, 2)
  from pg_namespace n where n.nspname ~ '^bk_[0-9]{8}_[0-9]{6}$' order by 1 desc;
end $$;
grant execute on function public.backup_list() to authenticated;

-- Khôi phục 1 bảng từ bản sao lưu (chạy trong SQL Editor):
--   select public.backup_restore_table('bk_20261029_120000', 'customers');
-- Ghi đè các dòng có trong bản sao lưu về đúng giá trị lúc sao lưu (theo khóa chính), dòng mới tạo sau đó giữ nguyên.
create or replace function public.backup_restore_table(p_schema text, p_table text) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare cols text; pk text; upd text; n bigint;
begin
  if auth.uid() is not null and not app.is_admin() then raise exception 'Chỉ Admin'; end if;
  if p_schema !~ '^bk_[0-9]{8}_[0-9]{6}$' then raise exception 'Tên bản sao lưu không hợp lệ'; end if;
  select string_agg(format('%I', a.attname), ', ' order by a.attnum) into cols
    from pg_attribute a where a.attrelid = format('public.%I', p_table)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
     and exists (select 1 from information_schema.columns ic where ic.table_schema = p_schema and ic.table_name = p_table and ic.column_name = a.attname);
  select string_agg(format('%I', a.attname), ', ') into pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = format('public.%I', p_table)::regclass and i.indisprimary;
  if cols is null or pk is null then raise exception 'Bảng % không khôi phục được (thiếu khóa chính)', p_table; end if;
  select string_agg(format('%1$I = excluded.%1$I', x), ', ') into upd
    from unnest(string_to_array(replace(cols, '"', ''), ', ')) x where x <> all(string_to_array(replace(pk, '"', ''), ', '));
  execute format('alter table public.%I disable trigger user', p_table);
  execute format('insert into public.%I (%s) overriding system value select %s from %I.%I on conflict (%s) do %s',
                 p_table, cols, cols, p_schema, p_table, pk, case when upd is null then 'nothing' else 'update set ' || upd end);
  get diagnostics n = row_count;
  execute format('alter table public.%I enable trigger user', p_table);
  insert into public.audit_logs(action, table_name, diff) values ('RESTORE', p_table, jsonb_build_object('from', p_schema, 'rows', n));
  return n;
end $$;
revoke all on function public.backup_restore_table(text, text) from public, anon, authenticated;

select public.backup_create('Trước khi cập nhật bản 5');

-- ---------- 1. Khách hàng: thêm trường theo file xuất hệ thống ----------
alter table public.customers add column if not exists sys_username text;
alter table public.customers add column if not exists sys_warehouse text;
alter table public.customers add column if not exists salutation text;
alter table public.customers add column if not exists legal_rep text;
alter table public.customers add column if not exists legal_address text;
alter table public.customers add column if not exists sys_created_date date;
alter table public.customers add column if not exists sys_first_order_date date;
create index if not exists customers_sys_username on public.customers (lower(sys_username));
create index if not exists customers_sys_code on public.customers (upper(sys_code));

-- MST: 10 số, 10-3 (chi nhánh) hoặc 12 số (MST cá nhân / hộ kinh doanh theo CCCD)
alter table public.customers drop constraint if exists tax_format;
alter table public.customers add constraint tax_format check (tax_code is null or tax_code ~ '^([0-9]{10}(-[0-9]{3})?|[0-9]{12})$');
-- Khách lớn có thể ẩn SĐT: chấp nhận khi đã có mã KH / username hệ thống
alter table public.customers drop constraint if exists phone_or_zalo;
alter table public.customers add constraint phone_or_zalo check (phone_norm is not null or zalo_norm is not null or sys_code is not null or sys_username is not null);

create or replace function app.customers_sys_before() returns trigger language plpgsql as $$
begin
  new.sys_code := nullif(upper(btrim(new.sys_code)), '');
  new.sys_username := nullif(btrim(new.sys_username), '');
  return new;
end $$;
drop trigger if exists customers_sys_before on public.customers;
create trigger customers_sys_before before insert or update of sys_code, sys_username on public.customers for each row execute function app.customers_sys_before();

-- Nhập / đồng bộ theo file xuất từ hệ thống. Khớp: Mã KH → Username → SĐT → MST.
create or replace function public.import_customers(p_rows jsonb, p_create boolean default false)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare r jsonb; i int := 0; c record; v_owner uuid; v_last date; v_first date; v_phone text; v_tax text; v_id uuid; v_user text; v_code text;
        n_upd int := 0; n_new int := 0; n_skip int := 0; errs jsonb := '[]'; warns jsonb := '[]'; v_type text; v_src text; v_name text;
begin
  if not app.has_role('admin','bgd','tp_kd') then raise exception 'Chỉ Admin, BGĐ, Trưởng phòng KD được nhập dữ liệu khách'; end if;
  perform set_config('app.system', '1', true);
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    begin
      v_phone := app.norm_phone(nullif(btrim(r->>'phone'), '')); if v_phone !~ '^0[0-9]{9,10}$' then v_phone := null; end if;
      v_tax := app.norm_tax(nullif(r->>'tax_code', '')); if v_tax !~ '^([0-9]{10}(-[0-9]{3})?|[0-9]{12})$' then v_tax := null; end if;
      v_user := nullif(btrim(r->>'sys_username'), ''); v_code := nullif(upper(btrim(r->>'sys_code')), '');
      v_last := coalesce(nullif(r->>'last_order_date', '')::date,
                         case when nullif(r->>'days_no_order', '') is not null then app.vn_today() - round((r->>'days_no_order')::numeric)::int end);
      v_first := nullif(r->>'first_order_date', '')::date;
      v_name := coalesce(nullif(btrim(concat_ws(' ', nullif(btrim(r->>'last_name'), ''), nullif(btrim(r->>'first_name'), ''))), ''), nullif(btrim(r->>'contact_name'), ''),
                         nullif(btrim(r->>'legal_rep'), ''), nullif(btrim(r->>'company_name'), ''), v_user, v_code);
      c := null;
      select * into c from public.customers cu where cu.deleted_at is null and (
             (v_code is not null and upper(cu.sys_code) = v_code)
          or (v_user is not null and lower(cu.sys_username) = lower(v_user))
          or (v_phone is not null and v_phone in (cu.phone_norm, cu.zalo_norm))
          or (v_tax is not null and v_tax = cu.tax_code))
        order by (upper(cu.sys_code) = v_code) desc nulls last, (lower(cu.sys_username) = lower(v_user)) desc nulls last limit 1;
      if c.id is not null then
        update public.customers set
          sys_code = coalesce(v_code, sys_code), sys_username = coalesce(v_user, sys_username),
          sys_warehouse = coalesce(nullif(r->>'sys_warehouse', ''), sys_warehouse),
          sys_created_date = coalesce(nullif(r->>'sys_created_date', '')::date, sys_created_date),
          sys_first_order_date = coalesce(v_first, sys_first_order_date),
          sys_last_order_date = coalesce(v_last, sys_last_order_date),
          sys_order_count = coalesce(nullif(r->>'order_count', '')::numeric::int, sys_order_count),
          sys_revenue = coalesce(nullif(r->>'revenue', '')::numeric, sys_revenue),
          sys_synced_at = now(),
          email = coalesce(email, nullif(r->>'email', '')), address = coalesce(address, nullif(r->>'address', '')),
          company_name = coalesce(company_name, nullif(r->>'company_name', '')), position = coalesce(position, nullif(r->>'position', '')),
          salutation = coalesce(salutation, nullif(r->>'salutation', '')), legal_rep = coalesce(legal_rep, nullif(r->>'legal_rep', '')),
          legal_address = coalesce(legal_address, nullif(r->>'legal_address', '')),
          first_order_at = coalesce(first_order_at, (v_first::timestamp at time zone 'Asia/Ho_Chi_Minh')),
          last_order_at = greatest(last_order_at, (v_last::timestamp at time zone 'Asia/Ho_Chi_Minh'))
        where id = c.id;
        n_upd := n_upd + 1;
      elsif p_create then
        if v_name is null then raise exception 'Thiếu tên khách'; end if;
        if v_phone is null and v_code is null and v_user is null then raise exception 'Cần ít nhất SĐT, Mã KH hoặc Username hệ thống'; end if;
        v_owner := null;
        if nullif(r->>'sale', '') is not null then
          select p.id into v_owner from public.profiles p
           where p.status = 'active' and (lower(p.email) = lower(btrim(r->>'sale')) or upper(p.employee_code) = upper(btrim(r->>'sale'))
              or app.norm_text(p.full_name) = app.norm_text(r->>'sale') or app.norm_text(r->>'sale') = any(select app.norm_text(x) from unnest(p.sale_aliases) x))
           limit 1;
          if v_owner is null and jsonb_array_length(warns) < 200 then warns := warns || jsonb_build_object('row', i, 'msg', 'Chưa khớp sale "' || (r->>'sale') || '" → tạm giao cho người nhập'); end if;
        end if;
        v_type := coalesce((select code from public.lookups where category = 'customer_type' and (code = r->>'customer_type' or app.norm_text(label) = app.norm_text(r->>'customer_type')) limit 1),
                           case when v_tax is not null and length(v_tax) >= 10 and coalesce(r->>'company_name', '') ~* '(công ty|cong ty|tnhh|cổ phần|jsc|co\.,)' then
                             (select code from public.lookups where category = 'customer_type' and code = 'doanh_nghiep') end,
                           (select code from public.lookups where category = 'customer_type' and active order by sort limit 1));
        v_src := coalesce((select code from public.lookups where category = 'source' and (code = r->>'source' or app.norm_text(label) = app.norm_text(r->>'source')) limit 1), 'du_lieu_cu');
        insert into public.customers(contact_name, company_name, phone, zalo, tax_code, email, customer_type, source, industry, goods, province, address, note,
                                     position, salutation, legal_rep, legal_address, owner_id, created_by,
                                     sys_code, sys_username, sys_warehouse, sys_created_date, sys_first_order_date, sys_last_order_date, sys_order_count, sys_revenue, sys_synced_at,
                                     first_order_at, last_order_at, stage)
        values (v_name, nullif(r->>'company_name', ''), case when v_phone is not null then btrim(r->>'phone') end, nullif(r->>'zalo', ''), v_tax,
                nullif(r->>'email', ''), v_type, v_src,
                (select code from public.lookups where category = 'industry' and (code = r->>'industry' or app.norm_text(label) = app.norm_text(r->>'industry')) limit 1),
                nullif(r->>'goods', ''), nullif(r->>'province', ''), nullif(r->>'address', ''), nullif(r->>'note', ''),
                nullif(r->>'position', ''), nullif(r->>'salutation', ''), nullif(r->>'legal_rep', ''), nullif(r->>'legal_address', ''),
                coalesce(v_owner, auth.uid()), null,
                v_code, v_user, nullif(r->>'sys_warehouse', ''), nullif(r->>'sys_created_date', '')::date, v_first, v_last,
                nullif(r->>'order_count', '')::numeric::int, nullif(r->>'revenue', '')::numeric, now(),
                (v_first::timestamp at time zone 'Asia/Ho_Chi_Minh'), (v_last::timestamp at time zone 'Asia/Ho_Chi_Minh'),
                case when v_last is null then 'moi' when v_last >= app.vn_today() - coalesce((app.setting('crm')->>'dormant_days')::int, 60) then 'hoat_dong' else 'kho_ngu' end)
        returning id into v_id;
        n_new := n_new + 1;
      else
        n_skip := n_skip + 1;
        if jsonb_array_length(errs) < 200 then errs := errs || jsonb_build_object('row', i, 'msg', 'Không tìm thấy khách khớp Mã KH / Username / SĐT / MST'); end if;
      end if;
    exception when others then
      n_skip := n_skip + 1;
      if jsonb_array_length(errs) < 200 then errs := errs || jsonb_build_object('row', i, 'msg', sqlerrm); end if;
    end;
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('IMPORT', 'customers', jsonb_build_object('updated', n_upd, 'created', n_new, 'skipped', n_skip));
  return jsonb_build_object('updated', n_upd, 'created', n_new, 'skipped', n_skip, 'errors', errs, 'warnings', warns);
end $$;
grant execute on function public.import_customers(jsonb, boolean) to authenticated;

-- ---------- 2. Kho báo giá: chỉ báo giá đã chốt, có mã đơn, quyền xem cước, tạo báo giá tương tự ----------
alter table public.quote_archive add column if not exists order_code text;
insert into public.settings(key, value, description) values ('library', '{"freight_roles":["admin","bgd","tp_kd","tn_kd","sale"]}', 'Kho báo giá tham khảo: vai trò được xem cước')
on conflict (key) do nothing;

create or replace function app.can_see_freight() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_admin() or app.my_roles() && coalesce((select array_agg(x) from jsonb_array_elements_text(app.setting('library')->'freight_roles') x), '{}'::text[])
$$;

drop function if exists public.quote_library(text, text, int, int);
create or replace function public.quote_library(p_q text default null, p_source text default null, p_limit int default 100, p_offset int default 0)
returns table(source text, ref uuid, code text, order_code text, quote_date date, status text, item_name text, hs_code text, unit text, qty numeric, price_cny numeric,
              duty_pct numeric, vat_pct numeric, export_price numeric, rate numeric, import_method text, warehouse text, freight text, sale_name text, score real, total bigint)
language plpgsql stable security definer set search_path = public, app, extensions as $$
declare q text := app.norm_text(p_q); v_fr boolean := app.can_see_freight();
begin
  if not app.is_active() then raise exception 'Không có quyền'; end if;
  return query
  with s as (
    select 'he_thong'::text src, l.id rf, qt.code || case when qt.version > 1 then '-v' || qt.version else '' end cd,
           coalesce(nullif(qt.order_code, ''), nullif(qt.header->>'maDonHeThong', '')) oc,
           (coalesce(qt.won_at, qt.created_at) at time zone 'Asia/Ho_Chi_Minh')::date dt, qt.status st,
           l.name nm, l.hs_code hs, l.unit un, l.qty qy, l.unit_price_cny pc, l.duty_pct dp, coalesce(l.vat_pct, (qt.header->>'vatPct')::numeric) vp,
           (l.computed->>'giaXuat')::numeric ep, (qt.header->>'tyGia')::numeric rt, qt.header->>'hinhThucNK' im, qt.header->>'khoNhan' wh,
           nullif(concat_ws(' · ', case when (qt.header->>'donGiaKg')::numeric > 0 then to_char((qt.header->>'donGiaKg')::numeric, 'FM999G999G999') || 'đ/kg' end,
                                   case when (qt.header->>'donGiaKhoi')::numeric > 0 then to_char((qt.header->>'donGiaKhoi')::numeric, 'FM999G999G999') || 'đ/m³' end), '') fr,
           app.name_of(qt.sale_id) sn, l.name_norm nn
      from public.quotation_lines l join public.quotations qt on qt.id = l.quotation_id
     where qt.status = 'da_chot'
    union all
    select 'luu_tru', a.id, a.src_code, a.order_code, a.quote_date, 'da_chot', a.item_name, a.hs_code, a.unit, a.qty, a.price_cny, a.duty_pct, a.vat_pct, a.export_price, a.rate,
           a.import_method, a.warehouse, a.freight, a.sale_name, a.name_norm
      from public.quote_archive a
  ), f as (
    select s.*, case when q = '' then 1::real else greatest(similarity(s.nn, q), word_similarity(q, s.nn)) end sc
      from s where (p_source is null or s.src = p_source)
       and (q = '' or s.nn like '%' || q || '%' or s.hs like p_q || '%' or upper(coalesce(s.oc, '')) like upper(btrim(p_q)) || '%'
            or upper(coalesce(s.cd, '')) like upper(btrim(p_q)) || '%' or word_similarity(q, s.nn) >= 0.45)
  )
  select f.src, f.rf, f.cd, f.oc, f.dt, f.st, f.nm, f.hs, f.un, f.qy, f.pc, f.dp, f.vp, f.ep, f.rt, f.im, f.wh, case when v_fr then f.fr end, f.sn, f.sc, count(*) over ()
    from f order by f.sc desc, f.dt desc nulls last limit greatest(1, least(p_limit, 2000)) offset greatest(p_offset, 0);
end $$;
grant execute on function public.quote_library(text, text, int, int) to authenticated;

-- Mẫu để tạo báo giá tương tự: tham số đầu báo giá (không có thông tin khách) + dòng hàng
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
                                        'duty_pct', x.duty_pct, 'vat_pct', x.vat_pct, 'freight_pct', x.freight_pct) order by x.line_no)
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
grant execute on function public.quote_template(text, uuid, boolean) to authenticated;

-- ---------- 3. Chấm công ngoài IP: chờ xác nhận hoặc chặn ----------
create or replace function public.attendance_check(p_kind text, p_selfie_path text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare v_ip text := app.client_ip(); v_ok boolean; v_id uuid; v_status text := 'valid'; v_cfg jsonb := coalesce(app.setting('attendance'),'{}');
        v_req boolean := coalesce((v_cfg->>'require_selfie')::boolean, true);
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  if p_kind not in ('in','out') then raise exception 'Loại chấm công không hợp lệ'; end if;
  v_ok := app.ip_allowed(v_ip);
  if not v_ok and jsonb_array_length(coalesce(v_cfg->'ip_whitelist','[]')) > 0 then
    if coalesce(v_cfg->>'outside_ip', 'flag') = 'block' then
      raise exception 'Bạn đang ở ngoài mạng công ty (IP %). Hãy kết nối wifi văn phòng để chấm công. Đi công tác / gặp khách: tạo đơn ở mục Xin nghỉ.', coalesce(v_ip, '?');
    end if;
    v_status := 'flagged';
  end if;
  if v_req and coalesce(p_selfie_path,'') = '' then raise exception 'Cần ảnh selfie'; end if;
  if p_selfie_path is not null and split_part(p_selfie_path, '/', 1) <> auth.uid()::text then
    raise exception 'Đường dẫn ảnh không hợp lệ';
  end if;
  if v_req and (select selfie_consent_at from public.profile_private where profile_id = auth.uid()) is null then
    raise exception 'Bạn cần đồng ý điều khoản lưu ảnh chấm công trước';
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

-- ---------- 4. Hồ sơ nhân sự: link Google Drive thay cho file nặng ----------
alter table public.hr_contracts add column if not exists file_url text;
alter table public.hr_agreements add column if not exists file_url text;
alter table public.hr_documents add column if not exists file_url text;
alter table public.hr_documents alter column file_path drop not null;
alter table public.hr_documents drop constraint if exists hr_documents_file_or_link;
alter table public.hr_documents add constraint hr_documents_file_or_link check (file_path is not null or file_url is not null);

reset search_path;


-- >>>>> supabase/migrations/0012_v6.sql
-- =====================================================================
-- 0012 · Bản 6: sinh nhật nhân sự (Hôm nay + lời chúc), Admin đặt lại mật khẩu
-- =====================================================================
set search_path = public, app, extensions;
-- Tránh trùng tên khi 2 bản sao lưu tạo trong cùng 1 giây
create or replace function public.backup_create(p_note text default null) returns text
language plpgsql security definer set search_path = public, app as $$
declare s text := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS'); t record; old record;
begin
  if auth.uid() is not null and not app.is_admin() then raise exception 'Chỉ Admin được tạo bản sao lưu'; end if;
  while exists (select 1 from pg_namespace where nspname = s) loop
    perform pg_sleep(1); s := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS');
  end loop;
  execute format('create schema %I', s);
  execute format('revoke all on schema %I from public, anon, authenticated', s);
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' loop
    execute format('create table %I.%I as table public.%I', s, t.relname, t.relname);
  end loop;
  execute format('comment on schema %I is %L', s, coalesce(p_note, 'Sao lưu') || ' · ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'));
  for old in select nspname from pg_namespace where nspname ~ '^bk_[0-9]{8}_[0-9]{6}$' order by nspname desc offset 5 loop
    execute format('drop schema %I cascade', old.nspname);
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('BACKUP', s, jsonb_build_object('note', p_note));
  return s;
end $$;

select public.backup_create('Trước khi cập nhật bản 6');
create extension if not exists pgcrypto with schema extensions;

-- ---------- Sinh nhật: chỉ lộ ngày/tháng, không lộ năm sinh ----------
create or replace function public.birthdays(p_month int default null)
returns table(profile_id uuid, full_name text, org_unit_id uuid, day int, month int, is_today boolean, days_left int)
language sql stable security definer set search_path = public, app as $$
  with t as (select app.vn_today() d)
  select p.id, p.full_name, p.org_unit_id, extract(day from r.dob)::int, extract(month from r.dob)::int,
         (extract(day from r.dob), extract(month from r.dob)) = (extract(day from t.d), extract(month from t.d)),
         extract(day from r.dob)::int - extract(day from t.d)::int
  from public.profiles p join public.hr_records r on r.profile_id = p.id cross join t
  where app.is_active() and p.status = 'active' and r.dob is not null
    and extract(month from r.dob)::int = coalesce(p_month, extract(month from t.d)::int)
  order by 5, 4
$$;
grant execute on function public.birthdays(int) to authenticated;

-- Nhân viên tự khai ngày sinh (1 lần); HCNS/Admin sửa được ở Hồ sơ nhân sự
create or replace function public.set_my_dob(p_dob date) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  if p_dob is null or p_dob > app.vn_today() - interval '15 years' or p_dob < date '1940-01-01' then raise exception 'Ngày sinh không hợp lệ'; end if;
  if exists (select 1 from public.hr_records where profile_id = auth.uid() and dob is not null) then raise exception 'Ngày sinh đã có — liên hệ HCNS nếu cần sửa'; end if;
  insert into public.hr_records(profile_id, dob) values (auth.uid(), p_dob) on conflict (profile_id) do update set dob = excluded.dob;
end $$;
grant execute on function public.set_my_dob(date) to authenticated;

create or replace function public.my_dob() returns date
language sql stable security definer set search_path = public as $$ select dob from public.hr_records where profile_id = auth.uid() $$;
grant execute on function public.my_dob() to authenticated;

-- 8:00 sáng: báo cả công ty ai sinh nhật hôm nay
create or replace function app.job_birthdays() returns void
language plpgsql security definer set search_path = public, app as $$
declare b record;
begin
  for b in select p.id, p.full_name from public.profiles p join public.hr_records r on r.profile_id = p.id
            where p.status = 'active' and r.dob is not null
              and to_char(r.dob, 'MM-DD') = to_char(app.vn_today(), 'MM-DD') loop
    perform app.notify(x.id, 'birthday', '🎂 Hôm nay sinh nhật ' || b.full_name, 'Gửi lời chúc tới ' || b.full_name || ' nhé!', '#/')
      from public.profiles x where x.status = 'active' and x.id <> b.id;
    perform app.notify(b.id, 'birthday', '🎉 Chúc mừng sinh nhật ' || b.full_name || '!', 'Nam Trung chúc bạn tuổi mới thật nhiều niềm vui, sức khỏe và thành công.', '#/');
    perform app.telegram('birthday', '🎂 Hôm nay sinh nhật <b>' || app.esc(b.full_name) || '</b>. Cả nhà gửi lời chúc nhé!');
  end loop;
end $$;
select cron.schedule('nt_birthdays', '0 1 * * *', 'select app.job_birthdays()');
update public.settings set value = jsonb_set(value, '{events}', coalesce(value->'events', '[]'::jsonb) || '"birthday"'::jsonb)
 where key = 'telegram' and not coalesce(value->'events', '[]'::jsonb) ? 'birthday';

-- ---------- Admin / HCNS đặt lại mật khẩu ----------
create or replace function public.admin_set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_roles text[];
begin
  select roles into v_roles from public.profiles where id = p_user;
  if v_roles is null then raise exception 'Không tìm thấy tài khoản'; end if;
  if not (app.is_admin() or (app.has_role('hcns') and not v_roles && array['admin','bgd'])) then
    raise exception 'Không có quyền đặt lại mật khẩu tài khoản này';
  end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'Mật khẩu tối thiểu 8 ký tự'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf', 10)), updated_at = now() where id = p_user;
  -- đăng xuất các phiên đang mở của tài khoản đó
  begin execute 'delete from auth.sessions where user_id = $1' using p_user; exception when others then null; end;
  begin execute 'delete from auth.refresh_tokens where user_id = $1::text' using p_user; exception when others then null; end;
  insert into public.audit_logs(action, table_name, record_id, diff) values ('RESET_PASSWORD', 'profiles', p_user::text, jsonb_build_object('by', auth.uid()));
  perform app.notify(p_user, 'account', '🔑 Mật khẩu của bạn vừa được đặt lại', 'Đăng nhập bằng mật khẩu mới rồi đổi lại ở mục Tài khoản.', '#/account');
end $$;
revoke all on function public.admin_set_password(uuid, text) from public, anon;
grant execute on function public.admin_set_password(uuid, text) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0013_v7.sql
-- =====================================================================
-- 0013 · Bản 7: COM Mua hàng / CSKH / TP Kế toán trong lương, tồn kho có giá,
--        câu trả lời mẫu, đếm trạng thái báo giá phía máy chủ (tải nhanh)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 7');

-- ---------- 1. Lương: COM theo bộ phận ----------
alter table public.order_results add column if not exists cskh_name text;
alter table public.order_results add column if not exists cskh_id uuid references public.profiles(id);
alter table public.order_results add column if not exists buyer_name text;
alter table public.order_results add column if not exists buyer_id uuid references public.profiles(id);
alter table public.order_results add column if not exists purchase_fee numeric(18,0) not null default 0;   -- Phí mua hàng (phí dịch vụ)
alter table public.order_results add column if not exists nego_fee numeric(18,0) not null default 0;       -- Tiền hoa hồng đàm phán
create index if not exists order_results_cskh on public.order_results(period_id, cskh_id);
create index if not exists order_results_buyer on public.order_results(period_id, buyer_id);
alter table public.payslips add column if not exists com_buyer numeric(18,0) not null default 0;
alter table public.payslips add column if not exists com_cskh numeric(18,0) not null default 0;
alter table public.payslips add column if not exists com_accounting numeric(18,0) not null default 0;

drop policy if exists or_read on public.order_results;
create policy or_read on public.order_results for select to authenticated
  using (app.can_see_hr() or app.in_tree(profile_id) or cskh_id = auth.uid() or buyer_id = auth.uid());

update public.settings set value = value
  || jsonb_build_object('buyer_com', coalesce(value->'buyer_com', '{"enabled":true,"fee_pct":2,"nego_pct_by_month":[2,3,4,5],"coef_pct":100}'::jsonb))
  || jsonb_build_object('cskh_com', coalesce(value->'cskh_com', '{"enabled":true,"fee_pct":2,"nego_pct":1}'::jsonb))
  || jsonb_build_object('accounting_com', coalesce(value->'accounting_com', '{"pct":0.5,"base_pct":60,"profile_ids":[]}'::jsonb))
  || jsonb_build_object('order_link', coalesce(value->'order_link', '"https://ad.namtrunglog.com/don-hang/{so}"'::jsonb))
 where key = 'payroll';

create or replace function app.is_assigned(p_name text) returns boolean language sql immutable as $$
  select coalesce(btrim(p_name), '') <> '' and lower(btrim(p_name)) not in ('chưa phân công', 'chua phan cong', '-', 'không', 'khong')
$$;
-- Khớp tên trong file với nhân sự (tên trong file đơn, họ tên, mã NV)
create or replace function app.match_staff(p_name text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select p.id from public.profiles p
   where app.is_assigned(p_name)
     and lower(btrim(p_name)) = any(select lower(btrim(x)) from unnest(p.sale_aliases || p.full_name || coalesce(p.employee_code, '')) x)
   limit 1
$$;


create or replace function public.import_order_results(p_period uuid, p_rows jsonb, p_replace boolean default true)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_pid uuid; v_cskh uuid; v_buyer uuid; n int := 0; unmapped text[] := '{}'; st text;
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
    v_cskh := app.match_staff(r->>'cskh_name'); v_buyer := app.match_staff(r->>'buyer_name');
    if v_cskh is null and app.is_assigned(r->>'cskh_name') then unmapped := unmapped || ('CSKH: ' || (r->>'cskh_name')); end if;
    if v_buyer is null and app.is_assigned(r->>'buyer_name') then unmapped := unmapped || ('Mua hàng: ' || (r->>'buyer_name')); end if;
    insert into public.order_results(period_id, ext_order_code, sale_name, profile_id, customer_ext, warehouse, order_type, completed_at, goods_value, order_profit, raw,
                                     cskh_name, cskh_id, buyer_name, buyer_id, purchase_fee, nego_fee)
    values (p_period, btrim(r->>'ext_order_code'), r->>'sale_name', v_pid, r->>'customer_ext', r->>'warehouse', r->>'order_type',
            (r->>'completed_at')::date, coalesce((r->>'goods_value')::numeric,0), coalesce((r->>'order_profit')::numeric,0), r->'raw',
            nullif(r->>'cskh_name', ''), v_cskh, nullif(r->>'buyer_name', ''), v_buyer, coalesce((r->>'purchase_fee')::numeric, 0), coalesce((r->>'nego_fee')::numeric, 0))
    on conflict (period_id, ext_order_code) do update set sale_name = excluded.sale_name, profile_id = excluded.profile_id,
       completed_at = excluded.completed_at, goods_value = excluded.goods_value, order_profit = excluded.order_profit, raw = excluded.raw,
       cskh_name = excluded.cskh_name, cskh_id = excluded.cskh_id, buyer_name = excluded.buyer_name, buyer_id = excluded.buyer_id,
       purchase_fee = excluded.purchase_fee, nego_fee = excluded.nego_fee;
    n := n + 1;
  end loop;
  return jsonb_build_object('imported', n, 'unmapped', (select coalesce(jsonb_agg(distinct x), '[]') from unnest(unmapped) x));
end $$;

create or replace function public.payroll_compute(p_period uuid)
returns int language plpgsql security definer set search_path = public, app as $$
declare
  per record; p record; pcfg jsonb := coalesce(app.setting('payroll'),'{}');
  m_start date; m_end date; d date; info jsonb;
  std numeric; paid numeric; worked numeric; pleave numeric; unpaid numeric; late int; over int;
  flex_min int := coalesce(app.setting_num('attendance','flex_minutes'), 100)::int; flex_from date := coalesce((app.setting('attendance')->>'flex_start')::date, '2026-11-01');
  base_pct numeric := coalesce((pcfg->>'commission_base_pct')::numeric, 60); max_off numeric := coalesce((pcfg->>'loss_offset_max_pct')::numeric, 50);
  priv record; lvl record; pos numeric; loss numeric; carry_in numeric; com numeric; off numeric; team numeric; adj numeric; sal numeric; flexded numeric; n int := 0; detail jsonb;
  bcfg jsonb := coalesce(pcfg->'buyer_com', '{}'); ccfg jsonb := coalesce(pcfg->'cskh_com', '{}'); acfg jsonb := coalesce(pcfg->'accounting_com', '{}');
  b_fee numeric; b_nego numeric; b_orders int; b_month int; b_nego_pct numeric; b_coef numeric; c_buyer numeric; c_fee numeric; c_nego numeric; c_orders int; c_cskh numeric;
  c_acc numeric; total_profit numeric;
begin
  if not app.has_role('admin','bgd','hcns','ke_toan') then raise exception 'Không có quyền tính lương'; end if;
  select * into per from public.payroll_periods where id = p_period for update;
  if per.id is null then raise exception 'Kỳ lương không tồn tại'; end if;
  if per.status not in ('open','review') then raise exception 'Kỳ lương đang chờ duyệt hoặc đã chốt'; end if;
  m_start := per.month; m_end := (per.month + interval '1 month - 1 day')::date;
  select coalesce(sum(order_profit), 0) into total_profit from public.order_results where period_id = p_period;
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
    -- COM Mua hàng: (Phí mua hàng × a% + Hoa hồng đàm phán × b% theo tháng thâm niên) × hệ số
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), count(*) into b_fee, b_nego, b_orders
      from public.order_results where period_id = p_period and buyer_id = p.id;
    c_buyer := 0; b_month := null; b_nego_pct := 0; b_coef := coalesce((bcfg->>'coef_pct')::numeric, 100);
    if coalesce((bcfg->>'enabled')::boolean, true) and b_orders > 0 then
      b_month := case when p.hire_date is null then 99 else
        (extract(year from age(m_start, date_trunc('month', p.hire_date)::date)) * 12 + extract(month from age(m_start, date_trunc('month', p.hire_date)::date)))::int + 1 end;
      b_nego_pct := coalesce((bcfg->'nego_pct_by_month'->>(least(greatest(b_month, 1), jsonb_array_length(coalesce(bcfg->'nego_pct_by_month', '[2,3,4,5]'::jsonb))) - 1))::numeric,
                             (array[2,3,4,5])[least(greatest(b_month, 1), 4)]);
      c_buyer := round((b_fee * coalesce((bcfg->>'fee_pct')::numeric, 2) / 100 + b_nego * b_nego_pct / 100) * b_coef / 100);
    end if;
    -- COM CSKH: Phí dịch vụ × 2% + Phí đàm phán × 1% các đơn hoàn thành mình phụ trách
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), count(*) into c_fee, c_nego, c_orders
      from public.order_results where period_id = p_period and cskh_id = p.id;
    c_cskh := case when coalesce((ccfg->>'enabled')::boolean, true) and c_orders > 0
                   then round(c_fee * coalesce((ccfg->>'fee_pct')::numeric, 2) / 100 + c_nego * coalesce((ccfg->>'nego_pct')::numeric, 1) / 100) else 0 end;
    -- COM Trưởng phòng Kế toán: 0,5% × 60% × LN đơn hoàn thành cả công ty
    c_acc := case when p.id::text in (select jsonb_array_elements_text(coalesce(acfg->'profile_ids', '[]'))) and total_profit > 0
                  then round(total_profit * coalesce((acfg->>'base_pct')::numeric, 60) / 100 * coalesce((acfg->>'pct')::numeric, 0.5) / 100) else 0 end;
    select coalesce(sum(a.amount),0) into adj from public.payslip_adjustments a join public.payslips ps on ps.id = a.payslip_id where ps.period_id = p_period and ps.profile_id = p.id;
    detail := jsonb_build_object('late_minutes', late, 'flex_minutes', flex_min, 'flex_active', m_start >= flex_from, 'commission_pct', coalesce(lvl.commission_pct,0),
      'commission_base_pct', base_pct, 'loss_this_month', loss, 'carry_in', carry_in, 'orders', (select count(*) from public.order_results where period_id = p_period and profile_id = p.id),
      'buyer', jsonb_build_object('orders', b_orders, 'purchase_fee', b_fee, 'nego_fee', b_nego, 'month', b_month, 'fee_pct', coalesce((bcfg->>'fee_pct')::numeric, 2), 'nego_pct', b_nego_pct, 'coef_pct', b_coef),
      'cskh', jsonb_build_object('orders', c_orders, 'purchase_fee', c_fee, 'nego_fee', c_nego, 'fee_pct', coalesce((ccfg->>'fee_pct')::numeric, 2), 'nego_pct', coalesce((ccfg->>'nego_pct')::numeric, 1)),
      'accounting', jsonb_build_object('total_profit', total_profit, 'base_pct', coalesce((acfg->>'base_pct')::numeric, 60), 'pct', coalesce((acfg->>'pct')::numeric, 0.5)));
    insert into public.payslips as ps(period_id, profile_id, standard_days, paid_days, worked_days, paid_leave_days, unpaid_days, late_minutes, flex_over_minutes, base_salary,
      salary_by_days, allowance, profit_total, commission_base, commission, loss_offset, carry_loss, team_bonus, com_buyer, com_cskh, com_accounting, flex_deduction, insurance, adjustments, net, details, status, updated_at)
    values (p_period, p.id, std, least(paid, std), worked, pleave, greatest(unpaid, 0), late, over, coalesce(priv.base_salary,0), sal, coalesce(priv.allowance,0),
      (select coalesce(sum(order_profit),0) from public.order_results where period_id = p_period and profile_id = p.id),
      pos, com, off, loss + carry_in - off, team, c_buyer, c_cskh, c_acc, flexded, coalesce(priv.insurance_deduction,0), adj,
      sal + coalesce(priv.allowance,0) + com - off + team + c_buyer + c_cskh + c_acc - flexded - coalesce(priv.insurance_deduction,0) + adj, detail, 'draft', now())
    on conflict (period_id, profile_id) do update set standard_days = excluded.standard_days, paid_days = excluded.paid_days, worked_days = excluded.worked_days,
      paid_leave_days = excluded.paid_leave_days, unpaid_days = excluded.unpaid_days, late_minutes = excluded.late_minutes, flex_over_minutes = excluded.flex_over_minutes,
      base_salary = excluded.base_salary, salary_by_days = excluded.salary_by_days, allowance = excluded.allowance, profit_total = excluded.profit_total,
      commission_base = excluded.commission_base, commission = excluded.commission, loss_offset = excluded.loss_offset, carry_loss = excluded.carry_loss,
      team_bonus = excluded.team_bonus, com_buyer = excluded.com_buyer, com_cskh = excluded.com_cskh, com_accounting = excluded.com_accounting, flex_deduction = excluded.flex_deduction, insurance = excluded.insurance, adjustments = excluded.adjustments,
      net = excluded.net, details = excluded.details, status = 'draft', confirmed_at = null, updated_at = now()
    where ps.status <> 'closed';
    n := n + 1;
  end loop;
  update public.payroll_periods set computed_at = now(), status = 'open' where id = p_period;
  return n;
end $$;

-- ---------- 2. Tồn kho: đơn giá nhập / xuất + tổng ----------
alter table public.inventory_items add column if not exists cost_price numeric(18,2);
alter table public.inventory_items add column if not exists sale_price numeric(18,2);
alter table public.inventory_items add column if not exists updated_by uuid references public.profiles(id);
drop trigger if exists inventory_touch on public.inventory_items;
create or replace function app.inventory_touch() returns trigger language plpgsql as $$ begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
create trigger inventory_touch before update on public.inventory_items for each row execute function app.inventory_touch();
drop trigger if exists audit_inventory on public.inventory_items;
create trigger audit_inventory after update or delete on public.inventory_items for each row execute function app.audit();

create or replace function public.import_inventory(p_rows jsonb, p_replace boolean default true) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.has_role('admin','bgd','ke_toan') then raise exception 'Chỉ Admin, BGĐ, Kế toán được nhập tồn kho'; end if;
  if p_replace then delete from public.inventory_items where true; end if;
  insert into public.inventory_items(sku, name, unit, qty, warehouse, note, cost_price, sale_price)
  select distinct on (upper(btrim(x->>'sku'))) btrim(x->>'sku'), btrim(x->>'name'), nullif(x->>'unit', ''), nullif(x->>'qty', '')::numeric, nullif(x->>'warehouse', ''), nullif(x->>'note', ''),
         nullif(x->>'cost_price', '')::numeric, nullif(x->>'sale_price', '')::numeric
    from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') <> ''
  on conflict (upper(sku)) where sku is not null do update set name = excluded.name, unit = excluded.unit, qty = excluded.qty, warehouse = excluded.warehouse, note = excluded.note,
     cost_price = coalesce(excluded.cost_price, inventory_items.cost_price), sale_price = coalesce(excluded.sale_price, inventory_items.sale_price), updated_at = now();
  get diagnostics n = row_count;
  insert into public.inventory_items(name, unit, qty, warehouse, note, cost_price, sale_price)
  select btrim(x->>'name'), nullif(x->>'unit', ''), nullif(x->>'qty', '')::numeric, nullif(x->>'warehouse', ''), nullif(x->>'note', ''), nullif(x->>'cost_price', '')::numeric, nullif(x->>'sale_price', '')::numeric
    from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') = '';
  n := n + (select count(*) from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') = '');
  insert into public.audit_logs(action, table_name, diff) values ('IMPORT', 'inventory_items', jsonb_build_object('rows', n, 'replace', p_replace));
  return n;
end $$;

create or replace function public.inventory_totals(p_q text default null)
returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('items', count(*), 'qty', coalesce(sum(qty), 0),
           'cost_value', coalesce(sum(qty * cost_price), 0), 'sale_value', coalesce(sum(qty * sale_price), 0),
           'updated_at', max(updated_at))
    from public.inventory_items
   where app.is_active() and (coalesce(btrim(p_q), '') = '' or name_norm like '%' || app.norm_text(p_q) || '%' or upper(coalesce(sku, '')) like '%' || upper(btrim(p_q)) || '%')
$$;
grant execute on function public.inventory_totals(text) to authenticated;

-- ---------- 3. Câu trả lời mẫu cho Sale / CSKH ----------
create table if not exists public.reply_templates(
  id uuid primary key default gen_random_uuid(),
  category text not null default 'chung',
  title text not null,
  content text not null,
  sort int not null default 0,
  use_count int not null default 0,
  active boolean not null default true,
  created_by uuid references public.profiles(id) default auth.uid(),
  updated_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.reply_templates enable row level security;
drop policy if exists rt_read on public.reply_templates;
create policy rt_read on public.reply_templates for select to authenticated using (app.is_active());
drop policy if exists rt_write on public.reply_templates;
create policy rt_write on public.reply_templates for all to authenticated using (app.has_role('admin','bgd','tp_kd','tn_kd','hcns')) with check (app.has_role('admin','bgd','tp_kd','tn_kd','hcns'));
grant select, insert, update, delete on public.reply_templates to authenticated;
drop trigger if exists rt_touch on public.reply_templates;
create or replace function app.rt_touch() returns trigger language plpgsql as $$ begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
create trigger rt_touch before update on public.reply_templates for each row execute function app.rt_touch();
create or replace function public.reply_template_used(p_id uuid) returns void
language sql security definer set search_path = public, app as $$ update public.reply_templates set use_count = use_count + 1 where id = p_id and app.is_active() $$;
grant execute on function public.reply_template_used(uuid) to authenticated;

insert into public.lookups(category, code, label, sort) values
 ('reply_cat','chao_hoi','Chào hỏi · giới thiệu',1), ('reply_cat','bao_gia','Báo giá · tư vấn',2), ('reply_cat','coc_thanh_toan','Cọc · thanh toán',3),
 ('reply_cat','van_chuyen','Vận chuyển · giao hàng',4), ('reply_cat','khieu_nai','Kiểm hàng · khiếu nại',5), ('reply_cat','cham_soc','Chăm sóc · giữ khách',6), ('reply_cat','chung','Khác',9)
on conflict do nothing;

insert into public.reply_templates(category, title, content, sort, created_by)
select * from (values
 ('khieu_nai', 'Nhắc kiểm hàng trong 48h sau khi giao', 'Dạ {danh_xung} ơi, đơn hàng của mình đã giao thành công ạ. {Danh_xung} vui lòng kiểm tra số lượng, chất lượng hàng giúp em trong vòng 48 giờ kể từ khi nhận nhé. Nếu có thiếu, lỗi hay sai mẫu, {danh_xung} chụp ảnh / quay video lúc mở hàng và báo em ngay để em làm việc với shop ạ. Sau 48 giờ, việc khiếu nại với shop rất khó khăn và khả năng không thành công cao. Em cảm ơn {danh_xung} nhiều ạ! 🙏', 1, null::uuid),
 ('chao_hoi', 'Chào khách mới', 'Dạ em chào {danh_xung}, em là {ten_sale} – Nam Trung Logistics. Bên em chuyên nhập khẩu chính ngạch, mua hộ, vận chuyển hàng Trung Quốc – Việt Nam trọn gói, có hóa đơn VAT đầy đủ. {Danh_xung} đang cần nhập mặt hàng gì để em tư vấn phương án tối ưu chi phí ạ?', 1, null),
 ('bao_gia', 'Gửi báo giá', 'Dạ em gửi {danh_xung} báo giá chi tiết đơn hàng ạ. Báo giá đã gồm tiền hàng, cước vận chuyển, phí dịch vụ, thuế và VAT; hiệu lực trong 5 ngày. {Danh_xung} xem giúp em, có điểm nào cần điều chỉnh em hỗ trợ ngay ạ.', 1, null),
 ('coc_thanh_toan', 'Hướng dẫn đặt cọc', 'Dạ để bên em tiến hành đặt hàng, {danh_xung} vui lòng chuyển khoản cọc theo mã QR trên báo giá giúp em, nội dung chuyển khoản đã ghi sẵn trên QR ạ. Nhận cọc xong em báo xác nhận và cập nhật tiến độ cho {danh_xung} ngay ạ.', 1, null),
 ('van_chuyen', 'Hàng đã về kho Việt Nam', 'Dạ hàng của {danh_xung} đã về kho Việt Nam ạ. Em gửi {danh_xung} thông tin cân nặng / số khối và số tiền còn lại cần thanh toán. {Danh_xung} xác nhận giúp em để em sắp xếp giao hàng sớm nhất ạ.', 1, null)
) v(category, title, content, sort, created_by)
where not exists (select 1 from public.reply_templates);

-- ---------- 4. Tải nhanh: đếm báo giá theo trạng thái phía máy chủ ----------
create or replace function public.quote_status_counts(p_sale uuid default null)
returns table(status text, n bigint) language sql stable security definer set search_path = public, app as $$
  select q.status, count(*) from public.quotations q
   where q.status <> 'da_thay_the' and (app.is_admin() or app.in_tree(q.sale_id)) and (p_sale is null or q.sale_id = p_sale)
   group by q.status
$$;
grant execute on function public.quote_status_counts(uuid) to authenticated;
create index if not exists quotations_sale_status on public.quotations(sale_id, status, created_at desc);
create index if not exists customers_owner_next on public.customers(owner_id, next_care_date) where deleted_at is null;

reset search_path;


-- >>>>> supabase/migrations/0014_v8.sql
-- =====================================================================
-- 0014 · Bản 8: sửa công thức COM Mua hàng (hệ số theo % hoàn thành chỉ tiêu đàm phán), KPI số đơn MH (tùy chọn)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 8');

update public.settings set value = jsonb_set(value, '{buyer_com}',
  (coalesce(value->'buyer_com', '{}'::jsonb) - 'coef_pct') || jsonb_build_object(
    'fee_pct', coalesce((value->'buyer_com'->>'fee_pct')::numeric, 2),
    'nego_pct_by_month', coalesce(value->'buyer_com'->'nego_pct_by_month', '[2,3,4,5]'::jsonb),
    'target_pct_by_month', coalesce(value->'buyer_com'->'target_pct_by_month', '[2,2.4,2.7,3]'::jsonb),
    'coef_tiers', coalesce(value->'buyer_com'->'coef_tiers', '[{"from":50,"coef":70},{"from":80,"coef":85},{"from":95,"coef":100},{"from":120,"coef":110},{"from":130,"coef":120}]'::jsonb),
    'coef_on_fee', coalesce((value->'buyer_com'->>'coef_on_fee')::boolean, false)))
  || jsonb_build_object('buyer_kpi', coalesce(value->'buyer_kpi', '{"enabled":false,"orders":900,"share_pct":30,"profile_ids":[]}'::jsonb))
 where key = 'payroll';

create or replace function public.payroll_compute(p_period uuid)
returns int language plpgsql security definer set search_path = public, app as $$
declare
  per record; p record; pcfg jsonb := coalesce(app.setting('payroll'),'{}');
  m_start date; m_end date; d date; info jsonb;
  std numeric; paid numeric; worked numeric; pleave numeric; unpaid numeric; late int; over int;
  flex_min int := coalesce(app.setting_num('attendance','flex_minutes'), 100)::int; flex_from date := coalesce((app.setting('attendance')->>'flex_start')::date, '2026-11-01');
  base_pct numeric := coalesce((pcfg->>'commission_base_pct')::numeric, 60); max_off numeric := coalesce((pcfg->>'loss_offset_max_pct')::numeric, 50);
  priv record; lvl record; pos numeric; loss numeric; carry_in numeric; com numeric; off numeric; team numeric; adj numeric; sal numeric; flexded numeric; n int := 0; detail jsonb;
  bcfg jsonb := coalesce(pcfg->'buyer_com', '{}'); ccfg jsonb := coalesce(pcfg->'cskh_com', '{}'); acfg jsonb := coalesce(pcfg->'accounting_com', '{}');
  b_fee numeric; b_nego numeric; b_goods numeric; b_orders int; b_month int; b_nego_pct numeric; b_coef numeric; b_target numeric; b_rate numeric; b_ach numeric; b_tier jsonb; kcfg jsonb := coalesce(pcfg->'buyer_kpi', '{}'); k_pct numeric; k_share numeric; k_target numeric; k_on boolean; c_buyer numeric; c_fee numeric; c_nego numeric; c_orders int; c_cskh numeric;
  c_acc numeric; total_profit numeric;
begin
  if not app.has_role('admin','bgd','hcns','ke_toan') then raise exception 'Không có quyền tính lương'; end if;
  select * into per from public.payroll_periods where id = p_period for update;
  if per.id is null then raise exception 'Kỳ lương không tồn tại'; end if;
  if per.status not in ('open','review') then raise exception 'Kỳ lương đang chờ duyệt hoặc đã chốt'; end if;
  m_start := per.month; m_end := (per.month + interval '1 month - 1 day')::date;
  select coalesce(sum(order_profit), 0) into total_profit from public.order_results where period_id = p_period;
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
    -- COM Mua hàng = Phí mua hàng × a% + Hoa hồng đàm phán × b% (theo tháng thâm niên) × Hệ số
    --   Hệ số theo % hoàn thành chỉ tiêu đàm phán: tỷ lệ đạt = Σ đàm phán / Σ tiền hàng (VND); hoàn thành = tỷ lệ đạt / chỉ tiêu tháng thâm niên
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), coalesce(sum(goods_value), 0), count(*) into b_fee, b_nego, b_goods, b_orders
      from public.order_results where period_id = p_period and buyer_id = p.id;
    c_buyer := 0; b_month := null; b_nego_pct := 0; b_coef := 0; b_target := null; b_rate := null; b_ach := null;
    if coalesce((bcfg->>'enabled')::boolean, true) and b_orders > 0 then
      b_month := case when p.hire_date is null then 99 else
        (extract(year from age(m_start, date_trunc('month', p.hire_date)::date)) * 12 + extract(month from age(m_start, date_trunc('month', p.hire_date)::date)))::int + 1 end;
      b_nego_pct := coalesce((bcfg->'nego_pct_by_month'->>(least(greatest(b_month, 1), 4) - 1))::numeric, (array[2,3,4,5])[least(greatest(b_month, 1), 4)]);
      b_target := coalesce((bcfg->'target_pct_by_month'->>(least(greatest(b_month, 1), 4) - 1))::numeric, (array[2,2.4,2.7,3])[least(greatest(b_month, 1), 4)]);
      b_rate := case when b_goods > 0 then round(b_nego / b_goods * 100, 4) else 0 end;
      b_ach := case when b_target > 0 then round(b_rate / b_target * 100, 2) else 0 end;
      b_coef := 0;
      for b_tier in select x from jsonb_array_elements(coalesce(bcfg->'coef_tiers', '[{"from":50,"coef":70},{"from":80,"coef":85},{"from":95,"coef":100},{"from":120,"coef":110},{"from":130,"coef":120}]'::jsonb)) x
                    order by (x->>'from')::numeric loop
        if b_ach >= (b_tier->>'from')::numeric then b_coef := (b_tier->>'coef')::numeric; end if;
      end loop;
      c_buyer := round(b_fee * coalesce((bcfg->>'fee_pct')::numeric, 2) / 100 * (case when coalesce((bcfg->>'coef_on_fee')::boolean, false) then b_coef / 100 else 1 end)
                       + b_nego * b_nego_pct / 100 * b_coef / 100);
    end if;
    -- Lương Mua hàng theo KPI số đơn (tắt mặc định): lương × (1 − x%) + lương × x% × min(số đơn / chỉ tiêu, 1)
    k_on := coalesce((kcfg->>'enabled')::boolean, false) and p.id::text in (select jsonb_array_elements_text(coalesce(kcfg->'profile_ids', '[]')));
    k_share := coalesce((kcfg->>'share_pct')::numeric, 30); k_target := coalesce((kcfg->>'orders')::numeric, 900); k_pct := null;
    if k_on and k_target > 0 then
      k_pct := least(coalesce(b_orders, 0) / k_target, 1);
      sal := round(sal * (1 - k_share / 100) + sal * k_share / 100 * k_pct);
    end if;
    -- COM CSKH: Phí dịch vụ × 2% + Phí đàm phán × 1% các đơn hoàn thành mình phụ trách
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), count(*) into c_fee, c_nego, c_orders
      from public.order_results where period_id = p_period and cskh_id = p.id;
    c_cskh := case when coalesce((ccfg->>'enabled')::boolean, true) and c_orders > 0
                   then round(c_fee * coalesce((ccfg->>'fee_pct')::numeric, 2) / 100 + c_nego * coalesce((ccfg->>'nego_pct')::numeric, 1) / 100) else 0 end;
    -- COM Trưởng phòng Kế toán: 0,5% × 60% × LN đơn hoàn thành cả công ty
    c_acc := case when p.id::text in (select jsonb_array_elements_text(coalesce(acfg->'profile_ids', '[]'))) and total_profit > 0
                  then round(total_profit * coalesce((acfg->>'base_pct')::numeric, 60) / 100 * coalesce((acfg->>'pct')::numeric, 0.5) / 100) else 0 end;
    select coalesce(sum(a.amount),0) into adj from public.payslip_adjustments a join public.payslips ps on ps.id = a.payslip_id where ps.period_id = p_period and ps.profile_id = p.id;
    detail := jsonb_build_object('late_minutes', late, 'flex_minutes', flex_min, 'flex_active', m_start >= flex_from, 'commission_pct', coalesce(lvl.commission_pct,0),
      'commission_base_pct', base_pct, 'loss_this_month', loss, 'carry_in', carry_in, 'orders', (select count(*) from public.order_results where period_id = p_period and profile_id = p.id),
      'buyer', jsonb_build_object('orders', b_orders, 'purchase_fee', b_fee, 'nego_fee', b_nego, 'goods', b_goods, 'month', b_month, 'fee_pct', coalesce((bcfg->>'fee_pct')::numeric, 2), 'nego_pct', b_nego_pct,
        'target_pct', b_target, 'rate_pct', b_rate, 'ach_pct', b_ach, 'coef_pct', b_coef, 'coef_on_fee', coalesce((bcfg->>'coef_on_fee')::boolean, false)),
      'buyer_kpi', case when k_on then jsonb_build_object('orders', b_orders, 'target', k_target, 'share_pct', k_share, 'pct', round(k_pct * 100, 2)) end,
      'cskh', jsonb_build_object('orders', c_orders, 'purchase_fee', c_fee, 'nego_fee', c_nego, 'fee_pct', coalesce((ccfg->>'fee_pct')::numeric, 2), 'nego_pct', coalesce((ccfg->>'nego_pct')::numeric, 1)),
      'accounting', jsonb_build_object('total_profit', total_profit, 'base_pct', coalesce((acfg->>'base_pct')::numeric, 60), 'pct', coalesce((acfg->>'pct')::numeric, 0.5)));
    insert into public.payslips as ps(period_id, profile_id, standard_days, paid_days, worked_days, paid_leave_days, unpaid_days, late_minutes, flex_over_minutes, base_salary,
      salary_by_days, allowance, profit_total, commission_base, commission, loss_offset, carry_loss, team_bonus, com_buyer, com_cskh, com_accounting, flex_deduction, insurance, adjustments, net, details, status, updated_at)
    values (p_period, p.id, std, least(paid, std), worked, pleave, greatest(unpaid, 0), late, over, coalesce(priv.base_salary,0), sal, coalesce(priv.allowance,0),
      (select coalesce(sum(order_profit),0) from public.order_results where period_id = p_period and profile_id = p.id),
      pos, com, off, loss + carry_in - off, team, c_buyer, c_cskh, c_acc, flexded, coalesce(priv.insurance_deduction,0), adj,
      sal + coalesce(priv.allowance,0) + com - off + team + c_buyer + c_cskh + c_acc - flexded - coalesce(priv.insurance_deduction,0) + adj, detail, 'draft', now())
    on conflict (period_id, profile_id) do update set standard_days = excluded.standard_days, paid_days = excluded.paid_days, worked_days = excluded.worked_days,
      paid_leave_days = excluded.paid_leave_days, unpaid_days = excluded.unpaid_days, late_minutes = excluded.late_minutes, flex_over_minutes = excluded.flex_over_minutes,
      base_salary = excluded.base_salary, salary_by_days = excluded.salary_by_days, allowance = excluded.allowance, profit_total = excluded.profit_total,
      commission_base = excluded.commission_base, commission = excluded.commission, loss_offset = excluded.loss_offset, carry_loss = excluded.carry_loss,
      team_bonus = excluded.team_bonus, com_buyer = excluded.com_buyer, com_cskh = excluded.com_cskh, com_accounting = excluded.com_accounting, flex_deduction = excluded.flex_deduction, insurance = excluded.insurance, adjustments = excluded.adjustments,
      net = excluded.net, details = excluded.details, status = 'draft', confirmed_at = null, updated_at = now()
    where ps.status <> 'closed';
    n := n + 1;
  end loop;
  update public.payroll_periods set computed_at = now(), status = 'open' where id = p_period;
  return n;
end $$;

reset search_path;


-- >>>>> supabase/migrations/0015_v9.sql
-- =====================================================================
-- 0015 · Bản 9: mẫu số % đàm phán = Tiền hàng trên web + Phí vận chuyển nội địa TQ (VND)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 9');

alter table public.order_results add column if not exists domestic_ship numeric(18,0) not null default 0;  -- Phí vận chuyển nội địa TQ (VND)
-- Lấy lại từ dữ liệu gốc đã nhập (cột raw) để không phải nhập lại file
update public.order_results o set domestic_ship = coalesce((
  select round(nullif(regexp_replace(e.value, '[^0-9.-]', '', 'g'), '')::numeric) from jsonb_each_text(o.raw) e
   where app.norm_text(e.key) like 'phi van chuyen noi dia%' and app.norm_text(e.key) like '%vnd%' limit 1), 0)
 where o.raw is not null;

create or replace function public.import_order_results(p_period uuid, p_rows jsonb, p_replace boolean default true)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_pid uuid; v_cskh uuid; v_buyer uuid; n int := 0; unmapped text[] := '{}'; st text;
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
    v_cskh := app.match_staff(r->>'cskh_name'); v_buyer := app.match_staff(r->>'buyer_name');
    if v_cskh is null and app.is_assigned(r->>'cskh_name') then unmapped := unmapped || ('CSKH: ' || (r->>'cskh_name')); end if;
    if v_buyer is null and app.is_assigned(r->>'buyer_name') then unmapped := unmapped || ('Mua hàng: ' || (r->>'buyer_name')); end if;
    insert into public.order_results(period_id, ext_order_code, sale_name, profile_id, customer_ext, warehouse, order_type, completed_at, goods_value, order_profit, raw,
                                     cskh_name, cskh_id, buyer_name, buyer_id, purchase_fee, nego_fee, domestic_ship)
    values (p_period, btrim(r->>'ext_order_code'), r->>'sale_name', v_pid, r->>'customer_ext', r->>'warehouse', r->>'order_type',
            (r->>'completed_at')::date, coalesce((r->>'goods_value')::numeric,0), coalesce((r->>'order_profit')::numeric,0), r->'raw',
            nullif(r->>'cskh_name', ''), v_cskh, nullif(r->>'buyer_name', ''), v_buyer, coalesce((r->>'purchase_fee')::numeric, 0), coalesce((r->>'nego_fee')::numeric, 0), coalesce((r->>'domestic_ship')::numeric, 0))
    on conflict (period_id, ext_order_code) do update set sale_name = excluded.sale_name, profile_id = excluded.profile_id,
       completed_at = excluded.completed_at, goods_value = excluded.goods_value, order_profit = excluded.order_profit, raw = excluded.raw,
       cskh_name = excluded.cskh_name, cskh_id = excluded.cskh_id, buyer_name = excluded.buyer_name, buyer_id = excluded.buyer_id,
       purchase_fee = excluded.purchase_fee, nego_fee = excluded.nego_fee, domestic_ship = excluded.domestic_ship;
    n := n + 1;
  end loop;
  return jsonb_build_object('imported', n, 'unmapped', (select coalesce(jsonb_agg(distinct x), '[]') from unnest(unmapped) x));
end $$;

create or replace function public.payroll_compute(p_period uuid)
returns int language plpgsql security definer set search_path = public, app as $$
declare
  per record; p record; pcfg jsonb := coalesce(app.setting('payroll'),'{}');
  m_start date; m_end date; d date; info jsonb;
  std numeric; paid numeric; worked numeric; pleave numeric; unpaid numeric; late int; over int;
  flex_min int := coalesce(app.setting_num('attendance','flex_minutes'), 100)::int; flex_from date := coalesce((app.setting('attendance')->>'flex_start')::date, '2026-11-01');
  base_pct numeric := coalesce((pcfg->>'commission_base_pct')::numeric, 60); max_off numeric := coalesce((pcfg->>'loss_offset_max_pct')::numeric, 50);
  priv record; lvl record; pos numeric; loss numeric; carry_in numeric; com numeric; off numeric; team numeric; adj numeric; sal numeric; flexded numeric; n int := 0; detail jsonb;
  bcfg jsonb := coalesce(pcfg->'buyer_com', '{}'); ccfg jsonb := coalesce(pcfg->'cskh_com', '{}'); acfg jsonb := coalesce(pcfg->'accounting_com', '{}');
  b_fee numeric; b_nego numeric; b_goods numeric; b_orders int; b_month int; b_nego_pct numeric; b_coef numeric; b_target numeric; b_rate numeric; b_ach numeric; b_tier jsonb; kcfg jsonb := coalesce(pcfg->'buyer_kpi', '{}'); k_pct numeric; k_share numeric; k_target numeric; k_on boolean; c_buyer numeric; c_fee numeric; c_nego numeric; c_orders int; c_cskh numeric;
  c_acc numeric; total_profit numeric;
begin
  if not app.has_role('admin','bgd','hcns','ke_toan') then raise exception 'Không có quyền tính lương'; end if;
  select * into per from public.payroll_periods where id = p_period for update;
  if per.id is null then raise exception 'Kỳ lương không tồn tại'; end if;
  if per.status not in ('open','review') then raise exception 'Kỳ lương đang chờ duyệt hoặc đã chốt'; end if;
  m_start := per.month; m_end := (per.month + interval '1 month - 1 day')::date;
  select coalesce(sum(order_profit), 0) into total_profit from public.order_results where period_id = p_period;
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
    -- COM Mua hàng = Phí mua hàng × a% + Hoa hồng đàm phán × b% (theo tháng thâm niên) × Hệ số
    --   Hệ số theo % hoàn thành chỉ tiêu đàm phán: tỷ lệ đạt = Σ đàm phán / Σ (tiền hàng web + phí VC nội địa TQ) (VND); hoàn thành = tỷ lệ đạt / chỉ tiêu tháng thâm niên
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), coalesce(sum(goods_value + domestic_ship), 0), count(*) into b_fee, b_nego, b_goods, b_orders
      from public.order_results where period_id = p_period and buyer_id = p.id;
    c_buyer := 0; b_month := null; b_nego_pct := 0; b_coef := 0; b_target := null; b_rate := null; b_ach := null;
    if coalesce((bcfg->>'enabled')::boolean, true) and b_orders > 0 then
      b_month := case when p.hire_date is null then 99 else
        (extract(year from age(m_start, date_trunc('month', p.hire_date)::date)) * 12 + extract(month from age(m_start, date_trunc('month', p.hire_date)::date)))::int + 1 end;
      b_nego_pct := coalesce((bcfg->'nego_pct_by_month'->>(least(greatest(b_month, 1), 4) - 1))::numeric, (array[2,3,4,5])[least(greatest(b_month, 1), 4)]);
      b_target := coalesce((bcfg->'target_pct_by_month'->>(least(greatest(b_month, 1), 4) - 1))::numeric, (array[2,2.4,2.7,3])[least(greatest(b_month, 1), 4)]);
      b_rate := case when b_goods > 0 then round(b_nego / b_goods * 100, 4) else 0 end;
      b_ach := case when b_target > 0 then round(b_rate / b_target * 100, 2) else 0 end;
      b_coef := 0;
      for b_tier in select x from jsonb_array_elements(coalesce(bcfg->'coef_tiers', '[{"from":50,"coef":70},{"from":80,"coef":85},{"from":95,"coef":100},{"from":120,"coef":110},{"from":130,"coef":120}]'::jsonb)) x
                    order by (x->>'from')::numeric loop
        if b_ach >= (b_tier->>'from')::numeric then b_coef := (b_tier->>'coef')::numeric; end if;
      end loop;
      c_buyer := round(b_fee * coalesce((bcfg->>'fee_pct')::numeric, 2) / 100 * (case when coalesce((bcfg->>'coef_on_fee')::boolean, false) then b_coef / 100 else 1 end)
                       + b_nego * b_nego_pct / 100 * b_coef / 100);
    end if;
    -- Lương Mua hàng theo KPI số đơn (tắt mặc định): lương × (1 − x%) + lương × x% × min(số đơn / chỉ tiêu, 1)
    k_on := coalesce((kcfg->>'enabled')::boolean, false) and p.id::text in (select jsonb_array_elements_text(coalesce(kcfg->'profile_ids', '[]')));
    k_share := coalesce((kcfg->>'share_pct')::numeric, 30); k_target := coalesce((kcfg->>'orders')::numeric, 900); k_pct := null;
    if k_on and k_target > 0 then
      k_pct := least(coalesce(b_orders, 0) / k_target, 1);
      sal := round(sal * (1 - k_share / 100) + sal * k_share / 100 * k_pct);
    end if;
    -- COM CSKH: Phí dịch vụ × 2% + Phí đàm phán × 1% các đơn hoàn thành mình phụ trách
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), count(*) into c_fee, c_nego, c_orders
      from public.order_results where period_id = p_period and cskh_id = p.id;
    c_cskh := case when coalesce((ccfg->>'enabled')::boolean, true) and c_orders > 0
                   then round(c_fee * coalesce((ccfg->>'fee_pct')::numeric, 2) / 100 + c_nego * coalesce((ccfg->>'nego_pct')::numeric, 1) / 100) else 0 end;
    -- COM Trưởng phòng Kế toán: 0,5% × 60% × LN đơn hoàn thành cả công ty
    c_acc := case when p.id::text in (select jsonb_array_elements_text(coalesce(acfg->'profile_ids', '[]'))) and total_profit > 0
                  then round(total_profit * coalesce((acfg->>'base_pct')::numeric, 60) / 100 * coalesce((acfg->>'pct')::numeric, 0.5) / 100) else 0 end;
    select coalesce(sum(a.amount),0) into adj from public.payslip_adjustments a join public.payslips ps on ps.id = a.payslip_id where ps.period_id = p_period and ps.profile_id = p.id;
    detail := jsonb_build_object('late_minutes', late, 'flex_minutes', flex_min, 'flex_active', m_start >= flex_from, 'commission_pct', coalesce(lvl.commission_pct,0),
      'commission_base_pct', base_pct, 'loss_this_month', loss, 'carry_in', carry_in, 'orders', (select count(*) from public.order_results where period_id = p_period and profile_id = p.id),
      'buyer', jsonb_build_object('orders', b_orders, 'purchase_fee', b_fee, 'nego_fee', b_nego, 'goods', b_goods, 'month', b_month, 'fee_pct', coalesce((bcfg->>'fee_pct')::numeric, 2), 'nego_pct', b_nego_pct,
        'target_pct', b_target, 'rate_pct', b_rate, 'ach_pct', b_ach, 'coef_pct', b_coef, 'coef_on_fee', coalesce((bcfg->>'coef_on_fee')::boolean, false)),
      'buyer_kpi', case when k_on then jsonb_build_object('orders', b_orders, 'target', k_target, 'share_pct', k_share, 'pct', round(k_pct * 100, 2)) end,
      'cskh', jsonb_build_object('orders', c_orders, 'purchase_fee', c_fee, 'nego_fee', c_nego, 'fee_pct', coalesce((ccfg->>'fee_pct')::numeric, 2), 'nego_pct', coalesce((ccfg->>'nego_pct')::numeric, 1)),
      'accounting', jsonb_build_object('total_profit', total_profit, 'base_pct', coalesce((acfg->>'base_pct')::numeric, 60), 'pct', coalesce((acfg->>'pct')::numeric, 0.5)));
    insert into public.payslips as ps(period_id, profile_id, standard_days, paid_days, worked_days, paid_leave_days, unpaid_days, late_minutes, flex_over_minutes, base_salary,
      salary_by_days, allowance, profit_total, commission_base, commission, loss_offset, carry_loss, team_bonus, com_buyer, com_cskh, com_accounting, flex_deduction, insurance, adjustments, net, details, status, updated_at)
    values (p_period, p.id, std, least(paid, std), worked, pleave, greatest(unpaid, 0), late, over, coalesce(priv.base_salary,0), sal, coalesce(priv.allowance,0),
      (select coalesce(sum(order_profit),0) from public.order_results where period_id = p_period and profile_id = p.id),
      pos, com, off, loss + carry_in - off, team, c_buyer, c_cskh, c_acc, flexded, coalesce(priv.insurance_deduction,0), adj,
      sal + coalesce(priv.allowance,0) + com - off + team + c_buyer + c_cskh + c_acc - flexded - coalesce(priv.insurance_deduction,0) + adj, detail, 'draft', now())
    on conflict (period_id, profile_id) do update set standard_days = excluded.standard_days, paid_days = excluded.paid_days, worked_days = excluded.worked_days,
      paid_leave_days = excluded.paid_leave_days, unpaid_days = excluded.unpaid_days, late_minutes = excluded.late_minutes, flex_over_minutes = excluded.flex_over_minutes,
      base_salary = excluded.base_salary, salary_by_days = excluded.salary_by_days, allowance = excluded.allowance, profit_total = excluded.profit_total,
      commission_base = excluded.commission_base, commission = excluded.commission, loss_offset = excluded.loss_offset, carry_loss = excluded.carry_loss,
      team_bonus = excluded.team_bonus, com_buyer = excluded.com_buyer, com_cskh = excluded.com_cskh, com_accounting = excluded.com_accounting, flex_deduction = excluded.flex_deduction, insurance = excluded.insurance, adjustments = excluded.adjustments,
      net = excluded.net, details = excluded.details, status = 'draft', confirmed_at = null, updated_at = now()
    where ps.status <> 'closed';
    n := n + 1;
  end loop;
  update public.payroll_periods set computed_at = now(), status = 'open' where id = p_period;
  return n;
end $$;

reset search_path;


-- >>>>> supabase/migrations/0016_v10.sql
-- =====================================================================
-- 0016 · Bản 10: Kế toán – Hóa đơn (đợt 1: đối soát xe APT B1 + HĐ đầu vào B2) · Sao lưu hằng ngày lên Google Drive
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 10');

-- ---------- Cấu hình ----------
insert into public.settings(key, value) values ('accounting', jsonb_build_object(
  'bien_muc_tieu', 0.03, 'bien_nt_min', 0.025, 'bien_nt_max', 0.04, 'dung_sai_bien', 0.001, 'tien_bo_qua', 50000, 'nguong_ghep', 0.65,
  'sale_lanchi', '["huyennk29","yenttt","Yentth"]'::jsonb, 'md_xuat_thang', '["MD2421","MD2744","MD2784","MD2785"]'::jsonb,
  'hs_hop_quy_chuong', '["50","51","52","53","54","55","56","57","58","59","60","61","62","63"]'::jsonb, 'han_sale_gio', 24,
  'approver_ids', '[]'::jsonb,
  'sale_names', '[{"acc":"khoile","names":["Lê Thị Minh Khơi","Khơi Lê"]},{"acc":"trungdv22","names":["Đỗ Văn Trung","Trungdv22"]},
    {"acc":"trangdtk","names":["Đắc Thị Kiều Trang","Trang"]},{"acc":"Linhnt","names":["Nguyễn Thị Linh","Linh NT"]},{"acc":"huevt","names":["Vũ Thị Huệ","Huệ Vũ"]},
    {"acc":"thuyltp","names":["Lê Thị Phương Thúy","Phương Thúy"]},{"acc":"ngocdtb","names":["Đào Bích Ngọc"]},{"acc":"huyenttt","names":["Trần Thị Thanh Huyền","Huyền Trần"]},
    {"acc":"huyennk29","names":[]},{"acc":"yenttt","names":["Yentth"]}]'::jsonb
)) on conflict (key) do nothing;
insert into public.settings(key, value) values ('drive', '{}'::jsonb) on conflict (key) do nothing;

create or replace function public.set_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_old jsonb;
begin
  if not (app.is_admin() or (app.has_role('hcns') and p_key in ('attendance','leave','payroll'))
          or (app.has_role('ke_toan') and p_key in ('vietqr','payroll','quote_defaults','accounting'))) then
    raise exception 'Không có quyền sửa cấu hình %', p_key;
  end if;
  -- Kế toán không tự thêm người duyệt mở chặn: chỉ Admin/BGĐ
  if p_key = 'accounting' and not app.is_admin() then
    select value into v_old from public.settings where key = p_key;
    p_value := jsonb_set(p_value, '{approver_ids}', coalesce(v_old->'approver_ids', '[]'));
  end if;
  select value into v_old from public.settings where key = p_key;
  insert into public.settings(key, value, updated_by) values (p_key, p_value, auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  insert into public.settings_history(key, old_value, new_value, changed_by) values (p_key, v_old, p_value, auth.uid());
end $$;

create or replace function app.is_acc() returns boolean language sql stable security definer set search_path = public, app as $$
  select app.has_role('admin','bgd','ke_toan')
$$;
create or replace function app.is_acc_approver() returns boolean language sql stable security definer set search_path = public, app as $$
  select app.is_admin() or auth.uid()::text in (select jsonb_array_elements_text(coalesce(app.setting('accounting')->'approver_ids', '[]')))
$$;

-- ---------- Bảng ----------
create table if not exists public.acc_trucks(
  id uuid primary key default gen_random_uuid(),
  name text not null,                              -- VD: Xe 25/10/2026
  truck_date date,
  files jsonb not null default '{}',               -- tên file đã nạp
  stats jsonb not null default '{}',
  warnings text[] not null default '{}',
  status text not null default 'open' check (status in ('open','closed')),
  created_by uuid default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.acc_lines(
  id uuid primary key default gen_random_uuid(),
  truck_id uuid not null references public.acc_trucks(id) on delete cascade,
  line_key text not null,
  ma_dong text, md text, sale_name text, sale_acc text, sale_id uuid references public.profiles(id), ma_kh text,
  sys_row int, ten_ht text, sl_ht numeric, dvt_ht text, gia_khach numeric, nk_ht numeric,
  apt_stt int, hh text, dh text, sale_apt text, ten_apt text, sl_apt numeric, dvt_apt text, gia_nhap numeric, gia_note numeric, note_apt text, nk_apt numeric, vat numeric,
  tk_row int, ten_tk text, hs text, sl_tk numeric, dvt_tk text, gia_tk_nh numeric, nk_tk numeric, tnk_dv numeric, md_header text,
  luong text not null, gia_ap_dung numeric, gia_de_xuat numeric, bien_nt numeric, tt_apt numeric, tt_khach numeric,
  status text not null check (status in ('ok','blocked','replied','pending_approval','approved','info')),
  level int not null default 3, issues text[] not null default '{}', notes text[] not null default '{}', phan_hoi text, match_score numeric,
  due_at timestamptz,
  reply text check (reply in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet')), reply_price numeric, reply_note text, replied_by uuid references public.profiles(id), replied_at timestamptz,
  approved_by uuid references public.profiles(id), approved_at timestamptz, approve_note text,
  inv_id uuid, inv_no text, inv_stt int, inv_price numeric, inv_qty numeric, inv_amount numeric, inv_result text,
  updated_at timestamptz not null default now(),
  unique (truck_id, line_key)
);
create index if not exists acc_lines_sale on public.acc_lines(sale_id, status);
create index if not exists acc_lines_hh on public.acc_lines(hh);
create index if not exists acc_lines_md on public.acc_lines(md);
create table if not exists public.acc_invoices(
  id uuid primary key default gen_random_uuid(),
  ky_hieu text not null, so_hd text not null, ngay date, mst_ban text, ten_ban text, mst_mua text, ten_mua text,
  tong_truoc_thue numeric, tien_thue numeric, tong numeric, file_name text,
  stats jsonb not null default '{}',
  created_by uuid default auth.uid() references public.profiles(id), created_at timestamptz not null default now(),
  unique (mst_ban, ky_hieu, so_hd)
);
create table if not exists public.acc_invoice_lines(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.acc_invoices(id) on delete cascade,
  stt int not null, hh text, ten text, dvt text, sl numeric, dg numeric, tt numeric, vat text,
  line_id uuid references public.acc_lines(id) on delete set null, result text not null,
  unique (invoice_id, stt)
);
create table if not exists public.acc_events(
  id bigint generated always as identity primary key,
  line_id uuid references public.acc_lines(id) on delete cascade,
  truck_id uuid references public.acc_trucks(id) on delete cascade,
  action text not null, note text, data jsonb,
  actor uuid default auth.uid() references public.profiles(id), at timestamptz not null default now()
);
create index if not exists acc_events_line on public.acc_events(line_id, at desc);

alter table public.acc_trucks enable row level security;
alter table public.acc_lines enable row level security;
alter table public.acc_invoices enable row level security;
alter table public.acc_invoice_lines enable row level security;
alter table public.acc_events enable row level security;
drop policy if exists acc_trucks_read on public.acc_trucks;
create policy acc_trucks_read on public.acc_trucks for select to authenticated using (app.is_acc() or app.is_acc_approver() or exists(select 1 from public.acc_lines l where l.truck_id = acc_trucks.id and app.in_tree(l.sale_id)));
drop policy if exists acc_trucks_write on public.acc_trucks;
create policy acc_trucks_write on public.acc_trucks for all to authenticated using (app.is_acc()) with check (app.is_acc());
drop policy if exists acc_lines_read on public.acc_lines;
create policy acc_lines_read on public.acc_lines for select to authenticated using (app.is_acc() or app.in_tree(sale_id) or (app.is_acc_approver() and status = 'pending_approval'));
drop policy if exists acc_lines_write on public.acc_lines;
create policy acc_lines_write on public.acc_lines for all to authenticated using (app.is_acc()) with check (app.is_acc());
drop policy if exists acc_inv_all on public.acc_invoices;
create policy acc_inv_all on public.acc_invoices for all to authenticated using (app.is_acc()) with check (app.is_acc());
drop policy if exists acc_invl_all on public.acc_invoice_lines;
create policy acc_invl_all on public.acc_invoice_lines for all to authenticated using (app.is_acc()) with check (app.is_acc());
drop policy if exists acc_ev_read on public.acc_events;
create policy acc_ev_read on public.acc_events for select to authenticated using (app.is_acc() or exists(select 1 from public.acc_lines l where l.id = acc_events.line_id and (app.in_tree(l.sale_id) or app.is_acc_approver())));
grant select, insert, update, delete on public.acc_trucks, public.acc_lines, public.acc_invoices, public.acc_invoice_lines to authenticated;
grant select on public.acc_events to authenticated;

-- Ghép sale trong file với nhân sự: tên trong file / họ tên / mã NV (không dấu, không phân biệt hoa thường)
create or replace function app.match_sale(p_name text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.match_staff(p_name), (
    select p.id from public.profiles p where app.is_assigned(p_name)
       and app.norm_text(p_name) = any(select app.norm_text(x) from unnest(p.sale_aliases || p.full_name) x) limit 1))
$$;

-- ---------- Lưu kết quả đối soát 1 xe (nạp lại: giữ trả lời của sale theo line_key) ----------
create or replace function public.acc_truck_save(p_truck uuid, p_info jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := p_truck; r jsonb; v_sale uuid; v_old public.acc_lines; v_status text; v_due timestamptz;
        h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); n_block int; s record; v_keys text[] := '{}';
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán được nạp đối soát'; end if;
  if v_id is null then
    insert into public.acc_trucks(name, truck_date, files, stats, warnings)
    values (p_info->>'name', nullif(p_info->>'truck_date','')::date, coalesce(p_info->'files','{}'), coalesce(p_info->'stats','{}'),
            coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), '{}'))
    returning id into v_id;
  else
    update public.acc_trucks set name = coalesce(p_info->>'name', name), truck_date = coalesce(nullif(p_info->>'truck_date','')::date, truck_date),
      files = coalesce(p_info->'files', files), stats = coalesce(p_info->'stats', stats),
      warnings = coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), warnings), updated_at = now() where id = v_id;
  end if;
  for r in select * from jsonb_array_elements(p_lines) loop
    v_keys := v_keys || (r->>'line_key');
    v_sale := coalesce(nullif(r->>'sale_id','')::uuid, app.match_sale(r->>'sale_name'), app.match_sale(r->>'sale_acc'));
    select * into v_old from public.acc_lines where truck_id = v_id and line_key = r->>'line_key';
    v_status := r->>'status';
    -- Đã được duyệt mở chặn thì giữ; sale đã trả lời mà vẫn chặn → giữ trạng thái đã trả lời
    if v_old.id is not null and v_status = 'blocked' and v_old.status in ('approved','replied','pending_approval') then v_status := v_old.status; end if;
    v_due := case when v_status = 'blocked' then coalesce(v_old.due_at, now() + make_interval(hours => h)) else null end;
    insert into public.acc_lines as l(truck_id, line_key, ma_dong, md, sale_name, sale_acc, sale_id, ma_kh, sys_row, ten_ht, sl_ht, dvt_ht, gia_khach, nk_ht,
      apt_stt, hh, dh, sale_apt, ten_apt, sl_apt, dvt_apt, gia_nhap, gia_note, note_apt, nk_apt, vat, tk_row, ten_tk, hs, sl_tk, dvt_tk, gia_tk_nh, nk_tk, tnk_dv, md_header,
      luong, gia_ap_dung, gia_de_xuat, bien_nt, tt_apt, tt_khach, status, level, issues, notes, phan_hoi, match_score, due_at, updated_at)
    select v_id, x.line_key, x.ma_dong, x.md, x.sale_name, x.sale_acc, v_sale, x.ma_kh, x.sys_row, x.ten_ht, x.sl_ht, x.dvt_ht, x.gia_khach, x.nk_ht,
      x.apt_stt, x.hh, x.dh, x.sale_apt, x.ten_apt, x.sl_apt, x.dvt_apt, x.gia_nhap, x.gia_note, x.note_apt, x.nk_apt, x.vat, x.tk_row, x.ten_tk, x.hs, x.sl_tk, x.dvt_tk, x.gia_tk_nh, x.nk_tk, x.tnk_dv, x.md_header,
      x.luong, x.gia_ap_dung, x.gia_de_xuat, x.bien_nt, x.tt_apt, x.tt_khach, v_status, x.level, coalesce(x.issues, '{}'), coalesce(x.notes, '{}'), x.phan_hoi, x.match_score, v_due, now()
    from jsonb_populate_record(null::public.acc_lines, r) x
    on conflict (truck_id, line_key) do update set ma_dong = excluded.ma_dong, md = excluded.md, sale_name = excluded.sale_name, sale_acc = excluded.sale_acc, sale_id = excluded.sale_id,
      ma_kh = excluded.ma_kh, sys_row = excluded.sys_row, ten_ht = excluded.ten_ht, sl_ht = excluded.sl_ht, dvt_ht = excluded.dvt_ht, gia_khach = excluded.gia_khach, nk_ht = excluded.nk_ht,
      apt_stt = excluded.apt_stt, hh = excluded.hh, dh = excluded.dh, sale_apt = excluded.sale_apt, ten_apt = excluded.ten_apt, sl_apt = excluded.sl_apt, dvt_apt = excluded.dvt_apt,
      gia_nhap = excluded.gia_nhap, gia_note = excluded.gia_note, note_apt = excluded.note_apt, nk_apt = excluded.nk_apt, vat = excluded.vat, tk_row = excluded.tk_row, ten_tk = excluded.ten_tk,
      hs = excluded.hs, sl_tk = excluded.sl_tk, dvt_tk = excluded.dvt_tk, gia_tk_nh = excluded.gia_tk_nh, nk_tk = excluded.nk_tk, tnk_dv = excluded.tnk_dv, md_header = excluded.md_header,
      luong = excluded.luong, gia_ap_dung = excluded.gia_ap_dung, gia_de_xuat = excluded.gia_de_xuat, bien_nt = excluded.bien_nt, tt_apt = excluded.tt_apt, tt_khach = excluded.tt_khach,
      status = excluded.status, level = excluded.level, issues = excluded.issues, notes = excluded.notes, phan_hoi = excluded.phan_hoi, match_score = excluded.match_score,
      due_at = excluded.due_at, updated_at = now();
  end loop;
  -- Dòng cũ không còn trong lần nạp mới → xóa (đã có nhật ký)
  delete from public.acc_lines where truck_id = v_id and line_key <> all(v_keys);
  insert into public.acc_events(truck_id, action, note, data) values (v_id, case when p_truck is null then 'import' else 'reimport' end, p_info->>'name', p_info->'stats');
  -- Báo sale có dòng bị chặn
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', coalesce(p_info->>'name','') || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
  select count(*) into n_block from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is null;
  if n_block > 0 then perform app.notify_roles(array['ke_toan'], 'acc', n_block || ' dòng bị chặn chưa ghép được sale', p_info->>'name', '#/acc?truck=' || v_id); end if;
  return v_id;
end $$;
grant execute on function public.acc_truck_save(uuid, jsonb, jsonb) to authenticated;

-- ---------- Sale trả lời dòng bị chặn ----------
create or replace function public.acc_line_reply(p_id uuid, p_reply text, p_price numeric default null, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; v_status text;
begin
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if not (app.is_acc() or app.in_tree(l.sale_id)) then raise exception 'Dòng này không thuộc khách của bạn'; end if;
  if l.status not in ('blocked','replied') then raise exception 'Dòng không ở trạng thái chờ sale'; end if;
  if p_reply not in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet') then raise exception 'Lựa chọn không hợp lệ'; end if;
  if p_reply = 'de_xuat_gia' and coalesce(p_price, 0) <= 0 then raise exception 'Nhập giá đề xuất'; end if;
  if p_reply = 'xin_duyet' and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do xin duyệt ngoại lệ'; end if;
  v_status := case when p_reply = 'xin_duyet' then 'pending_approval' else 'replied' end;
  update public.acc_lines set reply = p_reply, reply_price = p_price, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(), status = v_status, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'reply', p_note, jsonb_build_object('reply', p_reply, 'price', p_price));
  if p_reply = 'xin_duyet' then
    perform app.notify(x::uuid, 'acc', 'Xin duyệt ngoại lệ HĐ: ' || coalesce(l.md, 'dòng không có đơn'), left(coalesce(l.ten_apt, l.ten_ht, ''), 80) || ' — ' || p_note, '#/acc/approve')
      from jsonb_array_elements_text(coalesce(app.setting('accounting')->'approver_ids', '[]')) x;
  end if;
end $$;
grant execute on function public.acc_line_reply(uuid, text, numeric, text) to authenticated;

-- ---------- Người được cấp quyền duyệt mở chặn ----------
create or replace function public.acc_line_approve(p_id uuid, p_ok boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines;
begin
  if not app.is_acc_approver() then raise exception 'Bạn không có quyền duyệt mở chặn'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if l.status not in ('pending_approval','blocked','replied') then raise exception 'Dòng không chờ duyệt'; end if;
  if not p_ok and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do từ chối'; end if;
  update public.acc_lines set status = case when p_ok then 'approved' else 'blocked' end, approved_by = auth.uid(), approved_at = now(), approve_note = nullif(btrim(p_note), ''),
    phan_hoi = case when p_ok then coalesce(case when l.reply_price > 0 then 'XUẤT GIÁ ' || to_char(l.reply_price, 'FM999G999G999') end, 'CHỐT (duyệt ngoại lệ)') else phan_hoi end,
    due_at = case when p_ok then null else now() + interval '24 hours' end, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, case when p_ok then 'approve' else 'reject' end, p_note);
  perform app.notify(l.sale_id, 'acc', case when p_ok then 'Đã duyệt mở chặn: ' else 'Từ chối mở chặn: ' end || coalesce(l.md, ''), p_note, '#/acc/mine');
end $$;
grant execute on function public.acc_line_approve(uuid, boolean, text) to authenticated;

-- ---------- Kế toán chốt / trả lại dòng ----------
create or replace function public.acc_line_set(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if p_status not in ('ok','blocked') then raise exception 'Trạng thái không hợp lệ'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  update public.acc_lines set status = p_status, due_at = case when p_status = 'blocked' then now() + interval '24 hours' end,
    phan_hoi = case when p_status = 'ok' then coalesce(case when l.reply = 'de_xuat_gia' and l.reply_price > 0 then 'XUẤT GIÁ ' || to_char(l.reply_price, 'FM999G999G999') end,
                    case when l.phan_hoi like 'CHỜ SALE%' then 'CHỐT' else l.phan_hoi end) else 'CHỜ SALE — chưa xuất' end,
    updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'set_' || p_status, p_note);
  if p_status = 'blocked' then perform app.notify(l.sale_id, 'acc', 'Kế toán trả lại dòng HĐ: ' || coalesce(l.md, ''), p_note, '#/acc/mine'); end if;
end $$;
grant execute on function public.acc_line_set(uuid, text, text) to authenticated;

-- ---------- HĐ đầu vào (XML): lưu + ghi kết quả vào dòng đối soát ----------
create or replace function public.acc_invoice_save(p_inv jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_id uuid; r jsonb;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  insert into public.acc_invoices as i(ky_hieu, so_hd, ngay, mst_ban, ten_ban, mst_mua, ten_mua, tong_truoc_thue, tien_thue, tong, file_name, stats)
  values (p_inv->>'ky_hieu', p_inv->>'so_hd', nullif(p_inv->>'ngay','')::date, p_inv->>'mst_ban', p_inv->>'ten_ban', p_inv->>'mst_mua', p_inv->>'ten_mua',
          (p_inv->>'tong_truoc_thue')::numeric, (p_inv->>'tien_thue')::numeric, (p_inv->>'tong')::numeric, p_inv->>'file_name', coalesce(p_inv->'stats','{}'))
  on conflict (mst_ban, ky_hieu, so_hd) do update set ngay = excluded.ngay, tong_truoc_thue = excluded.tong_truoc_thue, tien_thue = excluded.tien_thue, tong = excluded.tong,
    file_name = excluded.file_name, stats = excluded.stats
  returning id into v_id;
  update public.acc_lines set inv_id = null, inv_no = null, inv_stt = null, inv_price = null, inv_qty = null, inv_amount = null, inv_result = null where inv_id = v_id;
  delete from public.acc_invoice_lines where invoice_id = v_id;
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into public.acc_invoice_lines(invoice_id, stt, hh, ten, dvt, sl, dg, tt, vat, line_id, result)
    values (v_id, (r->>'stt')::int, r->>'hh', r->>'ten', r->>'dvt', (r->>'sl')::numeric, (r->>'dg')::numeric, (r->>'tt')::numeric, r->>'vat', nullif(r->>'line_id','')::uuid, r->>'result');
    if nullif(r->>'line_id','') is not null then
      update public.acc_lines set inv_id = v_id, inv_no = p_inv->>'so_hd', inv_stt = (r->>'stt')::int, inv_price = (r->>'dg')::numeric, inv_qty = (r->>'sl')::numeric,
        inv_amount = (r->>'tt')::numeric, inv_result = r->>'result', updated_at = now() where id = (r->>'line_id')::uuid;
    end if;
  end loop;
  if exists(select 1 from public.acc_invoice_lines where invoice_id = v_id and result in ('khong_don','gia_khach_0','lech')) then
    perform app.telegram('acc_invoice', '🧾 HĐ APT <b>' || app.esc(p_inv->>'so_hd') || '</b>: ' ||
      (select count(*) from public.acc_invoice_lines where invoice_id = v_id and result in ('khong_don','gia_khach_0')) || ' dòng chưa có đơn/giá khách, ' ||
      (select count(*) from public.acc_invoice_lines where invoice_id = v_id and result = 'lech') || ' dòng lệch giá/SL.');
  end if;
  return v_id;
end $$;
grant execute on function public.acc_invoice_save(jsonb, jsonb) to authenticated;

-- Cho phép Kế toán ghép "tên trong file" qua hàm acc_set_sale_alias (chỉ đổi sale_aliases)
create or replace function app.guard_profile() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if auth.uid() is null then return new; end if; -- chạy từ hệ thống
  if new.roles is distinct from old.roles and not app.is_admin() then
    if not app.has_role('hcns') or new.roles && array['admin','bgd'] or old.roles && array['admin','bgd'] then
      raise exception 'Không có quyền đổi vai trò';
    end if;
  end if;
  if (new.manager_id, new.job_level, new.org_unit_id, new.status, new.email, new.employee_code, new.work_schedule, new.is_new_hire)
     is distinct from (old.manager_id, old.job_level, old.org_unit_id, old.status, old.email, old.employee_code, old.work_schedule, old.is_new_hire)
     and not app.has_role('admin','bgd','hcns') then
    raise exception 'Chỉ HCNS/Admin được sửa thông tin tổ chức';
  end if;
  if new.sale_aliases is distinct from old.sale_aliases and not app.has_role('admin','bgd','hcns')
     and coalesce(current_setting('nt.alias_ok', true), '') <> '1' then
    raise exception 'Chỉ HCNS/Admin/Kế toán được sửa tên trong file';
  end if;
  if new.manager_id = new.id then raise exception 'Không thể tự làm quản lý của mình'; end if;
  return new;
end $$;

-- ---------- Ghép tên sale trong file với nhân sự (kế toán tự làm) ----------
create or replace function public.acc_set_sale_alias(p_profile uuid, p_names text[])
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.is_acc() or app.has_role('hcns')) then raise exception 'Không có quyền'; end if;
  perform set_config('nt.alias_ok', '1', true);
  -- gỡ tên này khỏi người khác để không trùng
  update public.profiles set sale_aliases = array(select x from unnest(sale_aliases) x where app.norm_text(x) <> all(select app.norm_text(y) from unnest(p_names) y))
   where id <> p_profile and sale_aliases && p_names;
  update public.profiles set sale_aliases = array(select distinct x from unnest(sale_aliases || p_names) x where btrim(x) <> '') where id = p_profile;
  perform set_config('nt.alias_ok', '', true);
  -- Gắn lại các dòng đối soát mang tên này (không cần nạp lại file); bỏ lỗi "chưa ghép", hết lỗi thì tự chốt
  update public.acc_lines l set sale_id = p_profile, updated_at = now(),
    issues = array(select x from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%'),
    status = case when l.status = 'blocked' and not exists(select 1 from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%')
                  then case when l.luong in ('A','E') then 'ok' else 'info' end else l.status end,
    due_at = case when l.status = 'blocked' and not exists(select 1 from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%') then null else l.due_at end,
    phan_hoi = case when l.status = 'blocked' and l.apt_stt is not null and l.luong = 'A' and not exists(select 1 from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%')
                    then case when l.gia_note is not null and abs(l.gia_note - coalesce(l.gia_nhap, 0)) > 0.5 then 'XUẤT GIÁ ' || to_char(l.gia_note, 'FM999G999G999')
                              when l.gia_de_xuat is not null then 'XUẤT GIÁ ' || to_char(l.gia_de_xuat, 'FM999G999G999') else 'CHỐT' end
                    else l.phan_hoi end
   where (l.sale_id is null or l.sale_id <> p_profile)
     and app.norm_text(coalesce(l.sale_name, '')) = any(select app.norm_text(y) from unnest(p_names) y);
end $$;
grant execute on function public.acc_set_sale_alias(uuid, text[]) to authenticated;

create or replace function public.acc_sale_directory()
returns table(id uuid, full_name text, sale_aliases text[]) language sql stable security definer set search_path = public, app as $$
  select id, full_name, sale_aliases from public.profiles where status = 'active' and (app.is_acc() or app.has_role('hcns')) order by full_name
$$;
grant execute on function public.acc_sale_directory() to authenticated;

-- ---------- Nhắc hạn: dòng chặn quá hạn ----------
create or replace function app.job_acc_remind() returns void language plpgsql security definer set search_path = public, app as $$
declare s record; n int;
begin
  for s in select sale_id, count(*) c from public.acc_lines where status = 'blocked' and due_at < now() and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Quá hạn: ' || s.c || ' dòng HĐ APT chưa xử lý', 'Mở Kế toán – Hóa đơn → Việc của tôi', '#/acc/mine');
  end loop;
  select count(*) into n from public.acc_lines where status = 'blocked' and due_at < now();
  if n > 0 then perform app.telegram('acc_overdue', '⏰ ' || n || ' dòng HĐ APT quá hạn sale chưa xử lý.'); end if;
end $$;
do $$ begin perform cron.unschedule('nt_acc_remind'); exception when others then null; end $$;
select cron.schedule('nt_acc_remind', '30 1,7 * * 1-6', 'select app.job_acc_remind()');

-- ---------- Sao lưu hằng ngày lên Google Drive (Apps Script gọi bằng mã bí mật) ----------
create or replace function public.backup_set_token(p_token text) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  if length(coalesce(p_token, '')) < 32 then raise exception 'Mã quá ngắn'; end if;
  insert into app.secrets(key, value, updated_by) values ('backup_token_hash', encode(digest(p_token, 'sha256'), 'hex'), auth.uid())
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;
grant execute on function public.backup_set_token(text) to authenticated;

create or replace function public.backup_export(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_hash text; t record; out jsonb := '{}'; v jsonb;
begin
  select value into v_hash from app.secrets where key = 'backup_token_hash';
  if v_hash is null or encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') <> v_hash then
    perform pg_sleep(1); raise exception 'Sai mã sao lưu';
  end if;
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' order by 1 loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x', t.relname) into v;
    out := out || jsonb_build_object(t.relname, v);
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('BACKUP_DRIVE', 'all', jsonb_build_object('tables', (select count(*) from jsonb_object_keys(out))));
  update public.settings set value = value || jsonb_build_object('last_backup_at', now()) where key = 'drive';
  return jsonb_build_object('generated_at', now(), 'version', 1, 'tables', out);
end $$;
revoke all on function public.backup_export(text) from public;
grant execute on function public.backup_export(text) to anon, authenticated;

-- Khôi phục 1 bảng từ file sao lưu Drive (Admin; ghi đè theo khóa chính, dòng mới tạo sau giữ nguyên)
create or replace function public.backup_restore_json(p_table text, p_rows jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare cols text; pk text; upd text; n bigint;
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  if to_regclass(format('public.%I', p_table)) is null then raise exception 'Không có bảng %', p_table; end if;
  select string_agg(format('%I', a.attname), ', ' order by a.attnum) into cols
    from pg_attribute a where a.attrelid = format('public.%I', p_table)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = '';
  select string_agg(format('%I', a.attname), ', ') into pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = format('public.%I', p_table)::regclass and i.indisprimary;
  if pk is null then raise exception 'Bảng % không có khóa chính', p_table; end if;
  select string_agg(format('%1$I = excluded.%1$I', x), ', ') into upd
    from unnest(string_to_array(replace(cols, '"', ''), ', ')) x where x <> all(string_to_array(replace(pk, '"', ''), ', '));
  execute format('alter table public.%I disable trigger user', p_table);
  execute format('insert into public.%I (%s) overriding system value select %s from jsonb_populate_recordset(null::public.%I, $1) on conflict (%s) do %s',
                 p_table, cols, cols, p_table, pk, case when upd is null then 'nothing' else 'update set ' || upd end) using p_rows;
  get diagnostics n = row_count;
  execute format('alter table public.%I enable trigger user', p_table);
  insert into public.audit_logs(action, table_name, diff) values ('RESTORE_DRIVE', p_table, jsonb_build_object('rows', n));
  return n;
end $$;
revoke all on function public.backup_restore_json(text, jsonb) from public, anon;
grant execute on function public.backup_restore_json(text, jsonb) to authenticated;

create or replace function public.set_drive(p_value jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  insert into public.settings(key, value, updated_by) values ('drive', p_value, auth.uid())
    on conflict (key) do update set value = public.settings.value || excluded.value, updated_at = now(), updated_by = auth.uid();
end $$;
grant execute on function public.set_drive(jsonb) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0017_v10b.sql
-- =====================================================================
-- 0017 · Bản 10b: sao lưu Drive lấy theo từng bảng, từng trang (tránh quá thời gian chờ của Supabase gói miễn phí)
-- =====================================================================
set search_path = public, app, extensions;

create or replace function app.backup_check(p_token text) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_hash text;
begin
  select value into v_hash from app.secrets where key = 'backup_token_hash';
  if v_hash is null or encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') <> v_hash then
    perform pg_sleep(1); raise exception 'Sai mã sao lưu';
  end if;
end $$;

-- Danh sách bảng cần sao lưu
create or replace function public.backup_tables(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
begin
  perform app.backup_check(p_token);
  update public.settings set value = value || jsonb_build_object('last_backup_at', now()) where key = 'drive';
  insert into public.audit_logs(action, table_name) values ('BACKUP_DRIVE', 'all');
  return (select jsonb_agg(c.relname order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r');
end $$;

-- 1 trang dữ liệu của 1 bảng (sắp theo khóa chính để không sót/trùng)
create or replace function public.backup_page(p_token text, p_table text, p_offset int default 0, p_limit int default 1000) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
declare pk text; v jsonb;
begin
  perform app.backup_check(p_token);
  if to_regclass(format('public.%I', p_table)) is null then raise exception 'Không có bảng %', p_table; end if;
  select string_agg(format('%I', a.attname), ', ') into pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = format('public.%I', p_table)::regclass and i.indisprimary;
  execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from (select * from public.%I order by %s offset %s limit %s) x',
                 p_table, coalesce(pk, 'ctid'), greatest(p_offset, 0), least(greatest(p_limit, 1), 5000)) into v;
  return v;
end $$;
revoke all on function public.backup_tables(text) from public;
revoke all on function public.backup_page(text, text, int, int) from public;
grant execute on function public.backup_tables(text) to anon, authenticated;
grant execute on function public.backup_page(text, text, int, int) to anon, authenticated;
drop function if exists public.backup_export(text);

reset search_path;


-- >>>>> supabase/migrations/0018_v11.sql
-- =====================================================================
-- 0018 · Bản 11: xuất thẳng theo từng xe, nạp thử không báo sale, xóa xe, chống trùng, lưu file gốc lên Drive, theo dõi HĐ chưa về / xuất muộn
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 11');

alter table public.acc_trucks add column if not exists is_test boolean not null default false;
alter table public.acc_trucks add column if not exists md_xuat_thang text[] not null default '{}';
alter table public.acc_trucks add column if not exists xt_keys text[] not null default '{}';
alter table public.acc_trucks add column if not exists file_links jsonb not null default '{}';
alter table public.acc_lines add column if not exists is_test boolean not null default false;
create index if not exists acc_lines_open on public.acc_lines(truck_id) where inv_no is null;
update public.settings set value = (value - 'md_xuat_thang') || jsonb_build_object('han_hd_ngay', coalesce((value->>'han_hd_ngay')::int, 15)) where key = 'accounting';

-- Xe nạp thử: sale, người duyệt không thấy
drop policy if exists acc_lines_read on public.acc_lines;
create policy acc_lines_read on public.acc_lines for select to authenticated
  using (app.is_acc() or (not is_test and (app.in_tree(sale_id) or (app.is_acc_approver() and status = 'pending_approval'))));

create or replace function public.acc_truck_save(p_truck uuid, p_info jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := p_truck; r jsonb; v_sale uuid; v_old public.acc_lines; v_status text; v_due timestamptz;
        h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); n_block int; s record; v_keys text[] := '{}'; v_test boolean;
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
    -- Đã được duyệt mở chặn thì giữ; sale đã trả lời mà vẫn chặn → giữ trạng thái đã trả lời
    if v_old.id is not null and v_status = 'blocked' and v_old.status in ('approved','replied','pending_approval') then v_status := v_old.status; end if;
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
      due_at = excluded.due_at, updated_at = now(), is_test = excluded.is_test;
  end loop;
  -- Dòng cũ không còn trong lần nạp mới → xóa (đã có nhật ký)
  delete from public.acc_lines where truck_id = v_id and line_key <> all(v_keys);
  insert into public.acc_events(truck_id, action, note, data) values (v_id, case when p_truck is null then 'import' else 'reimport' end, p_info->>'name', p_info->'stats');
  -- Báo sale có dòng bị chặn (xe nạp thử: không báo ai)
  if v_test then return v_id; end if;
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', coalesce(p_info->>'name','') || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
  select count(*) into n_block from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is null;
  if n_block > 0 then perform app.notify_roles(array['ke_toan'], 'acc', n_block || ' dòng bị chặn chưa ghép được sale', p_info->>'name', '#/acc?truck=' || v_id); end if;
  return v_id;
end $$;

-- Xóa xe (nạp nhầm/nạp thử). Xe đã ghép HĐ chỉ Admin/BGĐ xóa được.
create or replace function public.acc_truck_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare t public.acc_trucks; n_inv int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  select * into t from public.acc_trucks where id = p_id; if t.id is null then raise exception 'Không tìm thấy xe'; end if;
  select count(*) into n_inv from public.acc_lines where truck_id = p_id and inv_id is not null;
  if n_inv > 0 and not app.is_admin() then raise exception 'Xe đã ghép % dòng HĐ — chỉ Admin/BGĐ được xóa', n_inv; end if;
  insert into public.audit_logs(action, table_name, record_id, diff)
    values ('DELETE', 'acc_trucks', p_id::text, jsonb_build_object('name', t.name, 'truck_date', t.truck_date, 'is_test', t.is_test, 'stats', t.stats, 'files', t.files,
            'lines', (select count(*) from public.acc_lines where truck_id = p_id), 'replied', (select count(*) from public.acc_lines where truck_id = p_id and reply is not null)));
  delete from public.acc_trucks where id = p_id;
end $$;
grant execute on function public.acc_truck_delete(uuid) to authenticated;

-- Chuyển xe nạp thử thành chính thức: báo sale, tính hạn từ lúc này
create or replace function public.acc_truck_publish(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); s record; t public.acc_trucks;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  update public.acc_trucks set is_test = false, updated_at = now() where id = p_id and is_test returning * into t;
  if t.id is null then raise exception 'Xe không ở chế độ nạp thử'; end if;
  update public.acc_lines set is_test = false, due_at = case when status = 'blocked' then now() + make_interval(hours => h) end where truck_id = p_id;
  insert into public.acc_events(truck_id, action, note) values (p_id, 'publish', t.name);
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = p_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', t.name || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
end $$;
grant execute on function public.acc_truck_publish(uuid) to authenticated;

-- Đánh dấu / bỏ đánh dấu APT xuất thẳng cho 1 dòng (lưu theo xe để nạp lại vẫn giữ)
create or replace function public.acc_line_xuat_thang(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  select * into l from public.acc_lines where id = p_id for update; if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if p_on then
    update public.acc_trucks set xt_keys = array(select distinct x from unnest(xt_keys || l.line_key) x) where id = l.truck_id;
    update public.acc_lines set luong = 'C', status = 'info', phan_hoi = case when apt_stt is not null then 'XUẤT THẲNG' end, due_at = null,
      notes = array_prepend('Kế toán đánh dấu APT xuất thẳng.', notes), updated_at = now() where id = p_id;
  else
    update public.acc_trucks set xt_keys = array_remove(xt_keys, l.line_key), md_xuat_thang = array_remove(md_xuat_thang, l.md) where id = l.truck_id;
    update public.acc_lines set luong = 'A', status = 'blocked', phan_hoi = 'CHỜ KẾ TOÁN — nạp lại file', due_at = null,
      issues = array['Kế toán bỏ đánh dấu xuất thẳng → bấm “Nạp lại file” để hệ thống chấm lại dòng này.'], updated_at = now() where id = p_id;
  end if;
  insert into public.acc_events(line_id, truck_id, action) values (p_id, l.truck_id, case when p_on then 'xuat_thang' else 'bo_xuat_thang' end);
end $$;
grant execute on function public.acc_line_xuat_thang(uuid, boolean) to authenticated;

-- Nhắc hạn: bỏ xe nạp thử
create or replace function app.job_acc_remind() returns void language plpgsql security definer set search_path = public, app as $$
declare s record; n int;
begin
  for s in select sale_id, count(*) c from public.acc_lines where status = 'blocked' and not is_test and due_at < now() and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Quá hạn: ' || s.c || ' dòng HĐ APT chưa xử lý', 'Mở Kế toán – Hóa đơn → Việc của tôi', '#/acc/mine');
  end loop;
  select count(*) into n from public.acc_lines where status = 'blocked' and not is_test and due_at < now();
  if n > 0 then perform app.telegram('acc_overdue', '⏰ ' || n || ' dòng HĐ APT quá hạn sale chưa xử lý.'); end if;
end $$;

reset search_path;


-- >>>>> supabase/migrations/0019_v12.sql
-- =====================================================================
-- 0019 · Bản 12: biên APT theo tờ khai nháp; HĐ APT nhiều đợt (gộp nhiều HĐ / xuất một phần);
--        HĐ về sau tự ghép vào xe nạp sau; tự ghép đủ tên sale (khoile…)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 12');

-- Giá vốn APT theo tờ khai nháp = đơn giá theo tỷ giá NH + thuế NK/đv; biên APT = giá APT ÷ giá vốn − 1
alter table public.acc_lines add column if not exists gia_von numeric generated always as (case when gia_tk_nh is not null then gia_tk_nh + coalesce(tnk_dv, 0) end) stored;
alter table public.acc_lines add column if not exists bien_apt numeric generated always as (
  case when gia_tk_nh is not null and gia_tk_nh + coalesce(tnk_dv, 0) > 0 and gia_ap_dung > 0 then round(gia_ap_dung / (gia_tk_nh + coalesce(tnk_dv, 0)) - 1, 6) end) stored;
create index if not exists acc_invl_line on public.acc_invoice_lines(line_id);
create index if not exists acc_invl_hh_free on public.acc_invoice_lines(hh) where line_id is null;

-- Kết luận 1 dòng HĐ so với dòng đối soát (chỉ giá; số lượng xét khi cộng các HĐ)
create or replace function app.acc_judge(p_dg numeric, l public.acc_lines) returns text language sql immutable as $$
  select case when l.id is null then 'khong_thuoc_xe' when l.md is null then 'khong_don' when coalesce(l.gia_khach, 0) = 0 then 'gia_khach_0'
              when coalesce(l.gia_note, l.gia_de_xuat, l.gia_nhap) is null then 'khop'
              when (l.gia_note is not null and abs(p_dg - l.gia_note) <= 0.5) or (l.gia_de_xuat is not null and abs(p_dg - l.gia_de_xuat) <= 0.5)
                or (l.gia_nhap is not null and abs(p_dg - l.gia_nhap) <= 0.5) then 'khop' else 'lech' end
$$;

-- Cộng mọi dòng HĐ (nhiều đợt, nhiều HĐ) của 1 dòng đối soát
create or replace function app.acc_line_inv_refresh(p_line uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; agg record; v_res text; v_sl numeric;
begin
  select * into l from public.acc_lines where id = p_line; if l.id is null then return; end if;
  select count(*) n, string_agg(distinct i.so_hd, ', ' order by i.so_hd) so, sum(il.sl) sl, sum(il.tt) tt,
         (array_agg(i.id order by i.ngay desc nulls last, i.created_at desc))[1] last_id, (array_agg(il.dg order by i.ngay desc nulls last))[1] dg,
         (array_agg(il.stt order by i.ngay desc nulls last))[1] stt,
         bool_or(il.result = 'khong_don') kd, bool_or(il.result = 'gia_khach_0') g0, bool_or(il.result = 'lech') lech
    into agg from public.acc_invoice_lines il join public.acc_invoices i on i.id = il.invoice_id where il.line_id = p_line;
  if agg.n = 0 then
    update public.acc_lines set inv_id = null, inv_no = null, inv_stt = null, inv_price = null, inv_qty = null, inv_amount = null, inv_result = null where id = p_line; return;
  end if;
  v_sl := coalesce(l.sl_tk, l.sl_apt);
  v_res := case when agg.kd then 'khong_don' when agg.g0 then 'gia_khach_0' when agg.lech then 'lech'
                when v_sl is not null and agg.sl > v_sl + 0.01 then 'lech' when v_sl is not null and agg.sl < v_sl - 0.01 then 'mot_phan' else 'khop' end;
  update public.acc_lines set inv_id = agg.last_id, inv_no = agg.so, inv_stt = agg.stt, inv_price = agg.dg, inv_qty = agg.sl, inv_amount = agg.tt, inv_result = v_res, updated_at = now() where id = p_line;
end $$;

create or replace function app.acc_inv_stats_refresh(p_inv uuid) returns void language sql security definer set search_path = public, app as $$
  update public.acc_invoices i set stats = coalesce((select jsonb_object_agg(result, c) from (select il.result, count(*) c from public.acc_invoice_lines il where il.invoice_id = p_inv group by il.result) x), '{}')
    || jsonb_build_object('tien_khong_don', (select coalesce(sum(tt), 0) from public.acc_invoice_lines where invoice_id = p_inv and result in ('khong_don','gia_khach_0')),
                          'mot_phan', (select count(*) from public.acc_invoice_lines il join public.acc_lines l on l.id = il.line_id where il.invoice_id = p_inv and l.inv_result = 'mot_phan'))
   where i.id = p_inv
$$;

-- Lưu HĐ: giữ kết luận từng dòng theo giá, cộng số lượng các đợt ở dòng đối soát
create or replace function public.acc_invoice_save(p_inv jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_id uuid; r jsonb; v_old uuid[]; x uuid;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  insert into public.acc_invoices as i(ky_hieu, so_hd, ngay, mst_ban, ten_ban, mst_mua, ten_mua, tong_truoc_thue, tien_thue, tong, file_name, stats)
  values (p_inv->>'ky_hieu', p_inv->>'so_hd', nullif(p_inv->>'ngay','')::date, p_inv->>'mst_ban', p_inv->>'ten_ban', p_inv->>'mst_mua', p_inv->>'ten_mua',
          (p_inv->>'tong_truoc_thue')::numeric, (p_inv->>'tien_thue')::numeric, (p_inv->>'tong')::numeric, p_inv->>'file_name', '{}')
  on conflict (mst_ban, ky_hieu, so_hd) do update set ngay = excluded.ngay, tong_truoc_thue = excluded.tong_truoc_thue, tien_thue = excluded.tien_thue, tong = excluded.tong, file_name = excluded.file_name
  returning id into v_id;
  select array_agg(distinct line_id) into v_old from public.acc_invoice_lines where invoice_id = v_id and line_id is not null;
  delete from public.acc_invoice_lines where invoice_id = v_id;
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into public.acc_invoice_lines(invoice_id, stt, hh, ten, dvt, sl, dg, tt, vat, line_id, result)
    values (v_id, (r->>'stt')::int, r->>'hh', r->>'ten', r->>'dvt', (r->>'sl')::numeric, (r->>'dg')::numeric, (r->>'tt')::numeric, r->>'vat', nullif(r->>'line_id','')::uuid, r->>'result');
  end loop;
  for x in select distinct line_id from public.acc_invoice_lines where invoice_id = v_id and line_id is not null union select unnest(coalesce(v_old, '{}')) loop
    perform app.acc_line_inv_refresh(x);
  end loop;
  perform app.acc_inv_stats_refresh(v_id);
  if exists(select 1 from public.acc_invoice_lines where invoice_id = v_id and result in ('khong_don','gia_khach_0','lech')) then
    perform app.telegram('acc_invoice', '🧾 HĐ APT <b>' || app.esc(p_inv->>'so_hd') || '</b>: ' ||
      (select count(*) from public.acc_invoice_lines where invoice_id = v_id and result in ('khong_don','gia_khach_0')) || ' dòng chưa có đơn/giá khách, ' ||
      (select count(*) from public.acc_invoice_lines where invoice_id = v_id and result = 'lech') || ' dòng lệch giá.');
  end if;
  return v_id;
end $$;

-- HĐ về trước, xe nạp sau: ghép các dòng HĐ "không thuộc xe" vào xe vừa nạp theo mã HH
create or replace function public.acc_relink_truck(p_truck uuid) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; x uuid; v_inv uuid[];
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if (select is_test from public.acc_trucks where id = p_truck) then return 0; end if;
  with m as (
    update public.acc_invoice_lines il set line_id = l.id, result = app.acc_judge(il.dg, l)
      from public.acc_lines l where l.truck_id = p_truck and il.line_id is null and coalesce(il.hh, '') <> '' and il.hh = l.hh
    returning il.line_id, il.invoice_id)
  select count(*), array_agg(distinct invoice_id) into n, v_inv from m;
  for x in select distinct line_id from public.acc_invoice_lines where invoice_id = any(coalesce(v_inv, '{}')) and line_id is not null loop perform app.acc_line_inv_refresh(x); end loop;
  for x in select unnest(coalesce(v_inv, '{}')) loop perform app.acc_inv_stats_refresh(x); end loop;
  if n > 0 then insert into public.acc_events(truck_id, action, note) values (p_truck, 'relink_invoice', n || ' dòng HĐ đã về trước được ghép vào xe này'); end if;
  return n;
end $$;
grant execute on function public.acc_relink_truck(uuid) to authenticated;

-- Chuyển xe nạp thử thành chính thức: ghép luôn HĐ đã về trước
create or replace function public.acc_truck_publish(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); s record; t public.acc_trucks;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  update public.acc_trucks set is_test = false, updated_at = now() where id = p_id and is_test returning * into t;
  if t.id is null then raise exception 'Xe không ở chế độ nạp thử'; end if;
  update public.acc_lines set is_test = false, due_at = case when status = 'blocked' then now() + make_interval(hours => h) end where truck_id = p_id;
  insert into public.acc_events(truck_id, action, note) values (p_id, 'publish', t.name);
  perform public.acc_relink_truck(p_id);
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = p_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', t.name || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
end $$;

-- Tính lại kết quả HĐ các dòng đã ghép (theo cách cộng nhiều đợt)
do $$ declare x uuid; begin
  for x in select distinct line_id from public.acc_invoice_lines where line_id is not null loop perform app.acc_line_inv_refresh(x); end loop;
  for x in select id from public.acc_invoices loop perform app.acc_inv_stats_refresh(x); end loop;
end $$;

-- Ghép đủ tên trong file cho sale đã khớp 1 tên (VD đã khớp "Lê Thị Minh Khơi" nhưng thiếu tài khoản "khoile")
do $$ declare g jsonb; v_names text[]; v_pid uuid; n int;
begin
  perform set_config('nt.alias_ok', '1', true);
  for g in select * from jsonb_array_elements(coalesce(app.setting('accounting')->'sale_names', '[]')) loop
    v_names := array(select jsonb_array_elements_text(g->'names')) || (g->>'acc');
    select count(distinct p.id), min(p.id::text)::uuid into n, v_pid from public.profiles p
     where p.status = 'active' and exists(select 1 from unnest(v_names) y where app.norm_text(y) = any(select app.norm_text(z) from unnest(p.sale_aliases || p.full_name) z));
    if n = 1 then
      update public.profiles set sale_aliases = array(select distinct x from unnest(sale_aliases || v_names) x where btrim(x) <> '') where id = v_pid;
      update public.acc_lines l set sale_id = v_pid,
        issues = array(select x from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%'),
        status = case when l.status = 'blocked' and not exists(select 1 from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%') then case when l.luong in ('A','E') then 'ok' else 'info' end else l.status end
       where l.sale_id is null and app.norm_text(coalesce(l.sale_name, '')) = any(select app.norm_text(y) from unnest(v_names) y);
    end if;
  end loop;
  perform set_config('nt.alias_ok', '', true);
end $$;

reset search_path;


-- >>>>> supabase/migrations/0020_v13.sql
-- =====================================================================
-- 0020 · Bản 13: sale xem toàn bộ dòng của mình; dòng chưa có chủ cho mọi sale nhận; kế toán chốt kèm giá khách/MD;
--        sale báo "Đơn APT xuất thẳng"; gán/ghép dòng HĐ chưa thuộc xe; mã KH hệ thống → khách ERP
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 13');

create or replace function app.norm_md(p text) returns text language sql immutable as $$
  select case when substring(coalesce(p, '') from '(\d+)') is null then null else 'MD' || (substring(p from '(\d+)'))::bigint end
$$;

alter table public.acc_lines add column if not exists claim_md text;
alter table public.acc_lines add column if not exists claim_gia numeric;
alter table public.acc_lines add column if not exists claimed_by uuid references public.profiles(id);
alter table public.acc_lines add column if not exists claimed_at timestamptz;
alter table public.acc_lines add column if not exists customer_id uuid references public.customers(id) on delete set null;
alter table public.acc_lines drop constraint if exists acc_lines_reply_check;
alter table public.acc_lines add constraint acc_lines_reply_check check (reply in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet','xuat_thang'));
create index if not exists acc_lines_unowned on public.acc_lines(truck_id) where sale_id is null;

-- Mã khách trên file khai báo (NT93844 hoặc username) → khách hàng ERP
create or replace function app.acc_line_customer() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(btrim(new.ma_kh), '') = '' then new.customer_id := null;
  elsif tg_op = 'INSERT' or new.ma_kh is distinct from old.ma_kh or new.customer_id is null then
    select id into new.customer_id from public.customers
     where deleted_at is null and (upper(sys_code) = upper(btrim(new.ma_kh)) or lower(sys_username) = lower(btrim(new.ma_kh)) or upper(code) = upper(btrim(new.ma_kh))) limit 1;
  end if;
  return new;
end $$;
drop trigger if exists acc_line_customer on public.acc_lines;
create trigger acc_line_customer before insert or update of ma_kh on public.acc_lines for each row execute function app.acc_line_customer();

-- Sale: thấy mọi dòng của mình; mọi sale thấy dòng chưa có sale phụ trách để nhận
drop policy if exists acc_lines_read on public.acc_lines;
create policy acc_lines_read on public.acc_lines for select to authenticated
  using (app.is_acc() or (not is_test and (app.in_tree(sale_id) or (app.is_acc_approver() and status = 'pending_approval')
         or (sale_id is null and luong in ('A','B') and app.has_role('sale','tn_kd','tp_kd')))));

drop policy if exists acc_trucks_read on public.acc_trucks;
create policy acc_trucks_read on public.acc_trucks for select to authenticated using (app.is_acc() or app.is_acc_approver()
  or exists(select 1 from public.acc_lines l where l.truck_id = acc_trucks.id and not l.is_test and (app.in_tree(l.sale_id) or (l.sale_id is null and l.luong in ('A','B') and app.has_role('sale','tn_kd','tp_kd')))));

-- Sale trả lời (thêm MD + giá khách khi đã sửa hệ thống; "Đơn APT xuất thẳng" đổi luồng ngay)
drop function if exists public.acc_line_reply(uuid, text, numeric, text);
create or replace function public.acc_line_reply(p_id uuid, p_reply text, p_price numeric default null, p_note text default null, p_md text default null, p_gia_khach numeric default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; v_status text; v_md text := nullif(app.norm_md(p_md), '');
begin
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if not (app.is_acc() or app.in_tree(l.sale_id)) then raise exception 'Dòng này không thuộc khách của bạn'; end if;
  if l.status not in ('blocked','replied') then raise exception 'Dòng không ở trạng thái chờ sale'; end if;
  if p_reply not in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet','xuat_thang') then raise exception 'Lựa chọn không hợp lệ'; end if;
  if p_reply = 'de_xuat_gia' and coalesce(p_price, 0) <= 0 then raise exception 'Nhập giá đề xuất'; end if;
  if p_reply = 'xin_duyet' and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do xin duyệt ngoại lệ'; end if;
  if p_reply = 'da_sua_ht' and l.md is null and l.luong in ('A','B') and v_md is null then raise exception 'Nhập mã đơn (MD) đã tạo trên hệ thống'; end if;
  if p_reply = 'da_sua_ht' and coalesce(l.gia_khach, 0) = 0 and l.luong in ('A','B') and coalesce(p_gia_khach, 0) <= 0 then raise exception 'Nhập giá khách (giá xuất HĐ cho khách)'; end if;
  if p_reply = 'xuat_thang' then
    update public.acc_trucks set xt_keys = array(select distinct x from unnest(xt_keys || l.line_key) x),
      md_xuat_thang = case when l.md is null then md_xuat_thang else array(select distinct x from unnest(md_xuat_thang || l.md) x) end where id = l.truck_id;
    update public.acc_lines set reply = p_reply, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(), luong = 'C', status = 'info', due_at = null,
      phan_hoi = case when apt_stt is not null then 'XUẤT THẲNG' end, issues = '{}', notes = array_prepend('Sale báo APT xuất thẳng.', notes), updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'reply_xuat_thang', p_note);
    return;
  end if;
  v_status := case when p_reply = 'xin_duyet' then 'pending_approval' else 'replied' end;
  update public.acc_lines set reply = p_reply, reply_price = p_price, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(), status = v_status,
    claim_md = coalesce(v_md, claim_md), claim_gia = coalesce(nullif(p_gia_khach, 0), claim_gia), updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'reply', p_note, jsonb_build_object('reply', p_reply, 'price', p_price, 'md', v_md, 'gia_khach', p_gia_khach));
  if p_reply = 'xin_duyet' then
    perform app.notify(x::uuid, 'acc', 'Xin duyệt ngoại lệ HĐ: ' || coalesce(l.md, 'dòng không có đơn'), left(coalesce(l.ten_apt, l.ten_ht, ''), 80) || ' — ' || p_note, '#/acc/approve')
      from jsonb_array_elements_text(coalesce(app.setting('accounting')->'approver_ids', '[]')) x;
  end if;
end $$;
grant execute on function public.acc_line_reply(uuid, text, numeric, text, text, numeric) to authenticated;


-- Nhận dòng chưa có chủ (sale) / gán cho sale (kế toán, admin)
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
  if coalesce(p_gia_khach, 0) <= 0 and coalesce(l.gia_khach, 0) = 0 then raise exception 'Nhập giá khách'; end if;
  update public.acc_lines set sale_id = v_sale, claimed_by = auth.uid(), claimed_at = now(), claim_md = coalesce(v_md, claim_md), claim_gia = coalesce(nullif(p_gia_khach, 0), claim_gia),
    reply = 'da_sua_ht', reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(),
    status = case when status in ('blocked','replied') then 'replied' else status end, due_at = null, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, case when p_sale is null then 'claim' else 'assign' end, p_note,
    jsonb_build_object('md', v_md, 'gia_khach', p_gia_khach, 'sale', v_sale));
  if p_sale is not null and p_sale <> auth.uid() then perform app.notify(p_sale, 'acc', 'Kế toán gán cho bạn 1 dòng HĐ APT', coalesce(v_md, '') || ' · ' || left(coalesce(l.ten_apt, ''), 80), '#/acc/mine'); end if;
end $$;
grant execute on function public.acc_line_claim(uuid, text, numeric, text, uuid) to authenticated;

-- Kế toán chốt / trả lại: chốt phải có giá khách (điền chuẩn theo hệ thống), có thể bổ sung MD
drop function if exists public.acc_line_set(uuid, text, text);
create or replace function public.acc_line_set(p_id uuid, p_status text, p_note text default null, p_gia_khach numeric default null, p_md text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; c jsonb := coalesce(app.setting('accounting'), '{}'); v_gk numeric; v_md text; v_ga numeric; v_b numeric; v_de numeric; v_ph text;
        tgt numeric := coalesce((c->>'bien_muc_tieu')::numeric, 0.03); hi numeric := coalesce((c->>'bien_nt_max')::numeric, 0.04);
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if p_status not in ('ok','blocked') then raise exception 'Trạng thái không hợp lệ'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  if p_status = 'blocked' then
    update public.acc_lines set status = 'blocked', due_at = now() + interval '24 hours', phan_hoi = 'CHỜ SALE — chưa xuất', updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'set_blocked', p_note);
    perform app.notify(l.sale_id, 'acc', 'Kế toán trả lại dòng HĐ: ' || coalesce(l.md, ''), p_note, '#/acc/mine');
    return;
  end if;
  v_gk := coalesce(nullif(p_gia_khach, 0), nullif(l.gia_khach, 0), l.claim_gia);
  v_md := coalesce(app.norm_md(p_md), l.md, l.claim_md);
  if l.luong in ('A','B') and coalesce(v_gk, 0) <= 0 then raise exception 'Nhập giá khách để chốt'; end if;
  v_ga := coalesce(l.gia_note, l.gia_nhap); v_b := case when v_gk > 0 and v_ga > 0 then v_gk / v_ga - 1 end;
  if l.reply = 'de_xuat_gia' and l.reply_price > 0 then v_de := l.reply_price;
  elsif v_b is not null and v_b > hi + 0.001 then v_de := round(v_gk / (1 + tgt)); end if;
  v_ph := case when l.apt_stt is null then null when l.luong = 'C' then 'XUẤT THẲNG'
               when v_de is not null then 'XUẤT GIÁ ' || round(v_de)::bigint::text
               when l.gia_note is not null and abs(l.gia_note - coalesce(l.gia_nhap, 0)) > 0.5 then 'XUẤT GIÁ ' || round(l.gia_note)::bigint::text else 'CHỐT' end;
  update public.acc_lines set status = 'ok', due_at = null, gia_khach = v_gk, md = v_md, ma_dong = coalesce(ma_dong, v_md),
    gia_de_xuat = coalesce(v_de, gia_de_xuat), gia_ap_dung = coalesce(v_de, gia_note, gia_nhap),
    bien_nt = case when v_gk > 0 and coalesce(v_de, v_ga) > 0 then v_gk / coalesce(v_de, v_ga) - 1 end,
    tt_khach = case when v_gk > 0 then round(v_gk * coalesce(sl_tk, sl_apt, sl_ht, 0)) end, tt_apt = round(coalesce(v_de, v_ga, 0) * coalesce(sl_tk, sl_apt, sl_ht, 0)),
    phan_hoi = v_ph, issues = '{}', notes = array_prepend('Kế toán chốt' || coalesce(': ' || nullif(btrim(p_note), ''), '') || '.', notes), updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'set_ok', p_note, jsonb_build_object('gia_khach', v_gk, 'md', v_md));
  if l.inv_id is not null then perform app.acc_line_inv_refresh(p_id); end if;
end $$;
grant execute on function public.acc_line_set(uuid, text, text, numeric, text) to authenticated;

-- Ghép tay 1 dòng HĐ (chưa thuộc xe nào / ghép nhầm) vào dòng đối soát; p_line null = gỡ ghép
create or replace function public.acc_invoice_line_link(p_invline uuid, p_line uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare il public.acc_invoice_lines; l public.acc_lines; v_old uuid;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  select * into il from public.acc_invoice_lines where id = p_invline for update; if il.id is null then raise exception 'Không tìm thấy dòng HĐ'; end if;
  v_old := il.line_id;
  if p_line is not null then select * into l from public.acc_lines where id = p_line; if l.id is null then raise exception 'Không tìm thấy dòng đối soát'; end if; end if;
  update public.acc_invoice_lines set line_id = p_line, result = case when p_line is null then 'khong_thuoc_xe' else app.acc_judge(il.dg, l) end where id = p_invline;
  if v_old is not null then perform app.acc_line_inv_refresh(v_old); end if;
  if p_line is not null then perform app.acc_line_inv_refresh(p_line); insert into public.acc_events(line_id, truck_id, action, note) values (p_line, l.truck_id, 'link_invoice', il.hh); end if;
  perform app.acc_inv_stats_refresh(il.invoice_id);
end $$;
grant execute on function public.acc_invoice_line_link(uuid, uuid) to authenticated;

create or replace function public.acc_line_approve(p_id uuid, p_ok boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines;
begin
  if not app.is_acc_approver() then raise exception 'Bạn không có quyền duyệt mở chặn'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if l.status not in ('pending_approval','blocked','replied') then raise exception 'Dòng không chờ duyệt'; end if;
  if not p_ok and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do từ chối'; end if;
  update public.acc_lines set status = case when p_ok then 'approved' else 'blocked' end, approved_by = auth.uid(), approved_at = now(), approve_note = nullif(btrim(p_note), ''),
    phan_hoi = case when p_ok then coalesce(case when l.reply_price > 0 then 'XUẤT GIÁ ' || round(l.reply_price)::bigint::text end, 'CHỐT (duyệt ngoại lệ)') else phan_hoi end,
    due_at = case when p_ok then null else now() + interval '24 hours' end, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, case when p_ok then 'approve' else 'reject' end, p_note);
  perform app.notify(l.sale_id, 'acc', case when p_ok then 'Đã duyệt mở chặn: ' else 'Từ chối mở chặn: ' end || coalesce(l.md, ''), p_note, '#/acc/mine');
end $$;


-- Đưa "XUẤT GIÁ" về dạng số liền (APT dán thẳng)
update public.acc_lines set phan_hoi = 'XUẤT GIÁ ' || replace(replace(substring(phan_hoi from 10), '.', ''), ',', '') where phan_hoi like 'XUẤT GIÁ %';
-- Gắn khách cho dòng đã có mã KH
update public.acc_lines set ma_kh = ma_kh where coalesce(ma_kh, '') <> '';

reset search_path;


-- >>>>> supabase/migrations/0021_v14.sql
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


-- >>>>> supabase/migrations/0022_v15.sql
-- =====================================================================
-- 0022 · Bản 15: danh sách đơn vị nhận HĐ (sheet "Thong tin KH") + tra MST khi lập phiếu; file nháp đúng mẫu MISA
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 15');

create index if not exists out_buyers_mst on public.out_buyers(btrim(tax_code)) where tax_code is not null;

-- Kế toán nạp danh sách đơn vị nhận HĐ (MST, tên, địa chỉ, email) — cập nhật theo MST
create or replace function public.out_buyers_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n int := 0; v_id uuid; v_mst text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), ''); if v_mst is null or coalesce(btrim(r->>'name'), '') = '' then continue; end if;
    select id into v_id from public.out_buyers where customer_id is null and btrim(tax_code) = v_mst limit 1;
    if v_id is null then
      insert into public.out_buyers(name, tax_code, address, email, note) values (btrim(r->>'name'), v_mst, nullif(btrim(r->>'address'), ''), nullif(btrim(r->>'email'), ''), 'Danh sách kế toán');
    else
      update public.out_buyers set name = btrim(r->>'name'), address = coalesce(nullif(btrim(r->>'address'), ''), address), email = coalesce(nullif(btrim(r->>'email'), ''), email) where id = v_id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_buyers_import(jsonb) to authenticated;

-- Sale tra 1 MST cụ thể (không xem được cả danh sách)
create or replace function public.out_buyer_lookup(p_mst text) returns table(name text, address text, email text)
language sql stable security definer set search_path = public as $$
  select b.name, b.address, b.email from public.out_buyers b
   where length(btrim(coalesce(p_mst, ''))) >= 10 and btrim(b.tax_code) = regexp_replace(p_mst, '\s', '', 'g')
   order by (b.customer_id is null), b.created_at desc limit 1
$$;
grant execute on function public.out_buyer_lookup(text) to authenticated;

-- File đơn hàng: dòng chưa có username thì lấy theo mã đơn, rồi gắn khách → sale (chủ khách)
create or replace function public.out_orders_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; r jsonb; t record; v_md text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_md := case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end; if v_md is null then continue; end if;
    for t in select id from public.out_items where md = v_md and (sale_id is null or username is null or customer_id is null) loop
      update public.out_items set nvkd = coalesce(nvkd, nullif(btrim(r->>'nvkd'), '')), username = coalesce(username, nullif(btrim(r->>'username'), '')),
        sale_id = coalesce(sale_id, app.match_sale(nullif(btrim(r->>'nvkd'), ''))) where id = t.id;
      perform app.out_item_match(t.id); n := n + 1;
    end loop;
  end loop;
  return n;
end $$;
reset search_path;


-- >>>>> supabase/migrations/0023_v16.sql
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


-- >>>>> supabase/migrations/0024_v17.sql
-- =====================================================================
-- 0024 · Bản 17: Xuất HĐ đầu ra
--  · 1 mã hàng chia nhiều dòng trên sổ (nhiều khách) → tách thành nhiều phần, không gộp
--  · Sổ cũ: chỉ dòng "Đã ký" mới hết tồn (vào phiếu Đã ký của sale); nháp vẫn còn tồn
--  · Giá xuất khách: lấy theo đối soát, không có thì theo sổ (cột Đơn giá xuất)
--  · Lưu file đơn hàng (mã đơn → khách, sale) để dùng mãi; MD đã biết sale/khách ở dòng khác thì dùng chung
--  · HĐ vào ↔ xe (tự theo XML, kế toán sửa được); xem nhanh hơn
--  · Sale nhận dòng: nhập MD (+ username, giá xuất khách nếu hệ thống chưa có)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 17');

-- ---------- Bảng / cột mới ----------
alter table public.out_items add column if not exists part int not null default 1;
alter table public.out_items add column if not exists gia_so numeric;
alter table public.out_items drop constraint if exists out_items_ma_hang_key;
create unique index if not exists out_items_ma_part on public.out_items(ma_hang, part);

create table if not exists public.out_orders(
  md text primary key, username text, nvkd text, updated_at timestamptz not null default now()
);
alter table public.out_orders enable row level security;
drop policy if exists out_orders_read on public.out_orders;
create policy out_orders_read on public.out_orders for select to authenticated using (true);
grant select on public.out_orders to authenticated;

create table if not exists public.out_hd_xe(
  so_hd text primary key, xe text not null, tu_dong boolean not null default false, updated_at timestamptz not null default now(), updated_by uuid default auth.uid()
);
alter table public.out_hd_xe enable row level security;
drop policy if exists out_hd_xe_read on public.out_hd_xe;
create policy out_hd_xe_read on public.out_hd_xe for select to authenticated using (true);
grant select on public.out_hd_xe to authenticated;

-- ---------- Gắn đơn / sale / khách / giá ----------
create or replace function app.out_item_match(p_id uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; al public.acc_lines; v_c uuid; v_owner uuid; v_src text; o public.out_orders; s_sale uuid; s_user text;
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
  if t.md is not null then select * into o from public.out_orders where md = t.md; end if;
  -- cùng mã đơn ở dòng khác của sổ đã biết sale / khách → dùng chung
  if t.md is not null and (t.sale_id is null or t.username is null) then
    select sale_id, username into s_sale, s_user from public.out_items where md = t.md and id <> t.id and (sale_id is not null or username is not null)
     order by (sale_id is not null) desc, (username is not null) desc limit 1;
  end if;
  t.username := coalesce(t.username, o.username, s_user);
  if t.username is not null then
    select id, owner_id into v_c, v_owner from public.customers where deleted_at is null
      and (lower(btrim(sys_username)) = lower(btrim(t.username)) or upper(btrim(sys_code)) = upper(btrim(t.username))) limit 1;
  end if;
  update public.out_items set acc_line_id = coalesce(acc_line_id, al.id),
    md = coalesce(md, al.md), username = t.username, nvkd = coalesce(nvkd, o.nvkd),
    gia_khach = coalesce(nullif(al.gia_khach, 0), al.claim_gia, gia_khach, gia_so),
    sale_id = coalesce(sale_id, al.sale_id, app.match_sale(t.nvkd), app.match_sale(o.nvkd), s_sale, v_owner),
    customer_id = coalesce(customer_id, al.customer_id, v_c),
    match_src = coalesce(match_src, v_src, case when t.nvkd is not null then 'nvkd' when o.md is not null then 'don_hang' when v_owner is not null then 'user' end)
  where id = p_id;
end $$;

-- ---------- Nạp sổ ----------
drop function if exists public.out_items_import(jsonb, jsonb);
create or replace function public.out_items_import(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_id uuid; n_new int := 0; n_upd int := 0; v_ids uuid[] := '{}';
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select id into v_id from public.out_items where ma_hang = r->>'ma_hang' and part = coalesce((r->>'part')::int, 1);
    if v_id is null then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
    insert into public.out_items as t(ma_hang, part, stt_so, ten, dvt, vat, sl_nhap, dg_nhap, so_hd_vao, ky_hieu, ngay_vao, ncc, stt_hd, md, nvkd, username, gia_so, legacy, updated_at, updated_by)
    values (r->>'ma_hang', coalesce((r->>'part')::int, 1), (r->>'stt_so')::numeric, r->>'ten', r->>'dvt', (r->>'vat')::numeric, coalesce((r->>'sl_nhap')::numeric, 0), (r->>'dg_nhap')::numeric,
            r->>'so_hd_vao', r->>'ky_hieu', nullif(r->>'ngay_vao','')::date, r->>'ncc', (r->>'stt_hd')::int,
            case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end, nullif(btrim(r->>'nvkd'), ''), nullif(btrim(r->>'username'), ''),
            nullif((r->>'gia_so')::numeric, 0), r->'legacy', now(), auth.uid())
    on conflict (ma_hang, part) do update set stt_so = excluded.stt_so, ten = excluded.ten, dvt = excluded.dvt, vat = excluded.vat, sl_nhap = excluded.sl_nhap, dg_nhap = excluded.dg_nhap,
      so_hd_vao = excluded.so_hd_vao, ky_hieu = excluded.ky_hieu, ngay_vao = excluded.ngay_vao, ncc = excluded.ncc, stt_hd = excluded.stt_hd,
      md = case when coalesce(t.match_src, '') = 'tay' then t.md else coalesce(excluded.md, t.md) end, nvkd = coalesce(excluded.nvkd, t.nvkd),
      username = case when coalesce(t.match_src, '') = 'tay' then t.username else coalesce(excluded.username, t.username) end,
      sale_id = case when coalesce(t.match_src, '') <> 'tay' and excluded.nvkd is not null and app.match_sale(excluded.nvkd) is not null then app.match_sale(excluded.nvkd) else t.sale_id end,
      gia_so = coalesce(excluded.gia_so, t.gia_so), legacy = excluded.legacy, updated_at = now(), updated_by = auth.uid()
    returning id into v_id;
    perform app.out_item_match(v_id); v_ids := v_ids || v_id;
  end loop;
  -- lượt 2: dòng cùng mã đơn nằm sau trong file đã có sale/khách → dùng chung
  for v_id in select id from public.out_items where id = any(v_ids) and md is not null and (sale_id is null or username is null) loop perform app.out_item_match(v_id); end loop;
  insert into public.out_events(action, data) values ('import', jsonb_build_object('new', n_new, 'upd', n_upd));
  return jsonb_build_object('new', n_new, 'upd', n_upd);
end $$;
grant execute on function public.out_items_import(jsonb) to authenticated;

-- Dòng đã ký trên sổ cũ → phiếu "Đã ký" của sale, hết tồn. Gọi theo từng nhóm nhỏ.
create or replace function public.out_legacy_import(p_legacy jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare g jsonb; x jsonb; v_inv uuid; t public.out_items; k int; n int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for g in select * from jsonb_array_elements(coalesce(p_legacy, '[]')) loop
    if g->>'status' <> 'da_ky' then continue; end if;
    if exists(select 1 from jsonb_array_elements(g->'lines') e(v) join public.out_items oi on oi.ma_hang = e.v->>'ma_hang' and oi.part = coalesce((e.v->>'part')::int, 1)
              join public.out_invoice_lines l on l.item_id = oi.id) then continue; end if;
    select * into t from public.out_items where ma_hang = g->'lines'->0->>'ma_hang' and part = coalesce((g->'lines'->0->>'part')::int, 1);
    if t.id is null then continue; end if;
    insert into public.out_invoices(sale_id, customer_id, buyer_info, buyer_name, tax_code, address, email, status, so_hd, ngay_hd, legacy, note, status_at)
    values (t.sale_id, t.customer_id, g->>'info', coalesce(nullif(btrim(g->>'buyer_name'), ''), left(split_part(coalesce(g->>'info', ''), E'\n', 1), 200)),
      nullif(btrim(g->>'tax_code'), ''), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), 'da_ky', nullif(g->>'so_hd', ''), nullif(g->>'ngay','')::date, true, 'Nhập từ sổ Excel cũ', now())
    returning id into v_inv;
    if nullif(btrim(g->>'tax_code'), '') is not null and nullif(btrim(g->>'buyer_name'), '') is not null
       and not exists(select 1 from public.out_buyers where btrim(tax_code) = btrim(g->>'tax_code')) then
      insert into public.out_buyers(name, tax_code, address, email, note) values (btrim(g->>'buyer_name'), btrim(g->>'tax_code'), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), 'Từ sổ cũ');
    end if;
    k := 0;
    for x in select * from jsonb_array_elements(g->'lines') loop
      select * into t from public.out_items where ma_hang = x->>'ma_hang' and part = coalesce((x->>'part')::int, 1); k := k + 1;
      -- đã ký = xuất hết phần của dòng đó
      if t.id is not null and t.sl_nhap > 0 then
        insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values (v_inv, t.id, k, t.sl_nhap, coalesce(nullif((x->>'gia')::numeric, 0), t.gia_khach, 0), coalesce((x->>'vat')::numeric, t.vat));
      end if;
    end loop;
    if not exists(select 1 from public.out_invoice_lines where invoice_id = v_inv) then delete from public.out_invoices where id = v_inv; else n := n + 1; end if;
  end loop;
  return n;
end $$;
grant execute on function public.out_legacy_import(jsonb) to authenticated;

-- File đơn hàng: lưu lại (mã đơn → khách, sale) rồi gắn cho các dòng
drop function if exists public.out_orders_import(jsonb);
create or replace function public.out_orders_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; r jsonb; t record; v_md text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_md := case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end; if v_md is null then continue; end if;
    insert into public.out_orders(md, username, nvkd) values (v_md, nullif(btrim(r->>'username'), ''), nullif(btrim(r->>'nvkd'), ''))
    on conflict (md) do update set username = coalesce(excluded.username, out_orders.username), nvkd = coalesce(excluded.nvkd, out_orders.nvkd), updated_at = now();
    for t in select id from public.out_items where md = v_md and (sale_id is null or username is null or customer_id is null) loop
      perform app.out_item_match(t.id); n := n + 1;
    end loop;
  end loop;
  return n;
end $$;
grant execute on function public.out_orders_import(jsonb) to authenticated;

-- Gắn lại toàn bộ dòng còn thiếu (sau khi ghép tên sale, thêm username khách…)
create or replace function public.out_rematch() returns int
language plpgsql security definer set search_path = public, app as $$
declare t record; n int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for t in select id, nvkd from public.out_items where (sale_id is null or customer_id is null or gia_khach is null) and coalesce(match_src, '') <> 'tay' loop
    update public.out_items set sale_id = coalesce(sale_id, app.match_sale(t.nvkd)) where id = t.id;
    perform app.out_item_match(t.id); n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_rematch() to authenticated;

-- Mã đơn sale gõ: "md 2943", "2943" → MD2943 nếu đơn đó có trong hệ thống; ID dạng số (Lanchi) giữ nguyên
create or replace function app.out_md_norm(p text) returns text language sql stable security definer set search_path = public, app as $$
  select case when coalesce(btrim(p), '') = '' then null
              when p ~* 'md' then app.norm_md(p)
              when btrim(p) ~ '^\d+$' and (exists(select 1 from public.out_orders where md = app.norm_md(p)) or exists(select 1 from public.out_items where md = app.norm_md(p))
                                          or exists(select 1 from public.acc_lines where md = app.norm_md(p))) then app.norm_md(p)
              else btrim(p) end
$$;

-- ---------- Sale tra mã đơn / nhận dòng ----------
create or replace function public.out_md_lookup(p_md text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_md text := app.out_md_norm(p_md); v_user text; v_gk numeric; v_kh text;
begin
  if v_md is null then return null; end if;
  select coalesce((select username from public.out_items where md = v_md and username is not null limit 1), (select username from public.out_orders where md = v_md)) into v_user;
  select coalesce((select nullif(gia_khach, 0) from public.acc_lines where md = v_md and not is_test order by updated_at desc limit 1),
                  (select gia_khach from public.out_items where md = v_md and gia_khach is not null limit 1)) into v_gk;
  if v_user is not null then select coalesce(company_name, contact_name) into v_kh from public.customers where deleted_at is null and lower(btrim(sys_username)) = lower(btrim(v_user)) limit 1; end if;
  return jsonb_build_object('md', v_md, 'username', v_user, 'khach', v_kh, 'gia_khach', v_gk);
end $$;
grant execute on function public.out_md_lookup(text) to authenticated;

-- Sale nhận dòng (và các dòng chưa có sale cùng mã đơn); kế toán gán cho sale
drop function if exists public.out_item_claim(uuid, text, text, numeric);
create or replace function public.out_item_claim(p_id uuid, p_md text, p_username text default null, p_gia numeric default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; v_md text := app.out_md_norm(p_md); n int := 0; x record;
begin
  if not app.has_role('sale','tn_kd','tp_kd') and not app.is_acc() then raise exception 'Chỉ sale được nhận dòng'; end if;
  select * into t from public.out_items where id = p_id for update; if t.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if t.sale_id is not null and not app.is_acc() then raise exception 'Dòng đã có sale — báo kế toán nếu nhầm'; end if;
  if v_md is null then raise exception 'Nhập mã đơn (MD)'; end if;
  for x in select id from public.out_items where id = p_id or (md = v_md and sale_id is null) loop
    update public.out_items set md = v_md, sale_id = auth.uid(), username = coalesce(nullif(btrim(p_username), ''), username),
      gia_khach = coalesce(nullif(p_gia, 0), gia_khach), match_src = 'tay', updated_at = now(), updated_by = auth.uid() where id = x.id;
    perform app.out_item_match(x.id);
    insert into public.out_events(item_id, action, data) values (x.id, 'item_claim', jsonb_build_object('md', v_md, 'username', p_username, 'gia', p_gia));
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_item_claim(uuid, text, text, numeric) to authenticated;

-- ---------- HĐ vào ↔ xe ----------
create or replace function public.out_hd_xe_set(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(r->>'so_hd'), '') = '' then continue; end if;
    if coalesce(btrim(r->>'xe'), '') = '' then delete from public.out_hd_xe where so_hd = ltrim(btrim(r->>'so_hd'), '0');
    else insert into public.out_hd_xe(so_hd, xe, tu_dong) values (ltrim(btrim(r->>'so_hd'), '0'), btrim(r->>'xe'), false)
      on conflict (so_hd) do update set xe = excluded.xe, tu_dong = false, updated_at = now(), updated_by = auth.uid(); end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_hd_xe_set(jsonb) to authenticated;

-- Tự gắn xe khi dòng HĐ XML ghép được vào dòng đối soát (kế toán đã sửa tay thì giữ)
create or replace function app.trg_acc_invline_xe() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if new.line_id is null then return null; end if;
  insert into public.out_hd_xe(so_hd, xe, tu_dong)
  select ltrim(i.so_hd, '0'), tr.name, true from public.acc_invoices i, public.acc_lines l join public.acc_trucks tr on tr.id = l.truck_id
   where i.id = new.invoice_id and l.id = new.line_id and not tr.is_test
  on conflict (so_hd) do nothing;
  return null;
end $$;
drop trigger if exists acc_invline_xe on public.acc_invoice_lines;
create trigger acc_invline_xe after insert or update of line_id on public.acc_invoice_lines for each row execute function app.trg_acc_invline_xe();
insert into public.out_hd_xe(so_hd, xe, tu_dong)
select distinct on (ltrim(i.so_hd, '0')) ltrim(i.so_hd, '0'), tr.name, true
  from public.acc_invoice_lines il join public.acc_invoices i on i.id = il.invoice_id join public.acc_lines l on l.id = il.line_id join public.acc_trucks tr on tr.id = l.truck_id
 where not tr.is_test order by ltrim(i.so_hd, '0'), tr.created_at
on conflict (so_hd) do nothing;

-- ---------- View nhanh (1 lần gộp, không gọi hàm từng dòng) ----------
drop view if exists public.out_items_v;
create view public.out_items_v with (security_invoker = true) as
  select t.*, coalesce(u.sl, 0) as sl_xuat, t.sl_nhap - coalesce(u.sl, 0) as ton, u.phieu,
    coalesce(c.company_name, c.contact_name) as khach, x.xe
  from public.out_items t
  left join (select l.item_id, sum(l.sl) sl, string_agg(i.code || ':' || i.status, ',' order by i.code) phieu
               from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id where i.status <> 'huy' group by l.item_id) u on u.item_id = t.id
  left join public.customers c on c.id = t.customer_id
  left join public.out_hd_xe x on x.so_hd = ltrim(t.so_hd_vao, '0');
grant select on public.out_items_v to authenticated;

-- ---------- Dọn dữ liệu đã nạp ----------
-- Phiếu sổ cũ: chỉ giữ phiếu Đã ký, dòng đã ký trừ hết tồn
delete from public.out_invoices where legacy and status <> 'da_ky';
update public.out_invoice_lines l set sl = oi.sl_nhap from public.out_items oi, public.out_invoices i
 where oi.id = l.item_id and i.id = l.invoice_id and i.legacy and l.sl <> oi.sl_nhap;
-- Giá xuất theo sổ cho dòng đã nạp
update public.out_items set gia_so = nullif((legacy->>'dg_xuat')::numeric, 0) where gia_so is null and legacy ? 'dg_xuat';
update public.out_items set gia_khach = coalesce(gia_khach, gia_so) where gia_khach is null and gia_so is not null;

reset search_path;


-- >>>>> supabase/migrations/0025_v18.sql
-- =====================================================================
-- 0025 · Bản 18: tối ưu tốc độ + dung lượng
--  · Danh sách Xuất HĐ đầu ra tải theo trang (lọc/tìm/đếm trên máy chủ), mặc định "còn tồn" / "chờ xuất nháp"
--  · "Đã ký không sale" tách riêng, không tính vào "Chưa gắn sale"
--  · Đổi tên xe (đối soát + cột Xe)
--  · Sao lưu tự động giữ 3 bản gần nhất, không chép nhật ký hệ thống
-- =====================================================================
set search_path = public, app, extensions;

-- ---------- Sao lưu gọn ----------
create or replace function public.backup_create(p_note text default null) returns text
language plpgsql security definer set search_path = public, app as $$
declare s text := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS'); t record; old record;
begin
  if auth.uid() is not null and not app.is_admin() then raise exception 'Chỉ Admin được tạo bản sao lưu'; end if;
  while exists(select 1 from pg_namespace where nspname = s) loop
    perform pg_sleep(1); s := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS');
  end loop;
  execute format('create schema %I', s);
  execute format('revoke all on schema %I from public, anon, authenticated', s);
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and c.relname not in ('audit_logs', 'notifications') loop
    execute format('create table %I.%I as table public.%I', s, t.relname, t.relname);
  end loop;
  execute format('comment on schema %I is %L', s, coalesce(p_note, 'Sao lưu') || ' · ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'));
  -- giữ 3 bản gần nhất (bản đầy đủ hằng ngày đã lưu trên Google Drive)
  for old in select nspname from pg_namespace where nspname ~ '^bk_[0-9]{8}_[0-9]{6}$' order by nspname desc offset 3 loop
    execute format('drop schema %I cascade', old.nspname);
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('BACKUP', s, jsonb_build_object('note', p_note));
  return s;
end $$;
select public.backup_create('Trước khi cập nhật bản 18');

-- Nhật ký hệ thống: giữ 180 ngày
delete from public.audit_logs where at < now() - interval '180 days';

-- ---------- Đổi tên xe ----------
create or replace function public.acc_truck_rename(p_id uuid, p_name text) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_old text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Nhập tên xe'; end if;
  select name into v_old from public.acc_trucks where id = p_id;
  update public.acc_trucks set name = btrim(p_name), updated_at = now() where id = p_id;
  update public.out_hd_xe set xe = btrim(p_name), updated_at = now() where xe = v_old;
  insert into public.acc_events(truck_id, action, note) values (p_id, 'rename', coalesce(v_old, '') || ' → ' || btrim(p_name));
end $$;
grant execute on function public.acc_truck_rename(uuid, text) to authenticated;

create or replace function public.out_xe_rename(p_old text, p_new text) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if coalesce(btrim(p_new), '') = '' then raise exception 'Nhập tên xe mới'; end if;
  update public.out_hd_xe set xe = btrim(p_new), tu_dong = false, updated_at = now(), updated_by = auth.uid() where xe = p_old;
  get diagnostics n = row_count;
  update public.acc_trucks set name = btrim(p_new), updated_at = now() where name = p_old;
  return n;
end $$;
grant execute on function public.out_xe_rename(text, text) to authenticated;

-- ---------- Dòng sổ: trang + bộ lọc + thống kê (theo quyền người xem) ----------
create index if not exists out_items_stt on public.out_items(stt_so desc nulls last);

create or replace function public.out_items_page(p jsonb) returns jsonb
language plpgsql stable security invoker set search_path = public, app as $$
declare v_mode text := coalesce(p->>'mode', 'acc'); v_f text := nullif(p->>'f', ''); v_q text := nullif(btrim(p->>'q'), '');
        v_hd text := nullif(p->>'hd', ''); v_xe text := nullif(p->>'xe', ''); v_sale text := nullif(p->>'sale', '');
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint;
begin
  with base as (
    select * from public.out_items_v t
     where (v_mode <> 'mine' or (t.sale_id is not null and app.in_tree(t.sale_id)))
       and (v_mode <> 'free' or t.sale_id is null)
       and (v_mode = 'acc' or t.ton > 0.0001)
       and (v_f is null or (v_f = 'ton' and t.ton > 0.0001) or (v_f = 'het' and t.ton <= 0.0001)
            or (v_f = 'nosale' and t.sale_id is null and t.ton > 0.0001) or (v_f = 'daky_nosale' and t.sale_id is null and t.ton <= 0.0001)
            or (v_f = 'nomd' and t.md is null) or (v_f = 'nogia' and t.gia_khach is null and t.ton > 0.0001))
       and (v_hd is null or t.so_hd_vao = v_hd) and (v_xe is null or coalesce(t.xe, '—') = v_xe)
       and (v_sale is null or coalesce(t.sale_id::text, '—') = v_sale)
       and (v_q is null or concat_ws(' ', t.ma_hang, t.ten, t.md, t.nvkd, t.username, t.khach, t.so_hd_vao, t.xe) ilike '%' || v_q || '%'))
  select count(*), coalesce(jsonb_agg(to_jsonb(x) - 'legacy' || jsonb_build_object('legacy', x.legacy) order by x.stt_so desc nulls last, x.ma_hang, x.part)
           filter (where x.rn > v_off and x.rn <= v_off + v_lim), '[]')
    into n, r
    from (select b.*, row_number() over (order by b.stt_so desc nulls last, b.ma_hang, b.part) rn from base b) x;
  return jsonb_build_object('total', n, 'rows', r);
end $$;
grant execute on function public.out_items_page(jsonb) to authenticated;

create or replace function public.out_items_stats(p_mode text) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object(
    'all', count(*), 'ton', count(*) filter (where ton > 0.0001), 'het', count(*) filter (where ton <= 0.0001),
    'nosale', count(*) filter (where sale_id is null and ton > 0.0001), 'daky_nosale', count(*) filter (where sale_id is null and ton <= 0.0001),
    'nomd', count(*) filter (where md is null), 'nogia', count(*) filter (where gia_khach is null and ton > 0.0001),
    'gia_tri', coalesce(sum(ton * coalesce(gia_khach, dg_nhap, 0)) filter (where ton > 0.0001), 0),
    'hd', (select coalesce(jsonb_agg(distinct so_hd_vao), '[]') from public.out_items_v v where (p_mode <> 'mine' or (v.sale_id is not null and app.in_tree(v.sale_id))) and (p_mode <> 'free' or (v.sale_id is null and v.ton > 0.0001))),
    'xe', (select coalesce(jsonb_agg(distinct coalesce(xe, '—')), '[]') from public.out_items_v v where (p_mode <> 'mine' or (v.sale_id is not null and app.in_tree(v.sale_id))) and (p_mode <> 'free' or (v.sale_id is null and v.ton > 0.0001))),
    'sale', (select coalesce(jsonb_agg(distinct coalesce(sale_id::text, '—')), '[]') from public.out_items v where p_mode = 'acc'))
  from public.out_items_v t
  where (p_mode <> 'mine' or (t.sale_id is not null and app.in_tree(t.sale_id))) and (p_mode <> 'free' or t.sale_id is null)
$$;
grant execute on function public.out_items_stats(text) to authenticated;

-- ---------- Phiếu: view có sẵn tổng tiền + trang ----------
drop view if exists public.out_invoices_v;
create view public.out_invoices_v with (security_invoker = true) as
  select i.*, coalesce(a.n, 0) as so_dong, coalesce(a.tt, 0) as tien_hang, coalesce(a.thue, 0) as tien_thue, coalesce(a.duoi_gia, false) as duoi_gia, a.tim
  from public.out_invoices i
  left join (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
                    bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim
               from public.out_invoice_lines l join public.out_items t on t.id = l.item_id group by l.invoice_id) a on a.invoice_id = i.id;
grant select on public.out_invoices_v to authenticated;

create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security invoker set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb;
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c from (select status, count(*) k from public.out_invoices_v where v_sale is null or sale_id = v_sale group by status) z;
  with base as (select * from public.out_invoices_v v
     where (v_st is null and v.status <> 'huy' or v.status = v_st) and (v_sale is null or v.sale_id = v_sale)
       and (v_q is null or concat_ws(' ', v.code, v.buyer_name, v.tax_code, v.so_hd, v.buyer_info, v.tim) ilike '%' || v_q || '%'))
  select count(*), coalesce(jsonb_agg(to_jsonb(x) - 'tim' order by x.status_at desc) filter (where x.rn > v_off and x.rn <= v_off + v_lim), '[]') into n, r
    from (select b.*, row_number() over (order by b.status_at desc) rn from base b) x;
  return jsonb_build_object('total', n, 'rows', r, 'counts', c);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0026_v19.sql
-- =====================================================================
-- 0026 · Bản 19: tăng tốc cho tài khoản sale / quản lý sale
--  · app.in_tree: tính cây nhân sự 1 lần mỗi lượt gọi (trước đây tính lại cho TỪNG dòng → rất chậm với sale)
--  · Trang Xuất HĐ đầu ra: hàm đọc riêng, gom 1 lần, lọc theo quyền ngay từ đầu
--  · Lọc theo khách / chưa gắn khách / chưa gắn đơn / chưa có giá xuất; danh sách sale theo nhóm
--  · Sổ cũ "Đã xuất nháp" → phiếu "Đã xuất nháp – chờ sale" của từng sale
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 19');

-- ---------- Cây nhân sự: nhớ trong 1 lượt gọi ----------
create or replace function app.in_tree(p_id uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare k text := coalesce(auth.uid()::text, '-'); c text := current_setting('nt.tree', true); t uuid[];
begin
  if p_id is null then return false; end if;
  if c is not null and c <> '' and split_part(c, '|', 1) = k then t := split_part(c, '|', 2)::uuid[];
  else t := app.my_tree(); perform set_config('nt.tree', k || '|' || t::text, true); end if;
  return p_id = any(t);
end $$;

-- ---------- Dòng sổ (đọc nhanh, đúng quyền) ----------
create index if not exists out_invoice_lines_item_inv on public.out_invoice_lines(item_id, invoice_id);

create or replace function app.out_items_scope(p_mode text) returns setof public.out_items
language plpgsql stable security definer set search_path = public, app as $$
declare v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree(); v_sale boolean := app.has_role('sale','tn_kd','tp_kd');
begin
  if p_mode = 'acc' then
    if not v_acc then return; end if;
    return query select * from public.out_items;
  elsif p_mode = 'free' then
    if not (v_acc or v_sale) then return; end if;
    return query select * from public.out_items where sale_id is null;
  else
    return query select * from public.out_items where sale_id = any(v_tree);
  end if;
end $$;

drop function if exists public.out_items_page(jsonb);
create or replace function public.out_items_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_mode text := coalesce(p->>'mode', 'acc'); v_f text := nullif(p->>'f', ''); v_q text := nullif(btrim(p->>'q'), '');
        v_hd text := nullif(p->>'hd', ''); v_xe text := nullif(p->>'xe', ''); v_sale text := nullif(p->>'sale', ''); v_kh text := nullif(p->>'kh', '');
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
            or (v_f = 'nokhach' and t.customer_id is null and t.username is null))
       and (v_hd is null or t.so_hd_vao = v_hd) and (v_xe is null or coalesce(t.xe, '—') = v_xe)
       and (v_sale is null or coalesce(t.sale_id::text, '—') = v_sale)
       and (v_kh is null or coalesce(t.customer_id::text, t.username, '—') = v_kh)
       and (v_q is null or concat_ws(' ', t.ma_hang, t.ten, t.md, t.nvkd, t.username, t.khach, t.so_hd_vao, t.xe) ilike '%' || v_q || '%')),
  o as (select f.*, row_number() over (order by f.stt_so desc nulls last, f.ma_hang, f.part) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r);
end $$;
grant execute on function public.out_items_page(jsonb) to authenticated;

drop function if exists public.out_items_stats(text);
create or replace function public.out_items_stats(p_mode text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb;
begin
  with s as (select * from app.out_items_scope(p_mode)),
  a as (select l.item_id, sum(l.sl) sl from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id
         where i.status <> 'huy' and l.item_id in (select id from s) group by l.item_id),
  b as (select s.id, s.sale_id, s.md, s.customer_id, s.username, s.gia_khach, s.dg_nhap, s.so_hd_vao, s.sl_nhap - coalesce(a.sl, 0) ton,
               x.xe, coalesce(c.company_name, c.contact_name) khach
          from s left join a on a.item_id = s.id left join public.out_hd_xe x on x.so_hd = ltrim(s.so_hd_vao, '0') left join public.customers c on c.id = s.customer_id),
  v as (select * from b where p_mode = 'acc' or ton > 0.0001)
  select jsonb_build_object(
    'all', count(*), 'ton', count(*) filter (where ton > 0.0001), 'het', count(*) filter (where ton <= 0.0001),
    'nosale', count(*) filter (where sale_id is null and ton > 0.0001), 'daky_nosale', count(*) filter (where sale_id is null and ton <= 0.0001),
    'nomd', count(*) filter (where md is null), 'nogia', count(*) filter (where gia_khach is null and ton > 0.0001),
    'nokhach', count(*) filter (where customer_id is null and username is null),
    'gia_tri', coalesce(sum(ton * coalesce(gia_khach, dg_nhap, 0)) filter (where ton > 0.0001), 0),
    'hd', coalesce((select jsonb_agg(distinct so_hd_vao) from v where so_hd_vao is not null), '[]'),
    'xe', coalesce((select jsonb_agg(distinct coalesce(xe, '—')) from v), '[]'),
    'kh', coalesce((select jsonb_agg(jsonb_build_array(k, t) order by t) from (select distinct coalesce(customer_id::text, username) k, coalesce(khach, username) t from v where coalesce(customer_id::text, username) is not null) z), '[]'),
    'sale', coalesce((select jsonb_agg(distinct coalesce(sale_id::text, '—')) from v), '[]'))
  into r from v;
  return r;
end $$;
grant execute on function public.out_items_stats(text) to authenticated;

-- Danh sách sale được xem: kế toán/admin = mọi sale; quản lý = cả nhóm; sale = chính mình
create or replace function public.out_sale_opts() returns table(id uuid, full_name text)
language sql stable security definer set search_path = public, app as $$
  select p.id, p.full_name from public.profiles p
   where p.status = 'active' and p.roles && array['sale','tn_kd','tp_kd']
     and (app.is_acc() or p.id = any(app.my_tree()))
   order by p.full_name
$$;
grant execute on function public.out_sale_opts() to authenticated;

-- ---------- Phiếu (đọc nhanh, đúng quyền) ----------
drop function if exists public.out_invoices_page(jsonb);
create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree();
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale) group by status) z;
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia
          from base b left join a on a.invoice_id = b.id
         where v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%'),
  o as (select f.*, row_number() over (order by f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

-- ---------- Sổ cũ: dòng đã xuất nháp → phiếu "Đã xuất nháp – chờ sale" ----------
create or replace function public.out_legacy_import(p_legacy jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare g jsonb; x jsonb; v_inv uuid; t public.out_items; k int; n int := 0; v_st text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for g in select * from jsonb_array_elements(coalesce(p_legacy, '[]')) loop
    v_st := g->>'status'; if v_st not in ('da_ky','da_nhap','xac_nhan_ky') then continue; end if;
    if exists(select 1 from jsonb_array_elements(g->'lines') e(v) join public.out_items oi on oi.ma_hang = e.v->>'ma_hang' and oi.part = coalesce((e.v->>'part')::int, 1)
              join public.out_invoice_lines l on l.item_id = oi.id) then continue; end if;
    select * into t from public.out_items where ma_hang = g->'lines'->0->>'ma_hang' and part = coalesce((g->'lines'->0->>'part')::int, 1);
    if t.id is null then continue; end if;
    insert into public.out_invoices(sale_id, customer_id, buyer_info, buyer_name, tax_code, address, email, status, so_hd, ngay_hd, legacy, note, status_at)
    values (t.sale_id, t.customer_id, g->>'info', coalesce(nullif(btrim(g->>'buyer_name'), ''), left(split_part(coalesce(g->>'info', ''), E'\n', 1), 200)),
      nullif(btrim(g->>'tax_code'), ''), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), v_st,
      case when v_st = 'da_ky' then nullif(g->>'so_hd', '') end, case when v_st = 'da_ky' then nullif(g->>'ngay','')::date end, true,
      case when v_st = 'da_ky' then 'Nhập từ sổ Excel cũ' else 'Sổ cũ: đã xuất nháp — sale kiểm tra, xác nhận ký' end, now())
    returning id into v_inv;
    if nullif(btrim(g->>'tax_code'), '') is not null and nullif(btrim(g->>'buyer_name'), '') is not null
       and not exists(select 1 from public.out_buyers where btrim(tax_code) = btrim(g->>'tax_code')) then
      insert into public.out_buyers(name, tax_code, address, email, note) values (btrim(g->>'buyer_name'), btrim(g->>'tax_code'), nullif(btrim(g->>'address'), ''), nullif(btrim(g->>'email'), ''), 'Từ sổ cũ');
    end if;
    k := 0;
    for x in select * from jsonb_array_elements(g->'lines') loop
      select * into t from public.out_items where ma_hang = x->>'ma_hang' and part = coalesce((x->>'part')::int, 1); k := k + 1;
      if t.id is not null and t.sl_nhap > 0 then
        insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values (v_inv, t.id, k, t.sl_nhap, coalesce(nullif((x->>'gia')::numeric, 0), t.gia_khach, 0), coalesce((x->>'vat')::numeric, t.vat));
      end if;
    end loop;
    if not exists(select 1 from public.out_invoice_lines where invoice_id = v_inv) then delete from public.out_invoices where id = v_inv; else n := n + 1; end if;
  end loop;
  return n;
end $$;

-- Chuyển dữ liệu đã nạp: dòng sổ cũ "đã xuất nháp / KD xác nhận ký" chưa có phiếu → tạo phiếu theo nhóm thông tin xuất HĐ
do $$
declare g record; v_inv uuid; k int; t record; v_name text;
begin
  for g in select legacy->>'status' st, coalesce(legacy->>'info', '') info, coalesce(legacy->>'so_hd_ra', '') sohd,
                  array_agg(id order by stt_so, ma_hang, part) ids
             from public.out_items oi
            where legacy->>'status' in ('da_nhap', 'xac_nhan_ky') and not exists(select 1 from public.out_invoice_lines l where l.item_id = oi.id)
            group by 1, 2, 3 loop
    select ln into v_name from unnest(string_to_array(g.info, E'\n')) ln
     where ln ~* '(CÔNG TY|CTY|HỘ KINH DOANH|HKD|DOANH NGHIỆP|CHI NHÁNH)' and ln !~* 'xuất giá' limit 1;
    insert into public.out_invoices(sale_id, customer_id, buyer_info, buyer_name, tax_code, email, status, legacy, note, status_at)
    select oi.sale_id, oi.customer_id, nullif(g.info, ''), coalesce(nullif(btrim(regexp_replace(regexp_replace(v_name, '^[^:]*:\s*', ''), '["“”]', '', 'g')), ''), left(split_part(g.info, E'\n', 1), 200)),
           substring(g.info from '(?:MST|Mã số thuế|mã số thuế|Tax code)[^0-9]*([0-9]{12}|[0-9]{10}(?:-[0-9]{3})?)'),
           substring(g.info from '([A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)'),
           g.st, true, 'Sổ cũ: đã xuất nháp — sale kiểm tra, xác nhận ký', now()
      from public.out_items oi where oi.id = g.ids[1] returning id into v_inv;
    k := 0;
    for t in select * from public.out_items where id = any(g.ids) order by stt_so, ma_hang, part loop
      k := k + 1;
      if t.sl_nhap > 0 then
        insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat)
        values (v_inv, t.id, k, t.sl_nhap, coalesce(nullif((t.legacy->>'dg_xuat')::numeric, 0), t.gia_khach, 0), t.vat);
      end if;
    end loop;
    if not exists(select 1 from public.out_invoice_lines where invoice_id = v_inv) then delete from public.out_invoices where id = v_inv; end if;
  end loop;
end $$;

reset search_path;


-- >>>>> supabase/migrations/0027_v20.sql
-- =====================================================================
-- 0027 · Bản 20: File PDF hóa đơn (nháp / đã ký) lưu trên Google Drive
--  · Kế toán / anh tải PDF hàng loạt → ghép phiếu xuất HĐ theo MST + tổng tiền (+ số HĐ khi đã ký)
--  · File nằm kín trên Drive (không chia sẻ). Supabase chỉ giữ mã file.
--  · Xem file bằng VÉ dùng 1 lần, hết hạn nhanh, gắn đúng file + người xin; Apps Script hỏi lại Supabase rồi mới trả file
--  · Tải file lên Drive cũng bằng vé → bỏ khóa tải lên cố định (upload_key) trong Cấu hình
--  · Nháp v1, v2…: bản mới → sale được báo, xác nhận "khách OK" của bản cũ tự hủy; bản đã ký → phiếu "Đã ký", điền số HĐ
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 20');

-- ---------- Bảng file ----------
create table if not exists public.out_invoice_files(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.out_invoices(id) on delete cascade,
  kind text not null check (kind in ('nhap','ky')),
  version int not null,
  drive_id text not null,
  file_name text, size_kb int, tong numeric, mst text, so_hd text, ky_hieu text, ngay date,
  note text,
  uploaded_by uuid default auth.uid() references public.profiles(id), uploaded_at timestamptz not null default now(),
  sent_at timestamptz, sent_by uuid references public.profiles(id),
  unique (invoice_id, kind, version)
);
create index if not exists out_invoice_files_inv on public.out_invoice_files(invoice_id, kind, version desc);
alter table public.out_invoice_files enable row level security;
-- Không cấp quyền đọc bảng trực tiếp: mọi truy cập qua hàm bên dưới (mã file Drive không lộ ra trình duyệt)
revoke all on public.out_invoice_files from anon, authenticated;

-- ---------- Vé truy cập Drive ----------
create table if not exists app.drive_tickets(
  token_hash text primary key,
  kind text not null check (kind in ('view','upload')),
  file_id uuid, folder text, user_id uuid,
  created_at timestamptz not null default now(), expires_at timestamptz not null, used_at timestamptz
);
create index if not exists drive_tickets_exp on app.drive_tickets(expires_at);
revoke all on app.drive_tickets from anon, authenticated;

create or replace function app.drive_new_ticket(p_kind text, p_file uuid, p_folder text, p_ttl interval) returns text
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_tok text := encode(gen_random_bytes(24), 'hex');
begin
  delete from app.drive_tickets where expires_at < now() - interval '1 day';
  insert into app.drive_tickets(token_hash, kind, file_id, folder, user_id, expires_at)
  values (encode(digest(v_tok, 'sha256'), 'hex'), p_kind, p_file, p_folder, auth.uid(), now() + p_ttl);
  return v_tok;
end $$;

-- Tổng tiền thanh toán của phiếu (tiền hàng + thuế, làm tròn từng dòng như mẫu MISA)
create or replace function app.out_inv_total(p_id uuid) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(round(l.sl * l.don_gia) + round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))), 0)
    from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = p_id
$$;

-- Vé tải lên (Kế toán / Admin / BGĐ). 1 vé cho 1 file, theo đúng thư mục xin
create or replace function public.drive_upload_tickets(p_folders text[]) returns text[]
language plpgsql security definer set search_path = public, app as $$
declare f text; r text[] := '{}';
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin được lưu file lên Drive'; end if;
  if coalesce(array_length(p_folders, 1), 0) = 0 or array_length(p_folders, 1) > 300 then raise exception 'Số file không hợp lệ'; end if;
  foreach f in array p_folders loop
    f := regexp_replace(coalesce(f, 'Khac'), '\.\.+', '', 'g');
    r := r || app.drive_new_ticket('upload', null, left(f, 200), interval '30 minutes');
  end loop;
  return r;
end $$;
grant execute on function public.drive_upload_tickets(text[]) to authenticated;

-- Vé xem 1 file: chỉ người có quyền với phiếu (sale của phiếu, cấp trên theo cây nhân sự, Kế toán / Admin)
create or replace function public.out_file_ticket(p_file uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare v_sale uuid; v_ok boolean;
begin
  select i.sale_id, true into v_sale, v_ok from public.out_invoice_files f join public.out_invoices i on i.id = f.invoice_id where f.id = p_file;
  if v_ok is null or not (app.is_acc() or app.in_tree(v_sale)) then raise exception 'Không có quyền xem file này'; end if;
  return app.drive_new_ticket('view', p_file, null, interval '2 minutes');
end $$;
grant execute on function public.out_file_ticket(uuid) to authenticated;

-- Apps Script đổi vé (kèm mã bí mật của Apps Script). Vé dùng 1 lần.
create or replace function public.drive_redeem(p_token text, p_ticket text) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
declare t app.drive_tickets; v_drive text;
begin
  perform app.backup_check(p_token);
  update app.drive_tickets set used_at = now()
   where token_hash = encode(digest(coalesce(p_ticket, ''), 'sha256'), 'hex') and used_at is null and expires_at > now()
  returning * into t;
  if t.token_hash is null then raise exception 'Vé không hợp lệ hoặc đã hết hạn'; end if;
  if t.kind = 'upload' then return jsonb_build_object('kind', 'upload', 'folder', t.folder); end if;
  select drive_id into v_drive from public.out_invoice_files where id = t.file_id;
  if v_drive is null then raise exception 'File không còn'; end if;
  insert into public.audit_logs(actor_id, action, table_name, record_id) values (t.user_id, 'VIEW_HD_FILE', 'out_invoice_files', t.file_id::text);
  return jsonb_build_object('kind', 'view', 'drive_id', v_drive);
end $$;
revoke all on function public.drive_redeem(text, text) from public;
grant execute on function public.drive_redeem(text, text) to anon, authenticated;

-- ---------- Khóa tải lên cố định: bỏ ----------
update public.settings set value = value - 'upload_key' where key = 'drive';
create or replace function public.set_drive(p_value jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin/BGĐ'; end if;
  insert into public.settings(key, value, updated_by) values ('drive', coalesce(p_value, '{}') - 'upload_key', auth.uid())
    on conflict (key) do update set value = (public.settings.value || excluded.value) - 'upload_key', updated_at = now(), updated_by = auth.uid();
end $$;
grant execute on function public.set_drive(jsonb) to authenticated;

-- ---------- Ghép file với phiếu ----------
-- p_rows: [{i, kind:'nhap'|'ky', mst, tong, so_hd, ky_hieu, name}]
create or replace function public.out_file_match(p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb; out jsonb := '[]'; v_mst text; v_tong numeric; v_kind text; v_so text; cands jsonb; v_auto uuid; v_dup boolean; n_ok int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    v_kind := r->>'kind'; v_mst := regexp_replace(coalesce(r->>'mst', ''), '\D', '', 'g'); v_tong := nullif(r->>'tong', '')::numeric;
    v_so := nullif(ltrim(regexp_replace(coalesce(r->>'so_hd', ''), '\D', '', 'g'), '0'), '');
    with inv as (
      select v.id, v.code, v.status, coalesce(v.buyer_name, left(v.buyer_info, 120)) buyer_name, v.sale_id, v.so_hd,
             app.out_inv_total(v.id) tong,
             (select f.tong from public.out_invoice_files f where f.invoice_id = v.id and f.kind = 'nhap' order by f.version desc limit 1) nhap_tong,
             (select f.file_name from public.out_invoice_files f where f.invoice_id = v.id and f.kind = 'nhap' order by f.version desc limit 1) nhap_name,
             (select max(f.version) from public.out_invoice_files f where f.invoice_id = v.id and f.kind = 'nhap') nhap_v,
             (select f.so_hd from public.out_invoice_files f where f.invoice_id = v.id and f.kind = 'ky' order by f.version desc limit 1) ky_so
        from public.out_invoices v
       where v.status <> 'huy' and (
             (v_mst <> '' and (regexp_replace(coalesce(v.tax_code, ''), '\D', '', 'g') = v_mst or v.buyer_info like '%' || v_mst || '%'))
          or (v_kind = 'ky' and v_so is not null and ltrim(v.so_hd, '0') = v_so))
    ), sc as (
      select inv.*,
        case when v_kind = 'nhap' then inv.status in ('cho_nhap','da_nhap','xac_nhan_ky')
             else inv.status in ('da_nhap','xac_nhan_ky') or (inv.status = 'da_ky' and (inv.so_hd is null or ltrim(inv.so_hd, '0') = v_so)) end ok,
        coalesce(v_tong is not null and (abs(inv.tong - v_tong) <= 100 or inv.nhap_tong = v_tong), false) tien_khop,
        coalesce(v_kind = 'ky' and v_so is not null and ltrim(coalesce(inv.so_hd, inv.ky_so, ''), '0') = v_so, false) so_khop
      from inv
    )
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'status', status, 'buyer_name', buyer_name, 'sale_id', sale_id, 'tong', tong,
             'nhap_tong', nhap_tong, 'nhap_v', nhap_v, 'ky_so', ky_so, 'so_hd', so_hd, 'ok', ok, 'khop', so_khop or tien_khop,
             'dup', case when v_kind = 'nhap' then nhap_name is not null and nhap_name = r->>'name' else ky_so is not null and ltrim(ky_so, '0') = v_so end)
             order by so_khop desc, (ok and tien_khop) desc, ok desc, abs(tong - coalesce(v_tong, tong))), '[]'),
           count(*) filter (where ok and (so_khop or tien_khop))
      into cands, n_ok from sc;
    v_auto := null; v_dup := false;
    if n_ok = 1 then
      select (e->>'id')::uuid, (e->>'dup')::boolean into v_auto, v_dup from jsonb_array_elements(cands) e where (e->>'ok')::boolean and (e->>'khop')::boolean limit 1;
    elsif n_ok > 1 and v_kind = 'ky' then  -- nhiều phiếu cùng MST + tiền: ưu tiên phiếu đúng số HĐ
      select (e->>'id')::uuid, (e->>'dup')::boolean into v_auto, v_dup from jsonb_array_elements(cands) e
       where (e->>'ok')::boolean and v_so is not null and ltrim(coalesce(e->>'so_hd', e->>'ky_so', ''), '0') = v_so limit 1;
    end if;
    out := out || jsonb_build_object('i', r->'i', 'auto', v_auto, 'dup', v_dup, 'n_khop', n_ok, 'cands', (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(cands) x limit 8) z));
  end loop;
  return out;
end $$;
grant execute on function public.out_file_match(jsonb) to authenticated;

-- Gắn 1 file đã lưu Drive vào phiếu
create or replace function public.out_file_attach(p_invoice uuid, p_kind text, p_drive_id text, p_name text, p_size_kb int, p_tong numeric,
  p_mst text, p_so_hd text default null, p_ky_hieu text default null, p_ngay date default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; v_ver int; v_note text; v_so text := nullif(btrim(p_so_hd), ''); v_new text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin'; end if;
  if p_kind not in ('nhap','ky') or coalesce(btrim(p_drive_id), '') = '' then raise exception 'Thiếu thông tin file'; end if;
  select * into v from public.out_invoices where id = p_invoice for update;
  if v.id is null then raise exception 'Không có phiếu'; end if;
  if p_kind = 'nhap' and v.status not in ('cho_nhap','da_nhap','xac_nhan_ky') then
    raise exception 'Phiếu % đang "%" — không gắn bản nháp được', v.code, v.status; end if;
  if p_kind = 'ky' then
    if v_so is null then raise exception 'Thiếu số HĐ đã ký cho phiếu %', v.code; end if;
    if v.status not in ('da_nhap','xac_nhan_ky','da_ky') then raise exception 'Phiếu % đang "%" — không gắn bản đã ký được', v.code, v.status; end if;
    if v.status = 'da_ky' and v.so_hd is not null and ltrim(v.so_hd, '0') <> ltrim(v_so, '0') then
      raise exception 'Phiếu % đã ký số HĐ %, file là số %', v.code, v.so_hd, v_so; end if;
  end if;
  select coalesce(max(version), 0) + 1 into v_ver from public.out_invoice_files where invoice_id = v.id and kind = p_kind;
  insert into public.out_invoice_files(invoice_id, kind, version, drive_id, file_name, size_kb, tong, mst, so_hd, ky_hieu, ngay)
  values (v.id, p_kind, v_ver, btrim(p_drive_id), left(p_name, 200), p_size_kb, p_tong, nullif(btrim(p_mst), ''), v_so, nullif(btrim(p_ky_hieu), ''), p_ngay);

  if p_kind = 'nhap' then
    v_new := case when v.status = 'cho_nhap' then 'da_nhap' when v.status = 'xac_nhan_ky' then 'da_nhap' else v.status end;
    v_note := 'Tải HĐ nháp v' || v_ver || case when v.status = 'xac_nhan_ky' then ' — bản mới, xác nhận ký của bản cũ đã hủy' else '' end;
    update public.out_invoices set status = v_new, sua_sau_nhap = false, updated_at = now(),
      status_at = case when v_new <> v.status then now() else status_at end, status_by = case when v_new <> v.status then auth.uid() else status_by end
     where id = v.id;
    insert into public.out_events(invoice_id, action, note, data) values (v.id, 'file', v_note, jsonb_build_object('kind', 'nhap', 'version', v_ver, 'from', v.status, 'to', v_new));
    perform app.notify(v.sale_id, 'acc',
      case when v_ver = 1 then 'Đã có HĐ nháp — xem, gửi khách: ' else 'HĐ nháp mới v' || v_ver || ' — gửi lại khách: ' end || v.code,
      coalesce(v.buyer_name, '') || case when v.status = 'xac_nhan_ky' then ' — khách cần xác nhận lại bản mới' else '' end, '#/out?inv=' || v.id);
  else
    update public.out_invoices set status = 'da_ky', so_hd = coalesce(so_hd, v_so), ngay_hd = coalesce(ngay_hd, p_ngay, current_date), updated_at = now(),
      status_at = case when v.status <> 'da_ky' then now() else status_at end, status_by = case when v.status <> 'da_ky' then auth.uid() else status_by end
     where id = v.id;
    insert into public.out_events(invoice_id, action, note, data) values (v.id, 'file', 'Tải HĐ đã ký số ' || v_so || case when v_ver > 1 then ' (bản ' || v_ver || ')' else '' end,
      jsonb_build_object('kind', 'ky', 'version', v_ver, 'from', v.status, 'to', 'da_ky', 'so_hd', v_so));
    perform app.notify(v.sale_id, 'acc', 'HĐ đã ký số ' || v_so || ' — in làm hợp đồng, báo khách: ' || v.code, coalesce(v.buyer_name, ''), '#/out?inv=' || v.id);
  end if;
  return jsonb_build_object('version', v_ver, 'status', case when p_kind = 'ky' then 'da_ky' else v_new end);
end $$;
grant execute on function public.out_file_attach(uuid, text, text, text, int, numeric, text, text, text, date) to authenticated;

-- Danh sách file của phiếu (không trả mã Drive)
create or replace function public.out_files_list(p_invoice uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_sale uuid; v_ok boolean;
begin
  select sale_id, true into v_sale, v_ok from public.out_invoices where id = p_invoice;
  if v_ok is null or not (app.is_acc() or app.in_tree(v_sale)) then raise exception 'Không có quyền'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'version', f.version, 'file_name', f.file_name, 'size_kb', f.size_kb, 'tong', f.tong,
      'so_hd', f.so_hd, 'ky_hieu', f.ky_hieu, 'ngay', f.ngay, 'uploaded_at', f.uploaded_at, 'uploaded_by', f.uploaded_by, 'sent_at', f.sent_at, 'sent_by', f.sent_by,
      'latest', f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = f.invoice_id and x.kind = f.kind))
      order by (f.kind = 'ky') desc, f.version desc), '[]')
    from public.out_invoice_files f where f.invoice_id = p_invoice);
end $$;
grant execute on function public.out_files_list(uuid) to authenticated;

-- Sale đánh dấu đã gửi khách bản nháp mới nhất
create or replace function public.out_file_sent(p_file uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare f public.out_invoice_files; v public.out_invoices;
begin
  select * into f from public.out_invoice_files where id = p_file;
  select * into v from public.out_invoices where id = f.invoice_id;
  if v.id is null or not (app.is_acc() or app.in_tree(v.sale_id)) then raise exception 'Không có quyền'; end if;
  if f.sent_at is not null then return; end if;
  update public.out_invoice_files set sent_at = now(), sent_by = auth.uid() where id = p_file;
  insert into public.out_events(invoice_id, action, note, data) values (v.id, 'sent', 'Đã gửi khách ' || case f.kind when 'ky' then 'HĐ đã ký' else 'bản nháp v' || f.version end, jsonb_build_object('kind', f.kind, 'version', f.version));
end $$;
grant execute on function public.out_file_sent(uuid) to authenticated;

-- ---------- Danh sách phiếu: thêm trạng thái file ----------
create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree();
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%'),
  o as (select f.*, row_number() over (order by f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

-- Sale xác nhận ký: ghi lại bản nháp khách đã OK
create or replace function public.out_confirm_sign(p_invoice uuid, p_version int) returns void
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; v_max int;
begin
  select * into v from public.out_invoices where id = p_invoice;
  if v.id is null or not (app.is_acc() or app.in_tree(v.sale_id)) then raise exception 'Không có quyền'; end if;
  select max(version) into v_max from public.out_invoice_files where invoice_id = v.id and kind = 'nhap';
  if v_max is not null and coalesce(p_version, 0) <> v_max then raise exception 'Đã có bản nháp mới v% — mở bản mới, gửi khách rồi xác nhận lại', v_max; end if;
  perform public.out_invoice_status(array[v.id], 'xac_nhan_ky', case when v_max is not null then 'Khách OK bản nháp v' || v_max end);
end $$;
grant execute on function public.out_confirm_sign(uuid, int) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0028_v21.sql
-- =====================================================================
-- 0028 · Bản 21: Xuất HĐ đầu ra theo quy trình mới (PDF MISA là nguồn trạng thái)
--  · Ghi "đã xuất file nhập MISA lúc …" thay cho bấm tay "Đã xuất nháp"; phiếu sửa lại thì tự xóa mốc này
--  · Danh sách phiếu: lọc "sửa sau nháp", "chưa xuất file MISA"
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 21');

alter table public.out_invoices add column if not exists misa_at timestamptz;
alter table public.out_invoices add column if not exists misa_by uuid references public.profiles(id);

-- Phiếu còn "Chờ xuất nháp" mà bị sửa / quay lại → file MISA đã xuất không còn đúng
create or replace function app.out_misa_reset() returns trigger language plpgsql as $$
begin
  if new.status = 'cho_nhap' and new.misa_at is not distinct from old.misa_at
     and (new.updated_at is distinct from old.updated_at or new.status is distinct from old.status) then
    new.misa_at := null; new.misa_by := null;
  end if;
  return new;
end $$;
drop trigger if exists out_misa_reset on public.out_invoices;
create trigger out_misa_reset before update on public.out_invoices for each row execute function app.out_misa_reset();

create or replace function public.out_mark_misa(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  with u as (update public.out_invoices set misa_at = now(), misa_by = auth.uid() where id = any(p_ids) and status = 'cho_nhap' returning id)
  insert into public.out_events(invoice_id, action, note) select id, 'misa', 'Đã xuất file nhập MISA' from u;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.out_mark_misa(uuid[]) to authenticated;

create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_flag text := nullif(p->>'flag', ''); v_sua int; v_misa int; v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree();
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  select count(*) filter (where i.sua_sau_nhap), count(*) filter (where i.misa_at is null) into v_sua, v_misa from public.out_invoices i
   where i.status = 'cho_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale);
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)
                               and (v_flag is null or v_flag = 'sua' and v.sua_sau_nhap or v_flag = 'misa_chua' and v.misa_at is null)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%'),
  o as (select f.*, row_number() over (order by f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

-- Thông báo: chữ theo quy trình mới, bấm vào mở thẳng phiếu
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
      perform app.notify_roles(array['ke_toan'], 'acc', case when p_status = 'xac_nhan_ky' then 'Khách OK — chờ ký: ' when v.status in ('da_nhap','xac_nhan_ky') then 'Khách yêu cầu sửa nháp: ' else 'Phiếu chờ xuất nháp: ' end || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out?inv=' || v.id);
    elsif p_status in ('da_nhap','da_ky','soan') or (p_status = 'huy' and v_acc) then
      perform app.notify(v.sale_id, 'acc', case p_status when 'da_nhap' then 'Có HĐ nháp — gửi khách: ' when 'da_ky' then 'Đã ký HĐ — báo khách kiểm tra email: '
        when 'soan' then 'Kế toán trả lại phiếu: ' else 'Kế toán hủy phiếu: ' end || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out?inv=' || v.id);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_invoice_status(uuid[], text, text, text, date) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0029_v22.sql
-- =====================================================================
-- 0029 · Bản 22: Lập phiếu nhanh theo ID đơn + kho giá xuất đối chiếu nhiều nguồn
--  · out_prices: mọi giá xuất anh / kế toán / sale đưa vào (đối soát xe, sổ HĐ, file đơn hàng, phiếu, sale nhập) theo ID đơn
--  · Mỗi dòng sổ tự chọn giá khớp nhất: đúng dòng (HĐ XML / mã hàng) > đúng SL > tên hàng giống > nguồn tin cậy hơn;
--    đơn có nhiều giá mà không phân biệt được → để trống, sale chọn trong danh sách giá của đơn (không đoán bừa)
--  · Sale nhận dòng: giá nhập chỉ gán cho đúng dòng đó (trước gán cho cả đơn)
--  · File đơn hàng nhận thêm cột Tên hàng / SL / Đơn giá xuất; file đơn vị nhận HĐ nhận thêm cột Username → gắn khách
--  · Gợi ý đơn vị nhận HĐ theo khách cho lập phiếu hàng loạt; danh sách phiếu thêm ID đơn, sắp xếp, lọc việc tiếp theo
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 22');

alter table public.out_items add column if not exists gia_src text;
alter table public.out_items add column if not exists gia_n int;

create table if not exists public.out_prices(
  id bigint generated always as identity primary key,
  md text not null, ten text, sl numeric, gia numeric not null check (gia > 0),
  src text not null check (src in ('doi_soat','so','don_hang','phieu','sale')), src_ref text, note text,
  at timestamptz not null default now(), by_user uuid default auth.uid()
);
create index if not exists out_prices_md on public.out_prices(md);
create unique index if not exists out_prices_ref on public.out_prices(src, src_ref) where src_ref is not null;
alter table public.out_prices enable row level security;
drop policy if exists out_prices_read on public.out_prices;
create policy out_prices_read on public.out_prices for select to authenticated using (app.is_acc());
grant select on public.out_prices to authenticated;

create or replace function app.out_price_put(p_md text, p_ten text, p_sl numeric, p_gia numeric, p_src text, p_ref text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_ref is not null then delete from public.out_prices where src = p_src and src_ref = p_ref; end if;
  if p_md is null or coalesce(p_gia, 0) <= 0 then return; end if;
  insert into public.out_prices(md, ten, sl, gia, src, src_ref) values (p_md, nullif(btrim(p_ten), ''), p_sl, p_gia, p_src, p_ref);
end $$;

-- Chọn giá khớp nhất cho 1 dòng sổ
create or replace function app.out_item_price(p_id uuid) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare t public.out_items; b record; n int;
begin
  select * into t from public.out_items where id = p_id;
  if t.id is null or t.md is null then return; end if;
  select count(distinct gia) into n from public.out_prices where md = t.md;
  if t.gia_src = 'sale' and t.gia_khach is not null then
    update public.out_items set gia_n = n where id = t.id and gia_n is distinct from n; return;
  end if;
  select p.gia, p.src,
         (case when (p.src = 'doi_soat' and t.acc_line_id is not null and p.src_ref = t.acc_line_id::text and t.match_src = 'hd_xml')
                 or (p.src = 'so' and p.src_ref = t.ma_hang || '#' || t.part) or (p.src in ('phieu','sale') and p.src_ref = t.id::text) then 100 else 0 end
          + case when p.sl is not null and abs(p.sl - t.sl_nhap) < 0.001 then 30 else 0 end
          + coalesce(similarity(lower(p.ten), lower(t.ten)), 0) * 50
          + case p.src when 'sale' then 8 when 'phieu' then 7 when 'doi_soat' then 6 when 'so' then 5 else 4 end) sc
    into b from public.out_prices p where p.md = t.md order by 3 desc, p.at desc limit 1;
  if b.gia is null then update public.out_items set gia_n = 0 where id = t.id and gia_n is distinct from 0; return; end if;
  if n > 1 and b.sc < 20 then
    -- đơn có nhiều giá, không biết dòng này giá nào → để sale chọn
    update public.out_items set gia_n = n, gia_khach = case when gia_src in ('phieu') then gia_khach end, gia_src = case when gia_src in ('phieu') then gia_src end where id = t.id;
    return;
  end if;
  update public.out_items set gia_khach = b.gia, gia_src = b.src, gia_n = n
   where id = t.id and (gia_khach is distinct from b.gia or gia_src is distinct from b.src or gia_n is distinct from n);
end $$;

create or replace function app.out_md_reprice(p_md text) returns void language plpgsql security definer set search_path = public, app as $$
declare t record;
begin
  if p_md is null then return; end if;
  for t in select id from public.out_items where md = p_md loop perform app.out_item_price(t.id); end loop;
end $$;

-- Đối soát xe: mỗi dòng có giá khách → 1 giá trong kho
create or replace function app.trg_acc_line_price() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'UPDATE' and old.md is distinct from new.md then perform app.out_price_put(null, null, null, null, 'doi_soat', new.id::text); perform app.out_md_reprice(old.md); end if;
  if new.is_test then return null; end if;
  perform app.out_price_put(new.md, coalesce(new.ten_ht, new.ten_apt), coalesce(new.sl_ht, new.sl_apt), coalesce(nullif(new.gia_khach, 0), new.claim_gia), 'doi_soat', new.id::text);
  perform app.out_md_reprice(new.md);
  return null;
end $$;
drop trigger if exists acc_line_price on public.acc_lines;
create trigger acc_line_price after insert or update of md, gia_khach, claim_gia, ten_ht, sl_ht on public.acc_lines for each row execute function app.trg_acc_line_price();

-- Sổ HĐ: cột Đơn giá xuất → 1 giá trong kho; đổi mã đơn → chọn lại giá
create or replace function app.trg_out_item_price() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  perform app.out_price_put(new.md, new.ten, new.sl_nhap, new.gia_so, 'so', new.ma_hang || '#' || new.part);
  if tg_op = 'UPDATE' and old.md is distinct from new.md then perform app.out_md_reprice(old.md); end if;
  perform app.out_md_reprice(new.md);
  return null;
end $$;
drop trigger if exists out_item_price on public.out_items;
create trigger out_item_price after insert or update of gia_so, md on public.out_items for each row execute function app.trg_out_item_price();

-- Phiếu: đơn giá sale chốt → 1 giá trong kho (dòng chưa có giá thì nhận luôn)
create or replace function app.trg_out_line_price() returns trigger language plpgsql security definer set search_path = public, app as $$
declare t public.out_items;
begin
  select * into t from public.out_items where id = new.item_id;
  if t.md is null or coalesce(new.don_gia, 0) <= 0 then return null; end if;
  perform app.out_price_put(t.md, t.ten, t.sl_nhap, new.don_gia, 'phieu', t.id::text);
  update public.out_items set gia_khach = new.don_gia, gia_src = 'phieu' where id = t.id and gia_khach is null;
  perform app.out_md_reprice(t.md);
  return null;
end $$;
drop trigger if exists out_line_price on public.out_invoice_lines;
create trigger out_line_price after insert or update of don_gia on public.out_invoice_lines for each row execute function app.trg_out_line_price();

-- Sale nhận dòng: giá chỉ gán cho đúng dòng sale bấm
drop function if exists public.out_item_claim(uuid, text, text, numeric);
create or replace function public.out_item_claim(p_id uuid, p_md text, p_username text default null, p_gia numeric default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; v_md text := app.out_md_norm(p_md); n int := 0; x record;
begin
  if not app.has_role('sale','tn_kd','tp_kd') and not app.is_acc() then raise exception 'Chỉ sale được nhận dòng'; end if;
  select * into t from public.out_items where id = p_id for update; if t.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if t.sale_id is not null and not app.is_acc() then raise exception 'Dòng đã có sale — báo kế toán nếu nhầm'; end if;
  if v_md is null then raise exception 'Nhập mã đơn (MD)'; end if;
  for x in select id from public.out_items where id = p_id or (md = v_md and sale_id is null) loop
    update public.out_items set md = v_md, sale_id = auth.uid(), username = coalesce(nullif(btrim(p_username), ''), username),
      match_src = 'tay', updated_at = now(), updated_by = auth.uid() where id = x.id;
    if x.id = p_id and coalesce(p_gia, 0) > 0 then
      update public.out_items set gia_khach = p_gia, gia_src = 'sale' where id = x.id;
      perform app.out_price_put(v_md, t.ten, t.sl_nhap, p_gia, 'sale', x.id::text);
    end if;
    perform app.out_item_match(x.id);
    insert into public.out_events(item_id, action, data) values (x.id, 'item_claim', jsonb_build_object('md', v_md, 'username', p_username, 'gia', case when x.id = p_id then p_gia end));
    n := n + 1;
  end loop;
  perform app.out_md_reprice(v_md);
  return n;
end $$;
grant execute on function public.out_item_claim(uuid, text, text, numeric) to authenticated;

-- Sale đặt giá xuất cho 1 dòng (chọn trong danh sách giá của đơn, hoặc gõ)
create or replace function public.out_item_set_price(p_id uuid, p_gia numeric) returns void
language plpgsql security definer set search_path = public, app as $$
declare t public.out_items;
begin
  select * into t from public.out_items where id = p_id;
  if t.id is null or not (app.is_acc() or app.in_tree(t.sale_id)) then raise exception 'Không có quyền'; end if;
  if coalesce(p_gia, 0) <= 0 then raise exception 'Giá phải > 0'; end if;
  update public.out_items set gia_khach = p_gia, gia_src = 'sale', updated_at = now(), updated_by = auth.uid() where id = p_id;
  perform app.out_price_put(t.md, t.ten, t.sl_nhap, p_gia, 'sale', t.id::text);
  perform app.out_md_reprice(t.md);
end $$;
grant execute on function public.out_item_set_price(uuid, numeric) to authenticated;

-- Các giá đã biết của đơn (để sale chọn), xếp theo độ khớp với dòng
create or replace function public.out_item_prices(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, extensions as $$
declare t public.out_items;
begin
  select * into t from public.out_items where id = p_id;
  if t.id is null or not (app.is_acc() or app.in_tree(t.sale_id) or t.sale_id is null) then raise exception 'Không có quyền'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('gia', gia, 'ten', ten, 'sl', sl, 'src', src, 'at', at) order by sc desc), '[]') from (
    select distinct on (p.gia, coalesce(p.ten, '')) p.*, coalesce(similarity(lower(p.ten), lower(t.ten)), 0) + case when p.sl is not null and abs(p.sl - t.sl_nhap) < 0.001 then 0.6 else 0 end sc
      from public.out_prices p where p.md = t.md order by p.gia, coalesce(p.ten, ''), p.at desc) z);
end $$;
grant execute on function public.out_item_prices(uuid) to authenticated;

-- File đơn hàng: thêm Tên hàng / SL / Đơn giá xuất (tùy chọn) → kho giá
create or replace function public.out_orders_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; r jsonb; t record; v_md text; v_mds text[] := '{}'; k int := 0;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  -- giá theo đơn: thay cả bộ giá của đơn trong file mới
  delete from public.out_prices where src = 'don_hang' and md in (
    select case when e->>'md' ~* 'md' then app.norm_md(e->>'md') else nullif(btrim(e->>'md'), '') end from jsonb_array_elements(p_rows) e where coalesce((e->>'gia')::numeric, 0) > 0);
  for r in select * from jsonb_array_elements(p_rows) loop
    k := k + 1;
    v_md := case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end; if v_md is null then continue; end if;
    if nullif(btrim(r->>'username'), '') is not null or nullif(btrim(r->>'nvkd'), '') is not null then
      insert into public.out_orders(md, username, nvkd) values (v_md, nullif(btrim(r->>'username'), ''), nullif(btrim(r->>'nvkd'), ''))
      on conflict (md) do update set username = coalesce(excluded.username, out_orders.username), nvkd = coalesce(excluded.nvkd, out_orders.nvkd), updated_at = now();
    end if;
    if coalesce((r->>'gia')::numeric, 0) > 0 then
      insert into public.out_prices(md, ten, sl, gia, src) values (v_md, nullif(btrim(r->>'ten'), ''), nullif(r->>'sl', '')::numeric, (r->>'gia')::numeric, 'don_hang');
    end if;
    if not v_md = any(v_mds) then v_mds := v_mds || v_md; end if;
  end loop;
  for t in select id from public.out_items where md = any(v_mds) loop
    perform app.out_item_match(t.id); perform app.out_item_price(t.id); n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_orders_import(jsonb) to authenticated;

-- File đơn vị nhận HĐ: thêm cột Username → gắn đơn vị cho đúng khách
create or replace function public.out_buyers_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n int := 0; v_id uuid; v_mst text; v_c uuid;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), ''); if v_mst is null or coalesce(btrim(r->>'name'), '') = '' then continue; end if;
    v_c := null;
    if nullif(btrim(r->>'username'), '') is not null then
      select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(btrim(r->>'username')) or upper(btrim(sys_code)) = upper(btrim(r->>'username'))) limit 1;
    end if;
    select id into v_id from public.out_buyers where customer_id is not distinct from v_c and btrim(tax_code) = v_mst limit 1;
    if v_id is null then
      insert into public.out_buyers(customer_id, name, tax_code, address, email, note) values (v_c, btrim(r->>'name'), v_mst, nullif(btrim(r->>'address'), ''), nullif(btrim(r->>'email'), ''), 'Danh sách kế toán')
      on conflict do nothing;
    else
      update public.out_buyers set name = btrim(r->>'name'), address = coalesce(nullif(btrim(r->>'address'), ''), address), email = coalesce(nullif(btrim(r->>'email'), ''), email) where id = v_id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_buyers_import(jsonb) to authenticated;

-- Gợi ý đơn vị nhận HĐ cho nhiều khách 1 lần (lập phiếu hàng loạt): phiếu gần nhất → danh sách đơn vị → hồ sơ khách
create or replace function public.out_buyer_suggest(p_customers uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare c record; out jsonb := '{}'; v jsonb;
begin
  for c in select * from public.customers where id = any(p_customers) and deleted_at is null and (app.is_acc() or app.in_tree(owner_id)) loop
    select jsonb_build_object('name', buyer_name, 'tax_code', tax_code, 'address', address, 'email', email, 'payment', payment, 'src', 'phiếu ' || code) into v
      from public.out_invoices where customer_id = c.id and status <> 'huy' and coalesce(btrim(buyer_name), '') <> '' order by created_at desc limit 1;
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

-- Danh sách dòng: sắp theo ID đơn / khách, lọc đơn nhiều giá, lọc 1 ID đơn
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
            or (v_f = 'nhieu_gia' and t.gia_n > 1 and t.gia_khach is null and t.ton > 0.0001))
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
  b as (select s.id, s.sale_id, s.md, s.customer_id, s.username, s.gia_khach, s.gia_n, s.dg_nhap, s.so_hd_vao, s.sl_nhap - coalesce(a.sl, 0) ton,
               x.xe, coalesce(c.company_name, c.contact_name) khach
          from s left join a on a.item_id = s.id left join public.out_hd_xe x on x.so_hd = ltrim(s.so_hd_vao, '0') left join public.customers c on c.id = s.customer_id),
  v as (select * from b where p_mode = 'acc' or ton > 0.0001)
  select jsonb_build_object(
    'all', count(*), 'ton', count(*) filter (where ton > 0.0001), 'het', count(*) filter (where ton <= 0.0001),
    'nosale', count(*) filter (where sale_id is null and ton > 0.0001), 'daky_nosale', count(*) filter (where sale_id is null and ton <= 0.0001),
    'nomd', count(*) filter (where md is null), 'nogia', count(*) filter (where gia_khach is null and ton > 0.0001),
    'nokhach', count(*) filter (where customer_id is null and username is null),
    'nhieu_gia', count(*) filter (where gia_n > 1 and gia_khach is null and ton > 0.0001),
    'gia_tri', coalesce(sum(ton * coalesce(gia_khach, dg_nhap, 0)) filter (where ton > 0.0001), 0),
    'hd', coalesce((select jsonb_agg(distinct so_hd_vao) from v where so_hd_vao is not null), '[]'),
    'xe', coalesce((select jsonb_agg(distinct coalesce(xe, '—')) from v), '[]'),
    'kh', coalesce((select jsonb_agg(jsonb_build_array(k, t) order by t) from (select distinct coalesce(customer_id::text, username) k, coalesce(khach, username) t from v where coalesce(customer_id::text, username) is not null) z), '[]'),
    'sale', coalesce((select jsonb_agg(distinct coalesce(sale_id::text, '—')) from v), '[]'))
  into r from v;
  return r;
end $$;
grant execute on function public.out_items_stats(text) to authenticated;

-- Danh sách phiếu: ID đơn, sắp xếp theo cột, lọc việc tiếp theo
create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_flag text := nullif(p->>'flag', ''); v_next text := nullif(p->>'next', ''); v_sort text := coalesce(nullif(p->>'sort', ''), 'at'); v_dir text := coalesce(nullif(p->>'dir', ''), 'desc'); v_sua int; v_misa int; v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree();
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  select count(*) filter (where i.sua_sau_nhap), count(*) filter (where i.misa_at is null) into v_sua, v_misa from public.out_invoices i
   where i.status = 'cho_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale);
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)
                               and (v_flag is null or v_flag = 'sua' and v.sua_sau_nhap or v_flag = 'misa_chua' and v.misa_at is null)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim,
               string_agg(distinct t.md, ', ') mds, bool_or(coalesce(l.vat, t.vat) >= 0.095) vat10
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia, a.mds, coalesce(a.vat10, false) vat10,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where (v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%')
           and (v_next is null or b.status = 'da_nhap' and fn.version is not null and (v_next = 'chua_gui' and fn.sent_at is null or v_next = 'cho_khach' and fn.sent_at is not null))),
  o as (select f.*, row_number() over (order by
          case when v_dir = 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end asc nulls last,
          case when v_dir <> 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end desc nulls last,
          case when v_sort = 'tien' and v_dir = 'asc' then f.tien_hang + f.tien_thue end asc nulls last,
          case when v_sort = 'tien' and v_dir <> 'asc' then f.tien_hang + f.tien_thue end desc nulls last,
          case when v_dir = 'asc' and v_sort = 'at' then f.status_at end asc, f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

-- Gắn đơn / sale / khách: giá giao cho kho giá
create or replace function app.out_item_match(p_id uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; al public.acc_lines; v_c uuid; v_owner uuid; v_src text; o public.out_orders; s_sale uuid; s_user text;
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
  if t.md is not null then select * into o from public.out_orders where md = t.md; end if;
  -- cùng mã đơn ở dòng khác của sổ đã biết sale / khách → dùng chung
  if t.md is not null and (t.sale_id is null or t.username is null) then
    select sale_id, username into s_sale, s_user from public.out_items where md = t.md and id <> t.id and (sale_id is not null or username is not null)
     order by (sale_id is not null) desc, (username is not null) desc limit 1;
  end if;
  t.username := coalesce(t.username, o.username, s_user);
  if t.username is not null then
    select id, owner_id into v_c, v_owner from public.customers where deleted_at is null
      and (lower(btrim(sys_username)) = lower(btrim(t.username)) or upper(btrim(sys_code)) = upper(btrim(t.username))) limit 1;
  end if;
  update public.out_items set acc_line_id = coalesce(acc_line_id, al.id),
    md = coalesce(md, al.md), username = t.username, nvkd = coalesce(nvkd, o.nvkd),
    -- giá: chỉ lấy thẳng khi khớp đúng dòng HĐ XML; còn lại để kho giá chọn (app.out_item_price)
    gia_khach = case when v_src = 'hd_xml' and gia_src is distinct from 'sale' then coalesce(nullif(al.gia_khach, 0), al.claim_gia, gia_khach) else gia_khach end,
    gia_src = case when v_src = 'hd_xml' and gia_src is distinct from 'sale' and coalesce(nullif(al.gia_khach, 0), al.claim_gia) is not null then 'doi_soat' else gia_src end,
    sale_id = coalesce(sale_id, al.sale_id, app.match_sale(t.nvkd), app.match_sale(o.nvkd), s_sale, v_owner),
    customer_id = coalesce(customer_id, al.customer_id, v_c),
    match_src = coalesce(match_src, v_src, case when t.nvkd is not null then 'nvkd' when o.md is not null then 'don_hang' when v_owner is not null then 'user' end)
  where id = p_id;
  perform app.out_item_price(p_id);
end $$;

-- Đổ kho giá từ dữ liệu đã có, rồi chọn lại giá cho mọi dòng
insert into public.out_prices(md, ten, sl, gia, src, src_ref)
select md, coalesce(ten_ht, ten_apt), coalesce(sl_ht, sl_apt), coalesce(nullif(gia_khach, 0), claim_gia), 'doi_soat', id::text
  from public.acc_lines where md is not null and not is_test and coalesce(nullif(gia_khach, 0), claim_gia) > 0
on conflict do nothing;
insert into public.out_prices(md, ten, sl, gia, src, src_ref)
select md, ten, sl_nhap, gia_so, 'so', ma_hang || '#' || part from public.out_items where md is not null and coalesce(gia_so, 0) > 0
on conflict do nothing;
insert into public.out_prices(md, ten, sl, gia, src, src_ref)
select distinct on (t.id) t.md, t.ten, t.sl_nhap, l.don_gia, 'phieu', t.id::text
  from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id join public.out_items t on t.id = l.item_id
 where i.status <> 'huy' and t.md is not null and l.don_gia > 0 order by t.id, i.created_at desc
on conflict do nothing;
update public.out_items set gia_src = 'sale' where match_src = 'tay' and gia_khach is not null and gia_src is null;
do $$ declare t record; begin for t in select id from public.out_items where md is not null loop perform app.out_item_price(t.id); end loop; end $$;

reset search_path;


-- >>>>> supabase/migrations/0030_v23.sql
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


-- >>>>> supabase/migrations/0031_v23b.sql
-- =====================================================================
-- 0031 · Bản 23b: dọn dữ liệu chạy thử Kế toán – Hóa đơn (anh xác nhận 02/11/2026 là dữ liệu test)
--  · Xóa xe đối soát, HĐ đầu vào, bảng gốc mã hàng, yêu cầu xuất HĐ, file PDF đã gắn, kho giá — bắt đầu sạch với bản 23
--  · GIỮ: pháp nhân nhận HĐ (out_buyers), file đơn hàng (out_orders), khách hàng
--  · Pháp nhân nhận HĐ gắn khách theo USERNAME (lưu lại username để tự gắn khi khách vào ERP sau); mỗi khách 1 pháp nhân mặc định
--  · File PDF trên Google Drive KHÔNG bị xóa — chỉ bỏ liên kết trong ERP
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi dọn dữ liệu test Kế toán – Hóa đơn (bản 23b)');

-- ---------- Dọn dữ liệu test ----------
delete from public.out_invoice_files;
delete from public.out_invoice_lines;
delete from public.out_events;
delete from public.out_invoices;
delete from public.out_prices;
delete from public.out_items;
delete from public.out_hd_xe;
delete from public.acc_invoice_lines;
delete from public.acc_invoices;
delete from public.acc_events;
delete from public.acc_lines;
delete from public.acc_trucks;
delete from app.drive_tickets where file_id is not null;
alter sequence public.out_invoice_seq restart with 1;

-- ---------- Pháp nhân nhận HĐ theo username khách ----------
alter table public.out_buyers add column if not exists username text;
create index if not exists out_buyers_username on public.out_buyers(lower(btrim(username))) where username is not null;

-- Gắn pháp nhân chưa có khách vào khách ERP theo username / mã hệ thống; khách chưa có mặc định → pháp nhân mới nhất làm mặc định
create or replace function app.out_buyers_relink() returns int language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  update public.out_buyers b set customer_id = c.id
    from public.customers c
   where b.customer_id is null and b.username is not null and c.deleted_at is null
     and (lower(btrim(c.sys_username)) = lower(btrim(b.username)) or upper(btrim(c.sys_code)) = upper(btrim(b.username)))
     and not exists(select 1 from public.out_buyers x where x.customer_id = c.id and lower(btrim(x.name)) = lower(btrim(b.name)) and coalesce(btrim(x.tax_code), '') = coalesce(btrim(b.tax_code), ''));
  get diagnostics n = row_count;
  update public.out_buyers b set is_default = true
   where b.id in (select distinct on (customer_id) id from public.out_buyers where customer_id is not null order by customer_id, created_at desc)
     and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default);
  return n;
end $$;

create or replace function public.out_buyers_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n int := 0; v_id uuid; v_mst text; v_c uuid; v_user text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), ''); if v_mst is null or coalesce(btrim(r->>'name'), '') = '' then continue; end if;
    v_c := null; v_user := nullif(btrim(r->>'username'), '');
    if v_user is not null then
      select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(v_user) or upper(btrim(sys_code)) = upper(v_user)) limit 1;
    end if;
    select id into v_id from public.out_buyers where customer_id is not distinct from v_c and btrim(tax_code) = v_mst
       and (v_c is not null or lower(btrim(coalesce(username, ''))) = lower(coalesce(v_user, ''))) limit 1;
    if v_id is null then
      insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note)
      values (v_c, v_user, btrim(r->>'name'), v_mst, nullif(btrim(r->>'address'), ''), nullif(btrim(r->>'email'), ''), 'Danh sách kế toán')
      on conflict do nothing;
    else
      update public.out_buyers set name = btrim(r->>'name'), username = coalesce(v_user, username), address = coalesce(nullif(btrim(r->>'address'), ''), address),
        email = coalesce(nullif(btrim(r->>'email'), ''), email) where id = v_id;
    end if;
    n := n + 1;
  end loop;
  perform app.out_buyers_relink();
  return n;
end $$;
grant execute on function public.out_buyers_import(jsonb) to authenticated;

-- Nạp bảng gốc HĐ đầu vào xong → gắn lại pháp nhân theo username khách vừa xác định
create or replace function app.trg_out_item_buyer() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if new.customer_id is not null and (tg_op = 'INSERT' or old.customer_id is distinct from new.customer_id) then
    update public.out_buyers set customer_id = new.customer_id
     where customer_id is null and username is not null
       and lower(btrim(username)) in (select lower(btrim(x)) from public.customers c, unnest(array[c.sys_username, c.sys_code]) x where c.id = new.customer_id and x is not null);
    update public.out_buyers b set is_default = true
     where b.id = (select id from public.out_buyers where customer_id = new.customer_id order by created_at desc limit 1)
       and not exists(select 1 from public.out_buyers x where x.customer_id = new.customer_id and x.is_default);
  end if;
  return new;
end $$;
drop trigger if exists out_item_buyer on public.out_items;
create trigger out_item_buyer after insert or update of customer_id on public.out_items for each row execute function app.trg_out_item_buyer();

select app.out_buyers_relink();

reset search_path;


-- >>>>> supabase/migrations/0032_v25.sql
-- =====================================================================
-- 0032 · Bản 25: nạp HĐ chính thức APT — kết quả đối chiếu xem trước (tên + SL → dòng nháp của xe) được lưu đúng như đã xem
--  · Mỗi dòng gửi kèm acc_line_id (dòng nháp đã ghép) → bảng gốc nhận mã khai báo, đơn, khách, sale, giá khách từ dòng đó
--  · Đổi dòng nháp khi nạp lại → xóa mã khai báo / đơn / sale cũ rồi ghép lại; dòng đã sửa tay (match_src = 'tay') giữ nguyên
--  · Không gửi acc_line_id (file cũ) → hệ thống tự ghép như bản 23
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 25');

create or replace function public.out_items_import(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_id uuid; n_new int := 0; n_upd int := 0; v_ids uuid[] := '{}'; v_line uuid; t public.out_items;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select * into t from public.out_items where ma_hang = r->>'ma_hang' and part = coalesce((r->>'part')::int, 1);
    v_id := t.id;
    if v_id is null then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
    v_line := nullif(r->>'acc_line_id', '')::uuid;
    if v_line is not null and not exists(select 1 from public.acc_lines where id = v_line) then v_line := null; end if;
    insert into public.out_items as x(ma_hang, part, stt_so, ten, dvt, vat, sl_nhap, dg_nhap, so_hd_vao, ky_hieu, ngay_vao, ncc, stt_hd, md, nvkd, username, gia_so, legacy, updated_at, updated_by)
    values (r->>'ma_hang', coalesce((r->>'part')::int, 1), (r->>'stt_so')::numeric, r->>'ten', r->>'dvt', (r->>'vat')::numeric, coalesce((r->>'sl_nhap')::numeric, 0), (r->>'dg_nhap')::numeric,
            r->>'so_hd_vao', r->>'ky_hieu', nullif(r->>'ngay_vao','')::date, r->>'ncc', (r->>'stt_hd')::int,
            case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end, nullif(btrim(r->>'nvkd'), ''), nullif(btrim(r->>'username'), ''),
            nullif((r->>'gia_so')::numeric, 0), r->'legacy', now(), auth.uid())
    on conflict (ma_hang, part) do update set stt_so = excluded.stt_so, ten = excluded.ten, dvt = excluded.dvt, vat = excluded.vat, sl_nhap = excluded.sl_nhap, dg_nhap = excluded.dg_nhap,
      so_hd_vao = excluded.so_hd_vao, ky_hieu = excluded.ky_hieu, ngay_vao = excluded.ngay_vao, ncc = excluded.ncc, stt_hd = excluded.stt_hd,
      md = case when coalesce(x.match_src, '') = 'tay' then x.md else coalesce(excluded.md, x.md) end, nvkd = coalesce(excluded.nvkd, x.nvkd),
      username = case when coalesce(x.match_src, '') = 'tay' then x.username else coalesce(excluded.username, x.username) end,
      sale_id = case when coalesce(x.match_src, '') <> 'tay' and excluded.nvkd is not null and app.match_sale(excluded.nvkd) is not null then app.match_sale(excluded.nvkd) else x.sale_id end,
      gia_so = coalesce(excluded.gia_so, x.gia_so), legacy = excluded.legacy, updated_at = now(), updated_by = auth.uid()
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
    perform app.out_item_match(v_id); v_ids := v_ids || v_id;
  end loop;
  for v_id in select id from public.out_items where id = any(v_ids) and md is not null and (sale_id is null or username is null) loop perform app.out_item_match(v_id); end loop;
  insert into public.out_events(action, data) values ('import', jsonb_build_object('new', n_new, 'upd', n_upd));
  return jsonb_build_object('new', n_new, 'upd', n_upd);
end $$;
grant execute on function public.out_items_import(jsonb) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0033_v26.sql
-- =====================================================================
-- 0033 · Bản 26: siết quyền theo yêu cầu 03/11/2026
--  · Nhân sự & phân quyền (tạo tài khoản, lời mời): chỉ Admin + Ban giám đốc (bỏ HCNS)
--  · Ủy quyền duyệt đơn: chỉ người có quyền duyệt (quản lý có cấp dưới, TN/TP KD, HCNS, Admin/BGĐ) mới tạo được.
--    Nhân viên thường vào "Duyệt đơn" chỉ xem — không duyệt (decide_request đã chặn sẵn), không ủy quyền, không tạo đơn hộ (lv_ins đã chặn sẵn).
-- Giao diện: chặn gõ thẳng URL #/admin/users, #/admin/data với người không phải Admin/BGĐ.
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 26');

-- 1) Tạo tài khoản / lời mời: chỉ Admin + BGĐ
create or replace function public.invite_user(p_email text, p_full_name text, p_roles text[], p_job_level text,
  p_manager uuid, p_org uuid, p_schedule text default 'office', p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_admin() then raise exception 'Chỉ Admin / Ban giám đốc được tạo tài khoản nhân sự'; end if;
  insert into public.invites(email, full_name, roles, job_level, manager_id, org_unit_id, work_schedule, employee_code, created_by)
  values (lower(trim(p_email)), p_full_name, p_roles, p_job_level, p_manager, p_org, p_schedule, nullif(p_code,''), auth.uid())
  on conflict (email) do update set full_name = excluded.full_name, roles = excluded.roles, job_level = excluded.job_level,
     manager_id = excluded.manager_id, org_unit_id = excluded.org_unit_id, work_schedule = excluded.work_schedule,
     employee_code = excluded.employee_code;
  perform app.log('INVITE', 'invites', lower(p_email), jsonb_build_object('roles', p_roles));
end $$;

drop policy if exists inv_all on public.invites;
create policy inv_all on public.invites for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- 2) Ủy quyền duyệt: chỉ người có quyền duyệt
drop policy if exists del_ins on public.delegations;
create policy del_ins on public.delegations for insert to authenticated with check (
  app.is_admin() or (
    delegator_id = auth.uid() and (
      app.has_role('hcns','tn_kd','tp_kd')
      or exists (select 1 from public.profiles c where c.manager_id = auth.uid() and c.status = 'active')
    )
  )
);


-- >>>>> supabase/migrations/0034_v27.sql
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


-- >>>>> supabase/migrations/0035_v28.sql
-- =====================================================================
-- 0035 · Bản 28 (04/11/2026)
--  1. Vai trò CSKH hỗ trợ sale: phân công chính / dự phòng; xem + thao tác dữ liệu kinh doanh của sale được giao,
--     KHÔNG có quyền duyệt (duyệt vẫn chỉ theo cây quản lý), không thấy dữ liệu nhân sự / lương của sale
--  2. Sale / CSKH sửa giá khách cả ở dòng đã tự chốt (biên ngoài khung có giá đề xuất), khi HĐ ký chưa về
--  3. Username khách là số điện thoại: chuẩn hóa (thêm số 0 đầu, bỏ dấu ' và khoảng trắng); tự gắn khách khi hồ sơ khách có username
--  4. Thông báo: đường dẫn cũ #/out chuyển về màn hình mới; sao thông báo của sale cho CSKH phụ trách; đẩy thông báo ra điện thoại (web push)
--  5. Phép năm: cộng dồn mỗi tháng (được hưởng năm ÷ 12) thay vì cấp đủ từ đầu năm
--  6. Bảng công: cột lương tạm tính theo công đến hôm nay
--  7. Duyệt đơn quên chấm công: người duyệt nhập giờ vào / giờ ra thực tế → tính đi muộn, chuyên cần
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 28');

-- =============== 1. CSKH ===============
alter table public.profiles drop constraint if exists roles_valid;
alter table public.profiles add constraint roles_valid check (roles <@ array['admin','bgd','hcns','ke_toan','tp_kd','tn_kd','sale','cskh','nhan_vien']::text[]);

create table if not exists public.support_assignments(
  id uuid primary key default gen_random_uuid(),
  cskh_id uuid not null references public.profiles(id),
  sale_id uuid not null references public.profiles(id),
  kind text not null default 'chinh' check (kind in ('chinh','du_phong')),
  started_at date not null default app.vn_today(),
  ended_at date,
  created_by uuid default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  check (cskh_id <> sale_id)
);
create unique index if not exists support_one_active on public.support_assignments(sale_id, kind) where ended_at is null;
create index if not exists support_by_cskh on public.support_assignments(cskh_id) where ended_at is null;
alter table public.support_assignments enable row level security;
revoke all on public.support_assignments from anon;
grant select on public.support_assignments to authenticated;

-- Cây quản lý (dùng cho NHÂN SỰ: công, phép, lương, KPI và mọi quyền DUYỆT) — nhớ trong 1 lượt gọi
create or replace function app.in_mgmt(p_id uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare k text := coalesce(auth.uid()::text, '-'); c text := current_setting('nt.tree', true); t uuid[];
begin
  if p_id is null then return false; end if;
  if c is not null and c <> '' and split_part(c, '|', 1) = k then t := split_part(c, '|', 2)::uuid[];
  else t := app.my_tree(); perform set_config('nt.tree', k || '|' || t::text, true); end if;
  return p_id = any(t);
end $$;

-- Sale đang được CSKH (người gọi) hỗ trợ
create or replace function app.my_support() returns uuid[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(distinct s.sale_id), '{}') from public.support_assignments s
   where s.cskh_id = auth.uid() and s.ended_at is null and s.started_at <= app.vn_today()
     and exists(select 1 from public.profiles p where p.id = auth.uid() and p.status = 'active' and 'cskh' = any(p.roles))
$$;
create or replace function app.is_support_of(p_sale uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_sale is not null and p_sale = any(app.my_support())
$$;
create or replace function app.is_cskh() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.has_role('cskh') $$;

-- Phạm vi DỮ LIỆU KINH DOANH (khách, chăm sóc, báo giá, đối soát xe, hóa đơn) = cây quản lý + sale được giao hỗ trợ
create or replace function app.my_scope() returns uuid[]
language sql stable security definer set search_path = public, app as $$
  select array(select distinct x from unnest(app.my_tree() || app.my_support()) x)
$$;
create or replace function app.in_tree(p_id uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare k text := coalesce(auth.uid()::text, '-'); c text := current_setting('nt.scope', true); t uuid[];
begin
  if p_id is null then return false; end if;
  if c is not null and c <> '' and split_part(c, '|', 1) = k then t := split_part(c, '|', 2)::uuid[];
  else t := app.my_scope(); perform set_config('nt.scope', k || '|' || t::text, true); end if;
  return p_id = any(t);
end $$;

-- CSKH được hỗ trợ / phụ trách cho 1 sale hôm nay: CSKH chính; chính nghỉ phép cả ngày hoặc không còn làm → dự phòng
create or replace function app.cskh_for(p_sale uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select s.cskh_id from public.support_assignments s join public.profiles p on p.id = s.cskh_id and p.status = 'active'
   where s.sale_id = p_sale and s.ended_at is null and s.started_at <= app.vn_today()
     and not (s.kind = 'chinh' and exists(select 1 from public.leave_requests l where l.profile_id = s.cskh_id and l.status = 'da_duyet'
                and app.vn_today() between l.start_date and l.end_date and l.part = 'full'))
   order by (s.kind = 'chinh') desc limit 1
$$;

drop policy if exists sa_read on public.support_assignments;
create policy sa_read on public.support_assignments for select to authenticated
  using (app.has_role('admin','bgd','hcns') or cskh_id = auth.uid() or sale_id = auth.uid() or app.in_mgmt(sale_id) or app.in_mgmt(cskh_id));

-- Admin / BGĐ phân công: thay toàn bộ danh sách sale của 1 CSKH (chính + dự phòng); phân công cũ được đóng lại, giữ lịch sử
create or replace function public.support_assign_save(p_cskh uuid, p_main uuid[], p_backup uuid[]) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_main uuid[] := coalesce(p_main, '{}'); v_bk uuid[] := coalesce(p_backup, '{}'); x uuid; n_new int := 0; n_end int := 0; t date := app.vn_today(); taken text;
begin
  if not app.is_admin() then raise exception 'Chỉ Admin / Ban giám đốc phân công CSKH'; end if;
  if not exists(select 1 from public.profiles where id = p_cskh and 'cskh' = any(roles)) then raise exception 'Nhân sự này chưa có vai trò CSKH'; end if;
  if p_cskh = any(v_main || v_bk) then raise exception 'CSKH không tự hỗ trợ chính mình'; end if;
  if exists(select 1 from unnest(v_main) m where m = any(v_bk)) then raise exception 'Một sale không vừa là hỗ trợ chính vừa dự phòng của cùng 1 CSKH'; end if;
  -- sale đã có CSKH chính / dự phòng khác
  select string_agg(app.name_of(s.sale_id) || ' (' || case s.kind when 'chinh' then 'chính' else 'dự phòng' end || ': ' || app.name_of(s.cskh_id) || ')', ', ') into taken
    from public.support_assignments s where s.ended_at is null and s.cskh_id <> p_cskh
     and ((s.kind = 'chinh' and s.sale_id = any(v_main)) or (s.kind = 'du_phong' and s.sale_id = any(v_bk)));
  if taken is not null then raise exception 'Sale đã có CSKH khác: % — bỏ phân công cũ trước', taken; end if;
  update public.support_assignments set ended_at = t - 1 where cskh_id = p_cskh and ended_at is null
     and not ((kind = 'chinh' and sale_id = any(v_main)) or (kind = 'du_phong' and sale_id = any(v_bk)));
  get diagnostics n_end = row_count;
  -- phân công mở và đóng trong cùng ngày → ended_at < started_at: xóa hẳn cho gọn
  delete from public.support_assignments where cskh_id = p_cskh and ended_at is not null and ended_at < started_at;
  foreach x in array v_main loop
    if not exists(select 1 from public.support_assignments where cskh_id = p_cskh and sale_id = x and kind = 'chinh' and ended_at is null) then
      insert into public.support_assignments(cskh_id, sale_id, kind) values (p_cskh, x, 'chinh'); n_new := n_new + 1; end if;
  end loop;
  foreach x in array v_bk loop
    if not exists(select 1 from public.support_assignments where cskh_id = p_cskh and sale_id = x and kind = 'du_phong' and ended_at is null) then
      insert into public.support_assignments(cskh_id, sale_id, kind) values (p_cskh, x, 'du_phong'); n_new := n_new + 1; end if;
  end loop;
  perform app.log('SUPPORT_ASSIGN', 'support_assignments', p_cskh::text, jsonb_build_object('chinh', v_main, 'du_phong', v_bk));
  return jsonb_build_object('them', n_new, 'dong', n_end);
end $$;
revoke all on function public.support_assign_save(uuid, uuid[], uuid[]) from public, anon;
grant execute on function public.support_assign_save(uuid, uuid[], uuid[]) to authenticated;

-- Danh sách phân công đang hiệu lực (màn hình Nhân sự & phân quyền, Hôm nay của CSKH)
create or replace function public.support_list() returns table(id uuid, cskh_id uuid, sale_id uuid, kind text, started_at date)
language sql stable security definer set search_path = public, app as $$
  select s.id, s.cskh_id, s.sale_id, s.kind, s.started_at from public.support_assignments s
   where s.ended_at is null and (app.has_role('admin','bgd','hcns') or s.cskh_id = auth.uid() or s.sale_id = auth.uid() or app.in_mgmt(s.sale_id))
   order by s.cskh_id, s.kind, s.sale_id
$$;
grant execute on function public.support_list() to authenticated;

-- Dữ liệu NHÂN SỰ của sale: CSKH không thấy (đổi in_tree → in_mgmt)
drop policy if exists att_read on public.attendance_events;
create policy att_read on public.attendance_events for select to authenticated using (profile_id = auth.uid() or app.in_mgmt(profile_id) or app.has_role('admin','bgd','hcns','ke_toan'));
drop policy if exists attr_read on public.attendance_requests;
create policy attr_read on public.attendance_requests for select to authenticated using (profile_id = auth.uid() or app.in_mgmt(profile_id) or app.has_role('admin','bgd','hcns','ke_toan'));
drop policy if exists lv_read on public.leave_requests;
create policy lv_read on public.leave_requests for select to authenticated using (profile_id = auth.uid() or app.in_mgmt(profile_id) or app.has_role('admin','bgd','hcns','ke_toan'));
drop policy if exists ll_read on public.leave_ledger;
create policy ll_read on public.leave_ledger for select to authenticated using (profile_id = auth.uid() or app.in_mgmt(profile_id) or app.can_see_hr());
drop policy if exists le_read on public.leave_entitlements;
create policy le_read on public.leave_entitlements for select to authenticated using (profile_id = auth.uid() or app.in_mgmt(profile_id) or app.can_see_hr());
drop policy if exists or_read on public.order_results;
create policy or_read on public.order_results for select to authenticated
  using (app.can_see_hr() or app.in_mgmt(profile_id) or cskh_id = auth.uid() or buyer_id = auth.uid());
drop policy if exists ks_read on public.kpi_snapshots;
create policy ks_read on public.kpi_snapshots for select to authenticated using (app.in_mgmt(profile_id) or app.can_see_hr());

-- Danh sách sale để lọc (Hóa đơn của tôi …): CSKH thấy thêm sale được giao
create or replace function public.out_sale_opts() returns table(id uuid, full_name text)
language sql stable security definer set search_path = public, app as $$
  select p.id, p.full_name from public.profiles p
   where p.status = 'active' and p.roles && array['sale','tn_kd','tp_kd']
     and (app.is_acc() or p.id = any(app.my_scope()))
   order by p.full_name
$$;
grant execute on function public.out_sale_opts() to authenticated;

-- Khách hàng: CSKH không được xóa khách của sale
create or replace function app.customers_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_dup record; v_lock record;
begin
  new.phone_norm := app.norm_phone(new.phone);
  new.zalo_norm := app.norm_phone(new.zalo);
  new.tax_code := app.norm_tax(new.tax_code);
  if new.zalo_norm is not null and new.zalo_norm !~ '^0[0-9]{9,10}$' then new.zalo_norm := null; end if;
  if tg_op = 'INSERT' or (new.phone_norm, new.zalo_norm, new.tax_code) is distinct from (old.phone_norm, old.zalo_norm, old.tax_code) then
    select * into v_lock from app.company_lock(new.phone_norm, new.zalo_norm, new.tax_code);
    if v_lock.status = 'active' then
      raise exception 'KHÁCH ĐANG CHẠY CỦA CÔNG TY (%: phụ trách %). Không được tạo hồ sơ.', v_lock.name, coalesce(v_lock.owner_text,'?');
    end if;
    if tg_op = 'INSERT' and v_lock.status = 'sleep' then new.source := 'kho_khach_ngu'; end if;
    select cu.code, cu.owner_id, cu.ownership into v_dup from public.customers cu
     where cu.deleted_at is null and cu.id <> new.id
       and ((new.phone_norm is not null and new.phone_norm in (cu.phone_norm, cu.zalo_norm))
         or (new.zalo_norm is not null and new.zalo_norm in (cu.phone_norm, cu.zalo_norm))
         or (new.tax_code is not null and new.tax_code = cu.tax_code))
     limit 1;
    if v_dup.code is not null then
      if v_dup.ownership = 'owned' then
        raise exception 'TRÙNG KHÁCH: % đã có chủ (%). Không được tiếp cận.', v_dup.code, app.name_of(v_dup.owner_id);
      else
        raise exception 'TRÙNG KHÁCH: % đang được % theo (sân chung). Báo Trưởng nhóm thống nhất 1 đầu mối.', v_dup.code, app.name_of(v_dup.owner_id);
      end if;
    end if;
  end if;
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    -- Bản 28: CSKH chỉ hỗ trợ — không xóa khách của sale
    if old.deleted_at is null and new.deleted_at is not null and auth.uid() is not null and not app.is_admin()
       and not app.in_mgmt(old.owner_id) and app.is_support_of(old.owner_id) then
      raise exception 'CSKH không được xóa khách của sale';
    end if;
    if new.owner_id is distinct from old.owner_id and coalesce(current_setting('app.transfer', true), '') <> '1' and auth.uid() is not null then
      raise exception 'Đổi người phụ trách phải dùng chức năng Chuyển khách';
    end if;
    if (new.ownership, new.owned_at, new.order_count, new.quote_count, new.care_count, new.first_order_code)
       is distinct from (old.ownership, old.owned_at, old.order_count, old.quote_count, old.care_count, old.first_order_code)
       and coalesce(current_setting('app.system', true), '') <> '1' and auth.uid() is not null then
      raise exception 'Các trường hệ thống tự đếm không sửa tay được';
    end if;
  else
    if auth.uid() is not null and new.owner_id <> auth.uid() and not app.can_approve(new.owner_id) then
      new.owner_id := auth.uid();
    end if;
  end if;
  return new;
end $$;

-- Báo giá: CSKH lập cho khách của sale → báo giá đứng tên sale chủ khách (doanh số, KPI về sale)
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
  insert into public.quotation_lines(quotation_id, line_no, name, spec, hs_code, unit, qty, unit_price_cny, duty_pct, vat_pct, freight_pct, manual_price, computed)
  select v_id, ord, l->>'name', l->>'spec', l->>'hs_code', l->>'unit', (l->>'qty')::numeric, coalesce((l->>'unit_price_cny')::numeric,0),
         coalesce((l->>'duty_pct')::numeric,0), (l->>'vat_pct')::numeric, (l->>'freight_pct')::numeric, (l->>'manual_price')::numeric, coalesce(l->'computed','{}')
  from jsonb_array_elements(p_lines) with ordinality t(l, ord)
  where coalesce(btrim(l->>'name'),'') <> '' and coalesce((l->>'qty')::numeric, 0) > 0;
  return v_id;
end $$;

create or replace function public.quote_submit(p_id uuid)
returns text language plpgsql security definer set search_path = public, app as $$
declare q record; c record; v_days int;
begin
  select * into q from public.quotations where id = p_id for update;
  if q.id is null or not (q.sale_id = auth.uid() or app.is_admin() or app.is_support_of(q.sale_id)) then raise exception 'Không có quyền'; end if;
  if q.status <> 'nhap' then raise exception 'Chỉ gửi được báo giá ở trạng thái Nháp'; end if;
  perform app.assert_customer_open(q.customer_id);
  if cardinality(q.violations) > 0 and q.approved_hash is distinct from q.price_hash then
    update public.quotations set status = 'cho_duyet', updated_at = now() where id = p_id;
    perform app.notify(x, 'quote', 'Duyệt giá ' || q.code || ' v' || q.version, array_to_string(q.violations, '; '), '#/crm/quote?id=' || q.id)
      from app.quote_approvers(q.sale_id) x;
    perform app.telegram('quote_approval', '🟠 <b>Chờ duyệt giá</b> ' || q.code || ' v' || q.version || E'\nSale: ' || app.esc(app.name_of(q.sale_id))
      || E'\nVi phạm: ' || app.esc(array_to_string(q.violations, '; ')) || E'\nTổng sau VAT: ' || to_char(q.total_after_vat, 'FM999G999G999G999') || 'đ');
    return 'cho_duyet';
  end if;
  v_days := coalesce(app.setting_num('crm','quote_valid_days'), 5)::int;
  update public.quotations set status = 'da_gui', sent_at = now(), valid_until = app.vn_today() + v_days, updated_at = now() where id = p_id;
  select * into c from public.customers where id = q.customer_id;
  perform set_config('app.system', '1', true);
  update public.customers set quote_count = quote_count + 1,
    stage = case when app.stage_order(stage) < app.stage_order('da_bao_gia') then 'da_bao_gia' else stage end,
    next_care_date = app.suggest_next_care(case when app.stage_order(stage) < app.stage_order('da_bao_gia') then 'da_bao_gia' else stage end, temperature)
  where id = q.customer_id;
  perform set_config('app.system', '', true);
  return 'da_gui';
end $$;

create or replace function public.quote_set_status(p_id uuid, p_status text, p_order_code text default null, p_reason text default null, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare q record; c record; v_first boolean;
begin
  select * into q from public.quotations where id = p_id for update;
  if q.id is null or not (q.sale_id = auth.uid() or app.is_admin() or app.is_support_of(q.sale_id)) then raise exception 'Không có quyền'; end if;
  if q.status not in ('da_gui','can_nhac') then raise exception 'Chỉ cập nhật kết quả cho báo giá đã gửi'; end if;
  if p_status = 'can_nhac' then
    update public.quotations set status = 'can_nhac', updated_at = now() where id = p_id;
  elsif p_status = 'da_chot' then
    if coalesce(btrim(p_order_code),'') = '' then raise exception 'Chốt đơn bắt buộc nhập Mã đơn'; end if;
    update public.quotations set status = 'da_chot', order_code = upper(btrim(p_order_code)), won_at = now(), updated_at = now() where id = p_id;
    select * into c from public.customers where id = q.customer_id for update;
    v_first := c.order_count = 0;
    perform set_config('app.system', '1', true);
    update public.customers set
      order_count = order_count + 1,
      first_order_code = coalesce(first_order_code, upper(btrim(p_order_code))),
      first_order_at = coalesce(first_order_at, now()),
      last_order_at = now(),
      ownership = 'owned',
      owned_at = coalesce(owned_at, now()),
      stage = case when v_first then 'don_dau' when stage = 'vip' then 'vip' else 'hoat_dong' end,
      temperature = 'nong',
      next_care_date = app.suggest_next_care(case when v_first then 'don_dau' when stage='vip' then 'vip' else 'hoat_dong' end, 'nong')
    where id = q.customer_id;
    perform set_config('app.system', '', true);
    perform app.telegram('quote_won', '🟢 <b>Chốt đơn</b> ' || app.esc(upper(p_order_code)) || ' · ' || q.code
      || E'\nKhách: ' || app.esc(coalesce(c.company_name, c.contact_name)) || case when v_first then ' (đơn đầu – xác lập chủ khách)' else '' end
      || E'\nSale: ' || app.esc(app.name_of(q.sale_id)) || E'\nGiá trị: ' || to_char(q.total_after_vat, 'FM999G999G999G999') || 'đ · LN ước tính ' || to_char(q.est_profit, 'FM999G999G999G999') || 'đ');
  elsif p_status = 'tu_choi' then
    if coalesce(btrim(p_reason),'') = '' then raise exception 'Bắt buộc lý do từ chối'; end if;
    update public.quotations set status = 'tu_choi', reject_reason = p_reason, reject_note = p_note, updated_at = now() where id = p_id;
  else
    raise exception 'Trạng thái không hợp lệ';
  end if;
end $$;

alter table public.quotations add column if not exists created_by uuid default auth.uid() references public.profiles(id);


-- =============== 2. Sửa giá khách cả ở dòng đã tự chốt ===============
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
  -- Bản 28: dòng đã tự chốt (biên ngoài khung có giá đề xuất) vẫn được sửa giá khách / xác nhận đã gửi APT khi HĐ ký chưa về
  if not (l.status in ('blocked','replied') or (l.status = 'ok' and p_reply in ('sua_gia_khach','da_gui_gia') and l.inv_no is null)) then
    raise exception 'Dòng không ở trạng thái chờ sale'; end if;
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


-- =============== 3. Username khách là số điện thoại ===============
-- '906099063 / 906099063 / +84906099063 / 84906099063 → 0906099063 ; username chữ giữ nguyên (chỉ bỏ dấu ' đầu và khoảng trắng)
create or replace function app.norm_username(p text) returns text language sql immutable as $$
  select case when x is null then null
              when x ~ '^\+?84[35789][0-9]{8}$' then '0' || right(x, 9)
              when x ~ '^[35789][0-9]{8}$' then '0' || x
              when x ~ '^2[0-9]{9}$' then '0' || x
              else x end
  from (select nullif(regexp_replace(regexp_replace(coalesce(p, ''), '[[:space:]]+', '', 'g'), '^[''`"‘’]+', ''), '') x) s
$$;

create or replace function app.trg_norm_username() returns trigger language plpgsql as $$
begin
  if tg_table_name = 'customers' then new.sys_username := app.norm_username(new.sys_username);
  elsif tg_table_name = 'acc_lines' then new.ma_kh := app.norm_username(new.ma_kh);
  else new.username := app.norm_username(new.username); end if;
  return new;
end $$;
drop trigger if exists norm_username on public.customers;
create trigger norm_username before insert or update of sys_username on public.customers for each row execute function app.trg_norm_username();
drop trigger if exists norm_username on public.out_items;
create trigger norm_username before insert or update of username on public.out_items for each row execute function app.trg_norm_username();
drop trigger if exists norm_username on public.out_buyers;
create trigger norm_username before insert or update of username on public.out_buyers for each row execute function app.trg_norm_username();
drop trigger if exists norm_username on public.out_orders;
create trigger norm_username before insert or update of username on public.out_orders for each row execute function app.trg_norm_username();
drop trigger if exists norm_username on public.acc_lines;
create trigger norm_username before insert or update of ma_kh on public.acc_lines for each row execute function app.trg_norm_username();

-- Hồ sơ khách có / đổi username → gắn ngay dòng HĐ và pháp nhân đang chờ username đó (không phải bấm "Gắn lại")
create or replace function app.trg_customer_relink() returns trigger language plpgsql security definer set search_path = public, app as $$
declare r record;
begin
  if new.deleted_at is not null or (new.sys_username is null and new.sys_code is null) then return null; end if;
  for r in select t.id from public.out_items t where t.customer_id is null and t.username is not null
             and (lower(t.username) = lower(new.sys_username) or upper(t.username) = upper(new.sys_code)) loop
    perform app.out_item_match(r.id);
  end loop;
  perform app.out_buyers_relink();
  return null;
end $$;
drop trigger if exists customer_relink on public.customers;
create trigger customer_relink after insert or update of sys_username, sys_code, deleted_at on public.customers for each row execute function app.trg_customer_relink();


-- =============== 4. Thông báo ===============
alter table public.notifications add column if not exists copy_of bigint;
alter table public.notifications add column if not exists pushed_at timestamptz;

-- Đường dẫn cũ #/out (đã ẩn) → màn hình mới: kế toán/BGĐ → Bàn làm việc kế toán, còn lại → Hóa đơn của tôi (giữ ?inv=)
create or replace function app.trg_notif_before() returns trigger language plpgsql security definer set search_path = public, app as $$
declare acc boolean;
begin
  if new.link like '#/out%' then
    select roles && array['ke_toan','admin','bgd'] into acc from public.profiles where id = new.recipient_id;
    new.link := case when coalesce(acc, false) then '#/hd/kt' else '#/hd' end || coalesce(substring(new.link from '\?.*$'), '');
  end if;
  return new;
end $$;
drop trigger if exists notif_before on public.notifications;
create trigger notif_before before insert on public.notifications for each row execute function app.trg_notif_before();
update public.notifications set link = case when exists(select 1 from public.profiles p where p.id = recipient_id and p.roles && array['ke_toan','admin','bgd'])
  then '#/hd/kt' else '#/hd' end || coalesce(substring(link from '\?.*$'), '') where link like '#/out%';

-- Sao thông báo việc của sale (đối soát xe, hóa đơn, báo giá) cho CSKH đang hỗ trợ sale đó; đẩy ra điện thoại
create table if not exists app.push_cfg(id int primary key default 1 check (id = 1), public_key text not null, private_key text not null, created_at timestamptz default now());
create table if not exists public.push_subs(
  endpoint text primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  p256dh text not null, auth text not null, ua text,
  created_at timestamptz not null default now(), last_ok timestamptz, fails int not null default 0
);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon;
grant select, delete on public.push_subs to authenticated;
drop policy if exists ps_own on public.push_subs;
create policy ps_own on public.push_subs for select to authenticated using (profile_id = auth.uid());
drop policy if exists ps_del on public.push_subs;
create policy ps_del on public.push_subs for delete to authenticated using (profile_id = auth.uid());

create or replace function public.push_public_key() returns text language sql stable security definer set search_path = public, app as $$
  select public_key from app.push_cfg where id = 1
$$;
grant execute on function public.push_public_key() to authenticated;
create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  if p_endpoint !~ '^https://' then raise exception 'Địa chỉ nhận thông báo không hợp lệ'; end if;
  insert into public.push_subs(endpoint, profile_id, p256dh, auth, ua) values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(p_ua, 200))
  on conflict (endpoint) do update set profile_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth, ua = excluded.ua, fails = 0;
end $$;
grant execute on function public.push_subscribe(text, text, text, text) to authenticated;

-- Chỉ hàm máy chủ (service_role) gọi: lấy / tạo khóa VAPID, nhận 1 thông báo để đẩy (mỗi thông báo đẩy 1 lần), dọn thiết bị hết hạn
create or replace function public.push_cfg_get() returns jsonb language sql security definer set search_path = public, app as $$
  select jsonb_build_object('public_key', public_key, 'private_key', private_key) from app.push_cfg where id = 1
$$;
create or replace function public.push_cfg_init(p_public text, p_private text) returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  insert into app.push_cfg(id, public_key, private_key) values (1, p_public, p_private) on conflict (id) do nothing;
  return public.push_cfg_get();
end $$;
create or replace function public.push_claim(p_id bigint) returns jsonb language plpgsql security definer set search_path = public, app as $$
declare n public.notifications;
begin
  update public.notifications set pushed_at = now() where id = p_id and pushed_at is null and read_at is null returning * into n;
  if n.id is null then return null; end if;
  return jsonb_build_object('title', n.title, 'body', coalesce(n.body, ''), 'link', coalesce(n.link, '#/'), 'tag', 'nt-' || n.id,
    'unread', (select count(*) from public.notifications x where x.recipient_id = n.recipient_id and x.read_at is null),
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)), '[]') from public.push_subs s where s.profile_id = n.recipient_id));
end $$;
create or replace function public.push_result(p_endpoint text, p_ok boolean, p_gone boolean default false) returns void language plpgsql security definer set search_path = public, app as $$
begin
  if p_gone then delete from public.push_subs where endpoint = p_endpoint;
  elsif p_ok then update public.push_subs set last_ok = now(), fails = 0 where endpoint = p_endpoint;
  else update public.push_subs set fails = fails + 1 where endpoint = p_endpoint; delete from public.push_subs where endpoint = p_endpoint and fails >= 20; end if;
end $$;
revoke all on function public.push_cfg_get() from public, anon, authenticated;
revoke all on function public.push_cfg_init(text, text) from public, anon, authenticated;
revoke all on function public.push_claim(bigint) from public, anon, authenticated;
revoke all on function public.push_result(text, boolean, boolean) from public, anon, authenticated;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.push_cfg_get() to service_role;
    grant execute on function public.push_cfg_init(text, text) to service_role;
    grant execute on function public.push_claim(bigint) to service_role;
    grant execute on function public.push_result(text, boolean, boolean) to service_role;
  end if;
end $$;

insert into public.settings(key, value, description) values ('push', jsonb_build_object('url', 'https://iggpwbsugfjhtnhgsyoz.supabase.co/functions/v1/push', 'on', true), 'Thông báo đẩy ra điện thoại')
  on conflict (key) do nothing;
do $$ begin create extension if not exists pg_net; exception when others then raise notice 'pg_net chưa bật: %', sqlerrm; end $$;

create or replace function app.trg_notif_after() returns trigger language plpgsql security definer set search_path = public, app as $$
declare v_cskh uuid; v_url text := app.setting('push')->>'url';
begin
  -- sao cho CSKH (1 lần, không sao tiếp bản sao)
  if new.copy_of is null and new.kind in ('acc','quote') then
    v_cskh := app.cskh_for(new.recipient_id);
    if v_cskh is not null and v_cskh <> new.recipient_id then
      insert into public.notifications(recipient_id, kind, title, body, link, copy_of)
      values (v_cskh, new.kind, '[' || coalesce(app.name_of(new.recipient_id), 'Sale') || '] ' || new.title, new.body, new.link, new.id);
    end if;
  end if;
  -- đẩy ra thiết bị đã bật thông báo (nếu có pg_net + hàm máy chủ)
  if coalesce((app.setting('push')->>'on')::boolean, false) and v_url is not null
     and exists(select 1 from public.push_subs s where s.profile_id = new.recipient_id)
     and exists(select 1 from pg_extension where extname = 'pg_net') then
    begin
      execute 'select net.http_post(url := $1, body := $2, headers := $3)'
        using v_url, jsonb_build_object('id', new.id), '{"Content-Type":"application/json"}'::jsonb;
    exception when others then null; end;
  end if;
  return null;
end $$;
-- Người dùng tự gửi thử 1 thông báo cho chính mình (nút "Gửi thử" ở trang Tài khoản)
create or replace function public.push_test() returns void language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  perform app.notify(auth.uid(), 'system', 'Thử thông báo ERP Nam Trung', 'Chạm vào đây để mở trang Tài khoản', '#/account');
end $$;
grant execute on function public.push_test() to authenticated;
drop trigger if exists notif_after on public.notifications;
create trigger notif_after after insert on public.notifications for each row execute function app.trg_notif_after();


-- =============== 5. Phép năm cộng dồn mỗi tháng ===============
create or replace function public.leave_balance(p_profile uuid default null, p_year int default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare v_id uuid := coalesce(p_profile, auth.uid()); y int := coalesce(p_year, extract(year from app.vn_today())::int);
        e record; used_h1 numeric; used_h2 numeric; pending numeric; total_used numeric; carry_left numeric; remaining numeric;
        hire date; months int; accrued numeric; v_mode text := coalesce(app.setting('leave')->>'accrual', 'monthly');
begin
  if not (v_id = auth.uid() or app.can_see_hr() or app.in_mgmt(v_id)) then raise exception 'Không có quyền'; end if;
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
  -- Bản 28: phép năm cộng dồn mỗi tháng = được hưởng năm ÷ 12, cộng vào ngày 01 hằng tháng.
  -- Tháng vào làm được tính nếu vào làm từ ngày 15 trở về trước. Năm đã qua: đủ cả năm (trừ tháng chưa vào làm).
  select hire_date into hire from public.profiles where id = v_id;
  select count(*) into months from generate_series(make_date(y, 1, 1), make_date(y, 12, 1), interval '1 month') m
   where m::date <= app.vn_today() and (hire is null or m::date >= date_trunc('month', hire)::date + case when extract(day from hire) > 15 then interval '1 month' else interval '0' end);
  accrued := case when v_mode = 'monthly' then least(e.entitled, round(e.entitled * months / 12.0, 2)) else e.entitled end;
  remaining := accrued + carry_left - total_used;
  return jsonb_build_object('year', y, 'entitled', e.entitled, 'carried', e.carried, 'used_before', e.used_before,
    'used', total_used, 'used_year', total_used, 'pending', pending, 'balance', remaining, 'available', remaining - pending,
    'accrued', accrued, 'months', months, 'per_month', round(e.entitled / 12.0, 2), 'mode', v_mode, 'configured', exists(select 1 from public.leave_entitlements where profile_id = v_id and year = y));
end $$;

update public.settings set value = value || '{"accrual":"monthly"}'::jsonb where key = 'leave' and not (value ? 'accrual');


-- =============== 7. Duyệt đơn quên chấm: nhập giờ vào / ra thực tế ===============
alter table public.attendance_requests add column if not exists confirm_in time;
alter table public.attendance_requests add column if not exists confirm_out time;

drop function if exists public.decide_request(text, uuid, boolean, text);
create or replace function public.decide_request(p_table text, p_id uuid, p_approve boolean, p_note text default null, p_in time default null, p_out time default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_owner uuid; v_status text; v_lock boolean; v_kind text; v_date date; v_has_in boolean;
begin
  if p_table = 'leave' then
    select profile_id, status into v_owner, v_status from public.leave_requests where id = p_id for update;
  elsif p_table = 'attendance' then
    select profile_id, status, kind, work_date into v_owner, v_status, v_kind, v_date from public.attendance_requests where id = p_id for update;
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
  if p_table = 'leave' then
    update public.leave_requests set status = case when p_approve then 'da_duyet' else 'tu_choi' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = p_id;
  else
    update public.attendance_requests set status = case when p_approve then 'da_duyet' else 'tu_choi' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note,
      confirm_in = case when p_approve then p_in end, confirm_out = case when p_approve then p_out end where id = p_id;
  end if;
  perform app.log(case when p_approve then 'APPROVE' else 'REJECT' end, p_table || '_requests', p_id::text, jsonb_build_object('note', p_note, 'in', p_in, 'out', p_out));
end $$;

grant execute on function public.decide_request(text, uuid, boolean, text, time, time) to authenticated;


create or replace function app.day_info(p_id uuid, p_schedule text, p_hire date, d date)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('attendance'),'{}'); dv numeric; off numeric := 0; paid_off numeric := 0; work_leave boolean := false;
        lpart text; codes text[] := '{}'; first_in timestamptz; last_out timestamptz; attended boolean; late int := 0; s_start time; s_end time;
        hrs record; l record; forgot boolean := false; holiday record; ci time; co time;
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
    select bool_or(true), min(r.confirm_in), max(r.confirm_out) into forgot, ci, co from public.attendance_requests r
     where r.profile_id = p_id and r.work_date = d and r.status = 'da_duyet' and r.kind = 'xac_nhan_cong';
    forgot := coalesce(forgot, false);
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


-- =============== 6. Bảng công: lương tạm tính đến hôm nay ===============
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
    select count(*) into nforgot from public.attendance_requests r where r.profile_id = p.id and r.kind = 'xac_nhan_cong' and r.status = 'da_duyet' and r.work_date between m0 and m1;
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


-- =============== Dữ liệu cũ: chuẩn hóa username + gắn khách ===============
update public.customers set sys_username = sys_username where sys_username is not null and sys_username is distinct from app.norm_username(sys_username);
update public.out_orders set username = username where username is distinct from app.norm_username(username);
update public.out_buyers set username = username where username is distinct from app.norm_username(username);
update public.acc_lines set ma_kh = ma_kh where ma_kh is distinct from app.norm_username(ma_kh);
update public.out_items set username = username where username is distinct from app.norm_username(username);
do $$ declare r record; begin
  for r in select id from public.out_items where customer_id is null and username is not null loop perform app.out_item_match(r.id); end loop;
  perform app.out_buyers_relink();
end $$;

reset search_path;


-- >>>>> supabase/migrations/0036_v29.sql
-- =====================================================================
-- 0036 · Bản 29 (05/11/2026)
--  1. CSKH (không kiêm sale / quản lý) KHÔNG được truy cập: Hỗ trợ khách, Báo cáo ngày, Báo cáo và KPI, Bảng Phong Thần
--  2. Hóa đơn của tôi: CSKH thấy hóa đơn + hàng sẵn sàng xuất của các sale mình hỗ trợ
--  3. Hóa đơn: lọc theo số HĐ đầu vào APT; trả mã hàng (HH00044-2153-2026) + số HĐ để hiện ngay trên danh sách
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 29');

-- CSKH thuần: có vai trò CSKH, không kiêm sale / trưởng nhóm / trưởng phòng / quản lý / admin
create or replace function app.is_cskh_only() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists(select 1 from public.profiles p where p.id = auth.uid() and 'cskh' = any(p.roles)
                and not p.roles && array['admin','bgd','sale','tn_kd','tp_kd','ke_toan','hcns'])
     and not exists(select 1 from public.profiles x where x.manager_id = auth.uid() and x.status = 'active')
$$;

-- Số HĐ đầu vào của 1 dòng: cột số HĐ, thiếu thì lấy từ mã hàng HH00044-2153-2026 → 2153
create or replace function app.hd_of(p_so text, p_ma text) returns text language sql immutable as $$
  select coalesce(nullif(ltrim(btrim(p_so), '0'), ''), substring(p_ma from '^[A-Za-z]+[0-9]+-0*([0-9]+)-[0-9]{4}'))
$$;


-- 1. Chặn CSKH: KPI, Bảng Phong Thần (leaderboard gọi kpi_report), báo cáo, hỗ trợ khách
create or replace function public.kpi_report(p_from date, p_to date, p_all boolean default false)
returns table(profile_id uuid, full_name text, job_level text, is_new boolean, metrics jsonb, score numeric, grade text)
language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('kpi'), '{}'); days int := greatest(app.kpi_days(p_from, least(p_to, app.vn_today())), 1);
        t0 timestamptz := (p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'); t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh');
begin
  if app.is_cskh_only() then return; end if; -- bản 29: CSKH không xem KPI / Bảng Phong Thần
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

create or replace function public.crm_report(p_kind text, p_from date, p_to date, p_sale uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare tree uuid[] := case when p_sale is not null and app.in_tree(p_sale) then array[p_sale] else app.my_tree() end;
        t0 timestamptz := (p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'); t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh');
        adm boolean := app.is_admin() and p_sale is null;
begin
  if app.is_cskh_only() then raise exception 'CSKH không xem báo cáo kinh doanh'; end if;
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  if p_kind = 'funnel' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select app.name_of(c.owner_id) sale, c.stage, count(*) n from public.customers c
      where c.deleted_at is null and (adm or c.owner_id = any(tree)) group by 1, 2 order by 1, 2) x);
  elsif p_kind = 'quotes' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select app.name_of(q.sale_id) sale, q.status, count(*) n, sum(q.total_after_vat) value, sum(q.est_profit) profit
      from public.quotations q where q.created_at >= t0 and q.created_at < t1 and (adm or q.sale_id = any(tree)) group by 1, 2 order by 1, 2) x);
  elsif p_kind = 'reject_reasons' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select coalesce(l.label, q.reject_reason) reason, count(*) n from public.quotations q
      left join public.lookups l on l.category='reject_reason' and l.code = q.reject_reason
      where q.status = 'tu_choi' and q.updated_at >= t0 and q.updated_at < t1 and (adm or q.sale_id = any(tree)) group by 1 order by 2 desc) x);
  elsif p_kind = 'sources' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select coalesce(l.label, c.source) source, count(*) n, count(*) filter (where c.order_count > 0) won from public.customers c
      left join public.lookups l on l.category='source' and l.code = c.source
      where c.deleted_at is null and c.created_at >= t0 and c.created_at < t1 and (adm or c.owner_id = any(tree)) group by 1 order by 2 desc) x);
  elsif p_kind = 'retention' then
    return (select jsonb_build_object(
      'buyers', count(*) filter (where order_count >= 1),
      'repeat', count(*) filter (where order_count >= 2),
      'rate', round(100.0 * count(*) filter (where order_count >= 2) / nullif(count(*) filter (where order_count >= 1), 0), 1),
      'sleeping', count(*) filter (where stage = 'kho_ngu'),
      'lost', count(*) filter (where stage = 'mat_khach'))
      from public.customers where deleted_at is null and (adm or owner_id = any(tree)));
  elsif p_kind = 'care_due' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select app.name_of(owner_id) sale, count(*) filter (where next_care_date < app.vn_today()) overdue,
             count(*) filter (where next_care_date = app.vn_today()) today,
             count(*) filter (where last_contact_at < now() - interval '30 days' or last_contact_at is null) forgotten
      from public.customers where deleted_at is null and stage not in ('khong_tiem_nang','mat_khach') and (adm or owner_id = any(tree)) group by 1 order by 2 desc) x);
  elsif p_kind = 'reports' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select app.name_of(s.id) sale, count(r.*) submitted, count(r.*) filter (where r.on_time) on_time, app.kpi_days(p_from, least(p_to, app.vn_today())) days
      from public.profiles s left join public.daily_reports r on r.sale_id = s.id and r.report_date between p_from and p_to
      where s.status='active' and s.roles && array['sale','tn_kd','tp_kd'] and (adm or s.id = any(tree)) group by s.id order by 1) x);
  elsif p_kind = 'transfers' then
    return (select coalesce(jsonb_agg(x), '[]') from (
      select to_char(t.created_at at time zone 'Asia/Ho_Chi_Minh', 'DD/MM/YYYY HH24:MI') at, c.code, coalesce(c.company_name, c.contact_name) customer,
             app.name_of(t.from_id) from_sale, app.name_of(t.to_id) to_sale, t.reason, t.note, app.name_of(t.created_by) by
      from public.customer_transfers t join public.customers c on c.id = t.customer_id
      where t.created_at >= t0 and t.created_at < t1 and (adm or t.to_id = any(tree) or t.from_id = any(tree)) order by t.created_at desc) x);
  end if;
  raise exception 'Loại báo cáo không hợp lệ';
end $$;

create or replace function public.support_customer(p_req uuid)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare r public.support_requests; c public.customers; res jsonb;
begin
  if app.is_cskh_only() then raise exception 'CSKH không dùng mục Hỗ trợ khách'; end if;
  select * into r from public.support_requests where id = p_req;
  if r.id is null or r.customer_id is null then return null; end if;
  if not (r.requester_id = auth.uid() or r.assignee_id = auth.uid() or app.is_admin() or app.in_tree(r.requester_id)
          or r.org_unit_id = (select org_unit_id from public.profiles where id = auth.uid())) then
    raise exception 'Không có quyền xem yêu cầu này';
  end if;
  select * into c from public.customers where id = r.customer_id;
  res := jsonb_build_object(
    'id', c.id, 'code', c.code, 'contact_name', c.contact_name, 'company_name', c.company_name, 'position', c.position,
    'phone', c.phone, 'zalo', c.zalo, 'email', c.email, 'tax_code', c.tax_code, 'province', c.province, 'address', c.address,
    'customer_type', c.customer_type, 'industry', c.industry, 'goods', c.goods, 'import_method', c.import_method,
    'current_provider', c.current_provider, 'monthly_value', c.monthly_value, 'stage', c.stage, 'temperature', c.temperature,
    'next_care_date', c.next_care_date, 'care_count', c.care_count, 'quote_count', c.quote_count, 'order_count', c.order_count,
    'note', c.note, 'owner_id', c.owner_id, 'owner_name', app.name_of(c.owner_id), 'services', c.services, 'goods_traits', c.goods_traits,
    'can_open', app.is_admin() or app.in_tree(c.owner_id),
    'care', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select cl.id, cl.created_at, cl.channel, cl.purpose, cl.result, cl.is_connected, cl.content, cl.stage_after, cl.temperature_after,
               cl.next_care_date, cl.quotation_code, app.name_of(cl.sale_id) sale_name
        from public.care_logs cl where cl.customer_id = c.id order by cl.created_at desc limit 30) x), '[]'),
    'quotes', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select q.id, q.code, q.version, q.status, q.total_after_vat, q.created_at, q.order_code
        from public.quotations q where q.customer_id = c.id and q.status <> 'da_thay_the' order by q.created_at desc limit 10) x), '[]'));
  return res;
end $$;

drop policy if exists dr_read on public.daily_reports;
create policy dr_read on public.daily_reports for select to authenticated using (sale_id = auth.uid() or app.in_mgmt(sale_id) or app.is_admin());


-- 2. Hóa đơn của tôi: CSKH thấy dữ liệu của sale được hỗ trợ
create or replace function app.out_items_scope(p_mode text) returns setof public.out_items
language plpgsql stable security definer set search_path = public, app as $$
declare v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_scope(); v_sale boolean := app.has_role('sale','tn_kd','tp_kd');
begin
  if p_mode = 'acc' then
    if not v_acc then return; end if;
    return query select * from public.out_items;
  elsif p_mode = 'free' then
    if not (v_acc or v_sale) then return; end if;
    return query select * from public.out_items where sale_id is null;
  else
    return query select * from public.out_items where sale_id = any(v_tree);
  end if;
end $$;

create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_flag text := nullif(p->>'flag', ''); v_next text := nullif(p->>'next', ''); v_sort text := coalesce(nullif(p->>'sort', ''), 'at'); v_dir text := coalesce(nullif(p->>'dir', ''), 'desc'); v_sua int; v_misa int; v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_scope(); v_hd text := nullif(ltrim(btrim(p->>'hd'), '0'), '');
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
       and (v_hd is null or exists(select 1 from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = i.id and app.hd_of(t.so_hd_vao, t.ma_hang) = v_hd)) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  select count(*) filter (where i.sua_sau_nhap), count(*) filter (where i.misa_at is null) into v_sua, v_misa from public.out_invoices i
   where i.status = 'cho_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale);
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_hd is null or exists(select 1 from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = v.id and app.hd_of(t.so_hd_vao, t.ma_hang) = v_hd))
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)
                               and (v_flag is null or v_flag = 'sua' and v.sua_sau_nhap or v_flag = 'misa_chua' and v.misa_at is null)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim,
               string_agg(distinct t.md, ', ') mds, bool_or(coalesce(l.vat, t.vat) >= 0.095) vat10,
               string_agg(distinct t.ma_hang, ', ') mas, string_agg(distinct app.hd_of(t.so_hd_vao, t.ma_hang), ', ') hds
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia, a.mds, coalesce(a.vat10, false) vat10, a.mas, a.hds,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where (v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%')
           and (v_next is null or b.status = 'da_nhap' and fn.version is not null and (v_next = 'chua_gui' and fn.sent_at is null or v_next = 'cho_khach' and fn.sent_at is not null))),
  o as (select f.*, row_number() over (order by
          case when v_dir = 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end asc nulls last,
          case when v_dir <> 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end desc nulls last,
          case when v_sort = 'tien' and v_dir = 'asc' then f.tien_hang + f.tien_thue end asc nulls last,
          case when v_sort = 'tien' and v_dir <> 'asc' then f.tien_hang + f.tien_thue end desc nulls last,
          case when v_dir = 'asc' and v_sort = 'at' then f.status_at end asc, f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa);
end $$;


-- 3. Danh sách số HĐ đầu vào để lọc (theo phạm vi người xem)
create or replace function public.out_hd_opts(p_mode text default 'mine') returns table(hd text, ngay date, n bigint)
language sql stable security definer set search_path = public, app as $$
  select app.hd_of(s.so_hd_vao, s.ma_hang) hd, max(s.ngay_vao) ngay, count(*) n
    from app.out_items_scope(case when p_mode = 'acc' then 'acc' else 'mine' end) s
   where app.hd_of(s.so_hd_vao, s.ma_hang) is not null
   group by 1 order by max(s.ngay_vao) desc nulls last, 1 desc
$$;
grant execute on function public.out_hd_opts(text) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0037_v30.sql
-- =====================================================================
-- 0037 · Bản 30 (05/11/2026): Bước 4 "Chờ ký" — bỏ tải PDF đã ký; kế toán ký trên MISA rồi nhập MÃ TRA CỨU
--  · Nhập mã tra cứu = chuyển "Đã ký" + báo sale. Sale bấm mã tra cứu → mở HĐ trên meinvoice.vn
--  · Kế toán sửa được mã tra cứu đã nhập (gõ nhầm); mỗi mã chỉ dùng cho 1 HĐ
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 30');

alter table public.out_invoices add column if not exists ma_tra_cuu text;
create unique index if not exists out_invoices_ma_tra_cuu on public.out_invoices(upper(ma_tra_cuu)) where ma_tra_cuu is not null;

-- Đường dẫn xem HĐ theo mã tra cứu (đổi được ở Cấu hình nếu MISA đổi)
update public.settings set value = value || jsonb_build_object('tra_cuu_url', 'https://www.meinvoice.vn/tra-cuu/tra-cuu/DownloadHandler.ashx?Type=pdf&Viewer=1&ext=QXVLM59J&Code={code}')
 where key = 'accounting' and not (value ? 'tra_cuu_url');

-- Kế toán: ký xong trên MISA → nhập mã tra cứu → "Đã ký" (gọi lại để sửa mã của HĐ đã ký)
create or replace function public.out_mark_signed(p_id uuid, p_ma text, p_so_hd text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; m text := upper(regexp_replace(coalesce(p_ma, ''), '[[:space:]]+', '', 'g')); dup text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán xác nhận ký'; end if;
  if m !~ '^[A-Z0-9_-]{6,30}$' then raise exception 'Mã tra cứu không hợp lệ (6–30 ký tự chữ / số)'; end if;
  select * into v from public.out_invoices where id = p_id for update;
  if v.id is null then raise exception 'Không tìm thấy phiếu'; end if;
  if v.status not in ('xac_nhan_ky', 'da_nhap', 'da_ky') then raise exception 'Phiếu % đang "%", chưa tới bước ký', v.code, v.status; end if;
  select code into dup from public.out_invoices where upper(ma_tra_cuu) = m and id <> p_id;
  if dup is not null then raise exception 'Mã tra cứu % đã gắn cho phiếu %', m, dup; end if;
  update public.out_invoices set ma_tra_cuu = m, so_hd = coalesce(nullif(btrim(p_so_hd), ''), so_hd),
    status = 'da_ky', ngay_hd = coalesce(ngay_hd, app.vn_today()),
    status_at = case when v.status = 'da_ky' then status_at else now() end, status_by = case when v.status = 'da_ky' then status_by else auth.uid() end, updated_at = now()
  where id = p_id;
  insert into public.out_events(invoice_id, action, note, data)
  values (p_id, case when v.status = 'da_ky' then 'sua_ma_tra_cuu' else 'status' end, 'Mã tra cứu ' || m,
          jsonb_build_object('from', v.status, 'to', 'da_ky', 'ma_tra_cuu', m, 'ma_cu', v.ma_tra_cuu));
  if v.status <> 'da_ky' then
    perform app.notify(v.sale_id, 'acc', 'Đã ký HĐ: ' || v.code, coalesce(v.buyer_name, '') || ' — mã tra cứu ' || m || '. Bấm để xem HĐ.', '#/hd?inv=' || v.id);
  end if;
  return jsonb_build_object('code', v.code, 'ma_tra_cuu', m);
end $$;
grant execute on function public.out_mark_signed(uuid, text, text) to authenticated;

reset search_path;


-- >>>>> supabase/migrations/0038_v31.sql
-- =====================================================================
-- 0038 · Bản 31 (05/11/2026): Tạo HĐ nháp MISA meInvoice bằng API — chạy SONG SONG với cách làm tay
--  · Làm tay giữ nguyên: Xuất Excel → nhập MISA → tải PDF nháp → dán mã tra cứu
--  · API (khi có ClientID): kế toán bấm "Tạo nháp MISA" → hàm máy chủ "misa" kiểm, gửi, lấy PDF về Drive;
--    tự dò MISA 15 phút/lần, HĐ đã ký → tự ghi số HĐ + mã tra cứu, chuyển "Đã ký"
--  · Bảng out_misa: mỗi dòng = 1 lần tạo nháp (RefID = GUID mới, không dùng lại). Mỗi phiếu tối đa 1 nháp đang sống.
--  · Chống tạo đôi giữa 2 cách: phiếu đã xuất Excel không tạo API được (trừ khi bỏ mốc export); phiếu có nháp API bị bỏ khỏi file Excel
--  · Chỉ Kế toán / Admin / BGĐ thao tác; sale, CSKH, trưởng nhóm chỉ xem theo phạm vi như phiếu xuất HĐ
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 31');

-- ---------- Bảng ----------
create table if not exists public.out_misa(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.out_invoices(id) on delete cascade,
  ref_id uuid not null unique default gen_random_uuid(),
  lan int not null,
  invoice_version int not null default 1,
  sale_id uuid references public.profiles(id),
  trang_thai text not null default 'dang_tao' check (trang_thai in ('dang_tao','da_tao','loi','da_xoa','da_phat_hanh')),
  payload jsonb,
  tien_hang numeric, tien_thue numeric, tong_tt numeric,
  misa_tong_tt numeric, misa_tien_thue numeric, khop boolean,
  so_hd text, ma_tra_cuu text, phat_hanh_at timestamptz,
  file_id uuid references public.out_invoice_files(id) on delete set null,
  loi_ma text, loi_text text,
  created_by uuid default auth.uid() references public.profiles(id), created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_by uuid references public.profiles(id), deleted_at timestamptz, synced_at timestamptz,
  unique (invoice_id, lan)
);
-- 1 phiếu chỉ có tối đa 1 nháp đang sống (bấm 2 lần / 2 máy cùng bấm → dòng thứ 2 bị từ chối)
create unique index if not exists out_misa_one_active on public.out_misa(invoice_id) where trang_thai in ('dang_tao','da_tao','da_phat_hanh');
create index if not exists out_misa_sync on public.out_misa(trang_thai, synced_at) where trang_thai in ('dang_tao','da_tao');
create index if not exists out_misa_sale on public.out_misa(sale_id);
alter table public.out_misa enable row level security;
revoke all on public.out_misa from anon, authenticated;
grant select on public.out_misa to authenticated;
drop policy if exists out_misa_read on public.out_misa;
create policy out_misa_read on public.out_misa for select to authenticated using (app.is_acc() or app.in_tree(sale_id));

-- Token MISA: chỉ hàm máy chủ (service_role) đọc / ghi
create table if not exists app.misa_token(id int primary key default 1 check (id = 1), token text, got_at timestamptz);
revoke all on app.misa_token from public, anon, authenticated;

-- Cấu hình MISA nằm trong cấu hình Kế toán: accounting.misa = {enabled, template_id, inv_series, with_code, batch, auto_sync}
update public.settings set value = value || jsonb_build_object('misa', jsonb_build_object('enabled', false, 'with_code', true, 'batch', 10, 'auto_sync', true))
 where key = 'accounting' and not (value ? 'misa');

-- ---------- Hàm hỗ trợ ----------
create or replace function app.is_service() returns boolean language sql stable as $$
  -- 'role' = vai trò đã SET ROLE của phiên (không đổi bên trong hàm security definer, khác current_user)
  select coalesce(current_setting('role', true), '') = 'service_role' or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role'
$$;
create or replace function app.misa_cfg() returns jsonb language sql stable security definer set search_path = public, app as $$
  select coalesce(app.setting('accounting')->'misa', '{}'::jsonb)
$$;
create or replace function app.vn_iso(p timestamptz default now()) returns text language sql stable as $$
  select to_char(p at time zone 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD"T"HH24:MI:SS') || '+07:00'
$$;
-- Mã số thuế / CCCD chuẩn: 10 số, 10-3 số hoặc 12 số
create or replace function app.mst_ok(p text) returns boolean language sql immutable as $$
  select coalesce(btrim(p), '') ~ '^([0-9]{10}|[0-9]{10}-[0-9]{3}|[0-9]{12})$'
$$;
create or replace function app.has_emoji(p text) returns boolean language sql immutable as $$
  select coalesce(p, '') ~ '[\U0001F000-\U0010FFFF]' or coalesce(p, '') ~ '[☀-➿️‍]'
$$;

-- Dữ liệu gửi MISA (InvoiceData) dựng từ phiếu XHD — 1 chỗ duy nhất. Làm tròn từng dòng rồi cộng (như file Excel + khuyến nghị MISA)
create or replace function app.out_misa_payload(p_inv uuid, p_ref uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v public.out_invoices; m jsonb := app.misa_cfg(); d jsonb; tt numeric; th numeric; rates int; one_rate int; mds text; sale_code text; kh text;
begin
  select * into v from public.out_invoices where id = p_inv;
  if v.id is null then return null; end if;
  with l as (
    select l.stt, t.ma_hang, t.ten, t.dvt, l.sl, l.don_gia, coalesce(l.vat, t.vat) vat, round(l.sl * l.don_gia) tt, t.md
      from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = p_inv)
  select coalesce(jsonb_agg(jsonb_build_object(
           'InventoryItemType', 0, 'InventoryItemCode', l.ma_hang, 'Description', l.ten, 'UnitName', l.dvt,
           'Quantity', l.sl, 'UnitPrice', l.don_gia, 'AmountOC', l.tt, 'Amount', l.tt,
           'DiscountRate', 0, 'DiscountAmountOC', 0, 'DiscountAmount', 0,
           'VATRate', case when l.vat is null then null else round(l.vat * 100)::int end,
           'VATAmountOC', round(l.tt * coalesce(l.vat, 0)), 'VATAmount', round(l.tt * coalesce(l.vat, 0)),
           'SortOrder', l.stt, 'SortOrderView', l.stt) order by l.stt), '[]'),
         coalesce(sum(l.tt), 0), coalesce(sum(round(l.tt * coalesce(l.vat, 0))), 0),
         count(distinct round(coalesce(l.vat, -1) * 100)), min(round(l.vat * 100))::int,
         string_agg(distinct l.md, ', ')
    into d, tt, th, rates, one_rate, mds from l;
  select coalesce(nullif(btrim(p.employee_code), ''), p.full_name) into sale_code from public.profiles p where p.id = v.sale_id;
  select coalesce(nullif(btrim(c.sys_code), ''), c.code) into kh from public.customers c where c.id = v.customer_id;
  return jsonb_strip_nulls(jsonb_build_object(
    'RefID', p_ref, 'InvoiceTemplateID', m->>'template_id', 'InvSeries', m->>'inv_series',
    'InvDate', to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD') || 'T00:00:00+07:00', 'InvNo', '<Chưa cấp số>',
    'AccountObjectName', btrim(v.buyer_name), 'AccountObjectTaxCode', nullif(btrim(v.tax_code), ''), 'AccountObjectCode', kh,
    'AccountObjectAddress', nullif(btrim(v.address), ''), 'ReceiverEmail', nullif(btrim(v.email), ''),
    'PaymentMethod', coalesce(nullif(btrim(v.payment), ''), 'TM/CK'), 'CurrencyCode', 'VND', 'CurrencyID', 'VND', 'ExchangeRate', 1, 'DiscountRate', 0,
    'VATRate', case when rates = 1 then one_rate end, 'EInvoiceStatus', 1,
    'TotalSaleAmountOC', tt, 'TotalSaleAmount', tt, 'TotalDiscountAmountOC', 0, 'TotalDiscountAmount', 0,
    'TotalVATAmountOC', th, 'TotalVATAmount', th, 'TotalAmountOC', tt + th, 'TotalAmount', tt + th,
    'CreatedDate', app.vn_iso(), 'ModifiedDate', app.vn_iso(),
    'CustomField1', v.code, 'CustomField2', sale_code, 'CustomField3', mds,
    'InvoiceDetails', d));
end $$;
revoke all on function app.out_misa_payload(uuid, uuid) from public, anon;

-- Kiểm 1 phiếu trước khi gửi: lỗi (chặn) + cảnh báo (không chặn) + tổng tiền + nháp đang có
create or replace function app.out_misa_eval(p_inv uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v public.out_invoices; m jsonb := app.misa_cfg(); e text[] := '{}'; w text[] := '{}'; act public.out_misa; prev public.out_misa; r record;
        n int := 0; tt numeric := 0; th numeric := 0; p jsonb; old boolean := false;
begin
  select * into v from public.out_invoices where id = p_inv;
  if v.id is null then return jsonb_build_object('invoice_id', p_inv, 'errors', jsonb_build_array('Không tìm thấy phiếu')); end if;
  select * into act from public.out_misa where invoice_id = p_inv and trang_thai in ('dang_tao','da_tao','da_phat_hanh') order by lan desc limit 1;
  select * into prev from public.out_misa where invoice_id = p_inv and payload is not null and trang_thai in ('da_tao','da_xoa','da_phat_hanh') order by lan desc limit 1;
  if coalesce(m->>'template_id', '') = '' or coalesce(m->>'inv_series', '') = '' then e := e || 'Chưa chọn mẫu HĐ MISA (Cấu hình → Kế toán – Hóa đơn → MISA)'; end if;
  if v.status <> 'cho_nhap' then
    e := e || ('Phiếu đang "' || case v.status when 'soan' then 'sale đang soạn' when 'cho_duyet_gia' then 'chờ duyệt giá' when 'da_nhap' then 'có nháp' when 'tra_sua' then 'sale trả sửa'
      when 'xac_nhan_ky' then 'chờ ký' when 'da_ky' then 'đã ký' when 'huy' then 'hủy' else v.status end || '" — chỉ tạo nháp cho phiếu "Đã gửi — chờ export"');
  end if;
  if act.id is not null then
    if act.trang_thai = 'dang_tao' then e := e || ('Đang tạo nháp lần ' || act.lan || ' — chờ xong hoặc bấm Kiểm tra trạng thái MISA');
    elsif act.trang_thai = 'da_phat_hanh' then e := e || ('MISA đã phát hành HĐ số ' || coalesce(act.so_hd, '?') || ' cho phiếu này');
    elsif act.invoice_version >= v.version then e := e || ('Đã có nháp MISA lần ' || act.lan || ' — muốn tạo lại thì bấm Tạo lại nháp ở chi tiết phiếu');
    else old := true; w := w || ('Nháp lần ' || act.lan || ' là bản cũ (sale đã sửa) — sẽ xóa trên MISA rồi tạo nháp mới'); end if;
  elsif v.misa_at is not null then
    e := e || ('Đã xuất Excel nhập MISA lúc ' || to_char(v.misa_at at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM') || ' — nếu đã nhập vào MISA thì xóa nháp tay trên MISA, rồi bấm "Bỏ mốc export"');
  end if;
  if coalesce(btrim(v.buyer_name), '') = '' then e := e || 'Thiếu tên đơn vị mua'::text; end if;
  if coalesce(btrim(v.address), '') = '' then e := e || 'Thiếu địa chỉ đơn vị mua'::text; end if;
  if coalesce(btrim(v.tax_code), '') = '' then e := e || 'Thiếu MST / CCCD'::text;
  elsif not app.mst_ok(v.tax_code) then e := e || ('MST "' || v.tax_code || '" sai dạng (10 số, 10-3 số hoặc 12 số)'); end if;
  if coalesce(btrim(v.email), '') <> '' and btrim(v.email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then e := e || ('Email "' || v.email || '" sai dạng'); end if;
  if coalesce(btrim(v.email), '') = '' then w := w || 'Khách chưa có email nhận HĐ'::text; end if;
  if app.has_emoji(concat_ws(' ', v.buyer_name, v.address, v.email)) then e := e || 'Thông tin đơn vị mua có emoji / ký tự lạ — MISA sẽ từ chối'::text; end if;
  for r in select l.stt, t.ma_hang, t.ten, t.dvt, l.sl, l.don_gia, coalesce(l.vat, t.vat) vat, t.dg_nhap, t.lech, t.lech_ok_at
             from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = p_inv order by l.stt loop
    n := n + 1; tt := tt + round(r.sl * r.don_gia); th := th + round(round(r.sl * r.don_gia) * coalesce(r.vat, 0));
    if coalesce(btrim(r.ten), '') = '' then e := e || ('Dòng ' || r.stt || ': thiếu tên hàng'); end if;
    if coalesce(btrim(r.dvt), '') = '' then e := e || ('Dòng ' || r.stt || ': thiếu đơn vị tính'); end if;
    if coalesce(r.sl, 0) <= 0 then e := e || ('Dòng ' || r.stt || ': số lượng phải > 0'); end if;
    if coalesce(r.don_gia, 0) <= 0 then e := e || ('Dòng ' || r.stt || ': đơn giá phải > 0'); end if;
    if r.vat is null or not exists(select 1 from unnest(array[0, 0.05, 0.08, 0.1]) x where abs(x - r.vat) < 0.00001) then
      e := e || ('Dòng ' || r.stt || ': thuế suất ' || coalesce(round(r.vat * 100, 2)::text || '%', 'trống') || ' — chỉ nhận 0, 5, 8, 10%'); end if;
    if app.has_emoji(concat_ws(' ', r.ten, r.dvt)) then e := e || ('Dòng ' || r.stt || ': có emoji / ký tự lạ'); end if;
    if r.lech and r.lech_ok_at is null then e := e || ('Dòng ' || r.stt || ' (' || r.ma_hang || '): đang lệch so với nháp APT — chờ kế toán xử lý'); end if;
    if r.dg_nhap is not null and r.don_gia < r.dg_nhap then w := w || ('Dòng ' || r.stt || ': đơn giá thấp hơn giá nhập'); end if;
  end loop;
  if n = 0 then e := e || 'Phiếu không có dòng hàng'::text; elsif n > 200 then e := e || ('Phiếu có ' || n || ' dòng — tối đa 200 dòng/HĐ, tách phiếu'); end if;
  if abs((tt + th) - app.out_inv_total(p_inv)) > 0.5 then e := e || 'Tổng tiền tính lại lệch với tổng phiếu — báo Admin'::text; end if;
  if exists(select 1 from public.out_invoices o where o.id <> v.id and o.status <> 'huy' and coalesce(o.tax_code, '') = coalesce(v.tax_code, '') and coalesce(v.tax_code, '') <> ''
              and o.created_at > now() - interval '7 days' and abs(app.out_inv_total(o.id) - (tt + th)) < 0.5) then
    w := w || 'Có phiếu khác cùng MST, cùng tổng tiền trong 7 ngày — kiểm tra trùng'::text; end if;
  p := app.out_misa_payload(p_inv, null);
  return jsonb_build_object('invoice_id', v.id, 'code', v.code, 'status', v.status, 'version', v.version, 'sale_id', v.sale_id, 'buyer_name', v.buyer_name, 'tax_code', v.tax_code,
    'so_dong', n, 'tien_hang', tt, 'tien_thue', th, 'tong', tt + th, 'errors', to_jsonb(e), 'warnings', to_jsonb(w), 'ok', cardinality(e) = 0,
    'old', old, 'active', case when act.id is null then null else jsonb_build_object('hd_id', act.id, 'lan', act.lan, 'ref_id', act.ref_id, 'trang_thai', act.trang_thai) end,
    'payload', p, 'prev', case when prev.id is null then null else jsonb_build_object('lan', prev.lan, 'payload', prev.payload) end);
end $$;
revoke all on function app.out_misa_eval(uuid) from public, anon;

-- ---------- Hàm cho Kế toán (trình duyệt) ----------
-- Kiểm tra trước khi gửi (không ghi gì)
create or replace function public.out_misa_check(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin tạo nháp MISA'; end if;
  if coalesce(array_length(p_ids, 1), 0) > 500 then raise exception 'Tối đa 500 phiếu mỗi lần'; end if;
  return (select coalesce(jsonb_agg(app.out_misa_eval(x) order by o), '[]') from unnest(p_ids) with ordinality u(x, o));
end $$;
grant execute on function public.out_misa_check(uuid[]) to authenticated;

-- Giữ chỗ trước khi gọi MISA: ghi dòng "đang tạo" + RefID mới. Nháp cũ (sale đã sửa) → trả need_delete để hàm máy chủ xóa trên MISA trước
create or replace function public.out_misa_claim(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x uuid; ev jsonb; out jsonb := '[]'; v public.out_invoices; v_ref uuid; v_hd uuid; v_lan int; p jsonb;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin tạo nháp MISA'; end if;
  if coalesce(array_length(p_ids, 1), 0) > 30 then raise exception 'Tối đa 30 HĐ mỗi lô'; end if;
  foreach x in array p_ids loop
    select * into v from public.out_invoices where id = x for update;
    ev := app.out_misa_eval(x);
    if not (ev->>'ok')::boolean then
      out := out || jsonb_build_object('invoice_id', x, 'code', ev->>'code', 'errors', ev->'errors'); continue; end if;
    if (ev->>'old')::boolean then
      out := out || jsonb_build_object('invoice_id', x, 'code', ev->>'code', 'need_delete', ev->'active'); continue; end if;
    v_ref := gen_random_uuid();
    select coalesce(max(lan), 0) + 1 into v_lan from public.out_misa where invoice_id = x;
    p := app.out_misa_payload(x, v_ref);
    if abs(((p->>'TotalAmountOC')::numeric) - app.out_inv_total(x)) > 0.5 then
      out := out || jsonb_build_object('invoice_id', x, 'code', v.code, 'errors', jsonb_build_array('Tổng dữ liệu gửi MISA lệch tổng phiếu — không gửi')); continue; end if;
    begin
      insert into public.out_misa(invoice_id, ref_id, lan, invoice_version, sale_id, payload, tien_hang, tien_thue, tong_tt)
      values (x, v_ref, v_lan, v.version, v.sale_id, p, (p->>'TotalSaleAmountOC')::numeric, (p->>'TotalVATAmountOC')::numeric, (p->>'TotalAmountOC')::numeric)
      returning id into v_hd;
    exception when unique_violation then
      out := out || jsonb_build_object('invoice_id', x, 'code', v.code, 'errors', jsonb_build_array('Phiếu đang được tạo nháp ở máy khác — tải lại để xem')); continue;
    end;
    out := out || jsonb_build_object('invoice_id', x, 'code', v.code, 'hd_id', v_hd, 'ref_id', v_ref, 'lan', v_lan, 'payload', p);
  end loop;
  return out;
end $$;
grant execute on function public.out_misa_claim(uuid[]) to authenticated;

-- Ghi kết quả tạo nháp. p_rows: [{hd_id, ok, loi_ma, loi_text, misa_tong_tt, misa_tien_thue}]
create or replace function public.out_misa_result(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; h public.out_misa; v public.out_invoices; n int := 0; v_khop boolean; mt numeric;
begin
  if not (app.is_acc() or app.is_service()) then raise exception 'Chỉ Kế toán / Admin'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    select * into h from public.out_misa where id = (r->>'hd_id')::uuid for update;
    if h.id is null or h.trang_thai not in ('dang_tao','da_tao') then continue; end if;
    select * into v from public.out_invoices where id = h.invoice_id;
    if coalesce((r->>'ok')::boolean, false) then
      mt := nullif(r->>'misa_tong_tt', '')::numeric;
      v_khop := case when mt is null then h.khop else abs(mt - h.tong_tt) < 0.5 and abs(coalesce(nullif(r->>'misa_tien_thue', '')::numeric, h.tien_thue) - h.tien_thue) < 0.5 end;
      update public.out_misa set trang_thai = 'da_tao', misa_tong_tt = coalesce(mt, misa_tong_tt), misa_tien_thue = coalesce(nullif(r->>'misa_tien_thue', '')::numeric, misa_tien_thue),
        khop = v_khop, loi_ma = case when v_khop is false then 'LechERP' else null end,
        loi_text = case when v_khop is false then 'MISA lưu tổng ' || mt || ', ERP ' || h.tong_tt || ' — xóa nháp này trên MISA rồi tạo lại' else null end,
        synced_at = now(), updated_at = now() where id = h.id;
      if h.trang_thai = 'dang_tao' then
        update public.out_invoices set misa_at = now(), misa_by = auth.uid(), updated_at = now() where id = v.id and v.status = 'cho_nhap';
        insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', 'Tạo nháp MISA bằng API lần ' || h.lan || case when v_khop is false then ' — MISA LỆCH TIỀN ERP' else '' end,
          jsonb_build_object('ref_id', h.ref_id, 'lan', h.lan, 'tong', h.tong_tt, 'misa_tong', mt));
      end if;
      if v_khop is false then perform app.notify_roles(array['ke_toan'], 'acc', 'Nháp MISA lệch tiền ERP: ' || v.code, 'MISA ' || mt || ' · ERP ' || h.tong_tt, '#/out?inv=' || v.id); end if;
    else
      update public.out_misa set trang_thai = 'loi', loi_ma = left(r->>'loi_ma', 200), loi_text = left(coalesce(r->>'loi_text', 'Lỗi không rõ'), 4000), updated_at = now() where id = h.id;
      insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', 'Tạo nháp MISA lỗi: ' || left(coalesce(r->>'loi_text', ''), 300), jsonb_build_object('ref_id', h.ref_id, 'lan', h.lan, 'loi_ma', r->>'loi_ma'));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_misa_result(jsonb) to authenticated;

-- Gắn PDF nháp (đã lưu Drive) cho nháp API → phiếu "Có nháp", báo sale (dùng lại out_file_attach)
create or replace function public.out_misa_file(p_hd uuid, p_drive_id text, p_name text, p_size_kb int) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare h public.out_misa; v public.out_invoices; res jsonb; fid uuid;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin'; end if;
  select * into h from public.out_misa where id = p_hd for update;
  if h.id is null or h.trang_thai <> 'da_tao' then raise exception 'Nháp MISA không còn ở trạng thái "đã tạo"'; end if;
  if h.khop is false then raise exception 'Nháp MISA lệch tiền ERP — không gửi sale'; end if;
  select * into v from public.out_invoices where id = h.invoice_id;
  if h.invoice_version < v.version then raise exception 'Nháp này là bản cũ (sale đã sửa phiếu) — tạo lại nháp'; end if;
  res := public.out_file_attach(h.invoice_id, 'nhap', p_drive_id, p_name, p_size_kb, h.tong_tt, v.tax_code);
  select id into fid from public.out_invoice_files where invoice_id = h.invoice_id and kind = 'nhap' order by version desc limit 1;
  update public.out_misa set file_id = fid, updated_at = now() where id = h.id;
  return res || jsonb_build_object('file_id', fid);
end $$;
grant execute on function public.out_misa_file(uuid, text, text, int) to authenticated;

-- Đã xóa nháp trên MISA (kế toán bấm Xóa / Tạo lại). Nháp đang dùng của phiếu bị xóa → phiếu quay về "chờ export"
create or replace function public.out_misa_deleted(p_hd uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare h public.out_misa; v public.out_invoices;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin'; end if;
  select * into h from public.out_misa where id = p_hd for update;
  if h.id is null then raise exception 'Không có nháp'; end if;
  if h.trang_thai = 'da_phat_hanh' then raise exception 'HĐ đã phát hành — không xóa được'; end if;
  if h.trang_thai = 'da_xoa' then return; end if;
  update public.out_misa set trang_thai = 'da_xoa', deleted_by = auth.uid(), deleted_at = now(), updated_at = now() where id = h.id;
  select * into v from public.out_invoices where id = h.invoice_id for update;
  insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', 'Xóa nháp MISA lần ' || h.lan || coalesce(' — ' || nullif(btrim(p_note), ''), ''), jsonb_build_object('ref_id', h.ref_id, 'lan', h.lan));
  if h.trang_thai = 'da_tao' and h.invoice_version >= v.version and v.status in ('da_nhap','xac_nhan_ky') then
    update public.out_invoices set status = 'cho_nhap', status_at = now(), status_by = auth.uid(), updated_at = now() where id = v.id;
    perform app.notify(v.sale_id, 'acc', 'Kế toán xóa nháp MISA, sẽ tạo lại: ' || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || nullif(btrim(p_note), ''), ''), '#/out?inv=' || v.id);
  end if;
  -- mốc export do API ghi → nháp API đã xóa thì bỏ mốc (phiếu lại tạo được bằng API hoặc xuất Excel)
  update public.out_invoices set misa_at = null, misa_by = null where id = v.id and status = 'cho_nhap' and misa_at is not null;
end $$;
grant execute on function public.out_misa_deleted(uuid, text) to authenticated;

-- Bỏ mốc "đã xuất Excel" (kế toán đã xóa nháp tay trên MISA) để chuyển sang tạo bằng API
create or replace function public.out_misa_clear_export(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin'; end if;
  with u as (update public.out_invoices i set misa_at = null, misa_by = null, updated_at = now()
              where i.id = any(p_ids) and i.status = 'cho_nhap' and i.misa_at is not null
                and not exists(select 1 from public.out_misa m where m.invoice_id = i.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh')) returning i.id)
  insert into public.out_events(invoice_id, action, note) select id, 'misa', 'Bỏ mốc export Excel (đã xóa nháp tay trên MISA)' from u;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.out_misa_clear_export(uuid[]) to authenticated;

-- Danh sách nháp cần dò trên MISA (đã tạo, hoặc đang tạo quá 10 phút)
create or replace function public.out_misa_sync_list(p_ids uuid[] default null, p_limit int default 500) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.is_acc() or app.is_service()) then raise exception 'Chỉ Kế toán / Admin'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('hd_id', m.id, 'ref_id', m.ref_id, 'trang_thai', m.trang_thai, 'invoice_id', m.invoice_id)), '[]')
    from (select * from public.out_misa m
           where (m.trang_thai = 'da_tao' or m.trang_thai = 'dang_tao' and m.created_at < now() - interval '10 minutes' or p_ids is not null and m.trang_thai = 'dang_tao')
             and (p_ids is null or m.invoice_id = any(p_ids))
           order by m.synced_at nulls first limit least(coalesce(p_limit, 500), 2000)) m);
end $$;
grant execute on function public.out_misa_sync_list(uuid[], int) to authenticated;

-- Áp dụng "đã ký" (dùng chung cho dò tự động) — như out_mark_signed nhưng không cần là kế toán
create or replace function app.out_sign_apply(p_id uuid, p_ma text, p_so_hd text) returns void
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; m text := upper(regexp_replace(coalesce(p_ma, ''), '[[:space:]]+', '', 'g'));
begin
  select * into v from public.out_invoices where id = p_id for update;
  if v.id is null or v.status in ('huy') then return; end if;
  if exists(select 1 from public.out_invoices where upper(ma_tra_cuu) = m and id <> p_id) then m := null; end if;
  update public.out_invoices set ma_tra_cuu = coalesce(nullif(m, ''), ma_tra_cuu), so_hd = coalesce(nullif(btrim(p_so_hd), ''), so_hd),
    status = case when nullif(m, '') is not null or ma_tra_cuu is not null then 'da_ky' else status end, ngay_hd = coalesce(ngay_hd, app.vn_today()),
    status_at = case when status <> 'da_ky' and (nullif(m, '') is not null or ma_tra_cuu is not null) then now() else status_at end, updated_at = now()
  where id = p_id;
  insert into public.out_events(invoice_id, action, note, data)
  values (p_id, 'status', 'MISA đã phát hành HĐ số ' || coalesce(p_so_hd, '?') || coalesce(' · mã tra cứu ' || nullif(m, ''), ' — chưa lấy được mã tra cứu') || ' (tự đối soát)',
          jsonb_build_object('from', v.status, 'to', case when nullif(m, '') is not null then 'da_ky' else v.status end, 'ma_tra_cuu', m, 'so_hd', p_so_hd, 'auto', true));
  if nullif(m, '') is not null and v.status <> 'da_ky' then
    perform app.notify(v.sale_id, 'acc', 'Đã ký HĐ: ' || v.code, coalesce(v.buyer_name, '') || ' — mã tra cứu ' || m || '. Bấm để xem HĐ.', '#/hd?inv=' || v.id);
  end if;
  if nullif(m, '') is null then
    perform app.notify_roles(array['ke_toan'], 'acc', 'MISA đã phát hành HĐ ' || coalesce(p_so_hd, '') || ' — nhập mã tra cứu: ' || v.code, coalesce(v.buyer_name, ''), '#/out?inv=' || v.id);
  end if;
  if v.status <> 'xac_nhan_ky' and v.status <> 'da_ky' then
    perform app.notify_roles(array['ke_toan'], 'acc', '⚠ HĐ ' || coalesce(p_so_hd, '') || ' phát hành khi sale chưa chốt: ' || v.code, coalesce(v.buyer_name, ''), '#/out?inv=' || v.id);
  end if;
end $$;
revoke all on function app.out_sign_apply(uuid, text, text) from public, anon;

-- Kết quả dò MISA (getlist). p_rows: [{hd_id, found, inv_no, ma_tra_cuu, misa_tong_tt, misa_tien_thue}]
create or replace function public.out_misa_sync_result(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; h public.out_misa; v public.out_invoices; n_pub int := 0; n_del int := 0; n_ok int := 0; so text; ma text; cfg jsonb;
begin
  if not (app.is_acc() or app.is_service()) then raise exception 'Chỉ Kế toán / Admin'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    select * into h from public.out_misa where id = (r->>'hd_id')::uuid for update;
    if h.id is null or h.trang_thai not in ('dang_tao','da_tao') then continue; end if;
    select * into v from public.out_invoices where id = h.invoice_id;
    so := nullif(btrim(r->>'inv_no'), ''); ma := nullif(upper(regexp_replace(coalesce(r->>'ma_tra_cuu', ''), '[[:space:]]+', '', 'g')), '');
    if ma is not null and ma !~ '^[A-Z0-9_-]{6,30}$' then ma := null; end if;
    if coalesce((r->>'found')::boolean, false) then
      if so is not null and so ~ '[0-9]' and so !~* 'chưa' then
        update public.out_misa set trang_thai = 'da_phat_hanh', so_hd = so, ma_tra_cuu = ma, phat_hanh_at = now(), synced_at = now(), updated_at = now() where id = h.id;
        if h.invoice_version >= v.version and v.status <> 'huy' then
          perform app.out_sign_apply(v.id, ma, so);
        else
          perform app.notify_roles(array['ke_toan','admin'], 'acc', '⚠ MISA phát hành NHÁP CŨ lần ' || h.lan || ' (HĐ ' || so || '): ' || v.code,
            'Phiếu đã ' || case when v.status = 'huy' then 'hủy' else 'sửa sau nháp này' end || ' — kiểm tra, xử lý điều chỉnh/thay thế trên MISA', '#/out?inv=' || v.id);
          insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', '⚠ MISA phát hành nháp cũ lần ' || h.lan || ', HĐ ' || so, jsonb_build_object('ref_id', h.ref_id, 'so_hd', so));
        end if;
        n_pub := n_pub + 1;
      else
        if h.trang_thai = 'dang_tao' then
          perform public.out_misa_result(jsonb_build_array(jsonb_build_object('hd_id', h.id, 'ok', true, 'misa_tong_tt', r->'misa_tong_tt', 'misa_tien_thue', r->'misa_tien_thue')));
        else
          update public.out_misa set synced_at = now(), misa_tong_tt = coalesce(nullif(r->>'misa_tong_tt', '')::numeric, misa_tong_tt) where id = h.id;
        end if;
        n_ok := n_ok + 1;
      end if;
    else
      if h.trang_thai = 'dang_tao' then
        update public.out_misa set trang_thai = 'loi', loi_ma = 'KhongCoTrenMISA', loi_text = 'Không có trên MISA (gửi chưa tới) — bấm tạo lại', synced_at = now(), updated_at = now() where id = h.id;
      else
        update public.out_misa set trang_thai = 'da_xoa', deleted_at = now(), synced_at = now(), loi_text = 'Không còn trên MISA (đã bị xóa trên web MISA)', updated_at = now() where id = h.id;
        insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', 'Nháp MISA lần ' || h.lan || ' không còn trên MISA (xóa trên web)', jsonb_build_object('ref_id', h.ref_id));
        perform app.notify_roles(array['ke_toan'], 'acc', 'Nháp MISA bị xóa trên web MISA: ' || v.code, coalesce(v.buyer_name, '') || ' — tạo lại nếu cần', '#/out?inv=' || v.id);
        n_del := n_del + 1;
      end if;
    end if;
  end loop;
  select value into cfg from public.settings where key = 'accounting';
  update public.settings set value = jsonb_set(value, '{misa}', coalesce(value->'misa', '{}') || jsonb_build_object('last_sync_at', now(), 'last_sync_pub', n_pub))
   where key = 'accounting';
  return jsonb_build_object('phat_hanh', n_pub, 'con_nhap', n_ok, 'bi_xoa', n_del);
end $$;
grant execute on function public.out_misa_sync_result(jsonb) to authenticated;

-- ---------- Hàm chỉ cho máy chủ (service_role) ----------
create or replace function public.misa_token_get() returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('token', token, 'got_at', got_at) from app.misa_token where id = 1
$$;
create or replace function public.misa_token_put(p_token text) returns void language sql security definer set search_path = public, app as $$
  insert into app.misa_token(id, token, got_at) values (1, p_token, now()) on conflict (id) do update set token = excluded.token, got_at = excluded.got_at
$$;
create or replace function public.misa_cron_ok(p_key text) returns boolean language sql stable security definer set search_path = public, app as $$
  select coalesce(p_key, '') <> '' and exists(select 1 from app.secrets where key = 'misa_cron_key' and value = p_key)
$$;
revoke all on function public.misa_token_get() from public, anon, authenticated;
revoke all on function public.misa_token_put(text) from public, anon, authenticated;
revoke all on function public.misa_cron_ok(text) from public, anon, authenticated;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'service_role') then
    grant select on public.out_misa to service_role;
    grant execute on function public.misa_token_get() to service_role;
    grant execute on function public.misa_token_put(text) to service_role;
    grant execute on function public.misa_cron_ok(text) to service_role;
    grant execute on function public.out_misa_result(jsonb) to service_role;
    grant execute on function public.out_misa_sync_list(uuid[], int) to service_role;
    grant execute on function public.out_misa_sync_result(jsonb) to service_role;
  end if;
end $$;

-- ---------- Tự dò MISA 15 phút/lần (7:00–21:00), chỉ khi đã bật MISA ----------
insert into app.secrets(key, value) values ('misa_cron_key', encode(gen_random_bytes(24), 'hex')) on conflict (key) do nothing;
create or replace function app.job_misa_sync() returns void language plpgsql security definer set search_path = public, app, extensions as $$
declare m jsonb := app.misa_cfg(); v_url text := replace(coalesce(app.setting('push')->>'url', ''), '/functions/v1/push', '/functions/v1/misa'); h int := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh');
begin
  if not coalesce((m->>'enabled')::boolean, false) or not coalesce((m->>'auto_sync')::boolean, true) or v_url not like '%/functions/v1/misa' or h < 7 or h > 21 then return; end if;
  if not exists(select 1 from public.out_misa where trang_thai in ('dang_tao','da_tao')) then return; end if;
  if not exists(select 1 from pg_extension where extname = 'pg_net') and not exists(select 1 from pg_namespace where nspname = 'net') then return; end if;
  begin
    execute 'select net.http_post(url := $1, body := $2, headers := $3)'
      using v_url, jsonb_build_object('action', 'sync', 'cron', true),
            jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', (select value from app.secrets where key = 'misa_cron_key'));
  exception when others then null; end;
end $$;
select cron.schedule('nt_misa_sync', '*/15 * * * *', 'select app.job_misa_sync()');

-- ---------- Không hủy phiếu khi còn nháp sống trên MISA ----------
create or replace function app.trg_out_misa_guard() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'huy' and old.status <> 'huy' and exists(select 1 from public.out_misa m where m.invoice_id = new.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh')) then
    raise exception 'Phiếu % đang có nháp trên MISA (tạo bằng API) — kế toán xóa nháp MISA trước khi hủy', new.code;
  end if;
  return new;
end $$;
drop trigger if exists out_misa_guard on public.out_invoices;
create trigger out_misa_guard before update of status on public.out_invoices for each row execute function app.trg_out_misa_guard();

-- ---------- Danh sách phiếu: thêm tình trạng MISA (API), bộ lọc + khoảng ngày ----------
create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_flag text := nullif(p->>'flag', ''); v_next text := nullif(p->>'next', ''); v_sort text := coalesce(nullif(p->>'sort', ''), 'at'); v_dir text := coalesce(nullif(p->>'dir', ''), 'desc'); v_sua int; v_misa int; v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_scope(); v_hd text := nullif(ltrim(btrim(p->>'hd'), '0'), '');
        v_from date := nullif(p->>'from', '')::date; v_to date := nullif(p->>'to', '')::date; mf jsonb;
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
       and (v_from is null or i.created_at >= v_from) and (v_to is null or i.created_at < v_to + 1)
       and (v_hd is null or exists(select 1 from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = i.id and app.hd_of(t.so_hd_vao, t.ma_hang) = v_hd)) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  select count(*) filter (where i.sua_sau_nhap), count(*) filter (where i.misa_at is null),
         jsonb_build_object(
           'api_san_sang', count(*) filter (where i.misa_at is null and mm.id is null),
           'api_cu', count(*) filter (where mm.trang_thai = 'da_tao' and mm.invoice_version < i.version),
           'api_loi', count(*) filter (where ml.trang_thai = 'loi' or mm.khop is false),
           'api_co', count(*) filter (where mm.trang_thai in ('dang_tao','da_tao') and mm.invoice_version >= i.version),
           'tay', count(*) filter (where i.misa_at is not null and mm.id is null))
    into v_sua, v_misa, mf
    from public.out_invoices i
    left join lateral (select m.id, m.trang_thai, m.invoice_version, m.khop from public.out_misa m where m.invoice_id = i.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh') limit 1) mm on true
    left join lateral (select m.trang_thai from public.out_misa m where m.invoice_id = i.id order by m.lan desc limit 1) ml on true
   where i.status = 'cho_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale);
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa, 'mf', mf); end if;
  with base as materialized (select v.*, ml.misa from public.out_invoices v
                               left join lateral (select jsonb_build_object('hd_id', m.id, 'lan', m.lan, 'st', m.trang_thai, 'khop', m.khop, 'cu', m.invoice_version < v.version and m.trang_thai = 'da_tao',
                                   'so_hd', m.so_hd, 'loi', left(m.loi_text, 300), 'pdf', m.file_id is not null, 'at', m.updated_at) misa
                                   from public.out_misa m where m.invoice_id = v.id order by m.lan desc limit 1) ml on true
                              where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_from is null or v.created_at >= v_from) and (v_to is null or v.created_at < v_to + 1)
                               and (v_hd is null or exists(select 1 from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = v.id and app.hd_of(t.so_hd_vao, t.ma_hang) = v_hd))
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)
                               and (v_flag is null or v_flag = 'sua' and v.sua_sau_nhap or v_flag = 'misa_chua' and v.misa_at is null
                                    or v_flag = 'api_san_sang' and v.misa_at is null and not exists(select 1 from public.out_misa m where m.invoice_id = v.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh'))
                                    or v_flag = 'api_cu' and exists(select 1 from public.out_misa m where m.invoice_id = v.id and m.trang_thai = 'da_tao' and m.invoice_version < v.version)
                                    or v_flag = 'api_loi' and (ml.misa->>'st' = 'loi' or ml.misa->>'khop' = 'false')
                                    or v_flag = 'api_co' and exists(select 1 from public.out_misa m where m.invoice_id = v.id and m.trang_thai in ('dang_tao','da_tao') and m.invoice_version >= v.version)
                                    or v_flag = 'tay' and v.misa_at is not null and not exists(select 1 from public.out_misa m where m.invoice_id = v.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh')))),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim,
               string_agg(distinct t.md, ', ') mds, bool_or(coalesce(l.vat, t.vat) >= 0.095) vat10,
               string_agg(distinct t.ma_hang, ', ') mas, string_agg(distinct app.hd_of(t.so_hd_vao, t.ma_hang), ', ') hds
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia, a.mds, coalesce(a.vat10, false) vat10, a.mas, a.hds,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where (v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%')
           and (v_next is null or b.status = 'da_nhap' and fn.version is not null and (v_next = 'chua_gui' and fn.sent_at is null or v_next = 'cho_khach' and fn.sent_at is not null))),
  o as (select f.*, row_number() over (order by
          case when v_dir = 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end asc nulls last,
          case when v_dir <> 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end desc nulls last,
          case when v_sort = 'tien' and v_dir = 'asc' then f.tien_hang + f.tien_thue end asc nulls last,
          case when v_sort = 'tien' and v_dir <> 'asc' then f.tien_hang + f.tien_thue end desc nulls last,
          case when v_dir = 'asc' and v_sort = 'at' then f.status_at end asc, f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa, 'mf', mf);
end $$;

reset search_path;


-- >>>>> supabase/migrations/0039_v32.sql
-- =====================================================================
-- 0039 · Bản 32 (06/11/2026): file xe lệch cột ID ĐƠN ↔ USERNAME, thiếu username khách
--  · Dòng đối soát đổi ĐƠN hoặc USERNAME (nạp lại file xe, kế toán điền username) → dòng sổ HĐ đầu vào theo ngay,
--    tìm lại khách (trước đây chỉ theo đơn/sale/giá, username cũ sai bị giữ lại mãi)
--  · Nạp lại file xe mà file thiếu username → giữ username đã có (trừ username trùng số đơn = lệch cột)
--  · acc_lines_set_kh: kế toán điền username cho dòng đối soát (màn nạp HĐ chính thức)
--  · out_items_fix_kh: sửa ID đơn / username dòng sẵn sàng xuất — kế toán, hoặc sale / CSKH / trưởng nhóm trong phạm vi
--  · Sửa dữ liệu cũ: dòng đối soát có mã khai báo MDxxxx-n mà ID đơn trống / khác đơn, username = chính số đơn
--    → lấy đơn theo mã khai báo, bỏ username sai (username đúng điền lại sau)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 32');

-- Dòng sổ đã lập phiếu (phiếu chưa hủy) → không tự đổi đơn/khách
create or replace function app.out_item_has_inv(p_id uuid) returns boolean language sql stable security definer set search_path = public, app as $$
  select exists(select 1 from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id where l.item_id = p_id and i.status <> 'huy')
$$;
-- Username là chính số đơn (2689 / MD2689 của đơn MD2689) → dấu hiệu lệch cột
create or replace function app.kh_la_don(p_kh text, p_md text) returns boolean language sql immutable as $$
  select coalesce(p_kh, '') <> '' and coalesce(p_md, '') <> '' and btrim(p_kh) ~* ('^(md)?\s*0*' || regexp_replace(p_md, '\D', '', 'g') || '$')
$$;

-- Dòng đối soát đổi MD / username / sale / giá khách / khách → dòng sổ đầu ra lấy theo (trừ dòng kế toán sửa tay)
create or replace function app.trg_acc_line_out() returns trigger language plpgsql security definer set search_path = public, app as $$
declare t record;
begin
  if new.is_test then return null; end if;
  -- Bản 32: đổi đơn hoặc username → dòng sổ nhận đơn + username mới, tìm lại khách (dòng đã lập phiếu thì giữ nguyên)
  if tg_op = 'UPDATE' and (old.md is distinct from new.md or old.ma_kh is distinct from new.ma_kh) then
    for t in select o.id, o.md, o.username from public.out_items o where o.acc_line_id = new.id and coalesce(o.match_src, '') <> 'tay' and not app.out_item_has_inv(o.id) loop
      update public.out_items set md = coalesce(new.md, md), username = nullif(new.ma_kh, ''), customer_id = new.customer_id, updated_at = now() where id = t.id;
      perform app.out_item_match(t.id);
      insert into public.out_events(item_id, action, data) values (t.id, 'doi_don_kh',
        jsonb_build_object('md', new.md, 'username', new.ma_kh, 'md_cu', t.md, 'username_cu', t.username));
    end loop;
  end if;
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
create trigger acc_line_out after insert or update of md, ma_kh, sale_id, gia_khach, customer_id on public.acc_lines for each row execute function app.trg_acc_line_out();

-- Nạp lại file xe: giữ username đã có khi file mới để trống (không giữ username sai = số đơn)
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
    ma_kh = case when coalesce(n.ma_kh, '') = '' and not app.kh_la_don(p_old.ma_kh, coalesce(n.md, p_old.md)) and coalesce(n.md, p_old.md) is not distinct from p_old.md then p_old.ma_kh else n.ma_kh end,
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

-- Kế toán điền username cho dòng đối soát (màn nạp HĐ chính thức) — dòng sổ theo qua trigger
create or replace function public.acc_lines_set_kh(p_ids uuid[], p_username text) returns int
language plpgsql security definer set search_path = public, app as $$
declare v_u text := app.norm_username(nullif(btrim(p_username), '')); n int; r record;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if v_u is null then raise exception 'Nhập username khách'; end if;
  for r in select truck_id, md, array_agg(ma_dong order by ma_dong) mas from public.acc_lines where id = any(p_ids) and ma_kh is distinct from v_u group by truck_id, md loop
    insert into public.acc_events(truck_id, action, note, data) values (r.truck_id, 'set_kh', r.md, jsonb_build_object('username', v_u, 'ma', r.mas));
  end loop;
  update public.acc_lines set ma_kh = v_u, updated_at = now() where id = any(p_ids) and ma_kh is distinct from v_u;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.acc_lines_set_kh(uuid[], text) to authenticated;

-- Sửa ID đơn / username dòng sẵn sàng xuất: kế toán, hoặc sale / CSKH / trưởng nhóm trong phạm vi; không đổi sale, không mở khóa dòng lệch
create or replace function public.out_items_fix_kh(p_ids uuid[], p_md text, p_username text) returns int
language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; v_md text := app.norm_md(nullif(btrim(p_md), '')); v_u text := app.norm_username(nullif(btrim(p_username), '')); n int := 0;
begin
  if v_md is null and v_u is null then raise exception 'Nhập ID đơn hoặc username khách'; end if;
  if app.kh_la_don(v_u, v_md) then raise exception 'Username đang trùng số đơn % — nhập username thật của khách', v_md; end if;
  for t in select * from public.out_items where id = any(p_ids) order by ma_hang for update loop
    if not (app.is_acc() or app.in_tree(t.sale_id)) then raise exception 'Dòng % không thuộc phạm vi của bạn', t.ma_hang; end if;
    if app.out_item_has_inv(t.id) then raise exception 'Dòng % đã lập phiếu xuất HĐ — báo kế toán', t.ma_hang; end if;
    update public.out_items set md = coalesce(v_md, md), username = coalesce(v_u, username),
      customer_id = case when v_u is not null and v_u is distinct from t.username then null else customer_id end, updated_at = now(), updated_by = auth.uid()
     where id = t.id;
    -- dòng đối soát cùng nguồn sửa theo, để nạp lại file / HĐ không đè lại giá trị sai
    if t.acc_line_id is not null then
      update public.acc_lines set md = coalesce(v_md, md), ma_kh = coalesce(v_u, ma_kh), updated_at = now()
       where id = t.acc_line_id and (md is distinct from coalesce(v_md, md) or ma_kh is distinct from coalesce(v_u, ma_kh));
    end if;
    perform app.out_item_match(t.id);
    insert into public.out_events(item_id, action, data) values (t.id, 'fix_kh', jsonb_build_object('md', v_md, 'username', v_u, 'md_cu', t.md, 'username_cu', t.username));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Không tìm thấy dòng'; end if;
  return n;
end $$;
grant execute on function public.out_items_fix_kh(uuid[], text, text) to authenticated;

-- ---------- Sửa dữ liệu đã nạp bằng file xe lệch cột ----------
-- Dòng đối soát: mã khai báo MDxxxx-n mà ID đơn trống / khác đơn, và username trống hoặc trùng số đơn → đơn theo mã khai báo, bỏ username sai
update public.acc_lines l set md = x.md_kb, ma_kh = case when app.kh_la_don(l.ma_kh, x.md_kb) then null else l.ma_kh end, updated_at = now()
  from (select id, 'MD' || (substring(ma_dong from '^MD0*(\d+)-\d+$'))::bigint md_kb from public.acc_lines where ma_dong ~ '^MD\d+-\d+$') x
 where x.id = l.id and not l.is_test and l.md is distinct from x.md_kb
   and (l.md is null or coalesce(l.ma_kh, '') = '' or app.kh_la_don(l.ma_kh, x.md_kb));
-- Dòng đối soát chỉ còn username = số đơn
update public.acc_lines set ma_kh = null, updated_at = now() where not is_test and app.kh_la_don(ma_kh, md);

reset search_path;


-- >>>>> supabase/migrations/0040_v33.sql
-- =====================================================================
-- 0040 · Bản 33 (06/11/2026): Menu "Pháp nhân" — nạp Excel, theo dõi, sửa trực tiếp, chuẩn hóa pháp nhân nhận HĐ
--  · Pháp nhân vẫn gắn khách theo USERNAME; 1 username có nhiều pháp nhân, 1 cái ★ mặc định
--  · Kế toán / Admin / BGĐ: thêm, sửa, xóa, đặt mặc định, đổi username (tự gắn lại khách)
--  · Phiếu lập nhanh theo ID đơn: chọn pháp nhân của khách (theo khách ERP hoặc username chưa gắn khách)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 33');

alter table public.out_buyers add column if not exists updated_at timestamptz;
alter table public.out_buyers add column if not exists updated_by uuid references public.profiles(id);

-- Danh sách pháp nhân + cờ chuẩn hóa. p: {q, flag, sale, offset, limit}
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
         where (v_q is null or concat_ws(' ', name, tax_code, uname, address, email, kh_name, kh_code, sys_code, note) ilike '%' || v_q || '%')
           and (v_sale is null or sale_id = v_sale)
           and (v_flag is null or v_flag = 'chua_gan' and customer_id is null or v_flag = 'mst_sai' and mst_sai or v_flag = 'thieu_dc' and thieu_dc
                or v_flag = 'trung_mst' and trung_mst or v_flag = 'khong_md' and khong_md)),
  o as (select f.*, row_number() over (order by lower(coalesce(uname, 'zzzz')), customer_id, is_default desc, created_at) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(jsonb_build_object('id', id, 'customer_id', customer_id, 'username', uname, 'own_username', username, 'name', name, 'tax_code', tax_code, 'address', address,
           'email', email, 'note', note, 'is_default', is_default, 'kh_name', kh_name, 'kh_code', coalesce(sys_code, kh_code), 'sale_id', sale_id, 'mst_sai', mst_sai, 'thieu_dc', thieu_dc,
           'trung_mst', trung_mst, 'khong_md', khong_md, 'so_phieu', so_phieu, 'created_at', created_at, 'updated_at', updated_at, 'updated_by', updated_by) order by rn)
           filter (where rn > v_off and rn <= v_off + v_lim), '[]')
    into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c);
end $$;
grant execute on function public.out_buyers_page(jsonb) to authenticated;

-- Thêm / sửa 1 pháp nhân. p: {username, name, tax_code, address, email, note, is_default}
create or replace function public.out_buyer_save(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare b public.out_buyers; v_user text := app.norm_username(nullif(btrim(p->>'username'), '')); v_c uuid; v_mst text := nullif(regexp_replace(coalesce(p->>'tax_code', ''), '\s', '', 'g'), '');
        v_name text := nullif(regexp_replace(btrim(coalesce(p->>'name', '')), '\s+', ' ', 'g'), ''); v_id uuid := p_id;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ sửa pháp nhân'; end if;
  if v_name is null then raise exception 'Nhập tên đơn vị'; end if;
  if v_mst is null then raise exception 'Nhập MST / CCCD'; end if;
  if not app.mst_ok(v_mst) then raise exception 'MST "%" sai dạng — 10 số, 10-3 số hoặc CCCD 12 số', v_mst; end if;
  if coalesce(btrim(p->>'email'), '') <> '' and btrim(p->>'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Email "%" sai dạng', p->>'email'; end if;
  if v_id is not null then select * into b from public.out_buyers where id = v_id for update; if b.id is null then raise exception 'Không thấy pháp nhân'; end if; end if;
  -- username → khách ERP; không gõ username thì giữ khách đang gắn
  if v_user is not null then
    select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(v_user) or upper(btrim(sys_code)) = upper(v_user)) order by created_at limit 1;
  elsif b.id is not null then v_c := b.customer_id; v_user := b.username;
  end if;
  if exists(select 1 from public.out_buyers x where x.id is distinct from v_id and btrim(x.tax_code) = v_mst
              and (v_c is not null and x.customer_id = v_c or v_c is null and x.customer_id is null and lower(coalesce(x.username, '')) = lower(coalesce(v_user, '')))) then
    raise exception 'Username % đã có pháp nhân MST % — sửa dòng đó thay vì thêm mới', coalesce(v_user, '(trống)'), v_mst;
  end if;
  if v_id is null then
    insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note, updated_at, updated_by)
    values (v_c, v_user, v_name, v_mst, nullif(btrim(p->>'address'), ''), nullif(btrim(p->>'email'), ''), coalesce(nullif(btrim(p->>'note'), ''), 'Nhập tay'), now(), auth.uid())
    returning id into v_id;
  else
    update public.out_buyers set customer_id = v_c, username = v_user, name = v_name, tax_code = v_mst, address = nullif(btrim(p->>'address'), ''), email = nullif(btrim(p->>'email'), ''),
      note = nullif(btrim(p->>'note'), ''), is_default = case when v_c is distinct from b.customer_id then false else is_default end, updated_at = now(), updated_by = auth.uid()
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

create or replace function public.out_buyer_delete(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int; cs uuid[];
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ xóa pháp nhân'; end if;
  select array_agg(distinct customer_id) into cs from public.out_buyers where id = any(p_ids) and customer_id is not null;
  delete from public.out_buyers where id = any(p_ids);
  get diagnostics n = row_count;
  -- khách mất pháp nhân mặc định → pháp nhân mới nhất còn lại làm mặc định
  update public.out_buyers b set is_default = true
   where b.id in (select distinct on (customer_id) id from public.out_buyers where customer_id = any(coalesce(cs, '{}')) order by customer_id, created_at desc)
     and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default);
  return n;
end $$;
grant execute on function public.out_buyer_delete(uuid[]) to authenticated;

-- Pháp nhân để chọn khi lập phiếu: theo khách ERP hoặc theo username chưa gắn khách
create or replace function public.out_buyers_for(p_customers uuid[], p_usernames text[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'customer_id', b.customer_id, 'username', b.username, 'name', b.name, 'tax_code', b.tax_code, 'address', b.address,
            'email', b.email, 'is_default', b.is_default) order by b.is_default desc, b.created_at desc), '[]')
    from public.out_buyers b
   where (b.customer_id = any(coalesce(p_customers, '{}')) and (app.is_acc() or exists(select 1 from public.customers c where c.id = b.customer_id and app.in_tree(c.owner_id))))
      or (b.customer_id is null and b.username is not null and lower(b.username) = any(select lower(app.norm_username(x)) from unnest(coalesce(p_usernames, '{}')) x)));
end $$;
grant execute on function public.out_buyers_for(uuid[], text[]) to authenticated;

reset search_path;
