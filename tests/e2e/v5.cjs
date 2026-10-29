// Bản 5: nhập file khách thật từ hệ thống, tìm theo username/mã HT, kho báo giá đã chốt + tạo BG tương tự, chặn chấm công ngoài IP, link Drive, sao lưu
const { chromium } = require('playwright');
const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots6';
const FILE = process.argv[2]; const errors = [];
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atc "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  require('fs').mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => { const ctx = await browser.newContext({ viewport, acceptDownloads: true }); const p = await ctx.newPage();
    p.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); }); p.on('pageerror', e => errors.push('PAGEERROR ' + e.message));
    await p.goto(BASE); await p.fill('input[type=email]', email); await p.fill('input[type=password]', 'Test1234!'); await p.click('button[type=submit]'); await p.waitForSelector('h2.display', { timeout: 10000 }); return p; };
  const shot = async (p, hash, name, full = false) => { if (hash) { await p.goto(BASE + '#' + hash); await p.waitForTimeout(1100); } await p.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: full }); };
  sql("update profiles set full_name = 'Lê Thị Minh Khơi' where email = 'a@nt.vn'");
  const ad = await login('namtrung20266@gmail.com');
  // Nhập file khách xuất từ hệ thống
  await ad.goto(BASE + '#/crm/customers'); await ad.waitForTimeout(900);
  await ad.click('button:has-text("Nhập / đồng bộ")'); await ad.setInputFiles('div.fixed.inset-0.z-50 input[type=file]', FILE); await ad.waitForTimeout(800);
  await ad.check('div.fixed.inset-0.z-50 input[type=checkbox]');
  await ad.screenshot({ path: SHOTS + '/import-map.png', fullPage: true });
  const n = (await ad.locator('div.fixed.inset-0.z-50 button:has-text("Nhập ")').last().innerText()).match(/\d+/)?.[0];
  await ad.locator('div.fixed.inset-0.z-50 button:has-text("Nhập ")').last().click(); await ad.waitForTimeout(2000);
  const res = await ad.locator('div.fixed.inset-0.z-50').innerText(); console.log('IMPORT:', res.split('\n').filter(l => /Cập nhật|Dòng/.test(l)).join(' | '));
  await ad.screenshot({ path: SHOTS + '/import-result.png' });
  await ad.locator('div.fixed.inset-0.z-50 button:text-is("Đóng")').click();
  const c = sql("select count(*) || '|' || count(sys_username) || '|' || count(sys_first_order_date) || '|' || count(*) filter (where tax_code ~ '^[0-9]{12}$') from customers where sys_code like 'NT%'");
  console.log('DB:', c, 'file rows:', n);
  if (!c.startsWith(String(n))) errors.push('Số khách nhập không khớp: ' + c);
  // Tìm theo username trong Khách hàng
  await ad.fill('input[placeholder^="Tìm tên"]', 'luongit'); await ad.waitForTimeout(1200);
  if (!(await ad.textContent('body')).includes('@luongit')) errors.push('Tìm theo username HT không ra');
  await ad.screenshot({ path: SHOTS + '/customers-search.png' });
  // Kho báo giá: chỉ đơn đã chốt
  sql("update quotations set status = 'da_chot', order_code = 'NT9999', won_at = now() where id = (select id from quotations order by created_at limit 1)");
  const sale = await login('a@nt.vn');
  await sale.goto(BASE + '#/crm/library'); await sale.waitForTimeout(1200);
  if (!(await sale.textContent('body')).includes('NT9999')) errors.push('Kho báo giá không hiện mã đơn');
  await sale.screenshot({ path: SHOTS + '/library.png' });
  await sale.locator('button:visible:has-text("Tạo BG tương tự")').first().click(); await sale.waitForTimeout(400);
  await sale.locator('div.fixed.inset-0.z-50 input').first().click(); await sale.locator('div.fixed.inset-0.z-50 input').first().fill('NT1166'); await sale.waitForTimeout(900);
  await sale.locator('div.fixed.inset-0.z-50 button:has-text("NT1166")').first().dispatchEvent('mousedown'); await sale.waitForTimeout(300);
  await sale.screenshot({ path: SHOTS + '/similar.png' });
  await sale.click('div.fixed.inset-0.z-50 button:has-text("Tạo báo giá")'); await sale.waitForTimeout(2000);
  const qb = await sale.textContent('body');
  if (!/Báo giá mới/.test(qb) || !(await sale.locator('textarea').first().inputValue())) errors.push('Tạo BG tương tự không điền dòng hàng');
  await sale.screenshot({ path: SHOTS + '/quote-from-template.png' });
  // Tìm báo giá theo mã đơn / username
  await sale.goto(BASE + '#/crm/quotes'); await sale.waitForTimeout(800);
  await sale.fill('input[placeholder^="Tìm mã BG"]', 'NT9999'); await sale.waitForTimeout(1500);
  if ((await sale.locator('table tbody tr').count()) !== 1) errors.push('Tìm báo giá theo mã đơn sai');
  // Chặn chấm công ngoài IP
  sql(`update settings set value = value || '{"ip_whitelist":["10.9.9.9"],"outside_ip":"block"}'::jsonb where key = 'attendance'`);
  const s2 = await login('a@nt.vn'); await s2.goto(BASE + '#/hr/attendance'); await s2.waitForTimeout(1200);
  if (!(await s2.textContent('body')).includes('ngoài mạng công ty — hãy kết nối wifi')) errors.push('Không hiện chặn ngoài IP');
  await s2.screenshot({ path: SHOTS + '/attendance-block.png' });
  // Link Drive cho hợp đồng
  const hr = await login('hr@nt.vn'); await hr.goto(BASE + '#/hr/staff'); await hr.waitForTimeout(900);
  await hr.locator('ul li button').filter({ hasText: 'Lê Thị Minh Khơi' }).click(); await hr.waitForTimeout(700);
  await hr.click('button:text-is("Hợp đồng")'); await hr.click('button:has-text("+ Hợp đồng mới")'); await hr.waitForTimeout(300);
  await hr.fill('input[placeholder="https://drive.google.com/…"]', 'https://drive.google.com/file/d/abc/view');
  await hr.click('div.fixed.inset-0.z-50 button:text-is("Lưu")'); await hr.waitForTimeout(1000);
  if (!(await hr.locator('a:has-text("Mở link")').count())) errors.push('Không lưu link hợp đồng');
  await hr.screenshot({ path: SHOTS + '/contract-link.png' });
  // Sao lưu
  await ad.goto(BASE + '#/admin/data'); await ad.waitForTimeout(800); await ad.click('button:text-is("Sao lưu & khôi phục")'); await ad.waitForTimeout(900);
  await ad.screenshot({ path: SHOTS + '/backup.png', fullPage: true });
  const [dl] = await Promise.all([ad.waitForEvent('download', { timeout: 60000 }), ad.click('button:has-text("Tải file sao lưu")')]);
  if (!/\.zip$/.test(dl.suggestedFilename())) errors.push('Không tải được file sao lưu');
  const m = await login('a@nt.vn', { width: 390, height: 844 });
  for (const h of ['/crm/library', '/crm/customers', '/crm/quotes', '/hr/attendance']) { await m.goto(BASE + '#' + h); await m.waitForTimeout(800); const w = await m.evaluate(() => document.documentElement.scrollWidth); if (w > 392) errors.push(`tràn ngang ${h}: ${w}`); }
  await browser.close();
  if (errors.length) { console.log(errors.join('\n')); process.exit(1); }
  console.log('V5 E2E OK');
})().catch(e => { console.log('FAILED', e.message.split('\n')[0], '\n' + errors.join('\n')); process.exit(1); });
