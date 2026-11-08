// Hàm máy chủ "mst" (Supabase Edge Function) — bản 35: tra cứu thông tin xuất HĐ theo MST
//
// Trình duyệt chỉ gọi 1 cửa này và luôn nhận 1 dạng kết quả chung (MstResult) — đổi nhà cung cấp KHÔNG phải sửa giao diện.
// Thứ tự thử: MST_PROVIDER (VD "misa,vietqr"); mặc định: misa (nếu có bí mật) → xinvoice (nếu có bí mật) → vietqr (miễn phí, không cần khóa).
//
// Bí mật tùy chọn (Supabase → Edge Functions → Secrets):
//   VietQR   : không cần. Lưu ý VietQR báo ngừng API tra MST từ 01/03/2027.
//   Xinvoice : bản miễn phí không cần khóa (10 lần / 30 giây); gói trả phí: XINVOICE_CLIENT_ID, XINVOICE_API_KEY
//   MISA     : MISA_MST_APPID, MISA_MST_USERNAME, MISA_MST_PASSWORD (+ dùng MISA_TAX_CODE sẵn có)
//              MISA_MST_TOKEN_URL / MISA_MST_LOOKUP_URL nếu MISA cung cấp địa chỉ khác mặc định
// Triển khai: Dashboard → Edge Functions → Deploy new function → tên "mst", dán file này; TẮT "Verify JWT" (hàm tự kiểm phiên đăng nhập).
// Kết quả được nhớ 7 ngày trong bảng mst_cache để không gọi lặp.
import { createClient } from 'npm:@supabase/supabase-js@2';

const env = (k: string) => Deno.env.get(k) || '';
const firstKey = (j: string) => { try { const o = JSON.parse(j || '{}'); return (o.default || Object.values(o)[0] || '') as string; } catch { return ''; } };
const admin = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY') || firstKey(env('SUPABASE_SECRET_KEYS')), { auth: { persistSession: false } });
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

export interface MstResult { found: boolean; mst: string; name: string; address: string; status: string; active: boolean | null; provider: string; warnings: string[]; at: string; cached?: boolean }
type Provider = 'misa' | 'xinvoice' | 'vietqr';
const has = (p: Provider) => p === 'vietqr' || p === 'xinvoice' || ( !!(env('MISA_MST_APPID') && env('MISA_MST_USERNAME') && env('MISA_MST_PASSWORD') && env('MISA_TAX_CODE')));
const order = (): Provider[] => { const want = (env('MST_PROVIDER') || 'misa,xinvoice,vietqr').split(',').map(s => s.trim().toLowerCase()) as Provider[]; return want.filter(p => ['misa', 'xinvoice', 'vietqr'].includes(p) && has(p)); };

function pick(o: any, ...names: string[]): any {
  if (!o || typeof o !== 'object') return undefined;
  const keys = Object.keys(o);
  for (const n of names) { const k = keys.find(x => x.toLowerCase() === n.toLowerCase()); if (k !== undefined && o[k] !== null && o[k] !== '') return o[k]; }
  return undefined;
}
const activeOf = (st: string): boolean | null => (!st ? null : /^NNT đang hoạt động(\s*\(đã được cấp GCN ĐKT\))?$/i.test(st.trim()) ? true : /ngừng|chấm dứt|đóng MST|không hoạt động/i.test(st) ? false : null);
const done = (r: Omit<MstResult, 'warnings' | 'at' | 'active'> & { active?: boolean | null }): MstResult => {
  const active = r.active ?? activeOf(r.status); const w: string[] = [];
  if (!r.found) w.push('Không tìm thấy MST trên dữ liệu thuế — kiểm tra lại số');
  else if (active === false) w.push('Tình trạng MST: ' + r.status + ' — KHÔNG xuất HĐ khi chưa xác minh với khách');
  else if (r.status && active === null) w.push('Tình trạng MST: ' + r.status);
  return { ...r, active, warnings: w, at: new Date().toISOString() };
};
class NotFound extends Error {}

async function getJson(url: string, init: RequestInit = {}): Promise<{ status: number; j: any }> {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(15_000) });
  const t = await res.text(); let j: any = null; try { j = JSON.parse(t); } catch { /* */ }
  if (res.status === 429) throw new Error('Nhà cung cấp tra cứu đang giới hạn số lần gọi — thử lại sau 1 phút');
  return { status: res.status, j };
}

async function viaVietqr(mst: string): Promise<MstResult> {
  const { status, j } = await getJson('https://api.vietqr.io/v2/business/' + encodeURIComponent(mst), { headers: { Accept: 'application/json' } });
  if (!j) throw new Error('VietQR trả HTTP ' + status);
  if (j.code === '00' && j.data) return done({ found: true, mst: j.data.id || mst, name: j.data.name || '', address: j.data.address || '', status: '', provider: 'vietqr' });
  if (j.code === '51' || j.code === '52') return done({ found: false, mst, name: '', address: '', status: j.desc || '', provider: 'vietqr' });
  throw new Error('VietQR: ' + (j.desc || 'lỗi ' + status));
}

