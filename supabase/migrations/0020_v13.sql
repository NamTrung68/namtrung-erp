-- =====================================================================
-- 0020 · Bản 13: sale xem toàn bộ dòng của mình; dòng chưa có chủ cho mọi sale nhận; kế toán chốt kèm giá khách/MD;
--        sale báo "Đơn APT xuất thẳng"; gán/ghép dòng HĐ chưa thuộc xe; mã KH hệ thống → khách ERP
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 13');

create or replace function app.norm_md(p text) returns text language sql immutable as $$
  select case when substring(coalesce(p, '') from '(\d+)') is null then null else 'MD' || (substring(p from '(\d+)'))::bigint end
$$;

alter table public.acc_lines add column if not exists claim_md text;
alter table public.acc_lines add column if not exists claim_gia numeric;
alter table public.acc_lines add column if not exists claimed_by uuid references public.profiles(id);
alter table public.acc_lines add column if not exists claimed_at timestamptz;
alter table public.acc_lines add column if not exists customer_id uuid references public.customers(id) on delete set null;
alter table public.acc_lines drop constraint if exists acc_lines_reply_check;
alter table public.acc_lines add constraint acc_lines_reply_check check (reply in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet','xuat_thang'));
create index if not exists acc_lines_unowned on public.acc_lines(truck_id) where sale_id is null;

-- Mã khách trên file khai báo (NT93844 hoặc username) → khách hàng ERP
create or replace function app.acc_line_customer() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(btrim(new.ma_kh), '') = '' then new.customer_id := null;
  elsif tg_op = 'INSERT' or new.ma_kh is distinct from old.ma_kh or new.customer_id is null then
    select id into new.customer_id from public.customers
     where deleted_at is null and (upper(sys_code) = upper(btrim(new.ma_kh)) or lower(sys_username) = lower(btrim(new.ma_kh)) or upper(code) = upper(btrim(new.ma_kh))) limit 1;
  end if;
  return new;
end $$;
drop trigger if exists acc_line_customer on public.acc_lines;
create trigger acc_line_customer before insert or update of ma_kh on public.acc_lines for each row execute function app.acc_line_customer();

-- Sale: thấy mọi dòng của mình; mọi sale thấy dòng chưa có sale phụ trách để nhận
drop policy if exists acc_lines_read on public.acc_lines;
create policy acc_lines_read on public.acc_lines for select to authenticated
  using (app.is_acc() or (not is_test and (app.in_tree(sale_id) or (app.is_acc_approver() and status = 'pending_approval')
         or (sale_id is null and luong in ('A','B') and app.has_role('sale','tn_kd','tp_kd')))));

drop policy if exists acc_trucks_read on public.acc_trucks;
create policy acc_trucks_read on public.acc_trucks for select to authenticated using (app.is_acc() or app.is_acc_approver()
  or exists(select 1 from public.acc_lines l where l.truck_id = acc_trucks.id and not l.is_test and (app.in_tree(l.sale_id) or (l.sale_id is null and l.luong in ('A','B') and app.has_role('sale','tn_kd','tp_kd')))));

-- Sale trả lời (thêm MD + giá khách khi đã sửa hệ thống; "Đơn APT xuất thẳng" đổi luồng ngay)
drop function if exists public.acc_line_reply(uuid, text, numeric, text);
create or replace function public.acc_line_reply(p_id uuid, p_reply text, p_price numeric default null, p_note text default null, p_md text default null, p_gia_khach numeric default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; v_status text; v_md text := nullif(app.norm_md(p_md), '');
begin
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if not (app.is_acc() or app.in_tree(l.sale_id)) then raise exception 'Dòng này không thuộc khách của bạn'; end if;
  if l.status not in ('blocked','replied') then raise exception 'Dòng không ở trạng thái chờ sale'; end if;
  if p_reply not in ('da_sua_ht','de_xuat_gia','chuyen_xe_sau','xin_duyet','xuat_thang') then raise exception 'Lựa chọn không hợp lệ'; end if;
  if p_reply = 'de_xuat_gia' and coalesce(p_price, 0) <= 0 then raise exception 'Nhập giá đề xuất'; end if;
  if p_reply = 'xin_duyet' and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do xin duyệt ngoại lệ'; end if;
  if p_reply = 'da_sua_ht' and l.md is null and l.luong in ('A','B') and v_md is null then raise exception 'Nhập mã đơn (MD) đã tạo trên hệ thống'; end if;
  if p_reply = 'da_sua_ht' and coalesce(l.gia_khach, 0) = 0 and l.luong in ('A','B') and coalesce(p_gia_khach, 0) <= 0 then raise exception 'Nhập giá khách (giá xuất HĐ cho khách)'; end if;
  if p_reply = 'xuat_thang' then
    update public.acc_trucks set xt_keys = array(select distinct x from unnest(xt_keys || l.line_key) x),
      md_xuat_thang = case when l.md is null then md_xuat_thang else array(select distinct x from unnest(md_xuat_thang || l.md) x) end where id = l.truck_id;
    update public.acc_lines set reply = p_reply, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(), luong = 'C', status = 'info', due_at = null,
      phan_hoi = case when apt_stt is not null then 'XUẤT THẲNG' end, issues = '{}', notes = array_prepend('Sale báo APT xuất thẳng.', notes), updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'reply_xuat_thang', p_note);
    return;
  end if;
  v_status := case when p_reply = 'xin_duyet' then 'pending_approval' else 'replied' end;
  update public.acc_lines set reply = p_reply, reply_price = p_price, reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(), status = v_status,
    claim_md = coalesce(v_md, claim_md), claim_gia = coalesce(nullif(p_gia_khach, 0), claim_gia), updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'reply', p_note, jsonb_build_object('reply', p_reply, 'price', p_price, 'md', v_md, 'gia_khach', p_gia_khach));
  if p_reply = 'xin_duyet' then
    perform app.notify(x::uuid, 'acc', 'Xin duyệt ngoại lệ HĐ: ' || coalesce(l.md, 'dòng không có đơn'), left(coalesce(l.ten_apt, l.ten_ht, ''), 80) || ' — ' || p_note, '#/acc/approve')
      from jsonb_array_elements_text(coalesce(app.setting('accounting')->'approver_ids', '[]')) x;
  end if;
