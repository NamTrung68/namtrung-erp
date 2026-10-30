-- =====================================================================
-- 0013 · Bản 7: COM Mua hàng / CSKH / TP Kế toán trong lương, tồn kho có giá,
--        câu trả lời mẫu, đếm trạng thái báo giá phía máy chủ (tải nhanh)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 7');

-- ---------- 1. Lương: COM theo bộ phận ----------
alter table public.order_results add column if not exists cskh_name text;
alter table public.order_results add column if not exists cskh_id uuid references public.profiles(id);
alter table public.order_results add column if not exists buyer_name text;
alter table public.order_results add column if not exists buyer_id uuid references public.profiles(id);
alter table public.order_results add column if not exists purchase_fee numeric(18,0) not null default 0;   -- Phí mua hàng (phí dịch vụ)
alter table public.order_results add column if not exists nego_fee numeric(18,0) not null default 0;       -- Tiền hoa hồng đàm phán
create index if not exists order_results_cskh on public.order_results(period_id, cskh_id);
create index if not exists order_results_buyer on public.order_results(period_id, buyer_id);
alter table public.payslips add column if not exists com_buyer numeric(18,0) not null default 0;
alter table public.payslips add column if not exists com_cskh numeric(18,0) not null default 0;
alter table public.payslips add column if not exists com_accounting numeric(18,0) not null default 0;

drop policy if exists or_read on public.order_results;
create policy or_read on public.order_results for select to authenticated
  using (app.can_see_hr() or app.in_tree(profile_id) or cskh_id = auth.uid() or buyer_id = auth.uid());

update public.settings set value = value
  || jsonb_build_object('buyer_com', coalesce(value->'buyer_com', '{"enabled":true,"fee_pct":2,"nego_pct_by_month":[2,3,4,5],"coef_pct":100}'::jsonb))
  || jsonb_build_object('cskh_com', coalesce(value->'cskh_com', '{"enabled":true,"fee_pct":2,"nego_pct":1}'::jsonb))
  || jsonb_build_object('accounting_com', coalesce(value->'accounting_com', '{"pct":0.5,"base_pct":60,"profile_ids":[]}'::jsonb))
  || jsonb_build_object('order_link', coalesce(value->'order_link', '"https://ad.namtrunglog.com/don-hang/{so}"'::jsonb))
 where key = 'payroll';

create or replace function app.is_assigned(p_name text) returns boolean language sql immutable as $$
  select coalesce(btrim(p_name), '') <> '' and lower(btrim(p_name)) not in ('chưa phân công', 'chua phan cong', '-', 'không', 'khong')
