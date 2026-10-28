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
