import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Empty, Field, Input, Loading, Modal, Select, Stat, Table, Td, Textarea, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { addDays, fmtDate, monthEnd, num, today, weekStart } from '../../lib/format';

export const LS: Record<string, [string, string]> = { cho_duyet: ['Chờ duyệt', 'amber'], da_duyet: ['Đã duyệt', 'green'], tu_choi: ['Từ chối', 'red'], huy: ['Đã hủy', 'gray'] };

export default function Leave() {
  const a = useApp(); const [open, setOpen] = useState(false); const { run } = useAction();
  const { data: bal, reload: rb } = useLoad(() => db.rpc('leave_balance', {}), []);
  const { data, loading, reload } = useLoad(() => db.from('leave_requests').select('*').eq('profile_id', a.me.id).order('start_date', { asc: false }).limit(100), []);
  const [range, setRange] = useState<'week' | 'month'>('week');
  const from = range === 'week' ? weekStart() : today().slice(0, 8) + '01'; const to = range === 'week' ? addDays(weekStart(), 6) : monthEnd();
  const { data: board } = useLoad(() => db.rpc('leave_board', { p_from: from, p_to: to }), [range]);
  const { data: ledger } = useLoad(() => db.from('leave_ledger').select('*').eq('profile_id', a.me.id).order('entry_date', { asc: false }).limit(50), []);
  return (
    <Layout title="Nghỉ phép" actions={<Button variant="dark" onClick={() => setOpen(true)}>Xin nghỉ</Button>}>
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Phép năm còn dùng được" value={num(bal?.available, 1)} tone="green" />
        <Stat label="Số dư sổ phép" value={num(bal?.balance, 1)} />
        <Stat label="Đang chờ duyệt" value={num(bal?.pending, 1)} />
        <Stat label="Đã dùng năm nay" value={num(bal?.used_year, 1)} />
      </div>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
        <Card title="Đơn nghỉ của tôi" bodyClass="p-0">
          {loading ? <Loading /> : !(data as any[])?.length ? <Empty>Chưa có đơn</Empty> : <Table head={['Loại', 'Thời gian', 'Số ngày', 'Trạng thái', '']}>{(data as any[]).map(r => (
            <tr key={r.id}><Td>{a.label('leave_type', r.leave_type)}</Td><Td className="whitespace-nowrap">{fmtDate(r.start_date)}{r.end_date !== r.start_date && ` – ${fmtDate(r.end_date)}`}{r.part !== 'full' && ` (${r.part === 'am' ? 'sáng' : 'chiều'})`}</Td>
              <Td>{num(r.days, 1)}</Td><Td><Badge color={LS[r.status][1]}>{LS[r.status][0]}</Badge>{r.decision_note && <div className="text-xs text-ink-400">{r.decision_note}</div>}</Td>
              <Td>{['cho_duyet', 'da_duyet'].includes(r.status) && r.start_date > today() && <Button size="sm" variant="ghost" onClick={() => run(async () => { await db.rpc('cancel_request', { p_table: 'leave', p_id: r.id }); reload(); rb(); }, 'Đã hủy đơn')}>Hủy</Button>}</Td></tr>))}</Table>}
        </Card>
        <Card title="Ai nghỉ" actions={<Select className="w-32" options={[['week', 'Tuần này'], ['month', 'Tháng này']]} value={range} onChange={v => setRange(v as any)} />} bodyClass="p-0">
          {!(board as any[])?.length ? <Empty>Không ai nghỉ</Empty> : <ul className="divide-y divide-ink-100">{(board as any[]).map((b, i) => <li key={i} className="flex justify-between px-4 py-2 text-sm">
            <span>{b.full_name}</span><span className="text-ink-500">{fmtDate(b.start_date).slice(0, 5)}{b.end_date !== b.start_date && '–' + fmtDate(b.end_date).slice(0, 5)}{b.part !== 'full' && (b.part === 'am' ? ' sáng' : ' chiều')} {b.status === 'cho_duyet' && <Badge color="amber">chờ</Badge>}</span></li>)}</ul>}
        </Card>
      </div>
      <Card title="Sổ phép năm" className="mt-4" bodyClass="p-0">
        {!(ledger as any[])?.length ? <Empty>Chưa có phát sinh. Phép cộng 1 ngày mỗi tháng làm việc đủ; phép năm cũ dùng đến hết 30/06 năm sau.</Empty> :
          <Table head={['Ngày', 'Loại', 'Số ngày', 'Ghi chú']}>{(ledger as any[]).map(l => <tr key={l.id}><Td>{fmtDate(l.entry_date)}</Td><Td>{({ accrue: 'Cộng phép', use: 'Sử dụng', expire: 'Hết hạn', adjust: 'Điều chỉnh', opening: 'Số dư đầu' } as any)[l.kind]}</Td>
            <Td className={Number(l.days) < 0 ? 'text-red-600' : 'text-emerald-700'}>{Number(l.days) > 0 && '+'}{num(l.days, 1)}</Td><Td>{l.note}</Td></tr>)}</Table>}
      </Card>
      <NewLeave open={open} onClose={() => setOpen(false)} onDone={() => { setOpen(false); reload(); rb(); }} />
    </Layout>
  );
}

export function NewLeave({ open, onClose, onDone, forPerson }: { open: boolean; onClose: () => void; onDone: () => void; forPerson?: boolean }) {
  const a = useApp(); const [f, setF] = useState({ profile_id: '', leave_type: 'phep_nam', start_date: addDays(today(), 1), end_date: addDays(today(), 1), part: 'full', reason: '' }); const { busy, run } = useAction();
  const single = f.start_date === f.end_date;
  return (
    <Modal open={open} onClose={onClose} title={forPerson ? 'Tạo đơn nghỉ hộ nhân sự' : 'Xin nghỉ'} size="sm" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      if (f.end_date < f.start_date) throw new Error('Ngày kết thúc phải sau ngày bắt đầu');
      await db.from('leave_requests').insert({ ...f, profile_id: forPerson ? f.profile_id : a.me.id, part: single ? f.part : 'full' }); onDone();
    }, 'Đã gửi đơn — chờ quản lý duyệt')}>Gửi đơn</Button>}>
      <div className="space-y-3">
        {forPerson && <Field label="Nhân sự" required><Select options={a.people.map(p => [p.id, p.full_name])} value={f.profile_id} onChange={v => setF({ ...f, profile_id: v })} placeholder="— Chọn —" /></Field>}
        <Field label="Loại nghỉ"><Select options={a.opts('leave_type')} value={f.leave_type} onChange={v => setF({ ...f, leave_type: v })} /></Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Từ ngày"><Input type="date" value={f.start_date} onChange={e => setF({ ...f, start_date: e.target.value, end_date: e.target.value > f.end_date ? e.target.value : f.end_date })} /></Field>
          <Field label="Đến ngày"><Input type="date" value={f.end_date} min={f.start_date} onChange={e => setF({ ...f, end_date: e.target.value })} /></Field>
        </div>
        {single && <Field label="Buổi"><Select options={[['full', 'Cả ngày'], ['am', 'Buổi sáng'], ['pm', 'Buổi chiều']]} value={f.part} onChange={v => setF({ ...f, part: v })} /></Field>}
        <Field label="Lý do (chỉ quản lý và HCNS thấy)"><Textarea value={f.reason} onChange={e => setF({ ...f, reason: e.target.value })} /></Field>
        <p className="text-xs text-ink-500">Thứ Bảy văn phòng tính 0,5 ngày; Chủ nhật và ngày lễ không tính. Hết phép năm thì chọn "Nghỉ không lương".</p>
      </div>
    </Modal>
  );
}
