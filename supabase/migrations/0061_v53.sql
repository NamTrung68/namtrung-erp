-- Bản 53 — Khách có nhiều pháp nhân: sửa các chỗ ghép sai pháp nhân
--  · out_invoice_save:
--      - khách của phiếu lấy theo dòng hàng khi phiếu chưa chọn khách (trước đây để trống → pháp nhân mới không có khách / username, VD XHD00118)
--      - ghép pháp nhân theo khách + MST chuẩn hóa (tên khác hoa thường / dấu câu không tạo pháp nhân trùng); pháp nhân tự thêm có username + ★ nếu khách chưa có
--      - phiếu không còn ghi đè địa chỉ / email của pháp nhân (đè cả khi đang khóa cập nhật), chỉ bổ sung ô trống
--  · out_ship_prep (chuyển phát): HĐ chưa gắn pháp nhân không còn mượn người nhận / địa chỉ của pháp nhân ★ khác MST
--  · Dọn dữ liệu: gắn pháp nhân mồ côi (không khách, không username) vào khách theo phiếu đã dùng nó; gắn buyer_id cho phiếu thiếu theo khách + MST

create or replace function public.out_invoice_save(p_id uuid, p_data jsonb, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; v_id uuid := p_id; x jsonb; t public.out_items; k int := 0; v_buyer uuid; v_sale uuid; v_cust uuid; v_acc boolean := app.is_acc(); v_status text;
        v_submit boolean := coalesce((p_data->>'submit')::boolean, false); v_b numeric; v_min numeric; v_max numeric;
        c_cam numeric := coalesce((app.setting('accounting')->>'xuat_bien_cam')::numeric, 0.02);
        c_duyet numeric := coalesce((app.setting('accounting')->>'xuat_bien_duyet')::numeric, 0.04);
        v_exported boolean := false; v_ver int := 1; v_cust0 uuid; v_mst0 text;
begin
  if p_id is not null then
    select * into v from public.out_invoices where id = p_id for update;
    if v.id is null then raise exception 'Không tìm thấy yêu cầu'; end if;
    if not (v_acc or app.in_tree(v.sale_id)) then raise exception 'Yêu cầu không thuộc bạn'; end if;
    if v.status in ('da_ky','huy') then raise exception 'Yêu cầu đã ký/đã hủy, không sửa được'; end if;
    if v.status = 'xac_nhan_ky' and not v_acc then raise exception 'Đã chốt — báo kế toán nếu cần sửa'; end if;
    v_exported := v.misa_at is not null or v.status in ('da_nhap','tra_sua','xac_nhan_ky');
    v_ver := v.version + case when v_exported then 1 else 0 end;
  end if;
  if jsonb_array_length(coalesce(p_lines, '[]')) = 0 then raise exception 'Chọn ít nhất 1 dòng hàng'; end if;
  if coalesce(btrim(p_data->>'buyer_name'), '') = '' then raise exception 'Nhập tên đơn vị mua hàng'; end if;
  -- Bản 53: khách của phiếu = khách chọn trên phiếu, không có thì lấy theo dòng hàng (trước đây bỏ trống → tạo pháp nhân "mồ côi")
  v_cust0 := coalesce(nullif(p_data->>'customer_id','')::uuid,
    (select oi.customer_id from public.out_items oi where oi.id in (select (y->>'item_id')::uuid from jsonb_array_elements(p_lines) y) and oi.customer_id is not null limit 1));
  v_mst0 := app.mst_norm(p_data->>'tax_code');
  if coalesce((p_data->>'save_buyer')::boolean, true) then
    -- Bản 53: ghép pháp nhân theo khách + MST (tên viết khác hoa thường / dấu câu vẫn là 1 pháp nhân); không MST thì theo tên chuẩn hóa
    select id into v_buyer from public.out_buyers b
     where b.customer_id is not distinct from v_cust0
       and (case when v_mst0 is not null then app.mst_norm(b.tax_code) = v_mst0
                 else coalesce(btrim(b.tax_code), '') = '' and app.ten_norm(b.name) = app.ten_norm(p_data->>'buyer_name') end)
     order by (app.ten_norm(b.name) = app.ten_norm(p_data->>'buyer_name')) desc, b.is_default desc, b.created_at limit 1;
    if v_buyer is null then
      begin
        insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note, is_default, created_by)
        values (v_cust0, (select nullif(btrim(c.sys_username), '') from public.customers c where c.id = v_cust0), btrim(p_data->>'buyer_name'), nullif(btrim(p_data->>'tax_code'), ''),
                nullif(btrim(p_data->>'address'), ''), nullif(btrim(p_data->>'email'), ''), 'Tự thêm từ phiếu xuất HĐ',
                v_cust0 is not null and not exists(select 1 from public.out_buyers b where b.customer_id = v_cust0 and b.is_default), auth.uid())
        returning id into v_buyer;
      exception when unique_violation then
        select id into v_buyer from public.out_buyers b where b.customer_id is not distinct from v_cust0 and lower(btrim(b.name)) = lower(btrim(p_data->>'buyer_name'))
           and coalesce(btrim(b.tax_code), '') = coalesce(btrim(p_data->>'tax_code'), '') limit 1;
      end;
    else
      -- Bản 53: phiếu KHÔNG ghi đè địa chỉ / email của pháp nhân (đè làm sai pháp nhân khi khóa cập nhật) — chỉ bổ sung ô đang trống
      update public.out_buyers set address = coalesce(nullif(btrim(address), ''), nullif(btrim(p_data->>'address'), '')),
                                   email = coalesce(nullif(btrim(email), ''), nullif(btrim(p_data->>'email'), ''))
       where id = v_buyer and (coalesce(btrim(address), '') = '' or coalesce(btrim(email), '') = '');
    end if;
  end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    select * into t from public.out_items where id = (x->>'item_id')::uuid;
    if t.id is null then raise exception 'Dòng hàng không tồn tại'; end if;
    if not v_acc and not app.in_tree(t.sale_id) then raise exception 'Dòng % không phải của bạn', t.ma_hang; end if;
    if t.lech and t.lech_ok_at is null then raise exception 'Dòng % đang lệch so với nháp (%) — chờ kế toán xử lý', t.ma_hang, t.lech_note; end if;
    -- 1 yêu cầu = 1 khách
    if v_cust is not null and t.customer_id is not null and t.customer_id <> v_cust then raise exception 'Không gộp hàng của 2 khách vào 1 HĐ (dòng %)', t.ma_hang; end if;
    v_cust := coalesce(v_cust, t.customer_id);
    v_sale := coalesce(v_sale, t.sale_id);
    if coalesce((x->>'sl')::numeric, 0) <= 0 then raise exception 'Số lượng dòng % phải > 0', t.ma_hang; end if;
    if (x->>'sl')::numeric > t.sl_nhap - app.out_used(t.id, p_id) + 0.0001 then raise exception 'Dòng % chỉ còn tồn %', t.ma_hang, t.sl_nhap - app.out_used(t.id, p_id); end if;
    if coalesce((x->>'don_gia')::numeric, -1) < 0 then raise exception 'Nhập đơn giá dòng %', t.ma_hang; end if;
    v_b := app.out_bien((x->>'don_gia')::numeric, t.dg_nhap);
    if v_b is not null then
      if v_b < c_cam - 0.000001 then raise exception 'Dòng %: giá % chỉ cao hơn giá APT % là % — dưới % không được xuất', t.ma_hang, (x->>'don_gia')::numeric, t.dg_nhap, round(v_b * 100, 2) || '%', round(c_cam * 100, 2) || '%'; end if;
      v_min := least(coalesce(v_min, v_b), v_b); v_max := greatest(coalesce(v_max, v_b), v_b);
    end if;
  end loop;
  v_status := case when p_id is null then case when v_submit then 'cho_nhap' else 'soan' end
                   when v.status in ('da_nhap','xac_nhan_ky','tra_sua','cho_duyet_gia') then 'cho_nhap'
                   when v_submit and v.status = 'soan' then 'cho_nhap' else v.status end;
  if v_status = 'cho_nhap' and coalesce(v_max, 0) > c_duyet + 0.000001 then v_status := 'cho_duyet_gia'; end if;
  if p_id is null then
    insert into public.out_invoices(sale_id, customer_id, buyer_id, buyer_name, tax_code, address, email, payment, note, status, status_by, bien_min, bien_max)
    values (coalesce(v_sale, auth.uid()), coalesce(v_cust0, v_cust), v_buyer, btrim(p_data->>'buyer_name'), nullif(btrim(p_data->>'tax_code'), ''), nullif(btrim(p_data->>'address'), ''),
            nullif(btrim(p_data->>'email'), ''), coalesce(nullif(p_data->>'payment', ''), 'TM/CK'), nullif(btrim(p_data->>'note'), ''), v_status, auth.uid(), v_min, v_max)
    returning id into v_id;
  else
    update public.out_invoices set customer_id = coalesce(v_cust0, v_cust), buyer_id = coalesce(v_buyer, buyer_id), buyer_name = btrim(p_data->>'buyer_name'),
      tax_code = nullif(btrim(p_data->>'tax_code'), ''), address = nullif(btrim(p_data->>'address'), ''), email = nullif(btrim(p_data->>'email'), ''),
      payment = coalesce(nullif(p_data->>'payment', ''), payment), note = nullif(btrim(p_data->>'note'), ''),
      sua_sau_nhap = sua_sau_nhap or v_exported, status = v_status, version = v_ver, bien_min = v_min, bien_max = v_max,
      price_ok_by = null, price_ok_at = null, misa_at = case when v_exported then null else misa_at end, misa_by = case when v_exported then null else misa_by end,
      status_at = case when v_status <> v.status then now() else status_at end, status_by = auth.uid(), updated_at = now() where id = v_id;
    delete from public.out_invoice_lines where invoice_id = v_id;
  end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    k := k + 1;
    insert into public.out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat)
    select v_id, oi.id, k, (x->>'sl')::numeric, (x->>'don_gia')::numeric, coalesce((x->>'vat')::numeric, oi.vat) from public.out_items oi where oi.id = (x->>'item_id')::uuid;
  end loop;
  update public.out_items oi set customer_id = nullif(p_data->>'customer_id','')::uuid
   where oi.customer_id is null and nullif(p_data->>'customer_id','') is not null and oi.id in (select item_id from public.out_invoice_lines where invoice_id = v_id);
  insert into public.out_events(invoice_id, action, note, data) values (v_id, case when p_id is null then 'create' else 'edit' end, nullif(btrim(p_data->>'note'), ''),
    jsonb_build_object('status', v_status, 'version', v_ver, 'bien_max', v_max));
  if v_status = 'cho_duyet_gia' and (p_id is null or v.status <> 'cho_duyet_gia') then
    perform app.notify_roles(array['ke_toan','tp_kd'], 'acc', 'Yêu cầu xuất HĐ chờ duyệt giá (biên ' || round(v_max * 100, 1) || '%)',
      (select code from public.out_invoices where id = v_id) || ' · ' || btrim(p_data->>'buyer_name'), '#/out?inv=' || v_id);
  elsif v_status = 'cho_nhap' and (p_id is null or v.status <> 'cho_nhap') then
    perform app.notify_roles(array['ke_toan'], 'acc', case when v_exported then 'Sale sửa yêu cầu sau khi đã export (v' || v_ver || ') — tạo lại nháp MISA' else 'Yêu cầu xuất HĐ mới' end,
      (select code from public.out_invoices where id = v_id) || ' · ' || btrim(p_data->>'buyer_name'), '#/out');
  end if;
  return v_id;
