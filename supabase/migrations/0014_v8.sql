-- =====================================================================
-- 0014 · Bản 8: sửa công thức COM Mua hàng (hệ số theo % hoàn thành chỉ tiêu đàm phán), KPI số đơn MH (tùy chọn)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 8');

update public.settings set value = jsonb_set(value, '{buyer_com}',
  (coalesce(value->'buyer_com', '{}'::jsonb) - 'coef_pct') || jsonb_build_object(
    'fee_pct', coalesce((value->'buyer_com'->>'fee_pct')::numeric, 2),
    'nego_pct_by_month', coalesce(value->'buyer_com'->'nego_pct_by_month', '[2,3,4,5]'::jsonb),
    'target_pct_by_month', coalesce(value->'buyer_com'->'target_pct_by_month', '[2,2.4,2.7,3]'::jsonb),
    'coef_tiers', coalesce(value->'buyer_com'->'coef_tiers', '[{"from":50,"coef":70},{"from":80,"coef":85},{"from":95,"coef":100},{"from":120,"coef":110},{"from":130,"coef":120}]'::jsonb),
    'coef_on_fee', coalesce((value->'buyer_com'->>'coef_on_fee')::boolean, false)))
  || jsonb_build_object('buyer_kpi', coalesce(value->'buyer_kpi', '{"enabled":false,"orders":900,"share_pct":30,"profile_ids":[]}'::jsonb))
 where key = 'payroll';

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
    --   Hệ số theo % hoàn thành chỉ tiêu đàm phán: tỷ lệ đạt = Σ đàm phán / Σ tiền hàng (VND); hoàn thành = tỷ lệ đạt / chỉ tiêu tháng thâm niên
    select coalesce(sum(purchase_fee), 0), coalesce(sum(nego_fee), 0), coalesce(sum(goods_value), 0), count(*) into b_fee, b_nego, b_goods, b_orders
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
