import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Empty, Field, Input, Loading, Modal, Select, Table, Td, Textarea, useAction, useLoad, ask } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp, go } from '../../state';
import { fmtDate, fmtDateTime, num, today, addDays } from '../../lib/format';
import { NewLeave, LS } from './Leave';

const KIND: Record<string, string> = { cong_tac: 'Công tác', xac_nhan_cong: 'Xác nhận công', xin_muon_som: 'Xin muộn/sớm' };

export default function Approvals() {
  const a = useApp(); const { run } = useAction(); const [hist, setHist] = useState(false); const [leaveFor, setLeaveFor] = useState(false); const [delOpen, setDelOpen] = useState(false);
  const { data: lv, loading, reload } = useLoad(() => db.from('leave_requests').select('*').neq('profile_id', a.me.id).eq('status', hist ? 'da_duyet' : 'cho_duyet').order('start_date', { asc: !hist }).limit(200), [hist]);
  const { data: ar, reload: r2 } = useLoad(() => db.from('attendance_requests').select('*').neq('profile_id', a.me.id).eq('status', hist ? 'da_duyet' : 'cho_duyet').order('work_date', { asc: !hist }).limit(200), [hist]);
  const { data: dels, reload: r3 } = useLoad(() => db.from('delegations').select('*').is('revoked_at', null).gte('to_at', new Date().toISOString()).order('from_at'), []);
  const decide = async (table: 'leave' | 'attendance', id: string, ok: boolean) => {
    const note = ok ? '' : await ask({ title: 'Từ chối đơn', input: { label: 'Lý do', required: true } });
    if (note === null) return;
    run(async () => { await db.rpc('decide_request', { p_table: table, p_id: id, p_approve: ok, p_note: note || null }); reload(); r2(); }, ok ? 'Đã duyệt' : 'Đã từ chối');
  };
  return (
    <Layout title="Duyệt đơn" actions={<>{a.has('hcns', 'admin', 'bgd') && <Button onClick={() => setLeaveFor(true)}>Tạo đơn nghỉ hộ</Button>}<Button onClick={() => setDelOpen(true)}>Ủy quyền duyệt</Button></>}>
      <div className="mb-3 flex items-center gap-3"><label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={hist} onChange={e => setHist(e.target.checked)} /> Xem đơn đã duyệt</label>
        {(a.isAdmin || a.has('tp_kd')) && <Button size="sm" onClick={() => go('/crm/quotes?status=cho_duyet')}>Báo giá chờ duyệt giá →</Button>}</div>
      <Card title="Đơn nghỉ phép" bodyClass="p-0" className="mb-4">
        {loading ? <Loading /> : !(lv as any[])?.length ? <Empty>Không có đơn</Empty> : <Table head={['Nhân sự', 'Loại', 'Thời gian', 'Ngày', 'Lý do', 'Gửi lúc', '']}>{(lv as any[]).map(r => (
          <tr key={r.id}><Td className="whitespace-nowrap font-medium">{a.personName(r.profile_id)}</Td><Td>{a.label('leave_type', r.leave_type)}</Td>
            <Td className="whitespace-nowrap">{fmtDate(r.start_date)}{r.end_date !== r.start_date && ` – ${fmtDate(r.end_date)}`}{r.part !== 'full' && ` (${r.part === 'am' ? 'sáng' : 'chiều'})`}</Td><Td>{num(r.days, 1)}</Td>
            <Td className="max-w-xs">{r.reason}</Td><Td className="whitespace-nowrap text-xs">{fmtDateTime(r.created_at)}</Td>
            <Td className="whitespace-nowrap">{r.status === 'cho_duyet' ? <><Button size="sm" variant="success" onClick={() => decide('leave', r.id, true)}>Duyệt</Button> <Button size="sm" variant="danger" onClick={() => decide('leave', r.id, false)}>Từ chối</Button></> : <Badge color={LS[r.status][1]}>{LS[r.status][0]}</Badge>}</Td></tr>))}</Table>}
      </Card>
      <Card title="Đơn công (công tác, xác nhận công, đi muộn/về sớm)" bodyClass="p-0" className="mb-4">
        {!(ar as any[])?.length ? <Empty>Không có đơn</Empty> : <Table head={['Nhân sự', 'Loại', 'Ngày', 'Lý do', '']}>{(ar as any[]).map(r => (
          <tr key={r.id}><Td className="font-medium">{a.personName(r.profile_id)}</Td><Td>{KIND[r.kind]}{r.minutes && ` · ${r.minutes} phút`}</Td><Td>{fmtDate(r.work_date)}{r.part !== 'full' && ` (${r.part === 'am' ? 'sáng' : 'chiều'})`}</Td><Td>{r.reason}</Td>
            <Td className="whitespace-nowrap">{r.status === 'cho_duyet' ? <><Button size="sm" variant="success" onClick={() => decide('attendance', r.id, true)}>Duyệt</Button> <Button size="sm" variant="danger" onClick={() => decide('attendance', r.id, false)}>Từ chối</Button></> : <Badge color={LS[r.status][1]}>{LS[r.status][0]}</Badge>}</Td></tr>))}</Table>}
      </Card>
      <Card title="Ủy quyền đang hiệu lực" bodyClass="p-0">
        {!(dels as any[])?.length ? <Empty>Không có</Empty> : <Table head={['Người ủy quyền', 'Người được ủy quyền', 'Từ', 'Đến', 'Lý do', '']}>{(dels as any[]).map(d => (
          <tr key={d.id}><Td>{a.personName(d.delegator_id)}</Td><Td>{a.personName(d.delegate_id)}</Td><Td>{fmtDateTime(d.from_at)}</Td><Td>{fmtDateTime(d.to_at)}</Td><Td>{d.reason}</Td>
            <Td>{(d.delegator_id === a.me.id || a.isAdmin) && <Button size="sm" variant="ghost" onClick={() => run(async () => { await db.from('delegations').update({ revoked_at: new Date().toISOString() }).eq('id', d.id); r3(); }, 'Đã thu hồi')}>Thu hồi</Button>}</Td></tr>))}</Table>}
      </Card>
      <NewLeave forPerson open={leaveFor} onClose={() => setLeaveFor(false)} onDone={() => { setLeaveFor(false); reload(); }} />
      <Delegate open={delOpen} onClose={() => setDelOpen(false)} onDone={() => { setDelOpen(false); r3(); }} />
    </Layout>
  );
}

