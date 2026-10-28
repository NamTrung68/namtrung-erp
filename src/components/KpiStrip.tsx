import React from 'react';
import { cx } from './ui';
import { num } from '../lib/format';
import { useApp } from '../state';

/** Gộp KPI của nhiều nhân viên: thực tế / chỉ tiêu từng chỉ số + điểm trung bình */
export function useKpiSummary(rows: any[] | null | undefined) {
  const a = useApp(); const k = a.settings.kpi || {}; const nf = Number(k.new_hire_factor ?? 0.7);
  const all: Record<string, { label: string; day: number; weight?: number; show?: boolean }> = Object.fromEntries(Object.entries(k.metrics || {}).filter(([key, m]: any) => m.show ?? key !== 'bao_cao')) as any;
  const rs = rows || [];
  const ORDER = ['kh_moi', 'tiep_can', 'ket_noi', 'cham_cu', 'bao_gia', 'bai_fb', 'cuoc_goi_nhat_ky', 'tin_nhan_nhat_ky', 'bao_cao', 'don_chot', 'khach_nong_am', 'cuoc_goi_khai', 'tin_nhan_khai'];
  const items = Object.entries(all).sort(([x], [y]) => (ORDER.indexOf(x) + 1 || 99) - (ORDER.indexOf(y) + 1 || 99)).map(([key, m]) => {
    const actual = rs.reduce((s, r) => s + (Number(r.metrics?.[key]) || 0), 0);
    const target = Math.round(rs.reduce((s, r) => s + Number(m.day || 0) * (Number(r.metrics?.days) || 1) * (r.is_new ? nf : 1), 0));
    return { key, label: m.label, actual, target, pct: target ? actual / target : 0 };
  });
  const score = rs.length ? rs.reduce((s, r) => s + Number(r.score || 0), 0) / rs.length : 0;
  return { items, score, count: rs.length };
}

export function KpiStrip({ rows, title = 'Điểm KPI hôm nay', compact }: { rows: any[] | null | undefined; title?: string; compact?: boolean }) {
  const { items, score, count } = useKpiSummary(rows);
  return (
    <div className="overflow-hidden rounded-2xl border border-ink-200 bg-white shadow-soft">
      <div className="grid grid-cols-[repeat(auto-fit,minmax(128px,1fr))]">
        {items.map(it => {
          const tone = it.pct >= 1 ? 'bg-emerald-500' : it.pct >= 0.7 ? 'bg-amber-400' : 'bg-orange-500';
          const short = it.target - it.actual;
          return <div key={it.key} className="min-w-0 border-b border-r border-ink-100 px-3 py-2.5">
            <div className="truncate text-[11px] font-medium text-ink-500" title={it.label}>{it.label}</div>
            <div className="mt-0.5 flex items-baseline gap-1"><b className="text-xl font-extrabold tabular-nums leading-none">{num(it.actual)}</b><span className="text-xs text-ink-400">/ {num(it.target)}</span></div>
            <div className="mt-1.5 h-1.5 rounded-full bg-ink-100"><div className={cx('h-1.5 rounded-full', tone)} style={{ width: `${Math.min(100, it.pct * 100)}%` }} /></div>
            {compact && <div className={cx('mt-1 text-[11px] font-semibold', short > 0 ? 'text-orange-600' : 'text-emerald-600')}>{short > 0 ? `Thiếu ${num(short)}` : it.actual > it.target ? `Thừa ${num(it.actual - it.target)}` : 'Đủ chỉ tiêu ✓'}</div>}
          </div>;
        })}
        <div className="col-span-2 flex flex-col justify-center bg-gradient-to-br from-brand-600 to-brand-500 px-3 py-2.5 text-white sm:col-span-1">
          <div className="text-[11px] font-medium opacity-80">{title}</div>
          <div className="text-3xl font-extrabold leading-tight tabular-nums">{num(score, 1)}</div>
          <div className="text-[11px] opacity-80">{count > 1 ? `Gộp ${count} nhân viên` : count === 1 ? 'thang điểm 100' : 'Chưa có dữ liệu'}</div>
        </div>
      </div>
    </div>
  );
}
