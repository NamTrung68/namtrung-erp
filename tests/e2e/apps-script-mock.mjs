// Giả lập Apps Script bản 20 (doGet / doPost với vé) để kiểm thử: đổi vé qua Supabase giả lập, file lưu trong bộ nhớ
import http from 'node:http';
const SB = process.env.SB || 'http://localhost:54321'; const ANON = process.env.ANON; const TOKEN = process.env.BACKUP_TOKEN;
const files = new Map(); let seq = 0;
const send = (res, o) => { res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }); res.end(JSON.stringify(o)); };
const rpc = async (fn, body) => { const r = await fetch(`${SB}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: 'Bearer ' + ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_token: TOKEN, ...body }) });
  const t = await r.text(); if (r.status !== 200) throw new Error(fn + ': ' + (JSON.parse(t).message || t)); return JSON.parse(t); };
http.createServer(async (req, res) => {
  if (req.method === 'GET') return send(res, { ok: true, app: 'NT-ERP Drive', version: 20 });
  const c = []; for await (const x of req) c.push(x);
  try {
    const b = JSON.parse(Buffer.concat(c).toString()); if (!b.ticket) return send(res, { ok: false, error: 'Thiếu vé' });
    const t = await rpc('drive_redeem', { p_ticket: b.ticket });
    if (b.action === 'get' && t.kind === 'view') { const f = files.get(t.drive_id); await new Promise(r => setTimeout(r, Number(process.env.DELAY || 0))); return send(res, { ok: true, mime: f.mime, data: f.data }); }
    if (b.action === 'upload' && t.kind === 'upload') { const id = 'mock-' + (++seq); files.set(id, { mime: b.mime, data: b.data, folder: t.folder, name: b.name }); console.log('UP', t.folder, b.name); return send(res, { ok: true, id, url: 'https://drive.google.com/file/d/' + id }); }
    return send(res, { ok: false, error: 'Vé không đúng loại' });
  } catch (e) { send(res, { ok: false, error: String(e.message || e) }); }
}).listen(8091, () => console.log('apps-script mock :8091'));
