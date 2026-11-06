// Hàm máy chủ "misa" (Supabase Edge Function) — bản 31: tạo HĐ NHÁP trên MISA meInvoice (nhóm /invoiceweb của MISA)
//
// CHỈ dùng 7 đường dẫn trong ALLOWED_PATHS bên dưới (token, templates, insert, preview, viewrefid, getlist, delete).
// Không bao giờ gọi nhóm phát hành / ký số của MISA — test tests/misa-guard.test.ts quét toàn repo để chặn.
//
// Bí mật (Supabase → Edge Functions → Secrets), không nằm trong code / GitHub / trình duyệt:
//   MISA_CLIENT_ID, MISA_CLIENT_SECRET, MISA_TAX_CODE, MISA_USERNAME, MISA_PASSWORD
//   (tùy chọn) MISA_BASE_URL — mặc định https://developer.misa.vn/apis/itg/meinvoice
// Triển khai: Dashboard → Edge Functions → Deploy new function → tên "misa", dán file này; TẮT "Verify JWT"
// (hàm tự kiểm phiên đăng nhập ERP + quyền Kế toán/Admin; lịch tự dò dùng khóa riêng x-cron-key do CSDL tự tạo).
//
// Việc hàm làm (body JSON {action, ...}):
//   status        — đã nhập đủ bí mật chưa
//   test          — lấy token mới + danh sách mẫu HĐ (không tạo gì)
//   create        — {ids, recreate?}: giữ chỗ (RefID mới) → xem trước từng HĐ → tạo cả lô → đọc lại so tiền
//   pdf           — {hd_id}: lấy bản xem PDF → lưu Google Drive (cơ chế vé như ERP) → gắn vào phiếu, báo sale
//   preview       — {invoice_id}: xem trước 1 phiếu trên MISA (không tạo)
//   delete        — {hd_id}: xóa nháp trên MISA (chỉ xóa được nháp chưa phát hành)
//   sync          — {ids?}: dò MISA: nháp đã phát hành → số HĐ + mã tra cứu → "Đã ký"
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

export const ALLOWED_PATHS = [
  '/invoiceweb/token', '/invoiceweb/templates', '/invoiceweb/insert', '/invoiceweb/preview',
  '/invoiceweb/viewrefid', '/invoiceweb/getlist', '/invoiceweb/delete',
] as const;
type MisaPath = typeof ALLOWED_PATHS[number];

const env = (k: string) => Deno.env.get(k) || '';
const BASE = (env('MISA_BASE_URL') || 'https://developer.misa.vn/apis/itg/meinvoice').replace(/\/+$/, '');
const SUPA_URL = env('SUPABASE_URL');
const firstKey = (j: string) => { try { const o = JSON.parse(j || '{}'); return (o.default || Object.values(o)[0] || '') as string; } catch { return ''; } };
const adminKey = env('SUPABASE_SERVICE_ROLE_KEY') || firstKey(env('SUPABASE_SECRET_KEYS'));
const anonKey = env('SUPABASE_ANON_KEY') || firstKey(env('SUPABASE_PUBLISHABLE_KEYS'));
const admin = createClient(SUPA_URL, adminKey, { auth: { persistSession: false } });
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-cron-key', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const SECRETS = ['MISA_CLIENT_ID', 'MISA_CLIENT_SECRET', 'MISA_TAX_CODE', 'MISA_USERNAME', 'MISA_PASSWORD'];
const configured = () => SECRETS.every(k => !!env(k));

class MisaError extends Error {
  code: string; raw: string;
  constructor(m: string, code = '', raw = '') { super(m); this.code = code; this.raw = raw; }
}
const errText = (e: unknown) => (e instanceof Error ? e.message : String(e));
const errCode = (e: unknown) => (e instanceof MisaError ? e.code : '');

