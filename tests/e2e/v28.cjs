// v28: CSKH hỗ trợ sale, sửa giá dòng đã chốt, khối ② kế toán (đã export vẫn hiện), #/out chuyển hướng, duyệt quên chấm có giờ vào, lương tạm tính, phép theo tháng
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const SHOTS = process.env.SHOTS || '/tmp/v28-shots';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
require('fs').mkdirSync(SHOTS, { recursive: true });
(async () => {
  sql(`insert into public.invites(email, full_name, roles, job_level) values ('cskh@nt.vn','Nguyễn CSKH','{cskh}','nhan_vien')`);
  sql(`insert into auth.users(email) values ('cskh@nt.vn')`);
  const A = sql("select id from profiles where email='a@nt.vn'"); const B = sql("select id from profiles where email='b@nt.vn'"); const CS = sql("select id from profiles where email='cskh@nt.vn'");
  // dòng HĐ username thiếu số 0 → hồ sơ khách 0906099063 → tự gắn
  sql(`insert into out_items(ma_hang, part, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id, username, so_hd_vao) values ('HH00001-2899-2026', 1, 'Công tắc điều khiển', 'Chiếc', 0.08, 120, 250000, 'MD2461', '${A}', '906099063', '2899')`);
  sql(`insert into customers(code, contact_name, phone, customer_type, source, owner_id, sys_username) values
    ('KH28A', 'Khách của A', '+84 912 000 281', 'nha_buon', 'tu_tim_zalo', '${A}', '0906099063'),
    ('KH28B', 'Khách của B', '+84 912 000 282', 'nha_buon', 'tu_tim_zalo', '${B}', 'khachb')`);
  sql(`insert into acc_trucks(id, name) values ('00000000-0000-0000-0028-00000000e001', 'Xe e2e 28');
    insert into acc_lines(id, truck_id, line_key, luong, status, level, sale_id, md, apt_stt, hh, ten_apt, gia_nhap, gia_ap_dung, gia_khach, bien_nt, gia_de_xuat, sl_apt, issues)
    values ('00000000-0000-0000-0028-00000000e0a1', '00000000-0000-0000-0028-00000000e001', 'E1', 'A', 'ok', 3, '${A}', 'MD2801', 1, 'HH001', 'Bình giữ nhiệt inox', 1000, 1000, 1050, 0.05, 1019, 10, '{}')`);
  ok(sql("select username || '|' || (customer_id is not null) from out_items where ma_hang='HH00001-2899-2026'") === '0906099063|true', 'username SĐT mất số 0 → chuẩn hóa + tự gắn khách');

  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => {
    const ctx = await browser.newContext({ viewport, hasTouch: viewport.width < 600, isMobile: viewport.width < 600, acceptDownloads: true }); const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|Failed to load resource|functions\/v1\/push/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE); await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 }); return page;
  };

  // 1) Admin phân công CSKH
  const ad = await login('namtrung20266@gmail.com');
  await ad.goto(BASE + '#/admin/users'); await ad.waitForTimeout(1500);
  ok(await ad.locator('text=Phân công CSKH hỗ trợ sale').count() >= 1, 'thẻ Phân công CSKH ở Nhân sự & phân quyền');
  await ad.locator('tr', { hasText: 'Nguyễn CSKH' }).locator('button:has-text("Phân công")').click(); await ad.waitForTimeout(800);
  const dlg = ad.locator('div.fixed.inset-0.z-50').last();
  await dlg.locator('button', { hasText: sql("select full_name from profiles where email='a@nt.vn'") }).first().click();
  await ad.screenshot({ path: SHOTS + '/1-phan-cong.png' });
  await dlg.locator('button:has-text("Lưu phân công")').click(); await ad.waitForTimeout(1500);
  ok(sql(`select count(*) from support_assignments where cskh_id='${CS}' and sale_id='${A}' and kind='chinh' and ended_at is null`) === '1', 'lưu phân công chính CSKH → sale A');

  // 2) CSKH: thấy khách của A, không thấy của B; sửa giá dòng đã chốt
  const cs = await login('cskh@nt.vn');
  await cs.goto(BASE + '#/crm/customers'); await cs.waitForTimeout(1500);
  ok(await cs.locator('text=Khách của A').count() >= 1 && await cs.locator('text=Khách của B').count() === 0, 'CSKH thấy khách của sale được giao, không thấy sale khác');
  await cs.screenshot({ path: SHOTS + '/2-cskh-khach.png' });
  await cs.goto(BASE + '#/acc/mine'); await cs.waitForTimeout(1500);
  await cs.locator('button', { hasText: 'Đề xuất giá gửi APT' }).first().click(); await cs.waitForTimeout(800);
  ok(await cs.locator('button:has-text("Sửa giá khách (chốt luôn)")').count() >= 1, 'dòng đã tự chốt có nút Sửa giá khách');
  await cs.locator('button:has-text("Sửa giá khách (chốt luôn)")').first().click(); await cs.waitForTimeout(300);
  const gi = cs.locator('input[inputmode=numeric]').first(); await gi.fill('1030'); await cs.waitForTimeout(300);
  await cs.screenshot({ path: SHOTS + '/3-sua-gia.png' });
  await cs.locator('button:has-text("Gửi")').last().click(); await cs.waitForTimeout(1500);
  ok(sql("select gia_khach::int || '|' || coalesce(gia_de_xuat::text,'null') from acc_lines where id='00000000-0000-0000-0028-00000000e0a1'") === '1030|null', 'CSKH sửa giá khách 1030 → biên 3%, hết đề xuất');
  await cs.goto(BASE + '#/hr/approvals'); await cs.waitForTimeout(1000);
  ok(await cs.locator('text=Chế độ').count() >= 1, 'CSKH ở Duyệt đơn chỉ xem');

  // 3) #/out → màn hình mới; khối ② kế toán hiện cả phiếu đã export chưa có PDF
  sql(`insert into out_invoices(id, code, sale_id, buyer_name, tax_code, status, misa_at) values
    ('00000000-0000-0000-0028-00000000f001', 'XHD28001', '${A}', 'CÔNG TY ĐÃ EXPORT', '0101010101', 'cho_nhap', now()),
    ('00000000-0000-0000-0028-00000000f002', 'XHD28002', '${A}', 'CÔNG TY CHƯA EXPORT', '0202020202', 'cho_nhap', null)`);
  const kt = await login('kt@nt.vn');
  await kt.goto(BASE + '#/out?inv=00000000-0000-0000-0028-00000000f001'); await kt.waitForTimeout(2000);
  ok(kt.url().includes('#/hd/kt'), '#/out của kế toán → Bàn làm việc kế toán');
  ok(await kt.locator('text=XHD28001').count() >= 1, 'mở đúng phiếu theo ?inv=');
  await kt.keyboard.press('Escape'); await kt.goto(BASE + '#/hd/kt'); await kt.waitForTimeout(1500);
  ok(await kt.locator('text=Đã export — chờ nạp PDF nháp (1)').count() === 1, 'khối ② hiện phiếu đã export chờ PDF');
  ok(await kt.locator('button:has-text("Export file nhập MISA (1)")').count() === 1, 'đếm 1 phiếu chưa export');
  ok(await kt.locator('text=Tra cứu yêu cầu / bảng gốc').count() === 0, 'bỏ nút Tra cứu (trang cũ)');
  await kt.screenshot({ path: SHOTS + '/4-ke-toan.png', fullPage: true });
  const s = await login('a@nt.vn');
  await s.goto(BASE + '#/out'); await s.waitForTimeout(1500);
  ok(s.url().includes('#/hd') && !s.url().includes('#/hd/kt'), '#/out của sale → Hóa đơn của tôi');

  // 4) Quên chấm: quản lý duyệt phải nhập giờ vào; bảng công có lương tạm tính; phép theo tháng
  sql(`insert into attendance_requests(id, profile_id, kind, work_date, reason) values ('00000000-0000-0000-0028-00000000c001', '${A}', 'xac_nhan_cong', app.vn_today(), 'Quên chấm công sáng nay')`);
  sql(`update profile_private set base_salary = 8000000 where profile_id = '${A}'`);
  const ld = await login('lead@nt.vn');
  await ld.goto(BASE + '#/hr/approvals'); await ld.waitForTimeout(1500);
  await ld.locator('tr', { hasText: 'Quên chấm công sáng nay' }).locator('button:has-text("Duyệt")').click(); await ld.waitForTimeout(800);
  ok(await ld.locator('text=Giờ vào thực tế').count() >= 1, 'duyệt quên chấm → hỏi giờ vào thực tế');
  await ld.locator('input[type=time]').first().fill('08:25'); await ld.screenshot({ path: SHOTS + '/5-gio-vao.png' });
  await ld.locator('div.fixed.inset-0.z-50 button:has-text("Duyệt")').last().click(); await ld.waitForTimeout(1500);
  ok(sql("select status || '|' || to_char(confirm_in, 'HH24:MI') from attendance_requests where id='00000000-0000-0000-0028-00000000c001'") === 'da_duyet|08:25', 'lưu giờ vào 08:25');
  await ld.goto(BASE + '#/hr/timesheet'); await ld.waitForTimeout(2000);
  ok(await ld.locator('th:has-text("Lương tạm tính")').count() === 1, 'bảng công có cột Lương tạm tính');
  await ld.screenshot({ path: SHOTS + '/6-bang-cong.png' });
  await s.goto(BASE + '#/hr/leave'); await s.waitForTimeout(1500);
  ok(await s.locator('text=Phép tích lũy đến nay').count() === 1, 'trang Xin nghỉ hiện phép tích lũy theo tháng');
  await s.goto(BASE + '#/account'); await s.waitForTimeout(1000);
  ok(await s.locator('text=Thông báo & cài ứng dụng').count() === 1, 'trang Tài khoản có mục thông báo');
  await browser.close();
  if (errors.length) { console.log(errors.join('\n')); process.exit(1); }
  console.log('V28 E2E OK');
})().catch(e => { console.log('FAILED', e.message); console.log(errors.join('\n')); process.exit(1); });
