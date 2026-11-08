// Bản 35: XML HĐ chính thức → mã hàng {mã khai báo}-{số HĐ}; kiểm tra MST; điền bộ chứng từ từ mẫu Word
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { assignMaHang, maHangXml, parseHdXml, soHdKey, xmlVat } from '../src/lib/hdxml';
import { localWarnings, mstChecksum, nameDiff } from '../src/lib/mst';
import { docRows, docVars, docsOf, fillXml, ngayHdnt, repeatRow, soHdmb, type DocInv } from '../src/lib/hdDocs';
import { unzip } from '../src/lib/xlsx';
import { makeZip } from '../src/lib/zip';

const XML = `<?xml version="1.0" encoding="UTF-8"?><HDon><DLHDon Id="data"><TTChung><PBan>2.1.0</PBan><THDon>Hóa đơn giá trị gia tăng</THDon><KHMSHDon>1</KHMSHDon><KHHDon>C26TAP</KHHDon>
<SHDon>00002080</SHDon><NLap>2026-11-05</NLap><DVTTe>VND</DVTTe></TTChung><NDHDon><NBan><Ten>CÔNG TY TNHH APT &amp; ALPHATIC</Ten><MST>0109999999</MST></NBan>
<NMua><Ten>CÔNG TY TNHH DỊCH VỤ VÀ THƯƠNG MẠI QUỐC TẾ NAM TRUNG</Ten><MST>0108195040</MST></NMua><DSHHDVu>
<HHDVu><TChat>1</TChat><STT>1</STT><MHHDVu>HH00001</MHHDVu><THHDVu>Móc khóa hình quả bóng,  mới 100%</THHDVu><DVTinh>Cái</DVTinh><SLuong>400</SLuong><DGia>1941.75</DGia><ThTien>776700</ThTien><TSuat>8%</TSuat></HHDVu>
<HHDVu><TChat>1</TChat><STT>2</STT><THHDVu>Bình nước inox</THHDVu><DVTinh>Chiếc</DVTinh><SLuong>10</SLuong><DGia>50000</DGia><ThTien>500000</ThTien><TSuat>10%</TSuat></HHDVu>
<HHDVu><TChat>4</TChat><STT>3</STT><THHDVu>Ghi chú: hàng giao theo đơn</THHDVu></HHDVu>
<HHDVu><TChat>1</TChat><STT>4</STT><THHDVu>Bình nước inox</THHDVu><DVTinh>Chiếc</DVTinh><SLuong>5</SLuong><DGia>50000</DGia><ThTien>250000</ThTien><TSuat>KCT</TSuat></HHDVu>
</DSHHDVu><TToan><TgTCThue>1526700</TgTCThue><TgTThue>112136</TgTThue><TgTTTBSo>1638836</TgTTTBSo></TToan></NDHDon></DLHDon><MCCQT>00ABC</MCCQT></HDon>`;

test('đọc XML HĐ điện tử', () => {
  const h = parseHdXml(XML);
  assert.equal(h.so_hd, '2080'); assert.equal(h.ky_hieu, '1C26TAP'); assert.equal(h.ngay, '2026-11-05'); assert.equal(h.ncc, 'CÔNG TY TNHH APT & ALPHATIC');
  assert.equal(h.lines.length, 3); assert.equal(h.bo_qua.length, 1);
  assert.deepEqual(h.lines.map(l => [l.stt, l.sl, l.dg, l.vat]), [[1, 400, 1941.75, 0.08], [2, 10, 50000, 0.1], [4, 5, 50000, null]]);
  assert.equal(h.lines[0].ten, 'Móc khóa hình quả bóng, mới 100%');
  assert.equal(h.tong, 1638836);
  assert.throws(() => parseHdXml('<abc/>'), /Không phải file XML/);
  assert.equal(xmlVat('5%'), 0.05); assert.equal(xmlVat('KKKNT'), null); assert.equal(xmlVat('0%'), 0);
});

test('mã hàng ERP = {mã khai báo}-{số HĐ}', () => {
  assert.equal(maHangXml('m3433-2', '02080', 1), 'M3433-2-2080');
  assert.equal(maHangXml(null, '2080', 7), 'CHUAKB-2080-7');
  assert.equal(soHdKey('00002080'), '2080'); assert.equal(soHdKey('HD 2080'), '2080');
  const rows = [{ stt_hd: 1, so_hd_vao: '2080' }, { stt_hd: 2, so_hd_vao: '2080' }, { stt_hd: 4, so_hd_vao: '2080' }];
  const out = assignMaHang(rows, i => (i === 2 ? null : 'M3433-2'));
  assert.deepEqual(out.map(r => [r.ma_hang, r.part]), [['M3433-2-2080', 1], ['M3433-2-2080', 2], ['CHUAKB-2080-4', 1]]);
});

test('kiểm tra MST', () => {
  assert.equal(mstChecksum('0108195040'), true);      // Nam Trung
  assert.equal(mstChecksum('0101248141'), true);      // FPT
  assert.equal(mstChecksum('0101248142'), false);
  assert.equal(mstChecksum('0101248141-001'), true);
  assert.equal(mstChecksum('038098020305'), null);    // CCCD 12 số: không có số kiểm tra
  assert.deepEqual(localWarnings('0108195040'), []);
  assert.match(localWarnings('0108195041')[0], /sai số kiểm tra/);
  assert.match(localWarnings('12345')[0], /10 số/);
  assert.equal(nameDiff('Công ty TNHH ABC', 'CÔNG TY TNHH  ABC.'), false);
  assert.equal(nameDiff('Công ty ABC', 'Công ty XYZ'), true);
});

