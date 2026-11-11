// Bản 40 — Chuyển phát HĐ đã ký (giai đoạn 1: nhập tay; giai đoạn 2 nối API ViettelPost)
//  · Chọn HĐ đã ký (tab Đã ký hoặc nút "+ Tạo phiếu gửi") → gom theo khách → 1 phiếu / khách
//  · Chờ gửi → Đã gửi (ngày gửi, mã vận đơn) → Khách đã nhận (báo sale nhắc khách gửi lại 1 bản, hạn = ngày nhận + 7)
//    → quá hạn chưa thu về: cảnh báo sale + quản lý mỗi sáng → "Đã thu về" từng HĐ → xong
//  · Phiếu Đã gửi / HĐ thu về tự cập nhật vết hồ sơ ở tab Đã ký (✉ đã gửi khách · ✓ đã có bản ký)
import React, { useEffect, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, NumInput, Select, StatusChips, Textarea, ask, toast, useAction, useLoad } from '../../components/ui';
import { CopyBtn } from '../../components/MstCheck';
import { db } from '../../lib/sb';
import { fmtDate, fmtDateTime, today } from '../../lib/format';
import { writeXlsx } from '../../lib/xlsx';
import { useApp } from '../../state';
import { ScanUpload, useIsAcc } from './HoSo';

export type ShipSt = 'cho_gui' | 'da_gui' | 'da_nhan' | 'da_thu' | 'hoan' | 'huy';
export const SHIP_ST: Record<ShipSt, [string, string]> = {
  cho_gui: ['Chờ gửi', 'amber'], da_gui: ['Đã gửi — đang giao', 'blue'], da_nhan: ['Khách đã nhận — chờ bản ký', 'purple'],
  da_thu: ['Đã thu về', 'green'], hoan: ['Hoàn / thất lạc', 'red'], huy: ['Đã hủy', 'gray'],
};
export const HANG: [string, string][] = [['viettelpost', 'ViettelPost'], ['khac', 'Hãng khác'], ['tay', 'Giao tay / nhân viên mang']];
const hangName = (h: string) => HANG.find(x => x[0] === h)?.[1] || h;
const sdtOk = (s: string) => /^0\d{9,10}$/.test(String(s || '').replace(/[\s.\-()]/g, '').replace(/^\+?84/, '0'));
const addDays = (d: string, n: number) => { const x = new Date(d + 'T00:00:00Z'); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };

/** Số liệu cho badge tab / menu */
export function useShipCounts(dep: any[] = []) {
  return useLoad(() => db.rpc<any>('out_ships_page', { p: { limit: 0 } }).then(r => r?.counts || {}).catch(() => ({})), dep);
}

// ================= Tạo phiếu =================
interface PrepRow { id: string; code: string; so_hd: string | null; ngay_hd: string | null; sale_id: string | null; customer_id: string | null; buyer_id: string | null; buyer_name: string | null; tax_code: string | null;
  kh_key: string; kh_name: string | null; username: string | null; nguoi_nhan: string | null; sdt: string | null; dia_chi: string | null; tu_phap_nhan: boolean; ship_code: string | null }
interface Grp { key: string; rows: PrepRow[]; khach: string; buyer_id: string | null; nguoi_nhan: string; sdt: string; dia_chi: string; note: string; luu: boolean }

