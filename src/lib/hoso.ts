// Bản 41 — Hồ sơ scan: gộp ảnh chụp thành 1 PDF, đặt tên + thư mục Drive theo khách
//  Phần thuần (không DOM) để kiểm thử bằng node: jpegsToPdf, scanFolder, scanName

export type ScanKind = 'hd' | 'ddh' | 'bbgn' | 'hdmb' | 'hdnt' | 'khac';
export const SCAN_KIND: Record<ScanKind, [string, string]> = {
  hd: ['HĐ đã ký', 'HD'], ddh: ['Đơn đặt hàng', 'DDH'], bbgn: ['Biên bản giao nhận', 'BBGN'],
  hdmb: ['HĐ mua bán', 'HDMB'], hdnt: ['HĐ nguyên tắc', 'HDNT'], khac: ['Giấy tờ khác', 'KHAC'],
};
export const SCAN_ORDER: ScanKind[] = ['hd', 'ddh', 'bbgn', 'hdmb', 'hdnt', 'khac'];

/** Bỏ dấu tiếng Việt + ký tự cấm trong tên file / thư mục Drive */
export function safeName(s: string, max = 60): string {
  return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D')
    .replace(/[\\/:*?"<>|#%{}~&]+/g, '-').replace(/\.{2,}/g, '.').replace(/\s+/g, ' ').trim().slice(0, max).replace(/[\s.-]+$/, '') || 'Khac';
}

/** Thư mục Drive (trong ERP_NAMTRUNG): Ho so khach hang/<MST> - <Tên>/HD <năm>  ·  HĐNT / chỉ HĐMB → …/Hop dong NT-MB */
export function scanFolder(o: { mst?: string | null; ten?: string | null; kinds: string[]; ngay?: string | null }): string {
  const kh = safeName([String(o.mst || '').replace(/\s/g, '') || 'Chua co MST', o.ten || ''].filter(Boolean).join(' - '), 90);
  const hopDong = o.kinds.length > 0 && o.kinds.every(k => k === 'hdnt' || k === 'hdmb');
  const nam = String(o.ngay || new Date().toISOString()).slice(0, 4);
  return `Ho so khach hang/${kh}/${hopDong ? 'Hop dong NT-MB' : 'HD ' + nam}`;
}

/** Tên file: HD401_HD-DDH-BBGN_20261111-0930.pdf · HDNT_01-2026-HDNT_20261111-0930.pdf */
export function scanName(o: { so_hd?: string | null; ma_hdnt?: string | null; kinds: string[]; ext: string; at?: Date }): string {
  const t = o.at || new Date(); const p = (n: number) => String(n).padStart(2, '0');
  const stamp = `${t.getFullYear()}${p(t.getMonth() + 1)}${p(t.getDate())}-${p(t.getHours())}${p(t.getMinutes())}`;
  const ks = SCAN_ORDER.filter(k => o.kinds.includes(k)).map(k => SCAN_KIND[k][1]).join('-') || 'SCAN';
  const so = String(o.so_hd || '').replace(/\D/g, '').replace(/^0+(?=\d)/, '');
  const head = so ? `HD${so}_${ks}` : o.ma_hdnt ? `${ks}_${safeName(o.ma_hdnt, 40)}` : ks;
  return `${safeName(head, 80)}_${stamp}.${o.ext.replace(/^\./, '') || 'pdf'}`;
}

export interface Jpeg { data: Uint8Array; w: number; h: number }
/** Gộp nhiều ảnh JPEG thành 1 PDF (mỗi ảnh 1 trang A4, giữ tỷ lệ, lề 18pt). Không cần thư viện. */
export function jpegsToPdf(pages: Jpeg[]): Uint8Array {
  if (!pages.length) throw new Error('Chưa có ảnh');
  const enc = new TextEncoder(); const chunks: Uint8Array[] = []; const offs: number[] = []; let len = 0;
  const push = (x: string | Uint8Array) => { const b = typeof x === 'string' ? enc.encode(x) : x; chunks.push(b); len += b.length; };
  const obj = (n: number, body: (string | Uint8Array)[]) => { offs[n] = len; push(`${n} 0 obj\n`); body.forEach(push); push('\nendobj\n'); };
  const N = pages.length; const kids = pages.map((_, i) => `${3 + i * 3} 0 R`).join(' ');
  push('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
  obj(1, ['<< /Type /Catalog /Pages 2 0 R >>']);
  obj(2, [`<< /Type /Pages /Kids [${kids}] /Count ${N} >>`]);
  pages.forEach((pg, i) => {
    const land = pg.w > pg.h; const W = land ? 842 : 595, H = land ? 595 : 842, m = 18;
    const s = Math.min((W - 2 * m) / pg.w, (H - 2 * m) / pg.h); const dw = +(pg.w * s).toFixed(2), dh = +(pg.h * s).toFixed(2);
    const x = +((W - dw) / 2).toFixed(2), y = +((H - dh) / 2).toFixed(2);
    const p = 3 + i * 3, c = p + 1, im = p + 2; const cs = `q ${dw} 0 0 ${dh} ${x} ${y} cm /Im0 Do Q`;
    obj(p, [`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${W} ${H}] /Resources << /XObject << /Im0 ${im} 0 R >> >> /Contents ${c} 0 R >>`]);
    obj(c, [`<< /Length ${cs.length} >>\nstream\n${cs}\nendstream`]);
    obj(im, [`<< /Type /XObject /Subtype /Image /Width ${pg.w} /Height ${pg.h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${pg.data.length} >>\nstream\n`, pg.data, '\nendstream']);
  });
  const total = 3 + N * 3; const xref = len;
  push(`xref\n0 ${total}\n0000000000 65535 f \n`);
  for (let i = 1; i < total; i++) push(String(offs[i]).padStart(10, '0') + ' 00000 n \n');
  push(`trailer\n<< /Size ${total} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
  const out = new Uint8Array(len); let o = 0; chunks.forEach(c => { out.set(c, o); o += c.length; }); return out;
}

// ---------- Phần chạy trên trình duyệt ----------
/** Ảnh (chụp điện thoại / scan) → JPEG nén (cạnh dài tối đa 2000px, đủ đọc chữ, ~300–500KB/trang) */
export async function toJpeg(file: Blob, maxSide = 2000, quality = 0.72): Promise<Jpeg> {
  const bmp = await createImageBitmap(file as Blob, { imageOrientation: 'from-image' } as any);
  const k = Math.min(1, maxSide / Math.max(bmp.width, bmp.height)); const w = Math.round(bmp.width * k), h = Math.round(bmp.height * k);
  const cv = document.createElement('canvas'); cv.width = w; cv.height = h; const g = cv.getContext('2d')!;
  g.fillStyle = '#fff'; g.fillRect(0, 0, w, h); g.drawImage(bmp, 0, 0, w, h); bmp.close?.();
  const blob: Blob = await new Promise((res, rej) => cv.toBlob(b => (b ? res(b) : rej(new Error('Không đọc được ảnh'))), 'image/jpeg', quality));
  return { data: new Uint8Array(await blob.arrayBuffer()), w, h };
}
/** Nhiều ảnh → 1 file PDF */
export async function imagesToPdf(files: Blob[], onStep?: (i: number, n: number) => void): Promise<Blob> {
  const pages: Jpeg[] = [];
  for (let i = 0; i < files.length; i++) { pages.push(await toJpeg(files[i])); onStep?.(i + 1, files.length); }
  return new Blob([jpegsToPdf(pages) as BlobPart], { type: 'application/pdf' });
}
