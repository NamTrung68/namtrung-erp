-- =====================================================================
-- 0038 · Bản 31 (05/11/2026): Tạo HĐ nháp MISA meInvoice bằng API — chạy SONG SONG với cách làm tay
--  · Làm tay giữ nguyên: Xuất Excel → nhập MISA → tải PDF nháp → dán mã tra cứu
--  · API (khi có ClientID): kế toán bấm "Tạo nháp MISA" → hàm máy chủ "misa" kiểm, gửi, lấy PDF về Drive;
--    tự dò MISA 15 phút/lần, HĐ đã ký → tự ghi số HĐ + mã tra cứu, chuyển "Đã ký"
--  · Bảng out_misa: mỗi dòng = 1 lần tạo nháp (RefID = GUID mới, không dùng lại). Mỗi phiếu tối đa 1 nháp đang sống.
--  · Chống tạo đôi giữa 2 cách: phiếu đã xuất Excel không tạo API được (trừ khi bỏ mốc export); phiếu có nháp API bị bỏ khỏi file Excel
--  · Chỉ Kế toán / Admin / BGĐ thao tác; sale, CSKH, trưởng nhóm chỉ xem theo phạm vi như phiếu xuất HĐ
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 31');

-- ---------- Bảng ----------
create table if not exists public.out_misa(
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.out_invoices(id) on delete cascade,
  ref_id uuid not null unique default gen_random_uuid(),
  lan int not null,
  invoice_version int not null default 1,
  sale_id uuid references public.profiles(id),
  trang_thai text not null default 'dang_tao' check (trang_thai in ('dang_tao','da_tao','loi','da_xoa','da_phat_hanh')),
  payload jsonb,
  tien_hang numeric, tien_thue numeric, tong_tt numeric,
  misa_tong_tt numeric, misa_tien_thue numeric, khop boolean,
  so_hd text, ma_tra_cuu text, phat_hanh_at timestamptz,
  file_id uuid references public.out_invoice_files(id) on delete set null,
  loi_ma text, loi_text text,
  created_by uuid default auth.uid() references public.profiles(id), created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_by uuid references public.profiles(id), deleted_at timestamptz, synced_at timestamptz,
  unique (invoice_id, lan)
);
-- 1 phiếu chỉ có tối đa 1 nháp đang sống (bấm 2 lần / 2 máy cùng bấm → dòng thứ 2 bị từ chối)
create unique index if not exists out_misa_one_active on public.out_misa(invoice_id) where trang_thai in ('dang_tao','da_tao','da_phat_hanh');
create index if not exists out_misa_sync on public.out_misa(trang_thai, synced_at) where trang_thai in ('dang_tao','da_tao');
create index if not exists out_misa_sale on public.out_misa(sale_id);
alter table public.out_misa enable row level security;
revoke all on public.out_misa from anon, authenticated;
grant select on public.out_misa to authenticated;
drop policy if exists out_misa_read on public.out_misa;
create policy out_misa_read on public.out_misa for select to authenticated using (app.is_acc() or app.in_tree(sale_id));

-- Token MISA: chỉ hàm máy chủ (service_role) đọc / ghi
create table if not exists app.misa_token(id int primary key default 1 check (id = 1), token text, got_at timestamptz);
revoke all on app.misa_token from public, anon, authenticated;

-- Cấu hình MISA nằm trong cấu hình Kế toán: accounting.misa = {enabled, template_id, inv_series, with_code, batch, auto_sync}
update public.settings set value = value || jsonb_build_object('misa', jsonb_build_object('enabled', false, 'with_code', true, 'batch', 10, 'auto_sync', true))
 where key = 'accounting' and not (value ? 'misa');

-- ---------- Hàm hỗ trợ ----------
create or replace function app.is_service() returns boolean language sql stable as $$
  -- 'role' = vai trò đã SET ROLE của phiên (không đổi bên trong hàm security definer, khác current_user)
  select coalesce(current_setting('role', true), '') = 'service_role' or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', '') = 'service_role'
$$;
create or replace function app.misa_cfg() returns jsonb language sql stable security definer set search_path = public, app as $$
  select coalesce(app.setting('accounting')->'misa', '{}'::jsonb)
