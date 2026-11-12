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

## Bản 26 (03/11/2026)

- Menu trái dạng nhóm thu gọn (accordion): nhóm của trang đang mở luôn mở, chuyển nhóm khác thì mở nhóm đó; trạng thái + vị trí cuộn giữ nguyên khi chuyển trang.
- Trang Hôm nay: nút **Chấm công vào / ra** (desktop trên thanh tiêu đề, điện thoại nút lớn đầu trang).
- Mục mới: *Kế toán – Hóa đơn → Hướng dẫn quy trình* (`#/hd/guide`), *Vận hành → Hướng dẫn tổng quan* (`#/guide`). Nội dung sửa trong `src/pages/Guide.tsx`.
- Phân quyền: *Nhân sự & phân quyền*, *Dữ liệu · Nhật ký* chỉ Admin / BGĐ (chặn cả gõ thẳng URL); `invite_user` + bảng `invites` chỉ Admin / BGĐ. *Duyệt đơn* mở cho mọi người ở chế độ chỉ xem; chỉ người có quyền duyệt mới tạo được ủy quyền (`del_ins`).
- Nâng cấp DB: chạy `supabase/migrations/0033_v26.sql` trong SQL Editor (tự sao lưu trước khi đổi). Kiểm thử: `supabase/tests/99h_v26.sql`.

## Bản 27 (03/11/2026)

- Bảng công: sửa lỗi tháng có đơn **vắng theo giờ** không hiện bảng công (`malformed array literal: "G"` trong `app.day_info`). Trang hiện rõ lỗi thay vì "Chưa có dữ liệu".
- Đối soát xe: biên NT **dưới tối thiểu (kể cả âm) hoặc trên mức chặn** (`accounting.bien_chan_max`, mặc định 7%) → chặn, vào "Cần xử lý" của sale; giữa tối đa và mức chặn chỉ cảnh báo. Migration chấm lại các dòng đang "Tự chốt" ngoài khung và báo sale.
- Sale có lựa chọn **Sửa giá khách (chốt luôn)**: biên mới trong khung → dòng chốt ngay, không cần duyệt.
- Tab "Đề xuất giá gửi APT": nút **Xuất Excel**, cột cuối chỉ có giá đề nghị (định dạng số `0`, không dấu phân cách).
- Ẩn menu "Tra cứu yêu cầu · bảng gốc" (trang `#/out` vẫn mở từ nút trong Bàn làm việc kế toán).
- Nâng cấp DB: chạy `supabase/migrations/0034_v27.sql` (tự sao lưu trước). Kiểm thử: `supabase/tests/99i_v27.sql`.

## Bản 31 — Tạo HĐ nháp MISA meInvoice bằng API (05/11/2026)

Chạy **song song** với cách làm tay: chưa bật API (chưa có ClientID) thì ERP chạy y như bản 30 — Excel → nhập MISA → tải PDF nháp → dán mã tra cứu.

- **Kế toán** (Bàn làm việc kế toán, khối ②): tick phiếu → **⚡ Tạo nháp MISA** → cửa sổ *Kiểm tra* (✓/✗ từng phiếu, khác gì so với nháp trước) → *Gửi* theo lô (mặc định 10, tối đa 30) → MISA xem thử từng HĐ → tạo → ERP đọc lại so tiền → lấy PDF về Drive → phiếu “Có nháp”, báo sale.
- **Chi tiết phiếu**: khung MISA — các lần tạo, nguyên văn lỗi MISA, dữ liệu đã gửi; nút Tạo lại / Xóa nháp / Lấy PDF / Kiểm tra MISA / Xem thử.
- **Tự đối soát**: pg_cron 15 phút/lần (7h–21h) gọi hàm `misa` → nháp đã phát hành → ghi số HĐ + mã tra cứu (`TransactionID`), chuyển “Đã ký”, báo sale. Không lấy được mã tra cứu → báo kế toán nhập tay như cũ.
- **Chống trùng**: mỗi phiếu tối đa 1 nháp sống (chỉ mục duy nhất `out_misa_one_active`); RefID = GUID mới mỗi lần, không dùng lại; phiếu đã xuất Excel không tạo API được (trừ khi “Bỏ mốc export” sau khi xóa nháp tay); phiếu có nháp API bị bỏ khỏi file Excel; không hủy phiếu khi còn nháp sống trên MISA.
- **An toàn**: chỉ 7 đường dẫn `/invoiceweb/*` (token, templates, insert, preview, viewrefid, getlist, delete) — `tests/misa-guard.test.ts` quét repo, chặn mọi lời gọi nhóm phát hành / ký số và khóa bí mật trong code.
- **Phân quyền**: bảng `out_misa` RLS giống phiếu xuất HĐ — sale thấy của mình, CSKH thấy sale mình hỗ trợ, trưởng nhóm/phòng thấy cấp dưới, Kế toán/Admin/BGĐ thấy tất cả; chỉ Kế toán/Admin/BGĐ thao tác.

