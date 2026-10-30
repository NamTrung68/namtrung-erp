// Lưu file lên Google Drive của công ty qua Apps Script (Web app). Cấu hình ở Cấu hình → Sao lưu Drive.
export interface DriveCfg { url?: string; upload_key?: string; last_backup_at?: string }
export const driveReady = (c?: DriveCfg) => !!(c?.url && c?.upload_key);
const b64 = (blob: Blob) => new Promise<string>((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] || ''); r.onerror = rej; r.readAsDataURL(blob); });
/** Gửi file lên Drive, trả link file. folder dạng "Ke toan/Doi soat/2026-10" */
export async function saveToDrive(c: DriveCfg, blob: Blob, name: string, folder: string): Promise<string> {
  if (!driveReady(c)) throw new Error('Chưa cấu hình lưu Google Drive (Cấu hình → Sao lưu Drive)');
  const r = await fetch(c.url!, { method: 'POST', body: JSON.stringify({ action: 'upload', key: c.upload_key, folder, name, mime: blob.type || 'application/octet-stream', data: await b64(blob) }) });
  let j: any; try { j = await r.json(); } catch { throw new Error('Drive không phản hồi đúng — kiểm tra link Web app (quyền truy cập: Bất kỳ ai)'); }
  if (!j.ok) throw new Error('Drive: ' + (j.error || 'lỗi'));
  return j.url;
}

/** Mã Apps Script dán vào script.google.com (điền sẵn địa chỉ Supabase) */
export const appsScriptCode = (supabaseUrl: string, anonKey: string) => `// ==== NT-ERP: Sao lưu hằng ngày + nhận file lên Google Drive ====
// Bước: (1) Project Settings → Script properties: thêm BACKUP_TOKEN và UPLOAD_KEY (lấy trong ERP)
//       (2) Chọn hàm setup → Run → cho phép quyền  (3) Deploy → New deployment → Web app → Execute as: Me, Who has access: Anyone → dán link vào ERP
const SUPABASE_URL = '${supabaseUrl}';
const ANON_KEY = '${anonKey}';
const ROOT = 'NT-ERP';           // thư mục gốc trên Drive
const KEEP_DAYS = 60;            // giữ bản sao lưu 60 ngày

const P = () => PropertiesService.getScriptProperties();
function root_() { const it = DriveApp.getFoldersByName(ROOT); return it.hasNext() ? it.next() : DriveApp.createFolder(ROOT); }
function folder_(path) { return String(path || 'Khac').split('/').filter(String).reduce((f, n) => { const it = f.getFoldersByName(n); return it.hasNext() ? it.next() : f.createFolder(n); }, root_()); }

function setup() {
  if (!P().getProperty('BACKUP_TOKEN') || !P().getProperty('UPLOAD_KEY')) throw new Error('Thiếu BACKUP_TOKEN / UPLOAD_KEY trong Script properties');
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('dailyBackup').timeBased().everyDays(1).atHour(1).inTimezone('Asia/Ho_Chi_Minh').create();
  dailyBackup();
}

function rpc_(fn, body) {
  const r = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, { method: 'post', contentType: 'application/json',
    headers: { apikey: ANON_KEY, Authorization: 'Bearer ' + ANON_KEY }, payload: JSON.stringify(Object.assign({ p_token: P().getProperty('BACKUP_TOKEN') }, body)), muteHttpExceptions: true });
  if (r.getResponseCode() !== 200) throw new Error('Sao lưu lỗi ' + r.getResponseCode() + ' (' + fn + '): ' + r.getContentText().slice(0, 300));
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
    if (!b.key || b.key !== P().getProperty('UPLOAD_KEY')) return out_({ ok: false, error: 'Sai khóa' });
    const file = folder_(b.folder).createFile(Utilities.newBlob(Utilities.base64Decode(b.data), b.mime || 'application/octet-stream', b.name));
    return out_({ ok: true, url: file.getUrl() });
  } catch (err) { return out_({ ok: false, error: String(err) }); }
}
function doGet() { return out_({ ok: true, app: 'NT-ERP Drive' }); }
function out_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
`;