end $$;
grant execute on function public.acc_line_reply(uuid, text, numeric, text, text, numeric) to authenticated;


-- Nhận dòng chưa có chủ (sale) / gán cho sale (kế toán, admin)
create or replace function public.acc_line_claim(p_id uuid, p_md text, p_gia_khach numeric, p_note text default null, p_sale uuid default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; v_sale uuid := coalesce(p_sale, auth.uid()); v_md text := app.norm_md(p_md);
begin
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if p_sale is not null and not app.is_acc() then raise exception 'Chỉ Kế toán/Admin được gán cho sale khác'; end if;
  if not app.is_acc() then
    if not app.has_role('sale','tn_kd','tp_kd') then raise exception 'Chỉ sale được nhận dòng'; end if;
    if l.is_test then raise exception 'Xe nạp thử'; end if;
    if l.sale_id is not null then raise exception 'Dòng đã có sale phụ trách — báo kế toán nếu nhầm'; end if;
  end if;
  if v_md is null and l.md is null then raise exception 'Nhập mã đơn (MD)'; end if;
  if coalesce(p_gia_khach, 0) <= 0 and coalesce(l.gia_khach, 0) = 0 then raise exception 'Nhập giá khách'; end if;
  update public.acc_lines set sale_id = v_sale, claimed_by = auth.uid(), claimed_at = now(), claim_md = coalesce(v_md, claim_md), claim_gia = coalesce(nullif(p_gia_khach, 0), claim_gia),
    reply = 'da_sua_ht', reply_note = nullif(btrim(p_note), ''), replied_by = auth.uid(), replied_at = now(),
    status = case when status in ('blocked','replied') then 'replied' else status end, due_at = null, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, case when p_sale is null then 'claim' else 'assign' end, p_note,
    jsonb_build_object('md', v_md, 'gia_khach', p_gia_khach, 'sale', v_sale));
  if p_sale is not null and p_sale <> auth.uid() then perform app.notify(p_sale, 'acc', 'Kế toán gán cho bạn 1 dòng HĐ APT', coalesce(v_md, '') || ' · ' || left(coalesce(l.ten_apt, ''), 80), '#/acc/mine'); end if;
end $$;
grant execute on function public.acc_line_claim(uuid, text, numeric, text, uuid) to authenticated;

