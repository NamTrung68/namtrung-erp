-- =====================================================================
-- 0012 · Bản 6: sinh nhật nhân sự (Hôm nay + lời chúc), Admin đặt lại mật khẩu
-- =====================================================================
set search_path = public, app, extensions;
-- Tránh trùng tên khi 2 bản sao lưu tạo trong cùng 1 giây
create or replace function public.backup_create(p_note text default null) returns text
language plpgsql security definer set search_path = public, app as $$
declare s text := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS'); t record; old record;
begin
  if auth.uid() is not null and not app.is_admin() then raise exception 'Chỉ Admin được tạo bản sao lưu'; end if;
  while exists (select 1 from pg_namespace where nspname = s) loop
    perform pg_sleep(1); s := 'bk_' || to_char(clock_timestamp() at time zone 'Asia/Ho_Chi_Minh', 'YYYYMMDD_HH24MISS');
  end loop;
  execute format('create schema %I', s);
  execute format('revoke all on schema %I from public, anon, authenticated', s);
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' loop
    execute format('create table %I.%I as table public.%I', s, t.relname, t.relname);
  end loop;
  execute format('comment on schema %I is %L', s, coalesce(p_note, 'Sao lưu') || ' · ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'HH24:MI DD/MM/YYYY'));
  for old in select nspname from pg_namespace where nspname ~ '^bk_[0-9]{8}_[0-9]{6}$' order by nspname desc offset 5 loop
    execute format('drop schema %I cascade', old.nspname);
  end loop;
  insert into public.audit_logs(action, table_name, diff) values ('BACKUP', s, jsonb_build_object('note', p_note));
  return s;
end $$;

select public.backup_create('Trước khi cập nhật bản 6');
create extension if not exists pgcrypto with schema extensions;

-- ---------- Sinh nhật: chỉ lộ ngày/tháng, không lộ năm sinh ----------
create or replace function public.birthdays(p_month int default null)
returns table(profile_id uuid, full_name text, org_unit_id uuid, day int, month int, is_today boolean, days_left int)
language sql stable security definer set search_path = public, app as $$
  with t as (select app.vn_today() d)
  select p.id, p.full_name, p.org_unit_id, extract(day from r.dob)::int, extract(month from r.dob)::int,
         (extract(day from r.dob), extract(month from r.dob)) = (extract(day from t.d), extract(month from t.d)),
         extract(day from r.dob)::int - extract(day from t.d)::int
  from public.profiles p join public.hr_records r on r.profile_id = p.id cross join t
  where app.is_active() and p.status = 'active' and r.dob is not null
    and extract(month from r.dob)::int = coalesce(p_month, extract(month from t.d)::int)
  order by 5, 4
$$;
grant execute on function public.birthdays(int) to authenticated;

-- Nhân viên tự khai ngày sinh (1 lần); HCNS/Admin sửa được ở Hồ sơ nhân sự
create or replace function public.set_my_dob(p_dob date) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.is_active() then raise exception 'Chưa đăng nhập'; end if;
  if p_dob is null or p_dob > app.vn_today() - interval '15 years' or p_dob < date '1940-01-01' then raise exception 'Ngày sinh không hợp lệ'; end if;
  if exists (select 1 from public.hr_records where profile_id = auth.uid() and dob is not null) then raise exception 'Ngày sinh đã có — liên hệ HCNS nếu cần sửa'; end if;
  insert into public.hr_records(profile_id, dob) values (auth.uid(), p_dob) on conflict (profile_id) do update set dob = excluded.dob;
end $$;
grant execute on function public.set_my_dob(date) to authenticated;

create or replace function public.my_dob() returns date
language sql stable security definer set search_path = public as $$ select dob from public.hr_records where profile_id = auth.uid() $$;
grant execute on function public.my_dob() to authenticated;

-- 8:00 sáng: báo cả công ty ai sinh nhật hôm nay
create or replace function app.job_birthdays() returns void
language plpgsql security definer set search_path = public, app as $$
declare b record;
begin
  for b in select p.id, p.full_name from public.profiles p join public.hr_records r on r.profile_id = p.id
            where p.status = 'active' and r.dob is not null
              and to_char(r.dob, 'MM-DD') = to_char(app.vn_today(), 'MM-DD') loop
    perform app.notify(x.id, 'birthday', '🎂 Hôm nay sinh nhật ' || b.full_name, 'Gửi lời chúc tới ' || b.full_name || ' nhé!', '#/')
      from public.profiles x where x.status = 'active' and x.id <> b.id;
    perform app.notify(b.id, 'birthday', '🎉 Chúc mừng sinh nhật ' || b.full_name || '!', 'Nam Trung chúc bạn tuổi mới thật nhiều niềm vui, sức khỏe và thành công.', '#/');
    perform app.telegram('birthday', '🎂 Hôm nay sinh nhật <b>' || app.esc(b.full_name) || '</b>. Cả nhà gửi lời chúc nhé!');
  end loop;
end $$;
select cron.schedule('nt_birthdays', '0 1 * * *', 'select app.job_birthdays()');
update public.settings set value = jsonb_set(value, '{events}', coalesce(value->'events', '[]'::jsonb) || '"birthday"'::jsonb)
 where key = 'telegram' and not coalesce(value->'events', '[]'::jsonb) ? 'birthday';

-- ---------- Admin / HCNS đặt lại mật khẩu ----------
create or replace function public.admin_set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
declare v_roles text[];
begin
  select roles into v_roles from public.profiles where id = p_user;
  if v_roles is null then raise exception 'Không tìm thấy tài khoản'; end if;
  if not (app.is_admin() or (app.has_role('hcns') and not v_roles && array['admin','bgd'])) then
    raise exception 'Không có quyền đặt lại mật khẩu tài khoản này';
  end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'Mật khẩu tối thiểu 8 ký tự'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf', 10)), updated_at = now() where id = p_user;
  -- đăng xuất các phiên đang mở của tài khoản đó
  begin execute 'delete from auth.sessions where user_id = $1' using p_user; exception when others then null; end;
  begin execute 'delete from auth.refresh_tokens where user_id = $1::text' using p_user; exception when others then null; end;
  insert into public.audit_logs(action, table_name, record_id, diff) values ('RESET_PASSWORD', 'profiles', p_user::text, jsonb_build_object('by', auth.uid()));
  perform app.notify(p_user, 'account', '🔑 Mật khẩu của bạn vừa được đặt lại', 'Đăng nhập bằng mật khẩu mới rồi đổi lại ở mục Tài khoản.', '#/account');
end $$;
revoke all on function public.admin_set_password(uuid, text) from public, anon;
grant execute on function public.admin_set_password(uuid, text) to authenticated;

reset search_path;
