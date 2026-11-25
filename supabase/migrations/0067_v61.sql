-- =====================================================================
-- 0067 · Bản 61 (25/11/2026) — Nạp bù dòng thiếu vào xe đã nạp
--  Nạp xe xong mới thấy thiếu dòng → "➕ Nạp bù dòng thiếu": chỉ THÊM dòng mới vào xe, không sửa / xóa dòng cũ
--  (khác "Nạp lại file": coi file là toàn bộ xe, dòng không có trong file bị xóa).
--  · Bỏ qua dòng đã có trong xe: cùng mã khai báo APT + SL, cùng mã HH APT, hoặc cùng tên APT + SL.
--  · Trùng mã dòng / STT tự sinh (100000+) → tự đánh số mới, không đè dòng cũ.
--  · Dòng "có trên hệ thống nhưng không lên xe" (luồng E) cùng mã khai báo với dòng bù → bỏ (đã lên xe).
--  · HĐ chính thức về sau ghép theo tên + SL như mọi dòng của xe; HĐ đã về trước được ghép lại ngay.
--  Chỉ thêm hàm, không đổi cấu trúc bảng, không đổi dữ liệu đang có.
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 61');

create or replace function public.acc_truck_append(p_truck uuid, p_info jsonb, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare t public.acc_trucks; r jsonb; x public.acc_lines; e public.acc_lines; v_key text; v_n int; v_sale uuid; v_status text; v_lid uuid;
        h int := coalesce((app.setting('accounting')->>'han_sale_gio')::int, 24); v_dup text;
        n_add int := 0; n_e int := 0; v_skip jsonb := '[]'; v_new uuid[] := '{}'; s record; n_block int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin được nạp bù'; end if;
  select * into t from public.acc_trucks where id = p_truck for update;
  if t.id is null then raise exception 'Không tìm thấy xe'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Không có dòng nào để nạp bù'; end if;

  for r in select * from jsonb_array_elements(p_lines) loop
    x := jsonb_populate_record(null::public.acc_lines, r);
    if x.apt_stt is null then
      v_skip := v_skip || jsonb_build_object('ten', coalesce(x.ten_ht, x.ten_apt), 'ly_do', 'Không có trên nháp APT (không lên xe) — không nạp bù'); continue;
    end if;
    -- dòng đã có trong xe
    select case when l.ma_kb_apt is not distinct from x.ma_kb_apt and x.ma_kb_apt is not null and l.sl_apt is not distinct from x.sl_apt then 'Trùng mã khai báo ' || x.ma_kb_apt || ' + SL'
                when coalesce(btrim(x.hh), '') <> '' and l.hh = x.hh then 'Trùng mã HH ' || x.hh
                else 'Trùng tên APT + SL' end || ' với STT ' || coalesce(l.apt_stt::text, '—')
      into v_dup from public.acc_lines l
     where l.truck_id = p_truck and l.apt_stt is not null
       and ((x.ma_kb_apt is not null and l.ma_kb_apt = x.ma_kb_apt and l.sl_apt is not distinct from x.sl_apt)
         or (coalesce(btrim(x.hh), '') <> '' and l.hh = x.hh)
         or (app.hd_ten(l.ten_apt) = app.hd_ten(x.ten_apt) and l.sl_apt is not distinct from x.sl_apt))
     limit 1;
    if v_dup is not null then
      v_skip := v_skip || jsonb_build_object('stt', x.apt_stt, 'ten', x.ten_apt, 'ly_do', v_dup); v_dup := null; continue;
    end if;
    -- STT tự sinh (dòng không có STT trên file) trùng → đánh số tiếp
    if x.apt_stt >= 100000 and exists(select 1 from public.acc_lines where truck_id = p_truck and apt_stt = x.apt_stt) then
      select greatest(100000, coalesce(max(apt_stt), 100000)) + 1 into x.apt_stt from public.acc_lines where truck_id = p_truck and apt_stt >= 100000;
      x.line_key := 'A' || x.apt_stt;
    end if;
    v_key := coalesce(nullif(x.line_key, ''), 'A' || x.apt_stt); v_n := 1;
    while exists(select 1 from public.acc_lines where truck_id = p_truck and line_key = v_key) loop v_n := v_n + 1; v_key := coalesce(nullif(x.line_key, ''), 'A' || x.apt_stt) || '-bu' || v_n; end loop;
    v_sale := coalesce(x.sale_id, app.match_sale(x.sale_name), app.match_sale(x.sale_acc));
    v_status := coalesce(x.status, 'ok');
    insert into public.acc_lines(truck_id, line_key, ma_dong, md, sale_name, sale_acc, sale_id, ma_kh, sys_row, ten_ht, sl_ht, dvt_ht, gia_khach, nk_ht,
      apt_stt, hh, dh, sale_apt, ten_apt, sl_apt, dvt_apt, gia_nhap, gia_note, note_apt, nk_apt, vat, tk_row, ten_tk, hs, sl_tk, dvt_tk, gia_tk_nh, nk_tk, tnk_dv, md_header,
      luong, gia_ap_dung, gia_de_xuat, bien_nt, tt_apt, tt_khach, status, level, issues, notes, phan_hoi, match_score, due_at, updated_at, is_test, ma_kb_apt, match_kind)
    values (p_truck, v_key, x.ma_dong, x.md, x.sale_name, x.sale_acc, v_sale, x.ma_kh, x.sys_row, x.ten_ht, x.sl_ht, x.dvt_ht, x.gia_khach, x.nk_ht,
      x.apt_stt, x.hh, x.dh, x.sale_apt, x.ten_apt, x.sl_apt, x.dvt_apt, x.gia_nhap, x.gia_note, x.note_apt, x.nk_apt, x.vat, x.tk_row, x.ten_tk, x.hs, x.sl_tk, x.dvt_tk, x.gia_tk_nh, x.nk_tk, x.tnk_dv, x.md_header,
      coalesce(x.luong, 'A'), x.gia_ap_dung, x.gia_de_xuat, x.bien_nt, x.tt_apt, x.tt_khach, v_status, coalesce(x.level, 3), coalesce(x.issues, '{}'),
      array_append(coalesce(x.notes, '{}'), 'Nạp bù vào xe' || coalesce(' từ file ' || nullif(p_info->>'file', ''), '') || '.'),
      x.phan_hoi, x.match_score, case when v_status = 'blocked' then now() + make_interval(hours => h) end, now(), t.is_test, x.ma_kb_apt, x.match_kind)
    returning id into v_lid;
    n_add := n_add + 1; v_new := v_new || v_lid;
    -- dòng "không lên xe" cùng mã khai báo → nay đã lên xe
    if x.ma_dong is not null then
      for e in select * from public.acc_lines where truck_id = p_truck and apt_stt is null and ma_dong = x.ma_dong loop
        insert into public.acc_events(line_id, truck_id, action, note, data) values (case when e.reply is null and e.claimed_at is null then null else e.id end, p_truck, 'bu_bo_dong_e',
          'Dòng không lên xe ' || e.ma_dong || ' đã có trên nháp APT nạp bù (STT ' || x.apt_stt || ')', to_jsonb(e));
        if e.reply is null and e.claimed_at is null and not exists(select 1 from public.out_items o where o.acc_line_id = e.id) then
          delete from public.acc_lines where id = e.id;
        else
          update public.acc_lines set status = 'info', due_at = null, issues = '{}',
            notes = array_prepend('Đã có trên nháp APT nạp bù (STT ' || x.apt_stt || ').', notes), updated_at = now() where id = e.id;
        end if;
        n_e := n_e + 1;
      end loop;
    end if;
  end loop;

  if n_add > 0 then
    update public.acc_trucks set
      stats = coalesce(stats, '{}') || (select jsonb_build_object('apt', count(*) filter (where apt_stt is not null), 'ok', count(*) filter (where status = 'ok'),
                 'blocked', count(*) filter (where status = 'blocked'), 'info', count(*) filter (where status = 'info'),
                 'tt_apt', coalesce(sum(tt_apt) filter (where apt_stt is not null), 0), 'bu', coalesce((t.stats->>'bu')::int, 0) + n_add)
               from public.acc_lines where truck_id = p_truck),
      files = coalesce(files, '{}') || jsonb_build_object('bu', coalesce(files->'bu', '[]') || jsonb_build_array(jsonb_build_object('file', p_info->>'file', 'by', p_info->>'by', 'at', now(), 'n', n_add))),
      warnings = warnings || coalesce(array(select jsonb_array_elements_text(p_info->'warnings')), '{}'),
      updated_at = now()
    where id = p_truck;
  end if;
  insert into public.acc_events(truck_id, action, note, data) values (p_truck, 'append', coalesce(p_info->>'file', ''),
    jsonb_build_object('them', n_add, 'bo_qua', v_skip, 'bo_dong_e', n_e));
  if n_add > 0 and not t.is_test then
    for s in select sale_id, count(*) c from public.acc_lines where id = any(v_new) and status = 'blocked' and sale_id is not null group by sale_id loop
      perform app.notify(s.sale_id, 'acc', 'Hóa đơn APT: ' || s.c || ' dòng nạp bù cần bạn xử lý', t.name || ' · hạn ' || h || 'h', '#/acc/mine');
    end loop;
    select count(*) into n_block from public.acc_lines where id = any(v_new) and status = 'blocked' and sale_id is null;
    if n_block > 0 then perform app.notify_roles(array['ke_toan'], 'acc', n_block || ' dòng nạp bù bị chặn chưa ghép được sale', t.name, '#/acc?truck=' || p_truck); end if;
  end if;
  return jsonb_build_object('them', n_add, 'bo_qua', v_skip, 'bo_dong_e', n_e);
end $$;
revoke all on function public.acc_truck_append(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.acc_truck_append(uuid, jsonb, jsonb) to authenticated;
