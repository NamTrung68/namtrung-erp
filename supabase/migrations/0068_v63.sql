-- =====================================================================
-- 0068 · Bản 63 (27/11/2026) — Lọc số HĐ kèm tên xe hàng
--  out_hd_opts trả thêm cột xe = tên xe đối soát của các dòng HĐ (qua dòng nháp đã ghép), để chọn HĐ theo xe.
--  Chỉ đổi hàm, không đổi bảng / dữ liệu.
-- =====================================================================
set search_path = public, app, extensions;

drop function if exists public.out_hd_opts(text);
create function public.out_hd_opts(p_mode text default 'mine') returns table(hd text, ngay date, n bigint, xe text)
language sql stable security definer set search_path = public, app as $$
  select app.hd_of(s.so_hd_vao, s.ma_hang) hd, max(s.ngay_vao) ngay, count(*) n,
         string_agg(distinct t.name, ', ') xe
    from app.out_items_scope(case when p_mode = 'acc' then 'acc' else 'mine' end) s
    left join public.acc_lines l on l.id = s.acc_line_id
    left join public.acc_trucks t on t.id = l.truck_id
   where app.hd_of(s.so_hd_vao, s.ma_hang) is not null
   group by 1 order by max(s.ngay_vao) desc nulls last, 1 desc
$$;
revoke all on function public.out_hd_opts(text) from public, anon;
grant execute on function public.out_hd_opts(text) to authenticated;

reset search_path;
