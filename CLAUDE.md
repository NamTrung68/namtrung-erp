# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ERP/CRM nội bộ của Công ty TNHH DV&TM Quốc tế Nam Trung (CRM bán hàng, chứng từ, nhân sự/lương, và mảng Kế toán – Hóa đơn). Toàn bộ giao diện, thông báo lỗi, comment và tài liệu viết bằng **tiếng Việt** — giữ nguyên cách này khi sửa/thêm. `README.md` có lịch sử từng bản (Bản 20 … 41) và đặc tả nghiệp vụ; đọc phần bản liên quan trước khi đụng vào một mảng.

## Lệnh thường dùng

```bash
npm install
npm run build                               # esbuild + Tailwind → dist/ (web tĩnh)
npm test                                    # unit test (tsx --test tests/*.test.ts)
npx tsx --test tests/hoso.test.ts           # chạy 1 file test
npx tsx --test --test-name-pattern="tên" tests/hoso.test.ts   # chạy 1 test theo tên
npm run db:test                             # toàn bộ migration + test SQL trên PostgreSQL cục bộ
npm run db:bundle                           # gộp migrations → supabase/setup.sql (phải commit kèm)
```

- Không có lint, không có typecheck trong CI. `esbuild` không kiểm kiểu; muốn soát kiểu phải tự chạy `tsc --noEmit` ngoài repo (code hiện có sẵn nhiều lỗi kiểu giả do `children`/`key`, chỉ nhìn lỗi mới ở file mình sửa).
- `npm run db:test` cần một PostgreSQL 16 đang chạy, biến `PGHOST` (mặc định `/var/tmp/pg`), `PGPORT` (mặc định `5433`), `PGUSER`. Nó **tạo lại DB `nt_test` từ đầu**, chạy `supabase/tests/00_supabase_stub.sql` (giả lập schema `auth`, `cron`, `net`, role `authenticated`…), mọi `supabase/migrations/*.sql` theo thứ tự, rồi mọi `supabase/tests/[1-9]*.sql` theo thứ tự tên. CI chạy đúng script này trên service `postgres:16`.
- Các test SQL **nối tiếp nhau và dùng dữ liệu của test trước** (user `a@nt.vn`, `b@nt.vn`, `kt@nt.vn`, các HĐ cố định…), nên không chạy riêng lẻ 1 file được — chạy cả bộ.
- `tests/e2e/*.cjs` là kịch bản Playwright, cần PostgREST + gateway giả lập (`tests/e2e/restart.sh`, binary `/var/tmp/postgrest` không nằm trong repo). Không chạy trong CI.
- Deploy: push/merge vào `main` → workflow `Test & Deploy` chạy `npm test` + `db:test` rồi build và đưa lên GitHub Pages. **Không có bước nào tự chạy migration lên Supabase** — xem mục Migration.

## Kiến trúc

**Frontend** (`src/`): React 19 + TypeScript, không router/state lib — tự viết.
- `src/main.tsx`: bảng `routes` ánh xạ hash-route (`#/hd`, `#/hd/kt`…) → trang. Thêm trang = thêm vào `routes` + menu trong `components/Layout.tsx` (`useNav`) + quyền vào trang trong `canOpen` nếu cần chặn gõ thẳng URL.
- `src/state.tsx`: `useApp()` trả về người dùng + cờ quyền dẫn xuất từ vai trò (`isAdmin`, `isSales`, `isLead`, `seesTeam`, `cskhOnly`, `has('ke_toan')`…). Quyền ở UI chỉ để ẩn/hiện; quyền thật nằm ở DB.
- `src/lib/sb.ts`: client Supabase tự viết bằng `fetch` (Auth + PostgREST + Storage), **không dùng `@supabase/supabase-js`**. Dùng `db.rpc('ten_ham', {…})` và `db.from('bang').select(…)`. `components/ui.tsx` có `useLoad`, `useAction`, `toast`, `ask`, `Modal`…
- `src/pages/hd/*` và `src/pages/out/*`, `src/pages/acc/*`: mảng Kế toán – Hóa đơn (lớn nhất). `src/lib/` chứa phần thuần không DOM để dễ test (`doisoat.ts`, `hoso.ts`, `hdDocs.ts`, `quote-calc.ts`…).

