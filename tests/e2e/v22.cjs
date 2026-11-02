// v22: lập phiếu nhanh theo ID đơn, chọn tất cả, lọc chưa có giá / đơn nhiều giá, kho giá, cột ID đơn + sắp xếp ở danh sách phiếu
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const SHOTS = process.env.SHOTS || '/tmp/v22-shots';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
require('fs').mkdirSync(SHOTS, { recursive: true });
(async () => {
  const A = sql("select id from profiles where email='a@nt.vn'");
  sql(`insert into customers(code, contact_name, company_name, tax_code, phone, customer_type, source, owner_id, sys_username, legal_address, email) values
    ('KH22', 'Chị Thủy', 'CÔNG TY TNHH THỦY 22', '0123456789', '+84 912 000 022', 'nha_buon', 'tu_tim_zalo', '${A}', 'thuyvu22', 'Hà Nội', 'kt@thuy22.vn')`);
  const C = sql("select id from customers where code='KH22'");
  sql(`insert into out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id, customer_id, username, so_hd_vao) values
    ('HH00001-7001-2026', 'Hộp đựng giấy vải polyester', 'Chiếc', 0.08, 400, 50000, 'MD7001', '${A}', '${C}', 'thuyvu22', '7001'),
    ('HH00002-7001-2026', 'Cốc sứ trắng men 350ml', 'Cái', 0.1, 120, 70000, 'MD7001', '${A}', '${C}', 'thuyvu22', '7001'),
    ('HH00003-7001-2026', 'Túi voan lưới', 'Cái', 0.08, 1000, 400, 'MD7002', '${A}', null, 'lela_shop', '7001'),
    ('HH00004-7001-2026', 'Khay nhựa đựng đồ', 'Cái', 0.08, 50, 1000, 'MD7003', '${A}', '${C}', 'thuyvu22', '7001')`);
  sql(`set role postgres; select app.out_price_put('MD7001', 'Hộp đựng giấy vải polyester', 400, 54000, 'don_hang', null); select app.out_price_put('MD7001', 'Cốc sứ trắng men 350ml', 120, 80000, 'don_hang', null);
    select app.out_price_put('MD7003', 'Bàn chải', 7, 15000, 'don_hang', null); select app.out_price_put('MD7003', 'Chổi quét', 9, 25000, 'don_hang', null);
    select app.out_md_reprice('MD7001'); select app.out_md_reprice('MD7003');`);
  ok(sql("select string_agg(coalesce(gia_khach::text,'-'), ',' order by ma_hang) from out_items where ma_hang like '%-7001-2026'") === '54000,80000,-,-', 'kho giá: đơn 2 giá khớp đúng 2 dòng; đơn không khớp để trống');
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => {
    const ctx = await browser.newContext({ viewport, hasTouch: viewport.width < 600, isMobile: viewport.width < 600, acceptDownloads: true }); const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE); await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 }); return page;
  };
  const s = await login('a@nt.vn');
  await s.goto(BASE + '#/out'); await s.waitForTimeout(1500);
  ok(await s.locator('button:has-text("Chưa có giá xuất (2)")').count() === 1, 'chip lọc Chưa có giá xuất (2)');
  ok(await s.locator('button:has-text("Đơn nhiều giá — cần chọn (1)")').count() === 1, 'chip Đơn nhiều giá (1)');
  ok(await s.locator('text=⚠ đơn có 2 giá — chọn').count() >= 1, 'dòng đơn nhiều giá có nút chọn giá');
  await s.locator('tr', { hasText: 'HH00004-7001-2026' }).locator('text=⚠ đơn có 2 giá — chọn').click(); await s.waitForTimeout(800);
  await s.locator('div.fixed.inset-0.z-50 button', { hasText: '25.000' }).click(); await s.waitForTimeout(1200);
  ok(sql("select gia_khach || '|' || gia_src from out_items where ma_hang='HH00004-7001-2026'") === '25000|sale', 'sale chọn giá trong danh sách giá của đơn');
  await s.locator('tr', { hasText: 'HH00001-7001-2026' }).locator('button:has-text("chọn cả đơn")').click(); await s.waitForTimeout(1000);
  ok(await s.locator('text=Đã chọn 2 dòng').count() === 1, '“chọn cả đơn” tick 2 dòng cùng MD7001');
  await s.click('button:has-text("Chọn tất cả")'); await s.waitForTimeout(1200);
  ok(await s.locator('text=Đã chọn 4 dòng · 3 ID đơn').count() === 1, 'chọn tất cả: 4 dòng · 3 ID đơn');
  await s.click('button:has-text("Lập nhanh theo ID đơn (3 phiếu)")'); await s.waitForSelector('text=Lập nhanh theo ID đơn · 3 phiếu', { timeout: 10000 }); await s.waitForTimeout(1200);
  const M = s.locator('div.fixed.inset-0.z-50');
  ok(await M.locator('input[value="CÔNG TY TNHH THỦY 22"]').count() === 2, 'tự điền đơn vị theo hồ sơ khách cho 2 đơn của khách');
  ok(await M.locator('text=Chưa có tên đơn vị mua').count() === 1 && await M.locator('text=Thiếu giá xuất 1 dòng').count() === 1, 'đơn chưa gắn khách: báo thiếu tên đơn vị + thiếu giá');
  ok(await M.locator('text=Username lela_shop chưa có trong khách ERP').count() === 1, 'cảnh báo username chưa có trong khách ERP');
  ok(await M.locator('text=Nhiều thuế suất trong 1 HĐ').count() === 1, 'cảnh báo đơn có 8% và 10%');
  await s.screenshot({ path: SHOTS + '/1-bulk.png', fullPage: true });
  ok(await M.locator('button:has-text("Gửi kế toán (2 phiếu)")').count() === 1, '2 phiếu sẵn sàng, 1 cần bổ sung');
  const card = M.locator('div.rounded-2xl', { hasText: 'MD7002' });
  await card.locator('input[placeholder="Tên đơn vị mua hàng *"]').fill('HỘ KINH DOANH LELA'); await card.locator('input[inputmode=numeric]').fill('420');
  await s.waitForTimeout(300);
  ok(await M.locator('button:has-text("Gửi kế toán (3 phiếu)")').count() === 1, 'bổ sung xong → 3 phiếu sẵn sàng');
  await M.locator('button:has-text("Gửi kế toán (3 phiếu)")').click(); await s.waitForTimeout(4000);
  ok(sql(`select count(*) from out_invoices where sale_id='${A}' and status='cho_nhap' and created_at > now() - interval '5 minutes'`) === '3', '3 phiếu gửi kế toán, mỗi ID đơn 1 phiếu');
  ok(sql("select count(*) from out_invoice_lines l join out_items t on t.id=l.item_id where t.md='MD7001'") === '2', 'phiếu MD7001 có 2 dòng');
  ok(sql("select gia_khach || '|' || gia_src from out_items where ma_hang='HH00003-7001-2026'") === '420|phieu', 'giá sale gõ trên phiếu lưu vào dòng + kho giá');
  await s.screenshot({ path: SHOTS + '/2-bulk-done.png', fullPage: true });
  await M.locator('button:text-is("Đóng")').first().click(); await s.waitForTimeout(800);
  // danh sách phiếu: cột ID đơn + sắp xếp
  await s.click('button:has-text("Phiếu của tôi")'); await s.waitForTimeout(800); await s.click('button:has-text("Chờ xuất nháp")'); await s.waitForTimeout(1500);
  ok(await s.locator('td', { hasText: 'MD7001' }).count() >= 1, 'danh sách phiếu có cột ID đơn');
  await s.locator('th button', { hasText: 'ID đơn' }).click(); await s.waitForTimeout(1200);
  const firstMd = await s.locator('tbody tr').first().locator('td').nth(1).innerText();
  ok(/MD7001/.test(firstMd), `sắp theo ID đơn (đầu danh sách: ${firstMd.split('\n')[0]})`);
  ok(await s.locator('text=có VAT 10%').count() >= 1, 'phiếu có dòng VAT 10% được đánh dấu');
  await s.screenshot({ path: SHOTS + '/3-list.png', fullPage: true });
  // điện thoại
  const m = await login('a@nt.vn', { width: 390, height: 844 });
  await m.goto(BASE + '#/out'); await m.waitForTimeout(1500); await m.click('button:has-text("Hàng chờ xuất HĐ")').catch(() => {}); await m.waitForTimeout(800);
  await m.screenshot({ path: SHOTS + '/4-mobile-items.png', fullPage: false });
  await browser.close();
  console.log(errors.length ? errors.join('\n') : 'V22 E2E PASSED');
  process.exit(errors.length ? 1 : 0);
})().catch(e => { console.error(e); console.log(errors.join('\n')); process.exit(1); });
