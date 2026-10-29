// Bản 3: dashboard KPI, báo giá (In/Nhân bản, bảng khai APT), hỗ trợ khách có thông tin khách, hồ sơ nhân sự, ảnh chụp desktop + mobile
const { chromium } = require('playwright');
const BASE = 'http://localhost:8080/';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots3';
const errors = [];
(async () => {
  require('fs').mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => {
    const ctx = await browser.newContext({ viewport, permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE);
    await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 });
    return page;
  };
  const shot = async (page, hash, name, full = false) => { if (hash) { await page.goto(BASE + '#' + hash); await page.waitForTimeout(1000); } await page.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: full }); };
  const sale = await login('a@nt.vn');
  await shot(sale, '/dashboard', 'dash-sale');
  await shot(sale, '/crm/customers', 'customers');
  await shot(sale, '/crm/quotes', 'quotes');
  // Nhân bản từ danh sách
  await sale.locator('button:visible:has-text("Nhân bản")').first().click(); await sale.waitForTimeout(1200);
  if (!/crm\/quote\?id=/.test(sale.url())) throw new Error('Nhân bản không mở báo giá mới');
  await sale.locator('textarea').first().fill('Ống phun kim tuyến màu đỏ, không có khí nén, chất liệu giấy bìa cứng, dài 80cm, không hiệu, nsx: Wuhu Sanxi Industrial Co., Ltd., mới 100%');
  await sale.locator('input[placeholder="VD: NT1234"]').fill('nt1234');
  await sale.click('button:has-text("Lưu nháp")'); await sale.waitForTimeout(1200);
  await sale.click('button:has-text("Bảng khai gửi APT")'); await sale.waitForTimeout(400);
  await shot(sale, null, 'apt');
  await sale.click('button:has-text("Sao chép bảng (Excel)")'); await sale.waitForTimeout(200);
  const clipApt = await sale.evaluate(() => navigator.clipboard.readText());
  if (!/STT\tTên hàng\tHS/.test(clipApt) || /NT xuất/.test(clipApt)) throw new Error('Clipboard APT sai: ' + clipApt.slice(0, 120));
  await sale.click('div.fixed.inset-0.z-50 button:text-is("Dán lên hệ thống kê khai")'); await sale.waitForTimeout(300);
  await shot(sale, null, 'apt-sys');
  await sale.click('div.fixed.inset-0.z-50 button:has-text("Sao chép để dán")'); await sale.waitForTimeout(200);
  const rawSys = await sale.evaluate(() => navigator.clipboard.readText()); const clipSys = JSON.parse(rawSys);
  if (Object.keys(clipSys).join(',') !== 'MoTa,DonViTinh,GiaKhaiHQToiThieu,SoLuong,ThueNK,ThueVAT,MaHS,Consignee,TenNhaCungCap,HinhAnh,ChinhSachNhapKhau,Status'
    || clipSys.DonViTinh !== 'Chiếc' || clipSys.GiaKhaiHQToiThieu !== 9040 || clipSys.Status !== 1 || !/Wuhu Sanxi Industrial Co., Ltd/.test(clipSys.TenNhaCungCap)) throw new Error('Clipboard hệ thống sai: ' + rawSys);
  await sale.locator('div.fixed.inset-0.z-50 button:text-is("Đóng")').first().click();
  await sale.goto(BASE + '#/crm/quotes'); await sale.waitForTimeout(800);
  if (!(await sale.textContent('body')).includes('NT1234')) throw new Error('Cột Mã đơn không hiện NT1234');
  await sale.locator('button:visible:has-text("🖨 In")').first().click(); await sale.waitForTimeout(1200);
  const content = await sale.locator('input[placeholder="KH1234 chuyen tien"]').inputValue();
  if (!/chuyen tien$/.test(content)) throw new Error('Nội dung CK mặc định sai: ' + content);
  await shot(sale, null, 'print');
  // Nhờ hỗ trợ lead với khách
  await sale.goto(BASE + '#/crm/customers'); await sale.waitForTimeout(800);
  await sale.locator('table tbody tr').first().click(); await sale.waitForTimeout(800);
  await sale.click('button:has-text("Nhờ hỗ trợ")'); await sale.waitForTimeout(300);
  const modal = sale.locator('[role=dialog], .fixed').last();
  const selects = sale.locator('div[role=dialog] select, .fixed select');
  await sale.screenshot({ path: `${SHOTS}/directive-modal.png` });
  await sale.keyboard.press('Escape');
  await shot(sale, '/crm/daily', 'daily-mine');
  // Lead tạo chỉ đạo cho sale → sale xem bên Hỗ trợ khách có thông tin khách
  const lead = await login('lead@nt.vn');
  await shot(lead, '/dashboard', 'dash-lead');
  await shot(lead, '/crm/daily', 'daily-team', true);
  await lead.goto(BASE + '#/crm/customers'); await lead.waitForTimeout(900);
  await lead.locator('table tbody tr').first().click(); await lead.waitForTimeout(900);
  await lead.click('button:has-text("Chỉ đạo sale")'); await lead.waitForTimeout(400);
  const dsel = lead.locator('div.fixed.inset-0.z-50 select').first(); const opt = await dsel.locator('option').nth(1).getAttribute('value'); await dsel.selectOption(opt);
  await lead.locator('div.fixed.inset-0.z-50 textarea').fill('Gọi lại chốt đơn trong hôm nay');
  await lead.screenshot({ path: `${SHOTS}/directive-lead.png` });
  const send = lead.locator('div.fixed.inset-0.z-50 button:text-is("Gửi")');
  await send.click(); await lead.waitForTimeout(1000);
  await shot(sale, '/support', 'support-list');
  await sale.locator('ul li button').first().click(); await sale.waitForTimeout(1200);
  await shot(sale, null, 'support-detail');
  if (!(await sale.textContent('body')).includes('Lịch sử trao đổi')) errors.push('Thiếu khung thông tin khách trong Hỗ trợ khách');
  for (const r of ['tong_quan', 'kpi', 'can_cham', 'bao_gia']) { await sale.goto(BASE + '#/crm/reports'); }
  await shot(lead, '/crm/reports', 'reports-lead');
  // HCNS: hồ sơ nhân sự
  const hr = await login('hr@nt.vn');
  await shot(hr, '/hr/staff', 'staff');
  await hr.locator('ul li button').filter({ hasText: 'Lê Văn Khơi' }).click(); await hr.waitForTimeout(900);
  await hr.locator('label:has-text("Số CCCD") input').fill('001099000111');
  await hr.click('button:has-text("Lưu hồ sơ")'); await hr.waitForTimeout(800);
  await hr.click('button:text-is("Hợp đồng")'); await hr.waitForTimeout(500);
  await hr.click('button:has-text("+ Hợp đồng mới")'); await hr.waitForTimeout(300);
  await hr.locator('label:has-text("Số hợp đồng") input').fill('01/2026/HĐTV');
  await hr.locator('label:has-text("Lương theo hợp đồng") input').fill('9000000');
  await hr.click('div.fixed button:text-is("Lưu")'); await hr.waitForTimeout(900);
  await hr.click('button:text-is("Thỏa thuận riêng")'); await hr.waitForTimeout(400);
  await hr.click('button:has-text("+ Thỏa thuận")'); await hr.waitForTimeout(300);
  await hr.locator('label:has-text("Tiêu đề") input').fill('Phụ cấp xăng xe 500k/tháng');
  await hr.click('div.fixed button:text-is("Lưu")'); await hr.waitForTimeout(900);
  await hr.click('button:text-is("Giấy tờ")'); await hr.waitForTimeout(400);
  await hr.locator('input[type=file]').first().setInputFiles({ name: 'cccd.jpg', mimeType: 'image/jpeg', buffer: Buffer.from([0xff, 0xd8, 0xff, 0xd9]) });
  await hr.waitForTimeout(1200);
  await shot(hr, null, 'staff-docs');
  await hr.click('button:text-is("Hợp đồng")'); await hr.waitForTimeout(500);
  await shot(hr, null, 'staff-contract');
  if (!(await hr.textContent('body')).includes('01/2026/HĐTV')) errors.push('Không lưu được hợp đồng');
  // Sale xem hồ sơ của mình
  await shot(sale, '/hr/staff', 'my-profile');
  await shot(sale, '/hr/leave', 'leave');
  // Mobile
  const mob = await login('a@nt.vn', { width: 390, height: 844 });
  for (const [h, n] of [['/dashboard', 'm-dash'], ['/crm/quotes', 'm-quotes'], ['/crm/daily', 'm-daily'], ['/crm/reports', 'm-reports'], ['/hr/leave', 'm-leave'], ['/support', 'm-support'], ['/hr/staff', 'm-profile'], ['/hr/timesheet', 'm-timesheet'], ['/news', 'm-news']])
    await shot(mob, h, n, true);
  const mlead = await login('lead@nt.vn', { width: 390, height: 844 });
  await shot(mlead, '/crm/reports', 'm-reports-lead', true); await shot(mlead, '/crm/daily', 'm-daily-team', true);
  const mhr = await login('hr@nt.vn', { width: 390, height: 844 });
  await shot(mhr, '/hr/staff', 'm-staff', true);
  // tràn ngang?
  for (const [pg, nm] of [[mob, 'sale'], [mlead, 'lead'], [mhr, 'hr']]) for (const h of ['/dashboard', '/crm/reports', '/hr/leave', '/crm/daily', '/hr/staff', '/support', '/crm/quotes', '/crm/customers', '/']) {
    await pg.goto(BASE + '#' + h); await pg.waitForTimeout(700);
    const w = await pg.evaluate(() => document.documentElement.scrollWidth); if (w > 392) errors.push(`[${nm}] tràn ngang ${h}: ${w}px`);
  }
  await browser.close();
  if (errors.length) { console.log(errors.join('\n')); process.exit(1); }
  console.log('V3 E2E OK');
})().catch(e => { console.log('FAILED', e.message, '\n' + errors.join('\n')); process.exit(1); });
