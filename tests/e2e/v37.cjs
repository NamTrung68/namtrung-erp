// v37: ảnh dòng báo giá (lập + bản in), đơn quên chấm đến / quên chấm về (tạo → duyệt sửa giờ)
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const SHOTS = process.env.SHOTS || '/tmp/v37-shots'; const IMG = process.env.IMG;
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
require('fs').mkdirSync(SHOTS, { recursive: true });
(async () => {
  const A = sql("select id from profiles where email='a@nt.vn'");
  const C = sql(`insert into customers(code, contact_name, phone, customer_type, source, owner_id) values ('KH37', 'Khách ảnh 37', '+84 912 000 371', 'nha_buon', 'tu_tim_zalo', '${A}') returning id`).split('\n')[0];
  const browser = await chromium.launch();
  const login = async (email) => {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } }); const page = await ctx.newPage();
    page.on('pageerror', e => errors.push(`[${email}] PAGEERROR ${e.message}`));
    page.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); });
    await page.goto(BASE); await page.fill('input[type=email]', email); await page.fill('input[type=password]', 'Test1234!');
    await page.click('button[type=submit]'); await page.waitForSelector('h2.display', { timeout: 10000 }); return page;
  };
  // 1) Báo giá có ảnh
  const a = await login('a@nt.vn');
  await a.goto(BASE + `#/crm/quote?customer=${C}`); await a.waitForTimeout(1500);
  await a.locator('tbody textarea').first().fill('Đèn LED trang trí 5m');
  const nums = a.locator('tbody tr').first().locator('input:not([type=file])');
  await nums.nth(2).fill('100'); await nums.nth(3).fill('12');
  await a.locator('tbody input[type=file]').first().setInputFiles(IMG); await a.waitForTimeout(1200);
  ok(await a.locator('tbody tr').first().locator('img').count() === 1, 'ảnh hiện trên dòng hàng sau khi tải');
  await a.click('text=Thêm dòng hàng'); await a.locator('tbody textarea').nth(1).fill('Dây cáp không ảnh');
  const n2 = a.locator('tbody tr').nth(1).locator('input:not([type=file])'); await n2.nth(2).fill('10'); await n2.nth(3).fill('5');
  await a.screenshot({ path: SHOTS + '/quote-editor.png' });
  await a.click('button:has-text("Lưu nháp")'); await a.waitForTimeout(2000);
  ok(sql("select count(*) from quotation_lines where image is not null and name like 'Đèn LED%'") === '1', 'lưu đường dẫn ảnh vào dòng báo giá');
  await a.reload(); await a.waitForTimeout(1800);
  ok(await a.locator('tbody img').count() === 1, 'mở lại báo giá vẫn có ảnh');
  await a.click('button:has-text("Xem và in")'); await a.waitForTimeout(1200);
  const pimg = a.locator('.print-area table img');
  ok(await pimg.count() === 1 && (await pimg.first().boundingBox()).width >= 90, 'bản in có cột ảnh, ảnh ≥ 90px');
  ok(await pimg.first().evaluate(i => i.complete && i.naturalWidth > 0), 'ảnh trên bản in tải được');
  await a.locator('.print-area').screenshot({ path: SHOTS + '/quote-print.png' });
  await a.keyboard.press('Escape');

  // 2) Đơn quên chấm đến / về
  const d2 = sql("select to_char(app.vn_today() - 2, 'YYYY-MM-DD')");
  await a.goto(BASE + '#/hr/attendance'); await a.waitForTimeout(1200); await a.click('text=Đơn công'); await a.waitForTimeout(600);
  await a.click('button:has-text("Tạo đơn")'); await a.waitForTimeout(500);
  const m = a.locator('body');
  await m.locator('input[type=date]').fill(d2); await m.locator('input[type=time]').fill('08:10'); await m.locator('textarea').fill('Quên chấm khi đến văn phòng');
  await a.screenshot({ path: SHOTS + '/req-new.png' });
  await a.click('button:has-text("Gửi đơn")'); await a.waitForTimeout(1200);
  await a.click('button:has-text("Tạo đơn")'); await a.waitForTimeout(500);
  await m.locator('select').first().selectOption('quen_cham_ra');
  await m.locator('input[type=date]').fill(d2); await m.locator('input[type=time]').fill('17:40'); await m.locator('textarea').fill('Quên chấm khi về nhà');
  await a.click('button:has-text("Gửi đơn")'); await a.waitForTimeout(1200);
  ok(sql(`select string_agg(kind || '@' || to_char(req_time,'HH24:MI'), ',' order by kind) from attendance_requests where profile_id='${A}' and work_date='${d2}'`) === 'quen_cham_ra@17:40,quen_cham_vao@08:10', 'tạo 2 đơn quên chấm đến / về có ngày + giờ');
  await a.screenshot({ path: SHOTS + '/req-list.png' });

  const g = await login('namtrung20266@gmail.com');
  await g.goto(BASE + '#/hr/approvals'); await g.waitForTimeout(1500);
  await g.screenshot({ path: SHOTS + '/approvals.png', fullPage: true });
  const rowIn = g.locator('tr', { hasText: 'Quên chấm công đến' });
  await rowIn.locator('button:has-text("Duyệt")').click(); await g.waitForTimeout(800);
  const t = g.locator('input[type=time]'); ok(await t.inputValue() === '08:10', 'ô giờ vào điền sẵn giờ nhân viên khai');
  await t.fill('08:25'); await g.screenshot({ path: SHOTS + '/approve-in.png' });
  await g.locator('.fixed button:has-text("Duyệt")').last().click(); await g.waitForTimeout(1200);
  const rowOut = g.locator('tr', { hasText: 'Quên chấm công về' });
  await rowOut.locator('button:has-text("Duyệt")').click(); await g.waitForTimeout(800);
  ok(await g.locator('input[type=time]').inputValue() === '17:40', 'ô giờ về điền sẵn giờ nhân viên khai');
  await g.locator('.fixed button:has-text("Duyệt")').last().click(); await g.waitForTimeout(1200);
  ok(sql(`select string_agg(kind || '=' || coalesce(to_char(confirm_in,'HH24:MI'), to_char(confirm_out,'HH24:MI')), ',' order by kind) from attendance_requests where profile_id='${A}' and work_date='${d2}' and status='da_duyet'`) === 'quen_cham_ra=17:40,quen_cham_vao=08:25', 'duyệt: giờ vào sửa 08:25, giờ về giữ 17:40');
  ok(sql(`select (app.day_info('${A}', 'office', null, '${d2}')->>'late')::int`) === '25', 'bảng công tính đi muộn 25 phút theo giờ đã duyệt');
  await a.click('text=Chấm công của tôi'); await a.waitForTimeout(1200);
  await a.screenshot({ path: SHOTS + '/my-history.png' });
  ok(await a.locator('text=theo đơn').count() >= 2, 'lịch sử chấm công hiện giờ theo đơn đã duyệt');
  await browser.close();
  if (errors.length) { console.log(errors.join('\n')); process.exit(1); } console.log('V37 E2E OK');
})().catch(e => { console.error(e); process.exit(1); });
