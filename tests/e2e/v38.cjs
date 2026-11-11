// v38: tải PDF HĐ đã ký (hàm máy chủ hdky chạy thật bằng Deno) → lưu Drive (Apps Script giả lập) → nút Tải HĐ + Cả bộ (ĐĐH + BBGN + HĐ)
// Cần: restart.sh với FN_PORT=8000 cho gateway, apps-script-mock.mjs (:8091), meInvoice giả lập (:8092, tạo trong file này),
//      deno chạy supabase/functions/hdky/index.ts (:8000, HDKY_TEST_BASE=http://localhost:8092)
const { chromium } = require('playwright'); const { execSync } = require('child_process'); const fs = require('fs'); const http = require('http');
const BASE = 'http://localhost:8080/'; const SHOTS = process.env.SHOTS || '/tmp/v38-shots'; const TOKEN = 'e2e-backup-token-0123456789abcdef0123456789';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
fs.mkdirSync(SHOTS, { recursive: true });
const PDF = process.env.PDF_FILE ? fs.readFileSync(process.env.PDF_FILE) : Buffer.from('%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n'); // PDF_FILE: PDF có dòng "Ngày 28 tháng 10 năm 2026"
const hits = [];
http.createServer((req, res) => { const u = new URL(req.url, 'http://x'); hits.push(u.pathname + u.search);
  if (u.searchParams.get('Code') && u.searchParams.get('Code').startsWith('GOOD')) { res.writeHead(200, { 'Content-Type': 'application/pdf' }); return res.end(PDF); }
  res.writeHead(200, { 'Content-Type': 'text/html' }); res.end('<html>Không tìm thấy hóa đơn</html>'); }).listen(8092);
