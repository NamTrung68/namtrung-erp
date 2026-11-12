-- =====================================================================
-- 0053 · Bản 45 (13/11/2026) — Người duyệt sửa LOẠI đơn nghỉ trước khi duyệt
--  Nhân sự chọn nhầm loại (VD "Việc riêng có lương" thay vì "Nghỉ phép năm") → quản lý / HCNS bấm "Sửa loại" rồi Duyệt,
--  không phải bắt tạo lại. Chỉ sửa khi đơn còn CHỜ DUYỆT (phép năm trừ sổ lúc duyệt → không lệch sổ phép).
--  Đơn theo giờ ↔ theo ngày không đổi qua lại được (khác cách nhập) — trường hợp này nhờ nhân sự tạo lại.
-- =====================================================================
set search_path = public, app, extensions;

create or replace function public.leave_change_type(p_id uuid, p_type text, p_note text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare r public.leave_requests; lt_old record; lt record; v_avail numeric; h_old boolean; h_new boolean;
begin
  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'Không tìm thấy đơn'; end if;
  if r.status <> 'cho_duyet' then raise exception 'Chỉ sửa loại khi đơn còn chờ duyệt'; end if;
  if not (app.can_approve(r.profile_id) or (app.has_role('hcns', 'admin', 'bgd') and r.profile_id <> auth.uid())) then raise exception 'Bạn không có quyền duyệt đơn này'; end if;
  if r.leave_type = p_type then return; end if;
  select * into lt from public.lookups where category = 'leave_type' and code = p_type and active;
  if lt.code is null then raise exception 'Loại đơn không hợp lệ'; end if;
  select * into lt_old from public.lookups where category = 'leave_type' and code = r.leave_type;
  h_old := r.part = 'hours'; h_new := coalesce((lt.extra->>'hours')::boolean, false) or (h_old and coalesce((lt.extra->>'work')::boolean, false));
  if h_old <> h_new then raise exception 'Không đổi được giữa đơn theo giờ và đơn theo ngày / buổi — nhờ nhân sự tạo lại đơn'; end if;
  if p_type = 'phep_nam' then
    v_avail := (public.leave_balance(r.profile_id, extract(year from r.start_date)::int)->>'available')::numeric;
    if v_avail < r.days then raise exception 'Phép năm còn % ngày, không đủ cho % ngày', v_avail, r.days; end if;
  end if;
  update public.leave_requests set leave_type = p_type,
    late_notice = (lt.extra ? 'notice_days') and r.created_at::date + 0 > r.start_date - (lt.extra->>'notice_days')::int,
    decision_note = trim(both ' ·' from coalesce(r.decision_note, '') || ' · Sửa loại: ' || coalesce(lt_old.label, r.leave_type) || ' → ' || lt.label || coalesce(' (' || nullif(btrim(p_note), '') || ')', ''))
  where id = p_id;
  perform app.log('LEAVE_TYPE', 'leave_requests', p_id::text, jsonb_build_object('from', r.leave_type, 'to', p_type, 'note', p_note));
  perform app.notify(r.profile_id, 'approval', 'Đơn nghỉ ' || to_char(r.start_date, 'DD/MM') || ' được sửa loại: ' || lt.label,
    'Người duyệt đổi từ "' || coalesce(lt_old.label, r.leave_type) || '"' || coalesce(' — ' || nullif(btrim(p_note), ''), ''), '#/hr/leave');
end $$;
grant execute on function public.leave_change_type(uuid, text, text) to authenticated;

create or replace function public.decide_request(p_table text, p_id uuid, p_approve boolean, p_note text default null, p_in time default null, p_out time default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare v_owner uuid; v_status text; v_lock boolean; v_kind text; v_date date; v_has_in boolean; v_req time;
begin
  if p_table = 'leave' then
    select profile_id, status into v_owner, v_status from public.leave_requests where id = p_id for update;
  elsif p_table = 'attendance' then
    select profile_id, status, kind, work_date, req_time into v_owner, v_status, v_kind, v_date, v_req from public.attendance_requests where id = p_id for update;
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
  -- Bản 37: quên chấm vào → giờ vào = giờ người duyệt chốt (mặc định giờ nhân viên khai); quên chấm về → giờ ra
  if p_table = 'attendance' and p_approve and v_kind = 'quen_cham_vao' then
    p_in := coalesce(p_in, v_req); p_out := null;
    if p_in is null then raise exception 'Nhập giờ vào làm để duyệt'; end if;
  elsif p_table = 'attendance' and p_approve and v_kind = 'quen_cham_ra' then
    p_out := coalesce(p_out, v_req); p_in := null;
    if p_out is null then raise exception 'Nhập giờ về để duyệt'; end if;
  end if;
  if p_table = 'leave' then
    -- Bản 45: giữ ghi chú "Sửa loại" của người duyệt, nối thêm ghi chú lúc duyệt
    update public.leave_requests set status = case when p_approve then 'da_duyet' else 'tu_choi' end, decided_by = auth.uid(), decided_at = now(),
      decision_note = nullif(concat_ws(' · ', nullif(btrim(decision_note), ''), nullif(btrim(p_note), '')), '') where id = p_id;
  else
    update public.attendance_requests set status = case when p_approve then 'da_duyet' else 'tu_choi' end, decided_by = auth.uid(), decided_at = now(), decision_note = p_note,
      confirm_in = case when p_approve then p_in end, confirm_out = case when p_approve then p_out end where id = p_id;
  end if;
  perform app.log(case when p_approve then 'APPROVE' else 'REJECT' end, p_table || '_requests', p_id::text, jsonb_build_object('note', p_note, 'in', p_in, 'out', p_out));
end $$;

reset search_path;
