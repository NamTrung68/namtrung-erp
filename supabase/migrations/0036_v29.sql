-- =====================================================================
-- 0036 · Bản 29 (05/11/2026)
--  1. CSKH (không kiêm sale / quản lý) KHÔNG được truy cập: Hỗ trợ khách, Báo cáo ngày, Báo cáo và KPI, Bảng Phong Thần
--  2. Hóa đơn của tôi: CSKH thấy hóa đơn + hàng sẵn sàng xuất của các sale mình hỗ trợ
--  3. Hóa đơn: lọc theo số HĐ đầu vào APT; trả mã hàng (HH00044-2153-2026) + số HĐ để hiện ngay trên danh sách
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 29');

-- CSKH thuần: có vai trò CSKH, không kiêm sale / trưởng nhóm / trưởng phòng / quản lý / admin
create or replace function app.is_cskh_only() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists(select 1 from public.profiles p where p.id = auth.uid() and 'cskh' = any(p.roles)
                and not p.roles && array['admin','bgd','sale','tn_kd','tp_kd','ke_toan','hcns'])
     and not exists(select 1 from public.profiles x where x.manager_id = auth.uid() and x.status = 'active')
$$;

-- Số HĐ đầu vào của 1 dòng: cột số HĐ, thiếu thì lấy từ mã hàng HH00044-2153-2026 → 2153
create or replace function app.hd_of(p_so text, p_ma text) returns text language sql immutable as $$
  select coalesce(nullif(ltrim(btrim(p_so), '0'), ''), substring(p_ma from '^[A-Za-z]+[0-9]+-0*([0-9]+)-[0-9]{4}'))
$$;


-- 1. Chặn CSKH: KPI, Bảng Phong Thần (leaderboard gọi kpi_report), báo cáo, hỗ trợ khách
create or replace function public.kpi_report(p_from date, p_to date, p_all boolean default false)
returns table(profile_id uuid, full_name text, job_level text, is_new boolean, metrics jsonb, score numeric, grade text)
language plpgsql stable security definer set search_path = public, app as $$
declare cfg jsonb := coalesce(app.setting('kpi'), '{}'); days int := greatest(app.kpi_days(p_from, least(p_to, app.vn_today())), 1);
        t0 timestamptz := (p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'); t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh');
begin
  if app.is_cskh_only() then return; end if; -- bản 29: CSKH không xem KPI / Bảng Phong Thần
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

create or replace function public.crm_report(p_kind text, p_from date, p_to date, p_sale uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare tree uuid[] := case when p_sale is not null and app.in_tree(p_sale) then array[p_sale] else app.my_tree() end;
        t0 timestamptz := (p_from::timestamp at time zone 'Asia/Ho_Chi_Minh'); t1 timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Ho_Chi_Minh');
        adm boolean := app.is_admin() and p_sale is null;
begin
  if app.is_cskh_only() then raise exception 'CSKH không xem báo cáo kinh doanh'; end if;
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

create or replace function public.support_customer(p_req uuid)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare r public.support_requests; c public.customers; res jsonb;
begin
  if app.is_cskh_only() then raise exception 'CSKH không dùng mục Hỗ trợ khách'; end if;
  select * into r from public.support_requests where id = p_req;
  if r.id is null or r.customer_id is null then return null; end if;
  if not (r.requester_id = auth.uid() or r.assignee_id = auth.uid() or app.is_admin() or app.in_tree(r.requester_id)
          or r.org_unit_id = (select org_unit_id from public.profiles where id = auth.uid())) then
    raise exception 'Không có quyền xem yêu cầu này';
  end if;
  select * into c from public.customers where id = r.customer_id;
  res := jsonb_build_object(
    'id', c.id, 'code', c.code, 'contact_name', c.contact_name, 'company_name', c.company_name, 'position', c.position,
    'phone', c.phone, 'zalo', c.zalo, 'email', c.email, 'tax_code', c.tax_code, 'province', c.province, 'address', c.address,
    'customer_type', c.customer_type, 'industry', c.industry, 'goods', c.goods, 'import_method', c.import_method,
    'current_provider', c.current_provider, 'monthly_value', c.monthly_value, 'stage', c.stage, 'temperature', c.temperature,
    'next_care_date', c.next_care_date, 'care_count', c.care_count, 'quote_count', c.quote_count, 'order_count', c.order_count,
    'note', c.note, 'owner_id', c.owner_id, 'owner_name', app.name_of(c.owner_id), 'services', c.services, 'goods_traits', c.goods_traits,
    'can_open', app.is_admin() or app.in_tree(c.owner_id),
    'care', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select cl.id, cl.created_at, cl.channel, cl.purpose, cl.result, cl.is_connected, cl.content, cl.stage_after, cl.temperature_after,
               cl.next_care_date, cl.quotation_code, app.name_of(cl.sale_id) sale_name
        from public.care_logs cl where cl.customer_id = c.id order by cl.created_at desc limit 30) x), '[]'),
    'quotes', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select q.id, q.code, q.version, q.status, q.total_after_vat, q.created_at, q.order_code
        from public.quotations q where q.customer_id = c.id and q.status <> 'da_thay_the' order by q.created_at desc limit 10) x), '[]'));
  return res;
