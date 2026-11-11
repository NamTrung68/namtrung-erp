// Bản 35 — Bộ chứng từ đi kèm HĐ đầu ra đã ký: Đơn đặt hàng, Biên bản giao nhận, HĐ mua bán (khách chưa ký HĐ nguyên tắc), HĐ nguyên tắc
// Mẫu Word của anh (public/mau-hd/*.docx) đã gắn sẵn chỗ điền {{...}}; ERP chỉ thay thông tin khách / hàng / ngày / số — giữ nguyên định dạng.
// Ngày của mọi chứng từ = ngày HĐ đã ký (ngày HĐ trên MISA) để đồng bộ với hóa đơn; HĐ nguyên tắc dùng ngày ký HĐNT.
import { docTien } from '../pages/out/print';

export type DocKind = 'ddh' | 'bbgn' | 'hdmb' | 'hdnt';
export const DOC_NAME: Record<DocKind, string> = { ddh: 'Đơn đặt hàng', bbgn: 'Biên bản giao nhận', hdmb: 'HĐ mua bán', hdnt: 'HĐ nguyên tắc' };
export const DOC_SHORT: Record<DocKind, string> = { ddh: 'DDH', bbgn: 'BBGN', hdmb: 'HDMB', hdnt: 'HDNT' };

export interface DocLine { ten: string; dvt: string | null; sl: number; don_gia: number; vat: number | null }
export interface DocInv {
  id: string; code: string; so_hd: string | null; mds?: string[]; ngay_hd: string | null; buyer_name: string | null; tax_code: string | null; address: string | null; payment: string | null;
  buyer?: { id?: string; dai_dien?: string | null; chuc_vu?: string | null; dia_chi_giao?: string | null; ma_hdnt?: string | null; ngay_hdnt?: string | null } | null; lines: DocLine[];
}

const esc = (s: any) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' } as any)[c]);
const vnd = (v: number) => Math.round(v).toLocaleString('vi-VN');
const qty = (v: number) => Number(v).toLocaleString('vi-VN', { maximumFractionDigits: 3 });
const p2 = (n: number | string) => String(n).padStart(2, '0');
const dmy = (iso: string) => { const [y, m, d] = iso.slice(0, 10).split('-'); return `${d}/${m}/${y}`; };
const ngayChu = (iso: string) => { const [y, m, d] = iso.slice(0, 10).split('-'); return `${p2(d)} tháng ${p2(m)} năm ${y}`; };
/** Số đơn hàng in trên ĐĐH / BBGN = mã đơn (ID đơn) của các dòng trong HĐ, VD "MD2546, MD2547"; không có thì dùng số HĐ */
export const maDon = (v: DocInv) => { const m = Array.from(new Set((v.mds || []).map(x => String(x || '').trim().toUpperCase()).filter(Boolean).map(x => (/^\d+$/.test(x) ? 'MD' + x : x))))
  .sort((a, b) => a.localeCompare(b, 'en', { numeric: true })); return m.length ? m.join(', ') : soDon(v); };
export const soDon = (v: DocInv) => String(v.so_hd || '').replace(/\D/g, '').replace(/^0+(?=\d)/, '') || v.code;
const CHAM = '…………………………';
/** Ngày HĐNT: điền tay, không thì đọc từ đầu mã dạng 28/08/2026/HĐNTHH/... */
export function ngayHdnt(ma?: string | null, ngay?: string | null): string | null {
  if (ngay) return ngay.slice(0, 10);
  const m = String(ma || '').match(/^\s*(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})/); return m ? `${m[3]}-${p2(m[2])}-${p2(m[1])}` : null;
}
export const hasHdnt = (v: DocInv) => !!String(v.buyer?.ma_hdnt || '').trim();
/** Số HĐ mua bán (khách không có HĐ nguyên tắc): dd/mm/yyyy/HĐMBHH/NT/{số HĐ} — mỗi HĐ 1 số riêng, đọc ra được ngày + số HĐ */
export const soHdmb = (v: DocInv) => `${dmy(v.ngay_hd!)}/HĐMBHH/NT/${soDon(v)}`;
/** Chứng từ mặc định đi kèm 1 HĐ: ĐĐH + BBGN + (HĐ mua bán nếu khách chưa ký HĐ nguyên tắc) */
export const docsOf = (v: DocInv): DocKind[] => ['ddh', 'bbgn', ...(hasHdnt(v) ? [] : ['hdmb' as DocKind])];
const TT: Record<string, string> = { 'TM/CK': 'Tiền mặt hoặc chuyển khoản', CK: 'Chuyển khoản', TM: 'Tiền mặt' };