**Cài khi có ClientID** (Admin, 1 lần):
1. Supabase → Edge Functions → *Deploy new function* tên `misa`, dán `supabase/functions/misa/index.ts`, **tắt Verify JWT** (hàm tự kiểm phiên đăng nhập + quyền).
2. Edge Functions → *Secrets*: `MISA_CLIENT_ID`, `MISA_CLIENT_SECRET`, `MISA_TAX_CODE`, `MISA_USERNAME`, `MISA_PASSWORD` (tài khoản tích hợp không có quyền ký/phát hành). Tùy chọn `MISA_BASE_URL`.
3. ERP → Cấu hình → Kế toán – Hóa đơn → khung MISA: *Kiểm tra kết nối* → chọn mẫu HĐ → tick *Bật* → Lưu.

MISA đã xác nhận (06/11/2026): `viewrefid` trả base64 của file PDF · mã tra cứu trong `getlist` là `TransactionID` · token sống 14 ngày, chưa có hàm làm mới (ERP tự lấy token mới sau 13 ngày hoặc khi MISA báo token lỗi) · lô insert có HĐ lỗi thì chỉ HĐ đó bị từ chối (ERP đối chiếu `getlist` để biết HĐ nào đã vào) · giới hạn 200 request/phút (gặp HTTP 429 ERP chờ 5s/15s rồi thử lại).
Mẫu HĐ: dùng mẫu HĐ **thường** (ký hiệu dạng 1C26T…); mẫu máy tính tiền (ký tự thứ 5 = M) bị chặn.

Kiểm thử: `tests/misa.test.ts`, `tests/misa-guard.test.ts`, `supabase/tests/99m_v31.sql`.

## Bản 33 — Menu Pháp nhân nhận HĐ (06/11/2026)

- Kế toán – Hóa đơn → **Pháp nhân nhận HĐ** (`#/hd/phap-nhan`, Kế toán / Admin / BGĐ): nhóm theo username khách; sửa thẳng tên, MST, địa chỉ, email, username trên dòng → Lưu (hoặc “Lưu N dòng đã sửa”); ★ đặt mặc định; xóa; thêm.
- Ô lọc chuẩn hóa: username chưa có khách ERP · MST sai dạng · thiếu địa chỉ · cùng MST khác tên · khách chưa có ★.
- **Xuất Excel** (đúng cột file mẫu) → sửa → **Nạp Excel**: xem trước Mới / Cập nhật / Không đổi / Lỗi trước khi lưu; cùng username + MST thì cập nhật, không xóa pháp nhân đang có.
- Đổi username = chuyển pháp nhân sang khách khác; khách cũ tự lấy pháp nhân còn lại làm ★.
- Phiếu **Lập nhanh theo ID đơn**: mỗi đơn có hàng nút pháp nhân của khách (theo khách ERP hoặc username chưa gắn) — ★ chọn sẵn, bấm để đổi, hoặc “Pháp nhân khác (nhập tay)”.
- Hàm mới: `out_buyers_page`, `out_buyer_save`, `out_buyer_delete`, `out_buyers_for`. Test: `supabase/tests/99n_v33.sql`.

## Bản 35 — XML HĐ đầu vào, tra cứu MST, bộ chứng từ kèm HĐ (08/11/2026)

