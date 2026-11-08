// Bản 35 — Ô kiểm tra MST: gõ MST → tra cứu → tự điền tên + địa chỉ theo đăng ký thuế, kèm cảnh báo
import React, { useEffect, useRef, useState } from 'react';
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
      {r.found && <div className="mt-0.5"><b>{r.name}</b>{r.address && <div>{r.address}</div>}{r.status && <div>Tình trạng: <b>{r.status}</b></div>}</div>}
      {r.warnings.map((w, i) => <div key={i} className="mt-0.5 font-semibold">⚠ {w}</div>)}
      {(khacTen || khacDc) && <div className="mt-1">Thông tin đang nhập khác đăng ký thuế{khacTen ? ' (tên)' : ''}{khacDc ? ' (địa chỉ)' : ''}.
        <button type="button" className="ml-1 font-semibold underline" onClick={() => { setPrev({ name, address }); onApply({ name: r.name || name, address: r.address || address }); }}>Điền theo đăng ký thuế</button></div>}
      {prev && !khacTen && !khacDc && <div className="mt-1">Đã tự điền tên + địa chỉ theo đăng ký thuế. <button type="button" className="font-semibold underline" onClick={() => { onApply(prev); setPrev(null); }}>↶ Giữ thông tin cũ</button></div>}
    </> : lw.map((w, i) => <div key={i} className="font-semibold">⚠ {w}</div>)}
  </div>;
}
