import React, { useState } from 'react';
import { Layout } from '../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, Select, Tabs, Textarea, toast, useAction, useLoad } from '../components/ui';
import { Pager, usePager } from '../components/Pager';
import { db, storage } from '../lib/sb';
import { go, useApp, useRoute } from '../state';
import { fmtDateTime } from '../lib/format';
import { compressImage } from '../lib/image';

const PRIO: [string, string][] = [['binh_thuong', 'Bình thường'], ['gap', 'Gấp'], ['khan', 'Khẩn']];
const ST: [string, string][] = [['moi', 'Mới'], ['dang_xu_ly', 'Đang xử lý'], ['cho_phan_hoi', 'Chờ phản hồi'], ['xong', 'Đã xong'], ['dong', 'Đóng']];
const stColor: Record<string, string> = { moi: 'red', dang_xu_ly: 'blue', cho_phan_hoi: 'amber', xong: 'green', dong: 'gray' };
const OPEN = ['moi', 'dang_xu_ly', 'cho_phan_hoi'];

export default function Tickets() {
  const a = useApp(); const { query } = useRoute();
  const [open, setOpen] = useState(false); const [tab, setTab] = useState('todo'); const [q, setQ] = useState('');
  const { data, loading, reload } = useLoad(() => db.from('tickets').select('*').order('created_at', { asc: false }).limit(500), []);
  const all = ((data as any[]) || []).filter(t => !q || `${t.title} ${t.description} ${t.answer || ''}`.toLowerCase().includes(q.toLowerCase()));
  const handles = (t: any) => t.assignee_id === a.me.id || (!t.assignee_id && (a.isAdmin || (t.type === 'claim_hoa_hong' && a.has('ke_toan'))));
  const lists: Record<string, any[]> = {
    todo: all.filter(t => handles(t) && OPEN.includes(t.status)),
    open: all.filter(t => t.reporter_id === a.me.id && OPEN.includes(t.status)),
    done: all.filter(t => (t.reporter_id === a.me.id || handles(t)) && !OPEN.includes(t.status)),
    faq: all.filter(t => t.is_public && t.answer),
  };
  const rows = lists[tab]; const sel = ((data as any[]) || []).find(t => t.id === query.id);
  const pg = usePager('tickets', [tab, q]);
  return (
    <Layout title="Claim & hỏi đáp" actions={<Button variant="dark" onClick={() => setOpen(true)}>Gửi claim / câu hỏi</Button>}>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <Tabs value={tab} onChange={setTab} tabs={[['todo', `Cần tôi xử lý ${lists.todo.length}`], ['open', `Đang mở ${lists.open.length}`], ['done', `Đã xong ${lists.done.length}`], ['faq', `Hỏi đáp chung ${lists.faq.length}`]]} />
        <Input className="max-w-xs" placeholder="Tìm trong tiêu đề, nội dung, câu trả lời…" value={q} onChange={e => setQ(e.target.value)} />
        <span className="text-xs text-ink-500">Claim, đề xuất, câu hỏi gửi thẳng Quản trị. Câu hỏi hay được đưa vào Hỏi đáp chung.</span>
      </div>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
        <Card bodyClass="p-0" className={cx(sel && 'hidden lg:block')}>{loading ? <Loading /> : !rows.length ? <Empty>Không có mục nào.</Empty> :
          <ul className="divide-y divide-ink-100">{pg.slice(rows).map(t => <li key={t.id}><button onClick={() => go(`/tickets?id=${t.id}`)} className={cx('w-full px-4 py-3 text-left hover:bg-ink-50', query.id === t.id && 'bg-brand-50')}>
            <div className="flex flex-wrap items-center gap-1.5"><b className="text-sm">{t.title}</b><Badge color={stColor[t.status]}>{ST.find(s => s[0] === t.status)?.[1]}</Badge>{['gap', 'khan', 'cao'].includes(t.priority) && <Badge color="solidred">{t.priority === 'khan' ? 'Khẩn' : 'Gấp'}</Badge>}</div>
            <div className="text-xs text-ink-500">{t.code} · {a.label('claim_type', t.type) || t.type} · {a.personName(t.reporter_id)} · {fmtDateTime(t.created_at)}</div></button></li>)}</ul>}
          {rows.length > 0 && <Pager p={pg} total={rows.length} />}
        </Card>
        {sel ? <TicketView t={sel} onChanged={reload} /> : <Card className="hidden lg:block"><Empty>Chọn một mục để xem</Empty></Card>}
      </div>
      {open && <NewTicket onClose={() => setOpen(false)} onDone={id => { setOpen(false); setTab('open'); reload(); go(`/tickets?id=${id}`); }} />}
    </Layout>
  );
}

