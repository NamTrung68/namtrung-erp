-- Bản 51 — Nạp HĐ tồn (bàn làm việc kế toán)
--  · File = cột HĐ chính thức APT + Mã đơn hàng, Username, Tên sale
--  · Giá xuất khách = đơn giá nhập × hệ số (mặc định 1,03 = +3%), làm tròn đồng; gia_src = 'ton' (không bị giá đơn / đối soát đè)
--  · Không có sale / không nhận ra sale → không nạp. Không có username → vẫn nạp, sale / kế toán điền sau (Sẵn sàng xuất → Điền đơn / khách)
--  · Mã hàng đã có trong ERP → bỏ qua (không đè dòng đang dùng)
--  · match_src = 'ton': không ghép vào nháp APT / file xe

create or replace function app.out_item_match(p_id uuid) returns void language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; al public.acc_lines; v_c uuid; v_owner uuid; v_src text; o public.out_orders; s_sale uuid; s_user text; n int; v_lech text;
begin
  select * into t from public.out_items where id = p_id;
  -- Bản 51: dòng HĐ tồn nạp tay (match_src = 'ton') — không ghép nháp / đối soát, chỉ gắn khách theo username (sale cập nhật sau)
  if t.match_src = 'ton' then
    if t.username is not null then
      select id, owner_id into v_c, v_owner from public.customers where deleted_at is null
        and (lower(btrim(sys_username)) = lower(btrim(t.username)) or upper(btrim(sys_code)) = upper(btrim(t.username))) limit 1;
    end if;
    update public.out_items set customer_id = coalesce(customer_id, v_c), sale_id = coalesce(sale_id, v_owner) where id = p_id;
    return;
  end if;
  if t.acc_line_id is not null then select * into al from public.acc_lines where id = t.acc_line_id; v_src := t.match_src; end if;
  if al.id is null and t.stt_hd is not null and t.so_hd_vao is not null then
    select l.* into al from public.acc_invoice_lines il join public.acc_invoices i on i.id = il.invoice_id join public.acc_lines l on l.id = il.line_id
     where ltrim(i.so_hd, '0') = ltrim(t.so_hd_vao, '0') and (t.ky_hieu is null or right(i.ky_hieu, 6) = right(t.ky_hieu, 6)) and il.stt = t.stt_hd limit 1;
    if al.id is not null then v_src := 'hd_xml'; end if;
  end if;
  -- Bản 23: tên HĐ ký = tên nháp (trừ sai số copy) + cùng SL → dòng nháp chưa thuộc dòng sổ nào khác
  if al.id is null then
    select count(*) into n from public.acc_lines l where not l.is_test and l.apt_stt is not null and app.hd_ten(l.ten_apt) = app.hd_ten(t.ten)
       and not exists(select 1 from public.out_items x where x.acc_line_id = l.id and x.id <> t.id);
    if n > 1 then
      select l.* into al from public.acc_lines l where not l.is_test and l.apt_stt is not null and app.hd_ten(l.ten_apt) = app.hd_ten(t.ten)
         and not exists(select 1 from public.out_items x where x.acc_line_id = l.id and x.id <> t.id)
       order by (abs(coalesce(l.sl_apt, -1) - t.sl_nhap) < 0.0001) desc, (abs(coalesce(l.gia_nhap, -1) - coalesce(t.dg_nhap, -2)) <= 0.5) desc, l.updated_at desc limit 1;
      if al.id is not null and abs(coalesce(al.sl_apt, -1) - t.sl_nhap) >= 0.0001 then al := null; end if;
    elsif n = 1 then
      select l.* into al from public.acc_lines l where not l.is_test and l.apt_stt is not null and app.hd_ten(l.ten_apt) = app.hd_ten(t.ten)
         and not exists(select 1 from public.out_items x where x.acc_line_id = l.id and x.id <> t.id);
    end if;
    if al.id is not null then v_src := 'ten'; end if;
  end if;
  if al.id is null and t.md is not null then
    select * into al from public.acc_lines where md = t.md and not is_test order by (sl_apt = t.sl_nhap) desc nulls last, updated_at desc limit 1;
    if al.id is not null then v_src := 'md'; end if;
  end if;
  if t.md is not null or al.md is not null then select * into o from public.out_orders where md = coalesce(t.md, al.md); end if;
  if coalesce(t.md, al.md) is not null and (t.sale_id is null or t.username is null) then
    select sale_id, username into s_sale, s_user from public.out_items where md = coalesce(t.md, al.md) and id <> t.id and (sale_id is not null or username is not null)
     order by (sale_id is not null) desc, (username is not null) desc limit 1;
  end if;
  t.username := coalesce(t.username, nullif(al.ma_kh, ''), o.username, s_user);
  if t.username is not null then
    select id, owner_id into v_c, v_owner from public.customers where deleted_at is null
      and (lower(btrim(sys_username)) = lower(btrim(t.username)) or upper(btrim(sys_code)) = upper(btrim(t.username))) limit 1;
  end if;
  -- đối chiếu chi tiết chỉ cho dòng ghép đúng dòng (XML / tên); ghép theo mã đơn là ước lượng, không khóa
  v_lech := case when v_src in ('ten','hd_xml') then app.out_item_check(t, al) end;
  update public.out_items set acc_line_id = coalesce(acc_line_id, al.id), ma_kb = coalesce(ma_kb, case when v_src in ('ten','hd_xml') then al.ma_dong end),
    md = coalesce(md, al.md), username = t.username, nvkd = coalesce(nvkd, o.nvkd),
    gia_khach = case when v_src in ('hd_xml','ten') and gia_src is distinct from 'sale' then coalesce(nullif(al.gia_khach, 0), al.claim_gia, gia_khach) else gia_khach end,
    gia_src = case when v_src in ('hd_xml','ten') and gia_src is distinct from 'sale' and coalesce(nullif(al.gia_khach, 0), al.claim_gia) is not null then 'doi_soat' else gia_src end,
    sale_id = coalesce(sale_id, al.sale_id, app.match_sale(t.nvkd), app.match_sale(o.nvkd), s_sale, v_owner),
    customer_id = coalesce(customer_id, al.customer_id, v_c),
    match_src = coalesce(match_src, v_src, case when t.nvkd is not null then 'nvkd' when o.md is not null then 'don_hang' when v_owner is not null then 'user' end),
    lech = case when lech_ok_at is not null then lech else v_lech is not null end,
    lech_note = case when lech_ok_at is not null then lech_note else v_lech end
  where id = p_id;
  perform app.out_item_price(p_id);
