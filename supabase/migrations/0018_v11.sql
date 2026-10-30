-- =====================================================================
-- 0018 · Bản 11: xuất thẳng theo từng xe, nạp thử không báo sale, xóa xe, chống trùng, lưu file gốc lên Drive, theo dõi HĐ chưa về / xuất muộn
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 11');

alter table public.acc_trucks add column if not exists is_test boolean not null default false;
alter table public.acc_trucks add column if not exists md_xuat_thang text[] not null default '{}';
alter table public.acc_trucks add column if not exists xt_keys text[] not null default '{}';
alter table public.acc_trucks add column if not exists file_links jsonb not null default '{}';
alter table public.acc_lines add column if not exists is_test boolean not null default false;
create index if not exists acc_lines_open on public.acc_lines(truck_id) where inv_no is null;
update public.settings set value = (value - 'md_xuat_thang') || jsonb_build_object('han_hd_ngay', coalesce((value->>'han_hd_ngay')::int, 15)) where key = 'accounting';

-- Xe nạp thử: sale, người duyệt không thấy
drop policy if exists acc_lines_read on public.acc_lines;
create policy acc_lines_read on public.acc_lines for select to authenticated
  using (app.is_acc() or (not is_test and (app.in_tree(sale_id) or (app.is_acc_approver() and status = 'pending_approval'))));

