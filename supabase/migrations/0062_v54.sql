-- Bản 54 — Chứng từ HĐ + khách nhiều pháp nhân
--  · app.pn_ten_sach / app.pn_dc_sach: bỏ nhãn dán nhầm vào tên ("… Đại diện: Ông …") / địa chỉ ("Địa chỉ: …", "ĐIA CHI : …")
--  · app.ten_norm / app.dc_norm so sánh sau khi bỏ nhãn → hết báo "Tên / địa chỉ khác HĐ đã ký" oan
--  · out_invoice_save: làm sạch tên / địa chỉ trước khi lưu phiếu
--  · out_docs_data: trả thêm tên / địa chỉ / MST của pháp nhân; ưu tiên pháp nhân cùng MST với HĐ → ĐĐH / BBGN / HĐNT in đúng tên pháp nhân và đúng HĐNT của pháp nhân đó
--  · out_buyers_page: lech_mau = HĐ đã ký lệch gần nhất (số, tên, địa chỉ) để kế toán thấy lệch chỗ nào
--  · Dọn dữ liệu: bỏ nhãn trong tên / địa chỉ các phiếu CHƯA ký (phiếu đã ký giữ nguyên để đối chiếu MISA)

create or replace function app.pn_ten_sach(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(coalesce(t, ''),
    '\s*[-–,;.]?\s*(đại diện|đai diện|đại diên|đai diên|dai dien|người đại diện|đ/d)\s*:.*$', '', 'i'),
    '^\s*(tên (công ty|đơn vị|khách hàng)[^:]*|tên)\s*:\s*', '', 'i')), '')
$$;
create or replace function app.pn_dc_sach(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(coalesce(t, ''), '^\s*(địa chỉ|đia chỉ|địa chi|đia chi|dia chi|đ/c|đc)\s*:\s*', '', 'i')), '')
$$;
create or replace function app.ten_norm(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(lower(coalesce(app.pn_ten_sach(t), '')), '[,.;:]+', ' ', 'g'), '\s+', ' ', 'g')), '')
$$;
create or replace function app.dc_norm(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
      ' ' || regexp_replace(lower(coalesce(app.pn_dc_sach(t), '')), '[,.;:–-]+', ' ', 'g') || ' ',
      '\s+', ' ', 'g'),
      ' việt nam\s*$', ' '),
      ' tp ', ' thành phố ', 'g'),
      ' tdp ', ' tổ dân phố ', 'g'),
      ' số nhà ', ' số ', 'g'),
      ' (thành phố|tỉnh) ', ' ', 'g'),
    '\s+', ' ', 'g')), '')
$$;

create or replace function public.out_invoice_save(p_id uuid, p_data jsonb, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; v_id uuid := p_id; x jsonb; t public.out_items; k int := 0; v_buyer uuid; v_sale uuid; v_cust uuid; v_acc boolean := app.is_acc(); v_status text;
        v_submit boolean := coalesce((p_data->>'submit')::boolean, false); v_b numeric; v_min numeric; v_max numeric;
        c_cam numeric := coalesce((app.setting('accounting')->>'xuat_bien_cam')::numeric, 0.02);
        c_duyet numeric := coalesce((app.setting('accounting')->>'xuat_bien_duyet')::numeric, 0.04);
        v_exported boolean := false; v_ver int := 1; v_cust0 uuid; v_mst0 text;
begin
  -- Bản 54: làm sạch tên / địa chỉ dán kèm nhãn ("… Đại diện: Ông …", "Địa chỉ: …") trước khi lưu phiếu
  p_data := p_data || jsonb_build_object('buyer_name', app.pn_ten_sach(p_data->>'buyer_name'), 'address', app.pn_dc_sach(p_data->>'address'));
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

create or replace function public.out_docs_data(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return (select coalesce(jsonb_agg(x order by x->>'so_hd', x->>'code'), '[]') from (
    select jsonb_build_object(
      'id', i.id, 'code', i.code, 'status', i.status, 'so_hd', i.so_hd, 'sale_id', i.sale_id, 'customer_id', i.customer_id,
      'ngay_hd', coalesce(i.ngay_hd, (i.status_at at time zone 'Asia/Ho_Chi_Minh')::date),
      'buyer_name', i.buyer_name, 'tax_code', i.tax_code, 'address', i.address, 'payment', i.payment,
      'buyer', (select jsonb_build_object('id', b.id, 'name', b.name, 'tax_code', b.tax_code, 'address', b.address, 'dai_dien', b.dai_dien, 'chuc_vu', b.chuc_vu, 'dia_chi_giao', b.dia_chi_giao,
                         'ma_hdnt', b.ma_hdnt, 'ngay_hdnt', app.hdnt_ngay(b.ma_hdnt, b.ngay_hdnt))
                  from public.out_buyers b
                 where b.id = i.buyer_id or (app.mst_norm(i.tax_code) is not null and app.mst_norm(b.tax_code) = app.mst_norm(i.tax_code))
                 order by (app.mst_norm(b.tax_code) is not distinct from app.mst_norm(i.tax_code)) desc, coalesce(b.id = i.buyer_id, false) desc,
                          (b.customer_id is not distinct from i.customer_id) desc, (b.ma_hdnt is not null) desc, (b.dai_dien is not null) desc, b.updated_at desc nulls last limit 1),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('ten', it.ten, 'dvt', it.dvt, 'sl', l.sl, 'don_gia', l.don_gia, 'vat', coalesce(l.vat, it.vat), 'ma_hang', it.ma_hang) order by l.stt, l.id), '[]')
                  from public.out_invoice_lines l join public.out_items it on it.id = l.item_id where l.invoice_id = i.id)) x
      from public.out_invoices i
     where i.id = any(p_ids) and i.status <> 'huy' and (app.is_acc() or app.in_tree(i.sale_id))) s);
