// Bản 31 — chốt chặn an toàn cho tích hợp MISA:
//  1) Không có lời gọi nhóm PHÁT HÀNH / KÝ SỐ của MISA ở bất kỳ đâu trong repo (chỉ được nhóm /invoiceweb tạo nháp)
//  2) Hàm máy chủ "misa" chỉ có đúng 7 đường dẫn được phép
//  3) Không có khóa bí mật / mật khẩu trong code
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const SKIP = new Set(['node_modules', 'dist', '.git']);
function walk(dir: string, out: string[] = []): string[] {
  for (const f of readdirSync(dir)) {
    if (SKIP.has(f)) continue;
    const p = join(dir, f); const s = statSync(p);
    if (s.isDirectory()) walk(p, out); else if (/\.(ts|tsx|js|mjs|cjs|sql|json|html|yml|yaml|sh|md)$/.test(f)) out.push(p);
  }
  return out;
}
const files = walk(ROOT).filter(f => !f.endsWith('misa-guard.test.ts'));
const read = (f: string) => readFileSync(f, 'utf8');
const rel = (f: string) => f.slice(ROOT.length);

// Ghép chuỗi để chính file test này không tự khớp
const PUB = 'publish' + 'ing';
const BAD_PATHS = [
  new RegExp('/invoice/' + PUB, 'i'),                    // nhóm phát hành
  new RegExp('/invoice' + '/(token|templates|unpublishview|publishview|status|Download|voucher-paper|paging|2fa|sign)', 'i'),
  new RegExp('invoice' + PUB, 'i'),                       // endpoint invoicepublishing (bản v3)
  /\/(sign-?xml|signxml|get-certificates)\b/i,          // ký số
];

test('không gọi nhóm phát hành / ký số của MISA ở bất kỳ file nào', () => {
  const hits: string[] = [];
  for (const f of files) {
    const t = read(f);
    BAD_PATHS.forEach(re => { const m = t.match(re); if (m) hits.push(`${rel(f)}: ${m[0]}`); });
  }
  assert.deepEqual(hits, []);
});

test('hàm máy chủ misa chỉ có 7 đường dẫn /invoiceweb được phép', () => {
  const src = read(join(ROOT, 'supabase/functions/misa/index.ts'));
  const block = src.match(/ALLOWED_PATHS = \[([\s\S]*?)\] as const/);
  assert.ok(block, 'thiếu ALLOWED_PATHS');
  const allowed = Array.from(block![1].matchAll(/'([^']+)'/g)).map(m => m[1]).sort();
  assert.deepEqual(allowed, ['/invoiceweb/delete', '/invoiceweb/getlist', '/invoiceweb/insert', '/invoiceweb/preview', '/invoiceweb/templates', '/invoiceweb/token', '/invoiceweb/viewrefid']);
  // mọi chuỗi đường dẫn MISA trong hàm đều thuộc danh sách
  const used = new Set(Array.from(src.matchAll(/'(\/invoice[a-z]*\/[A-Za-z0-9/_-]*)'/g)).map(m => m[1]));
  used.forEach(p => assert.ok(allowed.includes(p), 'đường dẫn ngoài danh sách: ' + p));
  // chỉ có 1 chỗ gọi fetch tới MISA (cửa duy nhất misaRaw) + 1 chỗ lưu Drive
  assert.equal((src.match(/await fetch\(/g) || []).length, 2);
  assert.match(src, /if \(!\(ALLOWED_PATHS as readonly string\[\]\)\.includes\(path\)\) throw/);
});

test('không có khóa bí mật / mật khẩu trong code', () => {
  const SECRET = [
    /sb_secret_[A-Za-z0-9_-]{8,}/,
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    /MISA_(CLIENT_SECRET|PASSWORD|CLIENT_ID|USERNAME)\s*[:=]\s*['"][^'"\s]{4,}['"]/,
    /ClientSecret['"]?\s*:\s*['"][^'"\s]{6,}['"]/,
    /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]*c2VydmljZV9yb2xl/, // JWT có role service_role
  ];
  const hits: string[] = [];
  for (const f of files) { const t = read(f); SECRET.forEach(re => { const m = t.match(re); if (m) hits.push(`${rel(f)}: ${m[0].slice(0, 40)}`); }); }
  assert.deepEqual(hits, []);
  // bí mật MISA chỉ được đọc từ biến môi trường của hàm máy chủ
  const fn = read(join(ROOT, 'supabase/functions/misa/index.ts'));
  ['MISA_CLIENT_ID', 'MISA_CLIENT_SECRET', 'MISA_TAX_CODE', 'MISA_USERNAME', 'MISA_PASSWORD'].forEach(k => assert.ok(fn.includes(`'${k}'`), k));
  // trình duyệt không bao giờ chứa tên bí mật MISA
  const front = files.filter(f => rel(f).startsWith('src/') || rel(f).startsWith('public/'));
  front.forEach(f => assert.ok(!/MISA_CLIENT_SECRET|MISA_PASSWORD/.test(read(f)) || rel(f) === 'src/pages/admin/Settings.tsx', 'lộ tên bí mật ở ' + rel(f)));
});