function NewTicket({ onClose, onDone }: { onClose: () => void; onDone: (id: string) => void }) {
  const a = useApp(); const [f, setF] = useState({ type: '', priority: 'binh_thuong', title: '', description: '', customer_text: '', order_code: '' });
  const [imgs, setImgs] = useState<Blob[]>([]); const { busy, run } = useAction();
  const addFiles = async (files: FileList | File[]) => { const out: Blob[] = []; for (const f of Array.from(files)) if (f.type.startsWith('image/')) out.push(await compressImage(f, 1600, 190)); setImgs(x => [...x, ...out].slice(0, 5)); };
  const send = () => run(async () => {
    if (!f.type || !f.title.trim() || f.description.trim().length < 5) throw new Error('Chọn loại, nhập tiêu đề và nội dung');
    const paths: string[] = [];
    for (const [i, b] of imgs.entries()) paths.push(await storage.upload('attachments', `${a.me.id}/${Date.now()}-${i}.jpg`, b));
    const r: any[] = await db.from('tickets').insert({ ...f, title: f.title.trim(), description: f.description.trim(), reporter_id: a.me.id, attachments: paths });
    onDone(r[0].id);
  }, 'Đã gửi');
  return (
    <Modal open onClose={onClose} title="Gửi claim / câu hỏi tới Quản trị" footer={<><Button onClick={onClose}>Hủy</Button><Button variant="primary" loading={busy} onClick={send}>Gửi</Button></>}>
      <div className="space-y-3" onPaste={e => { const fs = Array.from(e.clipboardData.files || []); if (fs.length) addFiles(fs); }}>
        <div className="grid gap-3 sm:grid-cols-2"><Field label="Loại" required><Select options={a.opts('claim_type')} value={f.type} onChange={v => setF({ ...f, type: v })} placeholder="— Chọn —" /></Field>
          <Field label="Mức độ"><Select options={PRIO} value={f.priority} onChange={v => setF({ ...f, priority: v })} /></Field></div>
        <Field label="Tiêu đề" required><Input value={f.title} onChange={e => setF({ ...f, title: e.target.value })} /></Field>
        <Field label="Nội dung" required><Textarea rows={4} value={f.description} onChange={e => setF({ ...f, description: e.target.value })} placeholder="Mô tả rõ sự việc, thời điểm, mong muốn…" /></Field>
        <div className="grid gap-3 sm:grid-cols-2"><Field label="Khách liên quan (nếu có)"><Input placeholder="Mã hoặc tên KH" value={f.customer_text} onChange={e => setF({ ...f, customer_text: e.target.value })} /></Field>
          <Field label="Mã đơn liên quan"><Input value={f.order_code} onChange={e => setF({ ...f, order_code: e.target.value })} /></Field></div>
        <Field label="Ảnh đính kèm (nếu có)"><div className="rounded-xl border border-dashed border-ink-300 p-3">
          <div className="flex flex-wrap items-center gap-2"><label className="cursor-pointer rounded-lg border border-ink-200 bg-white px-3 py-1 text-sm font-semibold">Chọn ảnh<input type="file" accept="image/*" multiple className="hidden" onChange={e => e.target.files && addFiles(e.target.files)} /></label>
            <span className="text-xs text-ink-500">hoặc chụp màn hình rồi bấm Ctrl+V tại đây</span></div>
          {imgs.length > 0 && <div className="mt-2 flex flex-wrap gap-2">{imgs.map((b, i) => <div key={i} className="relative"><img src={URL.createObjectURL(b)} className="h-16 w-16 rounded-lg object-cover" alt="" />
            <button className="absolute -right-1 -top-1 rounded-full bg-ink-900 px-1.5 text-xs text-white" onClick={() => setImgs(x => x.filter((_, j) => j !== i))}>×</button></div>)}</div>}
        </div></Field>
      </div>
    </Modal>
  );
}

