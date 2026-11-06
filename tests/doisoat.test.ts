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

test('bản 27: biên > 7% → CHẶN (cần xử lý) + giá đề xuất = giá khách ÷ 1,03 (số liền)', () => {
  const rows = APT.map(r => r.slice()); (rows[4] as any[])[18] = 1600; (rows[4] as any[])[23] = 1600; // Giá đỡ: APT 1600, khách 1800 → 12,5%
  const r = reconcile(parseApt(rows).rows, parseKhaiBao(KB), []);
  const l = r.lines.find(x => x.ma_kb_apt === 'MD2415-2')!;
  assert.equal(l.gia_de_xuat, 1748); assert.equal(l.status, 'blocked'); assert.equal(l.level, 1);
  assert.equal(aptPriceList(r.lines), '52\t1748');
});

test('bản 27: biên 4–7% chỉ cảnh báo (tự chốt); biên âm / dưới 2,5% → chặn', () => {
  const at = (gia: number) => { const rows = APT.map(r => r.slice()); (rows[4] as any[])[18] = gia; (rows[4] as any[])[23] = gia;
    return reconcile(parseApt(rows).rows, parseKhaiBao(KB), []).lines.find(x => x.ma_kb_apt === 'MD2415-2')!; };
  const mid = at(1700); // 1800/1700 − 1 = 5,88%
  assert.equal(mid.status, 'ok'); assert.equal(mid.level, 2); assert.ok(mid.gia_de_xuat);
  const neg = at(1900); // âm
  assert.equal(neg.status, 'blocked'); assert.ok(neg.bien_nt! < 0);
  const low = at(1770); // 1,69%
  assert.equal(low.status, 'blocked');
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

// ---------------- Bản 25: nạp HĐ chính thức — đối chiếu tên + SL về nháp ----------------
import { matchHd, bestTruck } from '../src/lib/hdapt';
test('bản 25: HĐ ký → dòng nháp (mã khai báo) → đơn/khách/sale; lệch giá → báo; không thấy → chờ ghép', () => {
  const lines = [
    { id: 'L1', truck_id: 'T', apt_stt: 52, ma_dong: 'MD2415-4', ten_apt: 'Giá đỡ cắm hoa bằng nhựa, 2 đầu vuông', sl_apt: 1500, gia_nhap: 1746, vat: 0.08, md: 'MD2415', gia_khach: 1800 },
    { id: 'L2', truck_id: 'T', apt_stt: 54, ma_dong: 'MD2415-2', ten_apt: 'Dụng cụ cắm hoa, cao 35cm', sl_apt: 900, gia_nhap: 4365, vat: 0.08, md: 'MD2415', gia_khach: 4500 },
    { id: 'L3', truck_id: 'T', apt_stt: 60, ma_dong: 'MD2420-1', ten_apt: 'Bình giữ nhiệt inox 500ml', sl_apt: 300, gia_nhap: 52000, gia_de_xuat: 51942, vat: 0.08, md: 'MD2420', gia_khach: 53500 },
    { id: 'L4', truck_id: 'T', apt_stt: 61, ma_dong: 'MD2421-1', ten_apt: 'Khăn tắm cotton 70x140cm loại dày', sl_apt: 200, gia_nhap: 38000, vat: 0.08, md: 'MD2421', gia_khach: 39200 }];
  const rows = [
    { ma_hang: 'HH00044-2080-2026', ten: 'Giá đỡ cắm hoa bằng nhựa,  2 đầu vuông.', sl_nhap: 1500, dg_nhap: 1746, vat: 0.08 },
    { ma_hang: 'HH00046-2080-2026', ten: 'Dụng cụ cắm hoa, cao 35cm', sl_nhap: 900, dg_nhap: 4400, vat: 0.08 },
    { ma_hang: 'HH00060-2080-2026', ten: 'Bình giữ nhiệt inox 500ml', sl_nhap: 300, dg_nhap: 51900, vat: 0.08 },
    { ma_hang: 'HH00061-2080-2026', ten: 'Khăn tắm cotton 70x140cm loai day', sl_nhap: 200, dg_nhap: 38000, vat: 0.08 },
    { ma_hang: 'HH00099-2080-2026', ten: 'Ốp lưng điện thoại', sl_nhap: 450, dg_nhap: 12000, vat: 0.08 }];
  const m = matchHd(rows, lines);
  assert.equal(m[0].line.ma_dong, 'MD2415-4'); assert.equal(m[0].kind, 'khop'); assert.equal(m[0].lech, null);
  assert.ok(m[1].lech?.includes('Đơn giá HĐ 4400'));
  assert.equal(m[2].lech, null, 'APT làm tròn giá đề xuất 51942 → 51900: chấp nhận');
  assert.equal(m[3].kind, 'gan'); assert.equal(m[3].line.id, 'L4');
  assert.equal(m[4].line, null);
  assert.equal(matchHd(rows, lines, new Set(['L1']))[0].line, null, 'dòng nháp đã thuộc mã hàng khác thì không ghép lại');
  assert.equal(bestTruck(rows, new Map([['T', lines], ['X', []]])), 'T');
});

// Bản 32: file xe đảo cột ID ĐƠN ↔ USERNAME ở vài dòng cuối (dữ liệu giả, đúng hình dạng file thật)
test('file xe lệch cột ID ĐƠN ↔ USERNAME — lấy đơn theo mã khai báo, đảo lại username', () => {
  const H = ['HÌNH ẢNH', 'THƯƠNG HIỆU', 'ID ĐƠN', 'USERNAME KHÁCH', 'SALE', 'MÃ KHAI BÁO', 'Tên KHAI BÁO KH yêu cầu', 'HS Code', 'SỐ KIỆN', 'SỐ LƯỢNG', 'DVT', 'GIÁ TRÊN TỜ KHAI'];
  const row = (don: any, kh: any, kb: string, ten: string) => ['', '', don, kh, 'Sale A', kb, ten, '', '', 10, 'Chiếc', 1000];
  const sys = parseKhaiBao([['NẠP KHI KÊ KHAI'], H,
    row(2406, 'khachdung', 'MD2406-1', 'Hàng 1'),
    row(2604, '0866445988', 'MD2604-1', 'Hàng 2'),          // username là số điện thoại — giữ nguyên
    row('khachA', 2689, 'MD2689-1', 'Hàng 3'),               // đảo cột
    row('khach2603', 2329, 'MD2329-2', 'Hàng 4'),            // đảo cột, username có số → trước đây đọc thành MD2603
    row('khach123', 'MD2707', 'MD2707-1', 'Hàng 5'),         // đảo cột, username có số → trước đây đọc thành MD123
    row(2445, 2445, 'MD2445-1', 'Hàng 6'),                   // username = số đơn → coi là thiếu
    row('', '', 'MD2445-3', 'Hàng 7'),                       // dòng tiếp của đơn trên, không mang username sai xuống
    row(2800, '', 'MD2800-1', 'Hàng 8'),                     // sang đơn mới thiếu username → không lấy username đơn trên
  ]);
  const by = (kb: string) => sys.find(s => s.ma_dong === kb)!;
  assert.deepEqual([by('MD2406-1').md, by('MD2406-1').ma_kh, by('MD2406-1').flags], ['MD2406', 'khachdung', []]);
  assert.deepEqual([by('MD2604-1').md, by('MD2604-1').ma_kh], ['MD2604', '0866445988']);
  assert.deepEqual([by('MD2689-1').md, by('MD2689-1').ma_kh, by('MD2689-1').flags], ['MD2689', 'khachA', ['dao_cot']]);
  assert.deepEqual([by('MD2329-2').md, by('MD2329-2').ma_kh], ['MD2329', 'khach2603']);
  assert.deepEqual([by('MD2707-1').md, by('MD2707-1').ma_kh], ['MD2707', 'khach123']);
  assert.deepEqual([by('MD2445-1').md, by('MD2445-1').ma_kh, by('MD2445-1').flags], ['MD2445', '', ['user_la_don']]);
  assert.deepEqual([by('MD2445-3').md, by('MD2445-3').ma_kh, by('MD2445-3').flags], ['MD2445', '', ['thieu_user']]);
  assert.deepEqual([by('MD2800-1').md, by('MD2800-1').ma_kh, by('MD2800-1').flags], ['MD2800', '', ['thieu_user']]);
  // cột MÃ KHAI BÁO đứng trước USERNAME không bị nhận nhầm là cột mã khách
  const H2 = ['ID ĐƠN', 'MÃ KHAI BÁO', 'USERNAME KHÁCH', 'SALE', 'Tên KHAI BÁO', 'SỐ LƯỢNG', 'DVT', 'GIÁ TRÊN TỜ KHAI'];
  const s2 = parseKhaiBao([H2, [2406, 'MD2406-1', 'khachdung', 'Sale A', 'Hàng 1', 10, 'Chiếc', 1000]]);
  assert.equal(s2[0].ma_kh, 'khachdung');
  // đối soát: thiếu username → cảnh báo (không chặn); lệch cột → ghi chú + cảnh báo đầu trang
  const apt = parseApt([['STT', 'Mã hàng', '', '', '', '', 'Đơn hàng', 'Sale', '', '', 'MÃ KHAI BÁO', 'Mã hàng ', 'Tên hàng (mô tả chi tiết)', 'Lượng', 'ĐVT', 'Đơn giá tính thuế', 'TS NK(%)', 'TS MT', 'Đơn giá bán', 'Thuế suất VAT(%)'],
    [1, '', '', '', '', '', 'DH1', 'a', '', '', 'MD2689-1', 'HH1', 'Hàng 3', 10, 'Chiếc', '', 0, '', 971, 0.08],
    [2, '', '', '', '', '', 'DH2', 'a', '', '', 'MD2800-1', 'HH2', 'Hàng 8', 10, 'Chiếc', '', 0, '', 971, 0.08]]);
  const r = reconcile(apt.rows, sys, []);
  const l1 = r.lines.find(l => l.ma_dong === 'MD2689-1')!, l2 = r.lines.find(l => l.ma_dong === 'MD2800-1')!;
  assert.equal(l1.ma_kh, 'khachA'); assert.ok(l1.notes.some(n => n.includes('đảo cột')));
  assert.equal(l2.status, 'ok'); assert.ok(l2.issues.some(x => x.startsWith('Thiếu username')));
  assert.equal(r.stats.thieu_user, 1);
  assert.ok(r.warnings.some(w => w.startsWith('File xe lệch cột ở 3 dòng')));
});
