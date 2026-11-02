// v20: PDF hóa đơn trên Drive — kế toán tải hàng loạt, ghép phiếu; sale xem / gửi / khách OK; bản mới; bản đã ký; không xem chéo
// Cần: tests/e2e/restart.sh + apps-script-mock.mjs (:8091). File PDF mẫu để ngoài repo (FX/sample.pdf) vì có thông tin khách thật.
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const FX = process.env.FX || '/home/claude/fx20'; const SHOTS = process.env.SHOTS || '/tmp/v20-shots';
const TOKEN = 'e2e-backup-token-0123456789abcdef0123456789';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
fs.mkdirSync(SHOTS, { recursive: true }); const UP = fs.mkdtempSync('/tmp/v20-up-');
const fx = name => { const p = path.join(UP, name); fs.copyFileSync(path.join(FX, 'sample.pdf'), p); return p; };
(async () => {
  const A = sql("select id from profiles where email='a@nt.vn'"), B = sql("select id from profiles where email='b@nt.vn'");
  sql(`insert into app.secrets(key, value) values ('backup_token_hash', encode(digest('${TOKEN}'::text, 'sha256'::text), 'hex')) on conflict (key) do update set value = excluded.value`);
  sql(`insert into settings(key, value) values ('drive', '{"url":"http://localhost:8091"}') on conflict (key) do update set value = excluded.value`);
  const IT = sql("insert into out_items(ma_hang, ten, dvt, vat, sl_nhap, dg_nhap) values ('HH-E2E-20', 'Hộp đựng giấy vải polyester', 'Chiếc', 0.08, 2000, 50000) returning id");
  const mk = (sale, name, mst, sl) => { const id = sql(`insert into out_invoices(sale_id, buyer_name, tax_code, status) values ('${sale}', '${name}', '${mst}', 'cho_nhap') returning id`);
    sql(`insert into out_invoice_lines(invoice_id, item_id, stt, sl, don_gia, vat) values ('${id}', '${IT}', 1, ${sl}, 54000, 0.08)`); return id; };
  const I1 = mk(A, 'HỘ KINH DOANH TÀI ĐỨC', '040091011932', 400), I2 = mk(A, 'HỘ KINH DOANH TÀI ĐỨC', '040091011932', 100), I3 = mk(B, 'CÔNG TY B', '0700871570', 200);
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1366, height: 900 }) => {
    const ctx = await browser.newContext({ viewport, acceptDownloads: true, hasTouch: viewport.width < 600, isMobile: viewport.width < 600 }); const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|Failed to load resource|Không có quyền/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE); await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 }); return page;
  };
  const uploadAs = async (k, files) => {
    if (await k.locator('div.fixed.inset-0.z-50 button:text-is("Đóng")').count()) await k.locator('div.fixed.inset-0.z-50 button:text-is("Đóng")').first().click();
    await k.goto(BASE + '#/out'); await k.waitForTimeout(1200);
    await k.click('button:has-text("Tải PDF hóa đơn")');
    await k.setInputFiles('input[type=file][accept*=pdf]', files);
    await k.waitForSelector('button:has-text("Lưu Drive & gắn phiếu")', { timeout: 15000 }); await k.waitForTimeout(2500);
  };
  // ===== 1. Kế toán tải nháp: tên chuẩn, tên cũ (phiếu B không cùng MST), tên lạ (đọc chữ trong PDF) =====
  console.log('1. Kế toán tải nháp');
  const k = await login('kt@nt.vn');
  await uploadAs(k, [fx('NHAP_040091011932_23328000_20261031_1.pdf'), fx('NHAP_0700871570_11664000_20261102_2.pdf'), fx('scan hoa don.pdf')]);
  await k.screenshot({ path: SHOTS + '/1-upload-preview.png', fullPage: true });
  const txt = await k.locator('div.fixed.inset-0.z-50').innerText();
  ok(/\(đọc trong file\)/.test(txt), 'file tên lạ: đọc MST / tổng tiền trong PDF bằng pdf.js');
  ok(/2 sẵn sàng/.test(txt), 'tự ghép 2 file (1 file trùng tiền với file đầu → cần chọn tay hoặc trùng)');
  await k.click('button:has-text("Lưu Drive & gắn phiếu")'); await k.waitForTimeout(4000);
  await k.screenshot({ path: SHOTS + '/2-upload-done.png', fullPage: true });
  ok(sql(`select status || '|' || (select count(*) from out_invoice_files where invoice_id='${I1}') from out_invoices where id='${I1}'`) === 'da_nhap|1', 'phiếu A có nháp v1, chuyển Đã xuất nháp');
  ok(sql(`select status || '|' || (select count(*) from out_invoice_files where invoice_id='${I3}') from out_invoices where id='${I3}'`) === 'da_nhap|1', 'phiếu B có nháp v1');
  ok(sql(`select count(*) from out_invoice_files where invoice_id='${I2}'`) === '0', 'phiếu khác tiền không bị gắn nhầm');
  ok(execSync('cat /var/tmp/as.log').toString().includes('HD nhap/'), 'file lưu vào thư mục HD nhap/<tháng>/<sale> trên Drive');
  // ===== 2. Sale A trên điện thoại: mở từ thông báo, xem, gửi khách, khách OK =====
  console.log('2. Sale A xem trên điện thoại');
  ok(sql(`select count(*) from notifications where recipient_id='${A}' and link='#/out?inv=${I1}'`) === '1', 'sale A nhận thông báo kèm link mở phiếu');
  const s = await login('a@nt.vn', { width: 390, height: 844 });
  await s.goto(BASE + '#/out?inv=' + I1); await s.waitForSelector('text=Xem HĐ nháp v1', { timeout: 10000 });
  await s.waitForTimeout(1500);   // tải sẵn file khi mở phiếu
  const t0 = Date.now(); await s.click('button:has-text("Xem HĐ nháp v1")');
  await s.waitForSelector('[data-hd-viewer] canvas', { timeout: 15000 }); const ms = Date.now() - t0;
  ok(ms < 1500, `mở HĐ đã tải sẵn: ${ms} ms`);
  await s.waitForTimeout(800); await s.screenshot({ path: SHOTS + '/3-sale-mobile-viewer.png' });
  ok(await s.locator('[data-hd-viewer] button:has-text("✕ Đóng")').isVisible(), 'nút Đóng to trên điện thoại');
  ok(await s.locator('[data-hd-viewer] button:has-text("Chia sẻ")').count() === 1, 'nút Chia sẻ (Zalo) trên điện thoại');
  await s.click('[data-hd-viewer] button:has-text("Đã gửi khách")'); await s.waitForTimeout(1200);
  ok(sql(`select sent_at is not null from out_invoice_files where invoice_id='${I1}'`) === 't', 'ghi nhận đã gửi khách');
  await s.click('button:has-text("Xem HĐ nháp v1")').catch(() => {}); await s.waitForTimeout(500);
  await s.click('[data-hd-viewer] button:has-text("Khách OK")'); await s.waitForTimeout(1500);
  ok(sql(`select status from out_invoices where id='${I1}'`) === 'xac_nhan_ky', 'khách OK → chờ kế toán ký');
  ok(await s.locator('[data-hd-viewer]').count() === 0, 'viewer tự đóng sau khi xác nhận');
  await s.screenshot({ path: SHOTS + '/4-sale-after-ok.png' });
  // ===== 3. Không xem chéo =====
  console.log('3. Không xem chéo');
  const fB = sql(`select id from out_invoice_files where invoice_id='${I3}'`);
  const cross = await s.evaluate(async ([u, key, f]) => { const sess = JSON.parse(Object.entries(localStorage).find(([k]) => /auth|session|sb/i.test(k))?.[1] || '{}');
    const tok = sess.access_token || sess.currentSession?.access_token;
    const r = await fetch(u + '/rest/v1/rpc/out_file_ticket', { method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_file: f }) });
    const r2 = await fetch(u + '/rest/v1/out_invoice_files?select=drive_id', { headers: { apikey: key, Authorization: 'Bearer ' + tok } });
    return [r.status, r2.status, !!tok]; }, [ 'http://localhost:54321', fs.readFileSync('/var/tmp/anon.jwt', 'utf8').trim(), fB ]);
  ok(cross[2] && cross[0] >= 400, `sale A xin vé xem file của sale B → bị chặn (${cross[0]})`);
  ok(cross[1] >= 400, `sale A đọc thẳng bảng file → bị chặn (${cross[1]})`);
  await s.goto(BASE + '#/out?inv=' + I3); await s.waitForTimeout(2000);
  ok(await s.locator('text=Xem HĐ nháp').count() === 0, 'mở link phiếu của sale B → không thấy file');
  const asLog = execSync('cat /var/tmp/as.log').toString();
  // ===== 4. Kế toán tải bản v2 → xác nhận cũ hủy, sale được báo =====
  console.log('4. Bản nháp mới v2');
  await uploadAs(k, [fx('NHAP_040091011932_23328000_20261102_9.pdf')]);
  const t4 = await k.locator('div.fixed.inset-0.z-50').innerText();
  ok(/1 sẵn sàng/.test(t4), 'bản v2 tự ghép đúng phiếu đã có nháp');
  await k.click('button:has-text("Lưu Drive & gắn phiếu")'); await k.waitForTimeout(3000);
  ok(sql(`select status || '|' || (select max(version) from out_invoice_files where invoice_id='${I1}') from out_invoices where id='${I1}'`) === 'da_nhap|2', 'v2 → phiếu quay về chờ sale, hủy xác nhận cũ');
  ok(sql(`select count(*) from notifications where recipient_id='${A}' and title like 'HĐ nháp mới v2%'`) === '1', 'sale A được báo bản mới');
  await s.goto(BASE + '#/out?inv=' + I1); await s.waitForSelector('text=Có bản nháp mới v2', { timeout: 10000 });
  ok(true, 'sale thấy nhãn đỏ "Có bản nháp mới v2 — chưa gửi khách"');
  await s.screenshot({ path: SHOTS + '/5-sale-new-version.png' });
  await s.click('button:has-text("Xem HĐ nháp v2")'); await s.waitForSelector('[data-hd-viewer] canvas', { timeout: 15000 });
  await s.click('[data-hd-viewer] button:has-text("✕ Đóng")'); await s.waitForTimeout(300);
  ok(await s.locator('[data-hd-viewer]').count() === 0, 'nút Đóng đóng viewer');
  // trưởng nhóm của A xem được
  const l = await login('lead@nt.vn'); await l.goto(BASE + '#/out?inv=' + I1); await l.waitForSelector('text=Xem HĐ nháp v2', { timeout: 10000 });
  await l.click('button:has-text("Xem HĐ nháp v2")'); await l.waitForSelector('[data-hd-viewer] canvas', { timeout: 15000 }); ok(true, 'trưởng nhóm xem được HĐ của sale trong nhóm');
  await s.click('button:has-text("Xem HĐ nháp v2")'); await s.waitForTimeout(500); await s.click('[data-hd-viewer] button:has-text("Đã gửi khách")'); await s.waitForTimeout(800);
  await s.click('[data-hd-viewer] button:has-text("Khách OK")'); await s.waitForTimeout(1500);
  ok(sql(`select status from out_invoices where id='${I1}'`) === 'xac_nhan_ky', 'khách OK bản v2');
  // ===== 5. Bản đã ký =====
  console.log('5. Bản đã ký');
  await uploadAs(k, [fx('KY_1C26TYY-00000928_040091011932_23328000.pdf')]);
  ok(/1 sẵn sàng/.test(await k.locator('div.fixed.inset-0.z-50').innerText()), 'bản ký tự ghép');
  await k.click('button:has-text("Lưu Drive & gắn phiếu")'); await k.waitForTimeout(3000);
  ok(sql(`select status || '|' || so_hd from out_invoices where id='${I1}'`) === 'da_ky|928', 'phiếu Đã ký, điền số HĐ');
  ok(execSync('cat /var/tmp/as.log').toString().includes('HD da ky/'), 'bản ký lưu thư mục HD da ky');
  const d = await login('a@nt.vn'); await d.goto(BASE + '#/out?inv=' + I1); await d.waitForSelector('text=Xem / in bản đã ký', { timeout: 10000 });
  await d.click('button:has-text("Xem / in bản đã ký")'); await d.waitForSelector('[data-hd-viewer] canvas', { timeout: 15000 });
  ok(await d.locator('[data-hd-viewer] button:has-text("Mở / in PDF")').count() === 1, 'máy tính: nút Mở / in PDF bản đã ký');
  await d.waitForTimeout(600); await d.screenshot({ path: SHOTS + '/6-sale-desktop-signed.png' });
  // danh sách phiếu
  await k.locator('div.fixed.inset-0.z-50 button:text-is("Đóng")').first().click();
  await k.goto(BASE + '#/out'); await k.waitForTimeout(1500); await k.click('button:has-text("Tất cả")'); await k.waitForTimeout(1200);
  await k.screenshot({ path: SHOTS + '/7-acc-list.png', fullPage: true });
  ok(await k.locator('text=📄 Đã ký').count() >= 1, 'danh sách: nhãn file đã ký');
  ok(sql(`select count(*) from audit_logs where action='VIEW_HD_FILE'`) >= '4', 'ghi nhật ký mỗi lần xem file');
  await browser.close();
  console.log(errors.length ? errors.join('\n') : 'V20 E2E PASSED');
  process.exit(errors.length ? 1 : 0);
})().catch(e => { console.error(e); console.log(errors.join('\n')); process.exit(1); });
