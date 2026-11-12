-- =====================================================================
-- 0052 · Bản 44 (12/11/2026) — Khung giá riêng theo khách
--  Anh (Admin / BGĐ) đặt mức tối thiểu riêng cho từng khách: phí ủy thác %, phí dịch vụ %, cước / m³.
--  Báo giá của khách đó kiểm theo mức riêng (CẤM / Cần duyệt) thay mức sàn chung → trong khung riêng thì sale gửi luôn, không cần duyệt.
--  Để trống ô nào thì ô đó theo mức chung. Tỷ giá vẫn theo mức chung.
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 44');

create table if not exists public.customer_price_floor(
  customer_id uuid primary key references public.customers(id) on delete cascade,
  phi_ut_min numeric(7,3) check (phi_ut_min is null or phi_ut_min between 0 and 100),
  phi_dv_min numeric(7,3) check (phi_dv_min is null or phi_dv_min between 0 and 100),
  cuoc_khoi_min numeric(14,0) check (cuoc_khoi_min is null or cuoc_khoi_min >= 0),
  note text,
  updated_by uuid references public.profiles(id), updated_at timestamptz not null default now()
);
alter table public.customer_price_floor enable row level security;
drop policy if exists cpf_read on public.customer_price_floor;
create policy cpf_read on public.customer_price_floor for select to authenticated using (app.is_active());
revoke insert, update, delete on public.customer_price_floor from anon, authenticated;
grant select on public.customer_price_floor to authenticated;

