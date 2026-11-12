-- Bản 47 — Pháp nhân "chứng thực" + đối chiếu yêu cầu HĐ đáng tin hơn
--  · Nguồn chứng thực của 1 MST: HĐ ĐÃ KÝ (khách đã nhận, không phản hồi) hoặc pháp nhân ĐÃ KÝ HĐ NGUYÊN TẮC
--  · app.dc_norm: so địa chỉ bỏ qua cách viết (TP = Thành phố, TDP = Tổ dân phố, "Số nhà" = "Số", tiền tố Tỉnh / Thành phố, đuôi "Việt Nam", dấu câu)
--  · out_pn_check: khop / lech / moi / mst_sai / khong_mst, kèm nguồn đối chiếu và bản so từng trường
--  · out_buyers_page: cờ hdnt / da_xuat / chua_xuat / lech_ky (+ các cờ "cần sửa" cũ)
--  · Dọn dữ liệu 1 lần: thêm pháp nhân từ HĐ đã ký còn thiếu; xóa pháp nhân không username hoặc chưa ký HĐNT mà MST chưa từng xuất HĐ (sao lưu app.out_buyers_bak_v47)

create or replace function app.dc_norm(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(
    regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
      ' ' || regexp_replace(lower(coalesce(t, '')), '[,.;:–-]+', ' ', 'g') || ' ',
      '\s+', ' ', 'g'),
      ' việt nam\s*$', ' '),
      ' tp ', ' thành phố ', 'g'),
      ' tdp ', ' tổ dân phố ', 'g'),
      ' số nhà ', ' số ', 'g'),
      ' (thành phố|tỉnh) ', ' ', 'g'),
    '\s+', ' ', 'g')), '')
$$;
-- tên: bỏ dấu câu + khoảng trắng thừa, không phân biệt hoa thường (KHÔNG bỏ dấu tiếng Việt)
create or replace function app.ten_norm(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(lower(coalesce(t, '')), '[,.;:]+', ' ', 'g'), '\s+', ' ', 'g')), '')
$$;

/** Đối chiếu người mua của yêu cầu với nguồn chứng thực cùng MST (HĐ đã ký khác + pháp nhân đã ký HĐNT).
 *  {invoice_id: {st, n, diff[], src{loai: hd|hdnt, so, ngay, ten, dia_chi, email}, email_khac}}
 *  st: khop (tên + địa chỉ trùng 1 nguồn) · lech (có nguồn cùng MST nhưng khác) · moi (MST chưa có nguồn nào) · mst_sai · khong_mst */
create or replace function public.out_pn_check(p_ids uuid[]) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare r jsonb := '{}'; v record; s record; n int; d text[];
begin
  if auth.uid() is null then raise exception 'Chưa đăng nhập'; end if;
  for v in select i.* from public.out_invoices i where i.id = any(p_ids) and (app.is_acc() or app.in_tree(i.sale_id)) loop
    if app.mst_norm(v.tax_code) is null then r := r || jsonb_build_object(v.id::text, jsonb_build_object('st', 'khong_mst')); continue; end if;
    if not app.mst_ok(app.mst_norm(v.tax_code)) then r := r || jsonb_build_object(v.id::text, jsonb_build_object('st', 'mst_sai')); continue; end if;
    create temp table if not exists pn_src(loai text, so text, ngay date, ten text, dia_chi text, email text, khop_ten boolean, khop_dc boolean) on commit drop;
    truncate pn_src;
    insert into pn_src
      select 'hd', coalesce(i.so_hd, i.code), i.ngay_hd, i.buyer_name, i.address, i.email,
             app.ten_norm(i.buyer_name) is not distinct from app.ten_norm(v.buyer_name), app.dc_norm(i.address) is not distinct from app.dc_norm(v.address)
        from public.out_invoices i where i.status = 'da_ky' and i.id <> v.id and app.mst_norm(i.tax_code) = app.mst_norm(v.tax_code)
      union all
      select 'hdnt', b.ma_hdnt, b.ngay_hdnt, b.name, b.address, b.email,
             app.ten_norm(b.name) is not distinct from app.ten_norm(v.buyer_name), app.dc_norm(b.address) is not distinct from app.dc_norm(v.address)
        from public.out_buyers b where nullif(btrim(b.ma_hdnt), '') is not null and app.mst_norm(b.tax_code) = app.mst_norm(v.tax_code);
    select count(*) into n from pn_src;
    if n = 0 then r := r || jsonb_build_object(v.id::text, jsonb_build_object('st', 'moi')); continue; end if;
    select * into s from pn_src order by (khop_ten and khop_dc) desc, khop_ten::int + khop_dc::int desc, (loai = 'hdnt') desc, ngay desc nulls last limit 1;
    d := array_remove(array[case when not s.khop_ten then 'ten' end, case when not s.khop_dc then 'dia_chi' end], null);
    r := r || jsonb_build_object(v.id::text, jsonb_build_object('st', case when cardinality(d) = 0 then 'khop' else 'lech' end, 'n', n, 'diff', to_jsonb(d),
      'src', jsonb_build_object('loai', s.loai, 'so', s.so, 'ngay', s.ngay, 'ten', s.ten, 'dia_chi', s.dia_chi, 'email', s.email),
      'email_khac', coalesce(nullif(btrim(v.email), ''), '') <> '' and coalesce(nullif(btrim(s.email), ''), '') <> '' and lower(btrim(v.email)) <> lower(btrim(s.email))));
  end loop;
  return r;