$$;
-- Khớp tên trong file với nhân sự (tên trong file đơn, họ tên, mã NV)
create or replace function app.match_staff(p_name text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select p.id from public.profiles p
   where app.is_assigned(p_name)
     and lower(btrim(p_name)) = any(select lower(btrim(x)) from unnest(p.sale_aliases || p.full_name || coalesce(p.employee_code, '')) x)
   limit 1
$$;


create or replace function public.import_order_results(p_period uuid, p_rows jsonb, p_replace boolean default true)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_pid uuid; v_cskh uuid; v_buyer uuid; n int := 0; unmapped text[] := '{}'; st text;
begin
  if not app.has_role('admin','bgd','ke_toan') then raise exception 'Chỉ Kế toán/BGĐ được nhập file đơn'; end if;
  select status into st from public.payroll_periods where id = p_period;
  if st is null then raise exception 'Kỳ lương không tồn tại'; end if;
  if st = 'closed' then raise exception 'Kỳ lương đã chốt'; end if;
  if p_replace then delete from public.order_results where period_id = p_period; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(r->>'ext_order_code'),'') = '' then continue; end if;
    select id into v_pid from public.profiles p
     where lower(btrim(r->>'sale_name')) = any(select lower(btrim(x)) from unnest(p.sale_aliases || p.full_name || p.employee_code) x)
     limit 1;
    if v_pid is null and coalesce(r->>'sale_name','') <> '' then unmapped := unmapped || (r->>'sale_name'); end if;
    v_cskh := app.match_staff(r->>'cskh_name'); v_buyer := app.match_staff(r->>'buyer_name');
    if v_cskh is null and app.is_assigned(r->>'cskh_name') then unmapped := unmapped || ('CSKH: ' || (r->>'cskh_name')); end if;
    if v_buyer is null and app.is_assigned(r->>'buyer_name') then unmapped := unmapped || ('Mua hàng: ' || (r->>'buyer_name')); end if;
    insert into public.order_results(period_id, ext_order_code, sale_name, profile_id, customer_ext, warehouse, order_type, completed_at, goods_value, order_profit, raw,
                                     cskh_name, cskh_id, buyer_name, buyer_id, purchase_fee, nego_fee)
    values (p_period, btrim(r->>'ext_order_code'), r->>'sale_name', v_pid, r->>'customer_ext', r->>'warehouse', r->>'order_type',
            (r->>'completed_at')::date, coalesce((r->>'goods_value')::numeric,0), coalesce((r->>'order_profit')::numeric,0), r->'raw',
            nullif(r->>'cskh_name', ''), v_cskh, nullif(r->>'buyer_name', ''), v_buyer, coalesce((r->>'purchase_fee')::numeric, 0), coalesce((r->>'nego_fee')::numeric, 0))
    on conflict (period_id, ext_order_code) do update set sale_name = excluded.sale_name, profile_id = excluded.profile_id,
       completed_at = excluded.completed_at, goods_value = excluded.goods_value, order_profit = excluded.order_profit, raw = excluded.raw,
       cskh_name = excluded.cskh_name, cskh_id = excluded.cskh_id, buyer_name = excluded.buyer_name, buyer_id = excluded.buyer_id,
       purchase_fee = excluded.purchase_fee, nego_fee = excluded.nego_fee;
    n := n + 1;
  end loop;
  return jsonb_build_object('imported', n, 'unmapped', (select coalesce(jsonb_agg(distinct x), '[]') from unnest(unmapped) x));
end $$;

create or replace function public.payroll_compute(p_period uuid)
returns int language plpgsql security definer set search_path = public, app as $$
declare
  per record; p record; pcfg jsonb := coalesce(app.setting('payroll'),'{}');
  m_start date; m_end date; d date; info jsonb;
  std numeric; paid numeric; worked numeric; pleave numeric; unpaid numeric; late int; over int;
  flex_min int := coalesce(app.setting_num('attendance','flex_minutes'), 100)::int; flex_from date := coalesce((app.setting('attendance')->>'flex_start')::date, '2026-11-01');
  base_pct numeric := coalesce((pcfg->>'commission_base_pct')::numeric, 60); max_off numeric := coalesce((pcfg->>'loss_offset_max_pct')::numeric, 50);
  priv record; lvl record; pos numeric; loss numeric; carry_in numeric; com numeric; off numeric; team numeric; adj numeric; sal numeric; flexded numeric; n int := 0; detail jsonb;
  bcfg jsonb := coalesce(pcfg->'buyer_com', '{}'); ccfg jsonb := coalesce(pcfg->'cskh_com', '{}'); acfg jsonb := coalesce(pcfg->'accounting_com', '{}');
  b_fee numeric; b_nego numeric; b_orders int; b_month int; b_nego_pct numeric; b_coef numeric; c_buyer numeric; c_fee numeric; c_nego numeric; c_orders int; c_cskh numeric;
  c_acc numeric; total_profit numeric;
