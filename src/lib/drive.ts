// Google Drive của công ty qua Apps Script (Web app). Cấu hình ở Cấu hình → Sao lưu Drive.
// Không có khóa cố định trong trình duyệt: mỗi lần tải lên / xem file, ERP xin 1 VÉ dùng 1 lần từ Supabase (đã kiểm quyền),
// Apps Script đổi vé với Supabase (kèm mã bí mật riêng của Apps Script) rồi mới ghi / trả file.
import { db } from './sb';

export interface DriveCfg { url?: string; last_backup_at?: string }
export const driveReady = (c?: DriveCfg) => !!c?.url;
const b64 = (blob: Blob) => new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] || ''); r.onerror = rej; r.readAsDataURL(blob); });
const OLD = 'Apps Script trên Drive chưa cập nhật bản mới — Admin vào Cấu hình → Sao lưu Google Drive, dán lại mã và Deploy bản mới';

async function call(c: DriveCfg, body: any): Promise<any> {
  if (!driveReady(c)) throw new Error('Chưa cấu hình lưu Google Drive (Cấu hình → Sao lưu Google Drive)');
  let r: Response;
  try { r = await fetch(c.url!, { method: 'POST', body: JSON.stringify(body) }); } catch { throw new Error('Không kết nối được Google Drive — kiểm tra mạng'); }
  let j: any; try { j = await r.json(); } catch { throw new Error('Drive không phản hồi đúng — kiểm tra link Web app (quyền truy cập: Bất kỳ ai)'); }
  if (!j.ok) throw new Error(/Sai khóa/.test(j.error || '') ? OLD : 'Drive: ' + (j.error || 'lỗi'));
  return j;
}

export interface UpItem { blob: Blob; name: string; folder: string }
export interface UpResult { ok: boolean; id?: string; url?: string; error?: string }
/** Tải nhiều file lên Drive: xin vé cả lô trong 1 lần, gửi song song 3 file */
export async function driveUploadMany(c: DriveCfg, items: UpItem[], onProgress?: (done: number, total: number) => void): Promise<UpResult[]> {
  if (!items.length) return [];
  const tickets = await db.rpc<string[]>('drive_upload_tickets', { p_folders: items.map(x => x.folder) });
  const out: UpResult[] = new Array(items.length); let next = 0, done = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++; const x = items[i];
      try { const j = await call(c, { action: 'upload', ticket: tickets[i], name: x.name, mime: x.blob.type || 'application/octet-stream', data: await b64(x.blob) }); out[i] = { ok: true, id: j.id, url: j.url }; }
      catch (e: any) { out[i] = { ok: false, error: e.message || String(e) }; }
      onProgress?.(++done, items.length);
    }
  };
  await Promise.all(Array.from({ length: Math.min(3, items.length) }, worker));
  return out;
}
/** Gửi 1 file lên Drive, trả link file. folder dạng "Ke toan/Doi soat/2026-10" */
export async function saveToDrive(c: DriveCfg, blob: Blob, name: string, folder: string): Promise<string> {
  const [r] = await driveUploadMany(c, [{ blob, name, folder }]);
  if (!r.ok) throw new Error(r.error); return r.url!;
}

// ---------- Xem file hóa đơn ----------
const cache = new Map<string, Promise<Blob>>();
/** Lấy file PDF hóa đơn theo mã file trong ERP (giữ trong bộ nhớ trang, mở lại là hiện ngay) */
export function hdFile(c: DriveCfg, fileId: string): Promise<Blob> {
  const hit = cache.get(fileId); if (hit) return hit;
  const p = (async () => {
    const ticket = await db.rpc<string>('out_file_ticket', { p_file: fileId });
    const j = await call(c, { action: 'get', ticket });
    const bin = atob(j.data); const u8 = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    return new Blob([u8], { type: j.mime || 'application/pdf' });
  })();
  cache.set(fileId, p); p.catch(() => cache.delete(fileId));
  if (cache.size > 40) cache.delete(cache.keys().next().value!);
  return p;
}
/** Bản 41: lấy file bản scan hồ sơ (vé xem dùng 1 lần — người có quyền với HĐ / pháp nhân, không cần quyền Drive) */
export function scanFile(c: DriveCfg, scanId: string): Promise<Blob> {
  const k = 'scan:' + scanId; const hit = cache.get(k); if (hit) return hit;
  const p = (async () => {
    const ticket = await db.rpc<string>('ho_so_scan_ticket', { p_id: scanId });
    const j = await call(c, { action: 'get', ticket });
    const bin = atob(j.data); const u8 = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    return new Blob([u8], { type: j.mime || 'application/pdf' });
  })();
  cache.set(k, p); p.catch(() => cache.delete(k));
  if (cache.size > 40) cache.delete(cache.keys().next().value!);
  return p;
}
export const hdFileCached = (fileId: string) => cache.has(fileId);
export const clearHdCache = () => cache.clear();