create or replace function public.acc_truck_save(p_truck uuid, p_info jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare v_id uuid := p_truck; r jsonb; v_sale uuid; v_old public.acc_lines; v_status text; v_due timestamptz;
        h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); n_block int; s record; v_keys text[] := '{}'; v_test boolean;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán được nạp đối soát'; end if;
  if v_id is null then
    insert into public.acc_trucks(name, truck_date, files, stats, warnings, is_test, md_xuat_thang, xt_keys)
    values (p_info->>'name', nullif(p_info->>'truck_date','')::date, coalesce(p_info->'files','{}'), coalesce(p_info->'stats','{}'),
            coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), '{}'), coalesce((p_info->>'is_test')::boolean, false),
            coalesce(array(select jsonb_array_elements_text(p_info->'md_xuat_thang')), '{}'), coalesce(array(select jsonb_array_elements_text(p_info->'xt_keys')), '{}'))
    returning id into v_id;
  else
    update public.acc_trucks set name = coalesce(p_info->>'name', name), truck_date = coalesce(nullif(p_info->>'truck_date','')::date, truck_date),
      files = coalesce(p_info->'files', files), stats = coalesce(p_info->'stats', stats),
      warnings = coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), warnings),
      md_xuat_thang = coalesce(array(select jsonb_array_elements_text(p_info->'md_xuat_thang')), md_xuat_thang),
      xt_keys = coalesce(array(select jsonb_array_elements_text(p_info->'xt_keys')), xt_keys), updated_at = now() where id = v_id;
  end if;
  select is_test into v_test from public.acc_trucks where id = v_id;
  for r in select * from jsonb_array_elements(p_lines) loop
    v_keys := v_keys || (r->>'line_key');
    v_sale := coalesce(nullif(r->>'sale_id','')::uuid, app.match_sale(r->>'sale_name'), app.match_sale(r->>'sale_acc'));
    select * into v_old from public.acc_lines where truck_id = v_id and line_key = r->>'line_key';
    v_status := r->>'status';
    -- Đã được duyệt mở chặn thì giữ; sale đã trả lời mà vẫn chặn → giữ trạng thái đã trả lời
    if v_old.id is not null and v_status = 'blocked' and v_old.status in ('approved','replied','pending_approval') then v_status := v_old.status; end if;
    v_due := case when v_status = 'blocked' then coalesce(v_old.due_at, now() + make_interval(hours => h)) else null end;
    insert into public.acc_lines as l(truck_id, line_key, ma_dong, md, sale_name, sale_acc, sale_id, ma_kh, sys_row, ten_ht, sl_ht, dvt_ht, gia_khach, nk_ht,
      apt_stt, hh, dh, sale_apt, ten_apt, sl_apt, dvt_apt, gia_nhap, gia_note, note_apt, nk_apt, vat, tk_row, ten_tk, hs, sl_tk, dvt_tk, gia_tk_nh, nk_tk, tnk_dv, md_header,
      luong, gia_ap_dung, gia_de_xuat, bien_nt, tt_apt, tt_khach, status, level, issues, notes, phan_hoi, match_score, due_at, updated_at, is_test)
    select v_id, x.line_key, x.ma_dong, x.md, x.sale_name, x.sale_acc, v_sale, x.ma_kh, x.sys_row, x.ten_ht, x.sl_ht, x.dvt_ht, x.gia_khach, x.nk_ht,
      x.apt_stt, x.hh, x.dh, x.sale_apt, x.ten_apt, x.sl_apt, x.dvt_apt, x.gia_nhap, x.gia_note, x.note_apt, x.nk_apt, x.vat, x.tk_row, x.ten_tk, x.hs, x.sl_tk, x.dvt_tk, x.gia_tk_nh, x.nk_tk, x.tnk_dv, x.md_header,
      x.luong, x.gia_ap_dung, x.gia_de_xuat, x.bien_nt, x.tt_apt, x.tt_khach, v_status, x.level, coalesce(x.issues, '{}'), coalesce(x.notes, '{}'), x.phan_hoi, x.match_score, v_due, now(), v_test
    from jsonb_populate_record(null::public.acc_lines, r) x
    on conflict (truck_id, line_key) do update set ma_dong = excluded.ma_dong, md = excluded.md, sale_name = excluded.sale_name, sale_acc = excluded.sale_acc, sale_id = excluded.sale_id,
      ma_kh = excluded.ma_kh, sys_row = excluded.sys_row, ten_ht = excluded.ten_ht, sl_ht = excluded.sl_ht, dvt_ht = excluded.dvt_ht, gia_khach = excluded.gia_khach, nk_ht = excluded.nk_ht,
      apt_stt = excluded.apt_stt, hh = excluded.hh, dh = excluded.dh, sale_apt = excluded.sale_apt, ten_apt = excluded.ten_apt, sl_apt = excluded.sl_apt, dvt_apt = excluded.dvt_apt,
      gia_nhap = excluded.gia_nhap, gia_note = excluded.gia_note, note_apt = excluded.note_apt, nk_apt = excluded.nk_apt, vat = excluded.vat, tk_row = excluded.tk_row, ten_tk = excluded.ten_tk,
      hs = excluded.hs, sl_tk = excluded.sl_tk, dvt_tk = excluded.dvt_tk, gia_tk_nh = excluded.gia_tk_nh, nk_tk = excluded.nk_tk, tnk_dv = excluded.tnk_dv, md_header = excluded.md_header,
      luong = excluded.luong, gia_ap_dung = excluded.gia_ap_dung, gia_de_xuat = excluded.gia_de_xuat, bien_nt = excluded.bien_nt, tt_apt = excluded.tt_apt, tt_khach = excluded.tt_khach,
      status = excluded.status, level = excluded.level, issues = excluded.issues, notes = excluded.notes, phan_hoi = excluded.phan_hoi, match_score = excluded.match_score,
      due_at = excluded.due_at, updated_at = now(), is_test = excluded.is_test;
  end loop;
  -- Dòng cũ không còn trong lần nạp mới → xóa (đã có nhật ký)
  delete from public.acc_lines where truck_id = v_id and line_key <> all(v_keys);
  insert into public.acc_events(truck_id, action, note, data) values (v_id, case when p_truck is null then 'import' else 'reimport' end, p_info->>'name', p_info->'stats');
  -- Báo sale có dòng bị chặn (xe nạp thử: không báo ai)
  if v_test then return v_id; end if;
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', coalesce(p_info->>'name','') || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
  select count(*) into n_block from public.acc_lines where truck_id = v_id and status = 'blocked' and sale_id is null;
  if n_block > 0 then perform app.notify_roles(array['ke_toan'], 'acc', n_block || ' dòng bị chặn chưa ghép được sale', p_info->>'name', '#/acc?truck=' || v_id); end if;
  return v_id;
end $$;

