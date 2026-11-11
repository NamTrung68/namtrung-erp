-- Kiểm thử bản 41: hồ sơ scan (bản mềm) + bản cứng
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
create or replace function pg_temp.err(p_sql text, p_like text) returns void language plpgsql as $$
begin execute p_sql; raise exception 'FAIL: phải báo lỗi "%"', p_like;
exception when others then if sqlerrm like 'FAIL:%' or sqlerrm not like '%' || p_like || '%' then raise exception 'FAIL: % (lỗi nhận được: %)', p_like, sqlerrm; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- Dữ liệu từ bản 40: HĐ c1 (pháp nhân d1, đang trong phiếu V40-A "khách đã nhận", chưa thu về), c3 của sale B
insert into public.out_invoices(id, code, sale_id, buyer_name, tax_code, status)
  select '00000000-0000-0000-0041-0000000000e1', 'XHD41001', id, 'Cty V38', '0101248141', 'soan' from public.profiles where email = 'a@nt.vn';

-- sale không được tải scan, không đọc thẳng bảng
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.ho_so_scan_add('{"invoice_id":"00000000-0000-0000-0040-0000000000c1","kinds":["hd"],"drive_id":"x"}')$$, 'Chỉ Kế toán');
select pg_temp.err($$select count(*) from public.ho_so_scans$$, 'permission denied');
reset role;

select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.err($$select public.ho_so_scan_add('{"invoice_id":"00000000-0000-0000-0040-0000000000c1","kinds":[],"drive_id":"x"}')$$, 'Chọn loại');
select pg_temp.err($$select public.ho_so_scan_add('{"invoice_id":"00000000-0000-0000-0040-0000000000c1","kinds":["xyz"],"drive_id":"x"}')$$, 'không hợp lệ');
select pg_temp.err($$select public.ho_so_scan_add('{"invoice_id":"00000000-0000-0000-0041-0000000000e1","kinds":["hd"],"drive_id":"x"}')$$, 'chưa ký');
select pg_temp.err($$select public.ho_so_scan_add('{"buyer_id":"00000000-0000-0000-0040-0000000000d1","kinds":["hd"],"drive_id":"x"}')$$, 'Hồ sơ pháp nhân chỉ gồm');
select pg_temp.err($$select public.ho_so_scan_add('{"invoice_id":"00000000-0000-0000-0040-0000000000c1","kinds":["hd"],"drive_id":"x","url":"http://a"}')$$, 'https');
-- scan HĐ + ĐĐH + BBGN của c1 → tự xác nhận thu về trong phiếu chuyển phát
select pg_temp.check((public.ho_so_scan_add('{"invoice_id":"00000000-0000-0000-0040-0000000000c1","kinds":["hd","ddh","bbgn"],"drive_id":"drv-c1","url":"https://drive.google.com/file/d/drv-c1","file_name":"HD401.pdf","size_kb":300,"so_trang":3}')->>'thu')::int = 1, 'tự thu về 1 phiếu');
reset role;
select pg_temp.check((select thu_at is not null from public.out_ship_items i join public.out_ships s on s.id = i.ship_id where s.note = 'V40-A' and i.invoice_id = '00000000-0000-0000-0040-0000000000c1'), 'phiếu chuyển phát: HĐ c1 đã thu về');
select pg_temp.check((select ky_at is not null from public.out_doc_state where invoice_id = '00000000-0000-0000-0040-0000000000c1'), 'vết hồ sơ: đã có bản ký');
select pg_temp.check(exists(select 1 from public.out_events where invoice_id = '00000000-0000-0000-0040-0000000000c1' and action = 'scan'), 'lịch sử HĐ ghi lưu scan');

-- tình trạng: chưa ký HĐNT → cần HĐ mua bán
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select (r->>'du')::boolean = false and r->'thieu' = '["hdmb"]'::jsonb and (r->>'n')::int = 1
                        from jsonb_array_elements(public.ho_so_status(array['00000000-0000-0000-0040-0000000000c1']::uuid[])) r), 'thiếu HĐ mua bán');
reset role;
-- pháp nhân đã ký HĐ nguyên tắc → cần scan HĐNT (1 lần cho mọi HĐ của pháp nhân)
update public.out_buyers set ma_hdnt = '01/2026/HDNT', ngay_hdnt = '2026-01-05' where id = '00000000-0000-0000-0040-0000000000d1';
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select pg_temp.check((select r->'thieu' = '["hdnt"]'::jsonb from jsonb_array_elements(public.ho_so_status(array['00000000-0000-0000-0040-0000000000c1']::uuid[])) r), 'thiếu HĐ nguyên tắc');
select public.ho_so_scan_add('{"buyer_id":"00000000-0000-0000-0040-0000000000d1","kinds":["hdnt"],"drive_id":"drv-nt","url":"https://drive.google.com/file/d/drv-nt","file_name":"HDNT.pdf"}');
select pg_temp.check((select (r->>'du')::boolean from jsonb_array_elements(public.ho_so_status(array['00000000-0000-0000-0040-0000000000c1']::uuid[])) r), 'c1 đủ hồ sơ');
select pg_temp.check((select r->'thieu' = '["hd","ddh","bbgn"]'::jsonb from jsonb_array_elements(public.ho_so_status(array['00000000-0000-0000-0038-0000000000b1']::uuid[])) r), 'b1 có HĐNT, còn thiếu bộ chứng từ');
select pg_temp.check((public.ho_so_buyer_status(array['00000000-0000-0000-0040-0000000000d1']::uuid[])->'00000000-0000-0000-0040-0000000000d1'->>'hdnt')::int = 1, 'pháp nhân có 1 scan HĐNT');
select pg_temp.check((select bool_and(r->>'url' like 'https://%') and count(*) = 2 from jsonb_array_elements(public.ho_so_list('{"invoice_id":"00000000-0000-0000-0040-0000000000c1"}')) r), 'kế toán thấy link Drive');
select pg_temp.check(jsonb_array_length(public.ho_so_list('{"buyer_id":"00000000-0000-0000-0040-0000000000d1"}')) = 2, 'hồ sơ pháp nhân gồm HĐNT + scan HĐ');
reset role;

