// Đối soát xe APT: so với kết quả skill doi-soat-xe-apt trên xe 25/10 (dữ liệu thật để ngoài repo, thiếu thì bỏ qua)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { DEFAULT_ACC_CFG, parseApt, parseKhaiBao, parseTkn, reconcile, parseInvoiceXml, judgeInvoiceLine, normMd, normKb, sim, vnNum, assign, matchAptSys, aptPriceList } from '../src/lib/doisoat';

test('tiện ích', () => {
  assert.equal(normMd('2411'), 'MD2411'); assert.equal(normMd('MD2411'), 'MD2411'); assert.equal(normMd(2411), 'MD2411');
  assert.equal(vnNum('938.000'), 938000); assert.equal(vnNum('1.881,50'), 1881.5); assert.equal(vnNum(12.5), 12.5);
  assert.ok(sim('Túi xách tay', 'tui xach tay') === 1);
  const m = assign([[0.9, 0.1], [0.8, 0.85]], 0.5); assert.deepEqual([m.get(0)![0], m.get(1)![0]], [0, 1]);
});

const FX = 'tests/fixtures/xe2510.json';
test('xe 25/10 khớp kết quả skill', { skip: !existsSync(FX) }, () => {
  const fx = JSON.parse(readFileSync(FX, 'utf8'));
  const apt = parseApt(fx.apt), sys = parseKhaiBao(fx.kb), tk = parseTkn(fx.tkn);
  assert.equal(apt.rows.length, 71); assert.equal(tk.length, 71);
  const map: Record<string, string> = { 'lê thị minh khơi': 'khoile', 'đỗ văn trung': 'trungdv22', 'đắc thị kiều trang': 'trangdtk', 'nguyễn thị linh': 'Linhnt', 'vũ thị huệ': 'huevt',
    'lê thị phương thúy': 'thuyltp', 'đào bích ngọc': 'ngocdtb', 'trần thị thanh huyền': 'huyenttt' };
  const acc = (s: string) => map[s.toLowerCase().trim()] || (['khoile', 'trungdv22', 'trangdtk', 'linhnt', 'huevt', 'thuyltp', 'ngocdtb', 'huyenttt', 'huyennk29', 'yenttt'].includes(s.toLowerCase()) ? s : null);
  const r = reconcile(apt.rows, sys, tk, { ...DEFAULT_ACC_CFG, md_xuat_thang: ['MD2421', 'MD2744', 'MD2784', 'MD2785'] }, acc);
  // cặp ghép APT ↔ hệ thống giống skill
  const pairs = fx.baseline.pairs as Record<string, number | null>; let diff = 0;
  for (const l of r.lines.filter(x => x.apt_stt)) if ((pairs[String(l.apt_stt)] ?? null) !== (l.sys_row ?? null)) diff++;
  assert.ok(diff <= 2, `lệch cặp ghép: ${diff}`);
  const blocked = r.lines.filter(l => l.status === 'blocked');
  const noOrder = r.lines.filter(l => l.apt_stt && !l.md && l.luong === 'A');
  assert.equal(noOrder.length, 10, 'xe 25/10 có 10 dòng không có đơn'); // STT 3–7, 48, 49, 67, 68, 70
  assert.ok(blocked.length >= 13, `dòng chặn ${blocked.length}`);
  // bản 23: biên ngoài khung chỉ cảnh báo (không chặn), có giá đề xuất, biên NT hiển thị theo giá nháp
  const over = r.lines.filter(l => l.gia_de_xuat && !l.gia_note);
  assert.ok(over.length > 0 && over.every(l => l.level <= 2 && l.gia_ap_dung === l.gia_nhap));
  // HĐ chính thức 2080 + 2081: 10 dòng không có đơn
  const dir = 'tests/fixtures/xml'; const byHH = new Map(r.lines.filter(l => l.hh).map(l => [l.hh!, l]));
  const res: Record<string, number> = {}; let money = 0;
  for (const f of readdirSync(dir)) { const inv = parseInvoiceXml(readFileSync(`${dir}/${f}`, 'utf8'));
    for (const il of inv.lines) { const k = judgeInvoiceLine(il, byHH.get(il.hh) || null); res[k] = (res[k] || 0) + 1; if (k === 'khong_don') money += il.tt; } }
  assert.equal(res.khong_don, 10); assert.equal(Math.round(money / 1e5) / 10, 164.3);
  assert.equal(res.khong_thuoc_xe, 47); assert.equal(res.khop, 49);
});