**1. Nạp HĐ chính thức APT bằng file XML gốc** (Hóa đơn → Nạp HĐ chính thức, nút “📄 File XML gốc” — mặc định)
- Chọn 1 hoặc nhiều file `.xml` (mỗi file 1 HĐ) → điền **Số HĐ** từng file (ERP gợi ý theo XML, sửa được) → đối chiếu nháp APT + file xe y như Excel.
- Mã hàng ERP tự sinh = `{mã khai báo}-{số HĐ}`, VD `M3433-2-2080`. Mã này đi tiếp vào file Excel MISA / API MISA.
- Dòng chưa ghép được nháp → mã tạm `CHUAKB-{số HĐ}-{STT}`; kế toán **ghép tay** xong ERP tự đổi sang mã chuẩn.
- Nạp lại cùng file không tạo trùng (nhận theo số HĐ + ký hiệu + STT dòng). Dòng chiết khấu / ghi chú trong XML được bỏ qua và báo ra.
- Nút “📊 File Excel sổ kế toán” vẫn giữ cách cũ (mã hàng MISA có sẵn).

**2. Tra cứu MST khi lập yêu cầu xuất HĐ** (phiếu lập tay, lập nhanh khi “Pháp nhân khác”, thêm pháp nhân)
- Gõ MST → ERP tra → **tự điền tên + địa chỉ theo đăng ký thuế** (có nút “Giữ thông tin cũ”), cảnh báo: MST sai số kiểm tra, không tồn tại, ngừng hoạt động (khi nhà cung cấp có trạng thái), tên đang nhập khác đăng ký thuế.
- Gửi kế toán khi MST có cảnh báo đỏ → hỏi xác nhận. Kết quả tra lưu trên phiếu (`mst_check`), kế toán thấy nhãn “MST ✓ / ⛔” ở chi tiết phiếu.
- Nhà cung cấp chọn ở hàm máy chủ `supabase/functions/mst` (giao diện không đổi khi đổi nguồn): **VietQR** (miễn phí, chạy ngay, *báo ngừng 01/03/2027*, không có trạng thái hoạt động) · **Xinvoice** (`XINVOICE_CLIENT_ID`, `XINVOICE_API_KEY`) · **MISA** (`MISA_MST_APPID`, `MISA_MST_USERNAME`, `MISA_MST_PASSWORD`, tùy chọn `MISA_MST_TOKEN_URL`, `MISA_MST_LOOKUP_URL`). Có bí mật MISA thì tự dùng MISA trước, lỗi thì lùi về nguồn kế tiếp; ép thứ tự bằng `MST_PROVIDER` (VD `misa,vietqr`).
- Chưa triển khai hàm `mst` thì trình duyệt gọi thẳng VietQR. Triển khai: Edge Functions → Deploy new function tên `mst`, dán file, **tắt Verify JWT**. Kết quả nhớ 7 ngày (bảng `mst_cache`).

**3. Bộ chứng từ đi kèm HĐ đã ký** (Hóa đơn của tôi → tab Đã ký; chi tiết phiếu Đã ký)
- Mỗi HĐ: nút **ĐĐH** (đơn đặt hàng) · **BBGN** (biên bản giao nhận) · **HĐMB/HĐNT** · **⬇ Cả bộ** (.zip).
- Hàng loạt: tìm (gõ ID đơn = cả đơn) → “Chọn tất cả đang lọc” hoặc tick → chọn loại chứng từ → **⬇ Xuất N HĐ (.zip)** (mỗi HĐ 1 thư mục; HĐ nguyên tắc 1 bản / mã).
- Khách đã ký HĐ nguyên tắc (có **Mã HĐ nguyên tắc** trong Pháp nhân) → biên bản căn cứ HĐNT, không tạo HĐ mua bán. Chưa có → mỗi HĐ 1 HĐ mua bán số `dd/mm/yyyy/HĐMBHH/NT/{số HĐ}`.
- Ngày mọi chứng từ = **ngày HĐ đã ký**; số đơn hàng = số HĐ; HĐNT dùng ngày ký HĐNT (trống thì đọc từ đầu mã `28/08/2026/...`).
- Pháp nhân thêm: Người đại diện, Chức vụ, Địa chỉ giao hàng, Mã + ngày HĐ nguyên tắc (sửa trên dòng, Xuất / Nạp Excel có cột mới). Thiếu người đại diện khi xuất → ERP hỏi 1 lần, lưu vào pháp nhân (sale được điền đại diện/chức vụ, mã HĐNT chỉ kế toán).
- Mẫu Word: `public/mau-hd/{ddh,bbgn,hdmb,hdnt}.docx` (mẫu của anh, đã gắn chỗ điền `{{...}}`). Đổi điều khoản: sửa file mẫu, giữ nguyên các `{{...}}`.