/** Lấy giá trị theo tên trường, không phân biệt hoa thường */
function pick(o: any, ...names: string[]): any {
  if (!o || typeof o !== 'object') return undefined;
  const keys = Object.keys(o);
  for (const n of names) { const k = keys.find(x => x.toLowerCase() === n.toLowerCase()); if (k !== undefined) return o[k]; }
  return undefined;
}
const asJson = (d: any) => { if (typeof d === 'string') { try { return JSON.parse(d); } catch { return d; } } return d; };
const num = (x: any) => (x === null || x === undefined || x === '' ? null : Number(x));

// ---------- Gọi MISA: 1 cửa duy nhất, chặn mọi đường dẫn ngoài danh sách ----------
async function misaRaw(path: MisaPath, opt: { method?: 'GET' | 'POST' | 'DELETE'; query?: Record<string, string>; body?: unknown; token?: string }): Promise<any> {
  if (!(ALLOWED_PATHS as readonly string[]).includes(path)) throw new MisaError('Đường dẫn MISA không được phép: ' + path, 'NotAllowed');
  if (!configured()) throw new MisaError('Chưa nhập đủ bí mật MISA trên Supabase (ClientID, ClientSecret, MST, tài khoản, mật khẩu)', 'NotConfigured');
  const url = new URL(BASE + path);
  Object.entries(opt.query || {}).forEach(([k, v]) => url.searchParams.set(k, v));
  const headers: Record<string, string> = { 'Content-Type': 'application/json', ClientID: env('MISA_CLIENT_ID'), TaxCode: env('MISA_TAX_CODE') };
  if (path === '/invoiceweb/token') headers.ClientSecret = env('MISA_CLIENT_SECRET');
  else headers.Authorization = 'Bearer ' + (opt.token || '');
  let res: Response | null = null;
  // MISA giới hạn 200 request/phút: bị chặn (HTTP 429) thì chờ 5s, 15s rồi thử lại
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      res = await fetch(url, { method: opt.method || 'POST', headers, body: opt.body === undefined ? undefined : JSON.stringify(opt.body), signal: AbortSignal.timeout(45_000) });
    } catch (e) { throw new MisaError('Không kết nối được MISA: ' + errText(e), 'Network'); }
    if (res.status !== 429 || attempt === 2) break;
    await new Promise(r => setTimeout(r, attempt === 0 ? 5_000 : 15_000));
  }
  if (!res) throw new MisaError('Không kết nối được MISA', 'Network');
  if (res.status === 429) throw new MisaError('MISA đang giới hạn số lần gọi (200 lần/phút) — đợi 1 phút rồi bấm Thử lại phiếu lỗi', 'RateLimit');
  const text = await res.text();
  let j: any = null; try { j = JSON.parse(text); } catch { /* không phải JSON */ }
  if (!j || typeof j !== 'object') throw new MisaError(`MISA trả HTTP ${res.status}: ${text.slice(0, 500)}`, 'HTTP' + res.status, text);
  const ok = pick(j, 'success');
  if (!ok) {
    const code = String(pick(j, 'errorCode') ?? '');
    const desc = pick(j, 'descriptionErrorCode', 'errorDescription') ?? '';
    const errs = pick(j, 'errors', 'error') ?? '';
    const msg = [code, desc, Array.isArray(errs) ? errs.join('; ') : typeof errs === 'object' ? JSON.stringify(errs) : errs].filter(Boolean).join(' — ');
    throw new MisaError(msg || `MISA báo lỗi (HTTP ${res.status})`, code || 'HTTP' + res.status, text.slice(0, 4000));
  }
  return pick(j, 'data');
}

