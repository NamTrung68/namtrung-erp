// v29: CSKH bị chặn 4 mục; Hóa đơn của tôi cho CSKH; lọc số HĐ; mã hàng hiện ngoài danh sách
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const SHOTS = '/tmp/v29-shots'; require('fs').mkdirSync(SHOTS, { recursive: true });
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  sql(`insert into public.invites(email, full_name, roles, job_level) values ('cskh@nt.vn','Nguyễn CSKH','{cskh}','nhan_vien')`);
  sql(`insert into auth.users(email) values ('cskh@nt.vn')`);
  const A = sql("select id from profiles where email='a@nt.vn'"); const CS = sql("select id from profiles where email='cskh@nt.vn'");
  sql(`insert into support_assignments(cskh_id, sale_id, kind) values ('${CS}', '${A}', 'chinh')`);
  sql(`insert into out_items(id, ma_hang, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id, gia_khach, ngay_vao) values
    ('00000000-0000-0000-0029-00000000e0a1', 'HH00044-2153-2026', 'Công tắc điều khiển từ xa', 'Chiếc', 0.08, 120, 250000, 'MD2461', '${A}', 260975, '2026-11-04'),
    ('00000000-0000-0000-0029-00000000e0a2', 'HH00001-2080-2026', 'Hộp giấy', 'Chiếc', 0.08, 10, 1000, 'MD2462', '${A}', 1030, '2026-10-30')`);
  sql(`insert into out_invoices(id, code, sale_id, buyer_name, status) values ('00000000-0000-0000-0029-00000000e0b1', 'XHD29001', '${A}', 'CÔNG TY THANH TÂM', 'cho_nhap');
    insert into out_invoice_lines(invoice_id, item_id, sl, don_gia) values ('00000000-0000-0000-0029-00000000e0b1', '00000000-0000-0000-0029-00000000e0a1', 20, 260975)`);
  const b = await chromium.launch();
  const login = async email => { const p = await (await b.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
    p.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await p.goto(BASE); await p.fill('input[type=email]', email); await p.fill('input[type=password]', 'Test1234!'); await p.click('button[type=submit]'); await p.waitForSelector('h2.display'); return p; };
  const cs = await login('cskh@nt.vn');
  for (const g of ['Bán hàng', 'Kế toán – Hóa đơn']) { const btn = cs.locator('nav button', { hasText: g }); if (await btn.count() && (await btn.first().getAttribute('aria-expanded')) === 'false') await btn.first().click(); }
  await cs.waitForTimeout(300); const nav = await cs.locator('nav').first().innerText();
  ok(!/Hỗ trợ khách|Báo cáo ngày|Báo cáo và KPI|Bảng Phong Thần/.test(nav), 'menu CSKH không có 4 mục bị cấm');
  for (const path of ['/support', '/crm/daily', '/crm/reports', '/kpi']) { await cs.goto(BASE + '#' + path); await cs.waitForTimeout(700);
    ok(await cs.locator('text=Không có quyền truy cập').count() >= 1, 'chặn đường dẫn ' + path); }
  await cs.goto(BASE + '#/hd'); await cs.waitForTimeout(1500);
  ok(/Hóa đơn của tôi/.test(await cs.locator('nav').first().innerText()), 'menu CSKH có Hóa đơn của tôi');
  ok(await cs.locator('text=HH00044-2153-2026').count() >= 1, 'CSKH thấy hàng sẵn sàng xuất của sale, mã hàng hiện ngoài');
  await cs.screenshot({ path: SHOTS + '/1-cskh-san-sang.png' });
  await cs.locator('button', { hasText: 'Đang xử lý' }).click(); await cs.waitForTimeout(1200);
  ok(await cs.locator('text=XHD29001').count() >= 1 && await cs.locator('span:has-text("HĐ 2153")').count() >= 1, 'phiếu của sale hiện cho CSKH, kèm HĐ + mã hàng');
  await cs.screenshot({ path: SHOTS + '/2-cskh-phieu.png' });
  // lọc HĐ 2080 → phiếu 2153 biến mất
  await cs.locator('select').first().selectOption({ label: /HĐ 2080/ }).catch(async () => { const o = await cs.locator('select').first().locator('option', { hasText: 'HĐ 2080' }).getAttribute('value'); await cs.locator('select').first().selectOption(o); });
  await cs.waitForTimeout(1200);
  ok(await cs.locator('text=XHD29001').count() === 0, 'lọc HĐ 2080 ẩn phiếu thuộc HĐ 2153');
  await cs.locator('button', { hasText: 'Sẵn sàng xuất' }).click(); await cs.waitForTimeout(1000);
  ok(await cs.locator('text=HH00001-2080-2026').count() >= 1 && await cs.locator('text=HH00044-2153-2026').count() === 0, 'Sẵn sàng xuất lọc theo HĐ 2080');
  await cs.screenshot({ path: SHOTS + '/3-loc-hd.png' });
  const kt = await login('kt@nt.vn'); await kt.goto(BASE + '#/hd/kt'); await kt.waitForTimeout(1500);
  ok(await kt.locator('text=HH00044-2153-2026').count() >= 1, 'Bàn kế toán: mã hàng hiện ngay trên dòng phiếu');
  await kt.screenshot({ path: SHOTS + '/4-ke-toan.png' });
  const s = await login('a@nt.vn'); await s.goto(BASE + '#/kpi'); await s.waitForTimeout(1000); const nav2 = await s.locator('nav').first().innerText();
  ok(/Bảng Phong Thần/.test(nav2) && /Báo cáo ngày/.test(nav2) && await s.locator('text=Không có quyền truy cập').count() === 0, 'sale vẫn thấy và vào được các mục');
  await b.close(); if (errors.length) { console.log(errors.join('\n')); process.exit(1); } console.log('V29 E2E OK');
})().catch(e => { console.log('FAILED', e.message, errors.join('\n')); process.exit(1); });
