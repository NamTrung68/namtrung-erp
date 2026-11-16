// v52: tab Đề xuất giá gửi APT — lọc theo xe, Excel toàn bộ dòng giá 3% (kể cả chờ hợp quy), Excel 2 cột Mã hàng APT + Giá đề xuất
const { chromium } = require('playwright'); const { execSync } = require('child_process');
const BASE = 'http://localhost:8080/'; const SHOTS = process.env.SHOTS || '/tmp/v52-shots';
const errors = []; const ok = (c, m) => { if (!c) errors.push('FAIL ' + m); else console.log('  ✓ ' + m); };
const sql = q => execSync(`psql -h /var/tmp/pg -p 5433 -U postgres -d nt_e2e -Atqc "${q.replace(/"/g, '\\"')}"`).toString().trim();
require('fs').mkdirSync(SHOTS, { recursive: true });
(async () => {
  const A = sql("select id from profiles where email='a@nt.vn'");
  const T1 = '00000000-0000-0000-0052-00000000e001', T2 = '00000000-0000-0000-0052-00000000e002';
  sql(`insert into acc_trucks(id, name, truck_date) values ('${T1}', 'Xe 52 Mot', '2026-11-10'), ('${T2}', 'Xe 52 Hai', '2026-11-14');
    insert into acc_lines(truck_id, line_key, luong, status, level, sale_id, md, apt_stt, hh, ten_apt, gia_nhap, gia_ap_dung, gia_khach, bien_nt, gia_de_xuat, sl_apt, issues) values
    ('${T1}', 'K1', 'A', 'ok', 3, '${A}', 'MD5201', 1, 'HH5201', 'Ấm siêu tốc', 1000, 1000, 1030, 0.03, null, 10, '{}'),
    ('${T1}', 'K7', 'A', 'ok', 3, '${A}', 'MD5206', 6, 'HH5207', 'Có mã khai báo', 1000, 1000, 1030, 0.03, null, 1, '{}'),
    ('${T1}', 'K2', 'A', 'ok', 2, '${A}', 'MD5201', 2, 'HH5202', 'Nồi cơm', 1000, 1000, 1050, 0.05, 1019, 5, '{}'),
    ('${T1}', 'K3', 'B', 'info', 3, '${A}', 'MD5202', 3, 'HH5203', 'Áo khoác (chờ hợp quy)', 2000, 2000, 2266, 0.133, null, 4, '{}'),
    ('${T1}', 'K4', 'A', 'blocked', 1, '${A}', 'MD5203', 4, 'HH5204', 'Quạt thiếu giá', 500, 500, null, null, null, 2, '{}'),
    ('${T1}', 'K5', 'C', 'info', 3, '${A}', 'MD5204', 5, 'HH5205', 'Xuất thẳng', 700, 700, 800, null, null, 1, '{}'),
    ('${T2}', 'K6', 'A', 'ok', 2, '${A}', 'MD5205', 1, 'HH5206', 'Xe khác', 1000, 1000, 1060, 0.06, 1029, 3, '{}')`);
  sql(`update acc_lines set ma_dong = 'MD5206-1' where line_key = 'K7' and truck_id = '${T1}'; update acc_lines set ma_kb_apt = 'MD5201-9' where line_key = 'K1' and truck_id = '${T1}'`);
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, acceptDownloads: true }); const p = await ctx.newPage();
  p.on('pageerror', e => errors.push('PAGEERROR ' + e.message));
  await p.goto(BASE); await p.fill('input[type=email]', 'a@nt.vn'); await p.fill('input[type=password]', 'Test1234!');
  await p.click('button[type=submit]'); await p.waitForSelector('h2.display', { timeout: 10000 });
  await p.goto(BASE + '#/acc/mine'); await p.waitForTimeout(1500);
  await p.locator('button', { hasText: 'Đề xuất giá gửi APT' }).first().click(); await p.waitForTimeout(800);
  ok(await p.locator('text=HH5206').count() >= 1, 'Tất cả xe: thấy dòng xe 2');
  const sel = p.locator('select').filter({ hasText: 'Tất cả xe' }).first();
  ok((await sel.locator('option').allTextContents())[1].startsWith('Xe 52 Hai'), 'xe mới nhất đứng đầu danh sách');
  await sel.selectOption(T1); await p.waitForTimeout(500);
  ok(await p.locator('text=HH5206').count() === 0, 'lọc Xe 52 Mot: ẩn dòng xe khác');
  await p.screenshot({ path: SHOTS + '/1-loc-xe.png' });
  const dl = async (txt) => { const [d] = await Promise.all([p.waitForEvent('download'), p.locator('button', { hasText: txt }).first().click()]); const f = SHOTS + '/' + d.suggestedFilename(); await d.saveAs(f); return f; };
  const f1 = await dl('Excel toàn bộ dòng giá 3%'); const f2 = await dl('Excel Mã hàng + Giá đề xuất');
  console.log('  files:', f1, f2);
  const dump = f => execSync(`python3 -c "import zipfile,re,sys;z=zipfile.ZipFile(sys.argv[1]);x=z.read('xl/worksheets/sheet1.xml').decode();print('\\n'.join('|'.join(re.findall(r'<v>([^<]*)</v>|<t[^>]*>([^<]*)</t>',row) and [a or b for a,b in re.findall(r'<v>([^<]*)</v>|<t[^>]*>([^<]*)</t>',row)]) for row in re.findall(r'<row[^>]*>(.*?)</row>',x)))" "${f}"`).toString().trim().split('\n');
  const r1 = dump(f1), r2 = dump(f2); console.log(r1.join('\n')); console.log(r2.join('\n'));
  ok(r1.length === 6, 'file 3%: 5 dòng (A + B, bỏ C, bỏ xe khác) + tiêu đề');
  ok(r1.some(r => r.startsWith('HH5203|2200|')), 'dòng chờ hợp quy giá 2266/1,03 = 2200');
  ok(r1.some(r => r.startsWith('HH5202|1019|')), 'dòng A: 1050/1,03 = 1019');
  ok(r1.some(r => r.startsWith('HH5204|Xe 52 Mot')), 'dòng thiếu giá khách: cột giá trống');
  ok(r2[0] === 'Mã hàng APT|Giá đề xuất APT xuất|Xe|Mã đơn|Mã khai báo' && r2.length === 5, 'file gọn: A mã hàng, B giá, C xe, D mã đơn, E mã khai báo — 4 dòng đủ giá');
  ok(r2.includes('HH5207|1000|Xe 52 Mot|MD5206|MD5206-1'), 'mã khai báo lấy từ file xe');
  ok(r2.includes('HH5201|1000|Xe 52 Mot|MD5201|MD5201-9'), 'thiếu mã file xe → lấy mã APT ghi trên nháp');
  await browser.close();
  if (errors.length) { console.log(errors.join('\n')); process.exit(1); } console.log('v52 OK');
})();