// ---------- Token: lưu phía máy chủ, chỉ lấy mới khi chưa có / MISA báo hết hạn ----------
let memToken = ''; let memGot = 0;
const TOKEN_TTL_MS = 13 * 86400_000; // MISA xác nhận: token sống 14 ngày, chưa có hàm refresh → chủ động lấy mới sau 13 ngày
const tokenOf = (d: any): string => {
  d = asJson(d);
  if (typeof d === 'string') return d;
  return String(pick(d, 'token', 'access_token', 'accessToken') || '');
};
async function getToken(force = false): Promise<string> {
  if (!force && memToken && Date.now() - memGot < TOKEN_TTL_MS) return memToken;
  if (!force) {
    const { data } = await admin.rpc('misa_token_get');
    const got = data?.got_at ? Date.parse(data.got_at) : 0;
    if (data?.token && Date.now() - got < TOKEN_TTL_MS) { memGot = got; return (memToken = data.token); }
  }
  const d = await misaRaw('/invoiceweb/token', { body: { TaxCode: env('MISA_TAX_CODE'), UserName: env('MISA_USERNAME'), Password: env('MISA_PASSWORD') } });
  const t = tokenOf(d);
  if (!t) throw new MisaError('MISA không trả token', 'NoToken', JSON.stringify(d).slice(0, 500));
  await admin.rpc('misa_token_put', { p_token: t });
  memGot = Date.now();
  return (memToken = t);
}
const TOKEN_ERR = /TokenExpired|UnAuthorize|InvalidToken|HTTP401/i;
async function misa(path: MisaPath, opt: { method?: 'GET' | 'POST' | 'DELETE'; query?: Record<string, string>; body?: unknown } = {}): Promise<any> {
  const t = await getToken();
  try { return await misaRaw(path, { ...opt, token: t }); }
  catch (e) {
    if (e instanceof MisaError && (TOKEN_ERR.test(e.code) || TOKEN_ERR.test(e.message))) return await misaRaw(path, { ...opt, token: await getToken(true) });
    throw e;
  }
}

async function cfg(): Promise<any> {
  const { data } = await admin.from('settings').select('value').eq('key', 'accounting').maybeSingle();
  return data?.value?.misa || {};
}
const withCodeQ = (c: any) => String(c.with_code !== false);

/** Đọc HĐ trên MISA theo RefID (tối đa 50/lần) → Map RefID → InvoiceData */
async function getlist(refs: string[], c: any): Promise<{ map: Map<string, any>; chunks: { refs: string[]; found: number }[] }> {
  const map = new Map<string, any>(); const chunks: { refs: string[]; found: number }[] = [];
  for (let i = 0; i < refs.length; i += 50) {
    const part = refs.slice(i, i + 50);
    const d = asJson(await misa('/invoiceweb/getlist', { query: { invoiceWithCode: withCodeQ(c) }, body: part }));
    const list: any[] = Array.isArray(d) ? d : Array.isArray(pick(d, 'data', 'items')) ? pick(d, 'data', 'items') : [];
    let n = 0;
    list.forEach(x => { const r = String(pick(x, 'RefID') || '').toLowerCase(); if (r) { map.set(r, x); n++; } });
    chunks.push({ refs: part, found: n });
  }
  return { map, chunks };
}

const stripVN = (s: string) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D');
const fileSafe = (s: string) => stripVN(s).replace(/[^A-Za-z0-9-]+/g, '');
const vnDate = () => new Date(Date.now() + 7 * 3600_000).toISOString().slice(0, 10);

