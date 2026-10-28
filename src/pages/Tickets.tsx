import React, { useState } from 'react';
import { Layout } from '../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, Select, Textarea, useAction, useLoad } from '../components/ui';
import { db } from '../lib/sb';
import { go, useApp, useRoute } from '../state';
import { fmtDateTime } from '../lib/format';

const TYPES: [string, string][] = [['y_tuong', 'Ý tưởng'], ['loi', 'Lỗi hệ thống'], ['cai_tien', 'Yêu cầu cải tiến'], ['khac', 'Khác']];
const PRIO: [string, string][] = [['thap', 'Thấp'], ['trung_binh', 'Trung bình'], ['cao', 'Cao'], ['khan', 'Khẩn']];
const ST: [string, string][] = [['moi', 'Mới'], ['dang_xu_ly', 'Đang xử lý'], ['cho_phan_hoi', 'Chờ phản hồi'], ['xong', 'Đã xong'], ['dong', 'Đóng']];
const stColor: Record<string, string> = { moi: 'red', dang_xu_ly: 'blue', cho_phan_hoi: 'amber', xong: 'green', dong: 'gray' };

export default function Tickets() {
  const a = useApp(); const { query } = useRoute();
  const [open, setOpen] = useState(false); const [st, setSt] = useState(''); const [type, setType] = useState('');
  const { data, loading, reload } = useLoad(async () => {
    let q = db.from('tickets').select('*').order('created_at', { asc: false }).limit(300);
    if (st) q = q.eq('status', st); if (type) q = q.eq('type', type);
    return q;
  }, [st, type]);
  const sel = ((data as any[]) || []).find(t => t.id === query.id);
  const counts = Object.fromEntries(ST.map(([k]) => [k, ((data as any[]) || []).filter(t => t.status === k).length]));
  return (
    <Layout title="Ý tưởng · Lỗi · Cải tiến" actions={<Button variant="dark" onClick={() => setOpen(true)}>Tạo ticket</Button>}>
      <div className="mb-3 flex flex-wrap gap-2">
        <Select className="w-44" options={ST.map(([k, l]) => [k, `${l} (${counts[k] ?? 0})`])} value={st} onChange={setSt} placeholder="Mọi trạng thái" />
        <Select className="w-44" options={TYPES} value={type} onChange={setType} placeholder="Mọi loại" />
      </div>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
        <Card bodyClass="p-0">{loading ? <Loading /> : !(data as any[])?.length ? <Empty>Chưa có ticket</Empty> :
          <ul className="divide-y divide-ink-100">{(data as any[]).map(t => <li key={t.id}><button onClick={() => go(`/tickets?id=${t.id}`)} className={cx('w-full px-4 py-3 text-left hover:bg-ink-50', query.id === t.id && 'bg-brand-50')}>
            <div className="flex flex-wrap items-center gap-2"><b className="text-sm">{t.title}</b><Badge color={stColor[t.status]}>{ST.find(s => s[0] === t.status)?.[1]}</Badge>{['cao', 'khan'].includes(t.priority) && <Badge color="red">{PRIO.find(p => p[0] === t.priority)?.[1]}</Badge>}</div>
            <div className="text-xs text-ink-500">{t.code} · {TYPES.find(x => x[0] === t.type)?.[1]} · {a.personName(t.reporter_id)} · {fmtDateTime(t.created_at)}</div></button></li>)}</ul>}
        </Card>
        {sel ? <TicketView t={sel} onChanged={reload} /> : <Card><Empty>Chọn ticket để xem</Empty></Card>}
      </div>
      <NewTicket open={open} onClose={() => setOpen(false)} onDone={id => { setOpen(false); reload(); go(`/tickets?id=${id}`); }} />
    </Layout>
  );
}

function NewTicket({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: (id: string) => void }) {
  const a = useApp(); const [f, setF] = useState({ type: 'y_tuong', title: '', description: '', priority: 'trung_binh' }); const { busy, run } = useAction();
  return (
    <Modal open={open} onClose={onClose} title="Tạo ticket" size="sm" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      if (!f.title.trim() || !f.description.trim()) throw new Error('Nhập tiêu đề và mô tả');
      const r: any[] = await db.from('tickets').insert({ ...f, reporter_id: a.me.id }); onDone(r[0].id);
    }, 'Đã gửi ticket')}>Gửi</Button>}>
      <div className="space-y-3">
        <div className="grid grid-cols-2 gap-3"><Field label="Loại"><Select options={TYPES} value={f.type} onChange={v => setF({ ...f, type: v })} /></Field>
          <Field label="Mức ưu tiên"><Select options={PRIO} value={f.priority} onChange={v => setF({ ...f, priority: v })} /></Field></div>
        <Field label="Tiêu đề" required><Input value={f.title} onChange={e => setF({ ...f, title: e.target.value })} /></Field>
        <Field label="Mô tả (lỗi gì, ở màn hình nào, mong muốn gì)" required><Textarea rows={5} value={f.description} onChange={e => setF({ ...f, description: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

function TicketView({ t, onChanged }: { t: any; onChanged: () => void }) {
  const a = useApp(); const [msg, setMsg] = useState(''); const { busy, run } = useAction();
  const { data, reload } = useLoad(() => db.from('ticket_comments').select('*').eq('ticket_id', t.id).order('created_at'), [t.id]);
  const upd = (v: any) => run(async () => { await db.from('tickets').update(v).eq('id', t.id); onChanged(); }, 'Đã cập nhật');
  return (
    <Card title={`${t.code} · ${t.title}`}>
      <div className="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
        <Field label="Trạng thái"><Select disabled={!(a.isAdmin || t.assignee_id === a.me.id || t.reporter_id === a.me.id)} options={a.isAdmin || t.assignee_id === a.me.id ? ST : ST.filter(s => ['moi', 'dong', t.status].includes(s[0]))} value={t.status} onChange={v => upd({ status: v })} /></Field>
        <Field label="Phụ trách"><Select disabled={!a.isAdmin} options={a.people.map(p => [p.id, p.full_name])} value={t.assignee_id || ''} onChange={v => upd({ assignee_id: v || null })} placeholder="— Chưa giao —" /></Field>
        <Field label="Ưu tiên"><Select disabled={!a.isAdmin} options={PRIO} value={t.priority} onChange={v => upd({ priority: v })} /></Field>
      </div>
      <p className="mb-3 whitespace-pre-wrap rounded-lg bg-ink-50 p-3 text-sm">{t.description}</p>
      <div className="space-y-2">{((data as any[]) || []).map(c => <div key={c.id} className="rounded-lg border border-ink-100 p-2.5 text-sm"><div className="text-xs text-ink-500">{a.personName(c.author_id)} · {fmtDateTime(c.created_at)}</div><div className="whitespace-pre-wrap">{c.body}</div></div>)}</div>
      <div className="mt-3 flex gap-2"><Input placeholder="Bình luận…" value={msg} onChange={e => setMsg(e.target.value)} />
        <Button variant="dark" loading={busy} onClick={() => msg.trim() && run(async () => { await db.from('ticket_comments').insert({ ticket_id: t.id, author_id: a.me.id, body: msg.trim() }); setMsg(''); reload(); })}>Gửi</Button></div>
    </Card>
  );
}
