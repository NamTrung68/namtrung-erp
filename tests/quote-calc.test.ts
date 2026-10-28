// Ca test vàng: báo giá BG2610-0003 trên CRM hiện tại
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { calcQuote, defaultHeader, roundTo } from '../src/lib/quote-calc';

const header = () => ({ ...defaultHeader(), tyGia: 4015, shipNoiDiaCNY: 8400, soKg: 13890, donGiaKg: 3500, soKhoi: 19.6, donGiaKhoi: 900000,
  phiDVPct: 1.2, phiUTPct: 1, lamTron: 1, vatPct: 8 });
const lines = [{ name: 'Chai thủy tinh kèm nắp', unit: 'Chiếc', qty: 100000, unit_price_cny: 2, duty_pct: 0, vat_pct: 8 }];

test('BG2610-0003 · ủy thác tính trên giá xuất', () => {
  const { totals: t, lines: l } = calcQuote(header(), lines);
  assert.equal(t.tienHang, 803_000_000);
  assert.equal(t.ship, 33_726_000);
  assert.equal(t.cuoc, 48_615_000);
  assert.equal(t.phiDV, 9_636_000);
  assert.equal(t.phiUT, 9_040_000);
  assert.equal(l[0].giaXuat, 9040);
  assert.equal(l[0].giaKhaiDV, 8520);
  assert.equal(t.tongTruocVAT, 904_000_000);
  assert.equal(t.vat, 72_320_000);
  assert.equal(t.tongSauVAT, 976_320_000);
  assert.equal(t.soThu, 976_337_000);
  assert.equal(t.chenh, -17_000);
  assert.equal(t.toKhai, 852_000_000);
  assert.equal(t.lnUocTinh, 57_170_000);
});

test('BG2610-0003 · ủy thác tính trên tiền hàng', () => {
  const { totals: t, lines: l } = calcQuote({ ...header(), coSoUyThac: 'tienHang' }, lines);
  assert.equal(t.phiUT, 8_030_000);
  assert.equal(l[0].giaXuat, 9030);
  assert.equal(l[0].giaKhaiDV, 8511);
  assert.equal(t.tongTruocVAT, 903_000_000);
  assert.equal(t.soThu, 975_247_000);
  assert.equal(t.chenh, -7_000);
  assert.equal(t.toKhai, 851_100_000);
  assert.equal(t.lnUocTinh, 56_170_000);
});

test('Phân bổ cước theo % cố định + tự chia', () => {
  const { lines: l } = calcQuote({ ...header(), soKhoi: 0, soKg: 100, donGiaKg: 10000 }, [
    { name: 'A', qty: 1, unit_price_cny: 100 }, { name: 'B', qty: 1, unit_price_cny: 300, freight_pct: 50 }, { name: 'C', qty: 1, unit_price_cny: 100 }]);
  assert.equal(Math.round(l[1].cuoc), 500000);
  assert.equal(Math.round(l[0].cuoc), 250000);
  assert.equal(Math.round(l[2].cuoc), 250000);
});

test('Xuất thấp 70% và xuất cao 110% có TNDN', () => {
  const thap = calcQuote({ ...header(), cheDoXuat: 'thap', pctXuat: 70, coSoUyThac: 'tienHang' }, lines);
  assert.equal(thap.lines[0].giaXuat, roundTo(9030.07 * 0.7, 1));
  const cao = calcQuote({ ...header(), cheDoXuat: 'cao', pctXuat: 110 }, lines);
  assert.ok(cao.totals.tndn > 0);
  assert.equal(cao.totals.tndn, Math.round((cao.totals.tongTruocVAT - cao.totals.giaDu) * 0.2));
  assert.equal(cao.totals.chenhLamTron, 0);
});

test('Cọc 80% (tiền hàng + phí DV) làm tròn lên nghìn', () => {
  const { totals: t } = calcQuote(header(), lines);
  assert.equal(t.coc, Math.ceil((803_000_000 + 9_636_000) * 0.8 / 1000) * 1000);
});

test('Bỏ qua dòng thiếu tên hoặc SL ≤ 0', () => {
  const r = calcQuote(header(), [...lines, { name: '', qty: 5, unit_price_cny: 1 }, { name: 'X', qty: 0, unit_price_cny: 1 }]);
  assert.equal(r.lines.length, 1);
});
