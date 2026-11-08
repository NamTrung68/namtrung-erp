// Bản 35 — Ô kiểm tra MST: gõ MST → tra cứu → tự điền tên + địa chỉ theo đăng ký thuế, kèm cảnh báo
import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { cx } from './ui';
import { localWarnings, lookupMst, mstForm, mstLevel, nameDiff, PROVIDER, type MstResult } from '../lib/mst';

const TONE = { red: 'border-red-300 bg-red-50 text-red-900', amber: 'border-amber-300 bg-amber-50 text-amber-900', green: 'border-emerald-200 bg-emerald-50 text-emerald-900', '': 'border-ink-200 bg-ink-50 text-ink-700' };

/** autoFill: tự điền khi MST vừa được gõ / đổi (không đè thông tin phiếu cũ lúc mới mở) */
export function MstCheck({ mst, name, address, onApply, onResult, autoFill = true, className }: {
  mst: string; name: string; address: string; onApply: (v: { name: string; address: string }) => void; onResult?: (r: MstResult | null) => void; autoFill?: boolean; className?: string;
}) {
  const [r, setR] = useState<MstResult | null>(null); const [busy, setBusy] = useState(false); const [err, setErr] = useState('');
  const [prev, setPrev] = useState<{ name: string; address: string } | null>(null);
  const first = useRef(mst); const cur = useRef({ name, address }); cur.current = { name, address };
  const run = async (fresh = false) => {
    const m = (mst || '').replace(/\s/g, ''); setErr(''); setPrev(null);
    if (!mstForm(m)) { setR(null); onResult?.(null); return; }
    setBusy(true);
    try {
      const x = await lookupMst(m, fresh); setR(x); onResult?.(x);
      const typed = m !== first.current; first.current = '';
      if (x.found && autoFill && (typed || !cur.current.name.trim()) && (nameDiff(cur.current.name, x.name) || !cur.current.name.trim() || (x.address && cur.current.address.trim() !== x.address.trim()))) {
        setPrev({ ...cur.current }); onApply({ name: x.name || cur.current.name, address: x.address || cur.current.address });
      }
    } catch (e: any) { setR(null); setErr(e.message || String(e)); onResult?.(null); }
    finally { setBusy(false); }
  };
  useEffect(() => { const t = setTimeout(() => run(), 450); return () => clearTimeout(t); }, [mst]);
  const lw = localWarnings(mst); const lv = mstLevel(r);
  if (!mst?.trim()) return null;
  if (!r && !busy && !err && !lw.length) return null;
  const khacTen = r?.found && nameDiff(name, r.name); const khacDc = r?.found && !!r.address && !!address.trim() && address.trim() !== r.address.trim();
  return <div className={cx('rounded-lg border px-2.5 py-1.5 text-xs', TONE[busy ? '' : err ? 'amber' : lv || (lw.length ? 'red' : '')], className)}>
    {busy ? <span>Đang tra cứu MST…</span> : err ? <span>⚠ {err} <button type="button" className="ml-1 font-semibold underline" onClick={() => run(true)}>Thử lại</button></span> : r ? <>
      <div className="flex flex-wrap items-center gap-x-2">
        <b>{r.found ? (lv === 'red' ? '⛔' : '✓') + ' Thông tin đăng ký thuế' : '⛔ Không tìm thấy MST'}</b>
        <span className="text-[11px] opacity-70">nguồn {PROVIDER[r.provider] || r.provider}{r.cached ? ' (đã lưu)' : ''}</span>
        <button type="button" className="ml-auto text-[11px] font-semibold underline" onClick={() => run(true)}>Tra lại</button></div>
      {r.found && <div className="mt-0.5"><b>{r.name}</b>{r.address && <div>{r.address}</div>}{r.status && <div>Tình trạng: <b>{r.status}</b></div>}
        {(r.org_type || r.tax_dept) && <div className="opacity-70">{[r.org_type, r.tax_dept].filter(Boolean).join(' · ')}</div>}</div>}
      {r.warnings.map((w, i) => <div key={i} className="mt-0.5 font-semibold">⚠ {w}</div>)}
      {(khacTen || khacDc) && <div className="mt-1">Thông tin đang nhập khác đăng ký thuế{khacTen ? ' (tên)' : ''}{khacDc ? ' (địa chỉ)' : ''}.
        <button type="button" className="ml-1 font-semibold underline" onClick={() => { setPrev({ name, address }); onApply({ name: r.name || name, address: r.address || address }); }}>Điền theo đăng ký thuế</button></div>}
      {prev && !khacTen && !khacDc && <div className="mt-1">Đã tự điền tên + địa chỉ theo đăng ký thuế. <button type="button" className="font-semibold underline" onClick={() => { onApply(prev); setPrev(null); }}>↶ Giữ thông tin cũ</button></div>}
    </> : lw.map((w, i) => <div key={i} className="font-semibold">⚠ {w}</div>)}
  </div>;
}