end $$;

create or replace function app.out_item_price(p_id uuid) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare t public.out_items; b record; n int;
begin
  select * into t from public.out_items where id = p_id;
  if t.id is null or t.md is null or t.gia_src = 'ton' then return; end if;  -- bản 51: giá HĐ tồn giữ nguyên
  select count(distinct gia) into n from public.out_prices where md = t.md;
  if t.gia_src = 'sale' and t.gia_khach is not null then
    update public.out_items set gia_n = n where id = t.id and gia_n is distinct from n; return;
  end if;
  select p.gia, p.src,
         (case when (p.src = 'doi_soat' and t.acc_line_id is not null and p.src_ref = t.acc_line_id::text and t.match_src = 'hd_xml')
                 or (p.src = 'so' and p.src_ref = t.ma_hang || '#' || t.part) or (p.src in ('phieu','sale') and p.src_ref = t.id::text) then 100 else 0 end
          + case when p.sl is not null and abs(p.sl - t.sl_nhap) < 0.001 then 30 else 0 end
          + coalesce(similarity(lower(p.ten), lower(t.ten)), 0) * 50
          + case p.src when 'sale' then 8 when 'phieu' then 7 when 'doi_soat' then 6 when 'so' then 5 else 4 end) sc
    into b from public.out_prices p where p.md = t.md order by 3 desc, p.at desc limit 1;
  if b.gia is null then update public.out_items set gia_n = 0 where id = t.id and gia_n is distinct from 0; return; end if;
  if n > 1 and b.sc < 20 then
    -- đơn có nhiều giá, không biết dòng này giá nào → để sale chọn
    update public.out_items set gia_n = n, gia_khach = case when gia_src in ('phieu') then gia_khach end, gia_src = case when gia_src in ('phieu') then gia_src end where id = t.id;
    return;
  end if;
  update public.out_items set gia_khach = b.gia, gia_src = b.src, gia_n = n
   where id = t.id and (gia_khach is distinct from b.gia or gia_src is distinct from b.src or gia_n is distinct from n);
end $$;

/** p_dry = true: chỉ kiểm, trả trạng thái từng dòng (mới / đã có / thiếu sale / sale lạ / lỗi) */
create or replace function public.out_items_import_ton(p_rows jsonb, p_dry boolean default true, p_he_so numeric default 1.03) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; i int := -1; out jsonb := '[]'; v_ma text; v_part int; v_sale uuid; v_c uuid; v_kh text; v_md text; v_user text; v_gia numeric; v_st text; v_ly text;
        n_moi int := 0; n_co int := 0; n_sale int := 0; n_loi int := 0; v_id uuid;
