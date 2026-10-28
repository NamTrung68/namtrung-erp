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