begin
  if not app.has_role('admin','bgd','hcns','ke_toan') then raise exception 'Không có quyền tính lương'; end if;
  select * into per from public.payroll_periods where id = p_period for update;
  if per.id is null then raise exception 'Kỳ lương không tồn tại'; end if;
  if per.status not in ('open','review') then raise exception 'Kỳ lương đang chờ duyệt hoặc đã chốt'; end if;
  m_start := per.month; m_end := (per.month + interval '1 month - 1 day')::date;
  select coalesce(sum(order_profit), 0) into total_profit from public.order_results where period_id = p_period;
  for p in select * from public.profiles where status = 'active' loop
    std := 0; paid := 0; worked := 0; pleave := 0; unpaid := 0; late := 0;
    for d in select x::date from generate_series(m_start, m_end, interval '1 day') x loop
      info := app.day_info(p.id, p.work_schedule, p.hire_date, d);
      std := std + coalesce((info->>'dv')::numeric, 0);
      if coalesce((info->>'future')::boolean, false) then worked := worked + coalesce((info->>'dv')::numeric, 0) - coalesce((info->>'off')::numeric, 0); pleave := pleave + coalesce((info->>'paid')::numeric, 0); continue; end if;
      worked := worked + coalesce((info->>'worked')::numeric, 0); pleave := pleave + coalesce((info->>'paid')::numeric, 0);
      unpaid := unpaid + coalesce((info->>'absent')::numeric, 0) + coalesce((info->>'off')::numeric, 0) - coalesce((info->>'paid')::numeric, 0);
      late := late + coalesce((info->>'late')::int, 0);
    end loop;
    paid := worked + pleave;
    select * into priv from public.profile_private where profile_id = p.id;
    select * into lvl from public.job_levels where code = p.job_level;
    sal := case when std > 0 then round(coalesce(priv.base_salary,0) * least(paid, std) / std) else 0 end;
    over := case when m_start >= flex_from then greatest(0, late - flex_min) else 0 end;
    flexded := case when std > 0 then round(coalesce(priv.base_salary,0) / std / 8 / 60 * over) else 0 end;
    select coalesce(sum(round(order_profit * base_pct / 100)) filter (where order_profit > 0), 0),
           coalesce(-sum(round(order_profit * base_pct / 100)) filter (where order_profit < 0), 0)
      into pos, loss from public.order_results where period_id = p_period and profile_id = p.id;
    select coalesce(ps.carry_loss, 0) into carry_in from public.payslips ps join public.payroll_periods pp on pp.id = ps.period_id
      where ps.profile_id = p.id and pp.month = (m_start - interval '1 month')::date;
    carry_in := coalesce(carry_in, 0);
    com := app.tiered_commission(pos, coalesce(lvl.commission_pct, 0));
    off := least(loss + carry_in, round(com * max_off / 100));
    team := 0;
    if coalesce(lvl.team_bonus_pct, 0) > 0 then
      with recursive t as (select id from public.profiles where manager_id = p.id union select x.id from public.profiles x join t on x.manager_id = t.id)
      select coalesce(round(sum(round(o.order_profit * base_pct / 100)) * lvl.team_bonus_pct / 100), 0) into team
        from public.order_results o where o.period_id = p_period and o.profile_id in (select id from t);
      team := greatest(team, 0);
    end if;
    -- COM Mua hàng: (Phí mua hàng × a% + Hoa hồng đàm phán × b% theo tháng thâm niên) × hệ số
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), count(*) into b_fee, b_nego, b_orders
      from public.order_results where period_id = p_period and buyer_id = p.id;
    c_buyer := 0; b_month := null; b_nego_pct := 0; b_coef := coalesce((bcfg->>'coef_pct')::numeric, 100);
    if coalesce((bcfg->>'enabled')::boolean, true) and b_orders > 0 then
      b_month := case when p.hire_date is null then 99 else
        (extract(year from age(m_start, date_trunc('month', p.hire_date)::date)) * 12 + extract(month from age(m_start, date_trunc('month', p.hire_date)::date)))::int + 1 end;
      b_nego_pct := coalesce((bcfg->'nego_pct_by_month'->>(least(greatest(b_month, 1), jsonb_array_length(coalesce(bcfg->'nego_pct_by_month', '[2,3,4,5]'::jsonb))) - 1))::numeric,
                             (array[2,3,4,5])[least(greatest(b_month, 1), 4)]);
      c_buyer := round((b_fee * coalesce((bcfg->>'fee_pct')::numeric, 2) / 100 + b_nego * b_nego_pct / 100) * b_coef / 100);
    end if;
    -- COM CSKH: Phí dịch vụ × 2% + Phí đàm phán × 1% các đơn hoàn thành mình phụ trách
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), count(*) into c_fee, c_nego, c_orders
      from public.order_results where period_id = p_period and cskh_id = p.id;
    c_cskh := case when coalesce((ccfg->>'enabled')::boolean, true) and c_orders > 0
                   then round(c_fee * coalesce((ccfg->>'fee_pct')::numeric, 2) / 100 + c_nego * coalesce((ccfg->>'nego_pct')::numeric, 1) / 100) else 0 end;
    -- COM Trưởng phòng Kế toán: 0,5% × 60% × LN đơn hoàn thành cả công ty
    c_acc := case when p.id::text in (select jsonb_array_elements_text(coalesce(acfg->'profile_ids', '[]'))) and total_profit > 0
                  then round(total_profit * coalesce((acfg->>'base_pct')::numeric, 60) / 100 * coalesce((acfg->>'pct')::numeric, 0.5) / 100) else 0 end;
    select coalesce(sum(a.amount),0) into adj from public.payslip_adjustments a join public.payslips ps on ps.id = a.payslip_id where ps.period_id = p_period and ps.profile_id = p.id;
    detail := jsonb_build_object('late_minutes', late, 'flex_minutes', flex_min, 'flex_active', m_start >= flex_from, 'commission_pct', coalesce(lvl.commission_pct,0),
      'commission_base_pct', base_pct, 'loss_this_month', loss, 'carry_in', carry_in, 'orders', (select count(*) from public.order_results where period_id = p_period and profile_id = p.id),
      'buyer', jsonb_build_object('orders', b_orders, 'purchase_fee', b_fee, 'nego_fee', b_nego, 'month', b_month, 'fee_pct', coalesce((bcfg->>'fee_pct')::numeric, 2), 'nego_pct', b_nego_pct, 'coef_pct', b_coef),
      'cskh', jsonb_build_object('orders', c_orders, 'purchase_fee', c_fee, 'nego_fee', c_nego, 'fee_pct', coalesce((ccfg->>'fee_pct')::numeric, 2), 'nego_pct', coalesce((ccfg->>'nego_pct')::numeric, 1)),
      'accounting', jsonb_build_object('total_profit', total_profit, 'base_pct', coalesce((acfg->>'base_pct')::numeric, 60), 'pct', coalesce((acfg->>'pct')::numeric, 0.5)));
    insert into public.payslips as ps(period_id, profile_id, standard_days, paid_days, worked_days, paid_leave_days, unpaid_days, late_minutes, flex_over_minutes, base_salary,
      salary_by_days, allowance, profit_total, commission_base, commission, loss_offset, carry_loss, team_bonus, com_buyer, com_cskh, com_accounting, flex_deduction, insurance, adjustments, net, details, status, updated_at)
    values (p_period, p.id, std, least(paid, std), worked, pleave, greatest(unpaid, 0), late, over, coalesce(priv.base_salary,0), sal, coalesce(priv.allowance,0),
      (select coalesce(sum(order_profit),0) from public.order_results where period_id = p_period and profile_id = p.id),
      pos, com, off, loss + carry_in - off, team, c_buyer, c_cskh, c_acc, flexded, coalesce(priv.insurance_deduction,0), adj,
      sal + coalesce(priv.allowance,0) + com - off + team + c_buyer + c_cskh + c_acc - flexded - coalesce(priv.insurance_deduction,0) + adj, detail, 'draft', now())
    on conflict (period_id, profile_id) do update set standard_days = excluded.standard_days, paid_days = excluded.paid_days, worked_days = excluded.worked_days,
      paid_leave_days = excluded.paid_leave_days, unpaid_days = excluded.unpaid_days, late_minutes = excluded.late_minutes, flex_over_minutes = excluded.flex_over_minutes,
      base_salary = excluded.base_salary, salary_by_days = excluded.salary_by_days, allowance = excluded.allowance, profit_total = excluded.profit_total,
      commission_base = excluded.commission_base, commission = excluded.commission, loss_offset = excluded.loss_offset, carry_loss = excluded.carry_loss,
      team_bonus = excluded.team_bonus, com_buyer = excluded.com_buyer, com_cskh = excluded.com_cskh, com_accounting = excluded.com_accounting, flex_deduction = excluded.flex_deduction, insurance = excluded.insurance, adjustments = excluded.adjustments,
      net = excluded.net, details = excluded.details, status = 'draft', confirmed_at = null, updated_at = now()
    where ps.status <> 'closed';
    n := n + 1;
  end loop;
  update public.payroll_periods set computed_at = now(), status = 'open' where id = p_period;
  return n;
