// v7: phân trang, tồn kho tổng + sửa, câu mẫu, COM bộ phận UI, camera filter
const { chromium } = require('playwright');
const BASE = 'http://localhost:8080/';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots';
const errors = []; const ok = (c, m) => { if (!c) { errors.push('FAIL ' + m); } };
(async () => {
  require('fs').mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const login = async (email, viewport = { width: 1440, height: 900 }) => {
    const ctx = await browser.newContext({ viewport, permissions: ['camera', 'clipboard-read', 'clipboard-write'] });
    const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE); await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 });
    return page;
  };
  const go = async (p, h) => { await p.goto(BASE + '#' + h); await p.waitForTimeout(1000); };
  const admin = await login('namtrung20266@gmail.com');
  // tồn kho: nhập qua rpc 45 dòng, kiểm tra phân trang + tổng
  require('child_process').execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -qc "delete from inventory_items; insert into inventory_items(name,sku,qty,unit,cost_price,sale_price) select 'Hàng thử '||i,'SP'||lpad(i::text,3,'0'),10,'cái',1000,1500 from generate_series(1,45) i"`);
  await go(admin, '/inventory');
  let txt = await admin.textContent('body');
  ok(/450/.test(txt), 'inventory total qty 450'); ok(/450\.000/.test(txt), 'cost value 450.000'); ok(/675\.000/.test(txt), 'sale value 675.000');
  ok(await admin.locator('tbody tr').count() === 20, 'inventory 20 rows/page');
  await admin.screenshot({ path: `${SHOTS}/v7-inventory.png` });
  await admin.locator('nav[aria-label="pager"] button:has-text("3"), button:has-text("3")').last().click().catch(() => {});
  await admin.waitForTimeout(800);
  // sửa tồn nhanh
  await go(admin, '/inventory');
  await admin.locator('button[title="Bấm để sửa số tồn"]').first().click();
  await admin.locator('tbody input').first().fill('25'); await admin.keyboard.press('Enter'); await admin.waitForTimeout(1200);
  txt = await admin.textContent('body'); ok(/465/.test(txt), 'qty edit updates total 465');
  // câu mẫu
  await go(admin, '/crm/replies'); txt = await admin.textContent('body'); ok(/48/.test(txt), 'reply templates seeded');
  await admin.screenshot({ path: `${SHOTS}/v7-replies.png` });
  await admin.click('text=💬 Câu mẫu'); await admin.waitForTimeout(800);
  await admin.screenshot({ path: `${SHOTS}/v7-replypicker.png` });
  // settings COM
  await go(admin, '/admin/settings'); await admin.click('button:has-text("Lương & KPI")').catch(() => {}); await admin.waitForTimeout(600);
  txt = await admin.textContent('body'); ok(/COM theo bộ phận/.test(txt), 'settings COM card');
  await admin.screenshot({ path: `${SHOTS}/v7-settings.png`, fullPage: true });
  await go(admin, '/hr/payroll'); await admin.screenshot({ path: `${SHOTS}/v7-payroll.png` });
  // khách hàng / báo giá có pager
  await go(admin, '/crm/customers'); await go(admin, '/crm/quotes'); await go(admin, '/crm/library');
  // sale: camera filter (mobile)
  const sale = await login('a@nt.vn', { width: 390, height: 844 });
  await go(sale, '/hr/attendance');
  const btn = sale.locator('button:has-text("Chấm vào")').first();
  if (await btn.count()) { await btn.click(); await sale.waitForTimeout(1500);
    ok(await sale.locator('text=Mịn da').count() > 0, 'camera filters shown');
    await sale.click('text=Hồng hào'); await sale.waitForTimeout(400);
    await sale.screenshot({ path: `${SHOTS}/v7-camera.png` }); }
  else errors.push('WARN no check-in button found');
  await browser.close();
  console.log(errors.length ? errors.join('\n') : 'V7 E2E OK');
})();
