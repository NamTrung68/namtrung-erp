-- =====================================================================
-- 0039 · Bản 32 (06/11/2026): file xe lệch cột ID ĐƠN ↔ USERNAME, thiếu username khách
--  · Dòng đối soát đổi ĐƠN hoặc USERNAME (nạp lại file xe, kế toán điền username) → dòng sổ HĐ đầu vào theo ngay,
--    tìm lại khách (trước đây chỉ theo đơn/sale/giá, username cũ sai bị giữ lại mãi)
--  · Nạp lại file xe mà file thiếu username → giữ username đã có (trừ username trùng số đơn = lệch cột)
--  · acc_lines_set_kh: kế toán điền username cho dòng đối soát (màn nạp HĐ chính thức)
--  · out_items_fix_kh: sửa ID đơn / username dòng sẵn sàng xuất — kế toán, hoặc sale / CSKH / trưởng nhóm trong phạm vi
--  · Sửa dữ liệu cũ: dòng đối soát có mã khai báo MDxxxx-n mà ID đơn trống / khác đơn, username = chính số đơn
--    → lấy đơn theo mã khai báo, bỏ username sai (username đúng điền lại sau)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 32');

-- Dòng sổ đã lập phiếu (phiếu chưa hủy) → không tự đổi đơn/khách
create or replace function app.out_item_has_inv(p_id uuid) returns boolean language sql stable security definer set search_path = public, app as $$
  select exists(select 1 from public.out_invoice_lines l join public.out_invoices i on i.id = l.invoice_id where l.item_id = p_id and i.status <> 'huy')
$$;
-- Username là chính số đơn (2689 / MD2689 của đơn MD2689) → dấu hiệu lệch cột
create or replace function app.kh_la_don(p_kh text, p_md text) returns boolean language sql immutable as $$
  select coalesce(p_kh, '') <> '' and coalesce(p_md, '') <> '' and btrim(p_kh) ~* ('^(md)?\s*0*' || regexp_replace(p_md, '\D', '', 'g') || '$')
$$;

-- Dòng đối soát đổi MD / username / sale / giá khách / khách → dòng sổ đầu ra lấy theo (trừ dòng kế toán sửa tay)
create or replace function app.trg_acc_line_out() returns trigger language plpgsql security definer set search_path = public, app as $$
declare t record;
begin
  if new.is_test then return null; end if;
  -- Bản 32: đổi đơn hoặc username → dòng sổ nhận đơn + username mới, tìm lại khách (dòng đã lập phiếu thì giữ nguyên)
  if tg_op = 'UPDATE' and (old.md is distinct from new.md or old.ma_kh is distinct from new.ma_kh) then
    for t in select o.id, o.md, o.username from public.out_items o where o.acc_line_id = new.id and coalesce(o.match_src, '') <> 'tay' and not app.out_item_has_inv(o.id) loop
      update public.out_items set md = coalesce(new.md, md), username = nullif(new.ma_kh, ''), customer_id = new.customer_id, updated_at = now() where id = t.id;
      perform app.out_item_match(t.id);
      insert into public.out_events(item_id, action, data) values (t.id, 'doi_don_kh',
        jsonb_build_object('md', new.md, 'username', new.ma_kh, 'md_cu', t.md, 'username_cu', t.username));
    end loop;
  end if;
  update public.out_items set md = coalesce(new.md, md), sale_id = coalesce(new.sale_id, sale_id), gia_khach = coalesce(nullif(new.gia_khach, 0), gia_khach),
         customer_id = coalesce(new.customer_id, customer_id), updated_at = now()
   where acc_line_id = new.id and coalesce(match_src, '') <> 'tay'
     and (md is distinct from coalesce(new.md, md) or sale_id is distinct from coalesce(new.sale_id, sale_id) or gia_khach is distinct from coalesce(nullif(new.gia_khach, 0), gia_khach) or customer_id is distinct from coalesce(new.customer_id, customer_id));
  if new.md is not null then
    for t in select id from public.out_items where acc_line_id is null and md = new.md loop perform app.out_item_match(t.id); end loop;
  end if;
  return null;
end $$;
drop trigger if exists acc_line_out on public.acc_lines;
create trigger acc_line_out after insert or update of md, ma_kh, sale_id, gia_khach, customer_id on public.acc_lines for each row execute function app.trg_acc_line_out();

