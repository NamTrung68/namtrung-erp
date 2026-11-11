-- Kiểm thử bản 38: tự tải PDF HĐ đã ký theo mã tra cứu (quyền, danh sách chờ, gắn file, vết hồ sơ)
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated, service_role;

insert into public.out_invoices(id, code, sale_id, buyer_name, tax_code, status, so_hd, status_at)
  select '00000000-0000-0000-0038-0000000000b1', 'XHD38001', id, 'Cty V38', '0101248141', 'xac_nhan_ky', '123', now() from public.profiles where email = 'a@nt.vn';
-- kế toán điền mã tra cứu → Đã ký (trigger gọi hàm máy chủ: không có pg_net/push → bỏ qua, không lỗi)
update public.out_invoices set status = 'da_ky', ma_tra_cuu = 'ABCD1234XYZ' where id = '00000000-0000-0000-0038-0000000000b1';

select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((public.out_ky_info('00000000-0000-0000-0038-0000000000b1')->>'ma_tra_cuu') = 'ABCD1234XYZ', 'sale của HĐ đọc được thông tin');
select pg_temp.check((public.out_ky_info('00000000-0000-0000-0038-0000000000b1')->>'url_tpl') like 'https://www.meinvoice.vn/%{code}%', 'link tải mặc định');
select pg_temp.check(public.out_ky_info('00000000-0000-0000-0038-0000000000b1')->>'file_id' is null, 'chưa có file');
select pg_temp.err($$select public.out_ky_attach('00000000-0000-0000-0038-0000000000b1', 'x', 'x.pdf', 1)$$, 'permission denied');
select pg_temp.err($$select public.out_ky_upload_ticket('HD da ky')$$, 'permission denied');
select public.out_doc_mark(array['00000000-0000-0000-0038-0000000000b1'::uuid], 'tai', array['hd']);
reset role;
select pg_temp.check((select (tai->'hd'->>'n')::int = 1 from public.out_doc_state where invoice_id = '00000000-0000-0000-0038-0000000000b1'), 'ghi vết tải HĐ PDF');
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_ky_info('00000000-0000-0000-0038-0000000000b1')$$, 'Không có quyền');
reset role;

-- hàm máy chủ (service_role)
select pg_temp.as_user(''); set role service_role;
select pg_temp.check('00000000-0000-0000-0038-0000000000b1' in (select * from public.out_ky_pending(50)), 'HĐ nằm trong danh sách chờ tải');
select public.out_ky_fail('00000000-0000-0000-0038-0000000000b1', 'meInvoice lỗi');
select pg_temp.check('00000000-0000-0000-0038-0000000000b1' not in (select * from public.out_ky_pending(50)), 'vừa lỗi → tạm bỏ qua 1 giờ');
select pg_temp.check(length(public.out_ky_upload_ticket('HD da ky/2026-11/Sale A')) = 48, 'vé tải lên');
do $$ declare f1 uuid; f2 uuid; begin
  f1 := public.out_ky_attach('00000000-0000-0000-0038-0000000000b1', 'drive-abc', 'KY_123.pdf', 120);
  f2 := public.out_ky_attach('00000000-0000-0000-0038-0000000000b1', 'drive-xyz', 'KY_123b.pdf', 120);
  perform pg_temp.check(f1 = f2, 'không gắn trùng file');
end $$;
select pg_temp.check(not public.hdky_cron_ok('sai'), 'khóa lịch sai');
reset role;
select value as k38 from app.secrets where key = 'hdky_cron_key' \gset
set role service_role;
select pg_temp.check(public.hdky_cron_ok(:'k38'), 'khóa lịch đúng');
reset role;
select pg_temp.check((select count(*) = 1 from public.out_invoice_files where invoice_id = '00000000-0000-0000-0038-0000000000b1' and kind = 'ky'), '1 file ky');
select pg_temp.check(not exists(select 1 from app.ky_fetch_fail where invoice_id = '00000000-0000-0000-0038-0000000000b1'), 'xóa vết lỗi khi tải được');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check(public.out_ky_info('00000000-0000-0000-0038-0000000000b1')->>'file_id' is not null, 'có file → trình duyệt lấy từ Drive');
select pg_temp.check(length(public.out_file_ticket((public.out_ky_info('00000000-0000-0000-0038-0000000000b1')->>'file_id')::uuid)) > 0, 'sale xin vé xem file');
reset role;
select 'V38 TESTS PASSED' as result;
