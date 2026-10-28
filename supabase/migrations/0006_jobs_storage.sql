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
