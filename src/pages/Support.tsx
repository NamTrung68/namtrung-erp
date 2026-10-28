import React, { useEffect, useState } from 'react';
import { Layout } from '../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, Select, Textarea, useAction, useLoad } from '../components/ui';
import { db } from '../lib/sb';
import { go, useApp, useRoute } from '../state';
import { fmtDateTime } from '../lib/format';

const ST: Record<string, [string, string]> = { moi: ['Mới', 'red'], da_nhan: ['Đã nhận', 'amber'], dang_xu_ly: ['Đang xử lý', 'blue'], xong: ['Đã xong', 'green'], dong: ['Đóng', 'gray'] };
const PR: [string, string][] = [['thap', 'Thấp'], ['thuong', 'Thường'], ['gap', 'Gấp']];

export default function Support() {
  const a = useApp(); const { query } = useRoute();
  const [newOpen, setNewOpen] = useState(query.new === '1');
  const [filter, setFilter] = useState('open');
  const { data, loading, reload } = useLoad(async () => {
    let q = db.from('support_requests').select('*').order('created_at', { asc: false }).limit(200);
    if (filter === 'open') q = q.in('status', ['moi', 'da_nhan', 'dang_xu_ly']);
    return q;
  }, [filter]);
  useEffect(() => { if (query.new === '1') setNewOpen(true); }, [query.new]);
  const sel = (data as any[] || []).find(x => x.id === query.id);
  return (
    <Layout title="Gọi hỗ trợ" actions={<Button variant="dark" onClick={() => setNewOpen(true)}>🆘 Gọi hỗ trợ</Button>}>
      <div className="mb-3 flex gap-2"><Select className="w-48" options={[['open', 'Đang mở'], ['all', 'Tất cả']]} value={filter} onChange={setFilter} /></div>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
        <Card bodyClass="p-0">
          {loading ? <Loading /> : !(data as any[])?.length ? <Empty>Không có yêu cầu</Empty> :
            <ul className="divide-y divide-ink-100">{(data as any[]).map(r => <li key={r.id}>
              <button onClick={() => go(`/support?id=${r.id}`)} className={cx('w-full px-4 py-3 text-left hover:bg-ink-50', query.id === r.id && 'bg-brand-50')}>
                <div className="flex items-center gap-2"><b className="text-sm">{r.title}</b><Badge color={ST[r.status][1]}>{ST[r.status][0]}</Badge>{r.priority === 'gap' && <Badge color="solidred">Gấp</Badge>}</div>
                <div className="text-xs text-ink-500">{r.code} · {a.personName(r.requester_id)} → {r.assignee_id ? a.personName(r.assignee_id) : a.units.find(u => u.id === r.org_unit_id)?.name} · {fmtDateTime(r.created_at)}</div>
              </button></li>)}</ul>}
        </Card>
        {sel ? <Thread req={sel} onChanged={reload} /> : <Card><Empty>Chọn một yêu cầu để xem trao đổi</Empty></Card>}
      </div>
      <NewSupport open={newOpen} customer={query.customer} onClose={() => { setNewOpen(false); if (query.new) go('/support'); }} onDone={id => { setNewOpen(false); reload(); go(`/support?id=${id}`); }} />
    </Layout>
  );
}

