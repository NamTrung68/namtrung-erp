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

/** Chuẩn bị file trước khi tải lên: ảnh → nén JPEG ~100–200 KB (giữ đủ nét để đọc giấy tờ); file khác giới hạn dung lượng */
export async function prepareUpload(file: File, maxMB = 5): Promise<File> {
  if (/^image\/(jpeg|png|webp|bmp|heic|heif)$/i.test(file.type) || /\.(jpe?g|png|webp|bmp|heic)$/i.test(file.name)) {
    if (file.size <= 200 * 1024 && /jpe?g/i.test(file.type)) return file;
    try {
      let blob: Blob | null = null;
      for (const side of [1800, 1500, 1200, 1000]) { blob = await compressImage(file, side, 190); if (blob.size <= 200 * 1024) break; }
      return new File([blob!], file.name.replace(/\.[^.]+$/, '') + '.jpg', { type: 'image/jpeg' });
    } catch { /* trình duyệt không đọc được định dạng ảnh này → giữ nguyên */ }
  }
  if (file.size > maxMB * 1024 * 1024) throw new Error(`File "${file.name}" nặng ${(file.size / 1048576).toFixed(1)} MB (tối đa ${maxMB} MB). Hãy tải lên Google Drive rồi dán link.`);
  return file;
}
export const isUrl = (s: string) => /^https?:\/\/\S+$/i.test(s.trim());
