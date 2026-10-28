import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, cx, Empty, Field, Input, Loading, Select, Textarea, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { addDays, fmtDate, num, today } from '../../lib/format';

export const LS: Record<string, [string, string]> = { cho_duyet: ['Chờ duyệt', 'amber'], da_duyet: ['Đã duyệt', 'green'], tu_choi: ['Từ chối', 'red'], huy: ['Đã hủy', 'gray'] };
export const whenText = (r: any) => `${fmtDate(r.start_date)}${r.end_date !== r.start_date ? ` – ${fmtDate(r.end_date)}` : ''}${r.part === 'am' ? ' (sáng)' : r.part === 'pm' ? ' (chiều)' : r.part === 'hours' ? ` ${String(r.from_time).slice(0, 5)}–${String(r.to_time).slice(0, 5)}` : ''}`;

function dayValue(sched: string, d: string, holidays: Set<string>) {
  if (holidays.has(d)) return 0; const w = new Date(d + 'T00:00:00Z').getUTCDay();
  if (w === 0) return 0; if (w === 6 && sched === 'office') return 0.5; return 1;
}

export default function Leave() {
  const a = useApp(); const { busy, run } = useAction();
  const canOnBehalf = a.isLead || a.has('hcns', 'admin', 'bgd');
  const [f, setF] = useState({ for_id: '', leave_type: 'phep_nam', start_date: today(), end_date: today(), part: 'full', from_time: '09:00', to_time: '10:00', reason: '', backup_id: '', handover: '' });
  const target = f.for_id || a.me.id;
  const { data: bal, reload: rb } = useLoad(() => db.rpc('leave_balance', { p_profile: target }), [target]);
  const { data: mine, loading, reload } = useLoad(() => db.from('leave_requests').select('*').eq('profile_id', a.me.id).order('start_date', { asc: false }).limit(100), []);
  const { data: hol } = useLoad(() => db.from('holidays').select('day').gte('day', `${today().slice(0, 4)}-01-01`), []);
  const holidays = useMemo(() => new Set(((hol as any[]) || []).map(h => h.day)), [hol]);
  const lt = a.lk('leave_type', f.leave_type); const ex = lt?.extra || {}; const hours = !!ex.hours;
  const sched = a.people.find(p => p.id === target) ? (target === a.me.id ? a.me.work_schedule : 'office') : 'office';
  const days = useMemo(() => {
    if (hours || f.end_date < f.start_date) return 0; let s = 0; let d = f.start_date;
    while (d <= f.end_date) { const v = dayValue(sched, d, holidays); s += f.start_date === f.end_date && f.part !== 'full' ? Math.min(v, 0.5) : v; d = addDays(d, 1); }
    return s;
  }, [f.start_date, f.end_date, f.part, hours, holidays]);
  const late = ex.notice_days && f.start_date < addDays(today(), ex.notice_days);
  const after = f.leave_type === 'phep_nam' && bal ? Number(bal.available) - days : null;
  const submit = () => run(async () => {
    if (f.end_date < f.start_date) throw new Error('Ngày kết thúc phải sau ngày bắt đầu');
    const single = f.start_date === f.end_date;
    await db.from('leave_requests').insert({ profile_id: target, leave_type: f.leave_type, start_date: f.start_date, end_date: hours ? f.start_date : f.end_date,
      part: hours ? 'hours' : single ? f.part : 'full', from_time: hours ? f.from_time : null, to_time: hours ? f.to_time : null,
      reason: f.reason || null, backup_id: f.backup_id || null, handover: f.handover || null });
    setF({ ...f, reason: '', handover: '' }); reload(); rb();
  }, f.for_id ? 'Đã tạo đơn hộ (duyệt ngay)' : 'Đã gửi đơn — chờ quản lý duyệt');
  const others = canOnBehalf ? a.people.filter(p => p.status === 'active' && p.id !== a.me.id && (a.has('hcns', 'admin', 'bgd') || p.manager_id === a.me.id)) : [];
  const setDate = (d: string) => setF({ ...f, start_date: d, end_date: d });
  const B = ({ children }: { children: React.ReactNode }) => <b className="text-ink-800">{children}</b>;
  const myList = (mine as any[]) || [];
  return (
    <Layout title="Xin nghỉ">
      <div className="mx-auto max-w-6xl space-y-4">
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-4 sm:gap-3">
          <div className="col-span-3 flex items-center gap-4 rounded-2xl bg-gradient-to-br from-ink-900 to-brand-700 px-5 py-4 text-white shadow-soft sm:col-span-1">
            <div className="text-4xl font-extrabold tabular-nums">{bal ? num(bal.balance, 1) : '…'}</div><div className="text-sm font-semibold leading-tight text-white/80">ngày phép<br />còn lại</div></div>
          {[['Được hưởng năm nay', bal?.entitled, 'Tồn năm trước ' + num(bal?.carried ?? 0, 1)], ['Đã dùng', bal?.used, 'Tích lũy đến nay ' + num(bal?.accrued ?? 0, 1)], ['Đang chờ duyệt', bal?.pending, myList.filter(r => r.status === 'cho_duyet').length + ' đơn']].map(([l, v, sub]) =>
            <div key={l as string} className="rounded-2xl border border-ink-200 bg-white px-3 py-2.5 shadow-soft sm:px-4 sm:py-3"><div className="text-[11px] text-ink-500 sm:text-xs">{l}</div><div className="text-xl sm:text-2xl font-extrabold tabular-nums">{num(v ?? 0, 1)}</div><div className="text-[11px] text-ink-400">{sub}</div></div>)}
        </div>
        {bal && !bal.configured && <p className="rounded-xl bg-amber-50 px-3 py-2 text-xs text-amber-800">Chưa nhập sổ phép năm nay — tạm tính {num(bal.entitled, 0)} ngày. HCNS nhập ở <a className="font-semibold underline" href="#/hr/timesheet">Bảng công · Chuyên cần → Sổ phép năm</a>.</p>}
        <div className="grid items-start gap-4 lg:grid-cols-[minmax(0,1fr)_340px]">
          <section className="rounded-2xl border border-ink-200 bg-white shadow-soft">
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-ink-100 px-5 py-3"><b>Tạo đơn</b><span className="text-xs text-ink-400">🔒 Lý do chỉ quản lý duyệt và HCNS thấy</span></div>
            <div className="space-y-4 p-5">
              {others.length > 0 && <Field label={<B>Tạo đơn cho</B>} hint={f.for_id ? 'Đơn tạo hộ được duyệt ngay — dùng để ghi nhận nghỉ không phép hoặc báo nghỉ qua điện thoại.' : undefined}>
                <Select options={[['', 'Chính tôi'], ...others.map(p => [p.id, p.full_name] as [string, string])]} value={f.for_id} onChange={v => setF({ ...f, for_id: v })} /></Field>}
              <div><div className="mb-1.5 text-xs"><B>Loại đơn</B>{ex.notice_days && <span className="ml-2 text-ink-400">cần báo trước {ex.notice_days} ngày</span>}</div>
                <div className="flex flex-wrap gap-1.5">{a.opts('leave_type').filter(([k]) => k !== 'khong_phep' || f.for_id).map(([k, l]) =>
                  <button key={k} type="button" onClick={() => setF({ ...f, leave_type: k })} className={cx('rounded-full border px-3 py-1 text-[13px] font-semibold transition', f.leave_type === k ? 'border-brand-600 bg-brand-600 text-white shadow-sm' : 'border-ink-200 bg-white text-ink-700 hover:border-brand-300')}>{l}</button>)}</div></div>
              <div className="grid gap-3 sm:grid-cols-2">
                <div>
                  <div className="grid grid-cols-2 gap-2">
                    <Field label={<B>{hours ? 'Ngày' : 'Từ ngày'}</B>}><Input type="date" value={f.start_date} onChange={e => setF({ ...f, start_date: e.target.value, end_date: e.target.value > f.end_date ? e.target.value : f.end_date })} /></Field>
                    {hours ? <div className="grid grid-cols-2 gap-1.5"><Field label={<B>Từ</B>}><Input type="time" value={f.from_time} onChange={e => setF({ ...f, from_time: e.target.value })} /></Field>
                      <Field label={<B>Đến</B>}><Input type="time" value={f.to_time} onChange={e => setF({ ...f, to_time: e.target.value })} /></Field></div>
                      : <Field label={<B>Đến ngày</B>}><Input type="date" min={f.start_date} value={f.end_date} onChange={e => setF({ ...f, end_date: e.target.value })} /></Field>}
                  </div>
                  <div className="mt-1.5 flex gap-1.5">{[['Hôm nay', 0], ['Ngày mai', 1], ['Ngày kia', 2]].map(([l, n]) => <button key={l as string} type="button" onClick={() => setDate(addDays(today(), n as number))} className={cx('rounded-full border px-2.5 py-0.5 text-xs', f.start_date === addDays(today(), n as number) && f.end_date === f.start_date ? 'border-brand-500 bg-brand-50 text-brand-700' : 'border-dashed border-ink-300 text-ink-600 hover:border-brand-500')}>{l}</button>)}</div>
                </div>
                {!hours && f.start_date === f.end_date ? <div><div className="mb-1.5 text-xs"><B>Buổi</B></div>
                  <div className="inline-flex rounded-full bg-ink-100 p-1">{[['full', 'Cả ngày'], ['am', 'Sáng'], ['pm', 'Chiều']].map(([k, l]) =>
                    <button key={k} type="button" onClick={() => setF({ ...f, part: k })} className={cx('rounded-full px-4 py-1.5 text-sm font-semibold', f.part === k ? 'bg-ink-900 text-white' : 'text-ink-600')}>{l}</button>)}</div></div>
                  : <Field label={<B>Khi bạn vắng, việc gấp tìm ai?</B>}><Select options={a.people.filter(p => p.id !== target && p.status === 'active').map(p => [p.id, p.full_name])} value={f.backup_id} onChange={v => setF({ ...f, backup_id: v })} placeholder="Chưa chọn" /></Field>}
              </div>
              {!hours && f.start_date === f.end_date && <Field label={<B>Khi bạn vắng, việc gấp tìm ai?</B>}><Select options={a.people.filter(p => p.id !== target && p.status === 'active').map(p => [p.id, p.full_name])} value={f.backup_id} onChange={v => setF({ ...f, backup_id: v })} placeholder="Chưa chọn" /></Field>}
              <div className="grid gap-3 sm:grid-cols-2">
                <Field label={<B>Lý do</B>}><Textarea rows={3} value={f.reason} onChange={e => setF({ ...f, reason: e.target.value })} placeholder="VD: Đưa con đi khám, về quê có việc…" /></Field>
                <Field label={<B>Bàn giao (không bắt buộc)</B>}><Textarea rows={3} value={f.handover} onChange={e => setF({ ...f, handover: e.target.value })} placeholder="Đơn đang chạy, khách cần gọi lại…" /></Field>
              </div>
            </div>
            <div className="flex flex-wrap items-center gap-3 rounded-b-2xl border-t border-ink-100 bg-ink-50/60 px-5 py-3">
              <div className="mr-auto"><div className="text-lg font-extrabold">{hours ? `${f.from_time} – ${f.to_time}` : `= ${num(days, 1)} ngày công`}</div>
                {after !== null && <div className={cx('text-xs', after < 0 ? 'font-semibold text-red-600' : 'text-ink-500')}>Sau đơn này còn {num(after, 1)} ngày phép</div>}</div>
              <Button variant="primary" className="h-11 px-6 text-base" loading={busy} onClick={submit}>Gửi đơn</Button>
            </div>
            {(late || hours || ex.work || (after !== null && after < 0)) && <ul className="space-y-1 border-t border-ink-100 px-5 py-3 text-xs">
              {late && <li className="text-amber-700">⚠️ Đơn báo gấp: loại này cần báo trước {ex.notice_days} ngày. Vẫn gửi được nhưng bị tính vào điểm chuyên cần.</li>}
              {hours && <li className="text-ink-600">⏱ Thời gian vắng tính vào quỹ linh hoạt {a.settings.attendance?.flex_minutes ?? 100} phút/tháng.</li>}
              {ex.work && <li className="text-emerald-700">✓ Loại này vẫn tính đủ công.</li>}
              {after !== null && after < 0 && <li className="text-red-600">Không đủ phép — chọn "Nghỉ không lương" cho phần thiếu.</li>}
            </ul>}
          </section>
          <aside className="rounded-2xl border border-ink-200 bg-white shadow-soft lg:sticky lg:top-16">
            <div className="border-b border-ink-100 px-4 py-3"><b>Đơn của tôi</b> <span className="text-xs text-ink-400">{myList.length}</span></div>
            {loading ? <Loading /> : !myList.length ? <Empty>Chưa có đơn</Empty> :
              <ul className="max-h-[560px] divide-y divide-ink-100 overflow-y-auto">{myList.map(r => (
                <li key={r.id} className="px-4 py-2.5 text-sm">
                  <div className="flex items-start justify-between gap-2"><b className="leading-snug">{a.label('leave_type', r.leave_type)}</b><Badge color={LS[r.status][1]}>{LS[r.status][0]}</Badge></div>
                  <div className="text-xs text-ink-500">{whenText(r)} · {num(r.days, 1)} ngày{r.late_notice && <span className="ml-1 font-semibold text-amber-700">· báo gấp</span>}</div>
                  {r.decision_note && <div className="text-xs text-ink-400">“{r.decision_note}”</div>}
                  {['cho_duyet', 'da_duyet'].includes(r.status) && r.start_date > today() && <button className="mt-0.5 text-xs font-semibold text-red-600 hover:underline" onClick={() => run(async () => { await db.rpc('cancel_request', { p_table: 'leave', p_id: r.id }); reload(); rb(); }, 'Đã hủy đơn')}>Hủy đơn</button>}
                </li>))}</ul>}
          </aside>
        </div>
      </div>
    </Layout>
  );
}
