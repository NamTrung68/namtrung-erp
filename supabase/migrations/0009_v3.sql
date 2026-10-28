-- =====================================================================
-- 0009 · Bản 3: thông tin khách trong Hỗ trợ khách, hồ sơ nhân sự,
--        hợp đồng lao động, thỏa thuận riêng, giấy tờ nhân sự
-- =====================================================================

-- ---------- Hỗ trợ khách: người xử lý xem được thông tin + lịch sử khách ----------
create or replace function public.support_customer(p_req uuid)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare r public.support_requests; c public.customers; res jsonb;
begin
  select * into r from public.support_requests where id = p_req;
  if r.id is null or r.customer_id is null then return null; end if;
  if not (r.requester_id = auth.uid() or r.assignee_id = auth.uid() or app.is_admin() or app.in_tree(r.requester_id)
          or r.org_unit_id = (select org_unit_id from public.profiles where id = auth.uid())) then
    raise exception 'Không có quyền xem yêu cầu này';
  end if;
  select * into c from public.customers where id = r.customer_id;
  res := jsonb_build_object(
    'id', c.id, 'code', c.code, 'contact_name', c.contact_name, 'company_name', c.company_name, 'position', c.position,
    'phone', c.phone, 'zalo', c.zalo, 'email', c.email, 'tax_code', c.tax_code, 'province', c.province, 'address', c.address,
    'customer_type', c.customer_type, 'industry', c.industry, 'goods', c.goods, 'import_method', c.import_method,
    'current_provider', c.current_provider, 'monthly_value', c.monthly_value, 'stage', c.stage, 'temperature', c.temperature,
    'next_care_date', c.next_care_date, 'care_count', c.care_count, 'quote_count', c.quote_count, 'order_count', c.order_count,
    'note', c.note, 'owner_id', c.owner_id, 'owner_name', app.name_of(c.owner_id), 'services', c.services, 'goods_traits', c.goods_traits,
    'can_open', app.is_admin() or app.in_tree(c.owner_id),
    'care', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select cl.id, cl.created_at, cl.channel, cl.purpose, cl.result, cl.is_connected, cl.content, cl.stage_after, cl.temperature_after,
               cl.next_care_date, cl.quotation_code, app.name_of(cl.sale_id) sale_name
        from public.care_logs cl where cl.customer_id = c.id order by cl.created_at desc limit 30) x), '[]'),
    'quotes', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select q.id, q.code, q.version, q.status, q.total_after_vat, q.created_at, q.order_code
        from public.quotations q where q.customer_id = c.id and q.status <> 'da_thay_the' order by q.created_at desc limit 10) x), '[]'));
  return res;
end $$;
grant execute on function public.support_customer(uuid) to authenticated;

-- ---------- Hồ sơ nhân sự ----------
create or replace function app.is_hr_admin() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.has_role('admin','bgd','hcns') $$;

