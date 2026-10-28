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