// ---------- Bản 36: MST nổi bật + copy nhanh + nút lấy thông tin (dùng ở mọi chỗ có MST trong Kế toán – Hóa đơn) ----------
async function copyText(t: string) { try { await navigator.clipboard.writeText(t); return true; } catch { const x = document.createElement('textarea'); x.value = t; document.body.appendChild(x); x.select(); const ok = document.execCommand('copy'); x.remove(); return ok; } }
export function CopyBtn({ text, title = 'Copy', className }: { text: string; title?: string; className?: string }) {
  const [ok, setOk] = useState(false);
  return <button type="button" title={title} className={cx('inline-flex h-5 w-5 items-center justify-center rounded text-[12px] text-ink-400 hover:bg-ink-100 hover:text-brand-700', ok && 'text-emerald-600', className)}
    onClick={async e => { e.stopPropagation(); if (await copyText(text)) { setOk(true); setTimeout(() => setOk(false), 1200); } }}>{ok ? '✓' : '⧉'}</button>;
}
const LV = { red: 'bg-red-500', amber: 'bg-amber-400', green: 'bg-emerald-500', '': 'bg-ink-300' };
/** MST to, đậm + ⧉ copy + 🔍 lấy thông tin (tên, địa chỉ, tình trạng) — onApply: điền vào phiếu / pháp nhân đang sửa */
export function MstChip({ mst, onApply, size = 'md', className, btnOnly }: { mst: string | null | undefined; onApply?: (v: { name: string; address: string }) => void; size?: 'sm' | 'md'; className?: string; btnOnly?: boolean }) {
  const m = String(mst || '').replace(/\s/g, ''); const [open, setOpen] = useState(false); const [r, setR] = useState<MstResult | null>(null); const [busy, setBusy] = useState(false); const [err, setErr] = useState('');
  const btn = useRef<HTMLButtonElement>(null); const [pos, setPos] = useState({ x: 0, y: 0 });
  const go = async (fresh = false) => { setErr(''); setBusy(true); try { setR(await lookupMst(m, fresh)); } catch (e: any) { setErr(e.message || String(e)); } finally { setBusy(false); } };
  useEffect(() => { if (!open) return; const close = () => setOpen(false); window.addEventListener('scroll', close, true); window.addEventListener('resize', close); return () => { window.removeEventListener('scroll', close, true); window.removeEventListener('resize', close); }; }, [open]);
  if (!m) return null;
  const lv = mstLevel(r);
  const toggle = (e: React.MouseEvent) => { e.stopPropagation(); if (!open) { const b = btn.current!.getBoundingClientRect(); setPos({ x: Math.max(8, Math.min(b.left - 120, window.innerWidth - 360)), y: b.bottom + 6 }); if (!r) go(); } setOpen(!open); };
  return <span className={cx('inline-flex items-center gap-0.5', !btnOnly && 'rounded-lg border border-ink-200 bg-white pl-1.5 pr-0.5 shadow-sm', className)} onClick={e => e.stopPropagation()}>
    {!btnOnly && <><span className="text-[10px] font-semibold uppercase tracking-wide text-ink-400">MST</span>
    <span className={cx('select-all font-mono font-bold tracking-wide text-ink-900', size === 'md' ? 'text-[14px]' : 'text-[12.5px]')}>{m}</span></>}
    {r && <span title={r.status || (r.found ? '' : 'Không tìm thấy')} className={cx('ml-0.5 h-2 w-2 rounded-full', LV[lv])} />}
    {!btnOnly && <CopyBtn text={m} title="Copy MST" />}
    <button ref={btn} type="button" title="Lấy thông tin theo MST (tên, địa chỉ, tình trạng)" onClick={toggle}
      className={cx('inline-flex h-5 items-center rounded px-1 text-[11px] font-semibold', open ? 'bg-brand-600 text-white' : 'text-brand-700 hover:bg-brand-50')}>🔍</button>
    {open && createPortal(<>
      <div className="fixed inset-0 z-[70]" onClick={e => { e.stopPropagation(); setOpen(false); }} />
      <div className="fixed z-[71] w-[350px] rounded-xl border border-ink-200 bg-white p-3 text-xs shadow-xl" style={{ left: pos.x, top: pos.y }} onClick={e => e.stopPropagation()}>
        <div className="mb-1.5 flex items-center gap-2"><b className="font-mono text-sm">{m}</b><CopyBtn text={m} /><span className="ml-auto text-[10px] text-ink-400">{r ? (PROVIDER[r.provider] || r.provider) + (r.cached ? ' · đã lưu' : '') : ''}</span>
          <button className="text-ink-400 hover:text-ink-700" onClick={() => setOpen(false)}>✕</button></div>
        {busy ? <div className="py-3 text-center text-ink-500">Đang tra cứu…</div> : err ? <div className="rounded-lg bg-amber-50 px-2 py-1.5 text-amber-900">⚠ {err}</div> : r && <>
          <div className={cx('rounded-lg border px-2 py-1.5', TONE[lv])}>
            {r.found ? <><div className="flex items-start gap-1"><b className="flex-1">{r.name}</b><CopyBtn text={r.name} title="Copy tên" /></div>
              {r.address && <div className="mt-0.5 flex items-start gap-1"><span className="flex-1">{r.address}</span><CopyBtn text={r.address} title="Copy địa chỉ" /></div>}
              {r.status && <div className="mt-1">Tình trạng: <b>{r.status}</b></div>}
              {(r.org_type || r.tax_dept) && <div className="opacity-70">{[r.org_type, r.tax_dept].filter(Boolean).join(' · ')}</div>}</> : <b>⛔ Không tìm thấy MST trên dữ liệu thuế</b>}
            {r.warnings.filter(w => !/Không tìm thấy MST/.test(w)).map((w, i) => <div key={i} className="mt-1 font-semibold">⚠ {w}</div>)}</div>
          <div className="mt-2 flex items-center gap-2">
            {onApply && r.found && <button className="rounded-lg bg-brand-600 px-2.5 py-1 font-semibold text-white hover:bg-brand-700" onClick={() => { onApply({ name: r.name, address: r.address }); setOpen(false); }}>Điền tên + địa chỉ</button>}
            <button className="ml-auto font-semibold text-brand-700 underline" onClick={() => go(true)}>Tra lại</button></div></>}
      </div></>, document.body)}
  </span>;
}
