// v45: người duyệt sửa loại đơn nghỉ (chọn nhầm) rồi duyệt
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const SHOTS = process.env.SHOTS || '/tmp/v45-shots';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
require('fs').mkdirSync(SHOTS, { recursive: true });
(async () => {
  const d = sql("select x::date from generate_series(app.vn_today() + 7, app.vn_today() + 20, interval '1 day') x where extract(isodow from x) between 1 and 5 order by x limit 1");
  const A = sql("select id from profiles where email='a@nt.vn'");
  sql(`set session_replication_role = replica; insert into leave_requests(profile_id, leave_type, start_date, end_date, part, reason, days, status) values ('${A}', 'che_do', '${d}', '${d}', 'pm', 'Việc nhà', 0.5, 'cho_duyet')`);
  const b = await chromium.launch(); const p = await (await b.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
  p.on('pageerror', e => errors.push(e.message));
  await p.goto(BASE); await p.fill('input[type=email]', 'lead@nt.vn'); await p.fill('input[type=password]', 'Test1234!'); await p.click('button[type=submit]'); await p.waitForSelector('h2.display');
  await p.goto(BASE + '#/hr/approvals'); await p.waitForTimeout(1500);
  const row = p.locator('tr', { hasText: 'Việc riêng có lương' });
  await row.locator('button:has-text("Sửa loại")').click(); await p.waitForTimeout(500);
  await p.locator('.fixed select').last().selectOption('phep_nam'); await p.screenshot({ path: SHOTS + '/1-sua-loai.png' });
  await p.click('button:has-text("Sửa loại") >> nth=-1'); await p.waitForTimeout(1200);
  ok(await p.locator('tr', { hasText: 'Nghỉ phép năm' }).count() === 1, 'dòng đổi sang Nghỉ phép năm');
  await p.locator('tr', { hasText: 'Nghỉ phép năm' }).locator('button:has-text("Duyệt")').click(); await p.waitForTimeout(1200);
  ok(sql(`select leave_type||'|'||status from leave_requests where profile_id='${A}' and start_date='${d}'`) === 'phep_nam|da_duyet', 'đã sửa loại + duyệt');
  await b.close(); if (errors.length) { console.log(errors.join('\n')); process.exit(1); } console.log('V45 E2E OK');
})().catch(e => { console.error(e); process.exit(1); });
