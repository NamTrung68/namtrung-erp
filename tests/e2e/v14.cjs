// v14: biên ngoài khung → sale gửi giá đề xuất; nhầm sale; dòng thừa; Xuất HĐ đầu ra với sổ thật (để ngoài repo)
const { chromium } = require('playwright'); const fs = require('fs'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const FX = process.env.FX || '/home/claude/dsx';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const A = sql("select id from profiles where email='a@nt.vn'"), B = sql("select id from profiles where email='b@nt.vn'");
  sql("update profiles set sale_aliases = '{trungdv22}' where email = 'b@nt.vn'"); sql("update profiles set sale_aliases = '{huevt,Khơi Lê}' where email = 'a@nt.vn'");
  sql(`insert into settings(key, value) values ('company', '{"name":"CÔNG TY TNHH NAM TRUNG","tax_code":"0100000000","address":"Hà Nội","hotline":"0900000000"}') on conflict (key) do update set value = excluded.value`);
  const T = sql("insert into acc_trucks(name, truck_date) values ('Xe E2E 14', current_date - 3) returning id");
  sql(`insert into acc_lines(truck_id, line_key, apt_stt, hh, ten_apt, sl_apt, dvt_apt, gia_nhap, gia_khach, gia_de_xuat, md, sale_id, luong, status, issues, bien_nt, due_at) values
    ('${T}','G1',25,'HH09933','Bộ ấm trà thủy tinh',30,'Bộ',123193,128700,124951,'MD2508','${A}','A','blocked','{Biên NT 4.47% > 4%}', 0.0447, now() + interval '24 hours'),
    ('${T}','G2',27,'HH09935','Bộ bếp hợp kim nhôm',20,'Bộ',241165,248400,null,'MD2611','${A}','A','blocked','{Gộp đơn sai}', 0.03, now() + interval '24 hours')`);
  sql(`insert into acc_lines(truck_id, line_key, md, ten_ht, sl_ht, dvt_ht, gia_khach, sale_id, luong, status, issues, due_at) values
    ('${T}','S9','MD2506','Bộ ấm trà hoa văn',48,'PCE',130300,'${A}','E','blocked','{Có trên hệ thống, không lên xe}', now() + interval '24 hours')`);
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => {
    const ctx = await browser.newContext({ viewport, acceptDownloads: true }); const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE); await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 }); return page;
  };
  const M = 'div.fixed.inset-0.z-50';
  // ===== Đối soát =====
  const s = await login('a@nt.vn', { width: 1280, height: 900 });
  await s.goto(BASE + '#/acc/mine'); await s.waitForTimeout(1500);
  const card = n => s.locator('div.rounded-2xl', { hasText: n });
  ok(await card('Bộ ấm trà thủy tinh').locator('text=Đã gửi APT giá đề xuất').count() === 1, 'dòng vượt biên có lựa chọn gửi giá');
  ok((await card('Bộ ấm trà thủy tinh').innerText()).includes('124951'), 'hiện giá đề xuất số liền');
  await s.screenshot({ path: SHOTS + '/v14-todo.png', fullPage: true });
  await card('Bộ ấm trà thủy tinh').locator('button:has-text("Copy gửi APT")').click().catch(() => {});
  await card('Bộ ấm trà thủy tinh').locator('button:has-text("Đã gửi APT giá đề xuất")').click(); await card('Bộ ấm trà thủy tinh').locator('button:text-is("Gửi")').click(); await s.waitForTimeout(1200);
  ok(sql("select status || '|' || gia_nhap || '|' || phan_hoi from acc_lines where line_key='G1'") === 'ok|124951|XUẤT GIÁ 124951', 'gửi giá → chốt, đổi giá nháp');
  await card('Bộ bếp hợp kim').locator('button:has-text("Nhầm sale / nhầm đơn")').click(); await card('Bộ bếp hợp kim').locator('text=Không phải hàng của tôi').click();
  await card('Bộ bếp hợp kim').locator('textarea').fill('Hàng của chị Trang'); await card('Bộ bếp hợp kim').locator('button:text-is("Gửi")').click(); await s.waitForTimeout(1200);
  ok(sql("select coalesce(sale_id::text,'null') || status from acc_lines where line_key='G2'") === 'nullblocked', 'nhầm sale → nhả dòng');
  await card('Bộ ấm trà hoa văn').locator('button:has-text("Dòng thừa / Không khai")').click(); await card('Bộ ấm trà hoa văn').locator('text=Đi đường khác').click();
  ok(await card('Bộ ấm trà hoa văn').locator('button:has-text("Đề xuất giá khác")').count() === 0, 'luồng E chỉ hiện lựa chọn phù hợp');
  await card('Bộ ấm trà hoa văn').locator('button:text-is("Gửi")').click(); await s.waitForTimeout(1200);
  ok(sql("select reply || reply_sub || status from acc_lines where line_key='S9'") === 'dong_thuakhong_khaireplied', 'dòng thừa → chờ kế toán');
  const kt = await login('kt@nt.vn');
  await kt.goto(BASE + `#/acc?truck=${T}`); await kt.waitForTimeout(1500);
  await kt.locator('tr', { hasText: 'Bộ ấm trà hoa văn' }).click(); await kt.waitForTimeout(600);
  await kt.click('button:has-text("Chốt dòng")'); await kt.waitForTimeout(400); await kt.screenshot({ path: SHOTS + '/v14-chot-thua.png' });
  await kt.locator(M).last().locator('button:has-text("✓ Chốt")').click(); await kt.waitForTimeout(1200);
  ok(sql("select status from acc_lines where line_key='S9'") === 'info', 'kế toán chốt dòng thừa');
  // ===== Xuất HĐ đầu ra =====
  const so = FX + '/hdra/xuathd.xlsx';
  if (!fs.existsSync(so)) { console.log('V14 sổ: SKIP (no fixture)'); }
  else {
    await kt.goto(BASE + '#/out'); await kt.waitForTimeout(1000);
    await kt.click('button:has-text("Sổ HĐ đầu vào")'); await kt.waitForTimeout(800);
    await kt.click('button:has-text("Nạp sổ Excel")'); await kt.waitForTimeout(400);
    await kt.locator(`${M} input[type=file]`).nth(0).setInputFiles(so);
    if (fs.existsSync(FX + '/hdra/orders.xlsx')) await kt.locator(`${M} input[type=file]`).nth(1).setInputFiles(FX + '/hdra/orders.xlsx');
    if (fs.existsSync(FX + '/hdra/misa.xlsx')) await kt.locator(`${M} input[type=file]`).nth(2).setInputFiles(FX + '/hdra/misa.xlsx');
    await kt.click('button:has-text("Đọc file")'); await kt.waitForTimeout(3000); await kt.screenshot({ path: SHOTS + '/v14-import.png' });
    await kt.locator(M).locator('button:has-text("Lưu")').click(); await kt.waitForTimeout(15000);
    const n = sql("select count(*) || '|' || count(*) filter (where sale_id is not null) || '|' || count(md) from out_items"); console.log('items total|sale|md =', n);
    ok(n.startsWith('539|'), 'nạp 539 dòng');
    const nb = sql("select count(*) from out_buyers"); console.log('buyers', nb, 'items with username', sql("select count(username) from out_items")); ok(Number(nb) > 150, 'nạp danh sách đơn vị nhận HĐ');
    const leg = sql("select count(*) || '|' || count(*) filter (where status='da_ky') from out_invoices where legacy"); console.log('legacy invoices total|da_ky =', leg);
    ok(Number(leg.split('|')[0]) > 50, 'tạo phiếu từ sổ cũ');
    ok(sql("select count(*) from out_items_v where ton > 0") !== '539', 'trừ tồn theo phiếu cũ');
    await kt.screenshot({ path: SHOTS + '/v14-items.png' });
    // nạp lại không nhân đôi
    await kt.click('button:has-text("Nạp sổ Excel")'); await kt.waitForTimeout(400); await kt.locator(`${M} input[type=file]`).first().setInputFiles(so);
    await kt.click('button:has-text("Đọc file")'); await kt.waitForTimeout(3000); await kt.locator(M).locator('button:has-text("Lưu")').click(); await kt.waitForTimeout(15000);
    ok(sql("select count(*) from out_invoices where legacy") === leg.split('|')[0], 'nạp lại không tạo trùng phiếu');
    // Sale B (trungdv22) lập phiếu từ 2 dòng còn tồn
    const sb = await login('b@nt.vn', { width: 1366, height: 900 });
    const freeIds = sql(`select string_agg(ma_hang, ',') from (select ma_hang from out_items_v where sale_id='${B}' and ton > 0 order by stt_so limit 2) x`);
    console.log('B items to invoice:', freeIds);
    if (!freeIds) { sql(`update out_items set sale_id='${B}' where ma_hang in (select ma_hang from out_items_v where ton > 0 order by stt_so limit 2)`); }
    const mh = sql(`select string_agg(ma_hang, ',') from (select ma_hang from out_items_v where sale_id='${B}' and ton > 0 order by stt_so limit 2) x`).split(',');
    await sb.goto(BASE + '#/out'); await sb.waitForTimeout(2000); await sb.screenshot({ path: SHOTS + '/v14-sale-items.png' });
    for (const m of mh) { await sb.fill('input[placeholder^="🔎 Mã hàng"]', m); await sb.waitForTimeout(400); await sb.locator('tr', { hasText: m }).locator('input[type=checkbox]').check(); }
    await sb.fill('input[placeholder^="🔎 Mã hàng"]', '');
    await sb.click('button:has-text("Lập phiếu xuất HĐ")'); await sb.waitForTimeout(800);
    await sb.locator(M).locator('label:has-text("Mã số thuế") input').fill('0110250411'); await sb.locator(M).locator('label:has-text("Địa chỉ") input').click(); await sb.waitForTimeout(1200);
    ok((await sb.locator(`${M} input[placeholder^="HỘ KINH DOANH"]`).inputValue()).includes('CHÂN TRỜI MỚI'), 'gõ MST tự điền đơn vị');
    const gias = sb.locator(`${M} input[inputmode=numeric]:visible`); await gias.first().fill('1'); await sb.waitForTimeout(300);
    ok(await sb.locator(M).getByText("⚠ dưới giá nhập").count() > 0, 'cảnh báo giá dưới giá nhập');
    const dgn = mh.map(m => Math.ceil(Number(sql(`select dg_nhap from out_items where ma_hang='${m}'`)) * 1.03));
    for (let i = 0; i < await gias.count(); i++) await gias.nth(i).fill(String(dgn[i] || dgn[0]));
    await sb.screenshot({ path: SHOTS + '/v14-editor.png' });
    await sb.click('button:has-text("Xác nhận giá & thông tin")'); await sb.waitForTimeout(1500);
    const inv = sql(`select code || '|' || status from out_invoices where not legacy and sale_id='${B}'`); console.log('invoice', inv); ok(/\|cho_nhap$/.test(inv), 'sale gửi phiếu');
    // Kế toán xuất file nháp → đã xuất nháp
    await kt.click('button:has-text("Phiếu xuất HĐ")'); await kt.waitForTimeout(1500);
    const [dl] = await Promise.all([kt.waitForEvent('download'), kt.click('button:has-text("Xuất file nháp")')]); ok(/HD_nhap_MISA/.test(dl.suggestedFilename()), 'file nháp');
    await dl.saveAs(SHOTS + '/misa_out.xlsx');
    const chk = execSync(`python3 -I -c "import openpyxl;ws=openpyxl.load_workbook('${SHOTS}/misa_out.xlsx').active;print(ws.title,'|',ws.cell(9,1).value,'|',ws.cell(9,15).value,'|',ws.cell(10,15).value,ws.cell(10,15).number_format,'|',ws.cell(10,3).value)"`).toString().trim();
    console.log('misa file:', chk); ok(/Hóa đơn GTGT \| Số thứ tự hóa đơn \(\*\) \| Thuế suất GTGT \(%\) \| 0\.08 0%/.test(chk), 'file nháp đúng mẫu MISA');
    await kt.waitForTimeout(600); await kt.locator(M).last().locator('button:has-text("Đã xuất nháp")').click(); await kt.waitForTimeout(1500);
    ok(sql(`select status from out_invoices where not legacy and sale_id='${B}'`) === 'da_nhap', 'đã xuất nháp');
    await kt.screenshot({ path: SHOTS + '/v14-invoices.png' });
    // Sale: xem trước, nhắn, xác nhận ký
    await sb.click('button:has-text("Phiếu của tôi")'); await sb.waitForTimeout(1200); await sb.click('button:has-text("Đã xuất nháp")').catch(() => {}); await sb.waitForTimeout(500);
    await sb.locator('tbody tr').first().click(); await sb.waitForTimeout(1200);
    const [pop] = await Promise.all([sb.context().waitForEvent('page'), sb.click('button:has-text("Xem trước / in nháp")')]); await pop.waitForTimeout(500);
    ok((await pop.textContent('body')).includes('CHÂN TRỜI MỚI'), 'bản nháp in đúng người mua'); await pop.screenshot({ path: SHOTS + '/v14-print.png', fullPage: true }); await pop.close();
    await sb.locator(`${M} textarea`).fill('Khách OK nháp'); await sb.locator(M).locator('button:text-is("Gửi")').click(); await sb.waitForTimeout(800);
    await sb.locator(M).locator('button:has-text("✓ Xác nhận ký")').click(); await sb.waitForTimeout(400); await sb.locator(M).last().locator('button:has-text("Đồng ý")').click(); await sb.waitForTimeout(1200);
    ok(sql(`select status from out_invoices where not legacy and sale_id='${B}'`) === 'xac_nhan_ky', 'sale xác nhận ký');
    await sb.screenshot({ path: SHOTS + '/v14-detail.png' });
    // Kế toán ký
    await kt.click('button:has-text("↻ Tải lại")'); await kt.waitForTimeout(1200); await kt.click('button:has-text("Sale xác nhận ký")'); await kt.waitForTimeout(600); await kt.locator('tbody tr').first().click(); await kt.waitForTimeout(1000);
    await kt.click('button:has-text("✓ Đã ký")'); await kt.waitForTimeout(400); await kt.locator(M).last().locator('input').fill('1234');
    await kt.locator(M).last().locator('button:text-is("Đã ký")').click(); await kt.waitForTimeout(1500);
    ok(sql(`select status || so_hd from out_invoices where not legacy and sale_id='${B}'`) === 'da_ky1234', 'kế toán ký');
    await kt.keyboard.press('Escape'); await kt.waitForTimeout(300);
    await kt.click('button:has-text("Sổ HĐ đầu vào")'); await kt.waitForTimeout(1500);
    const [d2] = await Promise.all([kt.waitForEvent('download'), kt.click('button:has-text("Xuất sổ")')]); ok(/So_xuat_HD/.test(d2.suggestedFilename()), 'xuất sổ đúng mẫu');
  }
  await browser.close();
  console.log(errors.length ? errors.join('\n') : 'V14 E2E OK');
})();
