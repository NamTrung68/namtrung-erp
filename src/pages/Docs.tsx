import React, { useState } from 'react';
import { Layout } from '../components/Layout';
import { Button, Card, Empty, Field, Input, Loading, Modal, Select, Table, Td, Textarea, useAction, useLoad, toast } from '../components/ui';
import { db, storage } from '../lib/sb';
import { useApp } from '../state';
import { fmtDate } from '../lib/format';

export default function Docs() {
  const a = useApp();
  const [cat, setCat] = useState(''); const [q, setQ] = useState(''); const [open, setOpen] = useState(false);
  const { data: cats } = useLoad(() => db.from('doc_categories').select('*').order('sort'), []);
  const { data, loading, reload } = useLoad(async () => {
    let qq = db.from('documents').select('*').is('deleted_at', null).order('created_at', { asc: false }).limit(300);
    if (cat) qq = qq.eq('category_id', cat);
    if (q.trim()) qq = qq.or(`title.ilike.*${q.trim()}*,ext_order_code.ilike.*${q.trim()}*,note.ilike.*${q.trim()}*`);
    return qq;
  }, [cat, q]);
  const { run } = useAction();
  const openDoc = (d: any) => run(async () => {
    const r = await db.rpc('doc_open', { p_id: d.id });
    const url = r.kind === 'link' ? r.url : await storage.signedUrl('docs', r.storage_path, 300);
    window.open(url, '_blank', 'noopener');
  });
  const del = (d: any) => run(async () => { await db.from('documents').update({ deleted_at: new Date().toISOString() }).eq('id', d.id); reload(); }, 'Đã xóa');
  const catOpts = ((cats as any[]) || []).map(c => [c.id, c.name] as [string, string]);
  if (!a.canDocs) return <Layout title="Chứng từ"><Card>Module chứng từ dành cho cấp Chuyên viên trở lên và Kế toán.</Card></Layout>;
  return (
    <Layout title="Tài liệu chứng từ" actions={<Button variant="dark" onClick={() => setOpen(true)}>Thêm tài liệu</Button>}>
      <div className="mb-3 grid grid-cols-2 gap-2 md:grid-cols-4">
        <Input placeholder="Tìm tên, mã đơn, ghi chú…" value={q} onChange={e => setQ(e.target.value)} />
        <Select options={catOpts} value={cat} onChange={setCat} placeholder="Mọi loại tài liệu" />
      </div>
      <Card bodyClass="p-0">
        {loading ? <Loading /> : !(data as any[])?.length ? <Empty>Chưa có tài liệu</Empty> :
          <Table head={['Tài liệu', 'Loại', 'Mã đơn', 'Người phụ trách', 'Ngày', '']}>{(data as any[]).map(d => (
            <tr key={d.id}><Td><button className="text-left font-medium text-brand-700 hover:underline" onClick={() => openDoc(d)}>{d.kind === 'file' ? '📎 ' : '🔗 '}{d.title}</button>{d.note && <div className="text-xs text-ink-400">{d.note}</div>}</Td>
              <Td>{catOpts.find(c => c[0] === d.category_id)?.[1]}</Td><Td>{d.ext_order_code}</Td><Td>{a.personName(d.owner_id)}</Td><Td>{fmtDate(d.created_at)}</Td>
              <Td>{(d.owner_id === a.me.id || a.isAdmin) && <Button size="sm" variant="ghost" onClick={() => del(d)}>Xóa</Button>}</Td></tr>))}</Table>}
      </Card>
      <p className="mt-2 text-xs text-ink-500">Mỗi lần mở tài liệu được ghi nhật ký truy cập. File lưu riêng tư, chỉ mở qua link ký tạm 5 phút.</p>
      <NewDoc open={open} cats={catOpts} onClose={() => setOpen(false)} onDone={() => { setOpen(false); reload(); }} />
    </Layout>
  );
}

function NewDoc({ open, cats, onClose, onDone }: { open: boolean; cats: [string, string][]; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [f, setF] = useState({ category_id: '', title: '', kind: 'link', url: '', ext_order_code: '', note: '' }); const [file, setFile] = useState<File | null>(null);
  const { busy, run } = useAction();
  const save = () => run(async () => {
    if (!f.category_id || !f.title.trim()) throw new Error('Chọn loại và nhập tên tài liệu');
    const row: any = { category_id: f.category_id, title: f.title.trim(), kind: f.kind, ext_order_code: f.ext_order_code || null, note: f.note || null, owner_id: a.me.id };
    if (f.kind === 'link') { if (!/^https?:\/\//i.test(f.url)) throw new Error('Link phải bắt đầu bằng http(s)://'); row.url = f.url; }
    else {
      if (!file) throw new Error('Chọn file'); if (file.size > 20 * 1024 * 1024) throw new Error('File tối đa 20 MB');
      const path = `${f.category_id}/${Date.now()}-${file.name.replace(/[^\w.\-]/g, '_')}`;
      await storage.upload('docs', path, file); row.storage_path = path; row.file_name = file.name; row.file_size = file.size;
    }
    await db.from('documents').insert(row); toast.ok('Đã lưu tài liệu'); onDone();
  });
  return (
    <Modal open={open} onClose={onClose} title="Thêm tài liệu" size="sm" footer={<Button variant="primary" loading={busy} onClick={save}>Lưu</Button>}>
      <div className="space-y-3">
        <Field label="Loại tài liệu" required><Select options={cats} value={f.category_id} onChange={v => setF({ ...f, category_id: v })} placeholder="— Chọn —" /></Field>
        <Field label="Tên tài liệu" required><Input value={f.title} onChange={e => setF({ ...f, title: e.target.value })} /></Field>
        <Field label="Hình thức"><Select options={[['link', 'Link chia sẻ ngoài (Drive…)'], ['file', 'Tải file lên']]} value={f.kind} onChange={v => setF({ ...f, kind: v })} /></Field>
        {f.kind === 'link' ? <Field label="Đường dẫn"><Input value={f.url} onChange={e => setF({ ...f, url: e.target.value })} placeholder="https://" /></Field>
          : <Field label="File (≤ 20 MB)"><input type="file" onChange={e => setFile(e.target.files?.[0] || null)} className="text-sm" /></Field>}
        <Field label="Mã đơn liên quan"><Input value={f.ext_order_code} onChange={e => setF({ ...f, ext_order_code: e.target.value })} /></Field>
        <Field label="Ghi chú"><Textarea value={f.note} onChange={e => setF({ ...f, note: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}