// ---------- Các việc ----------
async function actCreate(db: SupabaseClient, ids: string[], recreate: boolean) {
  if (!Array.isArray(ids) || !ids.length) throw new Error('Chọn ít nhất 1 phiếu');
  if (ids.length > 30) throw new Error('Tối đa 30 HĐ mỗi lô');
  const c = await cfg(); const wc = withCodeQ(c);
  if (String(c.inv_series || '').charAt(4).toUpperCase() === 'M') throw new Error(`Mẫu HĐ đang chọn (${c.inv_series}) là HĐ khởi tạo từ máy tính tiền — vào Cấu hình chọn mẫu HĐ thường (ký hiệu dạng 1C26T…)`);
  const out = new Map<string, any>();
  const fails: any[] = [];
  const del = async (hd: string, ref: string, note: string) => {
    await misa('/invoiceweb/delete', { method: 'DELETE', query: { refid: ref, invoiceWithCode: wc } });
    const { error } = await db.rpc('out_misa_deleted', { p_hd: hd, p_note: note }); if (error) throw new Error(error.message);
  };
  let todo = ids.slice();
  if (recreate) {
    const { data: act } = await db.from('out_misa').select('id,ref_id,invoice_id,trang_thai').in('invoice_id', todo).in('trang_thai', ['dang_tao', 'da_tao']);
    for (const a of act || []) {
      try { await del(a.id, a.ref_id, 'Tạo lại nháp'); }
      catch (e) { out.set(a.invoice_id, { invoice_id: a.invoice_id, ok: false, error: 'Không xóa được nháp cũ trên MISA: ' + errText(e) }); }
    }
    todo = todo.filter(x => !out.has(x));
  }
  const claim = async (list: string[]) => { if (!list.length) return []; const { data, error } = await db.rpc('out_misa_claim', { p_ids: list }); if (error) throw new Error(error.message); return (data || []) as any[]; };
  let claimed = await claim(todo);
  // nháp cũ (sale đã sửa phiếu) → xóa trên MISA rồi giữ chỗ lại
  const again: string[] = [];
  for (const x of claimed.filter(x => x.need_delete)) {
    try { await del(x.need_delete.hd_id, x.need_delete.ref_id, 'Nháp cũ — sale đã sửa phiếu'); again.push(x.invoice_id); }
    catch (e) { out.set(x.invoice_id, { invoice_id: x.invoice_id, code: x.code, ok: false, error: 'Không xóa được nháp cũ trên MISA: ' + errText(e) }); }
  }
  claimed = claimed.filter(x => !x.need_delete).concat(await claim(again));
  claimed.filter(x => x.errors).forEach(x => out.set(x.invoice_id, { invoice_id: x.invoice_id, code: x.code, ok: false, error: (x.errors as string[]).join(' · ') }));
  const ready = claimed.filter(x => x.hd_id);
  // 1) MISA xem trước từng HĐ (không tạo gì) — lỗi thì HĐ đó không gửi
  const toInsert: any[] = [];
  for (const x of ready) {
    try { await misa('/invoiceweb/preview', { body: x.payload }); toInsert.push(x); }
    catch (e) { fails.push({ hd_id: x.hd_id, ok: false, loi_ma: errCode(e), loi_text: 'Xem trước MISA: ' + errText(e) }); out.set(x.invoice_id, { invoice_id: x.invoice_id, code: x.code, ok: false, error: errText(e) }); }
  }
  // 2) Tạo cả lô
  let inserted: any[] = [];
  if (toInsert.length) {
    try {
      const ins = asJson(await misa('/invoiceweb/insert', { body: toInsert.map(x => x.payload) }));
      // MISA xác nhận: 1 HĐ lỗi thì chỉ HĐ đó bị từ chối → hỏi lại MISA HĐ nào thật sự đã vào
      let got: Map<string, any> | null = null; try { got = (await getlist(toInsert.map(x => x.ref_id), c)).map; } catch { /* đọc lại lỗi: coi như đã vào hết, đối soát sau */ }
      const insList: any[] = Array.isArray(ins) ? ins.map(asJson) : [];
      const errOf = (ref: string) => { const r = insList.find(o => o && typeof o === 'object' && String(pick(o, 'RefID') || '').toLowerCase() === ref.toLowerCase());
        const m = r ? [pick(r, 'ErrorCode', 'errorCode'), pick(r, 'DescriptionErrorCode', 'descriptionErrorCode', 'Description', 'Error', 'error', 'Errors')].filter(Boolean).map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' — ') : '';
        return m || 'MISA không tạo HĐ này. Phản hồi MISA: ' + JSON.stringify(ins).slice(0, 600); };
      inserted = got ? toInsert.filter(x => got!.has(String(x.ref_id).toLowerCase())) : toInsert;
      toInsert.filter(x => !inserted.includes(x)).forEach(x => { const m = errOf(String(x.ref_id));
        fails.push({ hd_id: x.hd_id, ok: false, loi_ma: 'InsertRejected', loi_text: m }); out.set(x.invoice_id, { invoice_id: x.invoice_id, code: x.code, ok: false, error: m }); });
    }
    catch (e) {
      // lỗi cả lô: hỏi lại MISA từng RefID xem HĐ nào đã vào
      let got = new Map<string, any>(); try { got = (await getlist(toInsert.map(x => x.ref_id), c)).map; } catch { /* bỏ qua */ }
      inserted = toInsert.filter(x => got.has(String(x.ref_id).toLowerCase()));
      toInsert.filter(x => !got.has(String(x.ref_id).toLowerCase())).forEach(x => {
        fails.push({ hd_id: x.hd_id, ok: false, loi_ma: errCode(e), loi_text: errText(e) });
        out.set(x.invoice_id, { invoice_id: x.invoice_id, code: x.code, ok: false, error: errText(e) });
      });
    }
  }
  // 3) Đọc lại trên MISA, so tiền với ERP
  let back = new Map<string, any>(); let readErr = '';
  if (inserted.length) { try { back = (await getlist(inserted.map(x => x.ref_id), c)).map; } catch (e) { readErr = errText(e); } }
  const rows = inserted.map(x => { const f = back.get(String(x.ref_id).toLowerCase());
    return { hd_id: x.hd_id, ok: true, misa_tong_tt: num(pick(f, 'TotalAmount', 'TotalAmountOC')), misa_tien_thue: num(pick(f, 'TotalVATAmount', 'TotalVATAmountOC')) }; });
  const all = rows.concat(fails);
  if (all.length) { const { error } = await db.rpc('out_misa_result', { p_rows: all }); if (error) throw new Error('Đã gửi MISA nhưng ERP ghi kết quả lỗi: ' + error.message); }
  inserted.forEach((x, i) => { const r = rows[i]; const tong = Number(x.payload?.TotalAmountOC);
    const khop = r.misa_tong_tt === null ? null : Math.abs(r.misa_tong_tt - tong) < 0.5;
    out.set(x.invoice_id, { invoice_id: x.invoice_id, code: x.code, ok: true, hd_id: x.hd_id, ref_id: x.ref_id, lan: x.lan, khop, warn: readErr ? 'Chưa đọc lại được từ MISA: ' + readErr : '' }); });
  return { results: ids.map(id => out.get(id) || { invoice_id: id, ok: false, error: 'Không xử lý' }) };
}

