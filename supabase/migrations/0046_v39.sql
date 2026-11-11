-- =====================================================================
-- 0046 · Bản 39 (11/11/2026)
--  Ngày trên chứng từ (ĐĐH, BBGN, HĐ mua bán) phải TRÙNG ngày in trên hóa đơn đã ký.
--  Trước đây ngay_hd = ngày kế toán / hệ thống đánh dấu "Đã ký" (có thể chậm 1–2 ngày so với ngày HĐ).
--  Nay trình duyệt đọc "Ngày … tháng … năm …" trong PDF HĐ đã ký (lưu Drive) và sửa ngay_hd cho đúng trước khi xuất chứng từ.
-- =====================================================================
set search_path = public, app, extensions;

create or replace function public.out_ky_fix_ngay(p_id uuid, p_ngay date) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices;
begin
  select * into v from public.out_invoices where id = p_id for update;
  if v.id is null or not (app.is_acc() or app.in_tree(v.sale_id)) then raise exception 'Không có quyền với HĐ này'; end if;
  if v.status <> 'da_ky' then raise exception 'HĐ chưa ký'; end if;
  if not exists(select 1 from public.out_invoice_files f where f.invoice_id = p_id and f.kind = 'ky') then raise exception 'Chưa có PDF HĐ đã ký'; end if;
  if p_ngay is null or p_ngay > app.vn_today() or p_ngay < coalesce(v.ngay_hd, app.vn_today()) - 60 or p_ngay < (v.created_at at time zone 'Asia/Ho_Chi_Minh')::date - 1 then
    raise exception 'Ngày HĐ đọc từ PDF không hợp lệ: %', p_ngay; end if;
  if v.ngay_hd is not distinct from p_ngay then return false; end if;
  update public.out_invoices set ngay_hd = p_ngay, updated_at = now() where id = p_id;
  insert into public.out_events(invoice_id, action, note, data) values (p_id, 'ngay_hd',
    'Ngày HĐ theo PDF đã ký: ' || to_char(p_ngay, 'DD/MM/YYYY') || coalesce(' (trước: ' || to_char(v.ngay_hd, 'DD/MM/YYYY') || ')', ''),
    jsonb_build_object('from', v.ngay_hd, 'to', p_ngay, 'auto', true));
  return true;
end $$;
grant execute on function public.out_ky_fix_ngay(uuid, date) to authenticated;

reset search_path;
