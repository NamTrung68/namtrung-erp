import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseHdName, parseHdText } from '../src/lib/hdfile';

test('tên file nháp chuẩn', () => {
  assert.deepEqual(parseHdName('NHAP_0700871570_64746218_20261102_5.pdf'), { kind: 'nhap', mst: '0700871570', tong: 64746218, ngay: '2026-11-02', from: 'ten' });
});
test('tên file đã ký chuẩn', () => {
  assert.deepEqual(parseHdName('KY_1C26TYY-00000928_001190005010_6372000.pdf'), { kind: 'ky', ky_hieu: '1C26TYY', so_hd: '928', mst: '001190005010', tong: 6372000, from: 'ten' });
  assert.equal(parseHdName('KY_1C26TYY-00000934_036092010112_73782144.pdf')?.so_hd, '934');
});
test('tên file cũ (MST_tên_tiền_stt)', () => {
  const r = parseHdName('040091011932_HO_KINH_DOANH_TAI_UC_23.328.000_10.pdf');
  assert.equal(r?.kind, 'nhap'); assert.equal(r?.mst, '040091011932'); assert.equal(r?.tong, 23328000);
});
test('tên lạ → không đọc được', () => { assert.equal(parseHdName('scan 01.pdf'), null); });

const NHAP = `HÓA ĐƠN GIÁ TRỊ GIA TĂNG Ngày 31 tháng 10 năm 2026 Mã CQT: Ký hiệu: 1C26TYY Số: <Chưa cấp số>
CÔNG TY TNHH DỊCH VỤ VÀ THƯƠNG MẠI QUỐC TẾ NAM TRUNG Mã số thuế: 0108195040 Địa chỉ: Tầng 6
Tên đơn vị: HỘ KINH DOANH TÀI ĐỨC Mã số thuế: 040091011932 Địa chỉ: Số 4
Thuế suất 8%: 21.600.000 1.728.000 23.328.000 Thuế suất 10%: Thuế suất KHÁC: Tổng cộng: 21.600.000 1.728.000 23.328.000`;
test('đọc chữ trong PDF nháp MISA', () => {
  assert.deepEqual(parseHdText(NHAP), { kind: 'nhap', mst: '040091011932', tong: 23328000, so_hd: undefined, ky_hieu: '1C26TYY', ngay: '2026-10-31', from: 'noi_dung' });
});
test('đọc chữ trong PDF đã ký', () => {
  const r = parseHdText(NHAP.replace('<Chưa cấp số>', '00000928'));
  assert.equal(r?.kind, 'ky'); assert.equal(r?.so_hd, '928');
});