async function actPdf(db: SupabaseClient, hd: string) {
  const c = await cfg();
  const { data: h, error } = await db.from('out_misa').select('id,ref_id,invoice_id,trang_thai,tong_tt,sale_id,created_at').eq('id', hd).maybeSingle();
  if (error || !h) throw new Error('Không thấy nháp MISA');
  if (h.trang_thai !== 'da_tao') throw new Error('Nháp không còn ở trạng thái "đã tạo"');
  const d = asJson(await misa('/invoiceweb/viewrefid', { method: 'GET', query: { RefID: h.ref_id, invoiceWithCode: withCodeQ(c) } }));
  let b64 = typeof d === 'string' ? d : String(pick(d, 'data', 'fileData', 'content') || '');
  b64 = b64.replace(/^data:[^,]*,/, '').replace(/\s+/g, '');
  if (!b64.startsWith('JVBER')) throw new MisaError(`MISA trả bản xem không phải PDF (bắt đầu "${b64.slice(0, 12)}") — kế toán tải PDF nháp từ MISA lên như cách làm tay`, 'NotPdf');
  const { data: v } = await db.from('out_invoices').select('code,tax_code,customer_id').eq('id', h.invoice_id).maybeSingle();
  // mã khách + tên sale chỉ để đặt tên file (đọc bằng quyền máy chủ, không trả ra ngoài)
  const { data: kh } = v?.customer_id ? await admin.from('customers').select('code,sys_code').eq('id', v.customer_id).maybeSingle() : { data: null };
  const { data: sp } = h.sale_id ? await admin.from('profiles').select('full_name').eq('id', h.sale_id).maybeSingle() : { data: null };
  const saleName = sp?.full_name || 'Khong ro sale';
  const name = [v?.code, kh?.sys_code || kh?.code || 'KH', (v?.tax_code || '').replace(/\D/g, '') || 'MST', Math.round(Number(h.tong_tt) || 0), fileSafe(saleName), vnDate().replace(/-/g, '')]
    .map(x => fileSafe(String(x))).join('_') + '.pdf';
  const folder = `HD nhap/${vnDate().slice(0, 7)}/${saleName.trim()}`;
  const { data: drv } = await admin.from('settings').select('value').eq('key', 'drive').maybeSingle();
  const url = drv?.value?.url; if (!url) throw new Error('Chưa cấu hình lưu Google Drive (Cấu hình → Sao lưu Google Drive)');
  const { data: tk, error: te } = await db.rpc('drive_upload_tickets', { p_folders: [folder] }); if (te) throw new Error(te.message);
  const r = await fetch(url, { method: 'POST', body: JSON.stringify({ action: 'upload', ticket: tk[0], name, mime: 'application/pdf', data: b64 }), redirect: 'follow' });
  let j: any = null; try { j = await r.json(); } catch { /* */ }
  if (!j?.ok || !j.id) throw new Error('Drive: ' + (j?.error || 'không lưu được file'));
  const { data: res, error: ae } = await db.rpc('out_misa_file', { p_hd: hd, p_drive_id: j.id, p_name: name, p_size_kb: Math.round(b64.length * 0.75 / 1024) });
  if (ae) throw new Error(ae.message);
  return { file: name, ...(res || {}) };
}

