-- =====================================================================
-- 0019 · Bản 12: biên APT theo tờ khai nháp; HĐ APT nhiều đợt (gộp nhiều HĐ / xuất một phần);
--        HĐ về sau tự ghép vào xe nạp sau; tự ghép đủ tên sale (khoile…)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 12');

-- Giá vốn APT theo tờ khai nháp = đơn giá theo tỷ giá NH + thuế NK/đv; biên APT = giá APT ÷ giá vốn − 1
alter table public.acc_lines add column if not exists gia_von numeric generated always as (case when gia_tk_nh is not null then gia_tk_nh + coalesce(tnk_dv, 0) end) stored;
alter table public.acc_lines add column if not exists bien_apt numeric generated always as (
  case when gia_tk_nh is not null and gia_tk_nh + coalesce(tnk_dv, 0) > 0 and gia_ap_dung > 0 then round(gia_ap_dung / (gia_tk_nh + coalesce(tnk_dv, 0)) - 1, 6) end) stored;
create index if not exists acc_invl_line on public.acc_invoice_lines(line_id);
create index if not exists acc_invl_hh_free on public.acc_invoice_lines(hh) where line_id is null;

-- Kết luận 1 dòng HĐ so với dòng đối soát (chỉ giá; số lượng xét khi cộng các HĐ)
create or replace function app.acc_judge(p_dg numeric, l public.acc_lines) returns text language sql immutable as $$
  select case when l.id is null then 'khong_thuoc_xe' when l.md is null then 'khong_don' when coalesce(l.gia_khach, 0) = 0 then 'gia_khach_0'
              when coalesce(l.gia_note, l.gia_de_xuat, l.gia_nhap) is null then 'khop'
              when (l.gia_note is not null and abs(p_dg - l.gia_note) <= 0.5) or (l.gia_de_xuat is not null and abs(p_dg - l.gia_de_xuat) <= 0.5)
                or (l.gia_nhap is not null and abs(p_dg - l.gia_nhap) <= 0.5) then 'khop' else 'lech' end
$$;

