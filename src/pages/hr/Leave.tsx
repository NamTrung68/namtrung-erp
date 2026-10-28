import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Select, Table, Td, Textarea, useAction, useLoad } from '../../components/ui';
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
  return (
    <Layout title="Xin nghỉ">
      <div className="mx-auto max-w-5xl">
        <h2 className="display text-4xl sm:text-5xl">Xin nghỉ</h2>
        <p className="mb-5 mt-1 max-w-xl text-ink-500">Lịch chung chỉ hiện tên, buổi vắng và người hỗ trợ. Lý do chỉ quản lý duyệt và HCNS thấy.</p>
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_280px]">
          <section className="space-y-4 rounded-3xl border border-ink-200 bg-white p-5 shadow-soft">
            <Field label={<b className="text-ink-800">Tạo đơn cho</b>} hint={f.for_id ? 'Đơn tạo hộ được duyệt ngay. Dùng để ghi nhận nghỉ không phép hoặc báo nghỉ qua điện thoại.' : undefined}>
              <Select options={[['', 'Chính tôi'], ...others.map(p => [p.id, p.full_name] as [string, string])]} value={f.for_id} onChange={v => setF({ ...f, for_id: v })} disabled={!others.length} /></Field>
            <div><div className="mb-1.5 text-xs font-bold text-ink-800">Loại</div>
              <div className="flex flex-wrap gap-2">{a.opts('leave_type').filter(([k]) => k !== 'khong_phep' || f.for_id).map(([k, l]) =>
                <button key={k} type="button" onClick={() => setF({ ...f, leave_type: k })} className={cx('rounded-full border px-3.5 py-1.5 text-sm font-semibold transition', f.leave_type === k ? 'border-brand-600 bg-brand-600 text-white' : 'border-ink-200 bg-ink-50 hover:border-brand-200')}>{l}</button>)}</div>
              {ex.notice_days && <p className="mt-1.5 text-xs text-ink-500">Cần báo trước {ex.notice_days} ngày.</p>}</div>
            <div className="grid grid-cols-2 gap-3">
              <Field label={<b className="text-ink-800">{hours ? 'Ngày' : 'Từ ngày'}</b>}><Input type="date" value={f.start_date} onChange={e => setF({ ...f, start_date: e.target.value, end_date: e.target.value > f.end_date ? e.target.value : f.end_date })} /></Field>
              {hours ? <div className="grid grid-cols-2 gap-2"><Field label={<b className="text-ink-800">Từ giờ</b>}><Input type="time" value={f.from_time} onChange={e => setF({ ...f, from_time: e.target.value })} /></Field>
                <Field label={<b className="text-ink-800">Đến giờ</b>}><Input type="time" value={f.to_time} onChange={e => setF({ ...f, to_time: e.target.value })} /></Field></div>
                : <Field label={<b className="text-ink-800">Đến ngày</b>}><Input type="date" min={f.start_date} value={f.end_date} onChange={e => setF({ ...f, end_date: e.target.value })} /></Field>}
            </div>
            <div className="-mt-2 flex gap-1.5">{[['Hôm nay', 0], ['Ngày mai', 1], ['Ngày kia', 2]].map(([l, n]) => <button key={l as string} type="button" onClick={() => setDate(addDays(today(), n as number))} className="rounded-full border border-dashed border-ink-300 px-2.5 py-0.5 text-xs text-ink-600 hover:border-brand-500">{l}</button>)}</div>
            {!hours && f.start_date === f.end_date && <div><div className="mb-1.5 text-xs font-bold text-ink-800">Buổi</div>
              <div className="inline-flex rounded-full bg-ink-100 p-1">{[['full', 'Cả ngày'], ['am', 'Sáng'], ['pm', 'Chiều']].map(([k, l]) =>
                <button key={k} type="button" onClick={() => setF({ ...f, part: k })} className={cx('rounded-full px-4 py-1.5 text-sm font-semibold', f.part === k ? 'bg-ink-900 text-white' : 'text-ink-600')}>{l}</button>)}</div></div>}
            <Field label={<b className="text-ink-800">Lý do</b>} hint="🔒 Riêng tư. Đồng nghiệp không nhìn thấy dòng này."><Textarea value={f.reason} onChange={e => setF({ ...f, reason: e.target.value })} placeholder="VD: Đưa con đi khám, về quê có việc gia đình…" /></Field>
            <Field label={<b className="text-ink-800">Khi bạn vắng, việc gấp tìm ai?</b>}><Select options={a.people.filter(p => p.id !== target && p.status === 'active').map(p => [p.id, p.full_name])} value={f.backup_id} onChange={v => setF({ ...f, backup_id: v })} placeholder="Chưa chọn" /></Field>
            <Field label={<b className="text-ink-800">Bàn giao (không bắt buộc)</b>}><Textarea value={f.handover} onChange={e => setF({ ...f, handover: e.target.value })} placeholder="Đơn đang chạy, khách cần gọi lại, giấy tờ cần nộp…" /></Field>
            <Button variant="primary" className="h-11 px-6 text-base" loading={busy} onClick={submit}>Gửi đơn</Button>
          </section>
          <aside className="space-y-3">
            <div className="rounded-3xl bg-ink-900 p-5 text-white">
              <div className="text-5xl font-extrabold">{bal ? num(bal.balance, 1) : '…'}</div><div className="mt-1 font-semibold text-ink-200">ngày phép còn lại</div>
              {bal && <dl className="mt-4 space-y-1.5 text-sm">{[['Được hưởng năm nay', bal.entitled], ['Tồn năm trước', bal.carried], ['Đã dùng', bal.used], ['Đang chờ duyệt', bal.pending], ['Tích lũy đến nay', bal.accrued]].map(([l, v]) =>
                <div key={l as string} className="flex justify-between"><dt className="text-ink-300">{l}</dt><dd className="font-bold">{num(v, 1)}</dd></div>)}</dl>}
              {bal && !bal.configured && <p className="mt-3 text-[11px] text-amber-300">Chưa nhập sổ phép năm nay — HCNS nhập số phép còn lại trong Nhân sự & phân quyền.</p>}
            </div>
            <div className="rounded-3xl border border-ink-200 bg-white p-4 shadow-soft">
              <div className="text-xl font-extrabold">{hours ? `${f.from_time}–${f.to_time}` : `= ${num(days, 1)} ngày công`}</div>
              {after !== null && <p className="mt-1 text-xs text-ink-500">Sau đơn này còn {num(after, 1)} ngày phép</p>}
              <ul className="mt-2 list-disc space-y-1 pl-4 text-xs text-ink-600">
                {late && <li className="text-amber-700">Đơn báo gấp: loại này cần báo trước {ex.notice_days} ngày. Vẫn gửi được nhưng bị tính vào điểm chuyên cần.</li>}
                {hours && <li>Thời gian vắng tính vào quỹ linh hoạt {a.settings.attendance?.flex_minutes ?? 100} phút/tháng.</li>}
                {ex.work && <li>Loại này vẫn tính đủ công.</li>}
                {after !== null && after < 0 && <li className="text-red-600">Không đủ phép — chọn "Nghỉ không lương" cho phần thiếu.</li>}
              </ul>
            </div>
          </aside>
        </div>
        <Card title="Đơn của tôi" className="mt-6" bodyClass="p-0">
          {loading ? <Loading /> : !(mine as any[])?.length ? <Empty>Chưa có đơn</Empty> : <Table head={['Loại', 'Thời gian', 'Ngày', 'Trạng thái', '']}>{(mine as any[]).map(r => (
            <tr key={r.id}><Td>{a.label('leave_type', r.leave_type)}{r.late_notice && <Badge color="amber" className="ml-1">báo gấp</Badge>}</Td><Td className="whitespace-nowrap">{whenText(r)}</Td>
              <Td>{num(r.days, 1)}</Td><Td><Badge color={LS[r.status][1]}>{LS[r.status][0]}</Badge>{r.decision_note && <div className="text-xs text-ink-400">{r.decision_note}</div>}</Td>
              <Td>{['cho_duyet', 'da_duyet'].includes(r.status) && r.start_date > today() && <Button size="sm" variant="ghost" onClick={() => run(async () => { await db.rpc('cancel_request', { p_table: 'leave', p_id: r.id }); reload(); rb(); }, 'Đã hủy đơn')}>Hủy</Button>}</Td></tr>))}</Table>}
        </Card>
      </div>
    </Layout>
  );
}
