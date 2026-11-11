// Hàm máy chủ "hdky" (Supabase Edge Function) — bản 38: tải PDF HĐ ĐÃ KÝ từ trang tra cứu công khai của MISA meInvoice
// theo mã tra cứu → lưu Google Drive (thư mục HD da ky/<tháng>/<sale>, cơ chế vé như ERP) → gắn vào phiếu (file "ky").
//
// Không dùng tài khoản / API MISA: chỉ gọi link tra cứu công khai (ai có mã tra cứu đều tải được), đúng link kế toán vẫn bấm tay.
// Triển khai: Dashboard → Edge Functions → Deploy new function → tên "hdky", dán file này; TẮT "Verify JWT"
// (hàm tự kiểm phiên đăng nhập ERP + quyền với phiếu; lịch / trigger CSDL dùng khóa riêng x-cron-key do CSDL tự tạo).
//
// Việc hàm làm (body JSON {action, ...}):
//   get    — {invoice_id}: người dùng ERP có quyền với phiếu. Đã có PDF → trả file_id; chưa có → tải + lưu → trả file_id + data (base64)
//   sweep  — {ids?}: CSDL gọi (x-cron-key): tải các HĐ đã ký còn thiếu PDF (tối đa 6 HĐ / lần — mỗi HĐ ~10 giây)
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';

const env = (k: string) => Deno.env.get(k) || '';
const SUPA_URL = env('SUPABASE_URL');
const firstKey = (j: string) => { try { const o = JSON.parse(j || '{}'); return (o.default || Object.values(o)[0] || '') as string; } catch { return ''; } };
const adminKey = env('SUPABASE_SERVICE_ROLE_KEY') || firstKey(env('SUPABASE_SECRET_KEYS'));
const anonKey = env('SUPABASE_ANON_KEY') || firstKey(env('SUPABASE_PUBLISHABLE_KEYS'));
const admin = createClient(SUPA_URL, adminKey, { auth: { persistSession: false } });
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-cron-key', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const errText = (e: unknown) => (e instanceof Error ? e.message : String(e));
const fileSafe = (s: string) => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D').replace(/[^A-Za-z0-9 _-]+/g, '').trim().replace(/\s+/g, ' ').slice(0, 60);
const vnMonth = () => new Date(Date.now() + 7 * 3600e3).toISOString().slice(0, 7);
const MAX = 12 * 1024 * 1024;

function b64(u8: Uint8Array): string {
  let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000));
  return btoa(s);
}

/** Link tải: chỉ cho https://*.meinvoice.vn (cấu hình sai / bị sửa cũng không gọi ra chỗ khác). Trả 2 biến thể: tải thẳng + xem (Viewer=1) */
function dlUrls(tpl: string, ma: string): string[] {
  const u = new URL(tpl.replace('{code}', encodeURIComponent(ma)));
  if (u.protocol !== 'https:' || !/(^|\.)meinvoice\.vn$/i.test(u.hostname)) throw new Error('Link tra cứu phải là https://…meinvoice.vn');
  const a = new URL(u); a.searchParams.delete('Viewer');
  const b = new URL(u); b.searchParams.set('Viewer', '1');
  const test = env('HDKY_TEST_BASE'); // chỉ môi trường kiểm thử cục bộ (biến máy chủ), production không đặt
  return [a, b].map(x => (test ? test.replace(/\/+$/, '') + x.pathname + x.search : x.toString()));
}
const isPdf = (u8: Uint8Array) => u8[0] === 0x25 && u8[1] === 0x50 && u8[2] === 0x44 && u8[3] === 0x46;
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

async function fetchPdf(urls: string[]): Promise<Uint8Array> {
  const why: string[] = [];
  for (const url of urls) {
    let r: Response;
    try { r = await fetch(url, { redirect: 'follow', headers: { 'User-Agent': UA, Accept: 'application/pdf,text/html,*/*', Referer: 'https://www.meinvoice.vn/tra-cuu/', 'Accept-Language': 'vi-VN,vi;q=0.9' }, signal: AbortSignal.timeout(30_000) }); }
    catch (e) { why.push('không kết nối: ' + errText(e)); continue; }
    const u8 = new Uint8Array(await r.arrayBuffer());
    if (u8.length > MAX) throw new Error('File HĐ quá lớn');
    if (r.ok && isPdf(u8)) return u8;
    // một số bản trả PDF dạng base64 (JSON / text)
    const txt = new TextDecoder().decode(u8.subarray(0, 200_000));
    const m = txt.match(/JVBERi0[A-Za-z0-9+/=\\]{100,}/);
    if (r.ok && m) { try { const bin = atob(m[0].replace(/\\/g, '')); const out = Uint8Array.from(bin, c => c.charCodeAt(0)); if (isPdf(out)) return out; } catch { /* */ } }
    const snip = txt.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 140);
    why.push(`${r.status} ${r.headers.get('content-type') || '?'} ${u8.length}B${r.url !== url ? ' → ' + new URL(r.url).pathname : ''}: ${snip}`);
  }
  throw new Error('meInvoice không trả file PDF — kiểm tra mã tra cứu (bấm link mã tra cứu để xem). Chi tiết: ' + why.join(' | ').slice(0, 380));
}