function Delegate({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [f, setF] = useState({ delegate_id: '', from: today(), to: addDays(today(), 3), reason: '' }); const { busy, run } = useAction();
  return (
    <Modal open={open} onClose={onClose} title="Ủy quyền duyệt khi vắng" size="sm" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      await db.from('delegations').insert({ delegator_id: a.me.id, delegate_id: f.delegate_id, from_at: new Date(f.from + 'T00:00:00+07:00').toISOString(), to_at: new Date(f.to + 'T23:59:59+07:00').toISOString(), reason: f.reason || null }); onDone();
    }, 'Đã ủy quyền')}>Ủy quyền</Button>}>
      <div className="space-y-3">
        <Field label="Người được ủy quyền" required><Select options={a.people.filter(p => p.id !== a.me.id).map(p => [p.id, p.full_name])} value={f.delegate_id} onChange={v => setF({ ...f, delegate_id: v })} placeholder="— Chọn —" /></Field>
        <div className="grid grid-cols-2 gap-3"><Field label="Từ ngày"><Input type="date" value={f.from} onChange={e => setF({ ...f, from: e.target.value })} /></Field><Field label="Đến ngày (tối đa 30 ngày)"><Input type="date" value={f.to} onChange={e => setF({ ...f, to: e.target.value })} /></Field></div>
        <Field label="Lý do"><Textarea value={f.reason} onChange={e => setF({ ...f, reason: e.target.value })} /></Field>
        <p className="text-xs text-ink-500">Người được ủy quyền duyệt được đơn của cấp dưới bạn trong thời gian này. Mọi lần duyệt đều ghi nhật ký.</p>
      </div>
    </Modal>
  );
}
