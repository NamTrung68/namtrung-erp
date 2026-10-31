-- =====================================================================
-- 0025 · Bản 18: tối ưu tốc độ + dung lượng
--  · Danh sách Xuất HĐ đầu ra tải theo trang (lọc/tìm/đếm trên máy chủ), mặc định "còn tồn" / "chờ xuất nháp"
--  · "Đã ký không sale" tách riêng, không tính vào "Chưa gắn sale"
--  · Đổi tên xe (đối soát + cột Xe)
--  · Sao lưu tự động giữ 3 bản gần nhất, không chép nhật ký hệ thống
-- =====================================================================
set search_path = public, app, extensions;

-- ---------- Sao lưu gọn ----------
create or replace function public.backup_create(p_note text default null) returns text
language plpgsql security definer set search_path = public, app as $$
declare s text := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS'); t record; old record;
begin
  if auth.uid() is not null and not app.is_admin() then raise exception 'Chỉ Admin được tạo bản sao lưu'; end if;
  while exists(select 1 from pg_namespace where nspname = s) loop
    perform pg_sleep(1); s := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS');
  end loop;
  execute format('create schema %I', s);
  execute format('revoke all on schema %I from public, anon, authenticated', s);
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and c.relname not in ('audit_logs', 'notifications') loop
    execute format('create table %I.%I as table public.%I', s, t.relname, t.relname);
  end loop;
  execute format('comment on schema %I is %L', s, coalesce(p_note, 'Sao lưu') || ' · ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'));
  -- giữ 3 bản gần nhất (bản đầy đủ hằng ngày đã lưu trên Google Drive)
  for old in select nspname from pg_namespace where nspname ~ '^bk_[0-9]{8}_[0-9]{6}$' order by nspname desc offset 3 loop
    execute format('drop schema %I cascade', old.nspname);
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('BACKUP', s, jsonb_build_object('note', p_note));
  return s;
end $$;
select public.backup_create('Trước khi cập nhật bản 18');

-- Nhật ký hệ thống: giữ 180 ngày
delete from public.audit_logs where at < now() - interval '180 days';

-- ---------- Đổi tên xe ----------
create or replace function public.acc_truck_rename(p_id uuid, p_name text) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_old text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Nhập tên xe'; end if;
  select name into v_old from public.acc_trucks where id = p_id;
  update public.acc_trucks set name = btrim(p_name), updated_at = now() where id = p_id;
  update public.out_hd_xe set xe = btrim(p_name), updated_at = now() where xe = v_old;
  insert into public.acc_events(truck_id, action, note) values (p_id, 'rename', coalesce(v_old, '') || ' → ' || btrim(p_name));
end $$;
grant execute on function public.acc_truck_rename(uuid, text) to authenticated;

create or replace function public.out_xe_rename(p_old text, p_new text) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if coalesce(btrim(p_new), '') = '' then raise exception 'Nhập tên xe mới'; end if;
  update public.out_hd_xe set xe = btrim(p_new), tu_dong = false, updated_at = now(), updated_by = auth.uid() where xe = p_old;
  get diagnostics n = row_count;
  update public.acc_trucks set name = btrim(p_new), updated_at = now() where name = p_old;
  return n;
end $$;
grant execute on function public.out_xe_rename(text, text) to authenticated;

-- ---------- Dòng sổ: trang + bộ lọc + thống kê (theo quyền người xem) ----------
create index if not exists out_items_stt on public.out_items(stt_so desc nulls last);