-- Cộng mọi dòng HĐ (nhiều đợt, nhiều HĐ) của 1 dòng đối soát
create or replace function app.acc_line_inv_refresh(p_line uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; agg record; v_res text; v_sl numeric;
begin
  select * into l from public.acc_lines where id = p_line; if l.id is null then return; end if;
  select count(*) n, string_agg(distinct i.so_hd, ', ' order by i.so_hd) so, sum(il.sl) sl, sum(il.tt) tt,
         (array_agg(i.id order by i.ngay desc nulls last, i.created_at desc))[1] last_id, (array_agg(il.dg order by i.ngay desc nulls last))[1] dg,
         (array_agg(il.stt order by i.ngay desc nulls last))[1] stt,
         bool_or(il.result = 'khong_don') kd, bool_or(il.result = 'gia_khach_0') g0, bool_or(il.result = 'lech') lech
    into agg from public.acc_invoice_lines il join public.acc_invoices i on i.id = il.invoice_id where il.line_id = p_line;
  if agg.n = 0 then
    update public.acc_lines set inv_id = null, inv_no = null, inv_stt = null, inv_price = null, inv_qty = null, inv_amount = null, inv_result = null where id = p_line; return;
  end if;
  v_sl := coalesce(l.sl_tk, l.sl_apt);
  v_res := case when agg.kd then 'khong_don' when agg.g0 then 'gia_khach_0' when agg.lech then 'lech'
                when v_sl is not null and agg.sl > v_sl + 0.01 then 'lech' when v_sl is not null and agg.sl < v_sl - 0.01 then 'mot_phan' else 'khop' end;
  update public.acc_lines set inv_id = agg.last_id, inv_no = agg.so, inv_stt = agg.stt, inv_price = agg.dg, inv_qty = agg.sl, inv_amount = agg.tt, inv_result = v_res, updated_at = now() where id = p_line;
end $$;

create or replace function app.acc_inv_stats_refresh(p_inv uuid) returns void language sql security definer set search_path = public, app as $$
  update public.acc_invoices i set stats = coalesce((select jsonb_object_agg(result, c) from (select il.result, count(*) c from public.acc_invoice_lines il where il.invoice_id = p_inv group by il.result) x), '{}')
    || jsonb_build_object('tien_khong_don', (select coalesce(sum(tt), 0) from public.acc_invoice_lines where invoice_id = p_inv and result in ('khong_don','gia_khach_0')),
                          'mot_phan', (select count(*) from public.acc_invoice_lines il join public.acc_lines l on l.id = il.line_id where il.invoice_id = p_inv and l.inv_result = 'mot_phan'))
   where i.id = p_inv
$$;

-- Lưu HĐ: giữ kết luận từng dòng theo giá, cộng số lượng các đợt ở dòng đối soát
create or replace function public.acc_invoice_save(p_inv jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_id uuid; r jsonb; v_old uuid[]; x uuid;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  insert into public.acc_invoices as i(ky_hieu, so_hd, ngay, mst_ban, ten_ban, mst_mua, ten_mua, tong_truoc_thue, tien_thue, tong, file_name, stats)
  values (p_inv->>'ky_hieu', p_inv->>'so_hd', nullif(p_inv->>'ngay','')::date, p_inv->>'mst_ban', p_inv->>'ten_ban', p_inv->>'mst_mua', p_inv->>'ten_mua',
          (p_inv->>'tong_truoc_thue')::numeric, (p_inv->>'tien_thue')::numeric, (p_inv->>'tong')::numeric, p_inv->>'file_name', '{}')
  on conflict (mst_ban, ky_hieu, so_hd) do update set ngay = excluded.ngay, tong_truoc_thue = excluded.tong_truoc_thue, tien_thue = excluded.tien_thue, tong = excluded.tong, file_name = excluded.file_name
  returning id into v_id;
  select array_agg(distinct line_id) into v_old from public.acc_invoice_lines where invoice_id = v_id and line_id is not null;
  delete from public.acc_invoice_lines where invoice_id = v_id;
  for r in select * from jsonb_array_elements(p_lines) loop
    insert into public.acc_invoice_lines(invoice_id, stt, hh, ten, dvt, sl, dg, tt, vat, line_id, result)
    values (v_id, (r->>'stt')::int, r->>'hh', r->>'ten', r->>'dvt', (r->>'sl')::numeric, (r->>'dg')::numeric, (r->>'tt')::numeric, r->>'vat', nullif(r->>'line_id','')::uuid, r->>'result');
  end loop;
  for x in select distinct line_id from public.acc_invoice_lines where invoice_id = v_id and line_id is not null union select unnest(coalesce(v_old, '{}')) loop
    perform app.acc_line_inv_refresh(x);
  end loop;
  perform app.acc_inv_stats_refresh(v_id);
  if exists(select 1 from public.acc_invoice_lines where invoice_id = v_id and result in ('khong_don','gia_khach_0','lech')) then
    perform app.telegram('acc_invoice', '🧾 HĐ APT <b>' || app.esc(p_inv->>'so_hd') || '</b>: ' ||
      (select count(*) from public.acc_invoice_lines where invoice_id = v_id and result in ('khong_don','gia_khach_0')) || ' dòng chưa có đơn/giá khách, ' ||
      (select count(*) from public.acc_invoice_lines where invoice_id = v_id and result = 'lech') || ' dòng lệch giá.');
  end if;
  return v_id;
end $$;

-- HĐ về trước, xe nạp sau: ghép các dòng HĐ "không thuộc xe" vào xe vừa nạp theo mã HH
create or replace function public.acc_relink_truck(p_truck uuid) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int := 0; x uuid; v_inv uuid[];
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if (select is_test from public.acc_trucks where id = p_truck) then return 0; end if;
  with m as (
    update public.acc_invoice_lines il set line_id = l.id, result = app.acc_judge(il.dg, l)
      from public.acc_lines l where l.truck_id = p_truck and il.line_id is null and coalesce(il.hh, '') <> '' and il.hh = l.hh
    returning il.line_id, il.invoice_id)
  select count(*), array_agg(distinct invoice_id) into n, v_inv from m;
  for x in select distinct line_id from public.acc_invoice_lines where invoice_id = any(coalesce(v_inv, '{}')) and line_id is not null loop perform app.acc_line_inv_refresh(x); end loop;
  for x in select unnest(coalesce(v_inv, '{}')) loop perform app.acc_inv_stats_refresh(x); end loop;
  if n > 0 then insert into public.acc_events(truck_id, action, note) values (p_truck, 'relink_invoice', n || ' dòng HĐ đã về trước được ghép vào xe này'); end if;
  return n;
end $$;
grant execute on function public.acc_relink_truck(uuid) to authenticated;

-- Chuyển xe nạp thử thành chính thức: ghép luôn HĐ đã về trước
create or replace function public.acc_truck_publish(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); s record; t public.acc_trucks;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  update public.acc_trucks set is_test = false, updated_at = now() where id = p_id and is_test returning * into t;
  if t.id is null then raise exception 'Xe không ở chế độ nạp thử'; end if;
  update public.acc_lines set is_test = false, due_at = case when status = 'blocked' then now() + make_interval(hours => h) end where truck_id = p_id;
  insert into public.acc_events(truck_id, action, note) values (p_id, 'publish', t.name);
  perform public.acc_relink_truck(p_id);
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = p_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', t.name || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
end $$;

-- Tính lại kết quả HĐ các dòng đã ghép (theo cách cộng nhiều đợt)
do $$ declare x uuid; begin
  for x in select distinct line_id from public.acc_invoice_lines where line_id is not null loop perform app.acc_line_inv_refresh(x); end loop;
  for x in select id from public.acc_invoices loop perform app.acc_inv_stats_refresh(x); end loop;
end $$;

-- Ghép đủ tên trong file cho sale đã khớp 1 tên (VD đã khớp "Lê Thị Minh Khơi" nhưng thiếu tài khoản "khoile")
do $$ declare g jsonb; v_names text[]; v_pid uuid; n int;
begin
  perform set_config('nt.alias_ok', '1', true);
  for g in select * from jsonb_array_elements(coalesce(app.setting('accounting')->'sale_names', '[]')) loop
    v_names := array(select jsonb_array_elements_text(g->'names')) || (g->>'acc');
    select count(distinct p.id), min(p.id::text)::uuid into n, v_pid from public.profiles p
     where p.status = 'active' and exists(select 1 from unnest(v_names) y where app.norm_text(y) = any(select app.norm_text(z) from unnest(p.sale_aliases || p.full_name) z));
    if n = 1 then
      update public.profiles set sale_aliases = array(select distinct x from unnest(sale_aliases || v_names) x where btrim(x) <> '') where id = v_pid;
      update public.acc_lines l set sale_id = v_pid,
        issues = array(select x from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%'),
        status = case when l.status = 'blocked' and not exists(select 1 from unnest(l.issues) x where x not like 'Tên sale "%chưa ghép%') then case when l.luong in ('A','E') then 'ok' else 'info' end else l.status end
       where l.sale_id is null and app.norm_text(coalesce(l.sale_name, '')) = any(select app.norm_text(y) from unnest(v_names) y);
    end if;
  end loop;
  perform set_config('nt.alias_ok', '', true);
end $$;

reset search_path;