-- Kế toán chốt / trả lại: chốt phải có giá khách (điền chuẩn theo hệ thống), có thể bổ sung MD
drop function if exists public.acc_line_set(uuid, text, text);
create or replace function public.acc_line_set(p_id uuid, p_status text, p_note text default null, p_gia_khach numeric default null, p_md text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines; c jsonb := coalesce(app.setting('accounting'), '{}'); v_gk numeric; v_md text; v_ga numeric; v_b numeric; v_de numeric; v_ph text;
        tgt numeric := coalesce((c->>'bien_muc_tieu')::numeric, 0.03); hi numeric := coalesce((c->>'bien_nt_max')::numeric, 0.04);
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if p_status not in ('ok','blocked') then raise exception 'Trạng thái không hợp lệ'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  if p_status = 'blocked' then
    update public.acc_lines set status = 'blocked', due_at = now() + interval '24 hours', phan_hoi = 'CHỜ SALE — chưa xuất', updated_at = now() where id = p_id;
    insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, 'set_blocked', p_note);
    perform app.notify(l.sale_id, 'acc', 'Kế toán trả lại dòng HĐ: ' || coalesce(l.md, ''), p_note, '#/acc/mine');
    return;
  end if;
  v_gk := coalesce(nullif(p_gia_khach, 0), nullif(l.gia_khach, 0), l.claim_gia);
  v_md := coalesce(app.norm_md(p_md), l.md, l.claim_md);
  if l.luong in ('A','B') and coalesce(v_gk, 0) <= 0 then raise exception 'Nhập giá khách để chốt'; end if;
  v_ga := coalesce(l.gia_note, l.gia_nhap); v_b := case when v_gk > 0 and v_ga > 0 then v_gk / v_ga - 1 end;
  if l.reply = 'de_xuat_gia' and l.reply_price > 0 then v_de := l.reply_price;
  elsif v_b is not null and v_b > hi + 0.001 then v_de := round(v_gk / (1 + tgt)); end if;
  v_ph := case when l.apt_stt is null then null when l.luong = 'C' then 'XUẤT THẲNG'
               when v_de is not null then 'XUẤT GIÁ ' || round(v_de)::bigint::text
               when l.gia_note is not null and abs(l.gia_note - coalesce(l.gia_nhap, 0)) > 0.5 then 'XUẤT GIÁ ' || round(l.gia_note)::bigint::text else 'CHỐT' end;
  update public.acc_lines set status = 'ok', due_at = null, gia_khach = v_gk, md = v_md, ma_dong = coalesce(ma_dong, v_md),
    gia_de_xuat = coalesce(v_de, gia_de_xuat), gia_ap_dung = coalesce(v_de, gia_note, gia_nhap),
    bien_nt = case when v_gk > 0 and coalesce(v_de, v_ga) > 0 then v_gk / coalesce(v_de, v_ga) - 1 end,
    tt_khach = case when v_gk > 0 then round(v_gk * coalesce(sl_tk, sl_apt, sl_ht, 0)) end, tt_apt = round(coalesce(v_de, v_ga, 0) * coalesce(sl_tk, sl_apt, sl_ht, 0)),
    phan_hoi = v_ph, issues = '{}', notes = array_prepend('Kế toán chốt' || coalesce(': ' || nullif(btrim(p_note), ''), '') || '.', notes), updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note, data) values (p_id, l.truck_id, 'set_ok', p_note, jsonb_build_object('gia_khach', v_gk, 'md', v_md));
  if l.inv_id is not null then perform app.acc_line_inv_refresh(p_id); end if;
end $$;
grant execute on function public.acc_line_set(uuid, text, text, numeric, text) to authenticated;

-- Ghép tay 1 dòng HĐ (chưa thuộc xe nào / ghép nhầm) vào dòng đối soát; p_line null = gỡ ghép
create or replace function public.acc_invoice_line_link(p_invline uuid, p_line uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare il public.acc_invoice_lines; l public.acc_lines; v_old uuid;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  select * into il from public.acc_invoice_lines where id = p_invline for update; if il.id is null then raise exception 'Không tìm thấy dòng HĐ'; end if;
  v_old := il.line_id;
  if p_line is not null then select * into l from public.acc_lines where id = p_line; if l.id is null then raise exception 'Không tìm thấy dòng đối soát'; end if; end if;
  update public.acc_invoice_lines set line_id = p_line, result = case when p_line is null then 'khong_thuoc_xe' else app.acc_judge(il.dg, l) end where id = p_invline;
  if v_old is not null then perform app.acc_line_inv_refresh(v_old); end if;
  if p_line is not null then perform app.acc_line_inv_refresh(p_line); insert into public.acc_events(line_id, truck_id, action, note) values (p_line, l.truck_id, 'link_invoice', il.hh); end if;
  perform app.acc_inv_stats_refresh(il.invoice_id);
end $$;
grant execute on function public.acc_invoice_line_link(uuid, uuid) to authenticated;

create or replace function public.acc_line_approve(p_id uuid, p_ok boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare l public.acc_lines;
begin
  if not app.is_acc_approver() then raise exception 'Bạn không có quyền duyệt mở chặn'; end if;
  select * into l from public.acc_lines where id = p_id for update;
  if l.id is null then raise exception 'Không tìm thấy dòng'; end if;
  if l.status not in ('pending_approval','blocked','replied') then raise exception 'Dòng không chờ duyệt'; end if;
  if not p_ok and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do từ chối'; end if;
  update public.acc_lines set status = case when p_ok then 'approved' else 'blocked' end, approved_by = auth.uid(), approved_at = now(), approve_note = nullif(btrim(p_note), ''),
    phan_hoi = case when p_ok then coalesce(case when l.reply_price > 0 then 'XUẤT GIÁ ' || round(l.reply_price)::bigint::text end, 'CHỐT (duyệt ngoại lệ)') else phan_hoi end,
    due_at = case when p_ok then null else now() + interval '24 hours' end, updated_at = now() where id = p_id;
  insert into public.acc_events(line_id, truck_id, action, note) values (p_id, l.truck_id, case when p_ok then 'approve' else 'reject' end, p_note);
  perform app.notify(l.sale_id, 'acc', case when p_ok then 'Đã duyệt mở chặn: ' else 'Từ chối mở chặn: ' end || coalesce(l.md, ''), p_note, '#/acc/mine');
end $$;


-- Đưa "XUẤT GIÁ" về dạng số liền (APT dán thẳng)
update public.acc_lines set phan_hoi = 'XUẤT GIÁ ' || replace(replace(substring(phan_hoi from 10), '.', ''), ',', '') where phan_hoi like 'XUẤT GIÁ %';
-- Gắn khách cho dòng đã có mã KH
update public.acc_lines set ma_kh = ma_kh where coalesce(ma_kh, '') <> '';

reset search_path;