$$;
create or replace function app.vn_iso(p timestamptz default now()) returns text language sql stable as $$
  select to_char(p at time zone 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD"T"HH24:MI:SS') || '+07:00'
$$;
-- Mã số thuế / CCCD chuẩn: 10 số, 10-3 số hoặc 12 số
create or replace function app.mst_ok(p text) returns boolean language sql immutable as $$
  select coalesce(btrim(p), '') ~ '^([0-9]{10}|[0-9]{10}-[0-9]{3}|[0-9]{12})$'
$$;
create or replace function app.has_emoji(p text) returns boolean language sql immutable as $$
  select coalesce(p, '') ~ '[\U0001F000-\U0010FFFF]' or coalesce(p, '') ~ '[☀-➿️‍]'
$$;

-- Dữ liệu gửi MISA (InvoiceData) dựng từ phiếu XHD — 1 chỗ duy nhất. Làm tròn từng dòng rồi cộng (như file Excel + khuyến nghị MISA)
create or replace function app.out_misa_payload(p_inv uuid, p_ref uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v public.out_invoices; m jsonb := app.misa_cfg(); d jsonb; tt numeric; th numeric; rates int; one_rate int; mds text; sale_code text; kh text;
begin
  select * into v from public.out_invoices where id = p_inv;
  if v.id is null then return null; end if;
  with l as (
    select l.stt, t.ma_hang, t.ten, t.dvt, l.sl, l.don_gia, coalesce(l.vat, t.vat) vat, round(l.sl * l.don_gia) tt, t.md
      from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = p_inv)
  select coalesce(jsonb_agg(jsonb_build_object(
           'InventoryItemType', 0, 'InventoryItemCode', l.ma_hang, 'Description', l.ten, 'UnitName', l.dvt,
           'Quantity', l.sl, 'UnitPrice', l.don_gia, 'AmountOC', l.tt, 'Amount', l.tt,
           'DiscountRate', 0, 'DiscountAmountOC', 0, 'DiscountAmount', 0,
           'VATRate', case when l.vat is null then null else round(l.vat * 100)::int end,
           'VATAmountOC', round(l.tt * coalesce(l.vat, 0)), 'VATAmount', round(l.tt * coalesce(l.vat, 0)),
           'SortOrder', l.stt, 'SortOrderView', l.stt) order by l.stt), '[]'),
         coalesce(sum(l.tt), 0), coalesce(sum(round(l.tt * coalesce(l.vat, 0))), 0),
         count(distinct round(coalesce(l.vat, -1) * 100)), min(round(l.vat * 100))::int,
         string_agg(distinct l.md, ', ')
    into d, tt, th, rates, one_rate, mds from l;
  select coalesce(nullif(btrim(p.employee_code), ''), p.full_name) into sale_code from public.profiles p where p.id = v.sale_id;
  select coalesce(nullif(btrim(c.sys_code), ''), c.code) into kh from public.customers c where c.id = v.customer_id;
  return jsonb_strip_nulls(jsonb_build_object(
    'RefID', p_ref, 'InvoiceTemplateID', m->>'template_id', 'InvSeries', m->>'inv_series',
    'InvDate', to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'YYYY-MM-DD') || 'T00:00:00+07:00', 'InvNo', '<Chưa cấp số>',
    'AccountObjectName', btrim(v.buyer_name), 'AccountObjectTaxCode', nullif(btrim(v.tax_code), ''), 'AccountObjectCode', kh,
    'AccountObjectAddress', nullif(btrim(v.address), ''), 'ReceiverEmail', nullif(btrim(v.email), ''),
    'PaymentMethod', coalesce(nullif(btrim(v.payment), ''), 'TM/CK'), 'CurrencyCode', 'VND', 'CurrencyID', 'VND', 'ExchangeRate', 1, 'DiscountRate', 0,
    'VATRate', case when rates = 1 then one_rate end, 'EInvoiceStatus', 1,
    'TotalSaleAmountOC', tt, 'TotalSaleAmount', tt, 'TotalDiscountAmountOC', 0, 'TotalDiscountAmount', 0,
    'TotalVATAmountOC', th, 'TotalVATAmount', th, 'TotalAmountOC', tt + th, 'TotalAmount', tt + th,
    'CreatedDate', app.vn_iso(), 'ModifiedDate', app.vn_iso(),
    'CustomField1', v.code, 'CustomField2', sale_code, 'CustomField3', mds,
    'InvoiceDetails', d));
end $$;
revoke all on function app.out_misa_payload(uuid, uuid) from public, anon;

-- Kiểm 1 phiếu trước khi gửi: lỗi (chặn) + cảnh báo (không chặn) + tổng tiền + nháp đang có
create or replace function app.out_misa_eval(p_inv uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v public.out_invoices; m jsonb := app.misa_cfg(); e text[] := '{}'; w text[] := '{}'; act public.out_misa; prev public.out_misa; r record;
        n int := 0; tt numeric := 0; th numeric := 0; p jsonb; old boolean := false;
begin
  select * into v from public.out_invoices where id = p_inv;
  if v.id is null then return jsonb_build_object('invoice_id', p_inv, 'errors', jsonb_build_array('Không tìm thấy phiếu')); end if;
  select * into act from public.out_misa where invoice_id = p_inv and trang_thai in ('dang_tao','da_tao','da_phat_hanh') order by lan desc limit 1;
  select * into prev from public.out_misa where invoice_id = p_inv and payload is not null and trang_thai in ('da_tao','da_xoa','da_phat_hanh') order by lan desc limit 1;
  if coalesce(m->>'template_id', '') = '' or coalesce(m->>'inv_series', '') = '' then e := e || 'Chưa chọn mẫu HĐ MISA (Cấu hình → Kế toán – Hóa đơn → MISA)'; end if;
  if v.status <> 'cho_nhap' then
    e := e || ('Phiếu đang "' || case v.status when 'soan' then 'sale đang soạn' when 'cho_duyet_gia' then 'chờ duyệt giá' when 'da_nhap' then 'có nháp' when 'tra_sua' then 'sale trả sửa'
      when 'xac_nhan_ky' then 'chờ ký' when 'da_ky' then 'đã ký' when 'huy' then 'hủy' else v.status end || '" — chỉ tạo nháp cho phiếu "Đã gửi — chờ export"');
  end if;
  if act.id is not null then
    if act.trang_thai = 'dang_tao' then e := e || ('Đang tạo nháp lần ' || act.lan || ' — chờ xong hoặc bấm Kiểm tra trạng thái MISA');
    elsif act.trang_thai = 'da_phat_hanh' then e := e || ('MISA đã phát hành HĐ số ' || coalesce(act.so_hd, '?') || ' cho phiếu này');
    elsif act.invoice_version >= v.version then e := e || ('Đã có nháp MISA lần ' || act.lan || ' — muốn tạo lại thì bấm Tạo lại nháp ở chi tiết phiếu');
    else old := true; w := w || ('Nháp lần ' || act.lan || ' là bản cũ (sale đã sửa) — sẽ xóa trên MISA rồi tạo nháp mới'); end if;
  elsif v.misa_at is not null then
    e := e || ('Đã xuất Excel nhập MISA lúc ' || to_char(v.misa_at at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM') || ' — nếu đã nhập vào MISA thì xóa nháp tay trên MISA, rồi bấm "Bỏ mốc export"');
  end if;
  if coalesce(btrim(v.buyer_name), '') = '' then e := e || 'Thiếu tên đơn vị mua'::text; end if;
  if coalesce(btrim(v.address), '') = '' then e := e || 'Thiếu địa chỉ đơn vị mua'::text; end if;
  if coalesce(btrim(v.tax_code), '') = '' then e := e || 'Thiếu MST / CCCD'::text;
  elsif not app.mst_ok(v.tax_code) then e := e || ('MST "' || v.tax_code || '" sai dạng (10 số, 10-3 số hoặc 12 số)'); end if;
  if coalesce(btrim(v.email), '') <> '' and btrim(v.email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then e := e || ('Email "' || v.email || '" sai dạng'); end if;
  if coalesce(btrim(v.email), '') = '' then w := w || 'Khách chưa có email nhận HĐ'::text; end if;
  if app.has_emoji(concat_ws(' ', v.buyer_name, v.address, v.email)) then e := e || 'Thông tin đơn vị mua có emoji / ký tự lạ — MISA sẽ từ chối'::text; end if;
  for r in select l.stt, t.ma_hang, t.ten, t.dvt, l.sl, l.don_gia, coalesce(l.vat, t.vat) vat, t.dg_nhap, t.lech, t.lech_ok_at
             from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = p_inv order by l.stt loop
    n := n + 1; tt := tt + round(r.sl * r.don_gia); th := th + round(round(r.sl * r.don_gia) * coalesce(r.vat, 0));
    if coalesce(btrim(r.ten), '') = '' then e := e || ('Dòng ' || r.stt || ': thiếu tên hàng'); end if;
    if coalesce(btrim(r.dvt), '') = '' then e := e || ('Dòng ' || r.stt || ': thiếu đơn vị tính'); end if;
    if coalesce(r.sl, 0) <= 0 then e := e || ('Dòng ' || r.stt || ': số lượng phải > 0'); end if;
    if coalesce(r.don_gia, 0) <= 0 then e := e || ('Dòng ' || r.stt || ': đơn giá phải > 0'); end if;
    if r.vat is null or not exists(select 1 from unnest(array[0, 0.05, 0.08, 0.1]) x where abs(x - r.vat) < 0.00001) then
      e := e || ('Dòng ' || r.stt || ': thuế suất ' || coalesce(round(r.vat * 100, 2)::text || '%', 'trống') || ' — chỉ nhận 0, 5, 8, 10%'); end if;
    if app.has_emoji(concat_ws(' ', r.ten, r.dvt)) then e := e || ('Dòng ' || r.stt || ': có emoji / ký tự lạ'); end if;
    if r.lech and r.lech_ok_at is null then e := e || ('Dòng ' || r.stt || ' (' || r.ma_hang || '): đang lệch so với nháp APT — chờ kế toán xử lý'); end if;
    if r.dg_nhap is not null and r.don_gia < r.dg_nhap then w := w || ('Dòng ' || r.stt || ': đơn giá thấp hơn giá nhập'); end if;
  end loop;
  if n = 0 then e := e || 'Phiếu không có dòng hàng'::text; elsif n > 200 then e := e || ('Phiếu có ' || n || ' dòng — tối đa 200 dòng/HĐ, tách phiếu'); end if;
  if abs((tt + th) - app.out_inv_total(p_inv)) > 0.5 then e := e || 'Tổng tiền tính lại lệch với tổng phiếu — báo Admin'::text; end if;
  if exists(select 1 from public.out_invoices o where o.id <> v.id and o.status <> 'huy' and coalesce(o.tax_code, '') = coalesce(v.tax_code, '') and coalesce(v.tax_code, '') <> ''
              and o.created_at > now() - interval '7 days' and abs(app.out_inv_total(o.id) - (tt + th)) < 0.5) then
    w := w || 'Có phiếu khác cùng MST, cùng tổng tiền trong 7 ngày — kiểm tra trùng'::text; end if;
  p := app.out_misa_payload(p_inv, null);
  return jsonb_build_object('invoice_id', v.id, 'code', v.code, 'status', v.status, 'version', v.version, 'sale_id', v.sale_id, 'buyer_name', v.buyer_name, 'tax_code', v.tax_code,
    'so_dong', n, 'tien_hang', tt, 'tien_thue', th, 'tong', tt + th, 'errors', to_jsonb(e), 'warnings', to_jsonb(w), 'ok', cardinality(e) = 0,
    'old', old, 'active', case when act.id is null then null else jsonb_build_object('hd_id', act.id, 'lan', act.lan, 'ref_id', act.ref_id, 'trang_thai', act.trang_thai) end,
    'payload', p, 'prev', case when prev.id is null then null else jsonb_build_object('lan', prev.lan, 'payload', prev.payload) end);
end $$;
revoke all on function app.out_misa_eval(uuid) from public, anon;

-- ---------- Hàm cho Kế toán (trình duyệt) ----------
-- Kiểm tra trước khi gửi (không ghi gì)
create or replace function public.out_misa_check(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin tạo nháp MISA'; end if;
  if coalesce(array_length(p_ids, 1), 0) > 500 then raise exception 'Tối đa 500 phiếu mỗi lần'; end if;
  return (select coalesce(jsonb_agg(app.out_misa_eval(x) order by o), '[]') from unnest(p_ids) with ordinality u(x, o));
end $$;
grant execute on function public.out_misa_check(uuid[]) to authenticated;

-- Giữ chỗ trước khi gọi MISA: ghi dòng "đang tạo" + RefID mới. Nháp cũ (sale đã sửa) → trả need_delete để hàm máy chủ xóa trên MISA trước
create or replace function public.out_misa_claim(p_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x uuid; ev jsonb; out jsonb := '[]'; v public.out_invoices; v_ref uuid; v_hd uuid; v_lan int; p jsonb;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin tạo nháp MISA'; end if;
  if coalesce(array_length(p_ids, 1), 0) > 30 then raise exception 'Tối đa 30 HĐ mỗi lô'; end if;
  foreach x in array p_ids loop
    select * into v from public.out_invoices where id = x for update;
    ev := app.out_misa_eval(x);
    if not (ev->>'ok')::boolean then
      out := out || jsonb_build_object('invoice_id', x, 'code', ev->>'code', 'errors', ev->'errors'); continue; end if;
    if (ev->>'old')::boolean then
      out := out || jsonb_build_object('invoice_id', x, 'code', ev->>'code', 'need_delete', ev->'active'); continue; end if;
    v_ref := gen_random_uuid();
    select coalesce(max(lan), 0) + 1 into v_lan from public.out_misa where invoice_id = x;
    p := app.out_misa_payload(x, v_ref);
    if abs(((p->>'TotalAmountOC')::numeric) - app.out_inv_total(x)) > 0.5 then
      out := out || jsonb_build_object('invoice_id', x, 'code', v.code, 'errors', jsonb_build_array('Tổng dữ liệu gửi MISA lệch tổng phiếu — không gửi')); continue; end if;
    begin
      insert into public.out_misa(invoice_id, ref_id, lan, invoice_version, sale_id, payload, tien_hang, tien_thue, tong_tt)
      values (x, v_ref, v_lan, v.version, v.sale_id, p, (p->>'TotalSaleAmountOC')::numeric, (p->>'TotalVATAmountOC')::numeric, (p->>'TotalAmountOC')::numeric)
      returning id into v_hd;
    exception when unique_violation then
      out := out || jsonb_build_object('invoice_id', x, 'code', v.code, 'errors', jsonb_build_array('Phiếu đang được tạo nháp ở máy khác — tải lại để xem')); continue;
    end;
    out := out || jsonb_build_object('invoice_id', x, 'code', v.code, 'hd_id', v_hd, 'ref_id', v_ref, 'lan', v_lan, 'payload', p);
  end loop;
  return out;
end $$;
grant execute on function public.out_misa_claim(uuid[]) to authenticated;

-- Ghi kết quả tạo nháp. p_rows: [{hd_id, ok, loi_ma, loi_text, misa_tong_tt, misa_tien_thue}]
create or replace function public.out_misa_result(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; h public.out_misa; v public.out_invoices; n int := 0; v_khop boolean; mt numeric;
begin
  if not (app.is_acc() or app.is_service()) then raise exception 'Chỉ Kế toán / Admin'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    select * into h from public.out_misa where id = (r->>'hd_id')::uuid for update;
    if h.id is null or h.trang_thai not in ('dang_tao','da_tao') then continue; end if;
    select * into v from public.out_invoices where id = h.invoice_id;
    if coalesce((r->>'ok')::boolean, false) then
      mt := nullif(r->>'misa_tong_tt', '')::numeric;
      v_khop := case when mt is null then h.khop else abs(mt - h.tong_tt) < 0.5 and abs(coalesce(nullif(r->>'misa_tien_thue', '')::numeric, h.tien_thue) - h.tien_thue) < 0.5 end;
      update public.out_misa set trang_thai = 'da_tao', misa_tong_tt = coalesce(mt, misa_tong_tt), misa_tien_thue = coalesce(nullif(r->>'misa_tien_thue', '')::numeric, misa_tien_thue),
        khop = v_khop, loi_ma = case when v_khop is false then 'LechERP' else null end,
        loi_text = case when v_khop is false then 'MISA lưu tổng ' || mt || ', ERP ' || h.tong_tt || ' — xóa nháp này trên MISA rồi tạo lại' else null end,
        synced_at = now(), updated_at = now() where id = h.id;
      if h.trang_thai = 'dang_tao' then
        update public.out_invoices set misa_at = now(), misa_by = auth.uid(), updated_at = now() where id = v.id and v.status = 'cho_nhap';
        insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', 'Tạo nháp MISA bằng API lần ' || h.lan || case when v_khop is false then ' — MISA LỆCH TIỀN ERP' else '' end,
          jsonb_build_object('ref_id', h.ref_id, 'lan', h.lan, 'tong', h.tong_tt, 'misa_tong', mt));
      end if;
      if v_khop is false then perform app.notify_roles(array['ke_toan'], 'acc', 'Nháp MISA lệch tiền ERP: ' || v.code, 'MISA ' || mt || ' · ERP ' || h.tong_tt, '#/out?inv=' || v.id); end if;
    else
      update public.out_misa set trang_thai = 'loi', loi_ma = left(r->>'loi_ma', 200), loi_text = left(coalesce(r->>'loi_text', 'Lỗi không rõ'), 4000), updated_at = now() where id = h.id;
      insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', 'Tạo nháp MISA lỗi: ' || left(coalesce(r->>'loi_text', ''), 300), jsonb_build_object('ref_id', h.ref_id, 'lan', h.lan, 'loi_ma', r->>'loi_ma'));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_misa_result(jsonb) to authenticated;

-- Gắn PDF nháp (đã lưu Drive) cho nháp API → phiếu "Có nháp", báo sale (dùng lại out_file_attach)
create or replace function public.out_misa_file(p_hd uuid, p_drive_id text, p_name text, p_size_kb int) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare h public.out_misa; v public.out_invoices; res jsonb; fid uuid;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin'; end if;
  select * into h from public.out_misa where id = p_hd for update;
  if h.id is null or h.trang_thai <> 'da_tao' then raise exception 'Nháp MISA không còn ở trạng thái "đã tạo"'; end if;
  if h.khop is false then raise exception 'Nháp MISA lệch tiền ERP — không gửi sale'; end if;
  select * into v from public.out_invoices where id = h.invoice_id;
  if h.invoice_version < v.version then raise exception 'Nháp này là bản cũ (sale đã sửa phiếu) — tạo lại nháp'; end if;
  res := public.out_file_attach(h.invoice_id, 'nhap', p_drive_id, p_name, p_size_kb, h.tong_tt, v.tax_code);
  select id into fid from public.out_invoice_files where invoice_id = h.invoice_id and kind = 'nhap' order by version desc limit 1;
  update public.out_misa set file_id = fid, updated_at = now() where id = h.id;
  return res || jsonb_build_object('file_id', fid);
end $$;
grant execute on function public.out_misa_file(uuid, text, text, int) to authenticated;

-- Đã xóa nháp trên MISA (kế toán bấm Xóa / Tạo lại). Nháp đang dùng của phiếu bị xóa → phiếu quay về "chờ export"
create or replace function public.out_misa_deleted(p_hd uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare h public.out_misa; v public.out_invoices;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin'; end if;
  select * into h from public.out_misa where id = p_hd for update;
  if h.id is null then raise exception 'Không có nháp'; end if;
  if h.trang_thai = 'da_phat_hanh' then raise exception 'HĐ đã phát hành — không xóa được'; end if;
  if h.trang_thai = 'da_xoa' then return; end if;
  update public.out_misa set trang_thai = 'da_xoa', deleted_by = auth.uid(), deleted_at = now(), updated_at = now() where id = h.id;
  select * into v from public.out_invoices where id = h.invoice_id for update;
  insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', 'Xóa nháp MISA lần ' || h.lan || coalesce(' — ' || nullif(btrim(p_note), ''), ''), jsonb_build_object('ref_id', h.ref_id, 'lan', h.lan));
  if h.trang_thai = 'da_tao' and h.invoice_version >= v.version and v.status in ('da_nhap','xac_nhan_ky') then
    update public.out_invoices set status = 'cho_nhap', status_at = now(), status_by = auth.uid(), updated_at = now() where id = v.id;
    perform app.notify(v.sale_id, 'acc', 'Kế toán xóa nháp MISA, sẽ tạo lại: ' || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || nullif(btrim(p_note), ''), ''), '#/out?inv=' || v.id);
  end if;
  -- mốc export do API ghi → nháp API đã xóa thì bỏ mốc (phiếu lại tạo được bằng API hoặc xuất Excel)
  update public.out_invoices set misa_at = null, misa_by = null where id = v.id and status = 'cho_nhap' and misa_at is not null;
end $$;
grant execute on function public.out_misa_deleted(uuid, text) to authenticated;

-- Bỏ mốc "đã xuất Excel" (kế toán đã xóa nháp tay trên MISA) để chuyển sang tạo bằng API
create or replace function public.out_misa_clear_export(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin'; end if;
  with u as (update public.out_invoices i set misa_at = null, misa_by = null, updated_at = now()
              where i.id = any(p_ids) and i.status = 'cho_nhap' and i.misa_at is not null
                and not exists(select 1 from public.out_misa m where m.invoice_id = i.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh')) returning i.id)
  insert into public.out_events(invoice_id, action, note) select id, 'misa', 'Bỏ mốc export Excel (đã xóa nháp tay trên MISA)' from u;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.out_misa_clear_export(uuid[]) to authenticated;

-- Danh sách nháp cần dò trên MISA (đã tạo, hoặc đang tạo quá 10 phút)
create or replace function public.out_misa_sync_list(p_ids uuid[] default null, p_limit int default 500) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.is_acc() or app.is_service()) then raise exception 'Chỉ Kế toán / Admin'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('hd_id', m.id, 'ref_id', m.ref_id, 'trang_thai', m.trang_thai, 'invoice_id', m.invoice_id)), '[]')
    from (select * from public.out_misa m
           where (m.trang_thai = 'da_tao' or m.trang_thai = 'dang_tao' and m.created_at < now() - interval '10 minutes' or p_ids is not null and m.trang_thai = 'dang_tao')
             and (p_ids is null or m.invoice_id = any(p_ids))
           order by m.synced_at nulls first limit least(coalesce(p_limit, 500), 2000)) m);
end $$;
grant execute on function public.out_misa_sync_list(uuid[], int) to authenticated;

-- Áp dụng "đã ký" (dùng chung cho dò tự động) — như out_mark_signed nhưng không cần là kế toán
create or replace function app.out_sign_apply(p_id uuid, p_ma text, p_so_hd text) returns void
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; m text := upper(regexp_replace(coalesce(p_ma, ''), '[[:space:]]+', '', 'g'));
begin
  select * into v from public.out_invoices where id = p_id for update;
  if v.id is null or v.status in ('huy') then return; end if;
  if exists(select 1 from public.out_invoices where upper(ma_tra_cuu) = m and id <> p_id) then m := null; end if;
  update public.out_invoices set ma_tra_cuu = coalesce(nullif(m, ''), ma_tra_cuu), so_hd = coalesce(nullif(btrim(p_so_hd), ''), so_hd),
    status = case when nullif(m, '') is not null or ma_tra_cuu is not null then 'da_ky' else status end, ngay_hd = coalesce(ngay_hd, app.vn_today()),
    status_at = case when status <> 'da_ky' and (nullif(m, '') is not null or ma_tra_cuu is not null) then now() else status_at end, updated_at = now()
  where id = p_id;
  insert into public.out_events(invoice_id, action, note, data)
  values (p_id, 'status', 'MISA đã phát hành HĐ số ' || coalesce(p_so_hd, '?') || coalesce(' · mã tra cứu ' || nullif(m, ''), ' — chưa lấy được mã tra cứu') || ' (tự đối soát)',
          jsonb_build_object('from', v.status, 'to', case when nullif(m, '') is not null then 'da_ky' else v.status end, 'ma_tra_cuu', m, 'so_hd', p_so_hd, 'auto', true));
  if nullif(m, '') is not null and v.status <> 'da_ky' then
    perform app.notify(v.sale_id, 'acc', 'Đã ký HĐ: ' || v.code, coalesce(v.buyer_name, '') || ' — mã tra cứu ' || m || '. Bấm để xem HĐ.', '#/hd?inv=' || v.id);
  end if;
  if nullif(m, '') is null then
    perform app.notify_roles(array['ke_toan'], 'acc', 'MISA đã phát hành HĐ ' || coalesce(p_so_hd, '') || ' — nhập mã tra cứu: ' || v.code, coalesce(v.buyer_name, ''), '#/out?inv=' || v.id);
  end if;
  if v.status <> 'xac_nhan_ky' and v.status <> 'da_ky' then
    perform app.notify_roles(array['ke_toan'], 'acc', '⚠ HĐ ' || coalesce(p_so_hd, '') || ' phát hành khi sale chưa chốt: ' || v.code, coalesce(v.buyer_name, ''), '#/out?inv=' || v.id);
  end if;
end $$;
revoke all on function app.out_sign_apply(uuid, text, text) from public, anon;

-- Kết quả dò MISA (getlist). p_rows: [{hd_id, found, inv_no, ma_tra_cuu, misa_tong_tt, misa_tien_thue}]
create or replace function public.out_misa_sync_result(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; h public.out_misa; v public.out_invoices; n_pub int := 0; n_del int := 0; n_ok int := 0; so text; ma text; cfg jsonb;
begin
  if not (app.is_acc() or app.is_service()) then raise exception 'Chỉ Kế toán / Admin'; end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    select * into h from public.out_misa where id = (r->>'hd_id')::uuid for update;
    if h.id is null or h.trang_thai not in ('dang_tao','da_tao') then continue; end if;
    select * into v from public.out_invoices where id = h.invoice_id;
    so := nullif(btrim(r->>'inv_no'), ''); ma := nullif(upper(regexp_replace(coalesce(r->>'ma_tra_cuu', ''), '[[:space:]]+', '', 'g')), '');
    if ma is not null and ma !~ '^[A-Z0-9_-]{6,30}$' then ma := null; end if;
    if coalesce((r->>'found')::boolean, false) then
      if so is not null and so ~ '[0-9]' and so !~* 'chưa' then
        update public.out_misa set trang_thai = 'da_phat_hanh', so_hd = so, ma_tra_cuu = ma, phat_hanh_at = now(), synced_at = now(), updated_at = now() where id = h.id;
        if h.invoice_version >= v.version and v.status <> 'huy' then
          perform app.out_sign_apply(v.id, ma, so);
        else
          perform app.notify_roles(array['ke_toan','admin'], 'acc', '⚠ MISA phát hành NHÁP CŨ lần ' || h.lan || ' (HĐ ' || so || '): ' || v.code,
            'Phiếu đã ' || case when v.status = 'huy' then 'hủy' else 'sửa sau nháp này' end || ' — kiểm tra, xử lý điều chỉnh/thay thế trên MISA', '#/out?inv=' || v.id);
          insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', '⚠ MISA phát hành nháp cũ lần ' || h.lan || ', HĐ ' || so, jsonb_build_object('ref_id', h.ref_id, 'so_hd', so));
        end if;
        n_pub := n_pub + 1;
      else
        if h.trang_thai = 'dang_tao' then
          perform public.out_misa_result(jsonb_build_array(jsonb_build_object('hd_id', h.id, 'ok', true, 'misa_tong_tt', r->'misa_tong_tt', 'misa_tien_thue', r->'misa_tien_thue')));
        else
          update public.out_misa set synced_at = now(), misa_tong_tt = coalesce(nullif(r->>'misa_tong_tt', '')::numeric, misa_tong_tt) where id = h.id;
        end if;
        n_ok := n_ok + 1;
      end if;
    else
      if h.trang_thai = 'dang_tao' then
        update public.out_misa set trang_thai = 'loi', loi_ma = 'KhongCoTrenMISA', loi_text = 'Không có trên MISA (gửi chưa tới) — bấm tạo lại', synced_at = now(), updated_at = now() where id = h.id;
      else
        update public.out_misa set trang_thai = 'da_xoa', deleted_at = now(), synced_at = now(), loi_text = 'Không còn trên MISA (đã bị xóa trên web MISA)', updated_at = now() where id = h.id;
        insert into public.out_events(invoice_id, action, note, data) values (v.id, 'misa', 'Nháp MISA lần ' || h.lan || ' không còn trên MISA (xóa trên web)', jsonb_build_object('ref_id', h.ref_id));
        perform app.notify_roles(array['ke_toan'], 'acc', 'Nháp MISA bị xóa trên web MISA: ' || v.code, coalesce(v.buyer_name, '') || ' — tạo lại nếu cần', '#/out?inv=' || v.id);
        n_del := n_del + 1;
      end if;
    end if;
  end loop;
  select value into cfg from public.settings where key = 'accounting';
  update public.settings set value = jsonb_set(value, '{misa}', coalesce(value->'misa', '{}') || jsonb_build_object('last_sync_at', now(), 'last_sync_pub', n_pub))
   where key = 'accounting';
  return jsonb_build_object('phat_hanh', n_pub, 'con_nhap', n_ok, 'bi_xoa', n_del);
end $$;
grant execute on function public.out_misa_sync_result(jsonb) to authenticated;

-- ---------- Hàm chỉ cho máy chủ (service_role) ----------
create or replace function public.misa_token_get() returns jsonb language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('token', token, 'got_at', got_at) from app.misa_token where id = 1
$$;
create or replace function public.misa_token_put(p_token text) returns void language sql security definer set search_path = public, app as $$
  insert into app.misa_token(id, token, got_at) values (1, p_token, now()) on conflict (id) do update set token = excluded.token, got_at = excluded.got_at
$$;
create or replace function public.misa_cron_ok(p_key text) returns boolean language sql stable security definer set search_path = public, app as $$
  select coalesce(p_key, '') <> '' and exists(select 1 from app.secrets where key = 'misa_cron_key' and value = p_key)
$$;
revoke all on function public.misa_token_get() from public, anon, authenticated;
revoke all on function public.misa_token_put(text) from public, anon, authenticated;
revoke all on function public.misa_cron_ok(text) from public, anon, authenticated;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'service_role') then
    grant select on public.out_misa to service_role;
    grant execute on function public.misa_token_get() to service_role;
    grant execute on function public.misa_token_put(text) to service_role;
    grant execute on function public.misa_cron_ok(text) to service_role;
    grant execute on function public.out_misa_result(jsonb) to service_role;
    grant execute on function public.out_misa_sync_list(uuid[], int) to service_role;
    grant execute on function public.out_misa_sync_result(jsonb) to service_role;
  end if;
end $$;

-- ---------- Tự dò MISA 15 phút/lần (7:00–21:00), chỉ khi đã bật MISA ----------
insert into app.secrets(key, value) values ('misa_cron_key', encode(gen_random_bytes(24), 'hex')) on conflict (key) do nothing;
create or replace function app.job_misa_sync() returns void language plpgsql security definer set search_path = public, app, extensions as $$
declare m jsonb := app.misa_cfg(); v_url text := replace(coalesce(app.setting('push')->>'url', ''), '/functions/v1/push', '/functions/v1/misa'); h int := extract(hour from now() at time zone 'Asia/Ho_Chi_Minh');
begin
  if not coalesce((m->>'enabled')::boolean, false) or not coalesce((m->>'auto_sync')::boolean, true) or v_url not like '%/functions/v1/misa' or h < 7 or h > 21 then return; end if;
  if not exists(select 1 from public.out_misa where trang_thai in ('dang_tao','da_tao')) then return; end if;
  if not exists(select 1 from pg_extension where extname = 'pg_net') and not exists(select 1 from pg_namespace where nspname = 'net') then return; end if;
  begin
    execute 'select net.http_post(url := $1, body := $2, headers := $3)'
      using v_url, jsonb_build_object('action', 'sync', 'cron', true),
            jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', (select value from app.secrets where key = 'misa_cron_key'));
  exception when others then null; end;
end $$;
select cron.schedule('nt_misa_sync', '*/15 * * * *', 'select app.job_misa_sync()');

-- ---------- Không hủy phiếu khi còn nháp sống trên MISA ----------
create or replace function app.trg_out_misa_guard() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'huy' and old.status <> 'huy' and exists(select 1 from public.out_misa m where m.invoice_id = new.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh')) then
    raise exception 'Phiếu % đang có nháp trên MISA (tạo bằng API) — kế toán xóa nháp MISA trước khi hủy', new.code;
  end if;
  return new;
end $$;
drop trigger if exists out_misa_guard on public.out_invoices;
create trigger out_misa_guard before update of status on public.out_invoices for each row execute function app.trg_out_misa_guard();

-- ---------- Danh sách phiếu: thêm tình trạng MISA (API), bộ lọc + khoảng ngày ----------
create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_flag text := nullif(p->>'flag', ''); v_next text := nullif(p->>'next', ''); v_sort text := coalesce(nullif(p->>'sort', ''), 'at'); v_dir text := coalesce(nullif(p->>'dir', ''), 'desc'); v_sua int; v_misa int; v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_scope(); v_hd text := nullif(ltrim(btrim(p->>'hd'), '0'), '');
        v_from date := nullif(p->>'from', '')::date; v_to date := nullif(p->>'to', '')::date; mf jsonb;
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
       and (v_from is null or i.created_at >= v_from) and (v_to is null or i.created_at < v_to + 1)
       and (v_hd is null or exists(select 1 from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = i.id and app.hd_of(t.so_hd_vao, t.ma_hang) = v_hd)) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  select count(*) filter (where i.sua_sau_nhap), count(*) filter (where i.misa_at is null),
         jsonb_build_object(
           'api_san_sang', count(*) filter (where i.misa_at is null and mm.id is null),
           'api_cu', count(*) filter (where mm.trang_thai = 'da_tao' and mm.invoice_version < i.version),
           'api_loi', count(*) filter (where ml.trang_thai = 'loi' or mm.khop is false),
           'api_co', count(*) filter (where mm.trang_thai in ('dang_tao','da_tao') and mm.invoice_version >= i.version),
           'tay', count(*) filter (where i.misa_at is not null and mm.id is null))
    into v_sua, v_misa, mf
    from public.out_invoices i
    left join lateral (select m.id, m.trang_thai, m.invoice_version, m.khop from public.out_misa m where m.invoice_id = i.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh') limit 1) mm on true
    left join lateral (select m.trang_thai from public.out_misa m where m.invoice_id = i.id order by m.lan desc limit 1) ml on true
   where i.status = 'cho_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale);
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa, 'mf', mf); end if;
  with base as materialized (select v.*, ml.misa from public.out_invoices v
                               left join lateral (select jsonb_build_object('hd_id', m.id, 'lan', m.lan, 'st', m.trang_thai, 'khop', m.khop, 'cu', m.invoice_version < v.version and m.trang_thai = 'da_tao',
                                   'so_hd', m.so_hd, 'loi', left(m.loi_text, 300), 'pdf', m.file_id is not null, 'at', m.updated_at) misa
                                   from public.out_misa m where m.invoice_id = v.id order by m.lan desc limit 1) ml on true
                              where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_from is null or v.created_at >= v_from) and (v_to is null or v.created_at < v_to + 1)
                               and (v_hd is null or exists(select 1 from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id = v.id and app.hd_of(t.so_hd_vao, t.ma_hang) = v_hd))
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)
                               and (v_flag is null or v_flag = 'sua' and v.sua_sau_nhap or v_flag = 'misa_chua' and v.misa_at is null
                                    or v_flag = 'api_san_sang' and v.misa_at is null and not exists(select 1 from public.out_misa m where m.invoice_id = v.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh'))
                                    or v_flag = 'api_cu' and exists(select 1 from public.out_misa m where m.invoice_id = v.id and m.trang_thai = 'da_tao' and m.invoice_version < v.version)
                                    or v_flag = 'api_loi' and (ml.misa->>'st' = 'loi' or ml.misa->>'khop' = 'false')
                                    or v_flag = 'api_co' and exists(select 1 from public.out_misa m where m.invoice_id = v.id and m.trang_thai in ('dang_tao','da_tao') and m.invoice_version >= v.version)
                                    or v_flag = 'tay' and v.misa_at is not null and not exists(select 1 from public.out_misa m where m.invoice_id = v.id and m.trang_thai in ('dang_tao','da_tao','da_phat_hanh')))),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim,
               string_agg(distinct t.md, ', ') mds, bool_or(coalesce(l.vat, t.vat) >= 0.095) vat10,
               string_agg(distinct t.ma_hang, ', ') mas, string_agg(distinct app.hd_of(t.so_hd_vao, t.ma_hang), ', ') hds
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia, a.mds, coalesce(a.vat10, false) vat10, a.mas, a.hds,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where (v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%')
           and (v_next is null or b.status = 'da_nhap' and fn.version is not null and (v_next = 'chua_gui' and fn.sent_at is null or v_next = 'cho_khach' and fn.sent_at is not null))),
  o as (select f.*, row_number() over (order by
          case when v_dir = 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end asc nulls last,
          case when v_dir <> 'asc' then case v_sort when 'code' then f.code when 'buyer' then lower(coalesce(f.buyer_name, f.buyer_info)) when 'status' then f.status when 'md' then f.mds when 'sale' then f.sale_id::text end end desc nulls last,
          case when v_sort = 'tien' and v_dir = 'asc' then f.tien_hang + f.tien_thue end asc nulls last,
          case when v_sort = 'tien' and v_dir <> 'asc' then f.tien_hang + f.tien_thue end desc nulls last,
          case when v_dir = 'asc' and v_sort = 'at' then f.status_at end asc, f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa, 'mf', mf);
end $$;

reset search_path;
