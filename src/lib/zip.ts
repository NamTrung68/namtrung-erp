// Ghi file ZIP (phương thức STORE, không nén) — đủ cho ảnh JPEG đã nén sẵn
const table = (() => { const t = new Uint32Array(256); for (let i = 0; i < 256; i++) { let c = i; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[i] = c >>> 0; } return t; })();
const crc32 = (b: Uint8Array) => { let c = 0xffffffff; for (let i = 0; i < b.length; i++) c = table[(c ^ b[i]) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
export async function makeZip(files: { name: string; data: Blob }[]): Promise<Blob> {
  const enc = new TextEncoder(); const parts: BlobPart[] = []; const central: Uint8Array[] = []; let offset = 0;
  for (const f of files) {
    const data = new Uint8Array(await f.data.arrayBuffer()); const name = enc.encode(f.name); const crc = crc32(data);
    const h = new DataView(new ArrayBuffer(30));
    h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(6, 0x0800, true); h.setUint16(8, 0, true);
    h.setUint32(14, crc, true); h.setUint32(18, data.length, true); h.setUint32(22, data.length, true); h.setUint16(26, name.length, true);
    parts.push(h.buffer, name, data);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x0800, true);
    c.setUint32(16, crc, true); c.setUint32(20, data.length, true); c.setUint32(24, data.length, true); c.setUint16(28, name.length, true); c.setUint32(42, offset, true);
    const cc = new Uint8Array(46 + name.length); cc.set(new Uint8Array(c.buffer)); cc.set(name, 46); central.push(cc);
    offset += 30 + name.length + data.length;
  }
  const size = central.reduce((s, c) => s + c.length, 0);
  const e = new DataView(new ArrayBuffer(22));
  e.setUint32(0, 0x06054b50, true); e.setUint16(8, files.length, true); e.setUint16(10, files.length, true); e.setUint32(12, size, true); e.setUint32(16, offset, true);
  return new Blob([...parts, ...central, e.buffer], { type: 'application/zip' });
}
