// Kiểm thử giao diện: đăng nhập, mở từng trang, chạy luồng chính, ghi lỗi console
const { chromium } = require('playwright');
const BASE = 'http://localhost:8080/';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots';
const errors = [];
(async () => {
  require('fs').mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => {
    const ctx = await browser.newContext({ viewport, permissions: ['camera'] });
    const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE);
    await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]');
    await page.waitForSelector('h2.display', { timeout: 10000 });
    return page;
  };
  const visit = async (page, hash, shot) => {
    await page.goto(BASE + '#' + hash); await page.waitForTimeout(900);
    const bad = await page.$('text=/Không tìm thấy|PAGEERROR/');
    if (shot) await page.screenshot({ path: `${SHOTS}/${shot}.png`, fullPage: false });
  };
  // ---- Admin
  const admin = await login('namtrung20266@gmail.com');
  for (const [h, s] of [['/', 'today'], ['/dashboard', 'dash-admin'], ['/hr/timesheet', 'timesheet'], ['/hr/leave', 'leave-admin'], ['/admin/users', 'users'], ['/admin/settings', 'settings'], ['/admin/data', 'data'], ['/hr/payroll', 'payroll'], ['/kpi', 'kpi'], ['/news', null], ['/tickets', null], ['/support', null], ['/docs', null], ['/hr/approvals', null], ['/crm/reports', 'reports']])
    await visit(admin, h, s);
  // cấu hình IP + telegram tab render
  await visit(admin, '/admin/settings', null);
  // ---- Sale: tạo khách, ghi chăm sóc, báo giá BG2610-0003
  const sale = await login('a@nt.vn');
  await visit(sale, '/crm/customers', null);
  await sale.click('text=Thêm khách hàng');
  const panel = sale;
  const fill = async (label, val) => { await panel.locator(`label:has-text("${label}") input`).first().fill(val); };
  await fill('Người liên hệ', 'Chị Linh'); await fill('Tên công ty / shop', 'GIADOAN'); await fill('Số điện thoại', '0969 300 5302');
  await panel.locator('label:has-text("Loại khách") select').selectOption('nha_may');
  await panel.locator('label:has-text("Nguồn khách") select').selectOption('tu_tim_zalo');
  await sale.click('text=Lưu khách hàng'); await sale.waitForTimeout(1200);
  await sale.screenshot({ path: `${SHOTS}/customer.png` });
  await sale.locator('button:text-is("Ghi chăm sóc")').last().click(); await sale.waitForTimeout(300);
  await sale.click('button:has-text("Xin báo giá")');
  await sale.fill('textarea[placeholder^="Khách nhập"]', 'Khách nhập chai thủy tinh 100k chiếc, cần HĐ VAT');
  await sale.screenshot({ path: `${SHOTS}/care-modal.png` });
  await sale.click('button:has-text("Lưu chăm sóc")'); await sale.waitForTimeout(1200);
  await sale.locator('button:has-text("Tạo báo giá")').last().click(); await sale.waitForTimeout(1500);
  const setNum = async (label, v) => { const el = sale.locator(`label:has-text("${label}") input`).first(); await el.fill(String(v)); };
  await setNum('Ship nội địa TQ', 8400); await setNum('Cân nặng cả lô', 13890); await setNum('Đơn giá / kg', 3500); await setNum('Số khối cả lô', 19.6); await setNum('Đơn giá / m³', 900000);
  await setNum('Phí dịch vụ (%)', 1.2); await setNum('Phí ủy thác (%)', 1);
  const row = sale.locator('tbody tr').first(); const inputs = row.locator('input');
  await row.locator('textarea').fill('Chai thủy tinh kèm nắp'); await inputs.nth(2).fill('100000'); await inputs.nth(3).fill('2'); await inputs.nth(5).fill('8');
  await sale.waitForTimeout(400);
  const txt = await sale.locator('aside').nth(1).innerText();
  for (const v of ['803.000.000', '33.726.000', '48.615.000', '904.000.000', '976.320.000', '976.337.000', '852.000.000', '57.170.000']) if (!txt.includes(v)) errors.push('Báo giá thiếu số ' + v);
  await sale.screenshot({ path: `${SHOTS}/quote.png`, fullPage: true });
  await sale.click('button:has-text("Lưu và gửi")'); await sale.waitForTimeout(1800);
  await sale.screenshot({ path: `${SHOTS}/quote-sent.png` });
  await sale.click('button:has-text("Xem và in")'); await sale.waitForTimeout(800);
  await sale.screenshot({ path: `${SHOTS}/quote-print.png`, fullPage: false });
  await sale.keyboard.press('Escape');
  // nghỉ phép & chấm công
  await visit(sale, '/hr/leave', 'leave');
  await visit(sale, '/hr/attendance', 'attendance');
  await sale.click('text=Tôi đồng ý'); await sale.waitForTimeout(1000);
  await visit(sale, '/crm/daily', null);
  await sale.locator('label:has-text("Kết quả trong ngày") textarea').fill('Gọi 30 khách, 2 khách xin báo giá'); await sale.click('button:has-text("Nộp báo cáo")'); await sale.waitForTimeout(800);
  await visit(sale, '/dashboard', 'dash-sale'); await visit(sale, '/crm/reports', 'reports-sale'); await visit(sale, '/tickets', null); await visit(sale, '/support', null);
  await visit(sale, '/kpi', null); await visit(sale, '/hr/payslips', null); await visit(sale, '/account', null);
  // mobile
  const mob = await login('a@nt.vn', { width: 390, height: 844 });
  await visit(mob, '/crm/customers', 'mobile-customers'); await mob.locator('ul li').first().click(); await mob.waitForTimeout(800); await mob.screenshot({ path: `${SHOTS}/mobile-customer-detail.png` }); await visit(mob, '/', 'mobile-today'); await visit(mob, '/hr/leave', 'mobile-leave');
  await browser.close();
  console.log(errors.length ? 'ERRORS:\n' + errors.join('\n') : 'SMOKE OK');
})().catch(e => { console.error('FAILED', e.message, '\n', errors.join('\n')); process.exit(1); });
