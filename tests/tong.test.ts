// Bản 53 — file tổng (nháp APT + file xe gộp sẵn)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DEFAULT_ACC_CFG, parseTong, reconcile, applyTongChecks, isTongHeader } from '../src/lib/doisoat';
import { TPL_TONG } from '../src/lib/mau';

const H = TPL_TONG[0];
const row = (o: Record<string, any>) => H.map(h => o[h] ?? '');
const base = { 'Sale': 'khoile', 'Đơn hàng': 'DH6349', 'Mã hàng APT (kiện)': 'APT11858-75HN', 'ĐVT': 'Cái', 'Thuế VAT (%)': '8%', 'TS NK(%)': 0, 'Thuế NK Khaibao': 0 };
const run = (rows: any[][]) => { const t = parseTong([H, ...rows]); const r = reconcile(t.apt, t.sys, [], DEFAULT_ACC_CFG, s => s || null, t.pairs); applyTongChecks(r, t.extra); return { t, r }; };

test('nhận tiêu đề file tổng, file mẫu đọc được', () => {
  assert.ok(isTongHeader(H));
  const { r } = run(TPL_TONG.slice(1));
  assert.equal(r.lines.length, 3); assert.ok(r.lines.every(l => l.md && l.ma_kh && l.gia_khach && l.hh));
});

test('biên, SL hệ thống, hợp quy, xuất thẳng, thành tiền, trùng mã', () => {
  const { t, r } = run([
    row({ ...base, STT: 1, 'Mã đơn (MD)': 'MD3039', 'Mã khai báo': 'MD3039-1', 'Username khách': 'lethanh', 'Mã hàng HH': 'HH10780', 'Tên hàng (mô tả chi tiết)': 'Hộp đựng quà tặng nhựa PP', 'Lượng': 1500, 'Đơn giá bán (APT)': 1928, 'Giá xuất khách': 2000, 'Mã HS (TKN)': '39231090', 'Số lượng hệ thống': 1500, 'Thành tiền': 2892000 }),
    // username ô trống, cùng đơn → lấy theo dòng trên; SL hệ thống lệch
    row({ ...base, STT: 2, 'Mã đơn (MD)': 'MD3039', 'Mã khai báo': 'MD3039-2', 'Tên hàng (mô tả chi tiết)': 'Hộp 4 ngăn', 'Lượng': 2400, 'Đơn giá bán (APT)': 1928, 'Giá xuất khách': 2000, 'Mã HS (TKN)': '39231090', 'Số lượng hệ thống': 2000, 'Thành tiền': 4627200 }),
    // biên 4,69% → cảnh báo + giá đề xuất
    row({ ...base, STT: 3, Sale: 'trungdv22', 'Mã đơn (MD)': 'MD2996', 'Mã khai báo': 'MD2996-1', 'Username khách': 'ntthuy0405', 'Tên hàng (mô tả chi tiết)': 'Túi bao bì PP', 'Lượng': 3000, 'Đơn giá bán (APT)': 7670, 'Giá xuất khách': 8030, 'Mã HS (TKN)': '39232990', 'Số lượng hệ thống': 3000, 'Thành tiền': 1 }),
    // dệt may → chờ hợp quy
    row({ ...base, STT: 4, 'Mã đơn (MD)': 'MD2881', 'Mã khai báo': 'MD2881-1', 'Username khách': 'x1', 'Tên hàng (mô tả chi tiết)': 'Áo thun cotton', 'Lượng': 10, 'Đơn giá bán (APT)': 100000, 'Giá xuất khách': 103000, 'Mã HS (TKN)': '61091000', 'Số lượng hệ thống': 10 }),
    // NOTE xuất thẳng
    row({ ...base, STT: 5, 'Mã đơn (MD)': 'MD2800', 'Mã khai báo': 'MD2800-1', 'Username khách': 'x2', 'Tên hàng (mô tả chi tiết)': 'Đôn kê', 'Lượng': 200, 'Đơn giá bán (APT)': 144616, 'Giá xuất khách': 150000, 'Mã HS (TKN)': '39249090', 'Số lượng hệ thống': 200, NOTE: 'XUẤT THẲNG' }),
    // trùng mã khai báo, không có username (đơn mới)
    row({ ...base, STT: 6, 'Mã đơn (MD)': 'MD2800', 'Mã khai báo': 'MD2800-1', 'Tên hàng (mô tả chi tiết)': 'Đôn kê 2', 'Lượng': 1, 'Đơn giá bán (APT)': 100, 'Giá xuất khách': 103, 'Số lượng hệ thống': 1 }),
    // hàng có trên hệ thống, không lên xe
    row({ ...base, 'Mã đơn (MD)': 'MD2990', 'Mã khai báo': 'MD2990-1', 'Username khách': 'khacdunghk', 'Tên hàng (mô tả chi tiết)': 'Nắp bảo vệ bình dầu', 'Giá xuất khách': 31415, 'Số lượng hệ thống': 200 }),
  ]);
  assert.equal(t.apt.length, 6); assert.equal(t.sys.length, 7);
  const L = (n: number) => r.lines.find(l => l.apt_stt === n)!;
  assert.equal(L(1).status, 'ok'); assert.equal(L(1).match_kind, 'ma'); assert.equal(L(1).ma_kh, 'lethanh'); assert.equal(L(1).hh, 'HH10780'); assert.equal(L(1).vat, 0.08);
  assert.equal(L(2).ma_kh, 'lethanh'); assert.equal(L(2).match_kind, 'ma_lech_sl'); assert.ok(L(2).issues.some(x => x.includes('Lệch số lượng')));
  assert.equal(L(3).gia_de_xuat, Math.round(8030 / 1.03)); assert.ok(L(3).issues.some(x => x.startsWith('Thành tiền')));
  assert.equal(L(4).luong, 'B');
  assert.equal(L(5).luong, 'C');
  assert.ok(L(6).issues.some(x => x.includes('trùng'))); assert.equal(L(6).ma_kh, 'x2', 'cùng đơn MD2800 → username như dòng trên');
  const e = r.lines.find(l => !l.apt_stt)!; assert.equal(e.luong, 'E'); assert.equal(e.md, 'MD2990');
  assert.ok(t.warnings.some(w => w.includes('không lên xe')));
});

test('đơn mới không mang username / sale của đơn trên', () => {
  const { r } = run([
    row({ ...base, STT: 1, 'Mã khai báo': 'MD1-1', 'Username khách': 'u1', 'Tên hàng (mô tả chi tiết)': 'A', 'Lượng': 1, 'Đơn giá bán (APT)': 100, 'Giá xuất khách': 103, 'Số lượng hệ thống': 1 }),
    row({ ...base, STT: 2, Sale: '', 'Mã khai báo': 'MD2-1', 'Tên hàng (mô tả chi tiết)': 'B', 'Lượng': 1, 'Đơn giá bán (APT)': 100, 'Giá xuất khách': 103, 'Số lượng hệ thống': 1 }),
  ]);
  const b = r.lines.find(l => l.apt_stt === 2)!; assert.equal(b.ma_kh, null); assert.equal(b.status, 'blocked');
});

test('thiếu cột bắt buộc báo rõ', () => {
  assert.throws(() => parseTong([H.filter(h => h !== 'Username khách')]), /Username khách/);
});
