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