create or replace function public.out_items_page(p jsonb) returns jsonb
language plpgsql stable security invoker set search_path = public, app as $$
declare v_mode text := coalesce(p->>'mode', 'acc'); v_f text := nullif(p->>'f', ''); v_q text := nullif(btrim(p->>'q'), '');
        v_hd text := nullif(p->>'hd', ''); v_xe text := nullif(p->>'xe', ''); v_sale text := nullif(p->>'sale', '');
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint;
begin
  with base as (
    select * from public.out_items_v t
     where (v_mode <> 'mine' or (t.sale_id is not null and app.in_tree(t.sale_id)))
       and (v_mode <> 'free' or t.sale_id is null)
       and (v_mode = 'acc' or t.ton > 0.0001)
       and (v_f is null or (v_f = 'ton' and t.ton > 0.0001) or (v_f = 'het' and t.ton <= 0.0001)
            or (v_f = 'nosale' and t.sale_id is null and t.ton > 0.0001) or (v_f = 'daky_nosale' and t.sale_id is null and t.ton <= 0.0001)
            or (v_f = 'nomd' and t.md is null) or (v_f = 'nogia' and t.gia_khach is null and t.ton > 0.0001))
       and (v_hd is null or t.so_hd_vao = v_hd) and (v_xe is null or coalesce(t.xe, '—') = v_xe)
       and (v_sale is null or coalesce(t.sale_id::text, '—') = v_sale)
       and (v_q is null or concat_ws(' ', t.ma_hang, t.ten, t.md, t.nvkd, t.username, t.khach, t.so_hd_vao, t.xe) ilike '%' || v_q || '%'))
  select count(*), coalesce(jsonb_agg(to_jsonb(x) - 'legacy' || jsonb_build_object('legacy', x.legacy) order by x.stt_so desc nulls last, x.ma_hang, x.part)
           filter (where x.rn > v_off and x.rn <= v_off + v_lim), '[]')
    into n, r
    from (select b.*, row_number() over (order by b.stt_so desc nulls last, b.ma_hang, b.part) rn from base b) x;
  return jsonb_build_object('total', n, 'rows', r);
end $$;
grant execute on function public.out_items_page(jsonb) to authenticated;

create or replace function public.out_items_stats(p_mode text) returns jsonb
language sql stable security invoker set search_path = public, app as $$
  select jsonb_build_object(
    'all', count(*), 'ton', count(*) filter (where ton > 0.0001), 'het', count(*) filter (where ton <= 0.0001),
    'nosale', count(*) filter (where sale_id is null and ton > 0.0001), 'daky_nosale', count(*) filter (where sale_id is null and ton <= 0.0001),
    'nomd', count(*) filter (where md is null), 'nogia', count(*) filter (where gia_khach is null and ton > 0.0001),
    'gia_tri', coalesce(sum(ton * coalesce(gia_khach, dg_nhap, 0)) filter (where ton > 0.0001), 0),
    'hd', (select coalesce(jsonb_agg(distinct so_hd_vao), '[]') from public.out_items_v v where (p_mode <> 'mine' or (v.sale_id is not null and app.in_tree(v.sale_id))) and (p_mode <> 'free' or (v.sale_id is null and v.ton > 0.0001))),
    'xe', (select coalesce(jsonb_agg(distinct coalesce(xe, '—')), '[]') from public.out_items_v v where (p_mode <> 'mine' or (v.sale_id is not null and app.in_tree(v.sale_id))) and (p_mode <> 'free' or (v.sale_id is null and v.ton > 0.0001))),
    'sale', (select coalesce(jsonb_agg(distinct coalesce(sale_id::text, '—')), '[]') from public.out_items v where p_mode = 'acc'))
  from public.out_items_v t
  where (p_mode <> 'mine' or (t.sale_id is not null and app.in_tree(t.sale_id))) and (p_mode <> 'free' or t.sale_id is null)
$$;
grant execute on function public.out_items_stats(text) to authenticated;

-- ---------- Phiếu: view có sẵn tổng tiền + trang ----------
drop view if exists public.out_invoices_v;
create view public.out_invoices_v with (security_invoker = true) as
  select i.*, coalesce(a.n, 0) as so_dong, coalesce(a.tt, 0) as tien_hang, coalesce(a.thue, 0) as tien_thue, coalesce(a.duoi_gia, false) as duoi_gia, a.tim
  from public.out_invoices i
  left join (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
                    bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim
               from public.out_invoice_lines l join public.out_items t on t.id = l.item_id group by l.invoice_id) a on a.invoice_id = i.id;
grant select on public.out_invoices_v to authenticated;

create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security invoker set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb;
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c from (select status, count(*) k from public.out_invoices_v where v_sale is null or sale_id = v_sale group by status) z;
  with base as (select * from public.out_invoices_v v
     where (v_st is null and v.status <> 'huy' or v.status = v_st) and (v_sale is null or v.sale_id = v_sale)
       and (v_q is null or concat_ws(' ', v.code, v.buyer_name, v.tax_code, v.so_hd, v.buyer_info, v.tim) ilike '%' || v_q || '%'))
  select count(*), coalesce(jsonb_agg(to_jsonb(x) - 'tim' order by x.status_at desc) filter (where x.rn > v_off and x.rn <= v_off + v_lim), '[]') into n, r
    from (select b.*, row_number() over (order by b.status_at desc) rn from base b) x;
  return jsonb_build_object('total', n, 'rows', r, 'counts', c);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

reset search_path;
