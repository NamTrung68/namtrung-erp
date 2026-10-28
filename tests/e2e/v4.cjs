// Bản 4: màn hình đăng nhập, KPI cấu hình, nhập/đồng bộ khách, tồn kho + cảnh báo, kho báo giá, xuất Excel, ảnh chấm công
const { chromium } = require('playwright');
const fs = require('fs');
const BASE = 'http://localhost:8080/';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots5';
const TMP = SHOTS + '/files'; const errors = [];
(async () => {
  fs.mkdirSync(TMP, { recursive: true });
  fs.writeFileSync(TMP + '/khach.csv', '﻿Mã khách hàng,Số điện thoại,Tên khách hàng,Số ngày không có đơn,NVKD\nNT-KH01,0969 300 5302,Chị Linh,12,\nNT-KH02,0977111222,Anh Bình mới,95,Lê Văn Khơi\n');
  fs.writeFileSync(TMP + '/tonkho.csv', 'Mã hàng;Tên hàng;Số lượng tồn;ĐVT\nTK01;Ống phun kim tuyến màu đỏ dài 80cm;350;Chiếc\nTK02;Chai thủy tinh 100ml;1200;Chiếc\n');
  fs.writeFileSync(TMP + '/bgcu.csv', 'Mã BG,Ngày,Tên sản phẩm,HS,SL,Đơn giá tệ,Thuế NK,VAT,Giá xuất\nBG-2024-01,15/03/2024,Máy hàn ống nhựa PPR 220V,85158090,10,95,0,8,450000\n');
  const browser = await chromium.launch();
  const ctxOf = async (viewport = { width: 1440, height: 900 }) => { const ctx = await browser.newContext({ viewport, acceptDownloads: true }); const p = await ctx.newPage();
    p.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(m.text()); }); p.on('pageerror', e => errors.push('PAGEERROR ' + e.message)); return p; };
  const login = async (email, viewport) => { const p = await ctxOf(viewport); await p.goto(BASE); await p.fill('input[type=email]', email); await p.fill('input[type=password]', 'Test1234!'); await p.click('button[type=submit]'); await p.waitForSelector('h2.display', { timeout: 10000 }); return p; };
  const shot = async (p, hash, name, full = false) => { if (hash) { await p.goto(BASE + '#' + hash); await p.waitForTimeout(1100); } await p.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: full }); };
  // Màn hình đăng nhập
  const lp = await ctxOf(); await lp.goto(BASE); await lp.waitForTimeout(1800); await lp.screenshot({ path: SHOTS + '/login.png' });
  const lm = await ctxOf({ width: 390, height: 844 }); await lm.goto(BASE); await lm.waitForTimeout(1500); await lm.screenshot({ path: SHOTS + '/login-m.png', fullPage: true });
  if (!(await lp.textContent('body')).includes('Chiến binh tuần')) errors.push('Thiếu thẻ tích cực');
  // Admin: KPI + màn hình đăng nhập
  const ad = await login('namtrung20266@gmail.com');
  await ad.goto(BASE + '#/admin/settings'); await ad.waitForTimeout(800);
  await ad.click('button:text-is("Lương & KPI")'); await ad.waitForTimeout(600);
  if (!(await ad.locator('input[value="Cuộc gọi có ghi nhật ký"]').count())) errors.push('KPI chưa có cuộc gọi nhật ký');
  await ad.screenshot({ path: SHOTS + '/kpi-cfg.png', fullPage: true });
  await ad.click('button:text-is("Màn hình đăng nhập")'); await ad.waitForTimeout(500);
  await ad.locator('textarea').first().fill('Xin chào Nam Trung!\nHôm nay thật tuyệt!');
  await ad.click('button:has-text("Lưu màn hình đăng nhập")'); await ad.waitForTimeout(900);
  await ad.screenshot({ path: SHOTS + '/login-cfg.png', fullPage: true });
  // Nhập/đồng bộ khách
  await ad.goto(BASE + '#/crm/customers'); await ad.waitForTimeout(900);
  await ad.click('button:has-text("Nhập / đồng bộ")'); await ad.waitForTimeout(300);
  await ad.setInputFiles('div.fixed.inset-0.z-50 input[type=file]', TMP + '/khach.csv'); await ad.waitForTimeout(700);
  await ad.check('div.fixed.inset-0.z-50 input[type=checkbox]');
  await ad.screenshot({ path: SHOTS + '/import-customers.png' });
  await ad.click('div.fixed.inset-0.z-50 button:has-text("Nhập 2 dòng")'); await ad.waitForTimeout(1500);
  const res = await ad.locator('div.fixed.inset-0.z-50').innerText();
  if (!/Cập nhật 1 · tạo mới 1/.test(res)) errors.push('Kết quả nhập khách sai: ' + res.slice(-200));
  await ad.locator('div.fixed.inset-0.z-50 button:text-is("Đóng")').click(); await ad.waitForTimeout(800);
  const body = await ad.textContent('body'); if (!body.includes('NT-KH01') || !/Không đơn 12 ngày/.test(body)) errors.push('Danh sách khách chưa hiện mã HT / số ngày không đơn');
  await ad.screenshot({ path: SHOTS + '/customers.png' });
  const [dl] = await Promise.all([ad.waitForEvent('download'), ad.click('button:has-text("Xuất Excel")')]);
  if (!/\.xlsx$/.test(dl.suggestedFilename())) errors.push('Xuất khách không ra xlsx');
  // Tồn kho
  await ad.goto(BASE + '#/inventory'); await ad.waitForTimeout(700);
  await ad.click('button:has-text("Nhập tồn kho")'); await ad.setInputFiles('div.fixed.inset-0.z-50 input[type=file]', TMP + '/tonkho.csv'); await ad.waitForTimeout(600);
  await ad.click('div.fixed.inset-0.z-50 button:has-text("Nhập 2 dòng")'); await ad.waitForTimeout(1200);
  await ad.locator('div.fixed.inset-0.z-50 button:text-is("Đóng")').click(); await ad.waitForTimeout(600);
  await shot(ad, null, 'inventory');
  // Kho báo giá: nhập dữ liệu cũ
  await ad.goto(BASE + '#/crm/library'); await ad.waitForTimeout(900);
  await ad.click('button:has-text("Nhập báo giá cũ")'); await ad.setInputFiles('div.fixed.inset-0.z-50 input[type=file]', TMP + '/bgcu.csv'); await ad.waitForTimeout(600);
  await ad.screenshot({ path: SHOTS + '/import-archive.png' });
  await ad.click('div.fixed.inset-0.z-50 button:has-text("Nhập 1 dòng")'); await ad.waitForTimeout(1200);
  await ad.locator('div.fixed.inset-0.z-50 button:text-is("Đóng")').click(); await ad.waitForTimeout(500);
  // Sale: báo giá có hàng giống tồn kho → cảnh báo; QR mặc định
  const sale = await login('a@nt.vn');
  await sale.goto(BASE + '#/crm/quotes'); await sale.waitForTimeout(900);
  await sale.locator('table tbody tr').first().click(); await sale.waitForTimeout(1500);
  if (!(await sale.textContent('body')).includes('Giống hàng tồn kho')) errors.push('Không thấy cảnh báo tồn kho trên dòng hàng');
  await sale.screenshot({ path: SHOTS + '/quote-inventory.png' });
  await sale.click('button:has-text("Xem và in")'); await sale.waitForTimeout(800);
  const qr = await sale.locator('input[placeholder="KH1234 chuyen tien"]').inputValue(); if (qr !== 'NT-KH01 chuyen tien') errors.push('Nội dung QR sai: ' + qr);
  await sale.screenshot({ path: SHOTS + '/print.png' });
  await sale.keyboard.press('Escape');
  await sale.goto(BASE + '#/crm/library'); await sale.waitForTimeout(800);
  await sale.fill('input[placeholder^="🔎"]', 'may han ong'); await sale.waitForTimeout(1300);
  if (!(await sale.textContent('body')).includes('Máy hàn ống nhựa PPR')) errors.push('Kho báo giá không tìm được dữ liệu cũ (không dấu)');
  await sale.fill('input[placeholder^="🔎"]', ''); await sale.waitForTimeout(1200);
  await shot(sale, null, 'library');
  const [dl2] = await Promise.all([sale.waitForEvent('download'), sale.goto(BASE + '#/crm/quotes').then(() => sale.waitForTimeout(800)).then(() => sale.click('button:has-text("Xuất Excel")'))]);
  if (!/\.xlsx$/.test(dl2.suggestedFilename())) errors.push('Xuất báo giá không ra xlsx');
  await shot(sale, '/', 'today');
  await shot(sale, '/dashboard', 'dash');
  const lead = await login('lead@nt.vn'); await shot(lead, '/hr/attendance', 'attendance-team', true);
  const m = await login('a@nt.vn', { width: 390, height: 844 });
  for (const h of ['/crm/library', '/inventory', '/crm/customers', '/hr/attendance']) { await m.goto(BASE + '#' + h); await m.waitForTimeout(800); const w = await m.evaluate(() => document.documentElement.scrollWidth); if (w > 392) errors.push(`tràn ngang ${h}: ${w}`); }
  await shot(m, '/crm/library', 'm-library', true);
  await browser.close();
  if (errors.length) { console.log(errors.join('\n')); process.exit(1); }
  console.log('V4 E2E OK');
})().catch(e => { console.log('FAILED', e.message.split('\n')[0], '\n' + errors.join('\n')); process.exit(1); });
