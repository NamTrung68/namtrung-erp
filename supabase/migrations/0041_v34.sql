-- =====================================================================
-- 0041 · Bản 34 (06/11/2026): Sửa lỗi "Dữ liệu bị trùng" khi nạp Excel pháp nhân
--  · Khóa chống trùng tính theo KHÁCH (đã gắn) hoặc USERNAME (chưa gắn khách) — trước đây mọi pháp nhân chưa gắn khách
--    bị coi như cùng 1 khách → 2 username có cùng pháp nhân (tên + MST) bị báo trùng
--  · Nạp: khớp đúng tên + MST trước, rồi mới khớp theo MST để đổi tên → không đụng dòng trùng có sẵn
--  · Nạp từng dòng: dòng lỗi bị bỏ qua và báo lại (không hủy cả file)
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 34');

drop index if exists public.out_buyers_uq;
create unique index if not exists out_buyers_uq2 on public.out_buyers(
  coalesce(customer_id::text, 'u:' || lower(btrim(coalesce(username, '')))), lower(btrim(name)), coalesce(btrim(tax_code), ''));

-- Gắn khách theo username: từng dòng, bỏ qua dòng mà khách đã có pháp nhân cùng tên + MST (không làm hỏng cả lần nạp)
create or replace function app.out_buyers_relink() returns int language plpgsql security definer set search_path = public, app as $$
declare n int := 0; r record;
begin
  for r in select b.id, c.id cid from public.out_buyers b
             join public.customers c on c.deleted_at is null and (lower(btrim(c.sys_username)) = lower(btrim(b.username)) or upper(btrim(c.sys_code)) = upper(btrim(b.username)))
            where b.customer_id is null and b.username is not null loop
    begin
      update public.out_buyers b set customer_id = r.cid where b.id = r.id and b.customer_id is null
        and not exists(select 1 from public.out_buyers x where x.customer_id = r.cid and lower(btrim(x.name)) = lower(btrim(b.name)) and coalesce(btrim(x.tax_code), '') = coalesce(btrim(b.tax_code), ''));
      if found then n := n + 1; end if;
    exception when unique_violation then null;
    end;
  end loop;
  update public.out_buyers b set is_default = true
   where b.id in (select distinct on (customer_id) id from public.out_buyers where customer_id is not null order by customer_id, created_at desc)
     and not exists(select 1 from public.out_buyers x where x.customer_id = b.customer_id and x.is_default);
  return n;
end $$;

-- Nạp danh sách: trả {n, moi, sua, loi:[{dong, name, tax_code, username, error}]}
create or replace function public.out_buyers_import_v2(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; k int := 0; n_moi int := 0; n_sua int := 0; loi jsonb := '[]'; v_id uuid; v_mst text; v_c uuid; v_user text; v_name text;
begin
  if not app.is_acc() then raise exception 'Chỉ Kế toán / Admin / BGĐ'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    k := k + 1;
    v_mst := nullif(regexp_replace(coalesce(r->>'tax_code', ''), '\s', '', 'g'), '');
    v_name := nullif(regexp_replace(btrim(coalesce(r->>'name', '')), '\s+', ' ', 'g'), '');
    if v_mst is null or v_name is null then continue; end if;
    begin
      v_c := null; v_id := null; v_user := app.norm_username(nullif(btrim(r->>'username'), ''));
      if v_user is not null then
        select id into v_c from public.customers where deleted_at is null and (lower(btrim(sys_username)) = lower(v_user) or upper(btrim(sys_code)) = upper(v_user)) order by created_at limit 1;
      end if;
      -- 1) đúng tên + MST của khách / username đó → chỉ cập nhật địa chỉ, email
      select id into v_id from public.out_buyers b
       where btrim(b.tax_code) = v_mst and lower(btrim(b.name)) = lower(v_name)
         and (v_c is not null and b.customer_id = v_c or v_c is null and b.customer_id is null and lower(coalesce(b.username, '')) = lower(coalesce(v_user, '')))
       limit 1;
      if v_id is not null then
        update public.out_buyers set name = v_name, username = coalesce(v_user, username), address = coalesce(nullif(btrim(r->>'address'), ''), address),
          email = coalesce(nullif(btrim(r->>'email'), ''), email), updated_at = now(), updated_by = auth.uid() where id = v_id;
        n_sua := n_sua + 1; continue;
      end if;
      -- 2) cùng MST, khác tên → đổi tên theo file (chuẩn hóa)
      select id into v_id from public.out_buyers b
       where btrim(b.tax_code) = v_mst
         and (v_c is not null and b.customer_id = v_c or v_c is null and b.customer_id is null and lower(coalesce(b.username, '')) = lower(coalesce(v_user, '')))
       order by b.is_default desc, b.created_at desc limit 1;
      if v_id is not null then
        update public.out_buyers set name = v_name, username = coalesce(v_user, username), address = coalesce(nullif(btrim(r->>'address'), ''), address),
          email = coalesce(nullif(btrim(r->>'email'), ''), email), updated_at = now(), updated_by = auth.uid() where id = v_id;
        n_sua := n_sua + 1; continue;
      end if;
      -- 3) chưa có → thêm
      insert into public.out_buyers(customer_id, username, name, tax_code, address, email, note, updated_at, updated_by)
      values (v_c, v_user, v_name, v_mst, nullif(btrim(r->>'address'), ''), nullif(btrim(r->>'email'), ''), 'Danh sách kế toán', now(), auth.uid());
      n_moi := n_moi + 1;
    exception when others then
      loi := loi || jsonb_build_object('dong', k, 'name', v_name, 'tax_code', v_mst, 'username', r->>'username',
        'error', case when sqlstate = '23505' then 'Trùng: khách / username này đã có pháp nhân cùng tên + MST' else sqlerrm end);
    end;
  end loop;
  perform app.out_buyers_relink();
  return jsonb_build_object('n', n_moi + n_sua, 'moi', n_moi, 'sua', n_sua, 'loi', loi);
end $$;
grant execute on function public.out_buyers_import_v2(jsonb) to authenticated;

-- Hàm cũ (nút nạp ở màn Bàn làm việc kế toán) dùng chung cách nạp mới
create or replace function public.out_buyers_import(p_rows jsonb) returns int
language plpgsql security definer set search_path = public, app as $$
begin
  return (public.out_buyers_import_v2(p_rows)->>'n')::int;
end $$;
grant execute on function public.out_buyers_import(jsonb) to authenticated;

reset search_path;