/** Biến điền cho 1 chứng từ của 1 HĐ */
export function docVars(v: DocInv, kind: DocKind) {
  const ngay = v.ngay_hd || new Date().toISOString().slice(0, 10);
  const nt = ngayHdnt(v.buyer?.ma_hdnt, v.buyer?.ngay_hdnt);
  const sub = v.lines.reduce((s, l) => s + Math.round(Number(l.sl) * Number(l.don_gia)), 0);
  const thue = v.lines.reduce((s, l) => s + Math.round(Math.round(Number(l.sl) * Number(l.don_gia)) * Number(l.vat ?? 0)), 0);
  const chu = docTien(sub + thue).replace(/\.$/, ''); const bangChu = chu.charAt(0).toLowerCase() + chu.slice(1);
  const base: Record<string, string> = {
    so_don: maDon(v), ten_mua: v.buyer_name || '', dia_chi: v.address || '', dia_chi_giao: v.buyer?.dia_chi_giao || v.address || '', mst: v.tax_code || '',
    dai_dien: v.buyer?.dai_dien || CHAM, chuc_vu: v.buyer?.chuc_vu || CHAM, ngay: dmy(ngay), ngay_giao: dmy(ngay), ngay_chu: ngayChu(ngay),
    thanh_toan: TT[v.payment || 'TM/CK'] || v.payment || TT['TM/CK'], cong_tien: vnd(sub), tong: vnd(sub + thue), bang_chu: bangChu,
    can_cu: hasHdnt(v) ? `${v.buyer!.ma_hdnt!.trim()}${nt ? ' ký ngày ' + ngayChu(nt) : ''}` : `${soHdmb(v)} ký ngày ${ngayChu(ngay)}`,
    so_hd: kind === 'hdnt' ? String(v.buyer?.ma_hdnt || '').trim() : soHdmb(v),
  };
  if (kind === 'hdnt') base.ngay_chu = nt ? ngayChu(nt) : ngayChu(ngay);
  // Đơn đặt hàng: ngày giao = ngày ký HĐ; ngày đặt = 30 ngày trước, tính cả 2 đầu (ký 30/10/2026 → đặt 01/10/2026)
  if (kind === 'ddh') base.ngay = dmy(ngayDat(ngay));
  return base;
}
/** Ngày đặt hàng trên ĐĐH = ngày ký HĐ − 29 ngày (khoảng 30 ngày tính cả ngày đặt và ngày giao) */
export function ngayDat(iso: string): string {
  const d = new Date(iso.slice(0, 10) + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() - 29); return d.toISOString().slice(0, 10);
}

/** Dòng hàng + dòng thuế theo từng thuế suất (HĐ có 8% và 10% → 2 dòng thuế) */
export function docRows(v: DocInv) {
  const rows = v.lines.map((l, i) => ({ stt: String(i + 1), ten_hang: l.ten, dvt: l.dvt || '', sl: qty(l.sl), don_gia: vnd(l.don_gia), thanh_tien: vnd(Math.round(Number(l.sl) * Number(l.don_gia))) }));
  const g = new Map<string, number>();
  v.lines.forEach(l => { const k = Math.round(Number(l.vat ?? 0) * 100) + '%'; g.set(k, (g.get(k) || 0) + Math.round(Math.round(Number(l.sl) * Number(l.don_gia)) * Number(l.vat ?? 0))); });
  const tax = Array.from(g.entries()).sort((a, b) => parseFloat(a[0]) - parseFloat(b[0])).map(([ts, t]) => ({ ts, tien_thue: vnd(t) }));
  return { rows, tax: tax.length ? tax : [{ ts: '0%', tien_thue: '0' }] };
}