-- Đặt / xóa khung giá riêng (chỉ Admin / BGĐ). Cả 3 ô trống → xóa (theo mức chung)
create or replace function public.customer_price_floor_set(p_customer uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare ut numeric := nullif(p->>'phi_ut_min', '')::numeric; dv numeric := nullif(p->>'phi_dv_min', '')::numeric; ck numeric := nullif(p->>'cuoc_khoi_min', '')::numeric;
begin
  if not app.has_role('admin', 'bgd') then raise exception 'Chỉ Admin / BGĐ đặt khung giá riêng'; end if;
  if not exists(select 1 from public.customers where id = p_customer) then raise exception 'Không tìm thấy khách'; end if;
  perform app.log('PRICE_FLOOR', 'customer_price_floor', p_customer::text, jsonb_build_object('phi_ut_min', ut, 'phi_dv_min', dv, 'cuoc_khoi_min', ck, 'note', p->>'note'));
  if ut is null and dv is null and ck is null then delete from public.customer_price_floor where customer_id = p_customer; return; end if;
  insert into public.customer_price_floor(customer_id, phi_ut_min, phi_dv_min, cuoc_khoi_min, note, updated_by, updated_at)
  values (p_customer, ut, dv, ck, nullif(btrim(p->>'note'), ''), auth.uid(), now())
  on conflict (customer_id) do update set phi_ut_min = excluded.phi_ut_min, phi_dv_min = excluded.phi_dv_min, cuoc_khoi_min = excluded.cuoc_khoi_min,
    note = excluded.note, updated_by = auth.uid(), updated_at = now();
end $$;
grant execute on function public.customer_price_floor_set(uuid, jsonb) to authenticated;

create or replace function app.quote_check_kh(p_header jsonb, p_lines jsonb, p_customer uuid)
returns text[] language plpgsql stable security definer set search_path = public, app as $$
declare
  v text[] := '{}';
  rate numeric := (p_header->>'tyGia')::numeric;
  dv numeric := coalesce((p_header->>'phiDVPct')::numeric, 0);
  dv_fixed numeric := coalesce((p_header->>'phiDVCoDinh')::numeric, 0);
  ut numeric := coalesce((p_header->>'phiUTPct')::numeric, 0);
  kg numeric := coalesce((p_header->>'soKg')::numeric, 0);
  m3 numeric := coalesce((p_header->>'soKhoi')::numeric, 0);
  dg_kg numeric := coalesce((p_header->>'donGiaKg')::numeric, 0);
  dg_m3 numeric := coalesce((p_header->>'donGiaKhoi')::numeric, 0);
  mode text := coalesce(p_header->>'cheDoXuat', 'du');
  pct numeric := coalesce((p_header->>'pctXuat')::numeric, 100);
  kho text := coalesce(p_header->>'khoNhan', 'HN');
  cfg jsonb := coalesce(app.setting('quote_defaults'), '{}');
  rate_von numeric := coalesce(app.current_rate('von'), (cfg->>'tyGiaVon')::numeric, 3955);
  rate_san numeric := coalesce(app.current_rate('san'), (cfg->>'tyGiaSan')::numeric, 4015);
  ut_min numeric := coalesce((cfg->>'phiUTSan')::numeric, 0.8);
  dv_min numeric := coalesce((cfg->>'phiDVSan')::numeric, 1.2);
  xuat_min numeric := coalesce((cfg->>'tyLeXuatMin')::numeric, 70);
  von_m3 numeric := coalesce((cfg->'giaVonKhoi'->>kho)::numeric, (cfg->>'giaVonKhoiHN')::numeric, 800000);
  tien_hang numeric;
  cuoc numeric;
  kh public.customer_price_floor;
begin
  -- Bản 44: khung giá riêng của khách (anh đặt) thay mức sàn chung
  select * into kh from public.customer_price_floor where customer_id = p_customer;
  if kh.customer_id is not null then
    ut_min := coalesce(kh.phi_ut_min, ut_min); dv_min := coalesce(kh.phi_dv_min, dv_min); von_m3 := coalesce(kh.cuoc_khoi_min, von_m3);
  end if;
  if rate is null or rate <= 0 then raise exception 'Thiếu tỷ giá'; end if;
  if jsonb_array_length(coalesce(p_lines, '[]')) = 0 then raise exception 'Báo giá phải có ít nhất 1 dòng hàng'; end if;
  -- CẤM
  if rate < rate_von then raise exception 'CẤM: tỷ giá % thấp hơn tỷ giá vốn %', rate, rate_von; end if;
  if ut < ut_min then raise exception 'CẤM: phí ủy thác % thấp hơn sàn %', ut, ut_min; end if;
  -- DUYỆT
  select sum((l->>'qty')::numeric * coalesce((l->>'unit_price_cny')::numeric,0)) * rate into tien_hang from jsonb_array_elements(p_lines) l;
  if rate < rate_san then v := v || ('Tỷ giá ' || rate || ' < ' || rate_san); end if;
  if dv_fixed > 0 then
    if dv_fixed < round(tien_hang * dv_min / 100) then v := v || ('Phí dịch vụ cố định < ' || dv_min || '% tiền hàng'); end if;
  elsif dv < dv_min then v := v || ('Phí dịch vụ ' || dv || '% < ' || dv_min || '%'); end if;
  cuoc := greatest(kg * dg_kg, m3 * dg_m3);
  if m3 > 0 and cuoc / m3 < von_m3 then v := v || ('Cước ' || round(cuoc/m3) || 'đ/m³ < giá vốn ' || von_m3); end if;
  if mode = 'thap' and pct < xuat_min then v := v || ('Xuất thấp ' || pct || '% < ' || xuat_min || '%'); end if;
  return v;
end $$;

-- giữ hàm cũ (gọi không có khách → mức chung)
create or replace function app.quote_check(p_header jsonb, p_lines jsonb) returns text[]
language sql stable security definer set search_path = public, app as $$ select app.quote_check_kh(p_header, p_lines, null) $$;

create or replace function public.save_quote(p_id uuid, p_customer uuid, p_header jsonb, p_lines jsonb, p_totals jsonb, p_note text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare q record; v_id uuid; v_viol text[]; v_hash text; v_header jsonb; v_owner uuid;
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  perform app.assert_customer_open(p_customer);
  -- chụp lại giá vốn tại thời điểm lập
  v_header := p_header || jsonb_build_object(
    'tyGiaVon', coalesce(app.current_rate('von'), 3955),
    'tyGiaSan', coalesce(app.current_rate('san'), 4015));
  v_viol := app.quote_check_kh(v_header, p_lines, p_customer);
  v_hash := app.quote_hash(p_header, p_lines);
  select owner_id into v_owner from public.customers where id = p_customer;
  if p_id is null then
    insert into public.quotations(code, sale_id, customer_id, header, totals, total_after_vat, est_profit, violations, price_hash, note)
    values ('BG' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'YYMM') || '-' || lpad(nextval('public.quote_code_seq')::text, 4, '0'),
            case when app.is_support_of(v_owner) and v_owner <> auth.uid() then v_owner else auth.uid() end,
            p_customer, v_header, coalesce(p_totals,'{}'), coalesce((p_totals->>'tongSauVAT')::numeric,0),
            coalesce((p_totals->>'lnUocTinh')::numeric,0), v_viol, v_hash, p_note)
    returning id into v_id;
    update public.quotations set root_id = id where id = v_id;
  else
    select * into q from public.quotations where id = p_id for update;
    if q.id is null then raise exception 'Không tìm thấy báo giá'; end if;
    if not (q.sale_id = auth.uid() or app.is_admin() or app.is_support_of(q.sale_id)) then raise exception 'Chỉ người lập (hoặc CSKH hỗ trợ) được sửa báo giá'; end if;
    if q.status in ('da_chot','tu_choi','het_han','da_thay_the') then raise exception 'Báo giá đã khóa — dùng Nhân bản'; end if;
    if q.status in ('da_gui','can_nhac') then
      insert into public.quotations(code, version, root_id, customer_id, sale_id, header, totals, total_after_vat, est_profit, violations, price_hash, note)
      values (q.code, (select max(version)+1 from public.quotations where root_id = q.root_id), q.root_id, p_customer, q.sale_id,
              v_header, coalesce(p_totals,'{}'), coalesce((p_totals->>'tongSauVAT')::numeric,0), coalesce((p_totals->>'lnUocTinh')::numeric,0), v_viol, v_hash, p_note)
      returning id into v_id;
      update public.quotations set status = 'da_thay_the', superseded_by = v_id, updated_at = now() where id = q.id;
    else
      v_id := q.id;
      update public.quotations set customer_id = p_customer, header = v_header, totals = coalesce(p_totals,'{}'),
        total_after_vat = coalesce((p_totals->>'tongSauVAT')::numeric,0), est_profit = coalesce((p_totals->>'lnUocTinh')::numeric,0),
        violations = v_viol, price_hash = v_hash, note = p_note, status = 'nhap', updated_at = now()
      where id = q.id;
    end if;
  end if;
  delete from public.quotation_lines where quotation_id = v_id;
  insert into public.quotation_lines(quotation_id, line_no, name, spec, hs_code, unit, qty, unit_price_cny, duty_pct, vat_pct, freight_pct, manual_price, computed, image)
  select v_id, ord, l->>'name', l->>'spec', l->>'hs_code', l->>'unit', (l->>'qty')::numeric, coalesce((l->>'unit_price_cny')::numeric,0),
         coalesce((l->>'duty_pct')::numeric,0), (l->>'vat_pct')::numeric, (l->>'freight_pct')::numeric, (l->>'manual_price')::numeric, coalesce(l->'computed','{}'),
         nullif(btrim(l->>'image'), '')
  from jsonb_array_elements(p_lines) with ordinality t(l, ord)
  where coalesce(btrim(l->>'name'),'') <> '' and coalesce((l->>'qty')::numeric, 0) > 0;
  return v_id;
end $$;

reset search_path;