// ---------------- Bản 23 ----------------
test('chuẩn hóa mã khai báo / mã đơn', () => {
  assert.equal(normKb('md2415 - 2'), 'MD2415-2'); assert.equal(normKb('MD02415-02'), 'MD2415-2'); assert.equal(normKb('2415-2'), '');
  for (const x of ['2411', 'md2411', 'mD2411', 'MD2411', ' MD 2411 ']) assert.equal(normMd(x), 'MD2411');
});

// File mẫu dạng anh gửi (02/11/2026): hậu tố mã khai báo bị đảo giữa APT và file xe
const HEAD_APT = ['STT', 'Mã hàng', 'Cân', 'm3', '', '', 'Đơn hàng', 'Sale', '', '', 'MÃ KHAI BÁO', 'Mã hàng ', 'Tên hàng (mô tả chi tiết)', 'Lượng', 'ĐVT', 'Đơn giá tính thuế', 'TS NK(%)', 'TS MT', 'Đơn giá bán', 'Thuế suất VAT(%)', 'Thành tiền', 'TIỀN VAT', 'Thành tiền \nthanh toán', 'NOTE', 'KT phản hồi'];
const aptRow = (stt: number, mahang: string, don: string, sale: string, md: string, kb: string, hh: string, ten: string, sl: number, dvt: string, nk: number, gia: number, note: any = gia) =>
  [stt, mahang, '', '', '', '', don, sale, md, '', kb, hh, ten, sl, dvt, 0, nk, gia, gia, 0.08, null, null, null, note, true];
const APT = [[',', null], HEAD_APT,
  aptRow(35, 'APT102512-7HN', 'DH5763', 'Linhnt', 'MD2525', 'MD2525-1', 'HH09965', 'Loa gaming có dây', 90, 'Chiếc', 5, 114560),
  aptRow(36, '', '', '', '', 'MD2525-2', 'HH09966', 'Loa gaming bluetooth', 120, 'Chiếc', 5, 131745),
  aptRow(52, 'APT102348-22HN', 'DH5818', 'khoile', 'MD2415', 'MD2415-2', 'HH10015', 'Giá đỡ cắm hoa', 1500, 'Cái', 0, 1746),
  aptRow(53, '', '', '', '', 'MD2415-3', 'HH10016', 'Đồ trang trí cắm hoa', 760, 'Cái', 0, 5820),
  aptRow(54, '', '', '', '', 'MD2415-4', 'HH10017', 'Dụng cụ cắm hoa', 900, 'Cái', 0, 4365),
  aptRow(69, 'APT102430-1HN', 'DH5814', 'trungdv22', 'MD2411', 'MD2411-1', 'HH10039', 'Túi xách bỉm sữa', 110, 'Cái', 0, 94232, 'CHỐT')];
const HEAD_KB = ['HÌNH ẢNH', 'ẢNH', 'THƯƠNG HIỆU', 'ID ĐƠN', 'USERNAME KHÁCH', 'SALE', 'MÃ KHAI BÁO', 'Tên KHAI BÁO KH yêu cầu', 'HS Code', 'GHI CHÚ', 'SALES NTG', 'ĐƠN HÀNG NTG', 'MÃ HÀNG', 'SỐ KIỆN', 'SỐ LƯỢNG', 'DVT', 'GIÁ TRÊN TỜ KHAI', 'MÃ VẬN ĐƠN', 'TÊN NHÀ CUNG CẤP', 'THUẾ NK', 'VAT', 'Trạng thái khai báo'];
const kbRow = (id: any, kh: string, sale: string, kb: string, ten: string, sl: number, dvt: string, gia: number, nk: number) => ['', '', '', id, kh, sale, kb, ten, '', '', '', '', '', 1, sl, dvt, gia, '', '', nk, 8, 'Chờ xử lý'];
const KB = [['NẠP KHI KÊ KHAI'], HEAD_KB,
  kbRow(2411, 'duongtra', 'Đỗ Văn Trung', 'MD2411-1', 'Túi xách bỉm sữa (túi mẹ và bé)', 110, 'PCE', 97000, 0),
  kbRow('md2415', 'thuyvuvu', 'Lê Thị Minh Khơi', 'MD2415-2', 'Dụng cụ cắm hoa', 900, 'Cái', 4500, 0),
  kbRow('MD2415', 'thuyvuvu', 'Lê Thị Minh Khơi', 'MD2415-3', 'Đồ trang trí cắm hoa', 760, 'Cái', 6000, 0),
  kbRow('mD2415', 'thuyvuvu', 'Lê Thị Minh Khơi', 'MD2415-4', 'Giá đỡ cắm hoa', 1500, 'Cái', 1800, 0),
  kbRow('MD2525', 'tiendat2603', 'Nguyễn Thị Linh', 'MD2525-1', 'Loa phiên bản bluetooth', 120, 'Chiếc', 135700, 0.05),
  kbRow('MD2525', 'tiendat2603', 'Nguyễn Thị Linh', 'MD2525-2', 'Loa phiên bản có dây', 90, 'Chiếc', 118000, 0.05)];

