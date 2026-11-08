// Bản 35–36 — Tra cứu thông tin xuất HĐ theo MST
// Nguồn chính: Xinvoice (dữ liệu Tổng cục Thuế, bản miễn phí, có TÌNH TRẠNG MST) gọi thẳng từ trình duyệt — không cần khóa.
// Giới hạn 10 lần / 30 giây (tính chung theo mạng văn phòng) → ERP nhớ kết quả 7 ngày trong mst_cache dùng chung, tự giãn nhịp, báo đợi khi vượt.
// Giao diện chỉ dùng lookupMst() + MstResult: khi có phương án MISA tốt hơn chỉ cần thêm 1 nguồn ở đây.
import { db } from './sb';
import { stripVN } from './format';

export interface MstResult { found: boolean; mst: string; name: string; address: string; status: string; active: boolean | null; provider: string; warnings: string[]; at: string; cached?: boolean;
  org_type?: string; tax_dept?: string; level?: 'red' | 'amber' | 'green' }
export const PROVIDER: Record<string, string> = { vietqr: 'VietQR', xinvoice: 'Xinvoice · Tổng cục Thuế', misa: 'MISA meInvoice', local: 'Kiểm tra dạng số' };

/** Tình trạng MST (Xinvoice): chỉ “NNT đang hoạt động” (kể cả “đã được cấp GCN ĐKT”) là ổn; còn lại đều cảnh báo */
export function statusLevel(st: string): 'red' | 'amber' | 'green' | '' {
  const s = String(st || '').trim(); if (!s) return '';
  if (/^NNT đang hoạt động(\s*\(đã được cấp GCN ĐKT\))?$/i.test(s)) return 'green';
  if (/ngừng|tạm ngừng|chấm dứt|đóng MST|không hoạt động/i.test(s)) return 'red';
  return 'amber';
}
const statusWarn = (st: string): string[] => { const l = statusLevel(st);
  return l === 'red' ? [`Tình trạng MST: “${st}” — KHÔNG xuất HĐ khi chưa xác minh với khách`] : l === 'amber' ? [`Tình trạng MST: “${st}” — khác “NNT đang hoạt động”, kiểm tra lại với khách / kế toán`] : []; };

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

/** Xinvoice: 200 → dữ liệu; 404 {"message":"Tax not found …"} → không tìm thấy; 429 → vượt giới hạn */
export function xinvoiceNorm(mst: string, status: number, j: any): MstResult {
  const at = new Date().toISOString();
  if (status === 404 || (j && j.success === false && /not found|không tìm thấy/i.test(String(j.message || j.error || ''))))
    return { found: false, mst, name: '', address: '', status: '', active: null, provider: 'xinvoice', warnings: ['Không tìm thấy MST trên dữ liệu thuế — kiểm tra lại số'], at };
  if (status === 429) throw new RateLimit();
  if (status !== 200 || !j?.name) throw new Error('Xinvoice: ' + (j?.message || j?.error || 'lỗi ' + status));
  const st = String(j.status || ''); const l = statusLevel(st);
  return { found: true, mst: j.taxID || mst, name: String(j.name).replace(/\s+/g, ' ').trim(), address: j.address || '', status: st, active: l === 'green' ? true : l === 'red' ? false : null,
    provider: 'xinvoice', warnings: statusWarn(st), at, org_type: j.orgType || '', tax_dept: j.taxDepartment || '' };
}
export class RateLimit extends Error { constructor(public wait = 30) { super(`Tra cứu MST đang vượt giới hạn (10 lần / 30 giây cho cả văn phòng) — đợi khoảng ${wait} giây rồi bấm “Tra lại”`); } }

// Tự giãn nhịp trong trình duyệt: tối đa 9 lần / 30 giây; vượt → báo đợi, không gọi thêm
const hits: number[] = []; let blockedUntil = 0;
const slot = () => { const now = Date.now(); while (hits.length && now - hits[0] > 30_000) hits.shift();
  if (now < blockedUntil) throw new RateLimit(Math.ceil((blockedUntil - now) / 1000));
  if (hits.length >= 9) throw new RateLimit(Math.ceil((30_000 - (now - hits[0])) / 1000) + 1); hits.push(now); };

const memo = new Map<string, MstResult>(); const inflight = new Map<string, Promise<MstResult>>();
export async function lookupMst(mst: string, fresh = false): Promise<MstResult> {
  const m = String(mst || '').replace(/\s/g, '');
  if (!mstForm(m)) throw new Error('MST phải là 10 số, 10-3 số hoặc CCCD 12 số');
  if (!fresh && memo.has(m)) return memo.get(m)!;
  if (inflight.has(m)) return inflight.get(m)!;
  const job = (async () => {
    let r: MstResult | null = null;
    if (!fresh) { const c = await db.rpc<any>('mst_cache_get', { p_mst: m }).catch(() => null); if (c?.found) r = { ...c, warnings: c.provider === 'xinvoice' ? statusWarn(c.status) : c.warnings || [], cached: true }; }
    if (!r) {
      slot();
      try { const res = await fetch('https://api.xinvoice.vn/gdt-api/tax-payer/' + encodeURIComponent(m), { headers: { Accept: 'application/json' } });
        r = xinvoiceNorm(m, res.status, await res.json().catch(() => null)); }
      catch (e: any) {
        if (e instanceof RateLimit) { blockedUntil = Date.now() + 30_000; throw new RateLimit(30); }
        if (/^Xinvoice/.test(e?.message || '')) throw e;
        // mất kết nối Xinvoice → tạm dùng VietQR (không có tình trạng MST)
        try { const res = await fetch('https://api.vietqr.io/v2/business/' + encodeURIComponent(m), { headers: { Accept: 'application/json' } }); r = vietqrNorm(m, await res.json());
          r.warnings.push('Nguồn dự phòng VietQR: không có tình trạng hoạt động — tra lại sau'); }
        catch { throw new Error('Không tra được MST lúc này (' + (e?.message || 'lỗi mạng') + ') — nhập tay theo giấy phép / thông tin khách gửi'); }
      }
      if (r.found && r.provider === 'xinvoice') db.rpc('mst_cache_put', { p_mst: m, p_data: { ...r, warnings: [] } }).catch(() => null);
    }
    r = { ...r, warnings: [...localWarnings(m).filter(w => !(r!.found && /sai số kiểm tra/.test(w))), ...(r.warnings || [])] };
    r.level = mstLevel(r) || undefined; memo.set(m, r); return r;
  })();
  inflight.set(m, job); try { return await job; } finally { inflight.delete(m); }
}
/** Mức cảnh báo: đỏ = không tìm thấy / ngừng hoạt động / sai số kiểm tra; vàng = còn lưu ý; xanh = ổn */
export const mstLevel = (r: MstResult | null): 'red' | 'amber' | 'green' | '' => (!r ? '' : !r.found || r.active === false || statusLevel(r.status) === 'red' || r.warnings.some(w => /sai số kiểm tra|KHÔNG xuất/.test(w)) ? 'red' : r.warnings.length ? 'amber' : 'green');
