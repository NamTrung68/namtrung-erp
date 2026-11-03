# ERP Nam Trung

Hệ thống quản trị nội bộ Công ty TNHH DV&TM Quốc tế Nam Trung: CRM kinh doanh (khách hàng, chăm sóc, chống trùng, báo giá, duyệt giá, bản in + VietQR), chứng từ, chấm công selfie + IP, nghỉ phép, tính lương + hoa hồng lũy tiến, KPI & Bảng Phong Thần, bảng tin, ticket, gọi hỗ trợ, thông báo trong ứng dụng + Telegram.

**Không** quản lý đơn hàng XNK/Logistics — chỉ nhận file Excel "BC Lợi nhuận" để tính hoa hồng.

## Kiến trúc

| Lớp | Công nghệ | Ghi chú |
| --- | --- | --- |
| Giao diện | React 19 + TypeScript, Tailwind, build bằng esbuild → web tĩnh | Chạy trên GitHub Pages, cài được như ứng dụng (PWA) |
| Dữ liệu, đăng nhập, file | Supabase (PostgreSQL, Auth, Storage) | Toàn bộ quyền kiểm tra bằng Row Level Security + hàm SQL |
| Nghiệp vụ | Hàm PostgreSQL (`supabase/migrations`) + công thức báo giá `src/lib/quote-calc.ts` | Server kiểm lại khung giá CẤM/DUYỆT, không tin số từ trình duyệt |
| Tác vụ định kỳ | pg_cron | 05:00 kho khách ngủ + hết hạn báo giá · 09:00 tóm tắt Telegram · 18:05 nhắc báo cáo · ngày 1 cộng phép · 01/07 hủy phép năm cũ |
| Telegram | pg_net gọi Bot API | Token lưu trong bảng bí mật, không ai đọc được qua API |

## Triển khai lần đầu

1. **Supabase** → project `erp-core` → *SQL Editor* → dán toàn bộ `supabase/setup.sql` → *Run*.
2. **Authentication → Sign In / Providers → Email**: tắt *Confirm email* (hệ thống chỉ cho email đã được mời đăng ký; gói free chỉ gửi được vài email/giờ).
   **Authentication → URL Configuration**: *Site URL* = địa chỉ GitHub Pages của app.
3. **Project Settings → API**: lấy *Project URL* và *anon public key*, ghi vào `public/config.js` (hoặc biến repo `SUPABASE_URL`, `SUPABASE_ANON_KEY`). Không bao giờ dùng `service_role` key ở frontend.
4. **GitHub** → *Settings → Pages → Source: GitHub Actions*. Mỗi lần push lên `main`, workflow chạy test rồi deploy.
5. Tài khoản Admin đầu tiên: Supabase → Authentication → Users → Invite user (email đã có trong lời mời sẵn) → mở email, đặt mật khẩu. Sau đó Admin tạo tài khoản nhân sự trong *Nhân sự & quyền* (kèm mật khẩu tạm). Không có tự đăng ký.
6. *Cấu hình → Chấm công*: bấm "Thêm IP hiện tại" khi đang ở văn phòng. *Cấu hình → Telegram*: dán token bot + chat id nhóm, bấm *Gửi tin thử*.

Cập nhật database sau này: tạo file migration mới `supabase/migrations/00NN_*.sql`, chạy trong SQL Editor, commit.

## Phát triển & kiểm thử

```bash
npm install
npm test                 # công thức báo giá (ca vàng BG2610-0003)
npm run db:test          # migrations + RLS + luồng nghiệp vụ trên PostgreSQL 16 (biến PGHOST/PGPORT)
npm run db:bundle        # gộp migrations → supabase/setup.sql
npm run build            # → dist/
```

`tests/e2e/` chứa môi trường giả lập Supabase cục bộ (PostgREST thật + Auth/Storage giả) và kịch bản Playwright cho giao diện.

## Sao lưu

- Gói Free không có backup tự động: định kỳ *Database → Backups* hoặc `pg_dump` bằng connection string (giữ ở nơi an toàn, mã hóa).
- Nâng gói Pro khi database > 300 MB hoặc khi đưa lương thật vào dùng (có backup hằng ngày).

## Phân quyền tóm tắt

- Sale thấy khách, báo giá, KPI, công, phiếu lương **của mình**; Trưởng nhóm/Trưởng phòng thấy toàn bộ cấp dưới (theo "Quản lý trực tiếp").
- Duyệt phá khung giá: Trưởng phòng KD trở lên. Duyệt nghỉ/đơn công: quản lý trực tiếp hoặc người được ủy quyền, HCNS.
- Lương: chính chủ, quản lý cấp trên, HCNS, Kế toán, BGĐ.
- Chứng từ: Chuyên viên trở lên và Kế toán. Nhân viên, Thử việc không xem.

## Sao lưu & khôi phục

- **Database**: *Dữ liệu · Nhật ký → Sao lưu & khôi phục*. Mỗi bản sao lưu là 1 schema `bk_YYYYMMDD_HHMMSS` (giữ 5 bản gần nhất). Mỗi migration nâng cấp tự tạo 1 bản trước khi thay đổi.
  Khôi phục 1 bảng: SQL Editor → `select public.backup_restore_table('bk_…', 'customers');`