const INV: DocInv = { id: 'x', code: 'XHD00012', so_hd: '00002759', ngay_hd: '2026-11-07', buyer_name: 'HỘ KINH DOANH JIN VPP & QUÀ TẶNG', tax_code: '038098020305',
  address: 'Số 352 Bà Triệu, Hậu Lộc, Thanh Hóa', payment: 'TM/CK',
  buyer: { id: 'b', dai_dien: 'Ông Trương Văn Dương', chuc_vu: 'Chủ hộ kinh doanh', ma_hdnt: null, ngay_hdnt: null },
  lines: [{ ten: 'Móc khóa <quả bóng>', dvt: 'Cái', sl: 400, don_gia: 2000, vat: 0.08 }, { ten: 'Bình nước', dvt: 'Chiếc', sl: 10, don_gia: 55000, vat: 0.1 }] };

test('biến bộ chứng từ', () => {
  const v = docVars(INV, 'ddh');
  assert.equal(v.so_don, '2759'); assert.equal(v.ngay, '07/11/2026'); assert.equal(v.ngay_chu, '07 tháng 11 năm 2026');
  assert.equal(v.cong_tien, '1.350.000'); assert.equal(v.tong, (1350000 + 64000 + 55000).toLocaleString('vi-VN'));
  assert.match(v.bang_chu, /^một triệu bốn trăm sáu mươi chín nghìn đồng chẵn$/);
  assert.equal(soHdmb(INV), '07/11/2026/HĐMBHH/NT/2759');
  assert.equal(docVars(INV, 'bbgn').can_cu, '07/11/2026/HĐMBHH/NT/2759 ký ngày 07 tháng 11 năm 2026');
  assert.deepEqual(docsOf(INV), ['ddh', 'bbgn', 'hdmb']);
  const nt: DocInv = { ...INV, buyer: { ...INV.buyer, ma_hdnt: '28/08/2026/HĐNTHH/NT/JINVPP' } };
  assert.deepEqual(docsOf(nt), ['ddh', 'bbgn']);
  assert.equal(docVars(nt, 'bbgn').can_cu, '28/08/2026/HĐNTHH/NT/JINVPP ký ngày 28 tháng 08 năm 2026');
  assert.equal(docVars(nt, 'hdnt').ngay_chu, '28 tháng 08 năm 2026'); assert.equal(docVars(nt, 'hdnt').so_hd, '28/08/2026/HĐNTHH/NT/JINVPP');
  assert.equal(ngayHdnt('1/9/2026/HĐNT', null), '2026-09-01'); assert.equal(ngayHdnt('ABC', '2026-01-02'), '2026-01-02');
  assert.equal(docVars({ ...INV, buyer: null }, 'bbgn').dai_dien, '…………………………');
  const t = docRows(INV).tax; assert.deepEqual(t, [{ ts: '8%', tien_thue: '64.000' }, { ts: '10%', tien_thue: '55.000' }]);
  assert.equal(repeatRow('<w:tbl><w:tr><w:tc>{{a}}</w:tc></w:tr></w:tbl>', '{{a}}', [{ a: '1' }, { a: '<2>' }]), '<w:tbl><w:tr><w:tc>1</w:tc></w:tr><w:tr><w:tc>&lt;2&gt;</w:tc></w:tr></w:tbl>');
});

test('điền mẫu Word thật (public/mau-hd)', async () => {
  const OUT = process.env.DOC_OUT; if (OUT) mkdirSync(OUT, { recursive: true });
  const nt: DocInv = { ...INV, buyer: { ...INV.buyer, ma_hdnt: '28/08/2026/HĐNTHH/NT/JINVPP' } };
  for (const k of ['ddh', 'bbgn', 'hdmb', 'hdnt'] as const) {
    const buf = readFileSync(`public/mau-hd/${k}.docx`); const files = await unzip(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
    const xml = new TextDecoder().decode(files.get('word/document.xml')!);
    const out = fillXml(xml, k === 'hdnt' ? nt : INV, k); const text = out.replace(/<[^>]+>/g, '');
    assert.ok(!/\{\{\w+\}\}/.test(out), `${k}: còn chỗ trống chưa điền`);
    assert.ok(text.includes('HỘ KINH DOANH JIN VPP &amp; QUÀ TẶNG'), `${k}: tên khách`);
    assert.ok(!text.includes('JIN VPP PHỤ KIỆN'), `${k}: còn tên khách mẫu`);
    if (k === 'ddh') { assert.ok(text.includes('Bình nước') && text.includes('THUẾ GTGT 10%') && text.includes('THUẾ GTGT 8%') && text.includes('2759')); assert.ok(text.includes('Móc khóa &lt;quả bóng&gt;')); }
    if (k === 'bbgn') assert.ok(text.includes('Ông Trương Văn Dương') && text.includes('07 tháng 11 năm 2026') && text.includes('HĐMBHH/NT/2759'));
    if (k === 'hdnt') assert.ok(text.includes('28 tháng 08 năm 2026'));
    if (OUT) { const z = await makeZip(Array.from(files.entries()).map(([name, d]) => ({ name, data: new Blob([name === 'word/document.xml' ? new TextEncoder().encode(out) : d]) })));
      writeFileSync(`${OUT}/${k}.docx`, Buffer.from(await z.arrayBuffer())); }
  }
});
