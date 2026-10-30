import React, { useEffect, useState } from 'react';
import { cx } from './ui';

const SIZES = [20, 50, 100, 200];
/** Phân trang: mặc định 20 dòng, nhớ số dòng/trang theo từng danh sách */
export function usePager(key: string, deps: any[] = []) {
  const [size, setSizeS] = useState<number>(() => { try { return Number(localStorage.getItem('nt_ps_' + key)) || 20; } catch { return 20; } });
  const [page, setPage] = useState(1);
  useEffect(() => { setPage(1); }, deps);
  const setSize = (n: number) => { setSizeS(n); setPage(1); try { localStorage.setItem('nt_ps_' + key, String(n)); } catch { /* */ } };
  const from = (page - 1) * size; const to = from + size - 1;
  return { page, size, setPage, setSize, from, to, slice: <T,>(rows: T[]) => rows.slice(from, from + size) };
}
export type PagerState = ReturnType<typeof usePager>;

export function Pager({ p, total, className }: { p: PagerState; total: number; className?: string }) {
  const pages = Math.max(1, Math.ceil(total / p.size));
  useEffect(() => { if (p.page > pages) p.setPage(pages); }, [pages]);
  if (total <= 20 && p.size === 20) return null;
  const nums: (number | '…')[] = [];
  for (let i = 1; i <= pages; i++) if (i === 1 || i === pages || Math.abs(i - p.page) <= 1) nums.push(i); else if (nums[nums.length - 1] !== '…') nums.push('…');
  const btn = 'grid h-8 min-w-[2rem] place-items-center rounded-lg border px-2 text-xs font-semibold transition disabled:opacity-40';
  return (
    <div className={cx('flex flex-wrap items-center justify-between gap-2 border-t border-ink-100 px-3 py-2.5 text-xs text-ink-500', className)}>
      <span><b className="text-ink-800">{total ? p.from + 1 : 0}–{Math.min(p.from + p.size, total)}</b> / {total.toLocaleString('vi-VN')} dòng</span>
      <div className="flex items-center gap-1">
        <button className={cx(btn, 'border-ink-200 bg-white hover:bg-ink-50')} disabled={p.page <= 1} onClick={() => p.setPage(p.page - 1)} aria-label="Trang trước">‹</button>
        {nums.map((n, i) => n === '…' ? <span key={i} className="px-1">…</span> :
          <button key={i} className={cx(btn, n === p.page ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white hover:bg-ink-50', Math.abs(n - p.page) > 1 && n !== 1 && n !== pages && 'hidden sm:grid')} onClick={() => p.setPage(n)}>{n}</button>)}
        <button className={cx(btn, 'border-ink-200 bg-white hover:bg-ink-50')} disabled={p.page >= pages} onClick={() => p.setPage(p.page + 1)} aria-label="Trang sau">›</button>
        <select className="ml-1 h-8 rounded-lg border border-ink-200 bg-white pl-2 pr-6 text-xs" value={p.size} onChange={e => p.setSize(Number(e.target.value))}>
          {SIZES.map(s => <option key={s} value={s}>{s} / trang</option>)}</select>
      </div>
    </div>
  );
}