async function actDelete(db: SupabaseClient, hd: string, note?: string) {
  const c = await cfg();
  const { data: h } = await db.from('out_misa').select('id,ref_id,trang_thai').eq('id', hd).maybeSingle();
  if (!h) throw new Error('Không thấy nháp MISA');
  if (h.trang_thai === 'da_phat_hanh') throw new Error('HĐ đã phát hành — không xóa được');
  if (h.trang_thai === 'dang_tao' || h.trang_thai === 'da_tao') await misa('/invoiceweb/delete', { method: 'DELETE', query: { refid: h.ref_id, invoiceWithCode: withCodeQ(c) } });
  const { error } = await db.rpc('out_misa_deleted', { p_hd: hd, p_note: note || null }); if (error) throw new Error(error.message);
  return { deleted: true };
}

async function actPreview(db: SupabaseClient, invoiceId: string) {
  const { data, error } = await db.rpc('out_misa_check', { p_ids: [invoiceId] }); if (error) throw new Error(error.message);
  const ev = (data || [])[0]; if (!ev?.payload) throw new Error('Không dựng được dữ liệu phiếu');
  const d = asJson(await misa('/invoiceweb/preview', { body: { ...ev.payload, RefID: crypto.randomUUID() } }));
  const b64 = (typeof d === 'string' ? d : String(pick(d, 'data', 'fileData', 'content') || '')).replace(/^data:[^,]*,/, '').replace(/\s+/g, '');
  return { pdf: b64.startsWith('JVBER'), data: b64.slice(0, 15_000_000), errors: ev.errors, warnings: ev.warnings };
}

async function actSync(db: SupabaseClient, ids: string[] | null) {
  const c = await cfg();
  const { data: list, error } = await db.rpc('out_misa_sync_list', { p_ids: ids && ids.length ? ids : null, p_limit: 500 }); if (error) throw new Error(error.message);
  const items = (list || []) as any[]; if (!items.length) return { checked: 0 };
  const { map, chunks } = await getlist(items.map(x => String(x.ref_id)), c);
  // an toàn: cả nhóm >3 RefID mà MISA không trả cái nào → nghi MISA trả rỗng bất thường, không đánh dấu "bị xóa"
  const suspicious = new Set<string>(); chunks.filter(k => k.found === 0 && k.refs.length > 3).forEach(k => k.refs.forEach(r => suspicious.add(r.toLowerCase())));
  const rows = items.filter(x => map.has(String(x.ref_id).toLowerCase()) || !suspicious.has(String(x.ref_id).toLowerCase())).map(x => {
    const f = map.get(String(x.ref_id).toLowerCase());
    return { hd_id: x.hd_id, found: !!f, inv_no: f ? String(pick(f, 'InvNo') ?? '') : null, ma_tra_cuu: f ? String(pick(f, 'TransactionID') ?? '') : null,
      misa_tong_tt: f ? num(pick(f, 'TotalAmount', 'TotalAmountOC')) : null, misa_tien_thue: f ? num(pick(f, 'TotalVATAmount', 'TotalVATAmountOC')) : null };
  });
  const { data: sum, error: se } = await db.rpc('out_misa_sync_result', { p_rows: rows }); if (se) throw new Error(se.message);
  return { checked: items.length, skipped: items.length - rows.length, ...(sum || {}) };
}

