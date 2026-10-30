-- =====================================================================
-- 0017 · Bản 10b: sao lưu Drive lấy theo từng bảng, từng trang (tránh quá thời gian chờ của Supabase gói miễn phí)
-- =====================================================================
set search_path = public, app, extensions;

create or replace function app.backup_check(p_token text) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_hash text;
begin
  select value into v_hash from app.secrets where key = 'backup_token_hash';
  if v_hash is null or encode(digest(coalesce(p_token, ''), 'sha256'), 'hex') <> v_hash then
    perform pg_sleep(1); raise exception 'Sai mã sao lưu';
  end if;
end $$;

-- Danh sách bảng cần sao lưu
create or replace function public.backup_tables(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
begin
  perform app.backup_check(p_token);
  update public.settings set value = value || jsonb_build_object('last_backup_at', now()) where key = 'drive';
  insert into public.audit_logs(action, table_name) values ('BACKUP_DRIVE', 'all');
  return (select jsonb_agg(c.relname order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r');
end $$;

-- 1 trang dữ liệu của 1 bảng (sắp theo khóa chính để không sót/trùng)
create or replace function public.backup_page(p_token text, p_table text, p_offset int default 0, p_limit int default 1000) returns jsonb
language plpgsql security definer set search_path = public, app, extensions as $$
declare pk text; v jsonb;
begin
  perform app.backup_check(p_token);
  if to_regclass(format('public.%I', p_table)) is null then raise exception 'Không có bảng %', p_table; end if;
  select string_agg(format('%I', a.attname), ', ') into pk
    from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = format('public.%I', p_table)::regclass and i.indisprimary;
  execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from (select * from public.%I order by %s offset %s limit %s) x',
                 p_table, coalesce(pk, 'ctid'), greatest(p_offset, 0), least(greatest(p_limit, 1), 5000)) into v;
  return v;
end $$;
revoke all on function public.backup_tables(text) from public;
revoke all on function public.backup_page(text, text, int, int) from public;
grant execute on function public.backup_tables(text) to anon, authenticated;
grant execute on function public.backup_page(text, text, int, int) to anon, authenticated;
drop function if exists public.backup_export(text);

reset search_path;