test('bản 23: đọc nháp APT + file xe theo tiêu đề', () => {
  const a = parseApt(APT).rows, s = parseKhaiBao(KB);
  assert.equal(a.length, 6); assert.deepEqual(a.map(r => r.ma_kb), ['MD2525-1', 'MD2525-2', 'MD2415-2', 'MD2415-3', 'MD2415-4', 'MD2411-1']);
  assert.equal(a[1].md_apt, 'MD2525'); assert.equal(a[1].sale_apt, 'Linhnt'); assert.equal(a[0].gia_note, null, 'NOTE = giá nháp → không coi là giá sale ghi');
  assert.deepEqual(s.map(r => r.md), ['MD2411', 'MD2415', 'MD2415', 'MD2415', 'MD2525', 'MD2525']);
  assert.equal(s[0].sale, 'Đỗ Văn Trung', 'cột SALE theo tiêu đề'); assert.equal(s[0].ma_kh, 'duongtra', 'USERNAME KHÁCH');
});

test('bản 23: ghép mã khai báo → mã đơn + SL, biên đúng 3%', () => {
  const a = parseApt(APT).rows, s = parseKhaiBao(KB); const m = matchAptSys(a, s);
  const kinds = [...m.values()].map(x => x[1]); assert.equal(kinds.filter(k => k === 'ma').length, 2); assert.equal(kinds.filter(k => k === 'don').length, 4);
  const r = reconcile(a, s, [], DEFAULT_ACC_CFG, x => x);
  for (const l of r.lines) { assert.ok(l.bien_nt! > 0.029 && l.bien_nt! < 0.031, `${l.ma_kb_apt} biên ${l.bien_nt}`); assert.notEqual(l.status, 'blocked'); }
  assert.equal(r.lines.find(l => l.ma_kb_apt === 'MD2415-2')!.ma_dong, 'MD2415-4');
  assert.equal(r.lines.find(l => l.ma_kb_apt === 'MD2525-1')!.gia_khach, 118000);
});

test('bản 23: biên ngoài khung → cảnh báo + giá đề xuất = giá khách ÷ 1,03 (số liền)', () => {
  const rows = APT.map(r => r.slice()); (rows[4] as any[])[18] = 1600; (rows[4] as any[])[23] = 1600; // Giá đỡ: APT 1600, khách 1800 → 12,5%
  const r = reconcile(parseApt(rows).rows, parseKhaiBao(KB), []);
  const l = r.lines.find(x => x.ma_kb_apt === 'MD2415-2')!;
  assert.equal(l.gia_de_xuat, 1748); assert.equal(l.status, 'ok'); assert.equal(l.level, 2);
  assert.equal(aptPriceList(r.lines), '52\t1748');
});

test('bản 23: mã đúng mà lệch SL → ghép + cảnh báo sai số', () => {
  const rows = APT.map(r => r.slice()); (rows[7] as any[])[13] = 100; // túi bỉm: APT 100, xe 110
  const r = reconcile(parseApt(rows).rows, parseKhaiBao(KB), []);
  const l = r.lines.find(x => x.ma_kb_apt === 'MD2411-1')!;
  assert.equal(l.match_kind, 'ma_lech_sl'); assert.ok(l.issues.some(x => x.includes('Lệch số lượng')));
});

const FX23 = 'tests/fixtures/xh261026001.json';
test('bản 23: 3 file mẫu XH261026001 (ngoài repo)', { skip: !existsSync(FX23) }, () => {
  const fx = JSON.parse(readFileSync(FX23, 'utf8')); const r = reconcile(parseApt(fx.apt).rows, parseKhaiBao(fx.kb), []);
  assert.equal(r.stats.khop_ma, 3); assert.equal(r.stats.ghep_don, 4); assert.equal(r.stats.blocked, 0);
});
