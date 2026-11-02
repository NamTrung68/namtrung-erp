// pdf.js (bản legacy — chạy cả điện thoại đời cũ), tự host ở vendor/pdfjs/, chỉ tải khi cần
let lib: Promise<any> | null = null;
export function pdfjs(): Promise<any> {
  if (!lib) {
    const base = new URL('vendor/pdfjs/', document.baseURI).href;
    const src = base + 'pdf.min.mjs';
    lib = import(/* @vite-ignore */ src).then((m: any) => { m.GlobalWorkerOptions.workerSrc = base + 'pdf.worker.min.mjs'; return m; });
    lib.catch(() => { lib = null; });
  }
  return lib;
}
const open = async (blob: Blob) => { const task = (await pdfjs()).getDocument({ data: new Uint8Array(await blob.arrayBuffer()) }); const doc = await task.promise; return { doc, done: () => { try { task.destroy(); } catch { /* bỏ qua */ } } }; };

/** Lấy chữ trong PDF (để đọc MST, tổng tiền, số HĐ khi tên file không theo mẫu) */
export async function pdfText(blob: Blob, maxPages = 3): Promise<string> {
  const { doc, done } = await open(blob); let t = '';
  for (let i = 1; i <= Math.min(doc.numPages, maxPages); i++) { const c = await (await doc.getPage(i)).getTextContent(); t += c.items.map((x: any) => x.str + (x.hasEOL ? '\n' : ' ')).join('') + '\n'; }
  done(); return t;
}

/** Vẽ toàn bộ trang PDF vào khung (vừa chiều ngang) */
export async function renderPdf(blob: Blob, el: HTMLElement, isAlive: () => boolean = () => true): Promise<number> {
  const { doc, done } = await open(blob); el.innerHTML = '';
  const w = Math.max(280, Math.min(el.clientWidth || 800, 1000)); const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
  for (let i = 1; i <= doc.numPages && isAlive(); i++) {
    const page = await doc.getPage(i); const v1 = page.getViewport({ scale: 1 }); const vp = page.getViewport({ scale: (w / v1.width) * dpr });
    const cv = document.createElement('canvas'); cv.width = Math.floor(vp.width); cv.height = Math.floor(vp.height);
    cv.style.width = w + 'px'; cv.style.maxWidth = '100%'; cv.style.height = 'auto'; cv.className = 'mx-auto mb-3 block rounded bg-white shadow';
    el.appendChild(cv);
    await page.render({ canvasContext: cv.getContext('2d')!, viewport: vp, canvas: cv }).promise;
  }
  const n = doc.numPages; done(); return n;
}
