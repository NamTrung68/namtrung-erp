// Bản 35 — Đọc file XML gốc của hóa đơn điện tử (chuẩn Tổng cục Thuế, NĐ 123 / TT 78) do APT gửi
// Không dùng DOMParser để chạy được cả trong test Node. Trả dòng hàng theo cùng dạng dòng sổ (SoRow) để đối chiếu như Excel.

export interface XmlLine { stt: number; ten: string; dvt: string; sl: number; dg: number | null; tt: number | null; vat: number | null; ts: string; tchat: number }
export interface XmlHd { so_hd: string; ky_hieu: string; mau_so: string; ngay: string | null; ncc: string; mst_ban: string; nguoi_mua: string; mst_mua: string; tong: number | null; lines: XmlLine[]; bo_qua: string[] }

const ENT: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
const dec = (s: string) => s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
  .replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e: string) => e[0] === '#' ? String.fromCodePoint(e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)) : ENT[e] ?? m);
/** Nội dung thẻ đầu tiên (bỏ tiền tố namespace nếu có) */
const tag = (x: string, name: string): string => { const m = x.match(new RegExp(`<(?:\\w+:)?${name}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:\\w+:)?${name}>`)); return m ? dec(m[1]).trim() : ''; };
const blocks = (x: string, name: string): string[] => Array.from(x.matchAll(new RegExp(`<(?:\\w+:)?${name}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:\\w+:)?${name}>`, 'g'))).map(m => m[1]);
const n = (s: string): number | null => { if (!s) return null; const v = Number(s.replace(/,/g, '')); return Number.isFinite(v) ? v : null; };

/** Thuế suất XML: "8%", "10%", "0%", "KCT", "KKKNT" → phần thập phân (0.08); không chịu thuế → null */
export function xmlVat(ts: string): number | null {
  const m = String(ts || '').trim().match(/^(\d+(?:[.,]\d+)?)\s*%?$/); if (!m) return null;
  return Math.round(Number(m[1].replace(',', '.')) * 100) / 10000;
}

export function parseHdXml(text: string): XmlHd {
  const x = String(text || '').replace(/^﻿/, '');
  if (!/<(?:\w+:)?(HDon|DLHDon)[\s>]/.test(x)) throw new Error('Không phải file XML hóa đơn điện tử (thiếu thẻ HDon / DLHDon)');
  const dl = blocks(x, 'DLHDon')[0] || x;
  const ttc = blocks(dl, 'TTChung')[0] || dl;
  const nban = blocks(dl, 'NBan')[0] || ''; const nmua = blocks(dl, 'NMua')[0] || '';
  const ttoan = blocks(dl, 'TToan')[0] || '';
  const mau = tag(ttc, 'KHMSHDon'); const kh = tag(ttc, 'KHHDon');
  const lines: XmlLine[] = []; const bo_qua: string[] = [];
  blocks(dl, 'HHDVu').forEach((b, i) => {
    const tchat = Number(tag(b, 'TChat') || 1); const ten = tag(b, 'THHDVu'); const sl = n(tag(b, 'SLuong'));
    const stt = Number(tag(b, 'STT')) || i + 1;
    if (tchat === 3 || tchat === 4) { bo_qua.push(`Dòng ${stt}: ${tchat === 3 ? 'chiết khấu' : 'ghi chú'} — ${ten.slice(0, 60)}`); return; }
    if (!ten || !sl) { bo_qua.push(`Dòng ${stt}: không có ${!ten ? 'tên hàng' : 'số lượng'}`); return; }
    const ts = tag(b, 'TSuat');
    lines.push({ stt, ten: ten.replace(/\s+/g, ' ').trim(), dvt: tag(b, 'DVTinh'), sl, dg: n(tag(b, 'DGia')), tt: n(tag(b, 'ThTien')), vat: xmlVat(ts), ts, tchat });
  });
  if (!lines.length) throw new Error('File XML không có dòng hàng hóa');
  const ngay = tag(ttc, 'NLap');
  return { so_hd: tag(ttc, 'SHDon').replace(/^0+(?=\d)/, ''), ky_hieu: mau + kh, mau_so: mau, ngay: /^\d{4}-\d{2}-\d{2}/.test(ngay) ? ngay.slice(0, 10) : null,
    ncc: tag(nban, 'Ten'), mst_ban: tag(nban, 'MST'), nguoi_mua: tag(nmua, 'Ten'), mst_mua: tag(nmua, 'MST'), tong: n(tag(ttoan, 'TgTTTBSo')), lines, bo_qua };
}

/** Số HĐ dùng trong mã hàng: chỉ chữ số, bỏ số 0 đầu */
export const soHdKey = (s: string) => String(s || '').replace(/\D/g, '').replace(/^0+(?=\d)/, '');
/** Mã hàng ERP của dòng XML: {mã khai báo}-{số HĐ}; chưa có mã khai báo → CHUAKB-{số HĐ}-{STT} (đổi khi ghép tay) */
export const maHangXml = (kb: string | null | undefined, so: string, stt: number) => {
  const k = String(kb || '').trim().toUpperCase(); const s = soHdKey(so) || '0';
  return k ? `${k}-${s}` : `CHUAKB-${s}-${stt}`;
};
/** Gán mã hàng + phần (1 mã khai báo xuất hiện 2 lần trên cùng HĐ → phần 2) */
export function assignMaHang<T extends { stt_hd: number | null; so_hd_vao: string }>(rows: T[], kbOf: (i: number) => string | null): (T & { ma_hang: string; part: number })[] {
  const seen = new Map<string, number>();
  return rows.map((r, i) => { const ma = maHangXml(kbOf(i), r.so_hd_vao, r.stt_hd || i + 1); const part = (seen.get(ma) || 0) + 1; seen.set(ma, part); return { ...r, ma_hang: ma, part }; });
}