Hàm mới: `out_docs_data`, `out_buyer_doc_info`, `out_invoice_mst`; sửa `out_items_import`, `out_item_relink`, `out_buyer_save`, `out_buyers_page`, `out_buyers_import_v2`. Kiểm thử: `tests/hd35.test.ts`, `supabase/tests/99o_v35.sql`.

## Bản 36 — Tra MST qua Xinvoice, MST nổi bật, biểu tượng + vết hồ sơ chứng từ, Pháp nhân cho Sale/CSKH (08/11/2026)

- **Tra MST: Xinvoice** (dữ liệu Tổng cục Thuế, bản miễn phí, không cần khóa) gọi thẳng từ trình duyệt; VietQR chỉ còn là dự phòng khi Xinvoice mất kết nối.
  Chỉ “NNT đang hoạt động” (kể cả “… đã được cấp GCN ĐKT”) là xanh; ngừng / tạm ngừng / chấm dứt / đóng MST / không hoạt động tại địa chỉ → **đỏ**, mọi tình trạng khác → **vàng**.
  Giới hạn **10 lần / 30 giây cho cả văn phòng**: ERP nhớ kết quả 7 ngày dùng chung (`mst_cache_get` / `mst_cache_put`), tự giãn nhịp, vượt giới hạn thì báo “đợi ~30 giây rồi Tra lại”.
- **MST nổi bật** ở mọi danh sách Kế toán – Hóa đơn (Hóa đơn của tôi, Bàn làm việc kế toán, chi tiết phiếu, Tạo nháp MISA): số to đậm, **⧉ copy**, **🔍 lấy thông tin** (tên, địa chỉ, tình trạng, chấm màu cảnh báo, copy tên / địa chỉ).
- **Chứng từ dạng biểu tượng**: 🧾 ĐĐH · 🚚 BBGN · 📜 HĐMB / 🤝 HĐNT · 🗂️ Cả bộ; ô đã tải có ✓ (rê chuột xem số lần, lúc nào).
- **Vết hồ sơ** (`out_doc_state`, `out_doc_mark`): ○ Chưa xử lý → ⬇ Đã tải (tự ghi) → ✉ Đã gửi khách → ✓ Đủ hồ sơ (tải bản ký / scan lên Google Drive `Ke toan/Chung tu da ky/yyyy-mm`, lưu link 📎). Tab Đã ký lọc theo trạng thái; chọn nhiều → “✉ Đã gửi khách”. Mỗi lần đổi trạng thái ghi nhật ký `out_events`.
- **Pháp nhân nhận HĐ** mở cho Sale / CSKH / TN / TP: máy chủ chỉ trả pháp nhân của **khách mình phụ trách** (chủ khách trong phạm vi; CSKH theo sale được hỗ trợ). Được sửa / thêm / ★ / xóa pháp nhân chưa dùng; **mã + ngày HĐNT và Nạp Excel chỉ kế toán / admin / BGĐ**. Nút 🔍 cạnh MST để tra và điền nhanh.

Kiểm thử: `tests/hd36.test.ts`, `supabase/tests/99p_v36.sql`.

## Bản 37 — Ảnh sản phẩm trong báo giá, đơn quên chấm đến / quên chấm về (11/11/2026)

Nâng cấp: chạy `supabase/migrations/0044_v37.sql` trong SQL Editor (tự sao lưu trước khi đổi).

- **Báo giá → ảnh từng dòng hàng** (không bắt buộc): cột “Ảnh” trước tên hàng — bấm chọn, dán (Ctrl+V) hoặc kéo thả; ảnh tự nén ~200 KB, lưu bucket công khai `quote-images/<người lập>/…` (cột `quotation_lines.image`).
  Bản in gửi khách có cột Ảnh 100×100 px (chỉ hiện khi có ít nhất 1 dòng có ảnh). Nhân bản / lấy mẫu từ Thư viện giữ ảnh. Ảnh **không** tính vào dấu giá → đổi ảnh không phải duyệt giá lại.
