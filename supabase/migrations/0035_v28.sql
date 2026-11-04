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
