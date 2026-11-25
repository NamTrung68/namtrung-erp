-- =====================================================================
-- 0066 · Bản 60 (25/11/2026) — Admin sửa trực tiếp dòng đối soát xe APT
--  Admin / BGĐ sửa ngay trên dòng: Sale, Mã đơn MD, Khách (username), Mã khai báo, Tên hàng APT, SL APT / tờ khai,
--  Giá APT nháp, Giá NOTE, Giá xuất khách, Thuế VAT, Thuế NK (hệ thống / tờ khai). Lý do bắt buộc, nhật ký cũ → mới.
--  · Tính lại biên NT, tiền APT, tiền khách, giá đề xuất, phản hồi APT; dòng đang Chốt mà biên mới dưới khung / giá khách 0 → trả lại sale.
--  · "Sửa theo cả đơn": Sale / Khách / MD áp cho mọi dòng cùng MD trong xe.
--  · Dòng đã có HĐ đầu ra (dòng sổ) → đẩy cập nhật sang, đối chiếu lại lệch HĐ ký; phiếu xuất HĐ đã gửi kế toán / xuất nháp / ký → CHẶN.
--  · Nạp lại file: giữ phần Admin sửa tay (cột manual), ghi chú dòng nào file mới khác.
--  Chỉ THÊM cột + hàm; không đổi dữ liệu đang có (cột mới mặc định rỗng).
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 60');

-- trường đã sửa tay: { "<tên trường>": { "goc": giá trị file, "moi": giá trị sửa, "by": uuid, "at": thời điểm } }
alter table public.acc_lines add column if not exists manual jsonb not null default '{}';

-- Tính lại số liệu 1 dòng sau khi sửa (cùng công thức lúc nạp file — lib/doisoat.ts reconcile)
--  p_gia: có sửa giá (nháp / NOTE / khách) → tính lại giá đề xuất + phản hồi APT + chấm lại trạng thái dòng đang Chốt
create or replace function app.acc_line_recalc(p_id uuid, p_gia boolean) returns text
language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; c jsonb := coalesce(app.setting('accounting'), '{}');
        lo numeric := coalesce((c->>'bien_nt_min')::numeric, 0.025); hi numeric := coalesce((c->>'bien_nt_max')::numeric, 0.04);
        tol numeric := coalesce((c->>'dung_sai_bien')::numeric, 0); tgt numeric := coalesce((c->>'bien_muc_tieu')::numeric, 0.03);
        chan numeric; ga numeric; gk numeric; sl numeric; b numeric; de numeric; ph text; v_block text;