- **Đơn công**: thêm 2 loại
  - *Xác nhận chấm công muộn (quên chấm đến)* — nhân viên chọn ngày + giờ vào. Người duyệt thấy giờ khai, sửa theo camera nếu sai → giờ chốt là **giờ đến chính thức** (thay cả lần chấm muộn) để tính đi muộn, chuyên cần, lương.
  - *Xác nhận quên chấm công về* — chọn ngày + giờ về; người duyệt sửa nếu sai → giờ ra chính thức (tính về sớm).
  - Gửi được cho ngày đã qua trong 30 ngày (`attendance.forgot_back_days`), không gửi cho tháng đã chốt lương, không trùng loại/ngày. Vẫn tính chung giới hạn quên chấm / tháng và điểm chuyên cần như đơn xác nhận công cũ.
  - Lịch sử “Chấm công của tôi” hiện giờ theo đơn đã duyệt (ghi “theo đơn”).

Kiểm thử: `supabase/tests/99q_v37.sql`, `tests/e2e/v37.cjs`.

## Bản 38 — Tự tải PDF HĐ đã ký, nút “Tải HĐ”, Cả bộ = ĐĐH + BBGN + HĐ (11/11/2026)

Nâng cấp:
1. Chạy `supabase/migrations/0045_v38.sql` trong SQL Editor (tự sao lưu trước khi đổi).
2. Supabase → *Edge Functions* → *Deploy a new function* → tên **`hdky`** → dán toàn bộ `supabase/functions/hdky/index.ts` → *Deploy* → vào *Details* **tắt “Verify JWT”** (hàm tự kiểm phiên đăng nhập + quyền với phiếu). Không cần bí mật nào.