(async () => {
  sql(`insert into app.secrets(key, value) values ('backup_token_hash', encode(digest('${TOKEN}'::text, 'sha256'::text), 'hex')) on conflict (key) do update set value = excluded.value`);
  sql(`insert into settings(key, value) values ('drive', '{"url":"http://localhost:8091"}') on conflict (key) do update set value = excluded.value`);
  const A = sql("select id from profiles where email='a@nt.vn'");
  const IT = sql("insert into out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap) values ('HH-E2E-38', 'Đèn LED dây 5m', 'Cuộn', 0.08, 500, 50000) returning id").split('\n')[0];
  const mk = (code, mst, so, ma) => { const id = sql(`insert into out_invoices(code, sale_id, buyer_name, tax_code, status, so_hd, ngay_hd, status_at, created_at) values ('${code}', '${A}', 'Công ty ${code}', '${mst}', 'xac_nhan_ky', '${so}', current_date, now(), now() - interval '30 days') returning id`).split('\n')[0];
    sql(`insert into out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values ('${id}', '${IT}', 1, 10, 54000, 0.08)`);
    sql(`update out_invoices set status = 'da_ky', ma_tra_cuu = '${ma}' where id = '${id}'`); return id; };
  const I1 = mk('XHD38001', '0101248141', '381', 'GOOD38A001'), I2 = mk('XHD38002', '0101248142', '382', 'BAD38B0002'), I3 = mk('XHD38003', '0101248143', '383', 'GOOD38C003');

  const browser = await browser_(); async function browser_() { return chromium.launch(); }
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true }); const a = await ctx.newPage();
  a.on('pageerror', e => errors.push('PAGEERROR ' + e.message));
  await a.goto(BASE); await a.fill('input[type=email]', 'a@nt.vn'); await a.fill('input[type=password]', 'Test1234!'); await a.click('button[type=submit]'); await a.waitForSelector('h2.display');
  await a.goto(BASE + '#/hd'); await a.waitForTimeout(1200); await a.click('text=Đã ký'); await a.waitForTimeout(1500);
  const row = code => a.locator('div.cursor-pointer', { hasText: code });
  ok(await row('XHD38001').locator('button:has-text("Tải HĐ (PDF)")').count() === 1, 'nút Tải HĐ (PDF) nằm dưới mã tra cứu');
  await a.screenshot({ path: SHOTS + '/1-da-ky.png' });

  // 1) Tải HĐ: máy chủ tải từ meInvoice → lưu Drive → trả PDF
  let [dl] = await Promise.all([a.waitForEvent('download', { timeout: 30000 }), row('XHD38001').locator('button:has-text("Tải HĐ (PDF)")').click()]);
  let p = await dl.path(); ok(fs.readFileSync(p).subarray(0, 4).toString() === '%PDF' && /HD381_/.test(dl.suggestedFilename()), 'tải về PDF HĐ đã ký: ' + dl.suggestedFilename());
  ok(sql(`select count(*) from out_invoice_files where invoice_id = '${I1}' and kind = 'ky'`) === '1', 'PDF đã lưu Drive + gắn phiếu');
  ok(hits.some(h => h.includes('DownloadHandler.ashx') && h.includes('Code=GOOD38A001') && !h.includes('Viewer')), 'gọi đúng link tải meInvoice');
  const n0 = hits.length;

  // 2) Cả bộ: ĐĐH + BBGN + HĐ (lấy từ Drive, không gọi lại meInvoice)
  [dl] = await Promise.all([a.waitForEvent('download', { timeout: 30000 }), (async () => { await row('XHD38001').locator('button[title^="Cả bộ"]').click();
    await a.waitForTimeout(1500); if (await a.locator('button:has-text("Bỏ qua")').count()) await a.click('button:has-text("Bỏ qua")'); })()]);
  p = await dl.path(); let names = execSync(`unzip -Z1 "${p}"`).toString();
  ok(/DDH_HD381/.test(names) && /BBGN_HD381/.test(names) && /HD_da_ky_381.*\.pdf/.test(names) && !/HDMB|HDNT/.test(names), 'Cả bộ có ĐĐH + BBGN + HĐ đã ký:\n' + names.trim());
  ok(hits.length === n0, 'lần 2 lấy PDF từ Drive, không tải lại meInvoice');
  if (process.env.PDF_FILE) {   // bản 39: ngày chứng từ = ngày in trên HĐ (đọc trong PDF), sửa luôn ngày trên phiếu
    const tmp = '/tmp/v38-bbgn.docx'; fs.writeFileSync(tmp, execSync(`unzip -p "${p}" "$(unzip -Z1 "${p}" | grep BBGN)"`));
    const doc = execSync(`unzip -p ${tmp} word/document.xml`).toString().replace(/<[^>]*>/g, '');
    ok(/28 tháng 10 năm 2026/.test(doc), 'Biên bản giao nhận ghi ngày theo HĐ: 28/10/2026');
    const ddhF = '/tmp/v38-ddh.docx'; fs.writeFileSync(ddhF, execSync(`unzip -p "${p}" "$(unzip -Z1 "${p}" | grep DDH)"`));
    ok(/Ngày giao hàng dự kiến: 28\/10\/2026/.test(execSync(`unzip -p ${ddhF} word/document.xml`).toString().replace(/<[^>]*>/g, '')), 'ĐĐH: Ngày giao hàng dự kiến 28/10/2026');
    ok(sql(`select to_char(ngay_hd, 'DD/MM/YYYY') from out_invoices where id = '${I1}'`) === '28/10/2026', 'ngày HĐ trên phiếu sửa theo PDF');
  }

  // 3) Mã tra cứu sai: báo + cho tải ĐĐH + BBGN
  await row('XHD38002').locator('button[title^="Cả bộ"]').click(); await a.waitForTimeout(3000);
  ok(await a.locator('text=Chưa lấy được HĐ đã ký').count() === 1, 'mã sai → nhắc bấm link mã tra cứu');
  await a.screenshot({ path: SHOTS + '/2-nhac.png' });
  [dl] = await Promise.all([a.waitForEvent('download', { timeout: 30000 }), (async () => { await a.click('button:has-text("Vẫn tải ĐĐH + BBGN")'); await a.waitForTimeout(1500);
    if (await a.locator('button:has-text("Bỏ qua")').count()) await a.click('button:has-text("Bỏ qua")'); })()]);
  names = execSync(`unzip -Z1 "${await dl.path()}"`).toString(); ok(/DDH_HD382/.test(names) && /BBGN_HD382/.test(names) && !/\.pdf/.test(names), 'vẫn tải được ĐĐH + BBGN');
  ok(sql(`select n from app.ky_fetch_fail where invoice_id = '${I2}'`) >= '1', 'ghi lần lỗi (tránh gọi lặp)');

  // 4) Lịch / trigger: quét HĐ còn thiếu bằng khóa CSDL
  const key = sql("select value from app.secrets where key = 'hdky_cron_key'");
  const r = await (await fetch('http://localhost:54321/functions/v1/hdky', { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cron-key': key }, body: JSON.stringify({ action: 'sweep' }) })).json();
  ok(r.ok === true && r.saved === 1 && sql(`select count(*) from out_invoice_files where invoice_id = '${I3}' and kind = 'ky'`) === '1', 'quét tự động tải HĐ còn thiếu: ' + JSON.stringify(r));
  const bad = await (await fetch('http://localhost:54321/functions/v1/hdky', { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cron-key': 'sai' }, body: JSON.stringify({ action: 'sweep' }) })).json();
  ok(bad.ok === false, 'khóa sai bị chặn');
  // người khác không lấy được HĐ của sale khác
  const tokB = await (await fetch('http://localhost:54321/auth/v1/token?grant_type=password', { method: 'POST', body: JSON.stringify({ email: 'b@nt.vn', password: 'Test1234!' }) })).json();
  const rb = await (await fetch('http://localhost:54321/functions/v1/hdky', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + tokB.access_token }, body: JSON.stringify({ action: 'get', invoice_id: I1 }) })).json();
  ok(rb.ok === false && /quyền/.test(rb.error), 'sale khác bị chặn: ' + rb.error);
  await browser.close();
  if (errors.length) { console.log(errors.join('\n')); process.exit(1); } console.log('V38 E2E OK'); process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