begin
  if not app.has_role('admin', 'ke_toan') then raise exception 'Chỉ Kế toán / Admin nạp HĐ tồn'; end if;
  if p_he_so is null or p_he_so < 1.02 or p_he_so > 1.04 then raise exception 'Hệ số giá xuất phải trong 1,02 – 1,04 (biên 2–4%%)'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; v_st := 'moi'; v_ly := null; v_sale := null; v_c := null; v_kh := null;
    v_ma := upper(nullif(btrim(r->>'ma_hang'), '')); v_part := coalesce((r->>'part')::int, 1);
    v_md := case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end;
    v_user := app.norm_username(nullif(btrim(r->>'username'), ''));
    v_gia := round(coalesce((r->>'dg_nhap')::numeric, 0) * p_he_so);
    if v_ma is null or coalesce(btrim(r->>'ten'), '') = '' then v_st := 'loi'; v_ly := 'Thiếu mã hàng / tên hàng';
    elsif coalesce((r->>'sl_nhap')::numeric, 0) <= 0 then v_st := 'loi'; v_ly := 'Số lượng nhập phải > 0';
    elsif coalesce((r->>'dg_nhap')::numeric, 0) <= 0 then v_st := 'loi'; v_ly := 'Thiếu đơn giá nhập';
    elsif nullif(btrim(r->>'nvkd'), '') is null then v_st := 'thieu_sale'; v_ly := 'Không có tên sale — không nạp';
    else
      v_sale := app.match_sale(r->>'nvkd');
      if v_sale is null then v_st := 'thieu_sale'; v_ly := 'Không nhận ra sale "' || btrim(r->>'nvkd') || '" — sửa đúng tên trên ERP';
      elsif exists(select 1 from public.out_items x where x.ma_hang = v_ma and x.part = v_part) then v_st := 'da_co'; v_ly := 'Mã hàng đã có trong ERP — bỏ qua';
      end if;
    end if;
    if v_user is not null then
      select c.id, coalesce(nullif(btrim(c.company_name), ''), c.contact_name) into v_c, v_kh from public.customers c where c.deleted_at is null
        and (lower(btrim(c.sys_username)) = lower(v_user) or upper(btrim(c.sys_code)) = upper(v_user)) limit 1;
    end if;
    if v_st = 'moi' and not p_dry then
      insert into public.out_items(ma_hang, part, stt_so, ten, dvt, vat, sl_nhap, dg_nhap, so_hd_vao, ky_hieu, ngay_vao, ncc, stt_hd, md, nvkd, username,
                                   sale_id, customer_id, gia_khach, gia_src, match_src, ma_auto, note, updated_at, updated_by)
      values (v_ma, v_part, (r->>'stt_so')::numeric, btrim(r->>'ten'), nullif(btrim(r->>'dvt'), ''), (r->>'vat')::numeric, (r->>'sl_nhap')::numeric, (r->>'dg_nhap')::numeric,
              nullif(btrim(r->>'so_hd_vao'), ''), nullif(btrim(r->>'ky_hieu'), ''), nullif(r->>'ngay_vao', '')::date, nullif(btrim(r->>'ncc'), ''), (r->>'stt_hd')::int,
              v_md, btrim(r->>'nvkd'), v_user, v_sale, v_c, v_gia, 'ton', 'ton', false, 'HĐ tồn nạp tay', now(), auth.uid())
      returning id into v_id;
      insert into public.out_events(item_id, action, data) values (v_id, 'import_ton', jsonb_build_object('he_so', p_he_so));
    end if;
    case v_st when 'moi' then n_moi := n_moi + 1; when 'da_co' then n_co := n_co + 1; when 'thieu_sale' then n_sale := n_sale + 1; else n_loi := n_loi + 1; end case;
    out := out || jsonb_build_object('i', i, 'st', v_st, 'ly_do', v_ly, 'sale_id', v_sale, 'kh', v_kh, 'co_kh', v_c is not null, 'gia', v_gia, 'md', v_md, 'username', v_user);
  end loop;
  if not p_dry and n_moi > 0 then
    insert into public.out_events(action, data) values ('import_ton', jsonb_build_object('moi', n_moi, 'bo_qua', n_co + n_sale + n_loi, 'he_so', p_he_so));
  end if;
  return jsonb_build_object('rows', out, 'moi', n_moi, 'da_co', n_co, 'thieu_sale', n_sale, 'loi', n_loi);
end $$;
grant execute on function public.out_items_import_ton(jsonb, boolean, numeric) to authenticated;