end $$;
grant execute on function public.out_docs_data(uuid[]) to authenticated;

create or replace function public.out_buyers_page(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare v_q text := nullif(btrim(p->>'q'), ''); v_flag text := nullif(p->>'flag', ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 200), 2000); r jsonb; n bigint; c jsonb;
        v_acc boolean := app.is_acc();
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  drop table if exists pn_b;
  create temp table pn_b on commit drop as
    select b.*, coalesce(b.username, cu.sys_username) uname, cu.code kh_code, cu.sys_code, coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name) kh_name, cu.owner_id sale_id,
           not app.mst_ok(b.tax_code) mst_sai, coalesce(btrim(b.address), '') = '' thieu_dc,
           exists(select 1 from public.out_buyers x where x.id <> b.id and app.mst_norm(x.tax_code) = app.mst_norm(b.tax_code) and app.ten_norm(x.name) <> app.ten_norm(b.name)) trung_mst,
           b.customer_id is not null and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) khong_md,
           (select count(*) from public.out_invoices i where i.status <> 'huy' and (i.buyer_id = b.id or i.customer_id is not distinct from b.customer_id and btrim(i.tax_code) = btrim(b.tax_code))) so_phieu,
           nullif(btrim(b.ma_hdnt), '') is not null hdnt,
           k.n da_xuat, k.khop khop_ky, k.cuoi xuat_cuoi,
           (select jsonb_build_object('so', coalesce(i.so_hd, i.code), 'ngay', i.ngay_hd, 'ten', i.buyer_name, 'dia_chi', i.address,
                     'ten_khac', app.ten_norm(i.buyer_name) is distinct from app.ten_norm(b.name), 'dc_khac', app.dc_norm(i.address) is distinct from app.dc_norm(b.address))
              from public.out_invoices i where i.status = 'da_ky' and app.mst_norm(i.tax_code) = app.mst_norm(b.tax_code)
               and not (app.ten_norm(i.buyer_name) is not distinct from app.ten_norm(b.name) and app.dc_norm(i.address) is not distinct from app.dc_norm(b.address))
             order by i.ngay_hd desc nulls last limit 1) lech_mau
      from public.out_buyers b left join public.customers cu on cu.id = b.customer_id
      left join lateral (select count(*) n, max(i.ngay_hd) cuoi,
                                count(*) filter (where app.ten_norm(i.buyer_name) is not distinct from app.ten_norm(b.name) and app.dc_norm(i.address) is not distinct from app.dc_norm(b.address)) khop
                           from public.out_invoices i where i.status = 'da_ky' and app.mst_norm(i.tax_code) = app.mst_norm(b.tax_code)) k on true
     where v_acc or (cu.id is not null and cu.deleted_at is null and app.in_tree(cu.owner_id));
  select jsonb_build_object('tat_ca', count(*), 'hdnt', count(*) filter (where hdnt), 'co_hdnt', count(*) filter (where hdnt), 'chua_hdnt', count(*) filter (where not hdnt), 'da_xuat', count(*) filter (where da_xuat > 0), 'chua_xuat', count(*) filter (where da_xuat = 0),
           'lech_ky', count(*) filter (where da_xuat > 0 and khop_ky = 0), 'chua_gan', count(*) filter (where customer_id is null), 'mst_sai', count(*) filter (where mst_sai),
           'thieu_dc', count(*) filter (where thieu_dc), 'trung_mst', count(*) filter (where trung_mst), 'khong_md', count(*) filter (where khong_md),
           'thieu_dd', count(*) filter (where dai_dien is null),
           'thieu_nhan', count(*) filter (where coalesce(btrim(sdt_nhan), '') = '' or coalesce(btrim(coalesce(dia_chi_giao, address)), '') = ''),
           'khach', count(distinct coalesce(customer_id::text, 'u:' || lower(coalesce(uname, '')))))
    into c from pn_b;
  with f as (select * from pn_b
         where (v_q is null or concat_ws(' ', name, tax_code, uname, address, email, kh_name, kh_code, sys_code, note, ma_hdnt, dai_dien, nguoi_nhan, sdt_nhan, dia_chi_giao) ilike '%' || v_q || '%')
           and (v_sale is null or sale_id = v_sale)
           and (v_flag is null or v_flag in ('hdnt', 'co_hdnt') and hdnt or v_flag = 'chua_hdnt' and not hdnt or v_flag = 'da_xuat' and da_xuat > 0 or v_flag = 'chua_xuat' and da_xuat = 0
                or v_flag = 'lech_ky' and da_xuat > 0 and khop_ky = 0 or v_flag = 'chua_gan' and customer_id is null or v_flag = 'mst_sai' and mst_sai
                or v_flag = 'thieu_dc' and thieu_dc or v_flag = 'trung_mst' and trung_mst or v_flag = 'khong_md' and khong_md or v_flag = 'thieu_dd' and dai_dien is null
                or v_flag = 'thieu_nhan' and (coalesce(btrim(sdt_nhan), '') = '' or coalesce(btrim(coalesce(dia_chi_giao, address)), '') = ''))),
  o as (select f.*, row_number() over (order by lower(coalesce(uname, 'zzzz')), customer_id, is_default desc, created_at) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(jsonb_build_object('id', id, 'customer_id', customer_id, 'username', uname, 'own_username', username, 'name', name, 'tax_code', tax_code, 'address', address,
           'email', email, 'note', note, 'is_default', is_default, 'kh_name', kh_name, 'kh_code', coalesce(sys_code, kh_code), 'sale_id', sale_id, 'mst_sai', mst_sai, 'thieu_dc', thieu_dc,
           'trung_mst', trung_mst, 'khong_md', khong_md, 'so_phieu', so_phieu, 'created_at', created_at, 'updated_at', updated_at, 'updated_by', updated_by,
           'dai_dien', dai_dien, 'chuc_vu', chuc_vu, 'dia_chi_giao', dia_chi_giao, 'ma_hdnt', ma_hdnt, 'ngay_hdnt', ngay_hdnt, 'nguoi_nhan', nguoi_nhan, 'sdt_nhan', sdt_nhan,
           'hdnt', hdnt, 'da_xuat', da_xuat, 'khop_ky', khop_ky, 'xuat_cuoi', xuat_cuoi, 'lech_mau', lech_mau) order by rn)
           filter (where rn > v_off and rn <= v_off + v_lim), '[]')
    into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'acc', v_acc);
