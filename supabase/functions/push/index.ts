// Hàm máy chủ "push" (Supabase Edge Function) — bản 28
// Gọi bởi: trigger CSDL khi có thông báo mới  → body {id}
//          app khi bật thông báo lần đầu      → body {init:true} (tạo khóa VAPID nếu chưa có, trả khóa công khai)
// Khóa VAPID tự tạo và lưu trong CSDL (app.push_cfg) qua quyền service_role có sẵn trong môi trường hàm — không cần nhập bí mật nào.
// Mỗi thông báo chỉ đẩy 1 lần (push_claim đánh dấu pushed_at). Thiết bị hết hạn (404/410) tự xóa.
// Triển khai: Dashboard → Edge Functions → Deploy new function → tên "push", dán file này; tắt "Verify JWT".
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

let keys: { public_key: string; private_key: string } | null = null;
async function getKeys() {
  if (keys) return keys;
  const { data } = await sb.rpc('push_cfg_get');
  if (data?.public_key) return (keys = data);
  const k = webpush.generateVAPIDKeys();
  const { data: d2, error } = await sb.rpc('push_cfg_init', { p_public: k.publicKey, p_private: k.privateKey });
  if (error) throw error;
  return (keys = d2);
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const k = await getKeys();
    if (body.init) return json({ public_key: k.public_key });
    const id = Number(body.id);
    if (!Number.isFinite(id) || id <= 0) return json({ ok: false, error: 'id' }, 400);
    const { data: n, error } = await sb.rpc('push_claim', { p_id: id });
    if (error) throw error;
    if (!n) return json({ ok: true, skip: true });
    webpush.setVapidDetails('https://namtrung68.github.io/namtrung-erp/', k.public_key, k.private_key);
    const payload = JSON.stringify({ title: n.title, body: n.body, link: n.link, tag: n.tag, unread: n.unread });
    const res = await Promise.all((n.subs || []).map(async (s: any) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: 'high' });
        await sb.rpc('push_result', { p_endpoint: s.endpoint, p_ok: true, p_gone: false });
        return 1;
      } catch (e: any) {
        const gone = e?.statusCode === 404 || e?.statusCode === 410;
        await sb.rpc('push_result', { p_endpoint: s.endpoint, p_ok: false, p_gone: gone });
        return 0;
      }
    }));
    return json({ ok: true, sent: res.reduce((a, b) => a + b, 0), total: res.length });
  } catch (e: any) {
    return json({ ok: false, error: String(e?.message || e) }, 500);
  }
});
