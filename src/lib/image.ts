// Nén ảnh selfie phía trình duyệt (mục tiêu 100–200 KB)
export async function compressImage(src: Blob | HTMLCanvasElement, maxSide = 960, targetKB = 180): Promise<Blob> {
  let canvas: HTMLCanvasElement;
  if (src instanceof HTMLCanvasElement) canvas = src;
  else {
    const bmp = await createImageBitmap(src);
    canvas = document.createElement('canvas');
    canvas.width = bmp.width; canvas.height = bmp.height;
    canvas.getContext('2d')!.drawImage(bmp, 0, 0);
  }
  const scale = Math.min(1, maxSide / Math.max(canvas.width, canvas.height));
  const out = document.createElement('canvas');
  out.width = Math.round(canvas.width * scale); out.height = Math.round(canvas.height * scale);
  out.getContext('2d')!.drawImage(canvas, 0, 0, out.width, out.height);
  let q = 0.82, blob: Blob | null = null;
  for (let i = 0; i < 6; i++) {
    blob = await new Promise<Blob | null>(r => out.toBlob(r, 'image/jpeg', q));
    if (!blob || blob.size / 1024 <= targetKB) break;
    q -= 0.12;
  }
  if (!blob) throw new Error('Không nén được ảnh');
  return blob;
}
