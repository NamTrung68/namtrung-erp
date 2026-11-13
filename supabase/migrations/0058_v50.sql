-- Bản 50 — Pháp nhân: thêm lọc / đếm "Chưa có HĐ nguyên tắc" (chua_hdnt)

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
           k.n da_xuat, k.khop khop_ky, k.cuoi xuat_cuoi
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
           'hdnt', hdnt, 'da_xuat', da_xuat, 'khop_ky', khop_ky, 'xuat_cuoi', xuat_cuoi) order by rn)
           filter (where rn > v_off and rn <= v_off + v_lim), '[]')
    into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'acc', v_acc);
end $$;
grant execute on function public.out_buyers_page(jsonb) to authenticated;
