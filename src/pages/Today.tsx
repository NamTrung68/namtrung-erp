import React, { useMemo, useState } from 'react';
import { Layout } from '../components/Layout';
import { Button, cx, Loading, useLoad } from '../components/ui';
import { db } from '../lib/sb';
import { go, useApp } from '../state';
import { addDays, today } from '../lib/format';
import { pickDaily } from '../lib/greeting';

const WD = ['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'];
const WDL = ['Chủ nhật', 'Thứ Hai', 'Thứ Ba', 'Thứ Tư', 'Thứ Năm', 'Thứ Sáu', 'Thứ Bảy'];
const wd = (d: string) => new Date(d + 'T00:00:00Z').getUTCDay();
const dm = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}`;
const CAT: Record<string, { dot: string; chip: string; label: string }> = {
  nghi: { dot: 'bg-sun', chip: 'bg-amber-100 text-amber-900', label: 'Nghỉ' },
  ra_ngoai: { dot: 'bg-aqua', chip: 'bg-sky-100 text-sky-900', label: 'Công tác, làm từ xa' },
  gio: { dot: 'bg-hot', chip: 'bg-rose-100 text-rose-900', label: 'Vắng theo giờ' },
};
const initials = (n: string) => n.split(/\s+/).filter(Boolean).slice(-2).map(x => x[0]).join('').toUpperCase();
const when = (r: any) => r.part === 'hours' ? `${String(r.from_time).slice(0, 5)}–${String(r.to_time).slice(0, 5)}` : r.part === 'am' ? 'Sáng' : r.part === 'pm' ? 'Chiều' : 'Cả ngày';

function Chip({ r }: { r: any }) {
  const c = CAT[r.category] || CAT.nghi;
  return (
    <span className={cx('inline-flex items-center gap-2 rounded-full border bg-white py-1 pl-1 pr-3 text-sm', r.status === 'cho_duyet' ? 'border-dashed border-ink-400' : 'border-ink-200')}>
      <span className={cx('grid h-7 w-7 place-items-center rounded-full text-[11px] font-bold', c.chip)}>{initials(r.full_name)}</span>
      <span className="font-semibold">{r.full_name}</span>
      <span className="text-xs text-ink-500">{r.category === 'nghi' ? when(r) : `${r.label} · ${when(r)}`}</span>
    </span>
  );
}

export default function Today() {
  const a = useApp(); const t = today(); let t1 = addDays(t, 1); if (wd(t1) === 0) t1 = addDays(t1, 1);
  const [unit, setUnit] = useState('');
  const { data, loading } = useLoad(() => db.rpc<any[]>('today_board', { p_from: t, p_to: addDays(t, 21) }), []);
  const units = a.units.filter(u => u.kind !== 'cong_ty');
  const rows = useMemo(() => (data || []).filter(r => !unit || r.org_unit_id === unit), [data, unit]);
  const on = (d: string) => rows.filter(r => r.day === d);
  const todayRows = on(t); const tomorrow = on(t1);
  const later = Array.from(new Set(rows.filter(r => r.day > t1).map(r => r.day))).sort();
  const headline = todayRows.length === 0 ? 'Hôm nay đủ quân' : `Hôm nay vắng ${new Set(todayRows.map(r => r.profile_id)).size} người`;
  return (
    <Layout title="Hôm nay" actions={<Button variant="primary" onClick={() => go('/hr/leave')}>Xin nghỉ / báo vắng</Button>}>
      <div className="mx-auto max-w-4xl py-2 sm:py-6">
        <div className="text-sm font-semibold text-ink-500">{WDL[wd(t)]}, {dm(t)}</div>
        <h2 className="display mt-1 text-4xl sm:text-6xl">{headline}</h2>
        {pickDaily(a.settings.login_screen?.messages, 3, a.me.id) && <div className="mt-3 inline-flex max-w-2xl items-start gap-2 rounded-2xl bg-gradient-to-r from-brand-50 to-pink-50 px-4 py-2.5 text-sm text-ink-700">
          <span>💜</span><span><b>{a.me.full_name.split(' ').slice(-1)[0]}</b> ơi, {pickDaily(a.settings.login_screen?.messages, 3, a.me.id)}</span></div>}
        <p className="mt-2 text-ink-500">{WD[wd(t1)]} {dm(t1)} {tomorrow.length ? `có ${tomorrow.length} người báo vắng.` : 'chưa ai báo vắng.'}</p>
        <div className="mt-5 flex flex-wrap gap-2">
          {[['', 'Tất cả'], ...units.map(u => [u.id, u.name])].map(([id, name]) =>
            <button key={id} onClick={() => setUnit(id)} className={cx('rounded-full border px-4 py-1.5 text-sm font-semibold transition', unit === id ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white hover:border-ink-400')}>{name}</button>)}
        </div>
        {loading ? <Loading /> : <>
          <div className="mt-6 rounded-3xl border-2 border-ink-900 bg-white p-5 shadow-pop sm:p-6">
            {todayRows.length === 0 ? <div className="text-lg font-bold">Không ai vắng. Ngày làm việc trọn vẹn 🙌</div> :
              <ul className="space-y-3">{todayRows.map((r, i) => <li key={i} className="flex flex-wrap items-center gap-2"><Chip r={r} />
                {r.backup_name && <span className="text-xs text-ink-500">Việc gấp tìm: <b className="text-ink-800">{r.backup_name}</b></span>}</li>)}</ul>}
          </div>
          <h3 className="mt-8 text-xl font-extrabold">{WD[wd(t1)]} {dm(t1)}</h3>
          {tomorrow.length === 0 ? <p className="mt-1 text-ink-500">Chưa ai báo vắng.</p> : <div className="mt-2 flex flex-wrap gap-2">{tomorrow.map((r, i) => <Chip key={i} r={r} />)}</div>}
          <h3 className="mt-8 text-xl font-extrabold">Những ngày tới</h3>
          {later.length === 0 ? <p className="mt-1 text-ink-500">Chưa có lịch vắng nào.</p> :
            <div className="mt-2 divide-y divide-ink-200 border-y border-ink-200">{later.map(d => (
              <div key={d} className="flex gap-4 py-3">
                <div className="w-14 shrink-0"><div className="text-xl font-extrabold">{dm(d).slice(0, 5).replace(/^0/, '')}</div><div className="text-xs text-ink-500">{WD[wd(d)]}</div></div>
                <div className="flex flex-wrap gap-2">{on(d).map((r, i) => <Chip key={i} r={r} />)}</div>
              </div>))}</div>}
          <div className="mt-5 flex flex-wrap gap-4 text-sm text-ink-500">
            {Object.values(CAT).map(c => <span key={c.label} className="flex items-center gap-1.5"><span className={cx('h-3 w-3 rounded-full', c.dot)} />{c.label}</span>)}
            <span className="flex items-center gap-1.5"><span className="h-3 w-3 rounded-full border border-dashed border-ink-500" />Đơn chờ duyệt</span>
          </div>
        </>}
      </div>
    </Layout>
  );
}
