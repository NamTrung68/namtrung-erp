// Bản 41: gộp ảnh → PDF, tên file + thư mục Drive hồ sơ scan
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { jpegsToPdf, safeName, scanFolder, scanName } from '../src/lib/hoso';

test('safeName bỏ dấu + ký tự cấm', () => {
  assert.equal(safeName('CÔNG TY TNHH Đại Phát / HN: số 1*'), 'CONG TY TNHH Dai Phat - HN- so 1');
  assert.equal(safeName('   '), 'Khac');
  assert.ok(!safeName('a/../b').includes('..'));
});

test('thư mục: HĐ theo năm, HĐNT / HĐMB riêng theo khách', () => {
  assert.equal(scanFolder({ mst: '0101248141', ten: 'Cty Đại Phát', kinds: ['hd', 'ddh'], ngay: '2026-11-03' }), 'Ho so khach hang/0101248141 - Cty Dai Phat/HD 2026');
  assert.equal(scanFolder({ mst: '0101248141', ten: 'Cty Đại Phát', kinds: ['hdnt'] }), 'Ho so khach hang/0101248141 - Cty Dai Phat/Hop dong NT-MB');
  assert.equal(scanFolder({ mst: '0101248141', ten: 'X', kinds: ['hdmb'], ngay: '2026-01-01' }), 'Ho so khach hang/0101248141 - X/Hop dong NT-MB');
  assert.match(scanFolder({ mst: '', ten: 'X', kinds: ['hd', 'hdmb'], ngay: '2025-12-31' }), /Chua co MST - X\/HD 2025$/);
});

test('tên file theo số HĐ + loại giấy', () => {
  const at = new Date(2026, 10, 11, 9, 5);
  assert.equal(scanName({ so_hd: '00000401', kinds: ['bbgn', 'hd', 'ddh'], ext: 'pdf', at }), 'HD401_HD-DDH-BBGN_20261111-0905.pdf');
  assert.equal(scanName({ ma_hdnt: '01/2026/HĐNT', kinds: ['hdnt'], ext: '.pdf', at }), 'HDNT_01-2026-HDNT_20261111-0905.pdf');
});

test('jpegsToPdf: cấu trúc PDF hợp lệ, xref đúng vị trí', () => {
  const fake = (n: number) => ({ data: new Uint8Array([0xff, 0xd8, ...Array(n).fill(7), 0xff, 0xd9]), w: 1200, h: 1600 });
  const pdf = jpegsToPdf([fake(50), { ...fake(30), w: 1600, h: 900 }]);
  const txt = Buffer.from(pdf).toString('latin1');
  assert.ok(txt.startsWith('%PDF-1.4'));
  assert.ok(txt.trimEnd().endsWith('%%EOF'));
  assert.match(txt, /\/Count 2/);
  assert.match(txt, /\/MediaBox \[0 0 842 595\]/, 'ảnh ngang → trang ngang');
  const xref = Number(/startxref\n(\d+)/.exec(txt)![1]);
  assert.equal(txt.slice(xref, xref + 4), 'xref');
  const offs = txt.slice(xref).split('\n').slice(3, 3 + 8).map(l => Number(l.slice(0, 10)));
  offs.forEach((o, i) => assert.equal(txt.slice(o, o + `${i + 1} 0 obj`.length), `${i + 1} 0 obj`, `obj ${i + 1}`));
  assert.throws(() => jpegsToPdf([]));
});