/** Nhân bản dòng bảng (<w:tr>) có chứa token cho từng phần tử */
export function repeatRow(xml: string, token: string, list: Record<string, string>[]): string {
  const k = xml.indexOf(token); if (k < 0) return xml;
  const s = Math.max(xml.lastIndexOf('<w:tr ', k), xml.lastIndexOf('<w:tr>', k)); const e = xml.indexOf('</w:tr>', k) + 7;
  if (s < 0 || e < 7) return xml;
  const tpl = xml.slice(s, e);
  return xml.slice(0, s) + list.map(r => tpl.replace(/\{\{(\w+)\}\}/g, (m, n) => (n in r ? esc(r[n]) : m))).join('') + xml.slice(e);
}
export function fillXml(xml: string, v: DocInv, kind: DocKind): string {
  let x = xml;
  if (kind === 'ddh' || kind === 'bbgn') { const { rows, tax } = docRows(v); x = repeatRow(x, '{{ten_hang}}', rows); x = repeatRow(x, '{{ts}}', tax); }
  const vars = docVars(v, kind);
  return x.replace(/\{\{(\w+)\}\}/g, (_, n) => esc(vars[n] ?? ''));
}

// ---------- trình duyệt: đọc mẫu, đóng gói .docx / .zip ----------
const cache = new Map<DocKind, Promise<Map<string, Uint8Array>>>();
async function tpl(kind: DocKind) {
  if (!cache.has(kind)) cache.set(kind, (async () => {
    const url = new URL(`mau-hd/${kind}.docx`, location.href.split('#')[0]).href;
    const r = await fetch(url); if (!r.ok) throw new Error('Không tải được mẫu ' + DOC_NAME[kind]);
    const { unzip } = await import('./xlsx'); return unzip(await r.arrayBuffer());
  })().catch(e => { cache.delete(kind); throw e; }));
  return cache.get(kind)!;
}
export async function makeDocx(v: DocInv, kind: DocKind): Promise<Blob> {
  const files = await tpl(kind); const { makeZip } = await import('./zip'); const enc = new TextEncoder(); const dec = new TextDecoder();
  const out = Array.from(files.entries()).map(([name, data]) => ({ name, data: new Blob([name === 'word/document.xml' ? enc.encode(fillXml(dec.decode(data), v, kind)) : data]) }));
  const z = await makeZip(out);
  return new Blob([z], { type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' });
}
const slug = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D').replace(/[^A-Za-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 40);
export const docFile = (v: DocInv, kind: DocKind) => kind === 'hdnt' ? `HDNT_${slug(v.buyer_name || '')}_${slug(String(v.buyer?.ma_hdnt || ''))}.docx` : `${DOC_SHORT[kind]}_HD${soDon(v)}_${slug(v.buyer_name || '')}.docx`;

/** Gói nhiều HĐ: mỗi HĐ 1 thư mục; HĐ nguyên tắc chỉ 1 bản cho mỗi mã HĐNT */
export async function makeBundle(invs: DocInv[], kinds: DocKind[], onStep?: (s: string) => void, pdf: Record<string, Blob> = {}): Promise<{ blob: Blob; n: number }> {
  const { makeZip } = await import('./zip'); const files: { name: string; data: Blob }[] = []; const seenNt = new Set<string>();
  for (let i = 0; i < invs.length; i++) { const v = invs[i]; onStep?.(`Đang tạo ${i + 1}/${invs.length}…`);
    const dir = `HD${soDon(v)}_${slug(v.buyer_name || '')}`;
    for (const k of kinds) {
      if (k === 'hdmb' && hasHdnt(v)) continue;            // đã có HĐ nguyên tắc → không cần HĐ mua bán từng HĐ
      if (k === 'hdnt') { const ma = String(v.buyer?.ma_hdnt || '').trim(); if (!ma || seenNt.has(ma)) continue; seenNt.add(ma);
        files.push({ name: `HD_nguyen_tac/${docFile(v, k)}`, data: await makeDocx(v, k) }); continue; }
      files.push({ name: `${dir}/${docFile(v, k)}`, data: await makeDocx(v, k) });
    }
    if (pdf[v.id]) files.push({ name: `${dir}/HD_da_ky_${soDon(v)}_${slug(v.buyer_name || '')}.pdf`, data: pdf[v.id] }); // bản 38: HĐ đã ký (PDF)
  }
  return { blob: await makeZip(files), n: files.length };
}
