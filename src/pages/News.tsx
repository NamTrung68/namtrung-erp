import React, { useEffect, useState } from 'react';
import { Layout } from '../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, Select, Textarea, useAction, useLoad, Chips } from '../components/ui';
import { db } from '../lib/sb';
import { go, useApp, useRoute } from '../state';
import { fmtDateTime } from '../lib/format';

const CATS: [string, string][] = [['chung', 'Thông báo chung'], ['quy_dinh', 'Quy định'], ['nhan_su', 'Nhân sự'], ['kinh_doanh', 'Kinh doanh'], ['su_kien', 'Sự kiện']];

export default function News() {
  const a = useApp(); const { query } = useRoute(); const [open, setOpen] = useState(false);
  const canPost = a.isAdmin || a.has('hcns', 'tp_kd', 'tn_kd');
  const { data, loading, reload } = useLoad(() => db.from('announcements').select('*').order('pinned', { asc: false }).order('publish_at', { asc: false }).limit(100), []);
  const { data: reads, reload: reloadReads } = useLoad(() => db.from('announcement_reads').select('announcement_id').eq('user_id', a.me.id), []);
  const readSet = new Set(((reads as any[]) || []).map(r => r.announcement_id));
  const sel = ((data as any[]) || []).find(x => x.id === query.id);
  useEffect(() => { if (sel && !readSet.has(sel.id)) db.from('announcement_reads').upsert({ announcement_id: sel.id, user_id: a.me.id }, 'announcement_id,user_id').then(reloadReads, () => {}); }, [sel?.id, reads]);
  const { run } = useAction();
  return (
    <Layout title="Bảng tin nội bộ" actions={canPost && <Button variant="dark" onClick={() => setOpen(true)}>Đăng thông báo</Button>}>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)]">
        <Card bodyClass="p-0">{loading ? <Loading /> : !(data as any[])?.length ? <Empty>Chưa có thông báo</Empty> :
          <ul className="divide-y divide-ink-100">{(data as any[]).map(n => <li key={n.id}><button onClick={() => go(`/news?id=${n.id}`)} className={cx('w-full px-4 py-3 text-left hover:bg-ink-50', query.id === n.id && 'bg-brand-50')}>
            <div className={cx('text-sm', readSet.has(n.id) ? 'text-ink-700' : 'font-semibold')}>{n.pinned && '📌 '}{n.title}</div>
            <div className="text-xs text-ink-400">{CATS.find(c => c[0] === n.category)?.[1]} · {a.personName(n.created_by)} · {fmtDateTime(n.publish_at)}</div></button></li>)}</ul>}
        </Card>
        {sel ? <Card title={sel.title} actions={(sel.created_by === a.me.id || a.isAdmin) && <Button size="sm" variant="danger" onClick={() => run(async () => { await db.from('announcements').delete().eq('id', sel.id); go('/news'); reload(); }, 'Đã xóa')}>Xóa</Button>}>
          <div className="mb-3 flex flex-wrap gap-2 text-xs text-ink-500"><Badge>{CATS.find(c => c[0] === sel.category)?.[1]}</Badge>{a.personName(sel.created_by)} · {fmtDateTime(sel.publish_at)}
            {sel.audience !== 'all' && <Badge color="purple">{sel.audience === 'team' ? 'Nhóm của người đăng' : 'Theo phòng'}</Badge>}</div>
          <div className="whitespace-pre-wrap text-sm leading-relaxed">{sel.body}</div></Card> : <Card><Empty>Chọn thông báo để đọc</Empty></Card>}
      </div>
      <NewPost open={open} onClose={() => setOpen(false)} onDone={() => { setOpen(false); reload(); }} />
    </Layout>
  );
}

function NewPost({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const full = a.isAdmin || a.has('hcns');
  const [f, setF] = useState({ title: '', body: '', category: 'chung', audience: full ? 'all' : 'team', unit_ids: [] as string[], pinned: false, expires_at: '' });
  const { busy, run } = useAction();
  return (
    <Modal open={open} onClose={onClose} title="Đăng thông báo" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      if (!f.title.trim() || !f.body.trim()) throw new Error('Nhập tiêu đề và nội dung');
      await db.from('announcements').insert({ ...f, created_by: a.me.id, expires_at: f.expires_at ? new Date(f.expires_at + 'T23:59:59+07:00').toISOString() : null });
      onDone();
    }, 'Đã đăng và gửi thông báo')}>Đăng</Button>}>
      <div className="space-y-3">
        <Field label="Tiêu đề" required><Input value={f.title} onChange={e => setF({ ...f, title: e.target.value })} /></Field>
        <Field label="Nội dung" required><Textarea rows={8} value={f.body} onChange={e => setF({ ...f, body: e.target.value })} /></Field>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="Phân loại"><Select options={CATS} value={f.category} onChange={v => setF({ ...f, category: v })} /></Field>
          <Field label="Gửi tới"><Select disabled={!full} options={[['all', 'Toàn công ty'], ['units', 'Theo phòng ban'], ['team', 'Nhóm của tôi']]} value={f.audience} onChange={v => setF({ ...f, audience: v })} /></Field>
          <Field label="Hết hạn hiển thị"><Input type="date" value={f.expires_at} onChange={e => setF({ ...f, expires_at: e.target.value })} /></Field>
        </div>
        {f.audience === 'units' && <Field label="Phòng ban"><Chips options={a.units.filter(u => u.kind !== 'cong_ty').map(u => [u.id, u.name])} value={f.unit_ids} onChange={v => setF({ ...f, unit_ids: v })} /></Field>}
        {full && <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.pinned} onChange={e => setF({ ...f, pinned: e.target.checked })} /> Ghim lên đầu</label>}
        <p className="text-xs text-ink-500">Thông báo toàn công ty cũng được gửi lên nhóm Telegram BGĐ (nếu đã bật).</p>
      </div>
    </Modal>
  );
}