- **Tải về máy**: nút "Tải file sao lưu (.zip)" — JSON từng bảng, nên cất lên Google Drive hằng tuần.
- **Phần mềm**: mỗi bản có nhánh `backup-ban-N` trên GitHub. Quay lại: chạy lại workflow *Test & Deploy* trên nhánh đó, hoặc `git revert` các commit sau nó.

## File PDF hóa đơn (bản 20)

- PDF hóa đơn nháp / đã ký từ MISA lưu **kín** trên Google Drive (`ERP_NAMTRUNG/HD nhap/<tháng>/<sale>`, `ERP_NAMTRUNG/HD da ky/<tháng>/<sale>`), không chia sẻ. Supabase chỉ giữ mã file, không trả mã này ra trình duyệt.
- Tên file chuẩn: `NHAP_<MST|CCCD>_<Tổng tiền>_<yyyymmdd>_<stt>.pdf`, `KY_<Ký hiệu>-<Số HĐ>_<MST|CCCD>_<Tổng tiền>.pdf`. Tên khác thì ERP đọc chữ trong PDF (pdf.js tự host ở `vendor/pdfjs`).
- Xem / tải lên đều qua **vé dùng 1 lần** (`out_file_ticket`, `drive_upload_tickets`, hết hạn 2 / 30 phút). Apps Script đổi vé bằng `drive_redeem` kèm `BACKUP_TOKEN`. Không còn `UPLOAD_KEY`.
- Quyền: sale của phiếu, cấp trên theo cây nhân sự, Kế toán / Admin / BGĐ. Tải PDF lên: Kế toán / Admin / BGĐ. Mỗi lần xem ghi `audit_logs` (`VIEW_HD_FILE`).
- Bản nháp mới (v2…) → phiếu quay về "Đã xuất nháp — chờ sale", xác nhận ký bản cũ tự hủy, sale được báo. Bản đã ký → phiếu "Đã ký", điền số HĐ.
- Kiểm thử giao diện: `tests/e2e/v20.cjs` + `tests/e2e/apps-script-mock.mjs` (PDF mẫu để ngoài repo, biến `FX`).

## Kế toán – Hóa đơn (bản 23)

Đặc tả đầy đủ: tài liệu “Đặc tả Kế toán – Hóa đơn (Bản 23)” trên claude.ai. Nâng cấp: chạy `supabase/migrations/0030_v23.sql` trong SQL Editor (tự sao lưu trước khi đổi).

- **Chu kỳ 1 – đối soát nháp APT ↔ file xe:** đọc 2 file theo tiêu đề cột. Ghép theo MÃ KHAI BÁO đầy đủ + SL → lệch thì theo mã đơn MD + SL (ghi “Ghép theo đơn – lệch mã”) → đúng mã mà lệch SL thì cảnh báo sai số. Không ghép theo tên. Biên ngoài 2,5–4% chỉ cảnh báo + giá đề xuất = giá khách ÷ 1,03 (số liền, nút “Copy STT + giá”). Tờ khai nháp không bắt buộc.
- **Chu kỳ 2 – HĐ chính thức APT:** mỗi dòng (mã hàng MISA `HH…-<số HĐ>-<năm>`) ghép về dòng nháp theo tên (bỏ khoảng trắng / dấu chấm cuối) + SL → nhận mã khai báo, đơn, khách, sale, giá khách. Đối chiếu SL / đơn giá / thuế suất từng dòng; lệch → khóa (`out_items.lech`), kế toán ghép lại hoặc chấp nhận kèm lý do.
- **Chu kỳ 3 – yêu cầu xuất HĐ:** biên so với giá APT: < 2% cấm, 2–4% tự do, > 4% “Chờ duyệt giá” (Kế toán / Trưởng phòng / Admin, 1 người). Sale không hủy sau khi kế toán export MISA; “Yêu cầu sửa” → sửa → phiên bản +1. Pháp nhân mặc định theo khách. Lập nhanh theo ID đơn có “Chỉ giữ đơn sạch” + màn xác nhận tổng. Tab “Báo cáo tồn” theo sale.
- Kiểm thử: `tests/doisoat.test.ts` (bản 23), `supabase/tests/99g_v23.sql`.

## Bản 26 (03/11/2026)

- Menu trái dạng nhóm thu gọn (accordion): nhóm của trang đang mở luôn mở, chuyển sang nhóm khác thì mở nhóm đó; trạng thái + vị trí cuộn giữ nguyên khi chuyển trang.
- Trang Hôm nay: nút **Chấm công vào / ra** (máy tính: trên thanh tiêu đề; điện thoại: nút lớn đầu trang).
- Mục mới: *Kế toán – Hóa đơn → Hướng dẫn quy trình* (`#/hd/guide`), *Vận hành → Hướng dẫn tổng quan* (`#/guide`). Nội dung sửa trong `src/pages/Guide.tsx`.
- Phân quyền: *Nhân sự & phân quyền*, *Dữ liệu · Nhật ký* chỉ Admin / BGĐ (chặn cả gõ thẳng URL); `invite_user` + bảng `invites` chỉ Admin / BGĐ. *Duyệt đơn* mở cho mọi người ở chế độ chỉ xem; chỉ người có quyền duyệt mới tạo được ủy quyền (`del_ins`).
- Nâng cấp DB: chạy `supabase/migrations/0033_v26.sql` trong SQL Editor (tự sao lưu trước khi đổi). Kiểm thử: `supabase/tests/99h_v26.sql`.
