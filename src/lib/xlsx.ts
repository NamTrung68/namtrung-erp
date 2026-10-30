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

/** Đọc file bảng: .xlsx (sheet đầu có dữ liệu) hoặc .csv */
export async function readTable(file: File): Promise<any[][]> {
  if (/\.(csv|txt)$/i.test(file.name)) {
    const text = (await file.text()).replace(/^﻿/, ''); const sep = (text.split('\n')[0].match(/;/g) || []).length > (text.split('\n')[0].match(/,/g) || []).length ? ';' : text.includes('\t') ? '\t' : ',';
    const rows: any[][] = []; let row: string[] = [], cur = '', q = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (q) { if (ch === '"' && text[i + 1] === '"') { cur += '"'; i++; } else if (ch === '"') q = false; else cur += ch; }
      else if (ch === '"') q = true; else if (ch === sep) { row.push(cur); cur = ''; }
      else if (ch === '\n') { row.push(cur.replace(/\r$/, '')); rows.push(row); row = []; cur = ''; } else cur += ch;
    }
    if (cur || row.length) { row.push(cur); rows.push(row); }
    return rows;
  }
  const sheets = await readXlsx(file);
  return (sheets.find(s => s.rows.some(r => r.filter(x => x !== null && x !== undefined && x !== '').length > 1)) || sheets[0])?.rows || [];
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '');
const colName = (i: number) => { let s = ''; i++; while (i) { const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = Math.floor((i - 1) / 26); } return s; };
/** Ghi file .xlsx 1 sheet (dòng đầu là tiêu đề, in đậm, cố định) */
export async function writeXlsx(name: string, rows: any[][], sheet = 'Data', download = true): Promise<Blob> {
  const { makeZip } = await import('./zip');
  const widths = (rows[0] || []).map((_, j) => Math.min(60, Math.max(8, ...rows.slice(0, 200).map(r => String(r[j] ?? '').length + 2))));
  const body = rows.map((r, i) => `<row r="${i + 1}">${r.map((v, j) => {
    const ref = colName(j) + (i + 1); const st = i === 0 ? ' s="1"' : '';
    if (v === null || v === undefined || v === '') return '';
    if (typeof v === 'number' && Number.isFinite(v)) return `<c r="${ref}"${st}><v>${v}</v></c>`;
    return `<c r="${ref}" t="inlineStr"${st}><is><t xml:space="preserve">${esc(String(v))}</t></is></c>`;
  }).join('')}</row>`).join('');
  const x = (s: string) => new Blob([s], { type: 'application/xml' });
  const files = [
    { name: '[Content_Types].xml', data: x('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>') },
    { name: '_rels/.rels', data: x('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>') },
    { name: 'xl/workbook.xml', data: x(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="${esc(sheet.slice(0, 31))}" sheetId="1" r:id="rId1"/></sheets></workbook>`) },
    { name: 'xl/_rels/workbook.xml.rels', data: x('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>') },
    { name: 'xl/styles.xml', data: x('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE8E3FF"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf/><xf fontId="1" fillId="2" applyFont="1" applyFill="1"/></cellXfs></styleSheet>') },
    { name: 'xl/worksheets/sheet1.xml', data: x(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols>${widths.map((w, j) => `<col min="${j + 1}" max="${j + 1}" width="${w}" customWidth="1"/>`).join('')}</cols><sheetData>${body}</sheetData></worksheet>`) },
  ];
  const out = new Blob([await makeZip(files)], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
  if (download) { const a = document.createElement('a'); a.href = URL.createObjectURL(out);
    a.download = name.endsWith('.xlsx') ? name : name + '.xlsx'; document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000); }
  return out;
}
