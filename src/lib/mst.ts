// Bản 35 — Tra cứu thông tin xuất HĐ theo MST
// Giao diện chỉ dùng lookupMst() + MstResult. Nhà cung cấp (VietQR / Xinvoice / MISA) chọn ở hàm máy chủ "mst" (Supabase) —
// đổi sang MISA chỉ cần nhập bí mật MISA trên Supabase, không sửa giao diện. Hàm máy chủ chưa triển khai → gọi thẳng VietQR từ trình duyệt.
import { accessToken } from './sb';
import { stripVN } from './format';

export interface MstResult { found: boolean; mst: string; name: string; address: string; status: string; active: boolean | null; provider: string; warnings: string[]; at: string; cached?: boolean }
export const PROVIDER: Record<string, string> = { vietqr: 'VietQR', xinvoice: 'Xinvoice (dữ liệu Tổng cục Thuế)', misa: 'MISA meInvoice', local: 'Kiểm tra dạng số' };

/** MST 10 số (hoặc 10-3 số chi nhánh): chữ số thứ 10 là số kiểm tra theo quy định của Tổng cục Thuế */
export function mstChecksum(mst: string): boolean | null {
  const m = String(mst || '').replace(/\s/g, '').match(/^(\d{10})(-\d{3})?$/); if (!m) return null;
  const d = m[1].split('').map(Number); const w = [31, 29, 23, 19, 17, 13, 7, 5, 3];
  const c = 10 - (w.reduce((s, x, i) => s + x * d[i], 0) % 11);
  return c === d[9];
}
export const mstForm = (mst: string) => /^(\d{10}|\d{10}-\d{3}|\d{12})$/.test(String(mst || '').replace(/\s/g, ''));

/** Kiểm tra trên máy (không cần mạng): dạng số + số kiểm tra */
export function localWarnings(mst: string): string[] {
  const s = String(mst || '').replace(/\s/g, ''); if (!s) return [];
  if (!mstForm(s)) return ['MST phải là 10 số, 10-3 số (chi nhánh) hoặc CCCD 12 số (hộ kinh doanh / cá nhân)'];
  if (mstChecksum(s) === false) return ['MST sai số kiểm tra (chữ số cuối) — gần như chắc chắn gõ nhầm'];
  return [];
}

const norm = (s: string) => stripVN(String(s || '')).toUpperCase().replace(/[^A-Z0-9]+/g, ' ').trim();
/** Tên đang nhập khác tên đăng ký thuế? (bỏ dấu, ký tự đặc biệt, khoảng trắng) */
export const nameDiff = (a: string, b: string) => !!a && !!b && norm(a) !== norm(b);

function vietqrNorm(mst: string, j: any): MstResult {
  const at = new Date().toISOString();
  if (j?.code === '00' && j.data) return { found: true, mst: j.data.id || mst, name: j.data.name || '', address: j.data.address || '', status: '', active: null, provider: 'vietqr', warnings: [], at };
  if (j?.code === '51' || j?.code === '52') return { found: false, mst, name: '', address: '', status: j.desc || '', active: null, provider: 'vietqr', warnings: ['Không tìm thấy MST trên dữ liệu thuế — kiểm tra lại số'], at };
  throw new Error('VietQR: ' + (j?.desc || 'không trả dữ liệu'));
}

const memo = new Map<string, MstResult>();
export async function lookupMst(mst: string, fresh = false): Promise<MstResult> {
  const m = String(mst || '').replace(/\s/g, '');
  if (!mstForm(m)) throw new Error('MST phải là 10 số, 10-3 số hoặc CCCD 12 số');
  if (!fresh && memo.has(m)) return memo.get(m)!;
  const c = window.NT_CONFIG; let r: MstResult | null = null; let fnErr = '';
  if (c?.supabaseUrl) {
    try {
      const res = await fetch(c.supabaseUrl + '/functions/v1/mst', { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: c.supabaseAnonKey, Authorization: 'Bearer ' + (await accessToken()) },
        body: JSON.stringify({ mst: m, fresh }) });
      if (res.status !== 404) { const j = await res.json().catch(() => null); if (j?.ok) r = j.result; else fnErr = j?.error || 'Máy chủ tra MST lỗi ' + res.status; }
    } catch { /* chưa triển khai / mạng → thử thẳng VietQR */ }
  }
  if (!r) {
    try { const res = await fetch('https://api.vietqr.io/v2/business/' + encodeURIComponent(m), { headers: { Accept: 'application/json' } }); r = vietqrNorm(m, await res.json()); }
    catch (e: any) { throw new Error(fnErr || 'Không tra được MST lúc này (' + (e?.message || 'lỗi mạng') + ') — nhập tay theo giấy phép / thông tin khách gửi'); }
  }
  r = { ...r, warnings: [...localWarnings(m), ...(r.warnings || [])] };
  memo.set(m, r); return r;
}
/** Mức cảnh báo: đỏ = không tìm thấy / ngừng hoạt động / sai số kiểm tra; vàng = còn lưu ý; xanh = ổn */
export const mstLevel = (r: MstResult | null): 'red' | 'amber' | 'green' | '' => (!r ? '' : !r.found || r.active === false || r.warnings.some(w => /sai số kiểm tra|KHÔNG xuất/.test(w)) ? 'red' : r.warnings.length ? 'amber' : 'green');