-- Xóa xe (nạp nhầm/nạp thử). Xe đã ghép HĐ chỉ Admin/BGĐ xóa được.
create or replace function public.acc_truck_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare t public.acc_trucks; n_inv int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  select * into t from public.acc_trucks where id = p_id; if t.id is null then raise exception 'Không tìm thấy xe'; end if;
  select count(*) into n_inv from public.acc_lines where truck_id = p_id and inv_id is not null;
  if n_inv > 0 and not app.is_admin() then raise exception 'Xe đã ghép % dòng HĐ — chỉ Admin/BGĐ được xóa', n_inv; end if;
  insert into public.audit_logs(action, table_name, record_id, diff)
    values ('DELETE', 'acc_trucks', p_id::text, jsonb_build_object('name', t.name, 'truck_date', t.truck_date, 'is_test', t.is_test, 'stats', t.stats, 'files', t.files,
            'lines', (select count(*) from public.acc_lines where truck_id = p_id), 'replied', (select count(*) from public.acc_lines where truck_id = p_id and reply is not null)));
  delete from public.acc_trucks where id = p_id;
end $$;
grant execute on function public.acc_truck_delete(uuid) to authenticated;

-- Chuyển xe nạp thử thành chính thức: báo sale, tính hạn từ lúc này
create or replace function public.acc_truck_publish(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); s record; t public.acc_trucks;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  update public.acc_trucks set is_test = false, updated_at = now() where id = p_id and is_test returning * into t;
  if t.id is null then raise exception 'Xe không ở chế độ nạp thử'; end if;
  update public.acc_lines set is_test = false, due_at = case when status = 'blocked' then now() + make_interval(hours => h) end where truck_id = p_id;
  insert into public.acc_events(truck_id, action, note) values (p_id, 'publish', t.name);
  for s in select sale_id, count(*) c from public.acc_lines where truck_id = p_id and status = 'blocked' and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng cần bạn xử lý', t.name || ' · hạn ' || h || 'h', '#/acc/mine');
  end loop;
end $$;
grant execute on function public.acc_truck_publish(uuid) to authenticated;

-- Đánh dấu / bỏ đánh dấu APT xuất thẳng cho 1 dòng (lưu theo xe để nạp lại vẫn giữ)
create or replace function public.acc_line_xuat_thang(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  select * into l from public.acc_lines where id = p_id for update; if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if p_on then
    update public.acc_trucks set xt_keys = array(select distinct x from unnest(xt_keys || l.line_key) x) where id = l.truck_id;
    update public.acc_lines set luong = 'C', status = 'info', phan_hoi = case when apt_stt is not null then 'XUẤT THẲNG' end, due_at = null,
      notes = array_prepend('Kế toán đánh dấu APT xuất thẳng.', notes), updated_at = now() where id = p_id;
  else
    update public.acc_trucks set xt_keys = array_remove(xt_keys, l.line_key), md_xuat_thang = array_remove(md_xuat_thang, l.md) where id = l.truck_id;
    update public.acc_lines set luong = 'A', status = 'blocked', phan_hoi = 'CHỜ KẾ TOÁN — nạp lại file', due_at = null,
      issues = array['Kế toán bỏ đánh dấu xuất thẳng → bấm “Nạp lại file” để hệ thống chấm lại dòng này.'], updated_at = now() where id = p_id;
  end if;
  insert into public.acc_events(line_id, truck_id, action) values (p_id, l.truck_id, case when p_on then 'xuat_thang' else 'bo_xuat_thang' end);
end $$;
grant execute on function public.acc_line_xuat_thang(uuid, boolean) to authenticated;

-- Nhắc hạn: bỏ xe nạp thử
create or replace function app.job_acc_remind() returns void language plpgsql security definer set search_path = public, app as $$
declare s record; n int;
begin
  for s in select sale_id, count(*) c from public.acc_lines where status = 'blocked' and not is_test and due_at < now() and sale_id is not null group by sale_id loop
    perform app.notify(s.sale_id, 'acc', 'Quá hạn: ' || s.c || ' dòng HĐ APT chưa xử lý', 'Mở Kế toán – Hóa đơn → Việc của tôi', '#/acc/mine');
  end loop;
  select count(*) into n from public.acc_lines where status = 'blocked' and not is_test and due_at < now();
  if n > 0 then perform app.telegram('acc_overdue', '⏰ ' || n || ' dòng HĐ APT quá hạn sale chưa xử lý.'); end if;
end $$;

reset search_path;
