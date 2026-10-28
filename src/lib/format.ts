export const money = (v: any, unit = '') => {
  const n = Number(v);
  if (!Number.isFinite(n)) return '';
  return Math.round(n).toLocaleString('vi-VN') + unit;
};
export const num = (v: any, d = 2) => {
  const n = Number(v);
  return Number.isFinite(n) ? n.toLocaleString('vi-VN', { maximumFractionDigits: d }) : '';
};
export const toNum = (v: any) => {
  if (typeof v === 'number') return v;
  const s = String(v ?? '').trim().replace(/\s/g, '');
  if (!s) return 0;
  // chấp nhận 1.000.000 hoặc 1,000,000 hoặc 1,5
  const norm = /^\d{1,3}(\.\d{3})+(,\d+)?$/.test(s) ? s.replace(/\./g, '').replace(',', '.') : s.replace(/,(?=\d{3}\b)/g, '').replace(',', '.');
  const n = parseFloat(norm);
  return Number.isFinite(n) ? n : 0;
};
const tz = 'Asia/Ho_Chi_Minh';
export const fmtDate = (v: any) => (v ? new Date(String(v).length === 10 ? v + 'T00:00:00+07:00' : v).toLocaleDateString('vi-VN', { timeZone: tz, day: '2-digit', month: '2-digit', year: 'numeric' }) : '');
export const fmtDateTime = (v: any) => (v ? new Date(v).toLocaleString('vi-VN', { timeZone: tz, hour: '2-digit', minute: '2-digit', day: '2-digit', month: '2-digit', year: 'numeric' }) : '');
export const fmtTime = (v: any) => (v ? new Date(v).toLocaleTimeString('vi-VN', { timeZone: tz, hour: '2-digit', minute: '2-digit' }) : '');
export const today = () => new Date().toLocaleDateString('sv-SE', { timeZone: tz });
export const addDays = (d: string, n: number) => { const x = new Date(d + 'T00:00:00Z'); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
export const monthStart = (d = today()) => d.slice(0, 8) + '01';
export const monthEnd = (d = today()) => { const x = new Date(d.slice(0, 8) + '01T00:00:00Z'); x.setUTCMonth(x.getUTCMonth() + 1); x.setUTCDate(0); return x.toISOString().slice(0, 10); };
export const weekStart = (d = today()) => { const x = new Date(d + 'T00:00:00Z'); const w = (x.getUTCDay() + 6) % 7; x.setUTCDate(x.getUTCDate() - w); return x.toISOString().slice(0, 10); };
export const daysBetween = (a: string, b: string) => Math.round((new Date(b + 'T00:00:00Z').getTime() - new Date(a + 'T00:00:00Z').getTime()) / 86400000);
export const stripVN = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D');
export function downloadCSV(name: string, rows: any[][]) {
  const esc = (v: any) => { const s = v === null || v === undefined ? '' : String(v); return /[",\n;]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  const blob = new Blob(['﻿' + rows.map(r => r.map(esc).join(',')).join('\r\n')], { type: 'text/csv;charset=utf-8' });
  downloadBlob(name.endsWith('.csv') ? name : name + '.csv', blob);
}
export function downloadBlob(name: string, blob: Blob) {
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
export async function copyTable(rows: any[][]) {
  await navigator.clipboard.writeText(rows.map(r => r.map(v => String(v ?? '').replace(/\t|\n/g, ' ')).join('\t')).join('\n'));
}
export async function copyText(s: string) {
  try { await navigator.clipboard.writeText(s); }
  catch { const t = document.createElement('textarea'); t.value = s; t.style.position = 'fixed'; t.style.opacity = '0'; document.body.appendChild(t); t.select(); document.execCommand('copy'); t.remove(); }
}
export const tsv = (rows: any[][]) => rows.map(r => r.map(v => String(v ?? '').replace(/\t|\r?\n/g, ' ')).join('\t')).join('\n');
export const noAccent = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D');
