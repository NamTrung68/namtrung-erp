-- =====================================================================
-- 0032 · Bản 25: nạp HĐ chính thức APT — kết quả đối chiếu xem trước (tên + SL → dòng nháp của xe) được lưu đúng như đã xem
--  · Mỗi dòng gửi kèm acc_line_id (dòng nháp đã ghép) → bảng gốc nhận mã khai báo, đơn, khách, sale, giá khách từ dòng đó
--  · Đổi dòng nháp khi nạp lại → xóa mã khai báo / đơn / sale cũ rồi ghép lại; dòng đã sửa tay (match_src = 'tay') giữ nguyên
--  · Không gửi acc_line_id (file cũ) → hệ thống tự ghép như bản 23
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 25');

create or replace function public.out_items_import(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; v_id uuid; n_new int := 0; n_upd int := 0; v_ids uuid[] := '{}'; v_line uuid; t public.out_items;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select * into t from public.out_items where ma_hang = r->>'ma_hang' and part = coalesce((r->>'part')::int, 1);
    v_id := t.id;
    if v_id is null then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
    v_line := nullif(r->>'acc_line_id', '')::uuid;
    if v_line is not null and not exists(select 1 from public.acc_lines where id = v_line) then v_line := null; end if;
    insert into public.out_items as x(ma_hang, part, stt_so, ten, dvt, vat, sl_nhap, dg_nhap, so_hd_vao, ky_hieu, ngay_vao, ncc, stt_hd, md, nvkd, username, gia_so, legacy, updated_at, updated_by)
    values (r->>'ma_hang', coalesce((r->>'part')::int, 1), (r->>'stt_so')::numeric, r->>'ten', r->>'dvt', (r->>'vat')::numeric, coalesce((r->>'sl_nhap')::numeric, 0), (r->>'dg_nhap')::numeric,
            r->>'so_hd_vao', r->>'ky_hieu', nullif(r->>'ngay_vao','')::date, r->>'ncc', (r->>'stt_hd')::int,
            case when r->>'md' ~* 'md' then app.norm_md(r->>'md') else nullif(btrim(r->>'md'), '') end, nullif(btrim(r->>'nvkd'), ''), nullif(btrim(r->>'username'), ''),
            nullif((r->>'gia_so')::numeric, 0), r->'legacy', now(), auth.uid())
    on conflict (ma_hang, part) do update set stt_so = excluded.stt_so, ten = excluded.ten, dvt = excluded.dvt, vat = excluded.vat, sl_nhap = excluded.sl_nhap, dg_nhap = excluded.dg_nhap,
      so_hd_vao = excluded.so_hd_vao, ky_hieu = excluded.ky_hieu, ngay_vao = excluded.ngay_vao, ncc = excluded.ncc, stt_hd = excluded.stt_hd,
      md = case when coalesce(x.match_src, '') = 'tay' then x.md else coalesce(excluded.md, x.md) end, nvkd = coalesce(excluded.nvkd, x.nvkd),
      username = case when coalesce(x.match_src, '') = 'tay' then x.username else coalesce(excluded.username, x.username) end,
      sale_id = case when coalesce(x.match_src, '') <> 'tay' and excluded.nvkd is not null and app.match_sale(excluded.nvkd) is not null then app.match_sale(excluded.nvkd) else x.sale_id end,
      gia_so = coalesce(excluded.gia_so, x.gia_so), legacy = excluded.legacy, updated_at = now(), updated_by = auth.uid()
    returning id into v_id;
    -- gắn đúng dòng nháp đã đối chiếu trên màn hình (trừ dòng kế toán đã ghép tay)
    if v_line is not null and coalesce(t.match_src, '') <> 'tay' and t.acc_line_id is distinct from v_line then
      if exists(select 1 from public.out_items o where o.acc_line_id = v_line and o.id <> v_id) then
        update public.out_items set acc_line_id = null where acc_line_id = v_line and id <> v_id and coalesce(match_src, '') <> 'tay';
      end if;
      update public.out_items set acc_line_id = v_line, match_src = 'ten', ma_kb = null,
        md = case when t.id is null or t.acc_line_id is null then md else null end,
        sale_id = case when t.id is null or t.acc_line_id is null then sale_id else null end,
        customer_id = case when t.id is null or t.acc_line_id is null then customer_id else null end,
        username = case when t.id is null or t.acc_line_id is null then username else null end,
        gia_khach = case when gia_src = 'sale' then gia_khach else null end, gia_src = case when gia_src = 'sale' then gia_src else null end,
        lech = false, lech_note = null, lech_ok_by = null, lech_ok_at = null, lech_ok_note = null
      where id = v_id;
    end if;
    perform app.out_item_match(v_id); v_ids := v_ids || v_id;
  end loop;
  for v_id in select id from public.out_items where id = any(v_ids) and md is not null and (sale_id is null or username is null) loop perform app.out_item_match(v_id); end loop;
  insert into public.out_events(action, data) values ('import', jsonb_build_object('new', n_new, 'upd', n_upd));
  return jsonb_build_object('new', n_new, 'upd', n_upd);
end $$;
grant execute on function public.out_items_import(jsonb) to authenticated;

reset search_path;
