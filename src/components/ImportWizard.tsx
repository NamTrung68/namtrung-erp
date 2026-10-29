import React, { useMemo, useState } from 'react';
import { Button, cx, Modal, Select, toast } from './ui';
import { readTable, toISODate, writeXlsx } from '../lib/xlsx';
import { noAccent } from '../lib/format';

export interface ImportField { key: string; label: string; required?: boolean; aliases?: string[]; type?: 'text' | 'number' | 'date'; hint?: string }
const norm = (s: any) => noAccent(String(s ?? '')).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const toNumber = (v: any) => { if (typeof v === 'number') return v; const s = String(v ?? '').replace(/[^\d,.\-]/g, ''); if (!s) return null;
  const n = /^-?\d{1,3}([.,]\d{3})+$/.test(s) ? Number(s.replace(/[.,]/g, '')) : Number(s.replace(/\.(?=\d{3}\b)/g, '').replace(',', '.')); return Number.isFinite(n) ? n : null; };

/** Nhập file Excel/CSV: tự nhận dòng tiêu đề, tự ghép cột theo tên, cho chỉnh lại, xem trước rồi mới ghi */
export function ImportWizard({ open, onClose, title, fields, note, onImport, options, sampleName }: {
  open: boolean; onClose: () => void; title: string; fields: ImportField[]; note?: React.ReactNode; sampleName: string;
  options?: React.ReactNode; onImport: (rows: Record<string, any>[]) => Promise<React.ReactNode>;
}) {
  const [raw, setRaw] = useState<any[][] | null>(null); const [hdr, setHdr] = useState(0); const [map, setMap] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false); const [result, setResult] = useState<React.ReactNode>(null); const [fname, setFname] = useState('');
  const headers = raw ? (raw[hdr] || []).map((h, i) => [String(i), `${String.fromCharCode(65 + (i % 26))} · ${h ?? ''}`] as [string, string]) : [];
  const autoMap = (rows: any[][], h: number) => {
    const hs = (rows[h] || []).map(norm); const m: Record<string, string> = {};
    for (const f of fields) {
      const keys = [f.label, ...(f.aliases || [])].map(norm);
      let i = hs.findIndex(x => keys.includes(x)); if (i < 0) i = hs.findIndex(x => x && keys.some(k => x.includes(k) || k.includes(x)));
      if (i >= 0 && !Object.values(m).includes(String(i))) m[f.key] = String(i);
    }
    setMap(m);
  };
  const load = async (file: File) => {
    try {
      const rows = (await readTable(file)).filter(r => r && r.some(x => x !== null && x !== undefined && String(x).trim() !== ''));
      if (!rows.length) throw new Error('File trống');
      // dòng tiêu đề = dòng có nhiều ô chữ khớp tên trường nhất trong 10 dòng đầu
      let best = 0, score = -1;
      rows.slice(0, 10).forEach((r, i) => { const hs = r.map(norm); const s = fields.filter(f => [f.label, ...(f.aliases || [])].map(norm).some(k => hs.some(x => x && (x === k || x.includes(k))))).length; if (s > score) { score = s; best = i; } });
      setRaw(rows); setHdr(best); autoMap(rows, best); setFname(file.name); setResult(null);
    } catch (e) { toast.err(e); }
  };
  const mapped = useMemo(() => !raw ? [] : raw.slice(hdr + 1).map(r => {
    const o: Record<string, any> = {};
    for (const f of fields) { const i = map[f.key]; if (i === undefined || i === '') continue; let v = r[Number(i)];
      if (f.type === 'number') v = toNumber(v); else if (f.type === 'date') v = toISODate(v); else v = v === null || v === undefined ? '' : String(v).trim();
      o[f.key] = v; }
    return o;
  }).filter(o => Object.values(o).some(v => v !== '' && v !== null && v !== undefined)), [raw, hdr, map]);
  const missing = fields.filter(f => f.required && !map[f.key]);
  const reset = () => { setRaw(null); setMap({}); setResult(null); setFname(''); };
  const go = async () => { setBusy(true); try { setResult(await onImport(mapped)); } catch (e) { toast.err(e); } finally { setBusy(false); } };
  return (
    <Modal open={open} onClose={() => { reset(); onClose(); }} title={title} size="xl"
      footer={<>
        <Button className="mr-auto" size="sm" onClick={() => writeXlsx(sampleName, [fields.map(f => f.label)])}>⬇ Tải file mẫu</Button>
        {raw && <Button onClick={reset}>Chọn file khác</Button>}
        <Button variant="primary" loading={busy} disabled={!raw || !mapped.length || missing.length > 0} onClick={go}>Nhập {mapped.length ? `${mapped.length} dòng` : ''}</Button></>}>
      {note && <div className="mb-3 rounded-xl bg-brand-50 px-3 py-2 text-xs text-brand-900">{note}</div>}
      {!raw ? <label className="grid cursor-pointer place-items-center rounded-2xl border-2 border-dashed border-ink-200 px-4 py-12 text-center hover:border-brand-400 hover:bg-brand-50/40">
          <div className="text-3xl">📄</div><div className="mt-2 font-semibold">Chọn file Excel (.xlsx) hoặc .csv</div><div className="text-xs text-ink-500">Hệ thống tự nhận dòng tiêu đề và ghép cột theo tên</div>
          <input type="file" accept=".xlsx,.csv,.txt" className="hidden" onChange={e => { const f = e.target.files?.[0]; if (f) load(f); e.target.value = ''; }} /></label>
        : <div className="space-y-3">
          <div className="flex flex-wrap items-center gap-2 text-sm"><b>{fname}</b><span className="text-ink-500">· {raw.length - hdr - 1} dòng dữ liệu · tiêu đề ở dòng</span>
            <Select className="w-20" options={raw.slice(0, 10).map((_, i) => [String(i), String(i + 1)])} value={String(hdr)} onChange={v => { setHdr(Number(v)); autoMap(raw, Number(v)); }} />
            {options}</div>
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">{fields.map(f => (
            <label key={f.key} className={cx('rounded-xl border p-2 text-xs', map[f.key] ? 'border-emerald-200 bg-emerald-50/50' : f.required ? 'border-red-200 bg-red-50/50' : 'border-ink-200')}>
              <div className="mb-1 font-semibold">{f.label}{f.required && <span className="text-red-600"> *</span>}{f.hint && <span className="font-normal text-ink-400"> · {f.hint}</span>}</div>
              <Select options={headers} value={map[f.key] || ''} onChange={v => setMap(m => ({ ...m, [f.key]: v }))} placeholder="— Không lấy —" /></label>))}</div>
          {missing.length > 0 && <p className="text-sm text-red-600">Chưa chọn cột bắt buộc: {missing.map(f => f.label).join(', ')}</p>}
          <div className="max-h-56 overflow-auto rounded-xl border border-ink-200"><table className="w-full text-xs">
            <thead className="sticky top-0 bg-ink-50"><tr>{fields.filter(f => map[f.key]).map(f => <th key={f.key} className="whitespace-nowrap px-2 py-1.5 text-left font-semibold">{f.label}</th>)}</tr></thead>
            <tbody className="divide-y divide-ink-100">{mapped.slice(0, 8).map((o, i) => <tr key={i}>{fields.filter(f => map[f.key]).map(f => <td key={f.key} className="max-w-[220px] truncate px-2 py-1">{String(o[f.key] ?? '')}</td>)}</tr>)}</tbody>
          </table></div>
          <p className="text-xs text-ink-400">Xem trước 8 dòng đầu.</p>
          {result && <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm">{result}</div>}
        </div>}
    </Modal>
  );
}
