-- Kiểm thử bản 5: sao lưu/khôi phục, nhập khách theo file hệ thống, kho báo giá, chặn chấm công ngoài IP
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- Sao lưu + khôi phục
select pg_temp.check((select count(*) from pg_namespace where nspname ~ '^bk_') >= 1, 'đã có bản sao lưu từ migration');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ begin perform public.backup_create('x'); raise exception 'phải chặn'; exception when others then if sqlerrm not like 'Chỉ Admin%' then raise; end if; end $$;
reset role;
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select pg_temp.check((select count(*) from public.backup_list()) >= 1, 'admin xem danh sách sao lưu');
reset role;
do $$ declare s text; old text; begin
  select contact_name into old from public.customers where phone_norm = '0888886812';
  perform pg_sleep(1.1); s := public.backup_create('test');
  update public.customers set note = 'SỬA NHẦM' where phone_norm = '0888886812';
  perform public.backup_restore_table(s, 'customers');
  if (select note from public.customers where phone_norm = '0888886812') is not distinct from 'SỬA NHẦM' then raise exception 'FAIL: khôi phục không ghi đè'; end if;
end $$;

-- Nhập khách theo file hệ thống
select pg_temp.as_user('namtrung20266@gmail.com'); set role authenticated;
select pg_temp.check((public.import_customers('[
 {"sys_username":"tasinamtrungcn","sys_code":"NT7785","last_name":"Nguyễn","first_name":"Trang","phone":"0988267290","tax_code":"038187013112","company_name":"Nguyễn Thị Thùy Trang","sys_warehouse":"Kho HCM","sale":"Sale B","first_order_date":"2026-10-07","last_order_date":"2026-10-17","salutation":"Bà","legal_rep":"Nguyễn Thị Thùy Trang"},
 {"sys_username":"khachlon","sys_code":"NT0001","last_name":"Khách","first_name":"Lớn","company_name":"Công ty TNHH Lớn"}
]'::jsonb, true)->>'created')::int = 2, 'tạo 2 khách (1 không SĐT, MST 12 số)');
select pg_temp.check((select tax_code = '038187013112' and sys_first_order_date = '2026-10-07' and sys_warehouse = 'Kho HCM' and created_by is null from public.customers where sys_code = 'NT7785'), 'lưu đủ trường, không tính KPI KH mới');
select pg_temp.check((select phone_norm is null from public.customers where sys_username = 'khachlon'), 'khách không SĐT');
select pg_temp.check((public.import_customers('[{"sys_username":"KhachLon","last_order_date":"2026-10-20"}]'::jsonb, false)->>'updated')::int = 1, 'khớp theo username');
reset role;

-- Kho báo giá: chỉ đơn đã chốt, ẩn cước theo cấu hình
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.quote_library(null, 'he_thong', 500, 0) where status <> 'da_chot') = 0, 'chỉ báo giá đã chốt');
reset role;
update public.settings set value = '{"freight_roles":["admin"]}' where key = 'library';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select count(*) from public.quote_library(null, null, 500, 0) where freight is not null) = 0, 'sale không thấy cước');
select pg_temp.check((public.quote_template('luu_tru', (select id from public.quote_archive limit 1), false)->'lines'->0->>'name') is not null, 'mẫu báo giá từ dữ liệu cũ');
reset role;

-- Chấm công ngoài IP bị chặn khi cấu hình "block"
update public.settings set value = value || '{"ip_whitelist":["10.0.0.1"],"outside_ip":"block"}' where key = 'attendance';
select pg_temp.as_user('a@nt.vn'); set role authenticated;
do $$ begin perform public.attendance_check('in', null, null); raise exception 'phải chặn'; exception when others then if sqlerrm not like 'Bạn đang ở ngoài mạng công ty%' then raise; end if; end $$;
reset role;
select 'V5 TESTS PASSED' as result;
