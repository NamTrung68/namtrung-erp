// Chu kỳ 2 (bản 25): đối chiếu 3 nguồn ngay khi nạp HĐ chính thức APT
//   HĐ chính thức (mã hàng MISA, tên, SL, đơn giá) ──tên + SL──► dòng nháp APT (MÃ KHAI BÁO) ──đã ghép ở chu kỳ 1──► file xe (đơn, khách, sale, giá khách)
// Cùng quy tắc với SQL app.hd_ten / app.out_item_check để xem trước = kết quả lưu.
import { sim } from './doisoat';

/** Tên so khớp: thường hóa, gộp khoảng trắng, bỏ dấu câu cuối (sai số copy) */
export const hdTen = (t: any) => String(t ?? '').toLowerCase().replace(/\s+/g, ' ').replace(/[\s.,;:]+$/, '').trim();
const eq = (a: any, b: any) => a != null && b != null && Math.abs(Number(a) - Number(b)) < 0.0001;

export type HdKind = 'khop' | 'gan' | 'chua';
export const HD_KIND: Record<HdKind, [string, string]> = { khop: ['Khớp tên + SL', 'green'], gan: ['Gần đúng — kiểm lại', 'amber'], chua: ['Chưa tìm thấy dòng nháp', 'red'] };
export interface HdMatch { i: number; line: any | null; kind: HdKind; score: number; lech: string | null }

/** Đối chiếu chi tiết 1 dòng HĐ ký với dòng nháp: SL, đơn giá (nháp / NOTE / đề xuất ± làm tròn), thuế suất */
export function hdCheck(r: { sl_nhap: number; dg_nhap: number | null; vat: number | null }, l: any, lamTron = 100): string | null {
  const v: string[] = [];
  if (l.sl_apt != null && !eq(r.sl_nhap, l.sl_apt)) v.push(`SL HĐ ${r.sl_nhap} ≠ nháp ${l.sl_apt}`);
  if (r.dg_nhap != null) {
    const ok = [l.gia_nhap, l.gia_note].some(g => g != null && Math.abs(Number(r.dg_nhap) - Number(g)) <= 0.5) || (l.gia_de_xuat != null && Math.abs(Number(r.dg_nhap) - Number(l.gia_de_xuat)) < lamTron);
    if (!ok) v.push(`Đơn giá HĐ ${r.dg_nhap} ≠ nháp ${l.gia_note ?? l.gia_nhap}${l.gia_de_xuat ? ' / đề xuất ' + Math.round(l.gia_de_xuat) : ''}`);
  }
  if (r.vat != null && l.vat != null && Math.abs(Number(r.vat) - Number(l.vat)) > 0.0001) v.push(`Thuế suất HĐ ${Math.round(r.vat * 100)}% ≠ nháp ${Math.round(Number(l.vat) * 100)}%`);
  return v.length ? v.join(' · ') : null;
}

/** Ghép từng dòng HĐ ký về dòng nháp (mỗi dòng nháp dùng 1 lần). lines = acc_lines có apt_stt; taken = id dòng nháp đã thuộc mã hàng khác */
export function matchHd(rows: { ma_hang: string; ten: string; sl_nhap: number; dg_nhap: number | null; vat: number | null }[], lines: any[], taken = new Set<string>(), lamTron = 100): HdMatch[] {
  const used = new Set<string>(taken); const out: HdMatch[] = rows.map((_, i) => ({ i, line: null, kind: 'chua', score: 0, lech: null }));
  const byName = new Map<string, any[]>(); lines.forEach(l => { const k = hdTen(l.ten_apt); byName.set(k, [...(byName.get(k) || []), l]); });
  const pick = (cs: any[], r: any) => cs.filter(l => !used.has(l.id)).sort((a, b) => (eq(b.sl_apt, r.sl_nhap) ? 1 : 0) - (eq(a.sl_apt, r.sl_nhap) ? 1 : 0)
    || (Math.abs(Number(a.gia_nhap ?? 0) - Number(r.dg_nhap ?? -1)) <= 0.5 ? -1 : 1))[0];
  // lượt 1: tên trùng (sau chuẩn hóa) + cùng SL
  rows.forEach((r, i) => { const c = pick((byName.get(hdTen(r.ten)) || []).filter(l => eq(l.sl_apt, r.sl_nhap)), r); if (c) { used.add(c.id); out[i] = { i, line: c, kind: 'khop', score: 1, lech: null }; } });
  // lượt 2: tên trùng, SL lệch (vẫn ghép nhưng sẽ báo lệch)
  rows.forEach((r, i) => { if (out[i].line) return; const c = pick(byName.get(hdTen(r.ten)) || [], r); if (c) { used.add(c.id); out[i] = { i, line: c, kind: 'khop', score: 1, lech: null }; } });
  // lượt 3: tên gần đúng ≥ 92% + cùng SL (sai số copy nặng hơn)
  rows.forEach((r, i) => { if (out[i].line) return;
    let best: any = null, bs = 0; for (const l of lines) { if (used.has(l.id) || !eq(l.sl_apt, r.sl_nhap)) continue; const s = sim(r.ten, l.ten_apt); if (s > bs) { bs = s; best = l; } }
    if (best && bs >= 0.92) { used.add(best.id); out[i] = { i, line: best, kind: 'gan', score: bs, lech: null }; } });
  out.forEach(m => { if (m.line) m.lech = hdCheck(rows[m.i], m.line, lamTron); });
  return out;
}

/** Chọn xe khớp nhiều tên nhất với file HĐ */
export function bestTruck(rows: { ten: string }[], linesByTruck: Map<string, any[]>): string | null {
  const names = new Set(rows.map(r => hdTen(r.ten))); let best: string | null = null, bn = 0;
  linesByTruck.forEach((ls, id) => { const n = ls.filter(l => names.has(hdTen(l.ten_apt))).length; if (n > bn) { bn = n; best = id; } });
  return best;
}
