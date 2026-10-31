// v13: dòng chưa có chủ (sale nhận), xuất thẳng, kế toán chốt kèm giá khách, ghép dòng HĐ lẻ, HĐ nháp
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  const A = sql("select id from profiles where email='a@nt.vn'"), B = sql("select id from profiles where email='b@nt.vn'");
  sql(`insert into settings(key, value) values ('company', '{"name":"CÔNG TY TNHH NAM TRUNG","tax_code":"0100000000","address":"Hà Nội","hotline":"0900000000"}') on conflict (key) do update set value = excluded.value`);
  const T = sql("insert into acc_trucks(name, truck_date) values ('Xe E2E 13', current_date - 20) returning id");
  const C = sql(`insert into customers(source, customer_type, contact_name, company_name, tax_code, address, sys_code, owner_id) values ('Khác','Doanh nghiệp','Anh Hùng','Cty Hùng Phát','0109999999','Hải Phòng','NT93844','${A}') returning id`);
  sql(`insert into acc_lines(truck_id, line_key, apt_stt, hh, ten_apt, sl_apt, dvt_apt, gia_nhap, luong, status, issues, due_at) values
    ('${T}','F1',1,'HH901','Áo khoác nữ',10,'Cái',19000,'A','blocked','{Không có đơn trên hệ thống}', now() + interval '24 hours')`);
  sql(`insert into acc_lines(truck_id, line_key, apt_stt, hh, ten_apt, sl_apt, dvt_apt, gia_nhap, gia_khach, md, ma_kh, sale_id, luong, status, issues, bien_nt) values
    ('${T}','F2',2,'HH902','Giày thể thao',5,'Đôi',100000,110000,'MD9002','NT93844','${A}','A','blocked','{Biên NT 10% > 4%}', 0.1),
    ('${T}','F3',3,'HH903','Túi xách',8,'Cái',50000,51500,'MD9003','NT93844','${A}','A','ok','{}', 0.03),
    ('${T}','F4',4,'HH904','Mũ lưỡi trai',20,'Cái',20000,0,'MD9004',null,'${A}','A','blocked','{Giá khách = 0}', null)`);
  const IV = sql("insert into acc_invoices(ky_hieu, so_hd, ngay, mst_ban) values ('C26TYT','00077001', current_date, '0110746961') returning id");
  sql(`insert into acc_invoice_lines(invoice_id, stt, hh, ten, dvt, sl, dg, tt, result) values ('${IV}',1,'HH777','Hàng mã lạ','Cái',8,50000,400000,'khong_thuoc_xe')`);
  ok(sql("select customer_id is not null from acc_lines where line_key='F2'") === 't', 'mã KH gắn khách');
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => {
    const ctx = await browser.newContext({ viewport }); const page = await ctx.newPage();
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    await page.goto(BASE); await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 }); return page;
  };
  const M = 'div.fixed.inset-0.z-50';
  // Sale B nhận dòng chưa có chủ
  const b = await login('b@nt.vn', { width: 390, height: 844 });
  await b.goto(BASE + '#/acc/mine'); await b.waitForTimeout(1500);
  await b.click('button:has-text("Dòng chưa có chủ")'); await b.waitForTimeout(500);
  await b.screenshot({ path: SHOTS + '/v13-free.png', fullPage: true });
  await b.fill('input[placeholder="VD: MD2650"]', 'md9001'); await b.locator('input[inputmode=numeric]').first().fill('20000');
  await b.click('button:has-text("Nhận dòng này")'); await b.waitForTimeout(1200);
  ok(sql(`select status || claim_md || sale_id from acc_lines where line_key='F1'`) === `repliedMD9001${B}`, 'sale nhận dòng');
  // Sale A: tab Tất cả, đề xuất giá, xuất thẳng, nhập giá khách
  const s = await login('a@nt.vn', { width: 1280, height: 900 });
  await s.goto(BASE + '#/acc/mine'); await s.waitForTimeout(1500);
  ok(!(await s.textContent('body')).includes('Áo khoác nữ'), 'A không thấy dòng B đã nhận');
  await s.screenshot({ path: SHOTS + '/v13-todo.png', fullPage: true });
  const card = n => s.locator('div.rounded-2xl', { hasText: n });
  await card('Giày thể thao').locator('button:has-text("Đơn APT xuất thẳng")').click(); await card('Giày thể thao').locator('button:text-is("Gửi")').click(); await s.waitForTimeout(1200);
  ok(sql("select luong || status from acc_lines where line_key='F2'") === 'Cinfo', 'xuất thẳng đổi luồng');
  ok(sql(`select 'F2' = any(xt_keys) from acc_trucks where id='${T}'`) === 't', 'xuất thẳng ghi vào xe');
  await card('Mũ lưỡi trai').locator('button:has-text("Đã sửa hệ thống")').click();
  ok(await card('Mũ lưỡi trai').locator('button:text-is("Gửi")').isDisabled(), 'thiếu giá khách → khóa Gửi');
  await card('Mũ lưỡi trai').locator('input[inputmode=numeric]').fill('21000'); await card('Mũ lưỡi trai').locator('button:text-is("Gửi")').click(); await s.waitForTimeout(1200);
  ok(sql("select claim_gia from acc_lines where line_key='F4'") === '21000', 'sale nhập giá khách');
  await s.click('button:has-text("Tất cả dòng của tôi")'); await s.waitForTimeout(500); await s.screenshot({ path: SHOTS + '/v13-all.png', fullPage: true });
  ok((await s.textContent('body')).includes('Túi xách'), 'tab tất cả');
  // Kế toán chốt
  const ad = await login('kt@nt.vn');
  await ad.goto(BASE + `#/acc?truck=${T}`); await ad.waitForTimeout(1500); await ad.screenshot({ path: SHOTS + '/v13-truck.png' });
  await ad.locator('tr', { hasText: 'Áo khoác nữ' }).click(); await ad.waitForTimeout(700); await ad.screenshot({ path: SHOTS + '/v13-line.png' });
  await ad.click('button:has-text("Chốt dòng")'); await ad.waitForTimeout(400);
  ok((await ad.locator(M).last().locator('input[inputmode=numeric]').inputValue()) === '20000', 'chốt: điền sẵn giá sale');
  await ad.locator(M).last().locator('button:has-text("✓ Chốt")').click(); await ad.waitForTimeout(1500);
  ok(sql("select status || '|' || md || '|' || phan_hoi from acc_lines where line_key='F1'") === 'ok|MD9001|XUẤT GIÁ 19417', 'kế toán chốt → XUẤT GIÁ 19417');
  // Ghép dòng HĐ lẻ
  await ad.goto(BASE + '#/acc'); await ad.waitForTimeout(800); await ad.click('button:has-text("Theo dõi HĐ đầu vào")'); await ad.waitForTimeout(1500);
  await ad.screenshot({ path: SHOTS + '/v13-track.png' });
  await ad.click('button:has-text("Dòng HĐ chưa thuộc xe nào")'); await ad.waitForTimeout(1200);
  await ad.click('button:text-is("Ghép")'); await ad.waitForTimeout(500); await ad.fill(`${M} input`, 'Túi'); await ad.waitForTimeout(1200);
  await ad.screenshot({ path: SHOTS + '/v13-link.png' });
  await ad.locator(M).locator('button:text-is("Chọn")').first().click(); await ad.waitForTimeout(1200);
  ok(sql("select inv_no from acc_lines where line_key='F3'") === '00077001', 'ghép tay dòng HĐ');
  await ad.click('button:has-text("Đã có HĐ")'); await ad.waitForTimeout(1500); ok((await ad.textContent('body')).includes('00077001'), 'tab đã có HĐ');
  await browser.close();
  console.log(errors.length ? errors.join('\n') : 'V13 E2E OK');
})();