/** Chọn HĐ → gom theo khách (cùng sale) → mỗi khách 1 phiếu; sửa người nhận trước khi tạo */
export function ShipCreate({ ids, onClose, onDone }: { ids: string[]; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const { busy, run } = useAction();
  const { data, loading, error } = useLoad(() => db.rpc<any>('out_ship_prep', { p_ids: ids }), [ids.join()]);
  const [groups, setGroups] = useState<Grp[]>([]);
  const [hang, setHang] = useState('viettelpost'); const [gui, setGui] = useState(false); const [ngay, setNgay] = useState(today()); const [mvd, setMvd] = useState<Record<string, string>>({});
  const rows: PrepRow[] = data?.rows || []; const cfg = data?.cfg || {};
  const busyRows = rows.filter(r => r.ship_code); const skip = ids.length - rows.length;
  useEffect(() => {
    if (!data) return; setHang(cfg.hang || 'viettelpost');
    const m = new Map<string, PrepRow[]>(); rows.filter(r => !r.ship_code).forEach(r => m.set(r.kh_key, [...(m.get(r.kh_key) || []), r]));
    setGroups(Array.from(m.entries()).map(([key, rs]) => { const h = rs.find(r => r.tu_phap_nhan) || rs.find(r => r.sdt) || rs[0];
      return { key, rows: rs, khach: h.buyer_name || h.kh_name || '', buyer_id: h.buyer_id, nguoi_nhan: h.nguoi_nhan || '', sdt: h.sdt || '', dia_chi: h.dia_chi || '', note: '', luu: !!h.buyer_id && !h.tu_phap_nhan }; }));
  }, [data]);
  const set = (k: string, p: Partial<Grp>) => setGroups(gs => gs.map(g => (g.key === k ? { ...g, ...p } : g)));
  const bad = (g: Grp) => !g.nguoi_nhan.trim() ? 'Thiếu người nhận' : !sdtOk(g.sdt) ? 'SĐT sai dạng' : g.dia_chi.trim().length < 10 ? 'Địa chỉ quá ngắn' : '';
  const nBad = groups.filter(bad).length;
  const save = () => run(async () => {
    const r = await db.rpc<any[]>('out_ship_create', { p: { groups: groups.map(g => ({ ids: g.rows.map(x => x.id), buyer_id: g.buyer_id, khach: g.khach, nguoi_nhan: g.nguoi_nhan, sdt: g.sdt, dia_chi: g.dia_chi,
      hang, gui, ngay_gui: gui ? ngay : null, ma_van_don: gui ? mvd[g.key] || null : null, note: g.note || null, luu: g.luu })) } });
    toast.ok(`Đã tạo ${r.length} phiếu chuyển phát: ${r.map(x => x.code).join(', ')}${gui ? ' — đã ghi ngày gửi' : ' — chờ gửi'}`); onDone();
  });
  return <Modal open size="lg" onClose={onClose} title={`Gửi chuyển phát · ${rows.length - busyRows.length} HĐ · ${groups.length} phiếu`} footer={<>
    <Button onClick={onClose}>Hủy</Button>
    <Button variant="primary" loading={busy} disabled={!groups.length || nBad > 0} onClick={save}>📦 Tạo {groups.length} phiếu{gui ? ' (đã gửi)' : ''}</Button></>}>
    {loading && !data ? <Loading /> : error ? <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{error}</div> : <>
      <div className="mb-3 rounded-xl bg-brand-50 px-3 py-2 text-xs text-brand-900">
        Mỗi khách 1 phiếu (HĐ của nhiều khách → nhiều phiếu). Người gửi: <b>{cfg.ten_gui || 'Nam Trung'}</b> — {cfg.dia_chi_gui || 'chưa cấu hình địa chỉ gửi'}{cfg.sdt_gui ? ' · ' + cfg.sdt_gui : ''}.
        Hạn thu về bản ký: <b>{cfg.so_ngay_thu || 7} ngày</b> sau ngày khách nhận.</div>
      {skip > 0 && <div className="mb-2 text-xs text-amber-700">{skip} HĐ bỏ qua (chưa ký hoặc không thuộc phạm vi của bạn).</div>}
      {busyRows.length > 0 && <div className="mb-2 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">Đã có phiếu, bỏ qua: {busyRows.map(r => `HĐ ${r.so_hd || r.code} (${r.ship_code})`).join(', ')}</div>}
      <div className="mb-3 grid gap-2 sm:grid-cols-[1fr_auto_auto] sm:items-end">
        <Field label="Hãng chuyển phát"><Select options={HANG} value={hang} onChange={setHang} /></Field>
        <label className="flex h-9 items-center gap-2 text-sm font-semibold"><input type="checkbox" className="h-4 w-4" checked={gui} onChange={e => setGui(e.target.checked)} /> Đã gửi luôn</label>
        {gui && <Field label="Ngày gửi"><Input type="date" max={today()} value={ngay} onChange={e => setNgay(e.target.value)} /></Field>}</div>
      {!groups.length && <Empty>Không có HĐ nào gửi được.</Empty>}
      <div className="space-y-3">{groups.map((g, i) => { const e = bad(g);
        return <div key={g.key} className={cx('rounded-2xl border p-3', e ? 'border-amber-300 bg-amber-50/40' : 'border-ink-200')}>
          <div className="mb-2 flex flex-wrap items-center gap-2 text-sm"><span className="flex h-6 w-6 items-center justify-center rounded-full bg-ink-900 text-[11px] font-bold text-white">{i + 1}</span>
            <b>{g.khach || '—'}</b>{g.rows[0].username && <Badge>{g.rows[0].username}</Badge>}
            {g.rows[0].sale_id && <span className="text-xs text-ink-500">Sale {a.personName(g.rows[0].sale_id)}</span>}
            <span className="ml-auto flex flex-wrap gap-1">{g.rows.map(r => <span key={r.id} className="rounded-md bg-ink-900 px-1.5 py-0.5 text-[11px] font-semibold text-white">HĐ {r.so_hd || r.code}</span>)}</span></div>
          <div className="grid gap-2 sm:grid-cols-[1.2fr_1fr_2.4fr]">
            <Input placeholder="Người nhận *" value={g.nguoi_nhan} onChange={x => set(g.key, { nguoi_nhan: x.target.value })} className={!g.nguoi_nhan.trim() ? 'border-amber-400' : ''} />
            <Input placeholder="SĐT người nhận *" inputMode="tel" value={g.sdt} onChange={x => set(g.key, { sdt: x.target.value })} className={!sdtOk(g.sdt) ? 'border-amber-400' : ''} />
            <Input placeholder="Địa chỉ nhận * (số nhà, đường, phường/xã, tỉnh/TP)" value={g.dia_chi} onChange={x => set(g.key, { dia_chi: x.target.value })} className={g.dia_chi.trim().length < 10 ? 'border-amber-400' : ''} /></div>
          <div className="mt-2 grid gap-2 sm:grid-cols-[1fr_1fr]">
            {gui && <Input placeholder="Mã vận đơn (nếu đã có)" value={mvd[g.key] || ''} onChange={x => setMvd(m => ({ ...m, [g.key]: x.target.value }))} />}
            <Input placeholder="Ghi chú (không bắt buộc)" value={g.note} onChange={x => set(g.key, { note: x.target.value })} /></div>
          <div className="mt-1.5 flex flex-wrap items-center gap-3 text-xs">
            {e && <span className="font-semibold text-amber-700">⚠ {e}</span>}
            {g.buyer_id ? <label className="flex items-center gap-1.5 text-ink-600"><input type="checkbox" checked={g.luu} onChange={x => set(g.key, { luu: x.target.checked })} /> Lưu người nhận vào Pháp nhân nhận HĐ (lần sau tự điền)</label>
              : <span className="text-ink-400">HĐ chưa gắn pháp nhân — người nhận chỉ lưu trên phiếu này</span>}</div>
        </div>; })}</div>
    </>}
  </Modal>;
}

/** Màn Chuyển phát: chọn HĐ đã ký chưa gửi để tạo phiếu */
function ShipPicker({ onClose, onPick }: { onClose: () => void; onPick: (ids: string[]) => void }) {
  const a = useApp(); const [q, setQ] = useState(''); const [qq, setQq] = useState(''); const [all, setAll] = useState(false); const [sel, setSel] = useState<Record<string, boolean>>({});
  useEffect(() => { const t = setTimeout(() => setQq(q), 300); return () => clearTimeout(t); }, [q]);
  const { data, loading } = useLoad(() => db.rpc<any[]>('out_ship_candidates', { p: { q: qq, all, limit: 500 } }), [qq, all]);
  const rows = data || []; const ids = rows.filter(r => sel[r.id]).map(r => r.id);
  return <Modal open size="lg" onClose={onClose} title="Chọn HĐ đã ký cần gửi" footer={<><Button onClick={onClose}>Hủy</Button>
    <Button variant="primary" disabled={!ids.length} onClick={() => onPick(ids)}>Tiếp tục ({ids.length} HĐ)</Button></>}>
    <div className="mb-2 flex flex-wrap items-center gap-2"><Input className="max-w-sm" autoFocus placeholder="🔎 Số HĐ, ID đơn, tên / MST / username khách…" value={q} onChange={e => setQ(e.target.value)} />
      <label className="flex items-center gap-1.5 text-xs text-ink-600"><input type="checkbox" checked={all} onChange={e => setAll(e.target.checked)} /> Gồm cả HĐ đã có bản ký</label>
      <label className="ml-auto flex items-center gap-1.5 text-xs font-semibold"><input type="checkbox" checked={rows.length > 0 && rows.every(r => sel[r.id])} onChange={e => setSel(e.target.checked ? Object.fromEntries(rows.map(r => [r.id, true])) : {})} /> Chọn tất cả ({rows.length})</label></div>
    <p className="mb-2 text-xs text-ink-500">Chỉ hiện HĐ đã ký, chưa nằm trong phiếu chuyển phát đang mở{all ? '' : ', chưa có bản ký thu về'}. Gõ username để lấy hết HĐ của 1 khách.</p>
    {loading && !data ? <Loading /> : !rows.length ? <Empty>Không có HĐ nào chờ gửi{qq ? ' khớp tìm kiếm' : ''}</Empty> :
      <div className="divide-y divide-ink-100 rounded-xl border border-ink-200">{rows.map(r => <label key={r.id} className={cx('flex cursor-pointer flex-wrap items-center gap-x-3 gap-y-0.5 px-3 py-2 text-sm hover:bg-ink-50', sel[r.id] && 'bg-brand-50/60')}>
        <input type="checkbox" className="h-4 w-4" checked={!!sel[r.id]} onChange={e => setSel(s => ({ ...s, [r.id]: e.target.checked }))} />
        <span className="w-24 font-bold">HĐ {r.so_hd || '—'}</span><span className="w-20 text-xs text-ink-500">{fmtDate(r.ngay_hd)}</span>
        <span className="min-w-[200px] flex-1"><span className="font-semibold">{r.buyer_name}</span> <span className="font-mono text-xs text-ink-500">{r.tax_code}</span>
          {r.username && <span className="ml-1 text-xs text-ink-500">· {r.username}</span>}{r.mds && <span className="ml-1 text-xs text-ink-400">· {r.mds}</span>}</span>
        <span className="text-xs text-ink-500">{a.personName(r.sale_id)}</span>
        {r.gui_at && <Badge color="purple">✉ đã gửi mail/tay</Badge>}</label>)}</div>}
  </Modal>;
}

// ================= Cập nhật trạng thái =================
type ActKind = 'gui' | 'nhan' | 'thu' | 'sua' | 'hoan' | 'huy';
function ActModal({ s, kind, items, onClose, onDone }: { s: any; kind: ActKind; items?: string[]; onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction();
  const [ngay, setNgay] = useState(today()); const [mvd, setMvd] = useState(s.ma_van_don || ''); const [note, setNote] = useState('');
  const [f, setF] = useState({ nguoi_nhan: s.nguoi_nhan || '', sdt: s.sdt || '', dia_chi: s.dia_chi || '', hang: s.hang || 'viettelpost', ma_van_don: s.ma_van_don || '', note: s.note || '' });
  const ttl: Record<ActKind, string> = { gui: '📤 Ghi nhận đã gửi', nhan: '📬 Khách đã nhận', thu: '✍ Đã thu về bản ký', sua: '✎ Sửa phiếu', hoan: '↩ Báo hoàn / thất lạc', huy: '✕ Hủy phiếu' };
  const nThu = items ? items.length : (s.items || []).filter((x: any) => !x.thu_at).length;
  const ok = () => run(async () => {
    if (kind === 'thu') await db.rpc('out_ship_thu', { p_id: s.id, p_ids: items || null, p_ngay: ngay, p_url: null, p_undo: false });
    else if (kind === 'sua') await db.rpc('out_ship_act', { p_id: s.id, p_act: 'sua', p: f });
    else await db.rpc('out_ship_act', { p_id: s.id, p_act: kind, p: { ngay, ma_van_don: mvd || null, note } });
    onDone();
  }, kind === 'nhan' ? 'Đã ghi ngày khách nhận — đã báo sale nhắc khách gửi lại bản ký' : kind === 'thu' ? `Đã xác nhận thu về ${nThu} HĐ` : 'Đã lưu');
  const minD = kind === 'nhan' || kind === 'thu' ? s.ngay_gui || undefined : undefined;
  return <Modal open size="sm" onClose={onClose} title={`${ttl[kind]} · ${s.code}`} footer={<><Button onClick={onClose}>Hủy</Button>
    <Button variant={kind === 'huy' || kind === 'hoan' ? 'danger' : 'primary'} loading={busy} disabled={(kind === 'hoan' && !note.trim()) || (kind === 'sua' && (!f.nguoi_nhan.trim() || !sdtOk(f.sdt) || f.dia_chi.trim().length < 10))} onClick={ok}>
      {kind === 'thu' ? `Xác nhận ${nThu} HĐ` : kind === 'huy' ? 'Hủy phiếu' : 'Lưu'}</Button></>}>
    <div className="space-y-3 text-sm">
      <div className="text-xs text-ink-600"><b>{s.khach || '—'}</b> · {s.nguoi_nhan} · {s.sdt}</div>
      {kind === 'sua' ? <>
        <Field label="Người nhận"><Input value={f.nguoi_nhan} onChange={e => setF({ ...f, nguoi_nhan: e.target.value })} /></Field>
        <Field label="SĐT"><Input value={f.sdt} onChange={e => setF({ ...f, sdt: e.target.value })} className={!sdtOk(f.sdt) ? 'border-amber-400' : ''} /></Field>
        <Field label="Địa chỉ nhận"><Textarea rows={2} value={f.dia_chi} onChange={e => setF({ ...f, dia_chi: e.target.value })} /></Field>
        <div className="grid grid-cols-2 gap-2"><Field label="Hãng"><Select options={HANG} value={f.hang} onChange={v => setF({ ...f, hang: v })} /></Field>
          <Field label="Mã vận đơn"><Input value={f.ma_van_don} onChange={e => setF({ ...f, ma_van_don: e.target.value })} /></Field></div>
        <Field label="Ghi chú"><Input value={f.note} onChange={e => setF({ ...f, note: e.target.value })} /></Field></> : <>
        {(kind === 'gui' || kind === 'nhan' || kind === 'thu') && <Field label={kind === 'gui' ? 'Ngày gửi' : kind === 'nhan' ? 'Ngày khách nhận' : 'Ngày nhận lại bản ký'}>
          <Input type="date" min={minD} max={today()} value={ngay} onChange={e => setNgay(e.target.value)} /></Field>}
        {(kind === 'gui' || kind === 'nhan') && <Field label="Mã vận đơn" hint={kind === 'gui' ? 'Có thể bổ sung sau' : undefined}><Input value={mvd} onChange={e => setMvd(e.target.value)} placeholder="VD: 1234567890" /></Field>}
        {kind === 'nhan' && <p className="rounded-lg bg-violet-50 px-3 py-2 text-xs text-violet-900">Hạn thu về bản ký: <b>{fmtDate(addDays(ngay, Number(s._cfg?.so_ngay_thu || 7)))}</b>. ERP báo sale ngay để nhắc khách ký và gửi lại 1 bản; quá hạn sẽ cảnh báo sale + quản lý mỗi sáng.</p>}
        {kind === 'thu' && <p className="text-xs text-ink-600">{items ? `HĐ: ${(s.items || []).filter((x: any) => items.includes(x.invoice_id)).map((x: any) => x.so_hd || x.code).join(', ')}` : `Tất cả ${nThu} HĐ còn lại của phiếu.`} Có bản scan thì bấm <b>📎 scan</b> trên từng HĐ của phiếu (kế toán) — lưu Drive và tự xác nhận thu về.</p>}
        {(kind === 'hoan' || kind === 'huy') && <Field label={kind === 'hoan' ? 'Lý do (bắt buộc)' : 'Lý do (không bắt buộc)'}><Input autoFocus value={note} onChange={e => setNote(e.target.value)} placeholder={kind === 'hoan' ? 'VD: sai địa chỉ, khách không nhận, thất lạc…' : ''} /></Field>}
        {kind === 'hoan' && <p className="text-xs text-ink-500">HĐ của phiếu được mở lại để tạo phiếu gửi mới.</p>}</>}
    </div></Modal>;
}

function ShipRow({ s, onAct, onChanged }: { s: any; onAct: (k: ActKind, items?: string[]) => void; onChanged: () => void }) {
  const a = useApp(); const { busy, run } = useAction(); const [menu, setMenu] = useState(false); const st = s.status as ShipSt;
  const acc = useIsAcc(); const [scan, setScan] = useState<any>(null); // bản 41: tải scan bản ký khách gửi lại → tự thu về
  const con = (s.items || []).filter((x: any) => !x.thu_at).length; const tong = (s.items || []).length;
  const lui = () => run(async () => { const n = await ask({ title: `Lùi trạng thái ${s.code}?`, message: 'Dùng khi bấm nhầm. Ngày đã ghi của bước hiện tại sẽ bị xóa.', input: { label: 'Ghi chú (không bắt buộc)' }, ok: 'Lùi' }); if (n === null) return;
    await db.rpc('out_ship_act', { p_id: s.id, p_act: 'lui', p: { note: n } }); onChanged(); }, 'Đã lùi trạng thái');
  const boThu = (id: string) => run(async () => { if (!(await ask({ title: 'Bỏ xác nhận thu về?', message: 'Dùng khi bấm nhầm.', ok: 'Bỏ xác nhận', danger: true }))) return;
    await db.rpc('out_ship_thu', { p_id: s.id, p_ids: [id], p_ngay: null, p_url: null, p_undo: true }); onChanged(); }, 'Đã bỏ xác nhận');
  const tone = s.qua_han ? 'border-red-300 bg-red-50/50' : s.sap_han ? 'border-amber-300 bg-amber-50/40' : 'border-ink-200 bg-white';
  const menuItems: [string, string, () => void][] = ([
    ['sua', '✎ Sửa người nhận / mã vận đơn', () => onAct('sua')],
    (st === 'da_gui' || st === 'da_nhan') && ['hoan', '↩ Báo hoàn / thất lạc', () => onAct('hoan')],
    (st === 'cho_gui' || st === 'da_gui') && ['huy', '✕ Hủy phiếu', () => onAct('huy')],
    ['da_gui', 'da_nhan', 'hoan', 'huy'].includes(st) && ['lui', st === 'hoan' || st === 'huy' ? '↶ Mở lại phiếu' : '↶ Lùi 1 bước (bấm nhầm)', lui],
  ].filter(Boolean) as [string, string, () => void][]).filter(x => !(st === 'huy' && x[0] === 'sua'));
  return <div className={cx('rounded-2xl border p-3 shadow-soft', tone)}>
    <div className="flex flex-wrap items-start gap-x-4 gap-y-2">
      <div className="w-32 shrink-0"><div className="text-[15px] font-bold text-ink-900">{s.code}</div>
        <Badge color={SHIP_ST[st]?.[1]}>{SHIP_ST[st]?.[0] || st}</Badge>
        {s.qua_han && <div className="mt-1 text-xs font-bold text-red-600">⏰ Trễ {s.tre} ngày</div>}
        {s.sap_han && <div className="mt-1 text-xs font-semibold text-amber-700">Sắp hạn {fmtDate(s.han_thu)}</div>}</div>
      <div className="min-w-[220px] flex-1">
        <div className="text-[15px] font-semibold leading-snug text-ink-900">{s.khach || '—'}{s.username && <span className="ml-1.5 text-xs font-normal text-ink-500">{s.username}</span>}</div>
        <div className="mt-0.5 text-xs text-ink-700">👤 <b>{s.nguoi_nhan}</b> · 📞 <a className="text-brand-700 hover:underline" href={'tel:' + s.sdt}>{s.sdt}</a></div>
        <div className="text-xs text-ink-500">📍 {s.dia_chi}</div>
        {s.sale_id && <div className="mt-0.5 text-xs text-ink-500">Sale <b className="text-ink-800">{a.personName(s.sale_id)}</b></div>}
        {s.note && <div className="mt-0.5 text-[11px] text-ink-400">{s.note}</div>}</div>
      <div className="w-44 text-xs">
        <div className="font-semibold text-ink-700">{hangName(s.hang)}</div>
        {s.ma_van_don ? <div className="flex items-center gap-1 font-mono text-ink-900">{s.ma_van_don}<CopyBtn text={s.ma_van_don} title="Copy mã vận đơn" /></div> : st !== 'cho_gui' && st !== 'huy' ? <div className="text-ink-400">chưa có mã vận đơn</div> : null}
        <div className="mt-1 grid grid-cols-[52px_1fr] gap-x-1 text-ink-600">
          <span>Gửi</span><b className="text-ink-800">{fmtDate(s.ngay_gui) || '—'}</b>
          <span>Nhận</span><b className="text-ink-800">{fmtDate(s.ngay_nhan) || '—'}</b>
          {s.han_thu && st !== 'da_thu' && <><span>Hạn thu</span><b className={s.qua_han ? 'text-red-600' : 'text-ink-800'}>{fmtDate(s.han_thu)}</b></>}
          {s.ngay_thu && <><span>Thu về</span><b className="text-emerald-700">{fmtDate(s.ngay_thu)}</b></>}</div>
        {s.canh_bao_n > 0 && st === 'da_nhan' && <div className="mt-0.5 text-[11px] text-red-600">Đã cảnh báo {s.canh_bao_n} lần · {fmtDateTime(s.canh_bao_at)}</div>}</div>
      <div className="flex w-full flex-col items-stretch gap-1.5 sm:w-auto sm:min-w-[170px]">
        {st === 'cho_gui' && <Button size="sm" variant="primary" onClick={() => onAct('gui')}>📤 Đã gửi</Button>}
        {st === 'da_gui' && <Button size="sm" variant="primary" onClick={() => onAct('nhan')}>📬 Khách đã nhận</Button>}
        {(st === 'da_gui' || st === 'da_nhan') && con > 0 && <Button size="sm" variant={st === 'da_nhan' ? 'success' : undefined} onClick={() => onAct('thu')}>✍ Thu về {con === tong ? 'tất cả' : `${con} HĐ còn lại`}</Button>}
        <div className="relative self-end">
          {menuItems.length > 0 && <button type="button" disabled={busy} className="rounded-md px-2 py-0.5 text-xs font-semibold text-ink-500 hover:bg-ink-100" onClick={() => setMenu(!menu)}>{busy ? '⏳' : '⋯ Khác'}</button>}
          {menu && <><div className="fixed inset-0 z-30" onClick={() => setMenu(false)} />
            <div className="absolute right-0 top-6 z-40 w-60 overflow-hidden rounded-xl border border-ink-200 bg-white text-xs shadow-xl">
              {menuItems.map(([k, l, f]) => <button key={k} className="block w-full px-3 py-2 text-left hover:bg-brand-50" onClick={() => { setMenu(false); f(); }}>{l}</button>)}</div></>}</div></div>
    </div>
    <div className="mt-2 flex flex-wrap gap-1.5 border-t border-ink-100 pt-2">{(s.items || []).map((x: any) => <span key={x.invoice_id} title={x.buyer_name + (x.thu_at ? `\nThu về ${fmtDate(x.thu_ngay)} · ${a.personName(x.thu_by)}` : '')}
      className={cx('inline-flex items-center gap-1 rounded-lg border px-2 py-0.5 text-[11.5px]', x.thu_at ? 'border-emerald-300 bg-emerald-50 text-emerald-800' : 'border-ink-200 bg-white text-ink-700')}>
      <b>HĐ {x.so_hd || x.code}</b>{x.ngay_hd && <span className="text-ink-400">{fmtDate(x.ngay_hd)}</span>}
      {x.thu_at ? <><span>✓ thu về {fmtDate(x.thu_ngay)}</span>{x.thu_url && <a href={x.thu_url} target="_blank" rel="noreferrer">📎</a>}<button className="text-ink-400 hover:text-red-600" title="Bỏ xác nhận (bấm nhầm)" onClick={() => boThu(x.invoice_id)}>↶</button></>
        : (st === 'da_gui' || st === 'da_nhan') && tong > 1 ? <button className="font-semibold text-emerald-700 hover:underline" onClick={() => onAct('thu', [x.invoice_id])}>✍ thu về</button> : null}
      {acc && st !== 'huy' && st !== 'cho_gui' && <button className="text-brand-700 hover:underline" title="Tải bản scan khách gửi lại (lưu Drive, tự xác nhận thu về)" onClick={() => setScan(x)}>📎 scan</button>}</span>)}</div>
    {scan && <ScanUpload target={{ inv: { id: scan.invoice_id, so_hd: scan.so_hd, buyer_name: scan.buyer_name, tax_code: scan.tax_code, ngay_hd: scan.ngay_hd } }} onClose={() => setScan(null)} onDone={() => { setScan(null); onChanged(); }} />}
  </div>;
}

// ================= Danh sách + bộ lọc =================
const FIELD: [string, string][] = [['gui', 'Ngày gửi'], ['nhan', 'Ngày khách nhận'], ['thu', 'Ngày thu về'], ['tao', 'Ngày tạo phiếu']];
const VIEW_KEY = 'nt_cp_view';
/** Dùng chung: tab "Chuyển phát HĐ" của sale và màn Chuyển phát của kế toán. sale = lọc sale từ ô chọn phía trên (tab sale) */
export function ShipList({ sale: saleProp, rev: revProp = 0, onChanged, canPick = true }: { sale?: string; rev?: number; onChanged?: () => void; canPick?: boolean }) {
  const a = useApp();
  const init = (() => { try { return JSON.parse(sessionStorage.getItem(VIEW_KEY) || '{}'); } catch { return {}; } })();
  const [st, setSt] = useState<string>(init.st ?? 'mo'); const [q, setQ] = useState(''); const [qq, setQq] = useState('');
  const [field, setField] = useState<string>(init.field || 'gui'); const [tu, setTu] = useState(''); const [den, setDen] = useState(''); const [sale, setSale] = useState('');
  const [rev, setRev] = useState(0); const reload = () => { setRev(x => x + 1); onChanged?.(); };
  const [act, setAct] = useState<{ s: any; kind: ActKind; items?: string[] } | null>(null); const [pick, setPick] = useState(false); const [create, setCreate] = useState<string[] | null>(null);
  const { busy, run } = useAction();
  useEffect(() => { const t = setTimeout(() => setQq(q), 300); return () => clearTimeout(t); }, [q]);
  useEffect(() => { try { sessionStorage.setItem(VIEW_KEY, JSON.stringify({ st, field })); } catch { /* */ } }, [st, field]);
  const sl = saleProp ?? sale;
  const p = { st, q: qq, sale: sl, field, tu, den };
  const { data, loading, error } = useLoad(() => db.rpc<any>('out_ships_page', { p: { ...p, limit: 300 } }), [JSON.stringify(p), rev, revProp]);
  const rows: any[] = data?.rows || []; const c = data?.counts || {}; const cfg = data?.cfg || {};
  const { data: saleOpts } = useLoad(() => saleProp === undefined && (a.seesTeam || a.isAdmin || a.has('ke_toan')) ? db.rpc<any[]>('out_sale_opts').catch(() => []) : Promise.resolve([]), []);
  const chips: [string, string, number, string][] = [
    ['mo', 'Đang theo dõi', c.mo ?? 0, 'dark'], ['cho_gui', 'Chờ gửi', c.cho_gui ?? 0, 'amber'], ['da_gui', 'Đã gửi — đang giao', c.da_gui ?? 0, 'blue'],
    ['da_nhan', 'Khách đã nhận', c.da_nhan ?? 0, 'purple'], ['sap_han', `Sắp hạn (≤ ${cfg.sap_han ?? 2} ngày)`, c.sap_han ?? 0, 'amber'], ['qua_han', '⏰ Quá hạn thu về', c.qua_han ?? 0, 'red'],
    ['da_thu', 'Đã thu về', c.da_thu ?? 0, 'green'], ['hoan', 'Hoàn / thất lạc', c.hoan ?? 0, 'red'], ['huy', 'Đã hủy', c.huy ?? 0, 'gray'], ['', 'Tất cả', c.tat_ca ?? 0, 'gray'],
  ];
  const exportX = () => run(async () => {
    const all: any[] = (await db.rpc<any>('out_ships_page', { p: { ...p, limit: 1000 } })).rows || [];
    const head = ['Mã phiếu', 'Trạng thái', 'Khách', 'Username', 'Sale', 'Người nhận', 'SĐT', 'Địa chỉ', 'Hãng', 'Mã vận đơn', 'Ngày gửi', 'Ngày khách nhận', 'Hạn thu về', 'Trễ (ngày)', 'Ngày thu về', 'Số HĐ', 'HĐ chưa thu về', 'Ghi chú'];
    const d = (x: any) => (x ? fmtDate(x) : '');
    await writeXlsx('Chuyen_phat_HD_' + today(), [head, ...all.map(s => [s.code, SHIP_ST[s.status as ShipSt]?.[0] || s.status, s.khach || '', s.username || '', a.personName(s.sale_id), s.nguoi_nhan, s.sdt, s.dia_chi, hangName(s.hang),
      s.ma_van_don || '', d(s.ngay_gui), d(s.ngay_nhan), d(s.han_thu), s.tre ?? '', d(s.ngay_thu), (s.items || []).map((x: any) => x.so_hd || x.code).join(', '),
      (s.items || []).filter((x: any) => !x.thu_at).map((x: any) => x.so_hd || x.code).join(', '), s.note || ''])], 'Chuyen phat', true, { fmt: { 1: 'plain', 6: 'plain', 9: 'plain' } });
  }, 'Đã xuất Excel');
  return <>
    <div className="mb-3 rounded-xl bg-ink-50 px-3 py-2 text-xs text-ink-600">
      Gửi bản cứng HĐ đã ký cho khách → khách nhận → sale nhắc khách <b>gửi lại 1 bản</b> trong <b>{cfg.so_ngay_thu ?? 7} ngày</b> → quá hạn ERP cảnh báo sale + quản lý mỗi sáng (nhắc lại {cfg.nhac_lai ?? 3} ngày/lần) → nhận về bấm <b>✍ Thu về</b>.
      Tạo phiếu: tick HĐ ở tab <b>Đã ký</b> → <b>📦 Gửi chuyển phát</b>{canPick ? <>, hoặc bấm <b>+ Tạo phiếu gửi</b></> : ''}.</div>
    <StatusChips items={chips} value={st} onChange={setSt} />
    <div className="mb-3 flex flex-wrap items-end gap-2">
      <Input className="max-w-xs" placeholder="🔎 Mã phiếu, mã vận đơn, số HĐ, khách, SĐT…" value={q} onChange={e => setQ(e.target.value)} />
      {saleProp === undefined && (saleOpts || []).length > 1 && <Select className="w-44" placeholder="Tất cả sale" options={[['', 'Tất cả sale'], ...(saleOpts || []).map((x: any) => [x.id, x.full_name] as [string, string])]} value={sale} onChange={setSale} />}
      <Select className="w-40" options={FIELD} value={field} onChange={setField} />
      <Input type="date" className="w-36" value={tu} onChange={e => setTu(e.target.value)} title="Từ ngày" />
      <Input type="date" className="w-36" value={den} onChange={e => setDen(e.target.value)} title="Đến ngày" />
      {(tu || den || q || st !== 'mo' || sale) && <button className="h-9 text-xs text-ink-500 underline" onClick={() => { setTu(''); setDen(''); setQ(''); setSt('mo'); setSale(''); }}>Xóa lọc</button>}
      <div className="ml-auto flex gap-2"><Button loading={busy} onClick={exportX}>⬇ Excel</Button>
        {canPick && <Button variant="primary" onClick={() => setPick(true)}>+ Tạo phiếu gửi</Button>}</div></div>
    {loading && !data ? <Loading /> : error ? <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{error}</div> : !rows.length ? <Card><Empty>Không có phiếu chuyển phát nào{st || qq || tu || den ? ' khớp bộ lọc' : ''}</Empty></Card> :
      <div className="space-y-2">{rows.map(s => <ShipRow key={s.id} s={s} onAct={(kind, items) => setAct({ s: { ...s, _cfg: cfg }, kind, items })} onChanged={reload} />)}
        {data.total > rows.length && <div className="text-center text-xs text-ink-500">Đang hiện {rows.length}/{data.total} — lọc để thu hẹp</div>}</div>}
    {act && <ActModal s={act.s} kind={act.kind} items={act.items} onClose={() => setAct(null)} onDone={() => { setAct(null); reload(); }} />}
    {pick && <ShipPicker onClose={() => setPick(false)} onPick={ids => { setPick(false); setCreate(ids); }} />}
    {create && <ShipCreate ids={create} onClose={() => setCreate(null)} onDone={() => { setCreate(null); reload(); }} />}
  </>;
}

/** Màn Chuyển phát HĐ (#/hd/cp) — kế toán, quản lý, sale */
export default function ChuyenPhat() {
  const a = useApp();
  if (!a.isSales && !a.isLead && !a.isAdmin && !a.has('ke_toan', 'bgd')) return <Layout title="Chuyển phát HĐ"><Card>Dành cho Kinh doanh, Kế toán, BGĐ.</Card></Layout>;
  return <Layout title="Chuyển phát HĐ đã ký"><ShipList /></Layout>;
}

/** Cấu hình (Cấu hình → Kế toán – Hóa đơn) */
export function ShipCfg({ v, set }: { v: any; set: (k: string) => (x: any) => void }) {
  return <div className="grid gap-3 sm:grid-cols-2">
    <Field label="Tên người gửi"><Input value={v.ten_gui || ''} onChange={e => set('ten_gui')(e.target.value)} /></Field>
    <Field label="SĐT người gửi"><Input value={v.sdt_gui || ''} onChange={e => set('sdt_gui')(e.target.value)} placeholder="Số liên hệ khi bưu tá lấy hàng" /></Field>
    <Field label="Địa chỉ gửi" className="sm:col-span-2"><Input value={v.dia_chi_gui || ''} onChange={e => set('dia_chi_gui')(e.target.value)} /></Field>
    <Field label="Hãng mặc định"><Select options={HANG} value={v.hang || 'viettelpost'} onChange={set('hang')} /></Field>
    <Field label="Hạn thu về bản ký (ngày sau ngày khách nhận)"><NumInput value={v.so_ngay_thu ?? 7} onChange={x => set('so_ngay_thu')(x ?? 7)} /></Field>
    <Field label="Nhắc lại khi quá hạn (mỗi … ngày)"><NumInput value={v.nhac_lai ?? 3} onChange={x => set('nhac_lai')(x ?? 3)} /></Field>
    <Field label="“Sắp hạn” khi còn ≤ … ngày"><NumInput value={v.sap_han ?? 2} onChange={x => set('sap_han')(x ?? 2)} /></Field>
  </div>;
}