begin
  select * into l from public.acc_lines where id = p_id for update; if l.id is null then return null; end if;
  chan := greatest(hi, coalesce((c->>'bien_chan_max')::numeric, 0.07));
  ga := coalesce(nullif(l.gia_note, 0), l.gia_nhap); gk := nullif(l.gia_khach, 0); sl := coalesce(l.sl_apt, l.sl_ht, 0);
  b := case when gk > 0 and ga > 0 then gk / ga - 1 end;
  if not p_gia then
    update public.acc_lines set tt_apt = round(coalesce(gia_ap_dung, ga, 0) * sl), tt_khach = case when gk > 0 then round(gk * sl) end where id = p_id;
    return null;
  end if;
  de := case when l.reply = 'de_xuat_gia' and l.reply_price > 0 then l.reply_price
             when l.luong in ('A','B') and b is not null and (b > hi + tol or b < lo - tol) then round(gk / (1 + tgt)) end;
  -- dòng đang Chốt mà sau khi sửa không còn xuất được → trả lại sale
  if l.status = 'ok' and l.luong = 'A' and l.apt_stt is not null then
    if gk is null then v_block := 'Giá khách = 0 sau khi Admin sửa → sale nhập giá khách đã chốt.';
    elsif b is not null and b < lo - tol then v_block := 'Biên NT ' || round(b * 100, 2) || '% < ' || round(lo * 100, 2) || '% sau khi Admin sửa → đề xuất APT xuất giá ' || de || ' hoặc sale sửa giá khách.';
    elsif b is not null and b > chan + tol then v_block := 'Biên NT ' || round(b * 100, 2) || '% > ' || round(chan * 100, 2) || '% sau khi Admin sửa → đề xuất APT xuất giá ' || de || '.';
    end if;
  end if;
  ph := case when l.apt_stt is null then l.phan_hoi
             when v_block is not null then 'CHỜ SALE — chưa xuất'
             when l.status not in ('ok','approved') then l.phan_hoi
             when l.luong = 'C' then 'XUẤT THẲNG'
             when l.luong = 'D' then l.phan_hoi
             when l.luong = 'B' and l.status <> 'approved' then l.phan_hoi
             when de is not null and b > hi + tol then 'XUẤT GIÁ ' || round(de)::bigint::text
             when l.gia_note is not null and abs(l.gia_note - coalesce(l.gia_nhap, 0)) > 0.5 then 'XUẤT GIÁ ' || round(l.gia_note)::bigint::text
             else 'CHỐT' end;
  update public.acc_lines set gia_ap_dung = ga, gia_de_xuat = de, bien_nt = b,
    tt_apt = round(coalesce(ga, 0) * sl), tt_khach = case when gk > 0 then round(gk * sl) end, phan_hoi = ph,
    status = case when v_block is not null then 'blocked' else status end,
    due_at = case when v_block is not null then now() + make_interval(hours => coalesce((c->>'han_sale_gio')::int, 24)) else due_at end,
    issues = case when v_block is not null then array_append(issues, v_block) else issues end
  where id = p_id;
  return v_block;
end $$;

-- Phiếu xuất HĐ đã vượt bước soạn của các dòng sổ gắn với dòng đối soát (null = chưa có / chỉ đang soạn)
create or replace function app.acc_line_out_locked(p_id uuid) returns text language sql stable security definer set search_path = public, app as $$
  select string_agg(distinct i.code || ' (' || case i.status when 'cho_nhap' then 'chờ kế toán xuất nháp' when 'da_nhap' then 'đã xuất nháp'
           when 'xac_nhan_ky' then 'sale xác nhận ký' when 'da_ky' then 'đã ký' else i.status end || ')', ', ')
    from public.out_items o join public.out_invoice_lines il on il.item_id = o.id join public.out_invoices i on i.id = il.invoice_id
   where o.acc_line_id = p_id and i.status in ('cho_nhap','da_nhap','xac_nhan_ky','da_ky')
$$;