function NewSupport({ open, customer, onClose, onDone }: { open: boolean; customer?: string; onClose: () => void; onDone: (id: string) => void }) {
  const a = useApp(); const [f, setF] = useState({ to: '', title: '', content: '', priority: 'thuong' }); const { busy, run } = useAction();
  const opts: [string, string][] = [...a.units.filter(u => u.kind !== 'cong_ty').map(u => ['u:' + u.id, '🏢 Phòng ' + u.name] as [string, string]), ...a.people.filter(p => p.id !== a.me.id && p.status === 'active').map(p => ['p:' + p.id, p.full_name] as [string, string])];
  return (
    <Modal open={open} onClose={onClose} title="Gọi hỗ trợ" size="sm" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      if (!f.to || !f.title.trim()) throw new Error('Chọn người/phòng nhận và nhập tiêu đề');
      const r: any[] = await db.from('support_requests').insert({ requester_id: a.me.id, title: f.title.trim(), content: f.content || null, priority: f.priority, customer_id: customer || null,
        assignee_id: f.to.startsWith('p:') ? f.to.slice(2) : null, org_unit_id: f.to.startsWith('u:') ? f.to.slice(2) : null });
      onDone(r[0].id);
    }, 'Đã gửi yêu cầu hỗ trợ')}>Gửi</Button>}>
      <div className="space-y-3">
        <Field label="Gửi tới" required><Select options={opts} value={f.to} onChange={v => setF({ ...f, to: v })} placeholder="— Chọn người hoặc phòng —" /></Field>
        <Field label="Cần hỗ trợ việc gì" required><Input value={f.title} onChange={e => setF({ ...f, title: e.target.value })} /></Field>
        <Field label="Chi tiết"><Textarea value={f.content} onChange={e => setF({ ...f, content: e.target.value })} /></Field>
        <Field label="Mức độ"><Select options={PR} value={f.priority} onChange={v => setF({ ...f, priority: v })} /></Field>
      </div>
    </Modal>
  );
}

function Thread({ req, onChanged }: { req: any; onChanged: () => void }) {
  const a = useApp(); const [msg, setMsg] = useState(''); const { busy, run } = useAction();
  const { data, reload } = useLoad(() => db.from('support_messages').select('*').eq('request_id', req.id).order('created_at'), [req.id]);
  const setStatus = (s: string) => run(async () => { await db.from('support_requests').update({ status: s, resolved_at: s === 'xong' ? new Date().toISOString() : null }).eq('id', req.id); onChanged(); }, 'Đã cập nhật');
  const handler = req.assignee_id === a.me.id || (!req.assignee_id && req.org_unit_id && a.people.find(p => p.id === a.me.id)?.org_unit_id === req.org_unit_id) || a.isAdmin;
  return (
    <Card title={`${req.code} · ${req.title}`} actions={<>
      {handler && req.status === 'moi' && <Button size="sm" onClick={() => setStatus('da_nhan')}>Nhận việc</Button>}
      {handler && ['moi', 'da_nhan'].includes(req.status) && <Button size="sm" onClick={() => setStatus('dang_xu_ly')}>Đang xử lý</Button>}
      {handler && req.status !== 'xong' && req.status !== 'dong' && <Button size="sm" variant="success" onClick={() => setStatus('xong')}>Đã xong</Button>}
      {req.requester_id === a.me.id && req.status === 'xong' && <Button size="sm" onClick={() => setStatus('dong')}>Đóng</Button>}</>}>
      {req.content && <p className="mb-3 whitespace-pre-wrap rounded-lg bg-ink-50 p-3 text-sm">{req.content}</p>}
      {req.customer_id && <a className="mb-3 inline-block text-sm text-brand-700" href={`#/crm/customer?id=${req.customer_id}`}>Mở hồ sơ khách</a>}
      <div className="max-h-[50vh] space-y-2 overflow-y-auto">{(data as any[] || []).map(m => <div key={m.id} className={cx('rounded-lg p-2.5 text-sm', m.author_id === a.me.id ? 'ml-8 bg-brand-50' : 'mr-8 bg-ink-50')}>
        <div className="text-xs text-ink-500">{a.personName(m.author_id)} · {fmtDateTime(m.created_at)}</div><div className="whitespace-pre-wrap">{m.body}</div></div>)}</div>
      {req.status !== 'dong' && <div className="mt-3 flex gap-2"><Input placeholder="Nhắn trao đổi…" value={msg} onChange={e => setMsg(e.target.value)} onKeyDown={e => e.key === 'Enter' && msg.trim() && run(async () => { await db.from('support_messages').insert({ request_id: req.id, author_id: a.me.id, body: msg.trim() }); setMsg(''); reload(); })} />
        <Button variant="dark" loading={busy} onClick={() => msg.trim() && run(async () => { await db.from('support_messages').insert({ request_id: req.id, author_id: a.me.id, body: msg.trim() }); setMsg(''); reload(); })}>Gửi</Button></div>}
    </Card>
  );
}