/** Mã Apps Script dán vào script.google.com (điền sẵn địa chỉ Supabase) */
export const appsScriptCode = (supabaseUrl: string, anonKey: string) => `// ==== NT-ERP: Sao lưu hằng ngày + lưu / xem file trên Google Drive (bản 20 — dùng vé, không còn UPLOAD_KEY) ====
// Cài lần đầu: (1) Project Settings → Script properties: thêm BACKUP_TOKEN (lấy trong ERP)
//              (2) Chọn hàm setup → Run → cho phép quyền  (3) Deploy → New deployment → Web app → Execute as: Me, Who has access: Anyone → dán link vào ERP
// Cập nhật bản mới: dán đè toàn bộ mã này → Lưu → Deploy → Manage deployments → ✎ → Version: New version → Deploy (link giữ nguyên)
const SUPABASE_URL = '${supabaseUrl}';
const ANON_KEY = '${anonKey}';
const ROOT = 'ERP_NAMTRUNG';     // thư mục chung chứa mọi file ERP trên Drive (thư mục cũ NT-ERP tự đổi tên thành thư mục này)
const KEEP_DAYS = 60;            // giữ bản sao lưu 60 ngày

const P = () => PropertiesService.getScriptProperties();
function root_() {
  const it = DriveApp.getFoldersByName(ROOT); if (it.hasNext()) return it.next();
  const old = DriveApp.getFoldersByName('NT-ERP');   // gom thư mục cũ vào thư mục chung: đổi tên, link file cũ vẫn mở được
  if (old.hasNext()) { const f = old.next(); f.setName(ROOT); return f; }
  return DriveApp.createFolder(ROOT);
}
function folder_(path) { return String(path || 'Khac').split('/').filter(String).reduce((f, n) => { const it = f.getFoldersByName(n); return it.hasNext() ? it.next() : f.createFolder(n); }, root_()); }

function setup() {
  if (!P().getProperty('BACKUP_TOKEN')) throw new Error('Thiếu BACKUP_TOKEN trong Script properties');
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('dailyBackup').timeBased().everyDays(1).atHour(1).inTimezone('Asia/Ho_Chi_Minh').create();
  dailyBackup();
}

function rpc_(fn, body) {
  const r = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, { method: 'post', contentType: 'application/json',
    headers: ANON_KEY.indexOf('eyJ') === 0 ? { apikey: ANON_KEY, Authorization: 'Bearer ' + ANON_KEY } : { apikey: ANON_KEY }, payload: JSON.stringify(Object.assign({ p_token: P().getProperty('BACKUP_TOKEN') }, body)), muteHttpExceptions: true });
  if (r.getResponseCode() !== 200) { let m = r.getContentText(); try { m = JSON.parse(m).message || m; } catch (e) {} throw new Error(fn + ': ' + String(m).slice(0, 300)); }
  return r.getContentText();
}

function dailyBackup() {
  const tables = JSON.parse(rpc_('backup_tables', {}));
  const parts = [];   // ghép chuỗi JSON từng bảng, lấy mỗi lần 1000 dòng
  tables.forEach(t => {
    const rows = [];
    for (let off = 0; ; off += 1000) {
      const page = rpc_('backup_page', { p_table: t, p_offset: off, p_limit: 1000 });
      if (page === '[]') break;
      rows.push(page.slice(1, -1));
      if (JSON.parse(page).length < 1000) break;
    }
    parts.push(JSON.stringify(t) + ':[' + rows.join(',') + ']');
  });
  const json = '{"generated_at":' + JSON.stringify(new Date().toISOString()) + ',"version":2,"tables":{' + parts.join(',') + '}}';
  const stamp = Utilities.formatDate(new Date(), 'Asia/Ho_Chi_Minh', 'yyyy-MM-dd_HHmm');
  const name = 'nt-erp_' + stamp + '.json';
  const f = folder_('Sao luu');
  f.createFile(Utilities.gzip(Utilities.newBlob(json, 'application/json', name), name + '.gz'));
  const cut = new Date(Date.now() - KEEP_DAYS * 864e5);
  const it = f.getFiles(); while (it.hasNext()) { const x = it.next(); if (x.getDateCreated() < cut) x.setTrashed(true); }
}

function doPost(e) {
  try {
    const b = JSON.parse(e.postData.contents);
    if (!b.ticket) return out_({ ok: false, error: 'Thiếu vé' });
    const t = JSON.parse(rpc_('drive_redeem', { p_ticket: b.ticket }));
    if (b.action === 'get' && t.kind === 'view') {
      const blob = DriveApp.getFileById(t.drive_id).getBlob();
      return out_({ ok: true, mime: blob.getContentType(), data: Utilities.base64Encode(blob.getBytes()) });
    }
    if (b.action === 'upload' && t.kind === 'upload') {
      const file = folder_(t.folder).createFile(Utilities.newBlob(Utilities.base64Decode(b.data), b.mime || 'application/octet-stream', b.name));
      return out_({ ok: true, id: file.getId(), url: file.getUrl() });
    }
    return out_({ ok: false, error: 'Vé không đúng loại' });
  } catch (err) { return out_({ ok: false, error: String(err && err.message || err) }); }
}
function doGet() { return out_({ ok: true, app: 'NT-ERP Drive', version: 20 }); }
function out_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
`;
