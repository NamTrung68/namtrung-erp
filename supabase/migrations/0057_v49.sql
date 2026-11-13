-- Bản 49 — Nạp Excel pháp nhân đủ cột (giống file Xuất Excel)
--  · Thêm cột: Mặc định (★), Ghi chú, Người nhận chuyển phát, SĐT nhận
--  · Ô TRỐNG = giữ nguyên giá trị đang có (pháp nhân cũ) / dùng mặc định (pháp nhân mới). Gõ "-" = xóa trắng ô đó
--  · Tên đơn vị để trống được nếu cùng username + MST đã có pháp nhân (giữ tên cũ)
--  · Mặc định: ★ / x / 1 / có → đặt pháp nhân mặc định của khách; khách chưa có ★ thì pháp nhân nạp vào tự thành mặc định

/** Giá trị ô nạp: trống → giữ cũ; "-" → xóa (null); còn lại → giá trị mới */
create or replace function app.xl_val(p_new text, p_old text) returns text language sql immutable as $$
  select case when nullif(btrim(coalesce(p_new, '')), '') is null then p_old when btrim(p_new) = '-' then null else btrim(p_new) end
$$;

create or replace function public.out_buyers_import_v2(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; k int := 0; n_moi int := 0; n_sua int := 0; loi jsonb := '[]'; v_id uuid; v_mst text; v_c uuid; v_user text; v_name text; v_ngay date;
        b public.out_buyers; v_md boolean; v_sdt text;
begin
  if not app.has_role('admin', 'ke_toan', 'bgd') then raise exception 'Chỉ Kế toán / Admin / BGĐ'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    k := k + 1;
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), '');
    v_name := nullif(regexp_replace(btrim(coalesce(r->>'name', '')), '\s+', ' ', 'g'), '');
    if v_mst is null then continue; end if;
    begin
      v_c := null; v_id := null; b := null; v_user := app.norm_username(nullif(btrim(r->>'username'), ''));
      v_md := lower(btrim(coalesce(r->>'mac_dinh', ''))) in ('★', 'x', '1', 'có', 'co', 'true', 'yes', 'mặc định', 'mac dinh');
      if not app.mst_ok(v_mst) then raise exception 'MST "%" sai dạng — 10 số, 10-3 số hoặc CCCD 12 số', v_mst; end if;
      if coalesce(btrim(r->>'email'), '') not in ('', '-') and btrim(r->>'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Email "%" sai dạng', r->>'email'; end if;
      v_sdt := case when coalesce(btrim(r->>'sdt_nhan'), '') in ('', '-') then btrim(coalesce(r->>'sdt_nhan', '')) else app.sdt_norm(r->>'sdt_nhan') end;
      if v_sdt is null then raise exception 'SĐT nhận "%" sai dạng', r->>'sdt_nhan'; end if;
      if v_user is not null then
        select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(v_user) or upper(btrim(sys_code)) = upper(v_user)) order by created_at limit 1;
      end if;
      if v_name is not null then
        select id into v_id from public.out_buyers x
         where btrim(x.tax_code) = v_mst and lower(btrim(x.name)) = lower(v_name)
           and (v_c is not null and x.customer_id = v_c or v_c is null and x.customer_id is null and lower(coalesce(x.username, '')) = lower(coalesce(v_user, '')))
         limit 1;
      end if;
      if v_id is null then
        select id into v_id from public.out_buyers x
         where btrim(x.tax_code) = v_mst
           and (v_c is not null and x.customer_id = v_c or v_c is null and x.customer_id is null and lower(coalesce(x.username, '')) = lower(coalesce(v_user, '')))
         order by x.is_default desc, x.created_at desc limit 1;
      end if;
      if v_id is not null then
        select * into b from public.out_buyers where id = v_id for update;
        v_ngay := case when coalesce(btrim(r->>'ngay_hdnt'), '') = '-' then null
                       when nullif(btrim(r->>'ngay_hdnt'), '') is not null then nullif(btrim(r->>'ngay_hdnt'), '')::date
                       when nullif(btrim(r->>'ma_hdnt'), '') is not null and btrim(r->>'ma_hdnt') <> '-' then app.hdnt_ngay(r->>'ma_hdnt', null)
                       else b.ngay_hdnt end;
        update public.out_buyers set name = coalesce(v_name, b.name), username = coalesce(v_user, b.username),
          address = app.xl_val(r->>'address', b.address), email = app.xl_val(r->>'email', b.email), note = app.xl_val(r->>'note', b.note),
          dai_dien = app.xl_val(r->>'dai_dien', b.dai_dien), chuc_vu = app.xl_val(r->>'chuc_vu', b.chuc_vu), dia_chi_giao = app.xl_val(r->>'dia_chi_giao', b.dia_chi_giao),
          ma_hdnt = app.xl_val(r->>'ma_hdnt', b.ma_hdnt), ngay_hdnt = case when app.xl_val(r->>'ma_hdnt', b.ma_hdnt) is null then null else coalesce(v_ngay, b.ngay_hdnt) end,
          nguoi_nhan = app.xl_val(r->>'nguoi_nhan', b.nguoi_nhan), sdt_nhan = app.xl_val(nullif(v_sdt, ''), b.sdt_nhan),
          updated_at = now(), updated_by = auth.uid()
         where id = v_id;
        n_sua := n_sua + 1;
      else
        if v_name is null then raise exception 'Pháp nhân mới — cần điền Tên đơn vị'; end if;
        v_ngay := app.hdnt_ngay(nullif(btrim(r->>'ma_hdnt'), '-'), nullif(nullif(btrim(r->>'ngay_hdnt'), ''), '-')::date);
        insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note, dai_dien, chuc_vu, dia_chi_giao, ma_hdnt, ngay_hdnt, nguoi_nhan, sdt_nhan, updated_at, updated_by)
        values (v_c, v_user, v_name, v_mst, app.xl_val(r->>'address', null), app.xl_val(r->>'email', null), coalesce(app.xl_val(r->>'note', null), 'Nạp Excel'),
                app.xl_val(r->>'dai_dien', null), app.xl_val(r->>'chuc_vu', null), app.xl_val(r->>'dia_chi_giao', null), app.xl_val(r->>'ma_hdnt', null), v_ngay,
                app.xl_val(r->>'nguoi_nhan', null), nullif(nullif(v_sdt, ''), '-'), now(), auth.uid())
        returning id into v_id;
        select * into b from public.out_buyers where id = v_id;
        n_moi := n_moi + 1;
      end if;
      -- ★ mặc định: theo cột Mặc định; khách chưa có ★ thì pháp nhân này thành ★
      if b.customer_id is not null and (v_md or not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default)) then
        update public.out_buyers set is_default = (id = v_id) where customer_id = b.customer_id and (is_default or id = v_id);
      end if;
    exception when others then
      loi := loi || jsonb_build_object('dong', k, 'name', v_name, 'tax_code', v_mst, 'username', r->>'username',
        'error', case when sqlstate = '23505' then 'Trùng: khách / username này đã có pháp nhân cùng tên + MST' when sqlstate in ('22007', '22008') then 'Ngày HĐ nguyên tắc sai dạng' else sqlerrm end);
    end;
  end loop;
  perform app.out_buyers_relink();
  return jsonb_build_object('n', n_moi + n_sua, 'moi', n_moi, 'sua', n_sua, 'loi', loi);
end $$;
grant execute on function public.out_buyers_import_v2(jsonb) to authenticated;