end $$;

-- ---------- 2. Tồn kho: đơn giá nhập / xuất + tổng ----------
alter table public.inventory_items add column if not exists cost_price numeric(18,2);
alter table public.inventory_items add column if not exists sale_price numeric(18,2);
alter table public.inventory_items add column if not exists updated_by uuid references public.profiles(id);
drop trigger if exists inventory_touch on public.inventory_items;
create or replace function app.inventory_touch() returns trigger language plpgsql as $$ begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
create trigger inventory_touch before update on public.inventory_items for each row execute function app.inventory_touch();
drop trigger if exists audit_inventory on public.inventory_items;
create trigger audit_inventory after update or delete on public.inventory_items for each row execute function app.audit();

create or replace function public.import_inventory(p_rows jsonb, p_replace boolean default true) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.has_role('admin','bgd','ke_toan') then raise exception 'Chỉ Admin, BGĐ, Kế toán được nhập tồn kho'; end if;
  if p_replace then delete from public.inventory_items where true; end if;
  insert into public.inventory_items(sku, name, unit, qty, warehouse, note, cost_price, sale_price)
  select distinct on (upper(btrim(x->>'sku'))) btrim(x->>'sku'), btrim(x->>'name'), nullif(x->>'unit', ''), nullif(x->>'qty', '')::numeric, nullif(x->>'warehouse', ''), nullif(x->>'note', ''),
         nullif(x->>'cost_price', '')::numeric, nullif(x->>'sale_price', '')::numeric
    from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') <> ''
  on conflict (upper(sku)) where sku is not null do update set name = excluded.name, unit = excluded.unit, qty = excluded.qty, warehouse = excluded.warehouse, note = excluded.note,
     cost_price = coalesce(excluded.cost_price, inventory_items.cost_price), sale_price = coalesce(excluded.sale_price, inventory_items.sale_price), updated_at = now();
  get diagnostics n = row_count;
  insert into public.inventory_items(name, unit, qty, warehouse, note, cost_price, sale_price)
  select btrim(x->>'name'), nullif(x->>'unit', ''), nullif(x->>'qty', '')::numeric, nullif(x->>'warehouse', ''), nullif(x->>'note', ''), nullif(x->>'cost_price', '')::numeric, nullif(x->>'sale_price', '')::numeric
    from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') = '';
  n := n + (select count(*) from jsonb_array_elements(p_rows) x where coalesce(btrim(x->>'name'), '') <> '' and coalesce(btrim(x->>'sku'), '') = '');
  insert into public.audit_logs(action, table_name, diff) values ('IMPORT', 'inventory_items', jsonb_build_object('rows', n, 'replace', p_replace));
  return n;