async function actTest(withCode: boolean) {
  await getToken(true);
  const d = asJson(await misa('/invoiceweb/templates', { query: { invoiceWithCode: String(withCode) },
    body: { TypeInvoice: 0, TaxCode: env('MISA_TAX_CODE'), UserName: env('MISA_USERNAME'), Password: env('MISA_PASSWORD') } }));
  const list: any[] = Array.isArray(d) ? d : [];
  return { templates: list.map(t => ({ id: pick(t, 'IPTemplateID'), name: pick(t, 'TemplateName'), no: pick(t, 'InvTemplateNo'), series: pick(t, 'InvSeries'), inactive: !!pick(t, 'Inactive') })) };
}

// ---------- Cửa vào ----------
Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST' }, 405);
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const action = String(body.action || '');
  try {
    // Lịch tự dò của CSDL (pg_cron) — chỉ được "sync"
    const cronKey = req.headers.get('x-cron-key');
    if (cronKey) {
      const { data: ok } = await admin.rpc('misa_cron_ok', { p_key: cronKey });
      if (!ok || action !== 'sync') return json({ ok: false, error: 'Khóa lịch không hợp lệ' }, 401);
      if (!configured()) return json({ ok: true, skip: 'chưa cấu hình' });
      return json({ ok: true, ...(await actSync(admin, null)) });
    }
    // Người dùng ERP: kiểm phiên + quyền Kế toán / Admin / BGĐ
    const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: u } = jwt ? await admin.auth.getUser(jwt) : { data: { user: null } } as any;
    if (!u?.user) return json({ ok: false, error: 'Phiên đăng nhập hết hạn — đăng nhập lại' }, 401);
    const { data: prof } = await admin.from('profiles').select('roles,status').eq('id', u.user.id).maybeSingle();
    if (prof?.status !== 'active' || !(prof.roles || []).some((r: string) => ['admin', 'bgd', 'ke_toan'].includes(r))) return json({ ok: false, error: 'Chỉ Kế toán / Admin dùng MISA' }, 403);
    const db = createClient(SUPA_URL, anonKey, { global: { headers: { Authorization: 'Bearer ' + jwt } }, auth: { persistSession: false } });
    switch (action) {
      case 'status': return json({ ok: true, configured: configured(), base: BASE, missing: SECRETS.filter(k => !env(k)) });
      case 'test': return json({ ok: true, ...(await actTest(body.with_code !== false)) });
      case 'create': return json({ ok: true, ...(await actCreate(db, body.ids, !!body.recreate)) });
      case 'pdf': return json({ ok: true, ...(await actPdf(db, String(body.hd_id))) });
      case 'preview': return json({ ok: true, ...(await actPreview(db, String(body.invoice_id))) });
      case 'delete': return json({ ok: true, ...(await actDelete(db, String(body.hd_id), body.note)) });
      case 'sync': return json({ ok: true, ...(await actSync(db, Array.isArray(body.ids) ? body.ids : null)) });
      default: return json({ ok: false, error: 'Việc không hợp lệ: ' + action }, 400);
    }
  } catch (e) {
    return json({ ok: false, error: errText(e), code: errCode(e) });
  }
});
