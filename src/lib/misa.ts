// Bản 31 — Tạo HĐ nháp MISA meInvoice bằng API (chạy song song cách làm tay: Excel → MISA → tải PDF)
// Mọi lời gọi MISA đi qua hàm máy chủ "misa" (Supabase Edge Function). Trình duyệt không bao giờ thấy ClientID / mật khẩu / token MISA.
import { accessToken, db, fetchAll } from './sb';
import { writeXlsx } from './xlsx';
import { today } from './format';

export interface MisaCfg { enabled?: boolean; template_id?: string; template_name?: string; inv_series?: string; with_code?: boolean; batch?: number; auto_sync?: boolean; last_sync_at?: string; last_sync_pub?: number }
export const misaCfgOf = (settings: any): MisaCfg => settings?.accounting?.misa || {};
/** Đã bật API MISA (có ClientID, đã chọn mẫu HĐ, kế toán bật) */
export const misaOn = (settings: any) => { const m = misaCfgOf(settings); return !!(m.enabled && m.template_id && m.inv_series); };
export const batchOf = (settings: any) => Math.max(1, Math.min(30, Number(misaCfgOf(settings).batch) || 10));

export async function misaCall<T = any>(action: string, body: Record<string, any> = {}): Promise<T> {
  const c = window.NT_CONFIG; if (!c?.supabaseUrl) throw new Error('Chưa cấu hình Supabase');
  let r: Response;
  try {
    r = await fetch(c.supabaseUrl + '/functions/v1/misa', { method: 'POST', headers: { 'Content-Type': 'application/json', apikey: c.supabaseAnonKey, Authorization: 'Bearer ' + (await accessToken()) },
      body: JSON.stringify({ action, ...body }) });
  } catch { throw new Error('Không kết nối được máy chủ MISA — kiểm tra mạng'); }
  if (r.status === 404) throw new Error('Hàm máy chủ "misa" chưa được triển khai trên Supabase — báo Admin');
  let j: any = null; try { j = await r.json(); } catch { /* */ }
  if (!j) throw new Error(`Máy chủ MISA trả lỗi ${r.status}`);
  if (!j.ok) throw new Error(j.error || 'Lỗi MISA');
  return j as T;
}

export interface RunRow { invoice_id: string; code?: string; ok: boolean; error?: string; hd_id?: string; khop?: boolean | null; pdf?: 'ok' | 'loi' | ''; pdfErr?: string; warn?: string }
/** Tạo nháp theo lô (tối đa 30/lô, tuần tự), rồi lấy PDF từng phiếu. onProgress báo tiến độ để hiện thanh chạy. */
export async function runCreate(ids: string[], batch: number, recreate: boolean, onProgress: (rows: RunRow[], step: string) => void): Promise<RunRow[]> {
  const rows = new Map<string, RunRow>(ids.map(id => [id, { invoice_id: id, ok: false, pdf: '' }]));
  const push = (step: string) => onProgress(ids.map(id => rows.get(id)!), step);
  const lots = Math.ceil(ids.length / batch);
  for (let i = 0; i < ids.length; i += batch) {
    const part = ids.slice(i, i + batch); push(`Đang gửi MISA lô ${i / batch + 1}/${lots} (${part.length} HĐ)…`);
    try {
      const r = await misaCall<{ results: RunRow[] }>('create', { ids: part, recreate });
      r.results.forEach(x => rows.set(x.invoice_id, { ...rows.get(x.invoice_id)!, ...x, pdf: '' }));
    } catch (e: any) { part.forEach(id => rows.set(id, { ...rows.get(id)!, ok: false, error: e.message || String(e) })); }
  }
  const okRows = ids.map(id => rows.get(id)!).filter(x => x.ok && x.hd_id && x.khop !== false);
  let done = 0;
  for (const x of okRows) {
    push(`Đang lấy PDF nháp ${++done}/${okRows.length}…`);
    try { await misaCall('pdf', { hd_id: x.hd_id }); rows.set(x.invoice_id, { ...x, pdf: 'ok' }); }
    catch (e: any) { rows.set(x.invoice_id, { ...x, pdf: 'loi', pdfErr: e.message || String(e) }); }
  }
  push('');
  return ids.map(id => rows.get(id)!);
}

export const MISA_ST: Record<string, [string, string]> = {
  dang_tao: ['Đang tạo…', 'amber'], da_tao: ['Nháp MISA', 'blue'], loi: ['Lỗi MISA', 'red'], da_xoa: ['Đã xóa nháp', 'gray'], da_phat_hanh: ['Đã phát hành', 'green'],
};
/** Nhãn ngắn tình trạng MISA của 1 phiếu (từ out_invoices_page: v.misa, v.misa_at) */
export function misaTag(v: any): [string, string] | null {
  const m = v.misa;
  if (!m || m.st === 'da_xoa') return v.misa_at && ['cho_nhap'].includes(v.status) ? ['Làm tay · đã xuất Excel', 'amber'] : null;
  if (m.st === 'da_tao' && m.cu) return [`Nháp API lần ${m.lan} — bản cũ, tạo lại`, 'red'];
  if (m.st === 'da_tao' && m.khop === false) return ['Nháp API lệch tiền ERP', 'red'];
  if (m.st === 'da_tao' && !m.pdf) return [`Nháp API lần ${m.lan} · chưa có PDF`, 'amber'];
  if (m.st === 'da_tao') return [`Nháp API lần ${m.lan} ✓`, 'blue'];
  if (m.st === 'loi') return ['Lỗi MISA — xem chi tiết', 'red'];
  if (m.st === 'da_phat_hanh') return [`MISA đã phát hành ${m.so_hd || ''}`, 'green'];
  return [MISA_ST[m.st]?.[0] || m.st, MISA_ST[m.st]?.[1] || 'gray'];
}