-- Admin sửa trực tiếp 1 dòng (p_cung_don: Sale / Khách / MD áp cho mọi dòng cùng MD trong xe)
create or replace function public.acc_line_admin_edit(p_id uuid, p_patch jsonb, p_note text, p_cung_don boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; o public.acc_lines; k text; v_ids uuid[]; v_id uuid; v_lock text; v_block text; v_warn text[] := '{}';
        f_line text[] := array['ma_dong','ten_apt','sl_apt','sl_tk','gia_nhap','gia_note','gia_khach','vat','nk_ht','nk_tk'];
        f_don text[] := array['sale_id','ma_kh','md'];
        f_num text[] := array['sl_apt','sl_tk','gia_nhap','gia_note','gia_khach','vat','nk_ht','nk_tk'];
        v_new jsonb; v_old jsonb; v_chg jsonb; v_val jsonb; v_gia boolean; v_a boolean; n int := 0; r record; v_txt text; v_num numeric;
begin
  if not app.has_role('admin', 'bgd') then raise exception 'Chỉ Admin / BGĐ được sửa trực tiếp dòng đối soát'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'Nhập lý do sửa'; end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}' then raise exception 'Không có thay đổi'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any(f_line) or k = any(f_don)) then raise exception 'Trường "%" không sửa được', k; end if;
  end loop;
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng đối soát'; end if;

  -- chuẩn hóa + kiểm giá trị mới
  v_new := '{}';
  for k, v_val in select * from jsonb_each(p_patch) loop
    v_txt := nullif(btrim(v_val #>> '{}'), '');
    if k = any(f_num) then
      if v_txt is not null then
        begin v_num := replace(v_txt, ',', '.')::numeric; exception when others then raise exception 'Giá trị "%" của % không phải số', v_txt, k; end;
        if v_num < 0 then raise exception '% không được âm', k; end if;
        if k in ('vat','nk_ht','nk_tk') and v_num > 1 then raise exception 'Thuế suất nhập dạng tỷ lệ (8%% = 0.08)'; end if;
        if k in ('sl_apt','sl_tk') and v_num = 0 then raise exception 'Số lượng phải > 0'; end if;
        v_new := v_new || jsonb_build_object(k, v_num);
      else
        if k in ('sl_apt','gia_nhap') and l.apt_stt is not null then raise exception '% của dòng APT không được để trống', k; end if;
        v_new := v_new || jsonb_build_object(k, null);
      end if;
    elsif k = 'sale_id' then
      if v_txt is null then raise exception 'Chọn sale'; end if;
      if not exists(select 1 from public.profiles where id = v_txt::uuid) then raise exception 'Không tìm thấy nhân sự'; end if;
      v_new := v_new || jsonb_build_object(k, v_txt);
    elsif k = 'md' then
      if v_txt is not null and app.norm_md(v_txt) is null then raise exception 'Mã đơn "%" không hợp lệ', v_txt; end if;
      v_new := v_new || jsonb_build_object(k, app.norm_md(v_txt));
    elsif k = 'ma_kh' then v_new := v_new || jsonb_build_object(k, app.norm_username(v_txt));
    elsif k = 'ma_dong' then v_new := v_new || jsonb_build_object(k, upper(v_txt));
    else v_new := v_new || jsonb_build_object(k, v_txt);
    end if;
  end loop;

  -- dòng áp dụng
  v_ids := array[p_id];
  if p_cung_don and l.md is not null and exists(select 1 from jsonb_object_keys(v_new) x where x = any(f_don)) then
    v_ids := array(select id from public.acc_lines where truck_id = l.truck_id and md = l.md order by apt_stt nulls last);
  end if;
  -- chặn khi phiếu xuất HĐ đã qua bước soạn
  foreach v_id in array v_ids loop
    v_lock := app.acc_line_out_locked(v_id);
    if v_lock is not null then raise exception 'Dòng đã nằm trong phiếu xuất HĐ %: hủy hoặc yêu cầu sửa phiếu trước khi sửa dòng đối soát', v_lock; end if;
  end loop;

  foreach v_id in array v_ids loop
    select * into o from public.acc_lines where id = v_id for update;
    v_old := to_jsonb(o); v_chg := '{}';
    for k, v_val in select * from jsonb_each(v_new) loop
      if v_id <> p_id and not (k = any(f_don)) then continue; end if;          -- dòng khác của đơn: chỉ Sale / Khách / MD
      if (v_old->k) is not distinct from v_val
         or (k = any(f_num) and v_val <> 'null' and v_old->>k is not null and (v_old->>k)::numeric = (v_val #>> '{}')::numeric) then continue; end if;
      v_chg := v_chg || jsonb_build_object(k, jsonb_build_object('cu', v_old->k, 'moi', v_val));
    end loop;
    if v_chg = '{}' then continue; end if;
    n := n + 1;
    update public.acc_lines set
      sale_id   = case when v_chg ? 'sale_id'   then (v_new->>'sale_id')::uuid else sale_id end,
      sale_acc  = case when v_chg ? 'sale_id'   then (select full_name from public.profiles where id = (v_new->>'sale_id')::uuid) else sale_acc end,
      md        = case when v_chg ? 'md'        then v_new->>'md' else md end,
      ma_kh     = case when v_chg ? 'ma_kh'     then v_new->>'ma_kh' else ma_kh end,
      ma_dong   = case when v_chg ? 'ma_dong'   then v_new->>'ma_dong' else ma_dong end,
      ten_apt   = case when v_chg ? 'ten_apt'   then v_new->>'ten_apt' else ten_apt end,
      sl_apt    = case when v_chg ? 'sl_apt'    then (v_new->>'sl_apt')::numeric else sl_apt end,
      sl_tk     = case when v_chg ? 'sl_tk'     then (v_new->>'sl_tk')::numeric else sl_tk end,
      gia_nhap  = case when v_chg ? 'gia_nhap'  then (v_new->>'gia_nhap')::numeric else gia_nhap end,
      gia_note  = case when v_chg ? 'gia_note'  then (v_new->>'gia_note')::numeric else gia_note end,
      gia_khach = case when v_chg ? 'gia_khach' then (v_new->>'gia_khach')::numeric else gia_khach end,
      vat       = case when v_chg ? 'vat'       then (v_new->>'vat')::numeric else vat end,
      nk_ht     = case when v_chg ? 'nk_ht'     then (v_new->>'nk_ht')::numeric else nk_ht end,
      nk_tk     = case when v_chg ? 'nk_tk'     then (v_new->>'nk_tk')::numeric else nk_tk end,
      tnk_dv    = case when v_chg ? 'nk_tk' and gia_tk_nh is not null then round(gia_tk_nh * coalesce((v_new->>'nk_tk')::numeric, 0), 4) else tnk_dv end,
      -- bỏ cảnh báo đã hết hiệu lực
      issues = array(select x from unnest(issues) x where not (
                 (v_chg ? 'sale_id' and x like 'Tên sale %')
              or ((v_chg ? 'ma_kh') and (x like 'Thiếu username%' or x like 'USERNAME trùng số đơn%'))
              or ((v_chg ? 'nk_ht' or v_chg ? 'nk_tk') and x like 'Thuế NK %')
              or ((v_chg ? 'sl_apt') and x like 'Lệch số lượng%'))),
      manual = manual || (select coalesce(jsonb_object_agg(e.key, jsonb_build_object('goc', coalesce(manual->e.key->'goc', e.value->'cu'), 'moi', e.value->'moi', 'by', auth.uid(), 'at', now())), '{}')
                            from jsonb_each(v_chg) e),
      updated_at = now()
    where id = v_id;
    v_gia := v_chg ?| array['gia_nhap','gia_note','gia_khach'];
    v_block := null;  -- chỉ tính lại khi đổi giá / SL APT (sửa sale, khách… không đụng số tiền đang có)
    if v_gia or (v_chg ? 'sl_apt') then v_block := app.acc_line_recalc(v_id, v_gia); end if;
    insert into public.acc_events(line_id, truck_id, action, note, data) values (v_id, o.truck_id, 'admin_edit', btrim(p_note),
      jsonb_build_object('thay_doi', v_chg, 'cung_don', v_id <> p_id, 'tra_sale', v_block));
    if v_block is not null then v_warn := array_append(v_warn, 'Trả lại sale: ' || v_block); end if;

    -- đồng bộ dòng sổ HĐ đầu vào đã gắn với dòng này (MD / khách / sale / giá khách do trigger acc_line_out đẩy)
    if v_chg ? 'ma_dong' then
      for r in select id from public.out_items where acc_line_id = v_id and coalesce(match_src, '') in ('ten','hd_xml') loop
        update public.out_items set ma_kb = nullif(v_new->>'ma_dong', ''), updated_at = now() where id = r.id;
        perform app.out_item_automa(r.id);
      end loop;
    end if;
    v_a := v_chg ?| array['ten_apt','sl_apt','gia_nhap','gia_note','vat','gia_khach'];
    if v_a then
      select * into o from public.acc_lines where id = v_id;
      -- dòng HĐ ký đã ghép: đối chiếu lại (khớp → tự mở khóa; kế toán đã chấp nhận lệch → giữ)
      update public.out_items t set lech = app.out_item_check(t, o) is not null, lech_note = app.out_item_check(t, o)
       where t.acc_line_id = v_id and coalesce(t.match_src, '') in ('ten','hd_xml') and t.lech_ok_at is null;
      -- dòng HĐ ký chưa ghép được nháp mà nay trùng tên → ghép lại
      if not o.is_test and o.apt_stt is not null then
        for r in select t.id from public.out_items t where t.acc_line_id is null and coalesce(t.match_src, '') not in ('tay','ton')
                    and app.hd_ten(t.ten) = app.hd_ten(o.ten_apt) and not app.out_item_has_inv(t.id) loop
          perform app.out_item_match(r.id); perform app.out_item_automa(r.id);
        end loop;
      end if;
    end if;
    if exists(select 1 from public.out_items t join public.out_invoice_lines il on il.item_id = t.id join public.out_invoices i on i.id = il.invoice_id
               where t.acc_line_id = v_id and i.status = 'soan') and v_chg ?| array['gia_khach','sale_id','ma_kh','md'] then
      v_warn := array_append(v_warn, 'Có phiếu xuất HĐ đang soạn chứa dòng này — giá / người mua trên phiếu không tự đổi, báo sale kiểm lại phiếu.');
    end if;
    -- báo sale (mới) của dòng
    select * into o from public.acc_lines where id = v_id;
    if not o.is_test and o.sale_id is not null and o.sale_id <> auth.uid() then
      perform app.notify(o.sale_id, 'acc', 'Admin sửa dòng đối soát ' || coalesce(o.md, o.ma_dong, '') || coalesce(' · STT APT ' || o.apt_stt, ''),
        btrim(p_note) || coalesce(' · ' || v_block, ''), '#/acc/mine');
    end if;
    if (v_chg ? 'sale_id') and not o.is_test and (v_chg->'sale_id'->>'cu') is not null and (v_chg->'sale_id'->>'cu')::uuid <> o.sale_id then
      perform app.notify((v_chg->'sale_id'->>'cu')::uuid, 'acc', 'Dòng đối soát ' || coalesce(o.md, '') || ' đã chuyển cho sale khác', btrim(p_note), '#/acc/mine');
    end if;
  end loop;
  return jsonb_build_object('n', n, 'warn', to_jsonb(array(select distinct x from unnest(v_warn) x)));
end $$;
revoke all on function public.acc_line_admin_edit(uuid, jsonb, text, boolean) from public, anon;
grant execute on function public.acc_line_admin_edit(uuid, jsonb, text, boolean) to authenticated;

-- Nạp lại file: áp lại trường Admin đã sửa tay, ghi chú trường nào file mới khác
create or replace function app.acc_apply_manual(p_old public.acc_lines, p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare m jsonb := coalesce(p_old.manual, '{}'); n jsonb; o jsonb; k text; v_diff text[] := '{}';
        ten jsonb := '{"sale_id":"Sale","md":"MD","ma_kh":"Khách","ma_dong":"Mã khai báo","ten_apt":"Tên APT","sl_apt":"SL APT","sl_tk":"SL tờ khai","gia_nhap":"Giá APT nháp","gia_note":"Giá NOTE","gia_khach":"Giá khách","vat":"VAT","nk_ht":"Thuế NK HT","nk_tk":"Thuế NK TK"}';
begin
  if m = '{}' then return; end if;
  select to_jsonb(l) into n from public.acc_lines l where id = p_id; o := to_jsonb(p_old);
  for k in select jsonb_object_keys(m) loop
    if (n->k) is distinct from (o->k) and (n->k) is distinct from (m->k->'goc') then v_diff := v_diff || coalesce(ten->>k, k); end if;
  end loop;
  update public.acc_lines set
    sale_id = case when m ? 'sale_id' then p_old.sale_id else sale_id end, sale_acc = case when m ? 'sale_id' then p_old.sale_acc else sale_acc end,
    md = case when m ? 'md' then p_old.md else md end, ma_kh = case when m ? 'ma_kh' then p_old.ma_kh else ma_kh end,
    ma_dong = case when m ? 'ma_dong' then p_old.ma_dong else ma_dong end, ten_apt = case when m ? 'ten_apt' then p_old.ten_apt else ten_apt end,
    sl_apt = case when m ? 'sl_apt' then p_old.sl_apt else sl_apt end, sl_tk = case when m ? 'sl_tk' then p_old.sl_tk else sl_tk end,
    gia_nhap = case when m ? 'gia_nhap' then p_old.gia_nhap else gia_nhap end, gia_note = case when m ? 'gia_note' then p_old.gia_note else gia_note end,
    gia_khach = case when m ? 'gia_khach' then p_old.gia_khach else gia_khach end, vat = case when m ? 'vat' then p_old.vat else vat end,
    nk_ht = case when m ? 'nk_ht' then p_old.nk_ht else nk_ht end, nk_tk = case when m ? 'nk_tk' then p_old.nk_tk else nk_tk end,
    tnk_dv = case when m ? 'nk_tk' then p_old.tnk_dv else tnk_dv end,
    manual = m,
    notes = array_prepend('Nạp lại file: giữ phần Admin sửa tay (' || (select string_agg(coalesce(ten->>x, x), ', ') from jsonb_object_keys(m) x) || ')'
              || case when cardinality(v_diff) > 0 then ' — file mới khác ở: ' || array_to_string(v_diff, ', ') else '' end || '.', notes)
  where id = p_id;
  if m ?| array['gia_nhap','gia_note','gia_khach'] then perform app.acc_line_recalc(p_id, true);
  elsif m ?| array['sl_apt'] then perform app.acc_line_recalc(p_id, false); end if;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, p_old.truck_id, 'giu_sua_tay',
    case when cardinality(v_diff) > 0 then 'File mới khác: ' || array_to_string(v_diff, ', ') end, jsonb_build_object('manual', m));
end $$;

-- acc_keep_manual (bản 32) giữ nguyên, thêm bước áp lại phần Admin sửa tay ở cuối
create or replace function app.acc_keep_manual(p_old public.acc_lines, p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare n public.acc_lines;
begin
  select * into n from public.acc_lines where id = p_id;
  -- sale/MD/giá khách đã nhận/gán/chốt tay mà file vẫn trống → giữ
  update public.acc_lines set
    sale_id = case when n.sale_id is null or n.sale_id = p_old.released_from then case when p_old.reply = 'nham' and p_old.reply_sub = 'khong_phai' then p_old.sale_id else coalesce(p_old.sale_id, n.sale_id) end else n.sale_id end,
    md = case when p_old.reply = 'nham' or p_old.claimed_at is not null then coalesce(p_old.md, n.md) else coalesce(n.md, p_old.md) end,
    ma_dong = case when p_old.reply = 'nham' or p_old.claimed_at is not null then coalesce(p_old.ma_dong, n.ma_dong) else n.ma_dong end, gia_khach = coalesce(nullif(n.gia_khach, 0), nullif(p_old.gia_khach, 0), n.gia_khach),
    ma_kh = case when coalesce(n.ma_kh, '') = '' and not app.kh_la_don(p_old.ma_kh, coalesce(n.md, p_old.md)) and coalesce(n.md, p_old.md) is not distinct from p_old.md then p_old.ma_kh else n.ma_kh end,
    released_from = p_old.released_from, claim_md = p_old.claim_md, claim_gia = p_old.claim_gia, claimed_by = p_old.claimed_by, claimed_at = p_old.claimed_at,
    reply = p_old.reply, reply_sub = p_old.reply_sub, reply_price = p_old.reply_price, reply_note = p_old.reply_note, replied_by = p_old.replied_by, replied_at = p_old.replied_at
  where id = p_id;
  if n.status <> 'ok' and (p_old.reply is not null or p_old.claimed_at is not null or p_old.status in ('approved','pending_approval')) then
    update public.acc_lines set status = p_old.status, luong = p_old.luong, phan_hoi = p_old.phan_hoi, issues = p_old.issues, due_at = p_old.due_at,
      gia_nhap = case when p_old.reply = 'da_gui_gia' then p_old.gia_nhap else gia_nhap end, gia_nhap_goc = p_old.gia_nhap_goc,
      gia_ap_dung = p_old.gia_ap_dung, gia_de_xuat = p_old.gia_de_xuat, bien_nt = p_old.bien_nt, tt_apt = p_old.tt_apt, tt_khach = p_old.tt_khach
    where id = p_id;
  end if;
  perform app.acc_apply_manual(p_old, p_id);  -- bản 60
end $$;
