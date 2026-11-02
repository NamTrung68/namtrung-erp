-- =====================================================================
-- 0031 · Bản 23b: dọn dữ liệu chạy thử Kế toán – Hóa đơn (anh xác nhận 02/11/2026 là dữ liệu test)
--  · Xóa xe đối soát, HĐ đầu vào, bảng gốc mã hàng, yêu cầu xuất HĐ, file PDF đã gắn, kho giá — bắt đầu sạch với bản 23
--  · GIỮ: pháp nhân nhận HĐ (out_buyers), file đơn hàng (out_orders), khách hàng
--  · Pháp nhân nhận HĐ gắn khách theo USERNAME (lưu lại username để tự gắn khi khách vào ERP sau); mỗi khách 1 pháp nhân mặc định
--  · File PDF trên Google Drive KHÔNG bị xóa — chỉ bỏ liên kết trong ERP
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi dọn dữ liệu test Kế toán – Hóa đơn (bản 23b)');

-- ---------- Dọn dữ liệu test ----------
delete from public.out_invoice_files;
delete from public.out_invoice_lines;
delete from public.out_events;
delete from public.out_invoices;
delete from public.out_prices;
delete from public.out_items;
delete from public.out_hd_xe;
delete from public.acc_invoice_lines;
delete from public.acc_invoices;
delete from public.acc_events;
delete from public.acc_lines;
delete from public.acc_trucks;
delete from app.drive_tickets where file_id is not null;
alter sequence public.out_invoice_seq restart with 1;

-- ---------- Pháp nhân nhận HĐ theo username khách ----------
alter table public.out_buyers add column if not exists username text;
create index if not exists out_buyers_username on public.out_buyers(lower(btrim(username))) where username is not null;

-- Gắn pháp nhân chưa có khách vào khách ERP theo username / mã hệ thống; khách chưa có mặc định → pháp nhân mới nhất làm mặc định
create or replace function app.out_buyers_relink() returns int language plpgsql security definer set search_path = public, app as $$
declare n int;
begin
  update public.out_buyers b set customer_id = c.id
    from public.customers c
   where b.customer_id is null and b.username is not null and c.deleted_at is null
     and (lower(btrim(c.sys_username)) = lower(btrim(b.username)) or upper(btrim(c.sys_code)) = upper(btrim(b.username)))
     and not exists(select 1 from public.out_buyers x where x.customer_id = c.id and lower(btrim(x.name)) = lower(btrim(b.name)) and coalesce(btrim(x.tax_code), '') = coalesce(btrim(b.tax_code), ''));
  get diagnostics n = row_count;
  update public.out_buyers b set is_default = true
   where b.id in (select distinct on (customer_id) id from public.out_buyers where customer_id is not null order by customer_id, created_at desc)
     and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default);
  return n;
end $$;

create or replace function public.out_buyers_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n int := 0; v_id uuid; v_mst text; v_c uuid; v_user text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), ''); if v_mst is null or coalesce(btrim(r->>'name'), '') = '' then continue; end if;
    v_c := null; v_user := nullif(btrim(r->>'username'), '');
    if v_user is not null then
      select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(v_user) or upper(btrim(sys_code)) = upper(v_user)) limit 1;
    end if;
    select id into v_id from public.out_buyers where customer_id is not distinct from v_c and btrim(tax_code) = v_mst
       and (v_c is not null or lower(btrim(coalesce(username, ''))) = lower(coalesce(v_user, ''))) limit 1;
    if v_id is null then
      insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note)
      values (v_c, v_user, btrim(r->>'name'), v_mst, nullif(btrim(r->>'address'), ''), nullif(btrim(r->>'email'), ''), 'Danh sách kế toán')
      on conflict do nothing;
    else
      update public.out_buyers set name = btrim(r->>'name'), username = coalesce(v_user, username), address = coalesce(nullif(btrim(r->>'address'), ''), address),
        email = coalesce(nullif(btrim(r->>'email'), ''), email) where id = v_id;
    end if;
    n := n + 1;
  end loop;
  perform app.out_buyers_relink();
  return n;
end $$;
grant execute on function public.out_buyers_import(jsonb) to authenticated;

-- Nạp bảng gốc HĐ đầu vào xong → gắn lại pháp nhân theo username khách vừa xác định
create or replace function app.trg_out_item_buyer() returns trigger language plpgsql security definer set search_path = public, app as $$
begin
  if new.customer_id is not null and (tg_op = 'INSERT' or old.customer_id is distinct from new.customer_id) then
    update public.out_buyers set customer_id = new.customer_id
     where customer_id is null and username is not null
       and lower(btrim(username)) in (select lower(btrim(x)) from public.customers c, unnest(array[c.sys_username, c.sys_code]) x where c.id = new.customer_id and x is not null);
    update public.out_buyers b set is_default = true
     where b.id = (select id from public.out_buyers where customer_id = new.customer_id order by created_at desc limit 1)
       and not exists(select 1 from public.out_buyers x where x.customer_id = new.customer_id and x.is_default);
  end if;
  return new;
end $$;
drop trigger if exists out_item_buyer on public.out_items;
create trigger out_item_buyer after insert or update of customer_id on public.out_items for each row execute function app.trg_out_item_buyer();

select app.out_buyers_relink();

reset search_path;
