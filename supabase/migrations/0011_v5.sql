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
