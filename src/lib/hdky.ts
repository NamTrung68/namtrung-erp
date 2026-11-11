// Bản 38 — PDF HĐ đã ký: lấy từ Google Drive của công ty; chưa có thì hàm máy chủ "hdky" tải từ meInvoice theo mã tra cứu rồi lưu Drive
import { accessToken } from './sb';
import { hdFile, type DriveCfg } from './drive';

const b64Blob = (s: string) => { const bin = atob(s); const u8 = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i); return new Blob([u8], { type: 'application/pdf' }); };

export async function hdkyCall<T = any>(action: string, body: Record<string, any> = {}): Promise<T> {
  const c = window.NT_CONFIG; if (!c?.supabaseUrl) throw new Error('Chưa cấu hình Supabase');
  let r: Response;
  try {
    r = await fetch(c.supabaseUrl + '/functions/v1/hdky', { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: c.supabaseAnonKey, Authorization: 'Bearer ' + (await accessToken()) },
      body: JSON.stringify({ action, ...body }) });
  } catch { throw new Error('Không kết nối được máy chủ tải HĐ — kiểm tra mạng'); }
  if (r.status === 404) throw new Error('Hàm máy chủ "hdky" chưa được triển khai trên Supabase — báo Admin');
  let j: any = null; try { j = await r.json(); } catch { /* */ }
  if (!j) throw new Error(`Máy chủ tải HĐ trả lỗi ${r.status}`);
  if (!j.ok) throw new Error(j.error || 'Lỗi tải HĐ');
  return j as T;
}

const mem = new Map<string, Promise<Blob>>();
/** PDF HĐ đã ký của 1 phiếu (giữ trong bộ nhớ trang) */
export function kyPdf(drive: DriveCfg | undefined, invoiceId: string): Promise<Blob> {
  const hit = mem.get(invoiceId); if (hit) return hit;
  const p = (async () => {
    const r = await hdkyCall<{ file_id: string; data?: string }>('get', { invoice_id: invoiceId });
    if (r.data) return b64Blob(r.data);
    if (!drive?.url) throw new Error('Chưa cấu hình Google Drive — nhờ Admin bật ở Cấu hình');
    return hdFile(drive, r.file_id);
  })();
  mem.set(invoiceId, p); p.catch(() => mem.delete(invoiceId));
  return p;
}

const slug = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D').replace(/[^A-Za-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 40);
export const kyName = (v: { so_hd?: string | null; code?: string; buyer_name?: string | null }) =>
  `HD${String(v.so_hd || '').replace(/\D/g, '').replace(/^0+(?=\d)/, '') || v.code || ''}_${slug(v.buyer_name || '')}.pdf`;

const ngayMem = new Map<string, Promise<string | null>>();
/** Ngày in trên HĐ đã ký ("Ngày … tháng … năm …" trong PDF) — dùng làm ngày chứng từ. Không đọc được → null */
export function kyNgay(drive: DriveCfg | undefined, invoiceId: string): Promise<string | null> {
  const hit = ngayMem.get(invoiceId); if (hit) return hit;
  const p = (async () => {
    const blob = await kyPdf(drive, invoiceId);
    const [{ pdfText }, { hdNgay }] = await Promise.all([import('./pdf'), import('./hdfile')]);
    const ngay = hdNgay(await pdfText(blob, 1)) || null;
    return ngay && /^\d{4}-\d{2}-\d{2}$/.test(ngay) ? ngay : null;
  })().catch(() => null);
  ngayMem.set(invoiceId, p);
  return p;
}