function TicketView({ t, onChanged }: { t: any; onChanged: () => void }) {
  const a = useApp(); const [msg, setMsg] = useState(''); const [ans, setAns] = useState(t.answer || ''); const { busy, run } = useAction(); const [img, setImg] = useState<string | null>(null);
  const { data, reload } = useLoad(() => db.from('ticket_comments').select('*').eq('ticket_id', t.id).order('created_at'), [t.id]);
  const handler = a.isAdmin || t.assignee_id === a.me.id || (t.type === 'claim_hoa_hong' && a.has('ke_toan'));
  const upd = (v: any, okMsg = 'Đã cập nhật') => run(async () => { await db.from('tickets').update(v).eq('id', t.id); onChanged(); }, okMsg);
  React.useEffect(() => setAns(t.answer || ''), [t.id]);
  return (
    <Card title={<span className="flex items-center gap-2"><button className="text-brand-700 lg:hidden" onClick={() => go('/tickets')}>←</button>{t.code} · {t.title}</span>}>
      <div className="mb-3 flex flex-wrap gap-2 text-xs text-ink-500"><Badge>{a.label('claim_type', t.type) || t.type}</Badge>{a.personName(t.reporter_id)} · {fmtDateTime(t.created_at)}
        {t.customer_text && <span>· KH: <b className="text-ink-800">{t.customer_text}</b></span>}{t.order_code && <span>· Đơn: <b className="text-ink-800">{t.order_code}</b></span>}</div>
      {handler && <div className="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
        <Field label="Trạng thái"><Select options={ST} value={t.status} onChange={v => upd({ status: v })} /></Field>
        <Field label="Người xử lý"><Select disabled={!a.isAdmin} options={a.people.map(p => [p.id, p.full_name])} value={t.assignee_id || ''} onChange={v => upd({ assignee_id: v || null })} placeholder="— Quản trị —" /></Field>
        <Field label="Mức độ"><Select disabled={!a.isAdmin} options={PRIO} value={t.priority} onChange={v => upd({ priority: v })} /></Field>
      </div>}
      {!handler && t.reporter_id === a.me.id && t.status !== 'dong' && <Button size="sm" className="mb-3" onClick={() => upd({ status: 'dong' })}>Đóng yêu cầu</Button>}
      <p className="mb-3 whitespace-pre-wrap rounded-xl bg-ink-50 p-3 text-sm">{t.description}</p>
      {t.attachments?.length > 0 && <div className="mb-3 flex flex-wrap gap-2">{t.attachments.map((p: string) => <button key={p} className="rounded-lg border border-ink-200 px-2 py-1 text-xs text-brand-700"
        onClick={() => run(async () => setImg(await storage.signedUrl('attachments', p, 300)))}>🖼 Xem ảnh</button>)}</div>}
      <div className="mb-3 rounded-xl border-2 border-ink-900 p-3 shadow-pop-sm">
        <div className="mb-1 text-xs font-bold uppercase text-ink-500">Trả lời của Quản trị</div>
        {handler ? <><Textarea rows={3} value={ans} onChange={e => setAns(e.target.value)} placeholder="Trả lời / kết quả xử lý…" />
          <div className="mt-2 flex flex-wrap items-center gap-3"><Button size="sm" variant="primary" loading={busy} onClick={() => upd({ answer: ans || null, status: ans ? 'xong' : t.status }, 'Đã trả lời')}>Lưu trả lời</Button>
            {a.isAdmin && <label className="flex items-center gap-1.5 text-sm"><input type="checkbox" checked={t.is_public} onChange={e => upd({ is_public: e.target.checked })} /> Đưa vào Hỏi đáp chung</label>}</div></>
          : <p className="whitespace-pre-wrap text-sm">{t.answer || <span className="text-ink-400">Chưa có trả lời</span>}</p>}
      </div>
      <div className="space-y-2">{((data as any[]) || []).map(c => <div key={c.id} className="rounded-xl border border-ink-100 p-2.5 text-sm"><div className="text-xs text-ink-500">{a.personName(c.author_id)} · {fmtDateTime(c.created_at)}</div><div className="whitespace-pre-wrap">{c.body}</div></div>)}</div>
      {t.status !== 'dong' && <div className="mt-3 flex gap-2"><Input placeholder="Trao đổi thêm…" value={msg} onChange={e => setMsg(e.target.value)} />
        <Button variant="dark" loading={busy} onClick={() => msg.trim() && run(async () => { await db.from('ticket_comments').insert({ ticket_id: t.id, author_id: a.me.id, body: msg.trim() }); setMsg(''); reload(); })}>Gửi</Button></div>}
      <Modal open={!!img} onClose={() => setImg(null)} title="Ảnh đính kèm">{img && <img src={img} className="w-full rounded-lg" alt="" />}</Modal>
    </Card>
  );
}
