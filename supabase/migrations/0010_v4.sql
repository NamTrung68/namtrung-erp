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
