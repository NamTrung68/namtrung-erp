// Bản 54: bên mua trên ĐĐH / BBGN / HĐNT lấy theo pháp nhân cùng MST; bỏ nhãn "Đại diện:" / "Địa chỉ:" dán nhầm; mẫu HĐNT mới
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { benMua, dcSach, docVars, fillXml, tenSach, type DocInv } from '../src/lib/hdDocs';
import { unzip } from '../src/lib/xlsx';

const base: DocInv = { id: '1', code: 'XHD1', so_hd: '1192', ngay_hd: '2026-11-11', buyer_name: 'HỘ KINH DOANH SHOP HOÀI VŨ Đại diện: Ông Châu Nguyễn Hoài Vũ',
  tax_code: '077093001530', address: 'Địa chỉ: Số 49, Đường số 7', payment: 'TM/CK', lines: [{ ten: 'Bình', dvt: 'Chiếc', sl: 2, don_gia: 1000, vat: 0.08 }] };

test('bỏ nhãn dán nhầm trong tên / địa chỉ', () => {
  assert.equal(tenSach('HỘ KINH DOANH SHOP HOÀI VŨ Đại diện: Ông Châu Nguyễn Hoài Vũ'), 'HỘ KINH DOANH SHOP HOÀI VŨ');
  assert.equal(tenSach('Tên công ty: CÔNG TY TNHH A'), 'CÔNG TY TNHH A');
  assert.equal(tenSach('CÔNG TY TNHH ĐẠI DIỆN THƯƠNG MẠI'), 'CÔNG TY TNHH ĐẠI DIỆN THƯƠNG MẠI');
  assert.equal(dcSach('ĐIA CHI : 49 ĐƯỜNG SỐ 7'), '49 ĐƯỜNG SỐ 7');
  assert.equal(dcSach('Địa chỉ: Số 49'), 'Số 49');
});

test('bên mua: pháp nhân cùng MST thắng, khác MST thì dùng HĐ đã làm sạch', () => {
  const pn = { id: 'b', name: 'HỘ KINH DOANH SHOP HOÀI VŨ', tax_code: '077093001530', address: 'Số 49, Đường số 7, Khu phố 5', ma_hdnt: '01/01/2026/HĐNTMB/NT/ANHTAM99' };
  assert.deepEqual(benMua({ ...base, buyer: pn }), { ten: 'HỘ KINH DOANH SHOP HOÀI VŨ', dia_chi: 'Số 49, Đường số 7, Khu phố 5', mst: '077093001530' });
  assert.deepEqual(benMua({ ...base, buyer: { ...pn, tax_code: '082195003202' } }), { ten: 'HỘ KINH DOANH SHOP HOÀI VŨ', dia_chi: 'Số 49, Đường số 7', mst: '077093001530' });
  const v = docVars({ ...base, buyer: pn }, 'bbgn');
  assert.equal(v.ten_mua, 'HỘ KINH DOANH SHOP HOÀI VŨ'); assert.match(v.can_cu, /^01\/01\/2026\/HĐNTMB\/NT\/ANHTAM99 ký ngày 01 tháng 01 năm 2026$/);
});

test('mẫu HĐNT mới: đủ chỗ điền, điền ra đúng pháp nhân', async () => {
  const f = await unzip(readFileSync('public/mau-hd/hdnt.docx').buffer as ArrayBuffer);
  const xml = new TextDecoder().decode(f.get('word/document.xml')!);
  for (const k of ['so_hd', 'ngay_chu', 'ten_mua', 'dia_chi', 'mst', 'dai_dien', 'chuc_vu']) assert.ok(xml.includes(`{{${k}}}`), 'thiếu {{' + k + '}}');
  assert.ok(!xml.includes('ĐINH CÔNG KHA'), 'còn sót tên khách mẫu');
  const out = fillXml(xml, { ...base, buyer: { id: 'b', name: 'HỘ KINH DOANH SHOP KIM HƯƠNG', tax_code: '077093001530', address: 'Số 49', dai_dien: 'Bà Nguyễn Thị Kim Hương', chuc_vu: 'Chủ hộ KD',
    ma_hdnt: '02/02/2026/HĐNTMB/NT/ANHTAM99' } }, 'hdnt');
  assert.ok(out.includes('02/02/2026/HĐNTMB/NT/ANHTAM99') && out.includes('02 tháng 02 năm 2026') && out.includes('HỘ KINH DOANH SHOP KIM HƯƠNG') && out.includes('Bà Nguyễn Thị Kim Hương'));
  assert.ok(!/\{\{\w+\}\}/.test(out));
  assert.ok(out.includes('BÊN BÁN (Bên A): CÔNG TY TNHH DỊCH VỤ VÀ THƯƠNG MẠI QUỐC TẾ NAM TRUNG') || out.includes('NAM TRUNG'));
});
