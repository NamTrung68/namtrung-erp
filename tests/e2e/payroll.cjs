// Kiểm thử luồng lương: mở kỳ, nhập file BC Lợi nhuận thật, tính lương, gửi xác nhận, chốt
const { chromium } = require('/home/claude/.npm-global/lib/node_modules/playwright');
const BASE = 'http://localhost:8080/'; const FILE = process.argv[2];
const SHOTS = '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots';
const errors = [];
(async () => {
  const browser = await chromium.launch(); const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } }); const page = await ctx.newPage();
  page.on('pageerror', e => errors.push('PAGEERROR ' + e.message)); page.on('console', m => m.type() === 'error' && !/fonts|vietqr|Failed to load/.test(m.text()) && errors.push(m.text()));
  await page.goto(BASE); await page.fill('input[type=email]', 'namtrung20266@gmail.com'); await page.fill('input[type=password]', 'Test1234!'); await page.click('button[type=submit]');
  await page.waitForSelector('text=Xin chào');
  // lương cơ bản cho sale A
  await page.goto(BASE + '#/hr/payroll'); await page.waitForTimeout(800);
  await page.fill('input[type=month]', '2026-10'); await page.waitForTimeout(800);
  await page.screenshot({ path: SHOTS + '/p0.png' }); if (await page.$('button:has-text("Mở kỳ lương")')) await page.click('button:has-text("Mở kỳ lương")'); await page.waitForTimeout(1000); await page.screenshot({ path: SHOTS + '/p1.png' });
  await page.click('button:has-text("1. Nhập file")'); await page.waitForTimeout(300);
  await page.setInputFiles('input[type=file]', FILE); await page.waitForTimeout(1200);
  await page.screenshot({ path: `${SHOTS}/import.png` });
  await page.click('button:has-text("thay toàn bộ dữ liệu")'); await page.waitForTimeout(1500);
  await page.click('button:has-text("2. Tính lương")'); await page.waitForTimeout(2000);
  await page.screenshot({ path: `${SHOTS}/payroll-computed.png`, fullPage: true });
  const t = await page.locator('main').innerText();
  console.log(t.split('\n').filter(l => /Khơi|Trưởng|chưa khớp|Đơn hoàn thành/.test(l)).slice(0, 10).join('\n'));
  await browser.close();
  console.log(errors.length ? 'ERRORS:\n' + errors.join('\n') : 'PAYROLL OK');
})().catch(e => { console.error('FAILED', e.message, errors.join('\n')); process.exit(1); });