async function viaXinvoice(mst: string): Promise<MstResult> {
  const { status, j } = await getJson('https://api.xinvoice.vn/gdt-api/tax-payer/' + encodeURIComponent(mst),
    { headers: { Accept: 'application/json', ...(env('XINVOICE_CLIENT_ID') ? { 'client-id': env('XINVOICE_CLIENT_ID'), 'api-key': env('XINVOICE_API_KEY') } : {}) } });
  if (status === 404) return done({ found: false, mst, name: '', address: '', status: '', provider: 'xinvoice' });
  const d = j?.data ?? j;
  if (!d || !pick(d, 'name', 'taxID')) throw new Error('Xinvoice trả HTTP ' + status);
  return done({ found: true, mst: pick(d, 'taxID') || mst, name: pick(d, 'name') || '', address: pick(d, 'address') || '', status: pick(d, 'status') || '', provider: 'xinvoice' });
}

// MISA meInvoice — theo mô tả: POST .../auth/token {appid, taxcode, username, password} → token; GET .../company?taxcode=<MST> (Bearer)
// Chưa có tài liệu chính thức nên đọc trường linh hoạt; khi MISA trả lời chỉ cần chỉnh 2 địa chỉ / tên trường ở đây.
let misaTok: { t: string; at: number } | null = null;
async function viaMisa(mst: string): Promise<MstResult> {
  const tokUrl = env('MISA_MST_TOKEN_URL') || 'https://api.meinvoice.vn/api/integration/auth/token';
  const lookUrl = env('MISA_MST_LOOKUP_URL') || 'https://api.meinvoice.vn/api/integration/company?taxcode={mst}';
  if (!misaTok || Date.now() - misaTok.at > 6 * 3600_000) {
    const { j } = await getJson(tokUrl, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ appid: env('MISA_MST_APPID'), taxcode: env('MISA_TAX_CODE'), username: env('MISA_MST_USERNAME'), password: env('MISA_MST_PASSWORD') }) });
    const t = typeof pick(j, 'Data', 'data') === 'string' ? pick(j, 'Data', 'data') : pick(pick(j, 'Data', 'data') || {}, 'token', 'access_token');
    if (!pick(j, 'Success', 'success') || !t) throw new Error('MISA không cấp token tra MST: ' + (pick(j, 'ErrorCode', 'Errors', 'message') || 'không rõ lỗi'));
    misaTok = { t, at: Date.now() };
  }
  const { status, j } = await getJson(lookUrl.replace('{mst}', encodeURIComponent(mst)), { headers: { Accept: 'application/json', Authorization: 'Bearer ' + misaTok.t } });
  if (status === 401) { misaTok = null; throw new Error('MISA: token hết hạn — thử lại'); }
  let d = pick(j, 'Data', 'data'); if (typeof d === 'string') { try { d = JSON.parse(d); } catch { /* */ } }
  if (Array.isArray(d)) d = d[0];
  if (!pick(j, 'Success', 'success') || !d) {
    const code = String(pick(j, 'ErrorCode', 'errorCode') || '');
    if (/notfound|not_found|invalid|khong/i.test(code)) return done({ found: false, mst, name: '', address: '', status: code, provider: 'misa' });
    throw new Error('MISA: ' + (code || 'không có dữ liệu'));
  }
  const st = String(pick(d, 'StatusName', 'Status', 'TaxStatus', 'status') ?? '');
  return done({ found: true, mst: pick(d, 'TaxCode', 'taxcode', 'MST') || mst, name: pick(d, 'CompanyName', 'Name', 'companyName', 'name') || '',
    address: pick(d, 'Address', 'CompanyAddress', 'address') || '', status: st, provider: 'misa' });
}

const RUN: Record<Provider, (m: string) => Promise<MstResult>> = { misa: viaMisa, xinvoice: viaXinvoice, vietqr: viaVietqr };

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST' }, 405);
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: u } = jwt ? await admin.auth.getUser(jwt) : { data: { user: null } } as any;
  if (!u?.user) return json({ ok: false, error: 'Phiên đăng nhập hết hạn — đăng nhập lại' }, 401);
  const { data: prof } = await admin.from('profiles').select('status').eq('id', u.user.id).maybeSingle();
  if (prof?.status !== 'active') return json({ ok: false, error: 'Tài khoản không hoạt động' }, 403);
  if (body.action === 'status') return json({ ok: true, providers: order() });
  const mst = String(body.mst || '').replace(/\s/g, '');
  if (!/^(\d{10}|\d{10}-\d{3}|\d{12})$/.test(mst)) return json({ ok: false, error: 'MST phải là 10 số, 10-3 số hoặc CCCD 12 số' }, 400);
  if (!body.fresh) {
    const { data: c } = await admin.from('mst_cache').select('data,at').eq('mst', mst).maybeSingle();
    if (c && Date.now() - new Date(c.at).getTime() < 7 * 864e5) return json({ ok: true, result: { ...c.data, cached: true } });
  }
  const errs: string[] = [];
  for (const p of order()) {
    try {
      const r = await RUN[p](mst);
      if (r.found) await admin.from('mst_cache').upsert({ mst, provider: p, data: r, at: new Date().toISOString() });
      return json({ ok: true, result: r });
    } catch (e) { errs.push(p + ': ' + (e instanceof Error ? e.message : String(e))); }
  }
  return json({ ok: false, error: 'Không tra được MST lúc này — ' + errs.join(' · ') }, 502);
});