end $$;

create or replace function public.inventory_totals(p_q text default null)
returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('items', count(*), 'qty', coalesce(sum(qty), 0),
           'cost_value', coalesce(sum(qty * cost_price), 0), 'sale_value', coalesce(sum(qty * sale_price), 0),
           'updated_at', max(updated_at))
    from public.inventory_items
   where app.is_active() and (coalesce(btrim(p_q), '') = '' or name_norm like '%' || app.norm_text(p_q) || '%' or upper(coalesce(sku, '')) like '%' || upper(btrim(p_q)) || '%')
$$;
grant execute on function public.inventory_totals(text) to authenticated;

-- ---------- 3. Câu trả lời mẫu cho Sale / CSKH ----------
create table if not exists public.reply_templates(
  id uuid primary key default gen_random_uuid(),
  category text not null default 'chung',
  title text not null,
  content text not null,
  sort int not null default 0,
  use_count int not null default 0,
  active boolean not null default true,
  created_by uuid references public.profiles(id) default auth.uid(),
  updated_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.reply_templates enable row level security;
drop policy if exists rt_read on public.reply_templates;
create policy rt_read on public.reply_templates for select to authenticated using (app.is_active());
drop policy if exists rt_write on public.reply_templates;
create policy rt_write on public.reply_templates for all to authenticated using (app.has_role('admin','bgd','tp_kd','tn_kd','hcns')) with check (app.has_role('admin','bgd','tp_kd','tn_kd','hcns'));
grant select, insert, update, delete on public.reply_templates to authenticated;
drop trigger if exists rt_touch on public.reply_templates;
create or replace function app.rt_touch() returns trigger language plpgsql as $$ begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
create trigger rt_touch before update on public.reply_templates for each row execute function app.rt_touch();
create or replace function public.reply_template_used(p_id uuid) returns void
language sql security definer set search_path = public, app as $$ update public.reply_templates set use_count = use_count + 1 where id = p_id and app.is_active() $$;
grant execute on function public.reply_template_used(uuid) to authenticated;

insert into public.lookups(category, code, label, sort) values
 ('reply_cat','chao_hoi','Chào hỏi · giới thiệu',1), ('reply_cat','bao_gia','Báo giá · tư vấn',2), ('reply_cat','coc_thanh_toan','Cọc · thanh toán',3),
 ('reply_cat','van_chuyen','Vận chuyển · giao hàng',4), ('reply_cat','khieu_nai','Kiểm hàng · khiếu nại',5), ('reply_cat','cham_soc','Chăm sóc · giữ khách',6), ('reply_cat','chung','Khác',9)
on conflict do nothing;

insert into public.reply_templates(category, title, content, sort, created_by)
select * from (values
 ('khieu_nai', 'Nhắc kiểm hàng trong 48h sau khi giao', 'Dạ {danh_xung} ơi, đơn hàng của mình đã giao thành công ạ. {Danh_xung} vui lòng kiểm tra số lượng, chất lượng hàng giúp em trong vòng 48 giờ kể từ khi nhận nhé. Nếu có thiếu, lỗi hay sai mẫu, {danh_xung} chụp ảnh / quay video lúc mở hàng và báo em ngay để em làm việc với shop ạ. Sau 48 giờ, việc khiếu nại với shop rất khó khăn và khả năng không thành công cao. Em cảm ơn {danh_xung} nhiều ạ! 🙏', 1, null::uuid),
 ('chao_hoi', 'Chào khách mới', 'Dạ em chào {danh_xung}, em là {ten_sale} – Nam Trung Logistics. Bên em chuyên nhập khẩu chính ngạch, mua hộ, vận chuyển hàng Trung Quốc – Việt Nam trọn gói, có hóa đơn VAT đầy đủ. {Danh_xung} đang cần nhập mặt hàng gì để em tư vấn phương án tối ưu chi phí ạ?', 1, null),
 ('bao_gia', 'Gửi báo giá', 'Dạ em gửi {danh_xung} báo giá chi tiết đơn hàng ạ. Báo giá đã gồm tiền hàng, cước vận chuyển, phí dịch vụ, thuế và VAT; hiệu lực trong 5 ngày. {Danh_xung} xem giúp em, có điểm nào cần điều chỉnh em hỗ trợ ngay ạ.', 1, null),
 ('coc_thanh_toan', 'Hướng dẫn đặt cọc', 'Dạ để bên em tiến hành đặt hàng, {danh_xung} vui lòng chuyển khoản cọc theo mã QR trên báo giá giúp em, nội dung chuyển khoản đã ghi sẵn trên QR ạ. Nhận cọc xong em báo xác nhận và cập nhật tiến độ cho {danh_xung} ngay ạ.', 1, null),
 ('van_chuyen', 'Hàng đã về kho Việt Nam', 'Dạ hàng của {danh_xung} đã về kho Việt Nam ạ. Em gửi {danh_xung} thông tin cân nặng / số khối và số tiền còn lại cần thanh toán. {Danh_xung} xác nhận giúp em để em sắp xếp giao hàng sớm nhất ạ.', 1, null)
) v(category, title, content, sort, created_by)
where not exists (select 1 from public.reply_templates);

-- ---------- 4. Tải nhanh: đếm báo giá theo trạng thái phía máy chủ ----------
create or replace function public.quote_status_counts(p_sale uuid default null)
returns table(status text, n bigint) language sql stable security definer set search_path = public, app as $$
  select q.status, count(*) from public.quotations q
   where q.status <> 'da_thay_the' and (app.is_admin() or app.in_tree(q.sale_id)) and (p_sale is null or q.sale_id = p_sale)
   group by q.status
$$;
grant execute on function public.quote_status_counts(uuid) to authenticated;
create index if not exists quotations_sale_status on public.quotations(sale_id, status, created_at desc);
create index if not exists customers_owner_next on public.customers(owner_id, next_care_date) where deleted_at is null;

reset search_path;
