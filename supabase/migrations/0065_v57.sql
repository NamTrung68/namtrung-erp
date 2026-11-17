-- Bản 57 — "Đủ hồ sơ pháp nhân" = đầy đủ thông tin VÀ đã ký HĐ nguyên tắc mua bán
--  Thiếu bất kỳ mục nào sau là "Chưa nhập đủ hồ sơ": gắn khách ERP, Tên, MST đúng dạng, Địa chỉ, Email, Người đại diện, Chức vụ,
--  Mã HĐNT, Ngày ký HĐNT, Bản scan HĐNT, Người nhận, SĐT nhận chuyển phát. (Địa chỉ giao hàng trống = dùng địa chỉ ĐKKD, không tính thiếu)
create or replace function app.pn_thieu(b public.out_buyers) returns text[] language sql stable security definer set search_path = public, app as $$
  select array_remove(array[
    case when b.customer_id is null then 'Khách ERP' end,
    case when coalesce(btrim(b.name), '') = '' then 'Tên' end,
    case when not coalesce(app.mst_ok(b.tax_code), false) then 'MST' end,
    case when coalesce(btrim(b.address), '') = '' then 'Địa chỉ' end,
    case when coalesce(btrim(b.email), '') = '' then 'Email' end,
    case when coalesce(btrim(b.dai_dien), '') = '' then 'Người đại diện' end,
    case when coalesce(btrim(b.chuc_vu), '') = '' then 'Chức vụ' end,
    case when nullif(btrim(b.ma_hdnt), '') is null then 'Mã HĐNT' end,
    case when b.ngay_hdnt is null then 'Ngày HĐNT' end,
    case when not exists(select 1 from public.ho_so_scans s where s.deleted_at is null and s.invoice_id is null and 'hdnt' = any(s.kinds)
                           and (s.buyer_id = b.id or btrim(s.tax_code) = btrim(b.tax_code))) then 'Scan HĐNT' end,
    case when coalesce(btrim(b.nguoi_nhan), '') = '' then 'Người nhận' end,
    case when coalesce(btrim(b.sdt_nhan), '') = '' then 'SĐT nhận' end], null)
$$;