-- sale của HĐ xem được (không có link Drive), xin vé xem; sale khác bị chặn
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.check((select bool_and(r->>'url' is null) and count(*) = 2 from jsonb_array_elements(public.ho_so_list('{"invoice_id":"00000000-0000-0000-0040-0000000000c1"}')) r), 'sale xem danh sách, không có link Drive');
select pg_temp.check(length(public.ho_so_scan_ticket((select (r->>'id')::uuid from jsonb_array_elements(public.ho_so_list('{"invoice_id":"00000000-0000-0000-0040-0000000000c1"}')) r where r->>'cap' = 'hd'))) = 48, 'vé xem scan');
select pg_temp.err($$select public.ho_so_scan_del((select id from public.out_invoices limit 1))$$, 'Chỉ Kế toán');
reset role;
select pg_temp.as_user('b@nt.vn'); set role authenticated;
select pg_temp.err($$select public.ho_so_list('{"invoice_id":"00000000-0000-0000-0040-0000000000c1"}')$$, 'Không có quyền');
select pg_temp.check(jsonb_array_length(public.ho_so_status(array['00000000-0000-0000-0040-0000000000c1']::uuid[])) = 0, 'sale B không thấy tình trạng');
reset role;
-- Apps Script đổi vé: trả đúng mã file Drive của bản scan
insert into app.secrets(key, value) values ('backup_token_hash', encode(digest('tok41', 'sha256'), 'hex')) on conflict (key) do update set value = excluded.value;
create temp table s41 as select id from public.ho_so_scans where drive_id = 'drv-c1';
create temp table t41(tk text);
grant select on s41 to authenticated; grant insert, select on t41 to authenticated;
select pg_temp.as_user('a@nt.vn'); set role authenticated;
insert into t41 select public.ho_so_scan_ticket((select id from s41));
reset role;
select pg_temp.check((public.drive_redeem('tok41', (select tk from t41))->>'drive_id') = 'drv-c1', 'đổi vé → mã file scan');
select pg_temp.err($$select public.drive_redeem('tok41', (select tk from t41))$$, 'Vé không hợp lệ');
select pg_temp.check(exists(select 1 from public.audit_logs where action = 'VIEW_SCAN'), 'ghi nhật ký xem scan');

-- gỡ scan
create temp table n41 as select id from public.ho_so_scans where drive_id = 'drv-nt';
grant select on n41 to authenticated;
select pg_temp.as_user('kt@nt.vn'); set role authenticated;
select public.ho_so_scan_del((select id from n41));
select pg_temp.check((select r->'thieu' = '["hdnt"]'::jsonb from jsonb_array_elements(public.ho_so_status(array['00000000-0000-0000-0040-0000000000c1']::uuid[])) r), 'gỡ HĐNT → lại thiếu');
-- bản cứng
select pg_temp.err($$select public.out_doc_cung(array['00000000-0000-0000-0040-0000000000c1']::uuid[], '')$$, 'vị trí');
select pg_temp.check(public.out_doc_cung(array['00000000-0000-0000-0040-0000000000c1', '00000000-0000-0000-0038-0000000000b1', '00000000-0000-0000-0041-0000000000e1']::uuid[], 'Tủ 1 · Bìa T11/2026') = 2, 'cất bản cứng 2 HĐ đã ký');
select pg_temp.check((select r->>'cung_vi_tri' = 'Tủ 1 · Bìa T11/2026' from jsonb_array_elements(public.ho_so_status(array['00000000-0000-0000-0040-0000000000c1']::uuid[])) r), 'vị trí bản cứng');
select public.out_doc_cung(array['00000000-0000-0000-0038-0000000000b1']::uuid[], null, true);
reset role;
select pg_temp.check((select cung_at is null from public.out_doc_state where invoice_id = '00000000-0000-0000-0038-0000000000b1'), 'bỏ đánh dấu bản cứng');
select pg_temp.as_user('a@nt.vn'); set role authenticated;
select pg_temp.err($$select public.out_doc_cung(array['00000000-0000-0000-0040-0000000000c1']::uuid[], 'Tủ 2')$$, 'Chỉ Kế toán');
reset role;
select 'V41 TESTS PASSED' as result;
