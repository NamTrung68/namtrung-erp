-- Kiểm thử bản 46: đối chiếu pháp nhân yêu cầu mới với HĐ đã ký
\set ON_ERROR_STOP 1
create or replace function pg_temp.as_user(p_email text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce((select id::text from public.profiles where email = p_email), ''), false); perform set_config('nt.scope', '', false); end $$;
create or replace function pg_temp.check(p boolean, p_msg text) returns void language plpgsql as $$
begin if p is not true then raise exception 'FAIL: %', p_msg; end if; end $$;
grant execute on all functions in schema pg_temp to authenticated;

select pg_temp.check(app.pn_norm('  Công ty  ABC. ') = app.pn_norm('công ty abc'), 'chuẩn hóa khoảng trắng / hoa thường / dấu chấm cuối');
select pg_temp.check(app.pn_norm('Công ty ABC') <> app.pn_norm('Cong ty ABC'), 'không bỏ dấu tiếng Việt');
select pg_temp.check(app.mst_norm(' 0101 234567 ') = '0101234567', 'MST bỏ khoảng trắng');

insert into public.out_invoices(id, code, sale_id, buyer_name, tax_code, address, email, status, so_hd, ngay_hd)
select x.id::uuid, x.code, p.id, x.ten, x.mst, x.dc, x.em, x.st, x.so, x.ngay::date from public.profiles p,
 (values ('00000000-0000-0000-0045-0000000000a1', 'XHD45001', 'Công ty TNHH Hoa Mai', '0101234567', '12 Lê Lợi, Hà Nội', 'a@hm.vn', 'da_ky', '101', '2026-10-01'),
         ('00000000-0000-0000-0045-0000000000a2', 'XHD45002', 'CÔNG TY TNHH HOA MAI ', '0101234567', '12 Lê Lợi,  Hà Nội.', 'a@hm.vn', 'cho_nhap', null, null),
         ('00000000-0000-0000-0045-0000000000a3', 'XHD45003', 'Công ty TNHH Hoa Mai', '0101234567', '15 Lê Lợi, Hà Nội', 'a@hm.vn', 'cho_nhap', null, null),
         ('00000000-0000-0000-0045-0000000000a4', 'XHD45004', 'Công ty Mới', '0109999999', 'Hà Nội', null, 'cho_nhap', null, null),
         ('00000000-0000-0000-0045-0000000000a5', 'XHD45005', 'Anh Nam', null, 'Hà Nội', null, 'cho_nhap', null, null)) x(id, code, ten, mst, dc, em, st, so, ngay)
 where p.email = 'a@nt.vn';

select pg_temp.as_user('kt@nt.vn'); set role authenticated;
do $$ declare r jsonb; begin
  r := public.out_pn_check(array['00000000-0000-0000-0045-0000000000a2', '00000000-0000-0000-0045-0000000000a3', '00000000-0000-0000-0045-0000000000a4', '00000000-0000-0000-0045-0000000000a5']::uuid[]);
  perform pg_temp.check(r->'00000000-0000-0000-0045-0000000000a2'->>'st' = 'khop', 'khác hoa thường / khoảng trắng → vẫn khớp');
  perform pg_temp.check(r->'00000000-0000-0000-0045-0000000000a2'->'last'->>'so_hd' = '101', 'khớp: trả số HĐ đã ký');
  perform pg_temp.check(r->'00000000-0000-0000-0045-0000000000a3'->>'st' = 'lech', 'đổi địa chỉ → lệch');
  perform pg_temp.check(r->'00000000-0000-0000-0045-0000000000a3'->'diff' = '["dia_chi"]', 'lệch đúng trường địa chỉ');
  perform pg_temp.check(r->'00000000-0000-0000-0045-0000000000a4'->>'st' = 'moi', 'MST chưa từng xuất → mới');
  perform pg_temp.check(r->'00000000-0000-0000-0045-0000000000a5'->>'st' = 'khong_mst', 'không MST');
  -- HĐ đã ký tự so với chính nó → không tính (MST chỉ có 1 HĐ đã ký là chính nó → mới)
  r := public.out_pn_check(array['00000000-0000-0000-0045-0000000000a1']::uuid[]);
  perform pg_temp.check(r->'00000000-0000-0000-0045-0000000000a1'->>'st' = 'moi', 'không so với chính nó');
end $$;
select pg_temp.check((public.out_buyers_page('{"flag":"da_xuat"}')->'counts') ? 'lech_xuat', 'out_buyers_page có đếm đã xuất / lệch');
reset role;
-- sale khác nhóm không xem được
select pg_temp.as_user('hr@nt.vn'); set role authenticated;
select pg_temp.check(public.out_pn_check(array['00000000-0000-0000-0045-0000000000a2']::uuid[]) = '{}', 'ngoài phạm vi → rỗng');
reset role;
select 'V46 TESTS PASSED' as result;