end $$;
grant execute on function public.out_buyers_page(jsonb) to authenticated;

-- ---------- Dọn dữ liệu: phiếu CHƯA ký có nhãn dán nhầm ----------
update public.out_invoices set buyer_name = coalesce(app.pn_ten_sach(buyer_name), buyer_name), address = app.pn_dc_sach(address), updated_at = now()
 where status not in ('da_ky', 'huy') and (buyer_name is distinct from coalesce(app.pn_ten_sach(buyer_name), buyer_name) or address is distinct from app.pn_dc_sach(address));
update public.out_buyers b set name = coalesce(app.pn_ten_sach(b.name), b.name), address = app.pn_dc_sach(b.address), updated_at = now()
 where (b.name is distinct from coalesce(app.pn_ten_sach(b.name), b.name) or b.address is distinct from app.pn_dc_sach(b.address))
   and not exists(select 1 from public.out_buyers x where x.id <> b.id
                   and coalesce(x.customer_id::text, 'u:' || lower(btrim(coalesce(x.username, '')))) = coalesce(b.customer_id::text, 'u:' || lower(btrim(coalesce(b.username, ''))))
                   and lower(btrim(x.name)) = lower(btrim(coalesce(app.pn_ten_sach(b.name), b.name))) and coalesce(btrim(x.tax_code), '') = coalesce(btrim(b.tax_code), ''));

-- Lập nhanh hàng loạt: kèm mã HĐ nguyên tắc để sale chọn đúng pháp nhân
create or replace function public.out_buyers_for(p_customers uuid[], p_usernames text[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'customer_id', b.customer_id, 'username', b.username, 'name', b.name, 'tax_code', b.tax_code, 'address', b.address,
            'email', b.email, 'is_default', b.is_default, 'ma_hdnt', b.ma_hdnt) order by b.is_default desc, b.created_at desc), '[]')
    from public.out_buyers b
   where (b.customer_id = any(coalesce(p_customers, '{}')) and (app.is_acc() or exists(select 1 from public.customers c where c.id = b.customer_id and app.in_tree(c.owner_id))))
      or (b.customer_id is null and b.username is not null and lower(b.username) = any(select lower(app.norm_username(x)) from unnest(coalesce(p_usernames, '{}')) x)));
end $$;
grant execute on function public.out_buyers_for(uuid[], text[]) to authenticated;
