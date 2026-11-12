-- Bản 46 — Pháp nhân "đã xuất HĐ" + đối chiếu thông tin người mua của yêu cầu mới với HĐ đã ký trước
--  · app.pn_norm: chuẩn hóa để so (bỏ khoảng trắng thừa, không phân biệt hoa thường, bỏ dấu câu cuối) — KHÔNG bỏ dấu tiếng Việt (sai dấu = sai trên HĐ)
--  · out_buyers_page: thêm da_xuat (số HĐ đã ký đúng y tên + MST + địa chỉ) / xuat_cuoi, bộ lọc da_xuat · chua_xuat · lech_xuat
--  · out_pn_check(ids): mỗi yêu cầu → khop (đã ký HĐ trước, y hệt tên/MST/địa chỉ/email) · lech (cùng MST, khác trường nào) · moi (MST chưa từng xuất) · khong_mst

create or replace function app.pn_norm(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(lower(coalesce(t, '')), '\s+', ' ', 'g'), '[\s\.,;]+$', '')), '')
$$;
create or replace function app.mst_norm(t text) returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(t, ''), '\s', '', 'g'), '')
$$;
create index if not exists out_invoices_ky_mst on public.out_invoices(app.mst_norm(tax_code)) where status = 'da_ky';

/** Danh sách pháp nhân — như bản 40, thêm da_xuat / xuat_cuoi / lech_xuat */
create or replace function public.out_buyers_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_q text := nullif(btrim(p->>'q'), ''); v_flag text := nullif(p->>'flag', ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_lim int := least(coalesce((p->>'limit')::int, 200), 2000); r jsonb; n bigint; c jsonb;
        v_acc boolean := app.is_acc();
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  with b as materialized (
    select b.*, coalesce(b.username, cu.sys_username) uname, cu.code kh_code, cu.sys_code, coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name) kh_name, cu.owner_id sale_id,
           not app.mst_ok(b.tax_code) mst_sai,
           coalesce(btrim(b.address), '') = '' thieu_dc,
           exists(select 1 from public.out_buyers x where x.id <> b.id and btrim(x.tax_code) = btrim(b.tax_code) and lower(btrim(x.name)) <> lower(btrim(b.name))) trung_mst,
           b.customer_id is not null and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) khong_md,
           (select count(*) from public.out_invoices i where i.status <> 'huy' and (i.buyer_id = b.id or i.customer_id is not distinct from b.customer_id and btrim(i.tax_code) = btrim(b.tax_code))) so_phieu,
           k.n da_xuat, k.cuoi xuat_cuoi, k.n_mst ky_mst
      from public.out_buyers b left join public.customers cu on cu.id = b.customer_id
      left join lateral (select count(*) filter (where app.pn_norm(i.buyer_name) = app.pn_norm(b.name) and app.pn_norm(i.address) is not distinct from app.pn_norm(b.address)) n,
                                max(i.ngay_hd) filter (where app.pn_norm(i.buyer_name) = app.pn_norm(b.name) and app.pn_norm(i.address) is not distinct from app.pn_norm(b.address)) cuoi,
                                count(*) n_mst
                           from public.out_invoices i where i.status = 'da_ky' and app.mst_norm(i.tax_code) = app.mst_norm(b.tax_code)) k on true
     where v_acc or (cu.id is not null and cu.deleted_at is null and app.in_tree(cu.owner_id)))
  select jsonb_build_object('tat_ca', count(*), 'chua_gan', count(*) filter (where customer_id is null), 'mst_sai', count(*) filter (where mst_sai),
           'thieu_dc', count(*) filter (where thieu_dc), 'trung_mst', count(*) filter (where trung_mst), 'khong_md', count(*) filter (where khong_md),
           'co_hdnt', count(*) filter (where ma_hdnt is not null), 'thieu_dd', count(*) filter (where dai_dien is null),
           'thieu_nhan', count(*) filter (where coalesce(btrim(sdt_nhan), '') = '' or coalesce(btrim(coalesce(dia_chi_giao, address)), '') = ''),
           'da_xuat', count(*) filter (where da_xuat > 0), 'chua_xuat', count(*) filter (where ky_mst = 0), 'lech_xuat', count(*) filter (where da_xuat = 0 and ky_mst > 0),
           'khach', count(distinct coalesce(customer_id::text, 'u:' || lower(coalesce(uname, '')))))
    into c from (
    select b.*, coalesce(b.username, cu.sys_username) uname, cu.owner_id sale_id,
           not app.mst_ok(b.tax_code) mst_sai, coalesce(btrim(b.address), '') = '' thieu_dc,
           exists(select 1 from public.out_buyers x where x.id <> b.id and btrim(x.tax_code) = btrim(b.tax_code) and lower(btrim(x.name)) <> lower(btrim(b.name))) trung_mst,
           b.customer_id is not null and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) khong_md,
           k.n da_xuat, k.n_mst ky_mst
      from public.out_buyers b left join public.customers cu on cu.id = b.customer_id
      left join lateral (select count(*) filter (where app.pn_norm(i.buyer_name) = app.pn_norm(b.name) and app.pn_norm(i.address) is not distinct from app.pn_norm(b.address)) n, count(*) n_mst
                           from public.out_invoices i where i.status = 'da_ky' and app.mst_norm(i.tax_code) = app.mst_norm(b.tax_code)) k on true
     where v_acc or (cu.id is not null and cu.deleted_at is null and app.in_tree(cu.owner_id))) b;
  with b as materialized (
    select b.*, coalesce(b.username, cu.sys_username) uname, cu.code kh_code, cu.sys_code, coalesce(nullif(btrim(cu.company_name), ''), cu.contact_name) kh_name, cu.owner_id sale_id,
           not app.mst_ok(b.tax_code) mst_sai, coalesce(btrim(b.address), '') = '' thieu_dc,
           exists(select 1 from public.out_buyers x where x.id <> b.id and btrim(x.tax_code) = btrim(b.tax_code) and lower(btrim(x.name)) <> lower(btrim(b.name))) trung_mst,
           b.customer_id is not null and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default) khong_md,
           (select count(*) from public.out_invoices i where i.status <> 'huy' and (i.buyer_id = b.id or i.customer_id is not distinct from b.customer_id and btrim(i.tax_code) = btrim(b.tax_code))) so_phieu,
           k.n da_xuat, k.cuoi xuat_cuoi, k.n_mst ky_mst
      from public.out_buyers b left join public.customers cu on cu.id = b.customer_id
      left join lateral (select count(*) filter (where app.pn_norm(i.buyer_name) = app.pn_norm(b.name) and app.pn_norm(i.address) is not distinct from app.pn_norm(b.address)) n,
                                max(i.ngay_hd) filter (where app.pn_norm(i.buyer_name) = app.pn_norm(b.name) and app.pn_norm(i.address) is not distinct from app.pn_norm(b.address)) cuoi,
                                count(*) n_mst
                           from public.out_invoices i where i.status = 'da_ky' and app.mst_norm(i.tax_code) = app.mst_norm(b.tax_code)) k on true
     where v_acc or (cu.id is not null and cu.deleted_at is null and app.in_tree(cu.owner_id))),
  f as (select * from b
         where (v_q is null or concat_ws(' ', name, tax_code, uname, address, email, kh_name, kh_code, sys_code, note, ma_hdnt, dai_dien, nguoi_nhan, sdt_nhan, dia_chi_giao) ilike '%' || v_q || '%')
           and (v_sale is null or sale_id = v_sale)
           and (v_flag is null or v_flag = 'chua_gan' and customer_id is null or v_flag = 'mst_sai' and mst_sai or v_flag = 'thieu_dc' and thieu_dc
                or v_flag = 'trung_mst' and trung_mst or v_flag = 'khong_md' and khong_md or v_flag = 'co_hdnt' and ma_hdnt is not null or v_flag = 'thieu_dd' and dai_dien is null
                or v_flag = 'thieu_nhan' and (coalesce(btrim(sdt_nhan), '') = '' or coalesce(btrim(coalesce(dia_chi_giao, address)), '') = '')
                or v_flag = 'da_xuat' and da_xuat > 0 or v_flag = 'chua_xuat' and ky_mst = 0 or v_flag = 'lech_xuat' and da_xuat = 0 and ky_mst > 0)),
  o as (select f.*, row_number() over (order by lower(coalesce(uname, 'zzzz')), customer_id, is_default desc, created_at) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(jsonb_build_object('id', id, 'customer_id', customer_id, 'username', uname, 'own_username', username, 'name', name, 'tax_code', tax_code, 'address', address,
           'email', email, 'note', note, 'is_default', is_default, 'kh_name', kh_name, 'kh_code', coalesce(sys_code, kh_code), 'sale_id', sale_id, 'mst_sai', mst_sai, 'thieu_dc', thieu_dc,
           'trung_mst', trung_mst, 'khong_md', khong_md, 'so_phieu', so_phieu, 'created_at', created_at, 'updated_at', updated_at, 'updated_by', updated_by,
           'dai_dien', dai_dien, 'chuc_vu', chuc_vu, 'dia_chi_giao', dia_chi_giao, 'ma_hdnt', ma_hdnt, 'ngay_hdnt', ngay_hdnt, 'nguoi_nhan', nguoi_nhan, 'sdt_nhan', sdt_nhan,
           'da_xuat', da_xuat, 'xuat_cuoi', xuat_cuoi, 'ky_mst', ky_mst) order by rn)
           filter (where rn > v_off and rn <= v_off + v_lim), '[]')
    into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'acc', v_acc);
