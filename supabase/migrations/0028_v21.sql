-- =====================================================================
-- 0028 · Bản 21: Xuất HĐ đầu ra theo quy trình mới (PDF MISA là nguồn trạng thái)
--  · Ghi "đã xuất file nhập MISA lúc …" thay cho bấm tay "Đã xuất nháp"; phiếu sửa lại thì tự xóa mốc này
--  · Danh sách phiếu: lọc "sửa sau nháp", "chưa xuất file MISA"
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 21');

alter table public.out_invoices add column if not exists misa_at timestamptz;
alter table public.out_invoices add column if not exists misa_by uuid references public.profiles(id);

-- Phiếu còn "Chờ xuất nháp" mà bị sửa / quay lại → file MISA đã xuất không còn đúng
create or replace function app.out_misa_reset() returns trigger language plpgsql as $$
begin
  if new.status = 'cho_nhap' and new.misa_at is not distinct from old.misa_at
     and (new.updated_at is distinct from old.updated_at or new.status is distinct from old.status) then
    new.misa_at := null; new.misa_by := null;
  end if;
  return new;
end $$;
drop trigger if exists out_misa_reset on public.out_invoices;
create trigger out_misa_reset before update on public.out_invoices for each row execute function app.out_misa_reset();

create or replace function public.out_mark_misa(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  with u as (update public.out_invoices set misa_at = now(), misa_by = auth.uid() where id = any(p_ids) and status = 'cho_nhap' returning id)
  insert into public.out_events(invoice_id, action, note) select id, 'misa', 'Đã xuất file nhập MISA' from u;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.out_mark_misa(uuid[]) to authenticated;

create or replace function public.out_invoices_page(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_st text := nullif(p->>'status', ''); v_q text := nullif(btrim(p->>'q'), ''); v_sale uuid := nullif(p->>'sale', '')::uuid;
        v_off int := coalesce((p->>'offset')::int, 0); v_flag text := nullif(p->>'flag', ''); v_sua int; v_misa int; v_lim int := least(coalesce((p->>'limit')::int, 20), 500); r jsonb; n bigint; c jsonb; v_cg int;
        v_acc boolean := app.is_acc(); v_tree uuid[] := app.my_tree();
begin
  select coalesce(jsonb_object_agg(status, k), '{}') into c
    from (select status, count(*) k from public.out_invoices i where (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale) group by status) z;
  -- nháp mới nhất chưa gửi khách
  select count(*) into v_cg from public.out_invoices i
   where i.status = 'da_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale)
     and exists(select 1 from public.out_invoice_files f where f.invoice_id = i.id and f.kind = 'nhap' and f.sent_at is null
                  and f.version = (select max(x.version) from public.out_invoice_files x where x.invoice_id = i.id and x.kind = 'nhap'));
  select count(*) filter (where i.sua_sau_nhap), count(*) filter (where i.misa_at is null) into v_sua, v_misa from public.out_invoices i
   where i.status = 'cho_nhap' and (v_acc or i.sale_id = any(v_tree)) and (v_sale is null or i.sale_id = v_sale);
  if v_lim = 0 then return jsonb_build_object('total', 0, 'rows', '[]'::jsonb, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa); end if;
  with base as materialized (select * from public.out_invoices v where (v_acc or v.sale_id = any(v_tree)) and (v_sale is null or v.sale_id = v_sale)
                               and (v_st is null and v.status <> 'huy' or v.status = v_st)
                               and (v_flag is null or v_flag = 'sua' and v.sua_sau_nhap or v_flag = 'misa_chua' and v.misa_at is null)),
  a as (select l.invoice_id, count(*) n, sum(round(l.sl * l.don_gia)) tt, sum(round(round(l.sl * l.don_gia) * coalesce(l.vat, t.vat, 0))) thue,
               bool_or(t.dg_nhap is not null and l.don_gia < t.dg_nhap) duoi_gia, string_agg(t.ma_hang || ' ' || coalesce(t.md, ''), ' ') tim
          from public.out_invoice_lines l join public.out_items t on t.id = l.item_id where l.invoice_id in (select id from base) group by l.invoice_id),
  fl as (select distinct on (invoice_id, kind) invoice_id, kind, version, sent_at from public.out_invoice_files
          where invoice_id in (select id from base) order by invoice_id, kind, version desc),
  f as (select b.*, coalesce(a.n, 0) so_dong, coalesce(a.tt, 0) tien_hang, coalesce(a.thue, 0) tien_thue, coalesce(a.duoi_gia, false) duoi_gia,
               fn.version nhap_v, fn.sent_at is not null nhap_sent, fk.version ky_v
          from base b left join a on a.invoice_id = b.id
          left join fl fn on fn.invoice_id = b.id and fn.kind = 'nhap' left join fl fk on fk.invoice_id = b.id and fk.kind = 'ky'
         where v_q is null or concat_ws(' ', b.code, b.buyer_name, b.tax_code, b.so_hd, b.buyer_info, a.tim) ilike '%' || v_q || '%'),
  o as (select f.*, row_number() over (order by f.status_at desc) rn, count(*) over () tot from f)
  select max(tot), coalesce(jsonb_agg(to_jsonb(o) - 'rn' - 'tot' order by rn) filter (where rn > v_off and rn <= v_off + v_lim), '[]') into n, r from o;
  return jsonb_build_object('total', coalesce(n, 0), 'rows', r, 'counts', c, 'chua_gui', v_cg, 'sua', v_sua, 'misa_chua', v_misa);
end $$;
grant execute on function public.out_invoices_page(jsonb) to authenticated;

-- Thông báo: chữ theo quy trình mới, bấm vào mở thẳng phiếu
create or replace function public.out_invoice_status(p_ids uuid[], p_status text, p_note text default null, p_so_hd text default null, p_ngay date default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare v public.out_invoices; n int := 0; v_acc boolean := app.is_acc(); ok boolean;
begin
  for v in select * from public.out_invoices where id = any(p_ids) for update loop
    if not (v_acc or app.in_tree(v.sale_id)) then raise exception 'Phiếu % không thuộc bạn', v.code; end if;
    ok := case p_status
      when 'cho_nhap' then v.status in ('soan','da_nhap','xac_nhan_ky')
      when 'xac_nhan_ky' then v.status = 'da_nhap'
      when 'da_nhap' then v_acc and v.status in ('cho_nhap','xac_nhan_ky')
      when 'da_ky' then v_acc and v.status in ('xac_nhan_ky','da_nhap')
      when 'soan' then v_acc and v.status in ('cho_nhap','da_nhap','xac_nhan_ky')
      when 'huy' then v.status <> 'da_ky' and (v_acc or v.status in ('soan','cho_nhap'))
      else false end;
    if not ok then raise exception 'Phiếu % đang "%", không chuyển sang "%" được', v.code, v.status, p_status; end if;
    if p_status = 'da_ky' and coalesce(btrim(coalesce(p_so_hd, v.so_hd)), '') = '' then raise exception 'Nhập số HĐ đã ký cho phiếu %', v.code; end if;
    if p_status in ('soan','huy') and v_acc and not app.in_tree(v.sale_id) and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi lý do'; end if;
    if p_status = 'cho_nhap' and v.status in ('da_nhap','xac_nhan_ky') and coalesce(btrim(p_note), '') = '' then raise exception 'Ghi nội dung cần sửa'; end if;
    update public.out_invoices set status = p_status, status_at = now(), status_by = auth.uid(), updated_at = now(),
      so_hd = case when p_status = 'da_ky' then coalesce(nullif(btrim(p_so_hd), ''), so_hd) else so_hd end,
      ngay_hd = case when p_status = 'da_ky' then coalesce(p_ngay, ngay_hd, current_date) else ngay_hd end,
      sua_sau_nhap = case when p_status = 'da_nhap' then false when p_status = 'cho_nhap' and v.status in ('da_nhap','xac_nhan_ky') then true else sua_sau_nhap end
    where id = v.id;
    insert into public.out_events(invoice_id, action, note, data) values (v.id, 'status', p_note, jsonb_build_object('from', v.status, 'to', p_status, 'so_hd', p_so_hd));
    if p_status in ('cho_nhap','xac_nhan_ky') then
      perform app.notify_roles(array['ke_toan'], 'acc', case when p_status = 'xac_nhan_ky' then 'Khách OK — chờ ký: ' when v.status in ('da_nhap','xac_nhan_ky') then 'Khách yêu cầu sửa nháp: ' else 'Phiếu chờ xuất nháp: ' end || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out?inv=' || v.id);
    elsif p_status in ('da_nhap','da_ky','soan') or (p_status = 'huy' and v_acc) then
      perform app.notify(v.sale_id, 'acc', case p_status when 'da_nhap' then 'Có HĐ nháp — gửi khách: ' when 'da_ky' then 'Đã ký HĐ — báo khách kiểm tra email: '
        when 'soan' then 'Kế toán trả lại phiếu: ' else 'Kế toán hủy phiếu: ' end || v.code, coalesce(v.buyer_name, '') || coalesce(' — ' || p_note, ''), '#/out?inv=' || v.id);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
grant execute on function public.out_invoice_status(uuid[], text, text, text, date) to authenticated;

reset search_path;
