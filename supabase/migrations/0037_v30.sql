-- =====================================================================
-- 0037 · Bản 30 (05/11/2026): Bước 4 "Chờ ký" — bỏ tải PDF đã ký; kế toán ký trên MISA rồi nhập MÃ TRA CỨU
--  · Nhập mã tra cứu = chuyển "Đã ký" + báo sale. Sale bấm mã tra cứu → mở HĐ trên meinvoice.vn
--  · Kế toán sửa được mã tra cứu đã nhập (gõ nhầm); mỗi mã chỉ dùng cho 1 HĐ
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 30');

alter table public.out_invoices add column if not exists ma_tra_cuu text;
create unique index if not exists out_invoices_ma_tra_cuu on public.out_invoices(upper(ma_tra_cuu)) where ma_tra_cuu is not null;

-- Đường dẫn xem HĐ theo mã tra cứu (đổi được ở Cấu hình nếu MISA đổi)
update public.settings set value = value || jsonb_build_object('tra_cuu_url', 'https://www.meinvoice.vn/tra-cuu/tra-cuu/DownloadHandler.ashx?Type=pdf&Viewer=1&ext=QXVLM59J&Code={code}')
 where key = 'accounting' and not (value ? 'tra_cuu_url');

-- Kế toán: ký xong trên MISA → nhập mã tra cứu → "Đã ký" (gọi lại để sửa mã của HĐ đã ký)
create or replace function public.out_mark_signed(p_id uuid, p_ma text, p_so_hd text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; m text := upper(regexp_replace(coalesce(p_ma, ''), '[[:space:]]+', '', 'g')); dup text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán xác nhận ký'; end if;
  if m !~ '^[A-Z0-9_-]{6,30}$' then raise exception 'Mã tra cứu không hợp lệ (6–30 ký tự chữ / số)'; end if;
  select * into v from public.out_invoices where id = p_id for update;
  if v.id is null then raise exception 'Không tìm thấy phiếu'; end if;
  if v.status not in ('xac_nhan_ky', 'da_nhap', 'da_ky') then raise exception 'Phiếu % đang "%", chưa tới bước ký', v.code, v.status; end if;
  select code into dup from public.out_invoices where upper(ma_tra_cuu) = m and id <> p_id;
  if dup is not null then raise exception 'Mã tra cứu % đã gắn cho phiếu %', m, dup; end if;
  update public.out_invoices set ma_tra_cuu = m, so_hd = coalesce(nullif(btrim(p_so_hd), ''), so_hd),
    status = 'da_ky', ngay_hd = coalesce(ngay_hd, app.vn_today()),
    status_at = case when v.status = 'da_ky' then status_at else now() end, status_by = case when v.status = 'da_ky' then status_by else auth.uid() end, updated_at = now()
  where id = p_id;
  insert into public.out_events(invoice_id, action, note, data)
  values (p_id, case when v.status = 'da_ky' then 'sua_ma_tra_cuu' else 'status' end, 'Mã tra cứu ' || m,
          jsonb_build_object('from', v.status, 'to', 'da_ky', 'ma_tra_cuu', m, 'ma_cu', v.ma_tra_cuu));
  if v.status <> 'da_ky' then
    perform app.notify(v.sale_id, 'acc', 'Đã ký HĐ: ' || v.code, coalesce(v.buyer_name, '') || ' — mã tra cứu ' || m || '. Bấm để xem HĐ.', '#/hd?inv=' || v.id);
  end if;
  return jsonb_build_object('code', v.code, 'ma_tra_cuu', m);
end $$;
grant execute on function public.out_mark_signed(uuid, text, text) to authenticated;

reset search_path;