-- Nạp lại file xe: giữ username đã có khi file mới để trống (không giữ username sai = số đơn)
create or replace function app.acc_keep_manual(p_old public.acc_lines, p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare n public.acc_lines;
begin
  select * into n from public.acc_lines where id = p_id;
  -- sale/MD/giá khách đã nhận/gán/chốt tay mà file vẫn trống → giữ
  update public.acc_lines set
    sale_id = case when n.sale_id is null or n.sale_id = p_old.released_from then case when p_old.reply = 'nham' and p_old.reply_sub = 'khong_phai' then p_old.sale_id else coalesce(p_old.sale_id, n.sale_id) end else n.sale_id end,
    md = case when p_old.reply = 'nham' or p_old.claimed_at is not null then coalesce(p_old.md, n.md) else coalesce(n.md, p_old.md) end,
    ma_dong = case when p_old.reply = 'nham' or p_old.claimed_at is not null then coalesce(p_old.ma_dong, n.ma_dong) else n.ma_dong end, gia_khach = coalesce(nullif(n.gia_khach, 0), nullif(p_old.gia_khach, 0), n.gia_khach),
    ma_kh = case when coalesce(n.ma_kh, '') = '' and not app.kh_la_don(p_old.ma_kh, coalesce(n.md, p_old.md)) and coalesce(n.md, p_old.md) is not distinct from p_old.md then p_old.ma_kh else n.ma_kh end,
    released_from = p_old.released_from, claim_md = p_old.claim_md, claim_gia = p_old.claim_gia, claimed_by = p_old.claimed_by, claimed_at = p_old.claimed_at,
    reply = p_old.reply, reply_sub = p_old.reply_sub, reply_price = p_old.reply_price, reply_note = p_old.reply_note, replied_by = p_old.replied_by, replied_at = p_old.replied_at
  where id = p_id;
  if n.status = 'ok' then return; end if; -- file mới đã sạch → theo file
  if p_old.reply is not null or p_old.claimed_at is not null or p_old.status in ('approved','pending_approval') then
    update public.acc_lines set status = p_old.status, luong = p_old.luong, phan_hoi = p_old.phan_hoi, issues = p_old.issues, due_at = p_old.due_at,
      gia_nhap = case when p_old.reply = 'da_gui_gia' then p_old.gia_nhap else gia_nhap end, gia_nhap_goc = p_old.gia_nhap_goc,
      gia_ap_dung = p_old.gia_ap_dung, gia_de_xuat = p_old.gia_de_xuat, bien_nt = p_old.bien_nt, tt_apt = p_old.tt_apt, tt_khach = p_old.tt_khach
    where id = p_id;
  end if;
end $$;

-- Kế toán điền username cho dòng đối soát (màn nạp HĐ chính thức) — dòng sổ theo qua trigger
create or replace function public.acc_lines_set_kh(p_ids uuid[], p_username text) returns int
language plpgsql security definer set search_path = public, app as $$
declare v_u text := app.norm_username(nullif(btrim(p_username), '')); n int; r record;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  if v_u is null then raise exception 'Nhập username khách'; end if;
  for r in select truck_id, md, array_agg(ma_dong order by ma_dong) mas from public.acc_lines where id = any(p_ids) and ma_kh is distinct from v_u group by truck_id, md loop
    insert into public.acc_events(truck_id, action, note, data) values (r.truck_id, 'set_kh', r.md, jsonb_build_object('username', v_u, 'ma', r.mas));
  end loop;
  update public.acc_lines set ma_kh = v_u, updated_at = now() where id = any(p_ids) and ma_kh is distinct from v_u;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.acc_lines_set_kh(uuid[], text) to authenticated;

-- Sửa ID đơn / username dòng sẵn sàng xuất: kế toán, hoặc sale / CSKH / trưởng nhóm trong phạm vi; không đổi sale, không mở khóa dòng lệch
create or replace function public.out_items_fix_kh(p_ids uuid[], p_md text, p_username text) returns int
language plpgsql security definer set search_path = public, app as $$
declare t public.out_items; v_md text := app.norm_md(nullif(btrim(p_md), '')); v_u text := app.norm_username(nullif(btrim(p_username), '')); n int := 0;
begin
  if v_md is null and v_u is null then raise exception 'Nhập ID đơn hoặc username khách'; end if;
  if app.kh_la_don(v_u, v_md) then raise exception 'Username đang trùng số đơn % — nhập username thật của khách', v_md; end if;
  for t in select * from public.out_items where id = any(p_ids) order by ma_hang for update loop
    if not (app.is_acc() or app.in_tree(t.sale_id)) then raise exception 'Dòng % không thuộc phạm vi của bạn', t.ma_hang; end if;
    if app.out_item_has_inv(t.id) then raise exception 'Dòng % đã lập phiếu xuất HĐ — báo kế toán', t.ma_hang; end if;
    update public.out_items set md = coalesce(v_md, md), username = coalesce(v_u, username),
      customer_id = case when v_u is not null and v_u is distinct from t.username then null else customer_id end, updated_at = now(), updated_by = auth.uid()
     where id = t.id;
    -- dòng đối soát cùng nguồn sửa theo, để nạp lại file / HĐ không đè lại giá trị sai
    if t.acc_line_id is not null then
      update public.acc_lines set md = coalesce(v_md, md), ma_kh = coalesce(v_u, ma_kh), updated_at = now()
       where id = t.acc_line_id and (md is distinct from coalesce(v_md, md) or ma_kh is distinct from coalesce(v_u, ma_kh));
    end if;
    perform app.out_item_match(t.id);
    insert into public.out_events(item_id, action, data) values (t.id, 'fix_kh', jsonb_build_object('md', v_md, 'username', v_u, 'md_cu', t.md, 'username_cu', t.username));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Không tìm thấy dòng'; end if;
  return n;
end $$;
grant execute on function public.out_items_fix_kh(uuid[], text, text) to authenticated;

-- ---------- Sửa dữ liệu đã nạp bằng file xe lệch cột ----------
-- Dòng đối soát: mã khai báo MDxxxx-n mà ID đơn trống / khác đơn, và username trống hoặc trùng số đơn → đơn theo mã khai báo, bỏ username sai
update public.acc_lines l set md = x.md_kb, ma_kh = case when app.kh_la_don(l.ma_kh, x.md_kb) then null else l.ma_kh end, updated_at = now()
  from (select id, 'MD' || (substring(ma_dong from '^MD0*(\d+)-\d+$'))::bigint md_kb from public.acc_lines where ma_dong ~ '^MD\d+-\d+$') x
 where x.id = l.id and not l.is_test and l.md is distinct from x.md_kb
   and (l.md is null or coalesce(l.ma_kh, '') = '' or app.kh_la_don(l.ma_kh, x.md_kb));
-- Dòng đối soát chỉ còn username = số đơn
update public.acc_lines set ma_kh = null, updated_at = now() where not is_test and app.kh_la_don(ma_kh, md);

reset search_path;