end $$;
grant execute on function public.out_buyers_page(jsonb) to authenticated;

/** Đối chiếu người mua của yêu cầu với HĐ ĐÃ KÝ trước đó cùng MST.
 *  Trả {invoice_id: {st, n, diff[], last{code, so_hd, ngay_hd, buyer_name, address, email}}}
 *  st: khop = có HĐ đã ký trước y hệt tên + địa chỉ + email · lech = cùng MST nhưng khác (diff = trường khác so với HĐ ký gần nhất) · moi = MST chưa từng xuất · khong_mst */
create or replace function public.out_pn_check(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare r jsonb := '{}'; v record; m record; k record; n int; d text[];
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  for v in select i.* from public.out_invoices i where i.id = any(p_ids) and (app.is_acc() or app.in_tree(i.sale_id)) loop
    if app.mst_norm(v.tax_code) is null then r := r || jsonb_build_object(v.id::text, jsonb_build_object('st', 'khong_mst')); continue; end if;
    select count(*) into n from public.out_invoices i where i.status = 'da_ky' and i.id <> v.id and app.mst_norm(i.tax_code) = app.mst_norm(v.tax_code);
    if n = 0 then r := r || jsonb_build_object(v.id::text, jsonb_build_object('st', 'moi')); continue; end if;
    -- HĐ đã ký trùng khớp hoàn toàn (ưu tiên gần nhất)
    select i.code, i.so_hd, i.ngay_hd, i.buyer_name, i.address, i.email into m from public.out_invoices i
     where i.status = 'da_ky' and i.id <> v.id and app.mst_norm(i.tax_code) = app.mst_norm(v.tax_code)
       and app.pn_norm(i.buyer_name) is not distinct from app.pn_norm(v.buyer_name) and app.pn_norm(i.address) is not distinct from app.pn_norm(v.address)
       and app.pn_norm(i.email) is not distinct from app.pn_norm(v.email)
     order by i.ngay_hd desc nulls last, i.status_at desc limit 1;
    if found then
      r := r || jsonb_build_object(v.id::text, jsonb_build_object('st', 'khop', 'n', n, 'diff', '[]'::jsonb, 'last', to_jsonb(m))); continue;
    end if;
    select i.code, i.so_hd, i.ngay_hd, i.buyer_name, i.address, i.email into k from public.out_invoices i
     where i.status = 'da_ky' and i.id <> v.id and app.mst_norm(i.tax_code) = app.mst_norm(v.tax_code)
     order by (app.pn_norm(i.buyer_name) is not distinct from app.pn_norm(v.buyer_name))::int + (app.pn_norm(i.address) is not distinct from app.pn_norm(v.address))::int desc,
              i.ngay_hd desc nulls last, i.status_at desc limit 1;
    d := array_remove(array[
      case when app.pn_norm(k.buyer_name) is distinct from app.pn_norm(v.buyer_name) then 'ten' end,
      case when app.pn_norm(k.address) is distinct from app.pn_norm(v.address) then 'dia_chi' end,
      case when app.pn_norm(k.email) is distinct from app.pn_norm(v.email) then 'email' end], null);
    r := r || jsonb_build_object(v.id::text, jsonb_build_object('st', 'lech', 'n', n, 'diff', to_jsonb(d), 'last', to_jsonb(k)));
  end loop;
  return r;
end $$;
grant execute on function public.out_pn_check(uuid[]) to authenticated;
