-- Giả lập các thành phần Supabase để chạy test trên PostgreSQL thường (KHÔNG chạy trên Supabase)
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
  if not exists (select 1 from pg_roles where rolname='authenticator') then create role authenticator login noinherit password 'auth'; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users(id uuid primary key default gen_random_uuid(), email text unique, raw_user_meta_data jsonb default '{}', created_at timestamptz default now());
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true),''), (nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'sub'))::uuid $$;
create or replace function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$;
grant usage on schema auth to anon, authenticated;
create schema if not exists storage;
create table if not exists storage.buckets(id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid, created_at timestamptz default now(), metadata jsonb);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $$ select (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
grant usage on schema storage to authenticated;
grant all on storage.objects to authenticated;
create schema if not exists net;
create table if not exists net.calls(id serial, url text, body jsonb, at timestamptz default now());
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint language sql as $$ insert into net.calls(url,body) values(url,body) returning id $$;
create schema if not exists cron;
create table if not exists cron.job(jobid serial, jobname text unique, schedule text, command text);
create or replace function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job(jobname,schedule,command) values(job_name,schedule,command) on conflict (jobname) do update set schedule=excluded.schedule, command=excluded.command returning jobid $$;
create or replace function cron.unschedule(job_name text) returns boolean language sql as $$ delete from cron.job where jobname=job_name returning true $$;

grant anon, authenticated, service_role to authenticator;
grant usage on schema net, cron to authenticated;
