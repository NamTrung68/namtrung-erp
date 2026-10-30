-- =====================================================================
-- 0015 · Bản 9: mẫu số % đàm phán = Tiền hàng trên web + Phí vận chuyển nội địa TQ (VND)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 9');

alter table public.order_results add column if not exists domestic_ship numeric(18,0) not null default 0;  -- Phí vận chuyển nội địa TQ (VND)
-- Lấy lại từ dữ liệu gốc đã nhập (cột raw) để không phải nhập lại file
update public.order_results o set domestic_ship = coalesce((
  select round(nullif(regexp_replace(e.value, '[^0-9.-]', '', 'g'), '')::numeric) from jsonb_each_text(o.raw) e
   where app.norm_text(e.key) like 'phi van chuyen noi dia%' and app.norm_text(e.key) like '%vnd%' limit 1), 0)
 where o.raw is not null;

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
                                     cskh_name, cskh_id, buyer_name, buyer_id, purchase_fee, nego_fee, domestic_ship)
    values (p_period, btrim(r->>'ext_order_code'), r->>'sale_name', v_pid, r->>'customer_ext', r->>'warehouse', r->>'order_type',
            (r->>'completed_at')::date, coalesce((r->>'goods_value')::numeric,0), coalesce((r->>'order_profit')::numeric,0), r->'raw',
            nullif(r->>'cskh_name', ''), v_cskh, nullif(r->>'buyer_name', ''), v_buyer, coalesce((r->>'purchase_fee')::numeric, 0), coalesce((r->>'nego_fee')::numeric, 0), coalesce((r->>'domestic_ship')::numeric, 0))
    on conflict (period_id, ext_order_code) do update set sale_name = excluded.sale_name, profile_id = excluded.profile_id,
       completed_at = excluded.completed_at, goods_value = excluded.goods_value, order_profit = excluded.order_profit, raw = excluded.raw,
       cskh_name = excluded.cskh_name, cskh_id = excluded.cskh_id, buyer_name = excluded.buyer_name, buyer_id = excluded.buyer_id,
       purchase_fee = excluded.purchase_fee, nego_fee = excluded.nego_fee, domestic_ship = excluded.domestic_ship;
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
  b_fee numeric; b_nego numeric; b_goods numeric; b_orders int; b_month int; b_nego_pct numeric; b_coef numeric; b_target numeric; b_rate numeric; b_ach numeric; b_tier jsonb; kcfg jsonb := coalesce(pcfg->'buyer_kpi', '{}'); k_pct numeric; k_share numeric; k_target numeric; k_on boolean; c_buyer numeric; c_fee numeric; c_nego numeric; c_orders int; c_cskh numeric;
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
    -- COM Mua hàng = Phí mua hàng × a% + Hoa hồng đàm phán × b% (theo tháng thâm niên) × Hệ số
    --   Hệ số theo % hoàn thành chỉ tiêu đàm phán: tỷ lệ đạt = Σ đàm phán / Σ (tiền hàng web + phí VC nội địa TQ) (VND); hoàn thành = tỷ lệ đạt / chỉ tiêu tháng thâm niên
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), coalesce(sum(goods_value + domestic_ship), 0), count(*) into b_fee, b_nego, b_goods, b_orders
      from public.order_results where period_id = p_period and buyer_id = p.id;
    c_buyer := 0; b_month := null; b_nego_pct := 0; b_coef := 0; b_target := null; b_rate := null; b_ach := null;
    if coalesce((bcfg->>'enabled')::boolean, true) and b_orders > 0 then
      b_month := case when p.hire_date is null then 99 else
        (extract(year from age(m_start, date_trunc('month', p.hire_date)::date)) * 12 + extract(month from age(m_start, date_trunc('month', p.hire_date)::date)))::int + 1 end;
      b_nego_pct := coalesce((bcfg->'nego_pct_by_month'->>(least(greatest(b_month, 1), 4) - 1))::numeric, (array[2,3,4,5])[least(greatest(b_month, 1), 4)]);
      b_target := coalesce((bcfg->'target_pct_by_month'->>(least(greatest(b_month, 1), 4) - 1))::numeric, (array[2,2.4,2.7,3])[least(greatest(b_month, 1), 4)]);
      b_rate := case when b_goods > 0 then round(b_nego / b_goods * 100, 4) else 0 end;
      b_ach := case when b_target > 0 then round(b_rate / b_target * 100, 2) else 0 end;
      b_coef := 0;
      for b_tier in select x from jsonb_array_elements(coalesce(bcfg->'coef_tiers', '[{"from":50,"coef":70},{"from":80,"coef":85},{"from":95,"coef":100},{"from":120,"coef":110},{"from":130,"coef":120}]'::jsonb)) x
                    order by (x->>'from')::numeric loop
        if b_ach >= (b_tier->>'from')::numeric then b_coef := (b_tier->>'coef')::numeric; end if;
      end loop;
      c_buyer := round(b_fee * coalesce((bcfg->>'fee_pct')::numeric, 2) / 100 * (case when coalesce((bcfg->>'coef_on_fee')::boolean, false) then b_coef / 100 else 1 end)
                       + b_nego * b_nego_pct / 100 * b_coef / 100);
    end if;
    -- Lương Mua hàng theo KPI số đơn (tắt mặc định): lương × (1 − x%) + lương × x% × min(số đơn / chỉ tiêu, 1)
    k_on := coalesce((kcfg->>'enabled')::boolean, false) and p.id::text in (select jsonb_array_elements_text(coalesce(kcfg->'profile_ids', '[]')));
    k_share := coalesce((kcfg->>'share_pct')::numeric, 30); k_target := coalesce((kcfg->>'orders')::numeric, 900); k_pct := null;
    if k_on and k_target > 0 then
      k_pct := least(coalesce(b_orders, 0) / k_target, 1);
      sal := round(sal * (1 - k_share / 100) + sal * k_share / 100 * k_pct);
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
      'buyer', jsonb_build_object('orders', b_orders, 'purchase_fee', b_fee, 'nego_fee', b_nego, 'goods', b_goods, 'month', b_month, 'fee_pct', coalesce((bcfg->>'fee_pct')::numeric, 2), 'nego_pct', b_nego_pct,
        'target_pct', b_target, 'rate_pct', b_rate, 'ach_pct', b_ach, 'coef_pct', b_coef, 'coef_on_fee', coalesce((bcfg->>'coef_on_fee')::boolean, false)),
      'buyer_kpi', case when k_on then jsonb_build_object('orders', b_orders, 'target', k_target, 'share_pct', k_share, 'pct', round(k_pct * 100, 2)) end,
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

reset search_path;