end $$;
grant execute on function public.out_invoice_save(uuid, jsonb, jsonb) to authenticated;

create or replace function public.out_ship_prep(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  return jsonb_build_object('cfg', app.cp_cfg(), 'rows', coalesce((select jsonb_agg(x order by x->>'kh_key', x->>'so_hd') from (
    select jsonb_build_object('id', i.id, 'code', i.code, 'so_hd', i.so_hd, 'ngay_hd', i.ngay_hd, 'sale_id', i.sale_id, 'customer_id', i.customer_id,
             'buyer_id', b.id, 'buyer_name', i.buyer_name, 'tax_code', i.tax_code,
             'kh_key', coalesce(i.customer_id::text, 'mst:' || btrim(coalesce(i.tax_code, ''))) || '|' || coalesce(i.sale_id::text, ''),
             'kh_name', coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name), 'username', cu.sys_username,
             'nguoi_nhan', coalesce(b.nguoi_nhan, nullif(btrim(cu.contact_name), ''), b.dai_dien),
             'sdt', coalesce(b.sdt_nhan, app.sdt_norm(cu.phone)),
             'dia_chi', coalesce(nullif(btrim(b.dia_chi_giao), ''), nullif(btrim(b.address), ''), nullif(btrim(i.address), ''), nullif(btrim(cu.address), '')),
             'tu_phap_nhan', b.nguoi_nhan is not null and b.sdt_nhan is not null,
             'ship_code', (select s.code from public.out_ship_items si join public.out_ships s on s.id = si.ship_id
                            where si.invoice_id = i.id and s.status not in ('huy', 'hoan') limit 1)) x
      from public.out_invoices i
      left join public.customers cu on cu.id = i.customer_id
      left join lateral (select b.* from public.out_buyers b
                          where b.id = i.buyer_id or (i.customer_id is not null and b.customer_id = i.customer_id and app.mst_norm(b.tax_code) = app.mst_norm(i.tax_code))
                          order by coalesce(b.id = i.buyer_id, false) desc, b.is_default desc limit 1) b on true
     where i.id = any(p_ids) and i.status = 'da_ky' and (app.is_acc() or app.in_tree(i.sale_id))) t), '[]'));
