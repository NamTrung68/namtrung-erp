// Đối soát xe APT: so với kết quả skill doi-soat-xe-apt trên xe 25/10 (dữ liệu thật để ngoài repo, thiếu thì bỏ qua)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { DEFAULT_ACC_CFG, parseApt, parseKhaiBao, parseTkn, reconcile, parseInvoiceXml, judgeInvoiceLine, normMd, sim, vnNum, assign } from '../src/lib/doisoat';

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
  // bản 14: dòng biên > khung không tự chốt — chặn, có giá đề xuất, biên NT hiển thị theo giá nháp
  const over = r.lines.filter(l => l.gia_de_xuat && !l.gia_note);
  assert.ok(over.length > 0 && over.every(l => l.status === 'blocked' && l.gia_ap_dung === l.gia_nhap));
  // HĐ chính thức 2080 + 2081: 10 dòng không có đơn
  const dir = 'tests/fixtures/xml'; const byHH = new Map(r.lines.filter(l => l.hh).map(l => [l.hh!, l]));
  const res: Record<string, number> = {}; let money = 0;
  for (const f of readdirSync(dir)) { const inv = parseInvoiceXml(readFileSync(`${dir}/${f}`, 'utf8'));
    for (const il of inv.lines) { const k = judgeInvoiceLine(il, byHH.get(il.hh) || null); res[k] = (res[k] || 0) + 1; if (k === 'khong_don') money += il.tt; } }
  assert.equal(res.khong_don, 10); assert.equal(Math.round(money / 1e5) / 10, 164.3);
  assert.equal(res.khong_thuoc_xe, 47); assert.equal(res.khop, 49);
});
