-- Bản 54b — so tên pháp nhân bỏ qua cả dấu gạch nối ("ĐIỆN-TỰ ĐỘNG" = "Điện - Tự Động")
create or replace function app.ten_norm(t text) returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(regexp_replace(lower(coalesce(app.pn_ten_sach(t), '')), '[,.;:–-]+', ' ', 'g'), '\s+', ' ', 'g')), '')
$$;
