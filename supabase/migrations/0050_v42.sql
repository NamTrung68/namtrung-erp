-- =====================================================================
-- 0050 · Bản 42 (11/11/2026) — Giảm egress Supabase (băng thông tải ra, gói Free 5 GB/tháng)
--  · Sao lưu Google Drive hằng đêm tải TOÀN BỘ database (~27 MB/đêm ≈ 800 MB/tháng), trong đó
--    nhật ký thay đổi (audit_logs) ~20 MB — 17,6 MB là bản chép từng dòng BC Lợi nhuận mỗi lần nhập lại.
--  · Sửa:
--    1. BC Lợi nhuận (order_results): thôi ghi nhật ký từng dòng; xóa nhật ký cũ của bảng này.
--       Dữ liệu vẫn giữ nguyên trong database (dùng tính hoa hồng), chỉ không đưa vào sao lưu Drive —
--       mất thì nhập lại file Excel.
--    2. Sao lưu Drive: bỏ bảng order_results; nhật ký chỉ lấy 3 ngày gần nhất (mỗi đêm nối tiếp nhau,
--       chồng 2 ngày cho an toàn) thay vì toàn bộ lịch sử.
--    3. Nhật ký cũ hơn 12 tháng tự xóa (05:20 hằng ngày).
--  · Apps Script trên Google Drive KHÔNG phải cập nhật.
-- =====================================================================
set search_path = public, app, extensions;
select public.backup_create('Trước khi cập nhật bản 42');

-- 1. BC Lợi nhuận: thôi ghi nhật ký + xóa nhật ký cũ
drop trigger if exists audit_orders on public.order_results;
delete from public.audit_logs where table_name = 'order_results';

-- 2. Sao lưu Drive
create or replace function public.backup_tables(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
begin
  perform app.backup_check(p_token);
  update public.settings set value = value || jsonb_build_object('last_backup_at', now()) where key = 'drive';
  insert into public.audit_logs(action, table_name) values ('BACKUP_DRIVE', 'all');
  return (select jsonb_agg(c.relname order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r' and c.relname not in ('order_results'));
end $$;

create or replace function public.backup_page(p_token text, p_table text, p_offset int default 0, p_limit int default 1000) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
declare pk text; v jsonb; w text := '';
begin
  perform app.backup_check(p_token);
  if to_regclass(format('public.%I', p_table)) is null then raise exception 'Không có bảng %', p_table; end if;
  if p_table = 'audit_logs' then w := 'where at > now() - interval ''3 days'''; end if;   -- nhật ký: chỉ phần mới
  select string_agg(format('%I', a.attname), ', ') into pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = format('public.%I', p_table)::regclass and i.indisprimary;
  execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from (select * from public.%I %s order by %s offset %s limit %s) x',
                 p_table, w, coalesce(pk, 'ctid'), greatest(p_offset, 0), least(greatest(p_limit, 1), 5000)) into v;
  return v;
end $$;
revoke all on function public.backup_tables(text) from public;
revoke all on function public.backup_page(text, text, int, int) from public;
grant execute on function public.backup_tables(text) to anon, authenticated;
grant execute on function public.backup_page(text, text, int, int) to anon, authenticated;

-- 3. Nhật ký giữ 12 tháng
select cron.schedule('nt_audit_purge', '20 22 * * *', $$delete from public.audit_logs where at < now() - interval '12 months'$$);

reset search_path;
