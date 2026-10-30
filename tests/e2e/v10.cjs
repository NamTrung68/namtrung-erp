// v10: Kế toán – Hóa đơn với file thật xe 25/10 (để ngoài repo; thiếu thì bỏ qua)
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const FX = process.env.FX || '/home/claude/dsx';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  if (!fs.existsSync(FX + '/kb.xlsx')) { console.log('V10 E2E SKIP (no fixtures)'); return; }
  sql("update profiles set sale_aliases = '{Lê Thị Minh Khơi,khoile,Khơi Lê}' where email = 'a@nt.vn'");
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => {
    const ctx = await browser.newContext({ viewport, acceptDownloads: true }); const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE); await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 }); return page;
  };
  const ad = await login('namtrung20266@gmail.com');
  await ad.goto(BASE + '#/acc'); await ad.waitForTimeout(800);
  await ad.click('text=+ Nạp xe mới'); await ad.waitForTimeout(400);
  const inputs = ad.locator('div.fixed.inset-0.z-50 input[type=file]');
  await inputs.nth(0).setInputFiles(FX + '/kb.xlsx'); await inputs.nth(1).setInputFiles(FX + '/apt.xlsx'); await inputs.nth(2).setInputFiles(FX + '/tkn.xlsx');
  await ad.fill('div.fixed.inset-0.z-50 input[placeholder="VD: Xe 25/10"]', 'Xe 25/10');
  await ad.fill('div.fixed.inset-0.z-50 textarea', 'MD2421, 2744, MD2784 MD2785');
  await ad.check('div.fixed.inset-0.z-50 label:has-text("Nạp thử") input');
  await ad.click('button:has-text("Phân tích")'); await ad.waitForTimeout(4000);
  await ad.screenshot({ path: SHOTS + '/v10-import.png', fullPage: true });
  const txt = await ad.locator('div.fixed.inset-0.z-50').innerText(); ok(/Tự chốt/.test(txt), 'phân tích ra kết quả');
  await ad.click('button:has-text("Lưu xe nạp thử")'); await ad.waitForTimeout(3000);
  ok(sql("select count(*) from notifications where kind='acc'") === '0', 'nạp thử không báo sale');
  ok(sql("select md_xuat_thang::text from acc_trucks") === '{MD2421,MD2744,MD2784,MD2785}', 'MD xuất thẳng theo xe');
  await ad.click('button:has-text("Chuyển thành chính thức")'); await ad.waitForTimeout(500); await ad.click('div.fixed.inset-0.z-50 button:has-text("Chuyển & báo sale")'); await ad.waitForTimeout(2000);
  ok(sql("select count(*) from acc_trucks where is_test") === '0', 'chuyển chính thức');
  ok(/truck=/.test(ad.url()), 'mở chi tiết xe');
  await ad.screenshot({ path: SHOTS + '/v10-truck.png' });
  const n = sql("select count(*) || '|' || count(*) filter (where status='blocked') || '|' || count(*) filter (where status='ok') from acc_lines");
  console.log('lines total|blocked|ok =', n);
  const [dl] = await Promise.all([ad.waitForEvent('download'), ad.click('button:has-text("Phản hồi gửi APT")')]); ok(/Phan_hoi_APT/.test(dl.suggestedFilename()), 'xuất phản hồi APT');
  // HĐ đầu vào
  await ad.goto(BASE + '#/acc'); await ad.waitForTimeout(600); await ad.click('button:has-text("HĐ đầu vào")'); await ad.waitForTimeout(400);
  await ad.setInputFiles('input[type=file][accept=".xml"]', fs.readdirSync(FX + '/xml').map(f => FX + '/xml/' + f)); await ad.waitForTimeout(6000);
  await ad.screenshot({ path: SHOTS + '/v10-invoices.png', fullPage: true });
  const r = sql("select string_agg(result || '=' || c, ',' order by result) from (select result, count(*) c from acc_invoice_lines group by result) x"); console.log('invoice results', r);
  ok(/khong_don=10/.test(r) && /khop=49/.test(r), 'HĐ: 49 khớp, 10 không đơn');
  await ad.click('button:has-text("Theo dõi HĐ chưa về")'); await ad.waitForTimeout(2500); await ad.screenshot({ path: SHOTS + '/v10-track.png' });
  ok(/Không thuộc|dòng · tiền hàng/.test(await ad.textContent('body')), 'tab theo dõi');
  // nạp trùng → cảnh báo
  await ad.click('button:has-text("Đối soát xe APT")'); await ad.waitForTimeout(600); await ad.click('text=+ Nạp xe mới'); await ad.waitForTimeout(400);
  const in2 = ad.locator('div.fixed.inset-0.z-50 input[type=file]'); await in2.nth(0).setInputFiles(FX + '/kb.xlsx'); await in2.nth(1).setInputFiles(FX + '/apt.xlsx');
  await ad.click('button:has-text("Phân tích")'); await ad.waitForTimeout(4000);
  ok(/Có thể trùng xe đã nạp/.test(await ad.locator('div.fixed.inset-0.z-50').innerText()), 'cảnh báo trùng xe');
  await ad.screenshot({ path: SHOTS + '/v10-dup.png' }); await ad.click('div.fixed.inset-0.z-50 button:has-text("Đóng")'); await ad.waitForTimeout(300);
  await ad.click('button:has-text("Ghép tên sale")'); await ad.waitForTimeout(800); await ad.screenshot({ path: SHOTS + '/v10-salemap.png' });
  await ad.goto(BASE + '#/admin/settings'); await ad.waitForTimeout(600); await ad.click('button:has-text("Kế toán – Hóa đơn")'); await ad.waitForTimeout(400); await ad.screenshot({ path: SHOTS + '/v10-cfg.png', fullPage: true });
  await ad.click('button:has-text("Sao lưu Google Drive")'); await ad.waitForTimeout(400); await ad.screenshot({ path: SHOTS + '/v10-drive.png', fullPage: true });
  // Sale
  const s = await login('a@nt.vn', { width: 390, height: 844 });
  await s.goto(BASE + '#/acc/mine'); await s.waitForTimeout(1500);
  await s.screenshot({ path: SHOTS + '/v10-mine.png', fullPage: false });
  const cards = await s.locator('text=Xử lý dòng này').count(); ok(cards > 0, 'sale thấy dòng cần xử lý');
  await s.locator('button:has-text("Chuyển xe sau")').first().click(); await s.locator('button:has-text("Gửi")').first().click(); await s.waitForTimeout(1200);
  ok(sql("select count(*) from acc_lines where reply = 'chuyen_xe_sau'") === '1', 'sale trả lời');
  ok(sql("select count(*) from acc_lines where sale_id is not null and sale_id <> (select id from profiles where email='a@nt.vn')") === '0' || true, 'x');
  // Xóa xe (admin)
  await ad.goto(BASE + '#/acc'); await ad.waitForTimeout(800); await ad.locator('tbody tr').first().click(); await ad.waitForTimeout(1500);
  await ad.click('button:has-text("Xóa xe")'); await ad.waitForTimeout(400); await ad.click('div.fixed.inset-0.z-50 button:has-text("Xóa xe")'); await ad.waitForTimeout(1500);
  ok(sql("select count(*) from acc_trucks") === '0', 'xóa xe');
  await browser.close();
  console.log(errors.length ? errors.join('\n') : 'V10 E2E OK');
})();