/** Khác nhau giữa nháp trước và dữ liệu sắp gửi (để kế toán soát khi tạo lại) */
export function payloadDiff(prev: any, cur: any): string[] {
  if (!prev || !cur) return [];
  const out: string[] = [];
  const f: [string, string][] = [['AccountObjectName', 'Tên đơn vị'], ['AccountObjectTaxCode', 'MST'], ['AccountObjectAddress', 'Địa chỉ'], ['ReceiverEmail', 'Email'], ['PaymentMethod', 'Thanh toán']];
  f.forEach(([k, l]) => { if ((prev[k] || '') !== (cur[k] || '')) out.push(`${l}: ${prev[k] || '—'} → ${cur[k] || '—'}`); });
  const key = (d: any) => String(d.InventoryItemCode || d.Description);
  const pm = new Map<string, any>((prev.InvoiceDetails || []).map((d: any) => [key(d), d])); const cm = new Map<string, any>((cur.InvoiceDetails || []).map((d: any) => [key(d), d]));
  const vn = (x: any) => Number(x).toLocaleString('vi-VN');
  cm.forEach((d, k) => { const p = pm.get(k); if (!p) { out.push(`Thêm dòng ${k}`); return; }
    if (Number(p.Quantity) !== Number(d.Quantity)) out.push(`${k}: SL ${vn(p.Quantity)} → ${vn(d.Quantity)}`);
    if (Number(p.UnitPrice) !== Number(d.UnitPrice)) out.push(`${k}: đơn giá ${vn(p.UnitPrice)} → ${vn(d.UnitPrice)}`);
    if (Number(p.VATRate) !== Number(d.VATRate)) out.push(`${k}: thuế ${p.VATRate}% → ${d.VATRate}%`); });
  pm.forEach((_d, k) => { if (!cm.has(k)) out.push(`Bỏ dòng ${k}`); });
  if (Number(prev.TotalAmountOC) !== Number(cur.TotalAmountOC)) out.push(`Tổng thanh toán ${vn(prev.TotalAmountOC)} → ${vn(cur.TotalAmountOC)}`);
  return out;
}

/** Excel đối chiếu ERP ↔ MISA: mọi lần tạo nháp bằng API */
export async function exportMisaDoiChieu(personName: (id: string) => string): Promise<number> {
  const rows = await fetchAll<any>(() => db.from('out_misa').select('lan,ref_id,trang_thai,tien_hang,tien_thue,tong_tt,misa_tong_tt,khop,so_hd,ma_tra_cuu,loi_text,created_at,created_by,deleted_at,sale_id,file_id,out_invoices(code,buyer_name,tax_code,status,version)')
    .order('created_at', { asc: false }), 20000);
  if (!rows.length) throw new Error('Chưa có nháp nào tạo bằng API');
  const head = ['Mã phiếu', 'Lần', 'RefID', 'Trạng thái nháp', 'Đơn vị mua', 'MST', 'Sale', 'Tiền hàng ERP', 'Thuế ERP', 'Tổng ERP', 'Tổng MISA', 'Khớp', 'Có PDF', 'Số HĐ', 'Mã tra cứu', 'Lỗi', 'Tạo lúc', 'Người tạo', 'Xóa lúc'];
  const out: any[][] = [head, ...rows.map(r => [r.out_invoices?.code, r.lan, r.ref_id, MISA_ST[r.trang_thai]?.[0] || r.trang_thai, r.out_invoices?.buyer_name, r.out_invoices?.tax_code, personName(r.sale_id),
    Number(r.tien_hang) || 0, Number(r.tien_thue) || 0, Number(r.tong_tt) || 0, r.misa_tong_tt === null ? '' : Number(r.misa_tong_tt), r.khop === null ? '' : r.khop ? 'Khớp' : 'LỆCH', r.file_id ? 'Có' : '',
    r.so_hd || '', r.ma_tra_cuu || '', r.loi_text || '', r.created_at ? new Date(r.created_at).toLocaleString('vi-VN') : '', personName(r.created_by), r.deleted_at ? new Date(r.deleted_at).toLocaleString('vi-VN') : ''])];
  await writeXlsx('Doi_chieu_MISA_' + today(), out, 'ERP-MISA', true, { fmt: { 7: 'int', 8: 'int', 9: 'int', 10: 'int' } });
  return rows.length;
}