- Hàm `hdky` tải PDF từ link tra cứu công khai của meInvoice (`DownloadHandler.ashx?Type=pdf&ext=QXVLM59J&Code={mã tra cứu}`; đổi được bằng `settings.accounting.tra_cuu_dl_url`, chỉ chấp nhận https://…meinvoice.vn) → kiểm file đúng PDF → lưu Google Drive `ERP_NAMTRUNG/HD da ky/<tháng>/<sale>/KY_<số HĐ>_<MST>_<tổng tiền>_<khách>.pdf` → gắn phiếu (file “ky”). Không dùng tài khoản / API MISA.
- **Tự động**: kế toán điền mã tra cứu (hoặc MISA tự dò ra “Đã ký”) → CSDL gọi ngay `hdky` (pg_net); lịch `nt_hdky` 15 phút/lần (7h–22h) quét HĐ còn thiếu PDF. Mã tra cứu sai → ghi lỗi, thử lại sau 1 giờ, tối đa 5 lần (`app.ky_fetch_fail`).
- **Hóa đơn của tôi → Đã ký**: dưới mã tra cứu có **⬇ Tải HĐ (PDF)** (lấy từ Drive; chưa có thì tải ngay). Nút **🗂️ Cả bộ** = Đơn đặt hàng + Biên bản giao nhận + HĐ đã ký (PDF) trong 1 file .zip; không lấy được HĐ → nhắc bấm link mã tra cứu, cho tải trước ĐĐH + BBGN. Xuất hàng loạt có thêm lựa chọn “HĐ đã ký (PDF)”. HĐ mua bán / HĐ nguyên tắc vẫn tải riêng ở biểu tượng 📜 / 🤝.
- Quyền: sale của phiếu, cấp trên theo cây, Kế toán / Admin. Gắn file chỉ hàm máy chủ làm được (service_role); mã file Drive không ra trình duyệt.

Kiểm thử: `supabase/tests/99r_v38.sql`, `tests/e2e/v38.cjs` (chạy thật hàm `hdky` bằng Deno, meInvoice + Apps Script giả lập).

## Bản 39 — Ngày chứng từ = ngày in trên HĐ đã ký; ĐĐH "Ngày giao hàng dự kiến" (11/11/2026)

- Trước: ngày trên ĐĐH / BBGN / HĐ mua bán = ngày kế toán / hệ thống đánh dấu "Đã ký" (có thể chậm 1–2 ngày so với ngày HĐ).
- Nay: trước khi xuất chứng từ, ERP đọc "Ngày … tháng … năm …" (cả mẫu song ngữ "Ngày (Date) … tháng (month) …") trong PDF HĐ đã ký lưu trên Drive → dùng ngày đó và sửa luôn ngày HĐ trên phiếu (`out_ky_fix_ngay`, ghi nhật ký `out_events`). Không đọc được PDF thì giữ ngày cũ.
- Mẫu ĐĐH: bỏ dòng "Ngày đặt hàng"; "Ngày giao hàng" → "Ngày giao hàng dự kiến" (= ngày HĐ).
- Nâng cấp: `supabase/migrations/0046_v39.sql`. Kiểm thử: `supabase/tests/99s_v39.sql`, `tests/hdfile.test.ts`, `tests/e2e/v38.cjs` với `PDF_FILE` (PDF có dòng ngày).

## Bản 40 — Chuyển phát HĐ đã ký, theo dõi thu về bản ký (giai đoạn 1: nhập tay) (11/11/2026)

Nâng cấp: chạy `supabase/migrations/0048_v40.sql` trong SQL Editor (tự sao lưu trước khi đổi). Không cần hàm máy chủ mới.

- **Hóa đơn của tôi → tab Đã ký**: tick HĐ → **📦 Gửi chuyển phát** → ERP gom theo khách (1 khách = 1 phiếu `CPxxxxx`, cùng sale), gợi ý người nhận / SĐT / địa chỉ từ *Pháp nhân nhận HĐ* (rồi tới người liên hệ của khách), tick “Lưu vào pháp nhân” để lần sau tự điền.
- **Tab 📦 Chuyển phát HĐ** (sale) và màn **Chuyển phát HĐ** `#/hd/cp` (kế toán / quản lý / BGĐ, có nút *+ Tạo phiếu gửi*): Chờ gửi → **Đã gửi** (ngày gửi, mã vận đơn) → **Khách đã nhận** (ngày nhận; báo sale + CSKH hỗ trợ nhắc khách gửi lại 1 bản; hạn thu về = ngày nhận + 7 ngày) → **Đã thu về** (từng HĐ hoặc cả phiếu). Có Báo hoàn / thất lạc (HĐ mở lại để gửi phiếu mới), Hủy, Lùi 1 bước khi bấm nhầm.
- **Cảnh báo quá hạn**: lịch `nt_ship_remind` 8h15 sáng thứ 2 – thứ 7 báo sale + CSKH + quản lý trực tiếp, nhắc lại theo chu kỳ (mặc định 3 ngày).
- **Bộ lọc**: trạng thái (đang theo dõi, chờ gửi, đã gửi, khách đã nhận, sắp hạn, quá hạn, đã thu về, hoàn, hủy), tìm mã phiếu / mã vận đơn / số HĐ / khách / SĐT, sale, khoảng ngày gửi / nhận / thu về / tạo; xuất Excel.
- **Vết hồ sơ**: phiếu Đã gửi → HĐ “✉ đã gửi khách”; HĐ thu về → “✓ đã có bản ký” (bỏ xác nhận chỉ gỡ khi chưa lưu file scan). Mỗi thao tác ghi `out_ship_events` và lịch sử phiếu xuất HĐ (`out_events`, action `chuyen_phat`).
- **Pháp nhân nhận HĐ**: thêm *Người nhận chuyển phát* + *SĐT nhận* (cột `out_buyers.nguoi_nhan`, `sdt_nhan`), bộ lọc “Thiếu SĐT / địa chỉ nhận chuyển phát”, có trong Excel xuất.
- **Cấu hình → Kế toán – Hóa đơn → 📦 Chuyển phát HĐ** (`settings.chuyen_phat`): tên / SĐT / địa chỉ gửi, hãng mặc định, hạn thu về, chu kỳ nhắc, ngưỡng “sắp hạn”. Kế toán sửa được.
- Quyền: sale của HĐ + cấp trên theo cây + CSKH được giao, Kế toán / Admin / BGĐ. Ghi chỉ qua hàm (`out_ship_create`, `out_ship_act`, `out_ship_thu`).
- Giai đoạn 2 (chờ ViettelPost cấp quyền tích hợp): tạo vận đơn + tính cước qua API, nhận webhook trạng thái → tự ghi ngày gửi / ngày khách nhận (cột `out_ships.api` để sẵn).

Kiểm thử: `supabase/tests/99t_v40.sql`.

## Bản 41 — Lưu trữ hồ sơ HĐ: bản scan lên Google Drive + bản cứng (11/11/2026)

Nâng cấp: chạy `supabase/migrations/0049_v41.sql` trong SQL Editor (tự sao lưu trước khi đổi). Apps Script Drive **không phải cập nhật** (`drive_redeem` tự tra thêm bảng scan).

- **Bảng `ho_so_scans`**: mỗi file scan gắn 1 HĐ (bộ chứng từ) hoặc 1 pháp nhân (HĐ nguyên tắc / mua bán). 1 file có thể gồm nhiều loại giấy (`kinds`: hd, ddh, bbgn, hdmb, hdnt, khac). Mã file Drive không ra trình duyệt; xem qua vé dùng 1 lần (`ho_so_scan_ticket`, nhật ký `VIEW_SCAN`).
- **Đủ hồ sơ** (`ho_so_status`): HĐ đã ký + ĐĐH + BBGN + (HĐNT của pháp nhân nếu có mã HĐNT, ngược lại HĐMB của HĐ). Chip 🗂 dưới mỗi HĐ ở tab Đã ký: chưa scan / thiếu loại nào / đủ, 🗄 = đã cất bản cứng. Bộ lọc “Lưu trữ” theo các trạng thái này.
- **Tải scan** (Kế toán / Admin / BGĐ — như quyền lưu Drive hiện có): PDF, hoặc nhiều ảnh / chụp điện thoại → ERP tự gộp 1 PDF (A4, `src/lib/hoso.ts`, không thư viện). Lưu `ERP_NAMTRUNG/Ho so khach hang/<MST> - <Tên>/HD <năm>/` hoặc `…/Hop dong NT-MB/`.
- Tải scan của HĐ đang trong phiếu chuyển phát chưa thu về → **tự xác nhận “Đã thu về”**; HĐ thành “✓ đã có bản ký”. Nút **📎 scan** trên từng HĐ ở màn Chuyển phát.
- **Pháp nhân nhận HĐ**: nút 🗂 (số bản scan; vàng = đã ký HĐNT nhưng chưa có scan) → hồ sơ pháp nhân, tải scan HĐNT / HĐMB.
- **Bản cứng**: `out_doc_state.cung_at / cung_vi_tri`, đánh dấu hàng loạt “🗄 Cất bản cứng” + vị trí tủ / bìa (`out_doc_cung`).
- **Trang mới** `#/hd/luu-tru` “Lưu trữ HĐ đã ký” cho Kế toán / BGĐ (500 HĐ mới nhất theo bộ lọc sale / số HĐ đầu vào), cùng giao diện tab Đã ký.
- Sửa: mục “Tải bản đã ký lên” cũ hiện cho cả sale nhưng sale không có quyền lưu Drive (báo lỗi) → nay chỉ hiện với Kế toán / Admin / BGĐ.

Kiểm thử: `supabase/tests/99u_v41.sql`, `tests/hoso.test.ts`.

## Bản 43 — Sửa tính phút đi muộn / về sớm, gặp khách theo giờ (12/11/2026)

- Đơn "Đi muộn, về sớm, ra ngoài" đã duyệt bị cộng 2 lần (giờ xin + phút về sớm thực tế). Nay gộp khoảng: phút vắng = (vắng thực tế ∪ giờ xin) trong khung giờ làm.
- "Công tác, gặp khách" chọn được **Theo giờ** (đi gặp khách rồi về thẳng): khoảng đó tính là giờ làm, không trừ quỹ. Gặp khách buổi sáng / chiều chỉ che buổi đó.
- "Chấm công của tôi" lấy phút muộn / sớm từ máy chủ (`att_my_month`) — trước tự tính từ 08:00 nên người nghỉ buổi sáng bị báo muộn hơn 300 phút.
- Nâng cấp: `supabase/migrations/0051_v43.sql`. Kiểm thử: `supabase/tests/99v_v43.sql`.
