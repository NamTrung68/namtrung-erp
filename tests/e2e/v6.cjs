// Bản 6: chấm công trên điện thoại, sinh nhật, đặt lại mật khẩu
const { chromium } = require('playwright');
const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/';
const SHOTS = process.env.SHOTS || '/tmp/claude-0/-home-claude/35bb19b3-0ac5-5cc1-996a-06924576031f/scratchpad/shots7';
const errors = [];
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atc "${q.replace(/"/g, '\\"')}"`).toString().trim();
(async () => {
  require('fs').mkdirSync(SHOTS, { recursive: true });
  const browser = await chromium.launch();
  const login = async (email, viewport = { width: 1440, height: 900 }) => { const ctx = await browser.newContext({ viewport }); const p = await ctx.newPage();
    p.on('console', m => { if (m.type() === 'error' && !/fonts.g|img.vietqr|Failed to load resource/.test(m.text())) errors.push(`[${email}] ${m.text()}`); }); p.on('pageerror', e => errors.push('PAGEERROR ' + e.message));
    await p.goto(BASE); await p.fill('input[type=email]', email); await p.fill('input[type=password]', 'Test1234!'); await p.click('button[type=submit]'); await p.waitForSelector('h2.display', { timeout: 10000 }); return p; };
  // dữ liệu chấm công có ảnh (giống máy thật)
  const uid = sql("select id from profiles where email='a@nt.vn'");
  execSync(`curl -s -X POST -H "Content-Type: image/jpeg" --data-binary @${SHOTS}/../s.jpg "http://localhost:54321/storage/v1/object/selfies/${uid}/t.jpg"`);
  sql(`insert into attendance_events(profile_id,kind,at,work_date,ip,ip_ok,selfie_path) values ('${uid}','in',now()-interval '1 day 2 hours',(now() at time zone 'Asia/Ho_Chi_Minh')::date-1,'1.2.3.4',true,'${uid}/t.jpg'),('${uid}','out',now()-interval '1 day',(now() at time zone 'Asia/Ho_Chi_Minh')::date-1,'1.2.3.4',true,'${uid}/t.jpg'),('${uid}','in',now()-interval '1 hour',(now() at time zone 'Asia/Ho_Chi_Minh')::date,'1.2.3.4',true,'${uid}/t.jpg')`);
  const m = await login('a@nt.vn', { width: 390, height: 844 });
  await m.goto(BASE + '#/hr/attendance'); await m.waitForTimeout(1500);
  const w = await m.evaluate(() => document.documentElement.scrollWidth); if (w > 392) errors.push('Chấm công tràn ngang: ' + w);
  await m.screenshot({ path: SHOTS + '/m-attendance.png', fullPage: true });
  // Sinh nhật: tự khai ở Tài khoản → hiện ở Hôm nay
  const d = new Date(Date.now() + 7 * 3600e3); const dob = `1996-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
  await m.goto(BASE + '#/account'); await m.waitForTimeout(900);
  await m.locator('label:has-text("Ngày sinh") input[type=date]').fill(dob); await m.locator('label:has-text("Ngày sinh") button:has-text("Lưu")').click(); await m.waitForTimeout(900);
  await m.goto(BASE + '#/'); await m.waitForTimeout(1300);
  if (!(await m.textContent('body')).includes('Hôm nay sinh nhật bạn')) errors.push('Không hiện sinh nhật hôm nay');
  await m.screenshot({ path: SHOTS + '/m-today-birthday.png', fullPage: true });
  const lead = await login('lead@nt.vn'); await lead.goto(BASE + '#/'); await lead.waitForTimeout(1300);
  await lead.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await lead.waitForTimeout(300);
  await lead.screenshot({ path: SHOTS + '/today-birthday.png' });
  // Admin đặt lại mật khẩu + ngày sinh
  const ad = await login('namtrung20266@gmail.com'); await ad.goto(BASE + '#/admin/users'); await ad.waitForTimeout(1000);
  await ad.locator('tr', { hasText: 'lead@nt.vn' }).click(); await ad.waitForTimeout(800);
  await ad.locator('label:has-text("Ngày sinh") input').fill('1990-03-15');
  const before = sql("select coalesce(encrypted_password,'') from auth.users where email='lead@nt.vn'");
  await ad.click('button:has-text("Đặt lại mật khẩu")'); await ad.waitForTimeout(300);
  await ad.locator('div.fixed.inset-0.z-50 button:text-is("Đặt lại")').last().click(); await ad.waitForTimeout(1200);
  await ad.screenshot({ path: SHOTS + '/reset-pw.png' });
  if (sql("select coalesce(encrypted_password,'') from auth.users where email='lead@nt.vn'") === before) errors.push('Mật khẩu không đổi');
  await ad.locator('div.fixed.inset-0.z-50 button:text-is("Lưu")').last().click(); await ad.waitForTimeout(900);
  if (sql("select dob from hr_records r join profiles p on p.id=r.profile_id where p.email='lead@nt.vn'") !== '1990-03-15') errors.push('Không lưu ngày sinh');
  await browser.close();
  if (errors.length) { console.log(errors.join('\n')); process.exit(1); }
  console.log('V6 E2E OK');
})().catch(e => { console.log('FAILED', e.message.split('\n')[0], '\n' + errors.join('\n')); process.exit(1); });