**Backend = chỉ PostgreSQL trên Supabase** (`supabase/migrations/NNNN_vNN.sql`). Không có server riêng:
- Nghiệp vụ nằm trong hàm SQL `security definer` ở schema `public` (frontend gọi qua RPC) và `app` (helper nội bộ, không expose). Bảng nghiệp vụ mới thường bật RLS chỉ cho `select`, **`revoke insert/update/delete`** và ghi qua hàm RPC để kiểm quyền + ghi nhật ký (`out_events`, `audit_logs`).
- Mô hình quyền dùng lại ở mọi chỗ: `app.is_acc()` (kế toán/admin/BGĐ), `app.is_admin()`, `app.in_tree(sale_id)` (người đó nằm trong cây quản lý của mình, tính cả CSKH được giao hỗ trợ và ủy quyền), `app.has_role(...)`. Khi thêm hàm đọc dữ liệu kinh doanh, lọc bằng `app.is_acc() or app.in_tree(sale_id)`.
- Việc định kỳ: `pg_cron` gọi các hàm `app.job_*` (đăng ký bằng `cron.schedule` ngay trong migration). Thông báo: `app.notify*` ghi bảng `notifications`; Telegram/push đi qua `pg_net`.
- Cấu hình động: bảng `settings` (đọc bằng `app.setting('khoa')`, ghi qua RPC `set_setting` — danh sách khóa mỗi vai trò được sửa nằm cứng trong hàm đó, thêm khóa mới phải cập nhật hàm).

**Hàm máy chủ** (`supabase/functions/{misa,hdky,mst,push}`, Deno): chỉ dùng khi cần gọi dịch vụ ngoài/giữ bí mật. Triển khai **thủ công** trên Supabase Dashboard (tắt “Verify JWT”, hàm tự kiểm phiên); bí mật ở Edge Function Secrets. CSDL gọi lại chúng bằng `pg_net` + khóa `x-cron-key`. `misa` chỉ được dùng nhóm tạo **nháp**; `tests/misa-guard.test.ts` quét **toàn bộ repo (kể cả file .md)** để chặn mọi đường dẫn phát hành/ký số của MISA và chặn khóa bí mật — đừng ghi các chuỗi đó vào code hay tài liệu.

**Lưu file = Google Drive của công ty, qua Apps Script** (`src/lib/drive.ts`). Trình duyệt không bao giờ có mã file Drive: tải lên/xem đều đi qua **vé dùng 1 lần** (`app.drive_new_ticket` → `drive_redeem`, Apps Script đổi vé bằng `BACKUP_TOKEN`). File được tra theo bảng tương ứng (`out_invoice_files` cho PDF hóa đơn, `ho_so_scans` cho bản scan); thêm loại file mới phải cập nhật `drive_redeem`. Chỉ Kế toán/Admin/BGĐ được xin vé tải lên. Mã Apps Script nằm trong `drive.ts` (`appsScriptCode`); đổi mã đó thì admin phải dán lại và deploy phiên bản mới trên Google.

**Luồng Kế toán – Hóa đơn** (cần đọc nhiều file mới thấy hết): file xe + nháp APT → đối soát (`lib/doisoat.ts`, `acc_*`) → sale lập yêu cầu xuất HĐ (`out_invoices`, trạng thái `soan → cho_nhap → da_nhap → xac_nhan_ky → da_ky`) → kế toán tạo nháp trên MISA → ký → HĐ đã ký có PDF trên Drive → bộ chứng từ (ĐĐH/BBGN/HĐMB/HĐNT, `lib/hdDocs.ts`) → **chuyển phát bản cứng** (`out_ships`, hạn thu về = ngày nhận + 7 ngày, cảnh báo quá hạn) → **hồ sơ scan + bản cứng** (`ho_so_scans`, `out_doc_state`). Vết hồ sơ ở `out_doc_state` được nhiều tính năng ghi chung qua `app.cp_doc` / `out_doc_mark` — sửa ở chỗ này nhớ kiểm các nơi ghi còn lại.

## Quy ước khi thay đổi

- **Migration**: tạo file mới `supabase/migrations/00NN_vNN.sql` (không sửa file đã chạy), mở đầu bằng `set search_path = public, app, extensions;` và `select public.backup_create('Trước khi cập nhật bản NN');`, kết thúc `reset search_path;`. Hàm dùng `create or replace`, bảng/cột dùng `if not exists` để chạy lại an toàn. Thêm test `supabase/tests/99x_vNN.sql` (theo mẫu `pg_temp.as_user / check / err`), chạy `npm run db:test` rồi `npm run db:bundle` và commit cả `supabase/setup.sql`.
- **Áp migration lên Supabase là thao tác riêng, thủ công** (SQL Editor hoặc MCP Supabase), không nằm trong CI. Làm theo thứ tự: sao lưu (`select public.backup_create(...)`, hệ thống chỉ giữ 3 bản gần nhất) → chạy migration → rồi mới merge code web, vì web cũ chạy được với DB mới nhưng web mới gọi hàm chưa có thì lỗi.
- **Số bản**: mỗi đợt thay đổi là “Bản NN” — đặt tên migration `00NN_vNN.sql`, thêm mục `## Bản NN` vào cuối `README.md`, và nếu có mục tương ứng trong `src/pages/Guide.tsx` thì cập nhật hướng dẫn người dùng.
- **Build**: `public/index.html` và `public/sw.js` chứa token `__BUILD__` được thay khi build (cache service worker); `public/config.js` chỉ chứa URL + khóa publishable của Supabase (công khai, an toàn nhờ RLS). Không bao giờ đưa khóa `service_role` vào frontend.