end $$;

drop policy if exists dr_read on public.daily_reports;
create policy dr_read on public.daily_reports for select to authenticated using (sale_id = auth.uid() or app.in_mgmt(sale_id) or app.is_admin());


-- 2. Hóa đơn của tôi: CSKH thấy dữ liệu của sale được hỗ trợ
create or replace function app.out_items_scope(p_mode text) returns setof public.out_items
language plpgsql stable security definer set search_path = public, app as $$
declare v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_scope(); v_sale boolean := app.has_role('sale','tn_kd','tp_kd');
begin
  if p_mode = 'acc' then
    if not v_acc then return; end if;
    return query select * from public.out_items;
  elsif p_mode = 'free' then
    if not (v_acc or v_sale) then return; end if;
    return query select * from public.out_items where sale_id is null;
  else
    return query select * from public.out_items where sale_id = any(v_tree);
  end if;
end $$;

create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_flag text := nullif(p->>'flag', ''); v_next text := nullif(p->>'next', ''); v_sort text := coalesce(nullif(p->>'sort', ''), 'at'); v_dir text := coalesce(nullif(p->>'dir', ''), 'desc'); v_sua int; v_misa int; v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_scope(); v_hd text := nullif(ltrim(btrim(p->>'hd'), '0'), '');
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
       and (v_hd is null or exists(select 1 from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = i.id and app.hd_of(t.so_hd_vao, t.ma_hang) = v_hd)) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  select count(*) filter (where i.sua_sau_nhap), count(*) filter (where i.misa_at is null) into v_sua, v_misa from public.out_invoices i
   where i.status = 'cho_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale);
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_hd is null or exists(select 1 from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = v.id and app.hd_of(t.so_hd_vao, t.ma_hang) = v_hd))
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)
                               and (v_flag is null or v_flag = 'sua' and v.sua_sau_nhap or v_flag = 'misa_chua' and v.misa_at is null)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim,
               string_agg(distinct t.md, ', ') mds, bool_or(coalesce(l.vat, t.vat) >= 0.095) vat10,
               string_agg(distinct t.ma_hang, ', ') mas, string_agg(distinct app.hd_of(t.so_hd_vao, t.ma_hang), ', ') hds
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia, a.mds, coalesce(a.vat10, false) vat10, a.mas, a.hds,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where (v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%')
           and (v_next is null or b.status = 'da_nhap' and fn.version is not null and (v_next = 'chua_gui' and fn.sent_at is null or v_next = 'cho_khach' and fn.sent_at is not null))),
  o as (select f.*, row_number() over (order by
          case when v_dir = 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end asc nulls last,
          case when v_dir <> 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end desc nulls last,
          case when v_sort = 'tien' and v_dir = 'asc' then f.tien_hang + f.tien_thue end asc nulls last,
          case when v_sort = 'tien' and v_dir <> 'asc' then f.tien_hang + f.tien_thue end desc nulls last,
          case when v_dir = 'asc' and v_sort = 'at' then f.status_at end asc, f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa);
end $$;


-- 3. Danh sách số HĐ đầu vào để lọc (theo phạm vi người xem)
create or replace function public.out_hd_opts(p_mode text default 'mine') returns table(hd text, ngay date, n bigint)
language sql stable security definer set search_path = public, app as $$
  select app.hd_of(s.so_hd_vao, s.ma_hang) hd, max(s.ngay_vao) ngay, count(*) n
    from app.out_items_scope(case when p_mode = 'acc' then 'acc' else 'mine' end) s
   where app.hd_of(s.so_hd_vao, s.ma_hang) is not null
   group by 1 order by max(s.ngay_vao) desc nulls last, 1 desc
$$;
grant execute on function public.out_hd_opts(text) to authenticated;

reset search_path;
