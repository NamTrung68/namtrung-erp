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
