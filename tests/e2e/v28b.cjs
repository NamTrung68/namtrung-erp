// v28b: kế toán xuất Excel HĐ chính thức APT — có Mã đơn hàng và VAT Nam Trung xuất dự kiến
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const A = sql("select id from profiles where email='a@nt.vn'");
  sql(`insert into out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap, md, sale_id, username, so_hd_vao, ngay_vao, gia_khach, gia_src) values
    ('HH00001-2153-2026', 'Bộ đồ đựng gia vị', 'Bộ', 0.08, 50, 151748, 'MD2550', '${A}', 'ahxdhn', '2153', '2026-11-04', 156300, 'doi_soat'),
    ('HH00002-2153-2026', 'Bát thủy tinh', 'Chiếc', 0.1, 300, 45583, 'MD2551', '${A}', 'ahxdhn', '2153', '2026-11-04', 46950, 'doi_soat'),
    ('HH00001-2080-2026', 'Hộp giấy', 'Chiếc', 0.08, 10, 1000, null, null, null, '2080', '2026-10-30', null, null)`);
  const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true }); const p = await ctx.newPage();
  p.on('pageerror', e => errors.push('PAGEERROR ' + e.message));
  await p.goto(BASE); await p.fill('input[type=email]', 'kt@nt.vn'); await p.fill('input[type=password]', 'Test1234!'); await p.click('button[type=submit]');
  await p.waitForSelector('h2.display'); await p.goto(BASE + '#/hd/kt'); await p.waitForTimeout(1500);
  await p.click('button:has-text("Excel HĐ chính thức")'); await p.waitForTimeout(1200);
  ok(await p.locator('text=HĐ 2153').count() >= 1, 'chọn được HĐ 2153 (mới nhất được chọn sẵn)');
  const [dl] = await Promise.all([p.waitForEvent('download'), p.click('button:has-text("Xuất 1 HĐ đã chọn")')]);
  const f = '/tmp/v28b.xlsx'; await dl.saveAs(f); console.log('  file', dl.suggestedFilename());
  const out = execSync(`python3 -c "
import openpyxl;ws=openpyxl.load_workbook('${f}').active;rows=list(ws.values);h=rows[0]
i=h.index('MÃ ĐƠN HÀNG');v=h.index('VAT NAM TRUNG XUẤT (dự kiến)');print(len(h),'|',rows[1][i],rows[1][v],'|',rows[2][i],rows[2][v],'|',rows[-1][7],rows[-1][v],'|',len(rows))"`).toString().trim();
  console.log('  ', out);
  // 50×156300=7.815.000 ×8% = 625.200 ; 300×46950=14.085.000 ×10% = 1.408.500 ; tổng 2.033.700 ; 2 dòng + trống + tổng = 5 hàng
  ok(out === '42 | MD2550 625200 | MD2551 1408500 | TỔNG CỘNG 2033700 | 5', 'Excel đúng cột Mã đơn hàng, VAT NT xuất, tổng cộng, chỉ HĐ đã chọn');
  await b.close(); if (errors.length) { console.log(errors.join('\n')); process.exit(1); } console.log('V28b E2E OK');
})().catch(e => { console.log('FAILED', e.message, errors.join('\n')); process.exit(1); });
