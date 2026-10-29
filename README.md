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