/** Tải + lưu Drive + gắn phiếu. info = out_ky_info_sys */
async function fetchStore(info: any): Promise<{ file_id: string; data: string }> {
  if (info.status !== 'da_ky') throw new Error('HĐ chưa ký');
  if (!info.ma_tra_cuu) throw new Error('HĐ chưa có mã tra cứu — kế toán điền mã tra cứu trước');
  const { data: drv } = await admin.from('settings').select('value').eq('key', 'drive').maybeSingle();
  const driveUrl = drv?.value?.url; if (!driveUrl) throw new Error('Chưa cấu hình lưu Google Drive (Cấu hình → Sao lưu Google Drive)');
  try {
    const u8 = await fetchPdf(dlUrls(String(info.url_tpl), String(info.ma_tra_cuu)));
    const data = b64(u8);
    const so = String(info.so_hd || '').replace(/\D/g, '').replace(/^0+(?=\d)/, '') || info.code;
    const name = ['KY', so, String(info.tax_code || '').replace(/\D/g, '') || 'MST', Math.round(Number(info.tong) || 0), fileSafe(String(info.buyer_name || ''))]
      .map(x => fileSafe(String(x)).replace(/ /g, '_')).filter(Boolean).join('_') + '.pdf';
    const folder = `HD da ky/${String(info.ngay_hd || '').slice(0, 7) || vnMonth()}/${fileSafe(String(info.sale_name || 'Khong ro sale'))}`;
    const { data: tk, error: te } = await admin.rpc('out_ky_upload_ticket', { p_folder: folder }); if (te) throw new Error(te.message);
    const r = await fetch(driveUrl, { method: 'POST', body: JSON.stringify({ action: 'upload', ticket: tk, name, mime: 'application/pdf', data }), redirect: 'follow' });
    let j: any = null; try { j = await r.json(); } catch { /* */ }
    if (!j?.ok || !j.id) throw new Error('Drive: ' + (j?.error || 'không lưu được file'));
    const { data: fid, error: ae } = await admin.rpc('out_ky_attach', { p_id: info.id, p_drive_id: j.id, p_name: name, p_size_kb: Math.round(u8.length / 1024) });
    if (ae) throw new Error(ae.message);
    return { file_id: String(fid), data };
  } catch (e) {
    await admin.rpc('out_ky_fail', { p_id: info.id, p_error: errText(e) });
    throw e;
  }
}

async function sweep(ids: string[] | null) {
  let list: string[] = [];
  if (ids && ids.length) list = ids.slice(0, 6);
  else { const { data, error } = await admin.rpc('out_ky_pending', { p_limit: 6 }); if (error) throw new Error(error.message); list = (data || []).map((x: any) => String(typeof x === 'string' ? x : Object.values(x)[0])); }
  const out = { saved: 0, skip: 0, fail: 0, errors: [] as string[] };
  for (const id of list) {
    const { data: info } = await admin.rpc('out_ky_info_sys', { p_id: id });
    if (!info || info.status !== 'da_ky' || !info.ma_tra_cuu || info.file_id) { out.skip++; continue; }
    try { await fetchStore(info); out.saved++; } catch (e) { out.fail++; out.errors.push(`${info.code}: ${errText(e)}`); }
  }
  return out;
}

async function get(db: SupabaseClient, id: string) {
  const { data: info, error } = await db.rpc('out_ky_info', { p_id: id }); if (error) throw new Error(error.message);
  if (info.file_id) return { file_id: info.file_id };
  return { ...(await fetchStore(info)), fresh: true };
}

// ---------- Cửa vào ----------
Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'POST' }, 405);
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const action = String(body.action || '');
  try {
    const cronKey = req.headers.get('x-cron-key');
    if (cronKey) {
      const { data: ok } = await admin.rpc('hdky_cron_ok', { p_key: cronKey });
      if (!ok || action !== 'sweep') return json({ ok: false, error: 'Khóa lịch không hợp lệ' }, 401);
      return json({ ok: true, ...(await sweep(Array.isArray(body.ids) ? body.ids.map(String) : null)) });
    }
    const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: u } = jwt ? await admin.auth.getUser(jwt) : { data: { user: null } } as any;
    if (!u?.user) return json({ ok: false, error: 'Phiên đăng nhập hết hạn — đăng nhập lại' }, 401);
    const db = createClient(SUPA_URL, anonKey, { global: { headers: { Authorization: 'Bearer ' + jwt } }, auth: { persistSession: false } });
    if (action === 'get') return json({ ok: true, ...(await get(db, String(body.invoice_id))) });
    return json({ ok: false, error: 'Việc không hợp lệ: ' + action }, 400);
  } catch (e) {
    return json({ ok: false, error: errText(e) });
  }
});
