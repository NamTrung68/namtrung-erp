// Giả lập Supabase cục bộ để kiểm thử: Auth (giả) + PostgREST thật + Storage (bộ nhớ)
import http from 'node:http';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
const SECRET = 'super-secret-jwt-token-with-at-least-32-characters-long';
const PG = ['-h', '/var/tmp/pg', '-p', '5433', '-U', 'postgres', '-d', process.env.DB || 'nt_e2e', '-At', '-v', 'ON_ERROR_STOP=1', '-c'];
const psql = sql => execFileSync('psql', [...PG, sql], { encoding: 'utf8' }).trim();
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = (sub, email) => { const h = b64({ alg: 'HS256', typ: 'JWT' }), p = b64({ sub, email, role: 'authenticated', aud: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 });
  return `${h}.${p}.${crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url')}`; };
const pw = new Map(); const files = new Map();
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': '*', 'Access-Control-Expose-Headers': 'content-range' };
const send = (res, code, body, h = {}) => { res.writeHead(code, { 'Content-Type': 'application/json', ...cors, ...h }); res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body)); };
const session = (id, email) => ({ access_token: jwt(id, email), refresh_token: 'r-' + id + '-' + email, expires_in: 3600, expires_at: Math.floor(Date.now() / 1000) + 3600, user: { id, email } });
http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') return send(res, 204, '');
  const chunks = []; for await (const c of req) chunks.push(c); const raw = Buffer.concat(chunks);
  const u = new URL(req.url, 'http://x');
  try {
    if (u.pathname.startsWith('/auth/v1/')) {
      const body = raw.length ? JSON.parse(raw) : {};
      if (u.pathname === '/auth/v1/token') {
        if (u.searchParams.get('grant_type') === 'refresh_token') { const [, id, email] = body.refresh_token.match(/^r-([0-9a-f-]{36})-(.*)$/); return send(res, 200, session(id, email)); }
        const id = psql(`select id from auth.users where email = '${body.email.replace(/'/g, "''")}'`);
        if (!id || (pw.get(body.email) || 'Test1234!') !== body.password) return send(res, 400, { error_description: 'Invalid login credentials' });
        return send(res, 200, session(id, body.email));
      }
      if (u.pathname === '/auth/v1/signup') {
        try { const id = psql(`insert into auth.users(email) values ('${body.email.replace(/'/g, "''")}') returning id`).split('\n')[0]; pw.set(body.email, body.password); return send(res, 200, session(id, body.email)); }
        catch (e) { return send(res, /duplicate/.test(e.stderr) ? 422 : 500, { msg: /duplicate/.test(e.stderr) ? 'User already registered' : 'Database error saving new user' }); }
      }
      return send(res, 200, {});
    }
    if (u.pathname.startsWith('/storage/v1/')) {
      const p = u.pathname.replace('/storage/v1/object/', '');
      if (req.method === 'POST' && p.startsWith('sign/')) return send(res, 200, { signedURL: '/object/public-signed/' + p.slice(5) + '?token=t' });
      if (req.method === 'POST') { files.set(decodeURIComponent(p), { type: req.headers['content-type'], data: raw }); return send(res, 200, { Key: p }); }
      if (req.method === 'GET') { const k = decodeURIComponent(p.replace(/^(public-signed|authenticated)\//, '')); const f = files.get(k); return f ? send(res, 200, f.data, { 'Content-Type': f.type }) : send(res, 404, { message: 'not found' }); }
      if (req.method === 'DELETE') { JSON.parse(raw).prefixes.forEach(x => files.delete(decodeURIComponent(p) + '/' + x)); return send(res, 200, []); }
    }
    if (u.pathname.startsWith('/rest/v1/')) {
      const headers = { ...req.headers, 'x-forwarded-for': '203.0.113.7' }; delete headers.host;
      const r = await fetch('http://127.0.0.1:3010' + req.url.replace('/rest/v1', ''), { method: req.method, headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : raw });
      const h = { 'Content-Type': r.headers.get('content-type') || 'application/json' }; if (r.headers.get('content-range')) h['content-range'] = r.headers.get('content-range');
      return send(res, r.status, Buffer.from(await r.arrayBuffer()), h);
    }
    send(res, 404, { message: 'not found' });
  } catch (e) { send(res, 500, { message: String(e) }); }
}).listen(54321, () => console.log('gateway :54321'));
