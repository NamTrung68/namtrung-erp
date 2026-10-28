// Client Supabase tối giản (Auth + PostgREST + Storage) bằng fetch — không phụ thuộc thư viện ngoài.
declare global { interface Window { NT_CONFIG?: { supabaseUrl: string; supabaseAnonKey: string; appUrl?: string } } }

const cfg = () => {
  const c = window.NT_CONFIG;
  if (!c?.supabaseUrl || c.supabaseUrl.includes('YOUR_')) throw new Error('Chưa cấu hình Supabase (public/config.js)');
  return c;
};

export interface Session { access_token: string; refresh_token: string; expires_at: number; user: { id: string; email: string } }
const KEY = 'nt_session';
let session: Session | null = null;
const listeners = new Set<(s: Session | null) => void>();
try { session = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch { session = null; }

function setSession(s: Session | null) {
  session = s;
  try { s ? localStorage.setItem(KEY, JSON.stringify(s)) : localStorage.removeItem(KEY); } catch { /* ignore */ }
  listeners.forEach(f => f(s));
}

export class ApiError extends Error { code?: string; status?: number; constructor(m: string, code?: string, status?: number) { super(m); this.code = code; this.status = status; } }

function friendly(msg: string) {
  if (/Invalid login credentials/i.test(msg)) return 'Sai email hoặc mật khẩu';
  if (/Email not confirmed/i.test(msg)) return 'Email chưa xác nhận. Kiểm tra hộp thư.';
  if (/Database error saving new user/i.test(msg)) return 'Email này chưa được mời vào hệ thống. Liên hệ quản trị.';
  if (/User already registered/i.test(msg)) return 'Email đã có tài khoản. Hãy đăng nhập hoặc dùng Quên mật khẩu.';
  if (/Password should be at least/i.test(msg)) return 'Mật khẩu tối thiểu 6 ký tự';
  if (/JWT expired/i.test(msg)) return 'Phiên đăng nhập hết hạn, vui lòng đăng nhập lại';
  if (/duplicate key/i.test(msg)) return 'Dữ liệu bị trùng';
  if (/violates row-level security/i.test(msg)) return 'Bạn không có quyền thực hiện thao tác này';
  if (/phone_or_zalo/.test(msg)) return 'Cần ít nhất SĐT hoặc Zalo hợp lệ';
  if (/phone_format/.test(msg)) return 'SĐT không hợp lệ (0 + 9–10 số)';
  if (/tax_format/.test(msg)) return 'MST phải gồm 10 số hoặc 10-3 số';
  if (/content_check|care_logs_content/.test(msg)) return 'Nội dung trao đổi tối thiểu 15 ký tự';
  if (/Failed to fetch/i.test(msg)) return 'Mất kết nối mạng, thử lại';
  return msg;
}

async function raw(path: string, init: RequestInit & { auth?: boolean } = {}) {
  const c = cfg();
  const headers = new Headers(init.headers);
  headers.set('apikey', c.supabaseAnonKey);
  if (init.auth !== false) {
    await ensureFresh();
    // Khóa publishable (sb_publishable_…) chỉ đi ở header apikey; Authorization chỉ mang JWT phiên đăng nhập
    if (session?.access_token) headers.set('Authorization', `Bearer ${session.access_token}`);
    else if (c.supabaseAnonKey.startsWith('eyJ')) headers.set('Authorization', `Bearer ${c.supabaseAnonKey}`);
  }
  let res: Response;
  try { res = await fetch(c.supabaseUrl + path, { ...init, headers }); }
  catch (e: any) { throw new ApiError(friendly(e?.message || 'Lỗi mạng')); }
  if (res.status === 401 && session && init.auth !== false) {
    const ok = await refresh();
    if (ok) { headers.set('Authorization', `Bearer ${session!.access_token}`); res = await fetch(c.supabaseUrl + path, { ...init, headers }); }
  }
  if (!res.ok) {
    let body: any = null; try { body = await res.json(); } catch { /* */ }
    const msg = body?.message || body?.msg || body?.error_description || body?.error || `Lỗi ${res.status}`;
    if (res.status === 401 && /JWT|expired|token/i.test(msg)) setSession(null);
    throw new ApiError(friendly(msg), body?.code, res.status);
  }
  return res;
}

let refreshing: Promise<boolean> | null = null;
async function refresh(): Promise<boolean> {
  if (!session?.refresh_token) return false;
  if (!refreshing) refreshing = (async () => {
    try {
      const c = cfg();
      const r = await fetch(`${c.supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
        method: 'POST', headers: { apikey: c.supabaseAnonKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: session!.refresh_token }) });
      if (!r.ok) { setSession(null); return false; }
      const j = await r.json(); setSession(toSession(j)); return true;
    } catch { return false; } finally { setTimeout(() => (refreshing = null), 0); }
  })();
  return refreshing;
}
async function ensureFresh() { if (session && session.expires_at * 1000 - Date.now() < 60_000) await refresh(); }
const toSession = (j: any): Session => ({ access_token: j.access_token, refresh_token: j.refresh_token,
  expires_at: j.expires_at || Math.floor(Date.now() / 1000) + (j.expires_in || 3600), user: { id: j.user?.id, email: j.user?.email } });

export const auth = {
  get session() { return session; },
  onChange(f: (s: Session | null) => void) { listeners.add(f); return () => listeners.delete(f); },
  async signIn(email: string, password: string) {
    const r = await raw('/auth/v1/token?grant_type=password', { method: 'POST', auth: false, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: email.trim().toLowerCase(), password }) });
    setSession(toSession(await r.json()));
  },
  /** Đăng ký: chỉ email đã được mời mới thành công. keepSession=false khi Admin tạo hộ. */
  async signUp(email: string, password: string, keepSession = true) {
    const r = await raw('/auth/v1/signup', { method: 'POST', auth: false, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: email.trim().toLowerCase(), password }) });
    const j = await r.json();
    if (keepSession && j.access_token) setSession(toSession(j));
    return { needConfirm: !j.access_token };
  },
  async resetPassword(email: string) {
    const redirect = location.origin + location.pathname;
    await raw(`/auth/v1/recover?redirect_to=${encodeURIComponent(redirect)}`, { method: 'POST', auth: false, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: email.trim().toLowerCase() }) });
  },
  async updatePassword(password: string) {
    await raw('/auth/v1/user', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password }) });
  },
  /** Nhận token từ link email (#access_token=...&type=recovery) */
  consumeUrlToken(): string | null {
    const h = location.hash.replace(/^#\/?/, '');
    if (!h.includes('access_token=')) return null;
    const p = new URLSearchParams(h);
    setSession({ access_token: p.get('access_token')!, refresh_token: p.get('refresh_token') || '', expires_at: Number(p.get('expires_at')) || Math.floor(Date.now() / 1000) + Number(p.get('expires_in') || 3600), user: { id: '', email: '' } });
    history.replaceState(null, '', location.pathname + '#/account');
    return p.get('type');
  },
  async signOut() {
    try { await raw('/auth/v1/logout', { method: 'POST' }); } catch { /* ignore */ }
    setSession(null);
  },
};

// ---------- PostgREST ----------
type Filter = [string, string];
export class Query<T = any> implements PromiseLike<T> {
  private filters: Filter[] = [];
  private params: Record<string, string> = {};
  private method = 'GET';
  private body: any;
  private prefer: string[] = [];
  private isSingle = false;
  private wantCount = false;
  constructor(private table: string) {}
  select(cols = '*', o: { count?: boolean } = {}) { this.params.select = cols.replace(/\s+/g, ''); if (o.count) { this.wantCount = true; this.prefer.push('count=exact'); } return this; }
  eq(c: string, v: any) { this.filters.push([c, `eq.${v}`]); return this; }
  neq(c: string, v: any) { this.filters.push([c, `neq.${v}`]); return this; }
  gt(c: string, v: any) { this.filters.push([c, `gt.${v}`]); return this; }
  gte(c: string, v: any) { this.filters.push([c, `gte.${v}`]); return this; }
  lt(c: string, v: any) { this.filters.push([c, `lt.${v}`]); return this; }
  lte(c: string, v: any) { this.filters.push([c, `lte.${v}`]); return this; }
  is(c: string, v: null | boolean) { this.filters.push([c, `is.${v}`]); return this; }
  in(c: string, vs: any[]) { this.filters.push([c, `in.(${vs.map(v => `"${String(v).replace(/"/g, '')}"`).join(',')})`]); return this; }
  ilike(c: string, v: string) { this.filters.push([c, `ilike.*${v.replace(/[*,()]/g, ' ')}*`]); return this; }
  or(expr: string) { this.filters.push(['or', `(${expr})`]); return this; }
  order(c: string, o: { asc?: boolean; nulls?: 'first' | 'last' } = {}) {
    const v = `${c}.${o.asc === false ? 'desc' : 'asc'}${o.nulls ? '.nulls' + o.nulls : ''}`;
    this.params.order = this.params.order ? this.params.order + ',' + v : v; return this;
  }
  limit(n: number) { this.params.limit = String(n); return this; }
  range(from: number, to: number) { this.params.offset = String(from); this.params.limit = String(to - from + 1); return this; }
  single() { this.isSingle = true; return this; }
  maybeSingle() { this.isSingle = true; if (!this.params.limit) this.params.limit = '1'; return this; }
  insert(rows: any) { this.method = 'POST'; this.body = rows; this.prefer.push('return=representation'); return this; }
  upsert(rows: any, onConflict?: string) { this.method = 'POST'; this.body = rows; this.prefer.push('return=representation', 'resolution=merge-duplicates'); if (onConflict) this.params.on_conflict = onConflict; return this; }
  update(v: any) { this.method = 'PATCH'; this.body = v; this.prefer.push('return=representation'); return this; }
  delete() { this.method = 'DELETE'; this.prefer.push('return=representation'); return this; }
  async run(): Promise<any> {
    const qs = new URLSearchParams(this.params);
    this.filters.forEach(([k, v]) => qs.append(k, v));
    const headers: Record<string, string> = {};
    if (this.prefer.length) headers.Prefer = this.prefer.join(',');
    if (this.body !== undefined) headers['Content-Type'] = 'application/json';
    const res = await raw(`/rest/v1/${this.table}?${qs}`, { method: this.method, headers, body: this.body !== undefined ? JSON.stringify(this.body) : undefined });
    const text = await res.text();
    const data = text ? JSON.parse(text) : null;
    if (this.wantCount) {
      const cr = res.headers.get('content-range') || '';
      return { data, count: Number(cr.split('/')[1] || 0) };
    }
    if (this.isSingle) return Array.isArray(data) ? data[0] ?? null : data;
    return data;
  }
  then<A = T, B = never>(ok?: ((v: T) => A | PromiseLike<A>) | null, err?: ((e: any) => B | PromiseLike<B>) | null): PromiseLike<A | B> {
    return this.run().then(ok as any, err as any);
  }
}

export const db = {
  from: <T = any>(t: string) => new Query<T>(t),
  async rpc<T = any>(fn: string, args: Record<string, any> = {}): Promise<T> {
    const res = await raw(`/rest/v1/rpc/${fn}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
    const t = await res.text();
    return t ? JSON.parse(t) : (null as any);
  },
};

// ---------- Storage ----------
const encPath = (p: string) => p.split('/').map(encodeURIComponent).join('/');
export const storage = {
  async upload(bucket: string, path: string, file: Blob, upsert = false) {
    await raw(`/storage/v1/object/${bucket}/${encPath(path)}`, { method: 'POST', headers: { 'Content-Type': file.type || 'application/octet-stream', 'x-upsert': String(upsert) }, body: file });
    return path;
  },
  async signedUrl(bucket: string, path: string, expiresIn = 600, download?: string) {
    const r = await raw(`/storage/v1/object/sign/${bucket}/${encPath(path)}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ expiresIn }) });
    const j = await r.json();
    return cfg().supabaseUrl + '/storage/v1' + j.signedURL + (download ? `&download=${encodeURIComponent(download)}` : '');
  },
  async download(bucket: string, path: string): Promise<Blob> {
    const r = await raw(`/storage/v1/object/authenticated/${bucket}/${encPath(path)}`, { method: 'GET' });
    return r.blob();
  },
  async remove(bucket: string, paths: string[]) {
    if (!paths.length) return;
    await raw(`/storage/v1/object/${bucket}`, { method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ prefixes: paths }) });
  },
};