create table if not exists public.hr_records(
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  gender text check (gender in ('nam','nu','khac')),
  dob date,
  id_number text,               -- số CCCD
  id_issued_on date,
  id_issued_by text,
  permanent_address text,
  current_address text,
  personal_email text,
  personal_tax_code text,
  social_insurance_no text,
  marital_status text,
  dependants int not null default 0,
  education text,
  major text,
  school text,
  emergency_name text,
  emergency_relation text,
  emergency_phone text,
  position_title text,
  employment_status text not null default 'chinh_thuc' check (employment_status in ('thu_viec','chinh_thuc','ctv','thoi_vu','nghi_viec')),
  probation_from date,
  probation_to date,
  official_date date,
  leave_date date,
  leave_reason text,
  note text,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.hr_contracts(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  contract_no text,
  contract_type text not null check (contract_type in ('thu_viec','xac_dinh','khong_xac_dinh','ctv','thoi_vu','phu_luc')),
  title text,
  position_title text,
  start_date date not null,
  end_date date,
  base_salary numeric(18,0),
  insurance_salary numeric(18,0),
  allowance numeric(18,0),
  status text not null default 'hieu_luc' check (status in ('nhap','hieu_luc','het_han','thanh_ly')),
  signed_on date,
  file_path text,
  note text,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists hr_contracts_profile on public.hr_contracts(profile_id, start_date desc);

create table if not exists public.hr_agreements(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'khac' check (kind in ('luong_thuong','hoa_hong','phu_cap','cam_ket','dao_tao','bao_mat','khac')),
  title text not null,
  content text,
  amount numeric(18,0),
  effective_from date,
  effective_to date,
  confidential boolean not null default true,   -- chỉ BGĐ/Admin + chính chủ xem
  file_path text,
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists hr_agreements_profile on public.hr_agreements(profile_id);

create table if not exists public.hr_documents(
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  doc_type text not null,
  title text,
  file_path text not null,
  file_name text,
  note text,
  uploaded_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists hr_documents_profile on public.hr_documents(profile_id);

insert into public.lookups(category, code, label, sort, extra) values
 ('hr_doc','cccd','CCCD 2 mặt',1,'{"required":true}'),
 ('hr_doc','so_yeu_ly_lich','Sơ yếu lý lịch',2,'{"required":true}'),
 ('hr_doc','bang_cap','Bằng cấp / chứng chỉ',3,'{"required":true}'),
 ('hr_doc','kham_suc_khoe','Giấy khám sức khỏe',4,'{"required":true}'),
 ('hr_doc','anh_the','Ảnh thẻ 3x4',5,'{"required":true}'),
 ('hr_doc','giay_khai_sinh','Giấy khai sinh',6,'{"required":false}'),
 ('hr_doc','so_bhxh','Sổ BHXH / tờ rời',7,'{"required":false}'),
 ('hr_doc','hop_dong_ky','Hợp đồng đã ký (bản scan)',8,'{"required":false}'),
 ('hr_doc','quyet_dinh','Quyết định (bổ nhiệm, tăng lương, kỷ luật…)',9,'{"required":false}'),
 ('hr_doc','khac','Giấy tờ khác',10,'{"required":false}')
on conflict (category, code) do nothing;

-- updated_at + audit
create or replace function app.touch_updated() returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists hr_records_touch on public.hr_records;
create trigger hr_records_touch before update on public.hr_records for each row execute function app.touch_updated();
drop trigger if exists hr_contracts_touch on public.hr_contracts;
create trigger hr_contracts_touch before update on public.hr_contracts for each row execute function app.touch_updated();
drop trigger if exists hr_agreements_touch on public.hr_agreements;
create trigger hr_agreements_touch before update on public.hr_agreements for each row execute function app.touch_updated();
drop trigger if exists audit_hr_records on public.hr_records;
create trigger audit_hr_records after insert or update or delete on public.hr_records for each row execute function app.audit();
drop trigger if exists audit_hr_contracts on public.hr_contracts;
create trigger audit_hr_contracts after insert or update or delete on public.hr_contracts for each row execute function app.audit();
drop trigger if exists audit_hr_agreements on public.hr_agreements;
create trigger audit_hr_agreements after insert or update or delete on public.hr_agreements for each row execute function app.audit();

-- Hợp đồng ký mới: cập nhật tình trạng làm việc + báo chính chủ
create or replace function app.hr_contract_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' and new.status = 'hieu_luc' then
    insert into public.hr_records(profile_id) values (new.profile_id) on conflict do nothing;
    update public.hr_records set
      employment_status = case new.contract_type when 'thu_viec' then 'thu_viec' when 'ctv' then 'ctv' when 'thoi_vu' then 'thoi_vu' when 'phu_luc' then employment_status else 'chinh_thuc' end,
      probation_from = case when new.contract_type = 'thu_viec' then new.start_date else probation_from end,
      probation_to = case when new.contract_type = 'thu_viec' then new.end_date else probation_to end,
      official_date = case when new.contract_type in ('xac_dinh','khong_xac_dinh') then coalesce(official_date, new.start_date) else official_date end,
      position_title = coalesce(new.position_title, position_title)
    where profile_id = new.profile_id;
    perform app.notify(new.profile_id, 'hr', 'Hợp đồng mới: ' || coalesce(new.contract_no, new.title, ''), 'Hiệu lực từ ' || to_char(new.start_date, 'DD/MM/YYYY'), '#/hr/staff');
  end if;
  return new;
end $$;
drop trigger if exists hr_contract_after on public.hr_contracts;
create trigger hr_contract_after after insert on public.hr_contracts for each row execute function app.hr_contract_after();

-- RLS
alter table public.hr_records enable row level security;
alter table public.hr_contracts enable row level security;
alter table public.hr_agreements enable row level security;
alter table public.hr_documents enable row level security;
drop policy if exists hrr_read on public.hr_records;
create policy hrr_read on public.hr_records for select to authenticated using (profile_id = auth.uid() or app.is_hr_admin());
drop policy if exists hrr_write on public.hr_records;
create policy hrr_write on public.hr_records for all to authenticated using (app.is_hr_admin()) with check (app.is_hr_admin());
drop policy if exists hrc_read on public.hr_contracts;
create policy hrc_read on public.hr_contracts for select to authenticated using (profile_id = auth.uid() or app.is_hr_admin());
drop policy if exists hrc_write on public.hr_contracts;
create policy hrc_write on public.hr_contracts for all to authenticated using (app.is_hr_admin()) with check (app.is_hr_admin());
drop policy if exists hra_read on public.hr_agreements;
create policy hra_read on public.hr_agreements for select to authenticated
  using (profile_id = auth.uid() or app.has_role('admin','bgd') or (app.has_role('hcns') and not confidential));
drop policy if exists hra_write on public.hr_agreements;
create policy hra_write on public.hr_agreements for all to authenticated
  using (app.has_role('admin','bgd') or (app.has_role('hcns') and not confidential))
  with check (app.has_role('admin','bgd') or (app.has_role('hcns') and not confidential));
drop policy if exists hrd_read on public.hr_documents;
create policy hrd_read on public.hr_documents for select to authenticated using (profile_id = auth.uid() or app.is_hr_admin());
drop policy if exists hrd_write on public.hr_documents;
create policy hrd_write on public.hr_documents for all to authenticated using (app.is_hr_admin()) with check (app.is_hr_admin());
grant select, insert, update, delete on public.hr_records, public.hr_contracts, public.hr_agreements, public.hr_documents to authenticated;

-- Tổng hợp danh sách hồ sơ cho HCNS
create or replace function public.hr_overview()
returns table(profile_id uuid, employment_status text, position_title text, official_date date, probation_to date,
              contract_type text, contract_end date, contract_status text, docs_have text[], docs_missing int, agreements int)
language sql stable security definer set search_path = public, app as $$
  select p.id, coalesce(r.employment_status, case when p.status = 'inactive' then 'nghi_viec' else 'chinh_thuc' end), r.position_title, r.official_date, r.probation_to,
         c.contract_type, c.end_date, c.status,
         coalesce((select array_agg(distinct d.doc_type) from public.hr_documents d where d.profile_id = p.id), '{}'),
         (select count(*) from public.lookups l where l.category = 'hr_doc' and l.active and (l.extra->>'required')::boolean
            and not exists (select 1 from public.hr_documents d where d.profile_id = p.id and d.doc_type = l.code))::int,
         (select count(*) from public.hr_agreements a where a.profile_id = p.id and (a.effective_to is null or a.effective_to >= app.vn_today()))::int
  from public.profiles p
  left join public.hr_records r on r.profile_id = p.id
  left join lateral (select * from public.hr_contracts k where k.profile_id = p.id and k.status in ('hieu_luc','het_han') and k.contract_type <> 'phu_luc'
                     order by k.start_date desc limit 1) c on true
  where app.is_hr_admin()
$$;
grant execute on function public.hr_overview() to authenticated;

-- Nhắc hợp đồng sắp hết hạn (30 và 7 ngày) + tự chuyển hết hạn
create or replace function app.job_contract_expiry() returns void
language plpgsql security definer set search_path = public, app as $$
declare k record; t date := app.vn_today();
begin
  update public.hr_contracts set status = 'het_han' where status = 'hieu_luc' and end_date < t;
  for k in select c.*, app.name_of(c.profile_id) nm from public.hr_contracts c
           where c.status = 'hieu_luc' and c.end_date in (t + 30, t + 7) loop
    perform app.notify(p.id, 'hr', 'Hợp đồng sắp hết hạn: ' || k.nm, 'Hết hạn ' || to_char(k.end_date, 'DD/MM/YYYY') || ' (còn ' || (k.end_date - t) || ' ngày)', '#/hr/staff?id=' || k.profile_id)
      from public.profiles p where p.status = 'active' and p.roles && array['hcns','admin'];
    perform app.telegram('hr', '📄 Hợp đồng của <b>' || app.esc(k.nm) || '</b> hết hạn ' || to_char(k.end_date, 'DD/MM/YYYY') || ' (còn ' || (k.end_date - t) || ' ngày)');
  end loop;
end $$;
select cron.schedule('nt_contract_expiry', '15 1 * * *', 'select app.job_contract_expiry()');

-- Kho giấy tờ nhân sự: thư mục {profile_id}/...
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('hr', 'hr', false, 15728640, null) on conflict (id) do nothing;
drop policy if exists hr_obj_ins on storage.objects;
create policy hr_obj_ins on storage.objects for insert to authenticated with check (bucket_id = 'hr' and app.is_hr_admin());
drop policy if exists hr_obj_read on storage.objects;
create policy hr_obj_read on storage.objects for select to authenticated
  using (bucket_id = 'hr' and (app.is_hr_admin() or (storage.foldername(name))[1] = auth.uid()::text));
drop policy if exists hr_obj_del on storage.objects;
create policy hr_obj_del on storage.objects for delete to authenticated using (bucket_id = 'hr' and app.is_hr_admin());

-- Bật sự kiện Telegram 'hr' (nhắc hợp đồng) cho cấu hình đang có
update public.settings set value = jsonb_set(value, '{events}', coalesce(value->'events', '[]'::jsonb) || '"hr"'::jsonb)
 where key = 'telegram' and not coalesce(value->'events', '[]'::jsonb) ? 'hr';
