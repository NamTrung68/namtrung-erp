// Đọc thông tin hóa đơn MISA từ tên file PDF (ưu tiên) hoặc chữ trong file
// Tên chuẩn:  NHAP_<MST|CCCD>_<Tổng tiền>_<yyyymmdd>_<stt>.pdf     KY_<Ký hiệu>-<Số HĐ>_<MST|CCCD>_<Tổng tiền>.pdf
// Tên cũ:     <MST>_<TEN_DON_VI>_<23.328.000>_<stt>.pdf  (coi là nháp)
export interface HdInfo { kind: 'nhap' | 'ky'; mst: string; tong: number | null; so_hd?: string; ky_hieu?: string; ngay?: string; from: 'ten' | 'noi_dung' }

const digits = (s: string) => (s || '').replace(/\D/g, '');
const money = (s: string) => { const d = digits(s); return d ? Number(d) : null; };
const ymd = (s?: string) => (s && /^\d{8}$/.test(s) ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : undefined);

export function parseHdName(name: string): HdInfo | null {
  const n = name.replace(/\.pdf$/i, '').trim();
  let m = n.match(/^NHAP_(\d{9,14})_([\d.,]+)(?:_(\d{8}))?(?:_.*)?$/i);
  if (m) return { kind: 'nhap', mst: m[1], tong: money(m[2]), ngay: ymd(m[3]), from: 'ten' };
  m = n.match(/^KY_([0-9A-Z]{4,10})-0*(\d{1,10})_(\d{9,14})_([\d.,]+)(?:_.*)?$/i);
  if (m) return { kind: 'ky', ky_hieu: m[1].toUpperCase(), so_hd: m[2], mst: m[3], tong: money(m[4]), from: 'ten' };
  m = n.match(/^(\d{9,14})_.+_(\d{1,3}(?:\.\d{3})+|\d{4,})_\d+$/);
  if (m) return { kind: 'nhap', mst: m[1], tong: money(m[2]), from: 'ten' };
  return null;
}

/** Từ chữ trong PDF MISA meInvoice. sellerMst: MST Nam Trung (bỏ qua khi tìm MST người mua) */
export function parseHdText(text: string, sellerMst = '0108195040'): HdInfo | null {
  const t = text.replace(/\s+/g, ' ');
  const msts = Array.from(t.matchAll(/Mã số thuế\s*:?\s*([\d\s-]{9,20})/gi)).map(x => digits(x[1])).filter(x => x.length >= 9 && x !== sellerMst);
  const cccd = t.match(/CCCD[^:]*:\s*(\d{9,12})/i)?.[1];
  const mst = msts[0] || cccd || '';
  const tong = t.match(/Tổng cộng\s*:?\s*[\d.]+\s+[\d.]+\s+([\d.]+)/i)?.[1] || t.match(/Cộng tiền thanh toán\s*:?\s*([\d.]+)/i)?.[1];
  const so = t.match(/Số\s*:\s*(<\s*Chưa cấp số\s*>|\d+)/i)?.[1] || '';
  const kh = t.match(/Ký hiệu\s*:\s*([0-9A-Z]{4,10})/i)?.[1];
  const d = t.match(/Ngày\s+(\d{1,2})\s+tháng\s+(\d{1,2})\s+năm\s+(\d{4})/i);
  const ngay = d ? `${d[3]}-${d[2].padStart(2, '0')}-${d[1].padStart(2, '0')}` : undefined;
  if (!mst && !tong) return null;
  const ky = /^\d+$/.test(so);
  return { kind: ky ? 'ky' : 'nhap', mst, tong: tong ? money(tong) : null, so_hd: ky ? String(Number(so)) : undefined, ky_hieu: kh, ngay, from: 'noi_dung' };
}