end $$;
grant execute on function public.out_ship_prep(uuid[]) to authenticated;

-- ---------- Dọn dữ liệu ----------
-- 1) pháp nhân không khách / không username đã dùng ở phiếu → gắn vào khách của phiếu (nếu khách đó chưa có pháp nhân cùng MST)
with o as (
  select distinct on (b.id) b.id, i.customer_id cid
    from public.out_buyers b join public.out_invoices i on i.buyer_id = b.id and i.customer_id is not null
   where b.customer_id is null and coalesce(btrim(b.username), '') = ''
   order by b.id, i.created_at desc)
update public.out_buyers b set customer_id = o.cid, username = (select nullif(btrim(c.sys_username), '') from public.customers c where c.id = o.cid),
       note = coalesce(nullif(btrim(b.note), ''), 'Tự thêm từ phiếu xuất HĐ'), updated_at = now()
  from o where b.id = o.id
   and not exists(select 1 from public.out_buyers x where x.customer_id = o.cid and app.mst_norm(x.tax_code) = app.mst_norm(b.tax_code));
-- khách chưa có ★ → pháp nhân vừa gắn thành ★
update public.out_buyers b set is_default = true
 where b.id in (select distinct on (customer_id) id from public.out_buyers where customer_id is not null order by customer_id, (nullif(btrim(ma_hdnt), '') is not null) desc, created_at)
   and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default);
-- 2) phiếu chưa gắn pháp nhân / gắn pháp nhân khác khách → gắn pháp nhân cùng khách + MST
update public.out_invoices i set buyer_id = (select b.id from public.out_buyers b where b.customer_id = i.customer_id and app.mst_norm(b.tax_code) = app.mst_norm(i.tax_code)
                                             order by (app.ten_norm(b.name) = app.ten_norm(i.buyer_name)) desc, b.is_default desc limit 1)
 where i.status <> 'huy' and i.customer_id is not null and app.mst_norm(i.tax_code) is not null
   and (i.buyer_id is null or not exists(select 1 from public.out_buyers b where b.id = i.buyer_id and b.customer_id = i.customer_id))
   and exists(select 1 from public.out_buyers b where b.customer_id = i.customer_id and app.mst_norm(b.tax_code) = app.mst_norm(i.tax_code));
