// Đọc file .xlsx (Office Open XML) ngay trên trình duyệt: giải nén ZIP + đọc sheet đầu tiên
async function inflate(data: Uint8Array): Promise<Uint8Array> {
  const ds = new (globalThis as any).DecompressionStream('deflate-raw');
  const out = new Response(new Blob([data]).stream().pipeThrough(ds));
  return new Uint8Array(await out.arrayBuffer());
}
async function unzip(buf: ArrayBuffer): Promise<Map<string, Uint8Array>> {
  const dv = new DataView(buf); const u8 = new Uint8Array(buf); const files = new Map<string, Uint8Array>();
  let eocd = -1; for (let i = buf.byteLength - 22; i >= 0; i--) if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) throw new Error('File không phải định dạng .xlsx');
  const n = dv.getUint16(eocd + 10, true); let p = dv.getUint32(eocd + 16, true); const dec = new TextDecoder();
  for (let i = 0; i < n; i++) {
    const method = dv.getUint16(p + 10, true), csize = dv.getUint32(p + 20, true), nlen = dv.getUint16(p + 28, true),
      elen = dv.getUint16(p + 30, true), clen = dv.getUint16(p + 32, true), off = dv.getUint32(p + 42, true);
    const name = dec.decode(u8.subarray(p + 46, p + 46 + nlen));
    const lnlen = dv.getUint16(off + 26, true), lelen = dv.getUint16(off + 28, true);
    const data = u8.subarray(off + 30 + lnlen + lelen, off + 30 + lnlen + lelen + csize);
    files.set(name, method === 0 ? data : await inflate(data));
    p += 46 + nlen + elen + clen;
  }
  return files;
}
const colIdx = (ref: string) => { const m = ref.match(/^[A-Z]+/)![0]; let c = 0; for (const ch of m) c = c * 26 + ch.charCodeAt(0) - 64; return c - 1; };
export async function readXlsx(file: Blob): Promise<{ sheet: string; rows: any[][] }[]> {
  const files = await unzip(await file.arrayBuffer()); const dec = new TextDecoder(); const parser = new DOMParser();
  const xml = (p: string) => (files.get(p) ? parser.parseFromString(dec.decode(files.get(p)!), 'application/xml') : null);
  const ss: string[] = [];
  const sst = xml('xl/sharedStrings.xml');
  sst?.querySelectorAll('si').forEach(si => ss.push(Array.from(si.getElementsByTagName('t')).map(t => t.textContent).join('')));
  const wb = xml('xl/workbook.xml'); const rels = xml('xl/_rels/workbook.xml.rels');
  const relMap = new Map<string, string>(); rels?.querySelectorAll('Relationship').forEach(r => relMap.set(r.getAttribute('Id')!, r.getAttribute('Target')!));
  const out: { sheet: string; rows: any[][] }[] = [];
  for (const s of Array.from(wb?.getElementsByTagName('sheet') || [])) {
    const rid = s.getAttribute('r:id') || s.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'id');
    let target = relMap.get(rid!) || ''; target = target.replace(/^\//, ''); if (!target.startsWith('xl/')) target = 'xl/' + target;
    const doc = xml(target); if (!doc) continue;
    const rows: any[][] = [];
    for (const r of Array.from(doc.getElementsByTagName('row'))) {
      const ri = Number(r.getAttribute('r')) - 1; const row: any[] = [];
      for (const c of Array.from(r.getElementsByTagName('c'))) {
        const t = c.getAttribute('t'); const v = c.getElementsByTagName('v')[0]?.textContent ?? null;
        let val: any = v;
        if (t === 's') val = ss[Number(v)];
        else if (t === 'inlineStr') val = Array.from(c.getElementsByTagName('t')).map(x => x.textContent).join('');
        else if (t === 'b') val = v === '1';
        else if (t !== 'str' && v !== null && v !== '' && !isNaN(Number(v))) val = Number(v);
        row[colIdx(c.getAttribute('r') || 'A')] = val;
      }
      rows[ri] = row;
    }
    out.push({ sheet: s.getAttribute('name') || '', rows: Array.from(rows, r => r || []) });
  }
  return out;
}
/** Chuyển dd/mm/yyyy hoặc số ngày Excel → yyyy-mm-dd */
export function toISODate(v: any): string | null {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'number') { const d = new Date(Math.round((v - 25569) * 86400000)); return d.toISOString().slice(0, 10); }
  const m = String(v).trim().match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})/);
  if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  const m2 = String(v).match(/^(\d{4})-(\d{2})-(\d{2})/); return m2 ? m2[0] : null;
}