end $$;
grant execute on function public.out_pn_check(uuid[]) to authenticated;

/** Danh sách pháp nhân — cờ chứng thực: hdnt (đã ký HĐ nguyên tắc) · da_xuat (MST đã có HĐ đã ký) · chua_xuat · lech_ky (đã xuất nhưng tên / địa chỉ khác HĐ đã ký) */
drop function if exists public.out_buyers_page(jsonb);
create function public.out_buyers_page(p jsonb) returns jsonb
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
  select jsonb_build_object('tat_ca', count(*), 'hdnt', count(*) filter (where hdnt), 'co_hdnt', count(*) filter (where hdnt), 'da_xuat', count(*) filter (where da_xuat > 0), 'chua_xuat', count(*) filter (where da_xuat = 0),
           'lech_ky', count(*) filter (where da_xuat > 0 and khop_ky = 0), 'chua_gan', count(*) filter (where customer_id is null), 'mst_sai', count(*) filter (where mst_sai),
           'thieu_dc', count(*) filter (where thieu_dc), 'trung_mst', count(*) filter (where trung_mst), 'khong_md', count(*) filter (where khong_md),
           'thieu_dd', count(*) filter (where dai_dien is null),
           'thieu_nhan', count(*) filter (where coalesce(btrim(sdt_nhan), '') = '' or coalesce(btrim(coalesce(dia_chi_giao, address)), '') = ''),
           'khach', count(distinct coalesce(customer_id::text, 'u:' || lower(coalesce(uname, '')))))
    into c from pn_b;
  with f as (select * from pn_b
         where (v_q is null or concat_ws(' ', name, tax_code, uname, address, email, kh_name, kh_code, sys_code, note, ma_hdnt, dai_dien, nguoi_nhan, sdt_nhan, dia_chi_giao) ilike '%' || v_q || '%')
           and (v_sale is null or sale_id = v_sale)
           and (v_flag is null or v_flag in ('hdnt', 'co_hdnt') and hdnt or v_flag = 'da_xuat' and da_xuat > 0 or v_flag = 'chua_xuat' and da_xuat = 0
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

-- ---------------- Dọn dữ liệu 1 lần (chạy lại không làm gì nữa) ----------------
do $$
declare n_add int; n_del int;
begin
  if to_regclass('app.out_buyers_bak_v47') is not null then raise notice 'Bản 47: đã dọn trước đó — bỏ qua'; return; end if;
  -- 1) thêm pháp nhân từ HĐ đã ký còn thiếu (cùng khách + tên + MST chưa có)
  insert into public.out_buyers(customer_id, name, tax_code, address, email, note, is_default)
  select distinct on (i.customer_id, lower(btrim(i.buyer_name)), coalesce(btrim(i.tax_code), ''))
         i.customer_id, btrim(i.buyer_name), btrim(i.tax_code), i.address, nullif(btrim(i.email), ''), 'Bản 47: thêm từ HĐ đã ký ' || coalesce(i.so_hd, i.code), false
    from public.out_invoices i
   where i.status = 'da_ky' and coalesce(btrim(i.buyer_name), '') <> '' and app.mst_norm(i.tax_code) is not null
     and not exists(select 1 from public.out_buyers b where b.customer_id is not distinct from i.customer_id and lower(btrim(b.name)) = lower(btrim(i.buyer_name))
                     and coalesce(btrim(b.tax_code), '') = coalesce(btrim(i.tax_code), ''))
   order by i.customer_id, lower(btrim(i.buyer_name)), coalesce(btrim(i.tax_code), ''), i.ngay_hd desc nulls last
  on conflict do nothing;
  get diagnostics n_add = row_count;
  -- 2) sao lưu rồi xóa: không (username + HĐNT) và MST chưa từng có HĐ đã ký
  create table app.out_buyers_bak_v47 as
    select b.* from public.out_buyers b left join public.customers cu on cu.id = b.customer_id
     where not (coalesce(nullif(btrim(b.username), ''), cu.sys_username) is not null and nullif(btrim(b.ma_hdnt), '') is not null)
       and not exists(select 1 from public.out_invoices i where i.status = 'da_ky' and app.mst_norm(i.tax_code) = app.mst_norm(b.tax_code));
  revoke all on app.out_buyers_bak_v47 from public;
  delete from public.out_buyers b where b.id in (select id from app.out_buyers_bak_v47);
  get diagnostics n_del = row_count;
  -- khách còn pháp nhân mà mất ★ mặc định → đặt lại
  update public.out_buyers b set is_default = true
   where b.id in (select distinct on (customer_id) id from public.out_buyers where customer_id is not null order by customer_id, (nullif(btrim(ma_hdnt), '') is not null) desc, created_at desc)
     and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default);
  raise notice 'Bản 47: thêm % pháp nhân từ HĐ đã ký, xóa % pháp nhân chưa chứng thực (sao lưu app.out_buyers_bak_v47)', n_add, n_del;
end $$;
