-- 0047 · Bản 39b: gọi hàm máy chủ hdky chờ tối đa 120 giây (mặc định pg_net 5 giây cắt sớm → mỗi lượt quét chỉ tải được 1 HĐ)
set search_path = public, app, extensions;
create or replace function app.hdky_kick(p_ids uuid[] default null) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_url text := replace(coalesce(app.setting('push')->>'url', ''), '/functions/v1/push', '/functions/v1/hdky');
begin
  if v_url not like 'https://%/functions/v1/hdky' or coalesce(app.setting('drive')->>'url', '') = '' then return; end if;
  if not exists(select 1 from pg_namespace where nspname = 'net') then return; end if;
  begin
    -- chờ tối đa 120 giây: mỗi HĐ ~10 giây, 6 HĐ / lượt; cắt sớm (mặc định 5 giây) làm hàm máy chủ dừng giữa chừng
    execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 120000)'
      using v_url, jsonb_build_object('action', 'sweep', 'ids', to_jsonb(p_ids)),
            jsonb_build_object('Content-Type', 'application/json', 'x-cron-key', (select value from app.secrets where key = 'hdky_cron_key'));
  exception when others then null; end;
end $$;
reset search_path;
