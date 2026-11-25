// Bản 60 — Admin / BGĐ sửa trực tiếp dòng đối soát xe APT (sửa đúng để HĐ chính thức APT về tự khớp)
//  Máy chủ (acc_line_admin_edit) kiểm quyền, tính lại biên / tiền / giá đề xuất, ghi nhật ký, đồng bộ HĐ đầu vào, chặn phiếu đã gửi.
import React, { useMemo, useState } from 'react';
import { Button, cx, Field, Input, Modal, Select, Textarea, toast, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { money, num } from '../../lib/format';
import { useApp } from '../../state';
import { bienTone, pctTxt, useAccCfg } from './common';
import { useSaleMatcher } from './Acc';

type Kind = 'text' | 'num' | 'pct' | 'sale' | 'up';
interface Def { k: string; l: string; kind: Kind; hint?: string; wide?: boolean; show?: (l: any) => boolean }
/** Nhãn từng trường sửa được (dùng chung cho nhật ký) */
export const FIELD_LBL: Record<string, string> = {
  sale_id: 'Sale', md: 'Mã đơn MD', ma_kh: 'Khách (username)', ma_dong: 'Mã khai báo', ten_apt: 'Tên hàng APT', sl_apt: 'SL APT', sl_tk: 'SL tờ khai',
  gia_nhap: 'Giá APT (nháp)', gia_note: 'Giá NOTE', gia_khach: 'Giá xuất khách', vat: 'Thuế VAT', nk_ht: 'Thuế NK hệ thống', nk_tk: 'Thuế NK tờ khai',
};
const PCT = new Set(['vat', 'nk_ht', 'nk_tk']);
const GROUPS: { t: string; sub: string; f: Def[] }[] = [
  { t: 'A. Để HĐ chính thức APT tự khớp', sub: 'HĐ về được ghép theo Tên hàng APT + SL, rồi đối chiếu SL, đơn giá, thuế suất. Sửa đúng theo HĐ thật thì HĐ về không bị khóa lệch.', f: [
    { k: 'ten_apt', l: FIELD_LBL.ten_apt, kind: 'text', wide: true },
    { k: 'sl_apt', l: FIELD_LBL.sl_apt, kind: 'num' }, { k: 'gia_nhap', l: FIELD_LBL.gia_nhap, kind: 'num' },
    { k: 'gia_note', l: FIELD_LBL.gia_note, kind: 'num', hint: 'Giá sale ghi NOTE — để trống nếu không có' }, { k: 'vat', l: FIELD_LBL.vat + ' (%)', kind: 'pct' }] },
  { t: 'B. Chuyển sang HĐ đầu ra', sub: 'Đi vào phiếu xuất HĐ, pháp nhân, hoa hồng sale. Mã hàng ERP = {Mã khai báo}-{số HĐ}.', f: [
    { k: 'sale_id', l: FIELD_LBL.sale_id, kind: 'sale' }, { k: 'md', l: FIELD_LBL.md, kind: 'up', hint: 'VD: MD2650' },
    { k: 'ma_kh', l: FIELD_LBL.ma_kh, kind: 'text' }, { k: 'ma_dong', l: FIELD_LBL.ma_dong, kind: 'up' },
    { k: 'gia_khach', l: FIELD_LBL.gia_khach + ' (đ/đv)', kind: 'num' }] },
  { t: 'C. Tham khảo', sub: 'Chỉ ảnh hưởng biên APT / cảnh báo thuế.', f: [
    { k: 'nk_ht', l: FIELD_LBL.nk_ht + ' (%)', kind: 'pct' }, { k: 'nk_tk', l: FIELD_LBL.nk_tk + ' (%)', kind: 'pct', show: l => l.tk_row != null || l.nk_tk != null },
    { k: 'sl_tk', l: FIELD_LBL.sl_tk, kind: 'num', show: l => l.tk_row != null || l.sl_tk != null }] },
];
const DON = new Set(['sale_id', 'ma_kh', 'md']);

const toForm = (k: string, v: any): string => v === null || v === undefined ? '' : PCT.has(k) ? String(Math.round(Number(v) * 10000) / 100) : String(v);
/** Số nhập tay: dấu phẩy = thập phân; giá tiền viết "1.250.000" (nhóm 3 số) hiểu là phân cách nghìn */
const numOf = (s: string, gia = false) => { let t = s.trim().replace(/\s/g, ''); if (!t) return null;
  if (gia && /^\d{1,3}(\.\d{3})+(,\d+)?$/.test(t)) t = t.replace(/\./g, '');
  const x = Number(t.replace(',', '.')); return Number.isFinite(x) ? x : NaN; };
/** Giá trị gửi máy chủ (null = để trống) */
function toVal(k: string, s: string): any {
  if (['sl_apt', 'sl_tk', 'gia_nhap', 'gia_note', 'gia_khach'].includes(k)) return numOf(s, k.startsWith('gia_'));
  if (PCT.has(k)) { const x = numOf(s); return x === null || Number.isNaN(x) ? x : Math.round(x * 100) / 10000; }
  const t = s.trim(); return t ? (k === 'md' || k === 'ma_dong' ? t.toUpperCase() : t) : null;
}
const same = (a: any, b: any) => (a === null || a === undefined || a === '') && (b === null || b === undefined || b === '') ? true : typeof b === 'number' ? Number(a) === b : String(a ?? '').trim() === String(b ?? '').trim();
/** Hiển thị 1 giá trị theo trường */
export const fmtField = (k: string, v: any, name: (id: string) => string) => v === null || v === undefined || v === '' ? '(trống)' : k === 'sale_id' ? name(v) || v : PCT.has(k) ? pctTxt(v) : (typeof v === 'number' || /^\d+(\.\d+)?$/.test(String(v))) && !['ma_kh', 'md', 'ma_dong', 'ten_apt'].includes(k) ? num(v, 4) : String(v);

export function EditLineModal({ line: l, onClose, onDone }: { line: any; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const cfg = useAccCfg(); const sm = useSaleMatcher(); const { busy, run } = useAction();
  const init = useMemo(() => Object.fromEntries(Object.keys(FIELD_LBL).map(k => [k, toForm(k, l[k])])), [l]);
  const [f, setF] = useState<Record<string, string>>(init); const [note, setNote] = useState(''); const [don, setDon] = useState(true);
  const { data: sameMd } = useLoad(() => l.md ? db.from<any[]>('acc_lines').select('id').eq('truck_id', l.truck_id).eq('md', l.md).limit(500) : Promise.resolve([]), [l.id]);
  const nDon = (sameMd || []).length;
  const patch: Record<string, any> = {}; const bad: string[] = [];
  Object.keys(FIELD_LBL).forEach(k => { if (f[k] === init[k]) return; const v = toVal(k, f[k]); if (typeof v === 'number' && Number.isNaN(v)) { bad.push(FIELD_LBL[k]); return; } if (!same(l[k], v)) patch[k] = v; });
  const keys = Object.keys(patch); const donKeys = keys.filter(k => DON.has(k));
  // xem trước biên NT sau khi sửa (cùng công thức máy chủ)
  const v = (k: string) => (k in patch ? patch[k] : l[k]);
  const ga = Number(v('gia_note')) || Number(v('gia_nhap')) || 0, gk = Number(v('gia_khach')) || 0, sl = Number(v('sl_apt') ?? l.sl_ht) || 0;
  const bien = gk && ga ? gk / ga - 1 : null; const giaDoi = keys.some(k => ['gia_nhap', 'gia_note', 'gia_khach'].includes(k));
  const traSale = giaDoi && l.status === 'ok' && l.luong === 'A' && l.apt_stt != null && (!gk || (bien !== null && (bien < cfg.bien_nt_min - (cfg.dung_sai_bien || 0) || bien > Math.max(cfg.bien_nt_max, cfg.bien_chan_max ?? 0.07) + (cfg.dung_sai_bien || 0))));
  const sales: [string, string][] = useMemo(() => { const m = new Map<string, string>((sm.dir || []).map(p => [p.id, p.full_name])); if (l.sale_id && !m.has(l.sale_id)) m.set(l.sale_id, a.personName(l.sale_id) || '(nhân sự hiện tại)');
    return Array.from(m.entries()).sort((x, y) => x[1].localeCompare(y[1], 'vi')); }, [sm.dir, l.sale_id]);
  const save = () => run(async () => {
    if (bad.length) throw new Error('Không phải số: ' + bad.join(', '));
    if (!keys.length) throw new Error('Chưa sửa gì');
    if (!note.trim()) throw new Error('Nhập lý do sửa');
    const r = await db.rpc<{ n: number; warn: string[] }>('acc_line_admin_edit', { p_id: l.id, p_patch: patch, p_note: note.trim(), p_cung_don: don && donKeys.length > 0 && nDon > 1 });
    toast.ok(`Đã sửa ${r?.n ?? 1} dòng`); (r?.warn || []).forEach(w => toast.info(w));
    onDone();
  });
  const inp = (d: Def) => {
    const ch = f[d.k] !== init[d.k] && (d.k in patch); const set = (x: string) => setF(o => ({ ...o, [d.k]: x }));
    const nv = toVal(d.k, f[d.k]);
    const cur = <span className="text-ink-400">hiện: {fmtField(d.k, l[d.k], a.personName)} → mới: <b className="text-brand-700">{typeof nv === 'number' && Number.isNaN(nv) ? 'không phải số' : fmtField(d.k, nv, a.personName)}</b></span>;
    return <Field key={d.k} className={d.wide ? 'sm:col-span-2' : ''} label={<span className={cx(ch && 'font-semibold text-brand-700')}>{d.l}{ch ? ' ✎' : ''}</span>} hint={ch ? cur : d.hint}>
      {d.kind === 'sale' ? <Select value={f[d.k]} onChange={set} placeholder="— Chọn sale —" options={sales} />
        : <Input value={f[d.k]} inputMode={d.kind === 'num' || d.kind === 'pct' ? 'decimal' : undefined} className={cx(ch && 'border-brand-400 bg-brand-50')}
            onChange={e => set(d.kind === 'up' ? e.target.value.toUpperCase() : e.target.value)} />}</Field>;
  };
  return <Modal open onClose={onClose} size="lg" title={<span>✎ Admin sửa dòng · {l.ma_dong || l.md || 'không có đơn'} · STT APT {l.apt_stt ?? '—'}</span>}
    footer={<><span className="mr-auto text-xs text-ink-500">{keys.length ? `${keys.length} trường thay đổi` : 'Chưa sửa gì'}</span>
      <Button onClick={onClose}>Hủy</Button><Button variant="primary" loading={busy} disabled={!keys.length || !note.trim() || bad.length > 0} onClick={save}>Lưu thay đổi</Button></>}>
    {l.inv_no || l.status === 'approved' ? <div className="mb-3 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-900">Dòng đã có HĐ / đã duyệt giá — sửa xong hệ thống đối chiếu lại với HĐ chính thức. Dòng nằm trong phiếu xuất HĐ đã gửi kế toán / xuất nháp / ký sẽ bị chặn.</div> : null}
    <div className="space-y-4">{GROUPS.map(g => { const fs = g.f.filter(d => !d.show || d.show(l)); return <div key={g.t} className="rounded-xl border border-ink-200 p-3">
      <div className="text-sm font-bold text-ink-800">{g.t}</div><div className="mb-2 text-[11px] text-ink-500">{g.sub}</div>
      <div className="grid gap-3 sm:grid-cols-2">{fs.map(inp)}</div></div>; })}</div>
    {donKeys.length > 0 && nDon > 1 && <label className="mt-3 flex items-start gap-2 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm">
      <input type="checkbox" className="mt-1" checked={don} onChange={e => setDon(e.target.checked)} />
      <span><b>Sửa theo cả đơn {l.md}</b> — áp {donKeys.map(k => FIELD_LBL[k]).join(', ')} cho cả {nDon} dòng của đơn trong xe này.<div className="text-xs text-ink-500">Các trường khác chỉ áp cho dòng đang mở.</div></span></label>}
    {giaDoi && <div className={cx('mt-3 rounded-xl border p-3 text-sm', traSale ? 'border-red-200 bg-red-50 text-red-800' : 'border-ink-200 bg-ink-50')}>
      Sau khi sửa: biên NT <b className={bienTone(bien, cfg.bien_nt_min, cfg.bien_nt_max, cfg.bien_chan_max)}>{bien === null ? '—' : pctTxt(bien)}</b>
      {' '}(cũ {pctTxt(l.bien_nt) || '—'}) · tiền APT {money(Math.round(ga * sl))} · tiền khách {gk ? money(Math.round(gk * sl)) : '—'}
      {traSale && <div className="mt-1 font-semibold">Biên ngoài khung / giá khách 0 → dòng sẽ bị trả lại sale.</div>}</div>}
    <Field className="mt-3" label="Lý do sửa *" hint="Ghi vào nhật ký dòng và thông báo cho sale"><Textarea rows={2} value={note} onChange={e => setNote(e.target.value)} placeholder="VD: Up nhầm giá khách / sai sale của đơn" /></Field>
  </Modal>;
}

/** Các trường Admin đã sửa tay (gốc file → hiện tại) */
export function ManualBox({ l }: { l: any }) {
  const a = useApp(); const m = l.manual || {}; const ks = Object.keys(m); if (!ks.length) return null;
  return <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm"><b>✎ Admin đã sửa tay</b> <span className="text-xs text-ink-500">(nạp lại file vẫn giữ)</span>
    {ks.map(k => <div key={k} className="text-xs">{FIELD_LBL[k] || k}: <span className="text-ink-500 line-through">{fmtField(k, m[k].goc, a.personName)}</span> → <b>{fmtField(k, m[k].moi, a.personName)}</b>
      <span className="text-ink-400"> · {a.personName(m[k].by)}</span></div>)}</div>;
}

/** Dòng nhật ký "admin_edit": liệt kê trường cũ → mới */
export function editLog(e: any, name: (id: string) => string): string | null {
  const t = e?.data?.thay_doi; if (e.action !== 'admin_edit' || !t) return null;
  return 'Admin sửa' + (e.data.cung_don ? ' (theo cả đơn)' : '') + ': ' + Object.entries(t).map(([k, x]: any) => `${FIELD_LBL[k] || k} ${fmtField(k, x.cu, name)} → ${fmtField(k, x.moi, name)}`).join('; ');
}
