import React, { useEffect, useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Button, cx, Empty, Field, Input, Loading, Modal, NumInput, Select, Textarea, toast, useAction, ask } from '../../components/ui';
import { Pager, usePager } from '../../components/Pager';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { copyText, fmtDate, noAccent } from '../../lib/format';
import { fillReply, useReplies } from '../../components/Replies';

export default function Replies() {
  const a = useApp(); const { list, load } = useReplies(); const [q, setQ] = useState(''); const [cat, setCat] = useState(''); const [edit, setEdit] = useState<any>(null);
  const canEdit = a.isAdmin || a.has('bgd', 'tp_kd', 'tn_kd', 'hcns');
  useEffect(() => { load(); }, []);
  const cats = a.opts('reply_cat');
  const rows = useMemo(() => (list || []).filter(r => (!cat || r.category === cat) && (!q.trim() || noAccent(r.title + ' ' + r.content).toLowerCase().includes(noAccent(q.trim()).toLowerCase()))), [list, q, cat]);
  const pg = usePager('replies', [q, cat]);
  const vars = { danh_xung: 'anh/chị', ten_sale: a.me.full_name };
  return (
    <Layout title="Câu trả lời mẫu" actions={canEdit && <Button variant="dark" onClick={() => setEdit({ category: cat || 'chung', title: '', content: '', sort: 0 })}>+ Thêm câu mẫu</Button>}>
      <p className="mb-3 text-sm text-ink-500">Bấm <b>📋 Sao chép</b> rồi dán vào Zalo. Ở mọi trang, Sale mở nhanh bằng nút <b>💬 Câu mẫu</b> trên thanh trên cùng. Dùng <code className="rounded bg-ink-100 px-1">{'{danh_xung}'}</code>, <code className="rounded bg-ink-100 px-1">{'{Danh_xung}'}</code> (viết hoa đầu câu), <code className="rounded bg-ink-100 px-1">{'{ten_sale}'}</code> để tự điền.</p>
      <div className="mb-3 flex flex-wrap items-center gap-2"><Input className="max-w-sm" placeholder="🔎 Tìm câu mẫu…" value={q} onChange={e => setQ(e.target.value)} />
        <div className="flex gap-1.5 overflow-x-auto [scrollbar-width:none]">{[['', 'Tất cả'], ...cats].map(([k, l]) => <button key={k} onClick={() => setCat(k)} className={cx('shrink-0 rounded-full border px-3 py-1 text-xs font-semibold', cat === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white')}>{l} <span className="opacity-60">{(list || []).filter(r => !k || r.category === k).length}</span></button>)}</div></div>
      <div className="rounded-2xl border border-ink-200 bg-white shadow-soft">
        {!list ? <Loading /> : !rows.length ? <Empty>Chưa có câu mẫu</Empty> :
          <ul className="divide-y divide-ink-100">{pg.slice(rows).map(r => <li key={r.id} className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-start">
            <div className="min-w-0 flex-1"><div className="flex flex-wrap items-center gap-2"><b>{r.title}</b><span className="rounded-full bg-brand-50 px-2 py-0.5 text-[11px] font-semibold text-brand-700">{a.label('reply_cat', r.category)}</span>
              {r.use_count > 0 && <span className="text-[11px] text-ink-400">dùng {r.use_count} lần</span>}</div>
              <p className="mt-1 whitespace-pre-wrap text-sm text-ink-700">{fillReply(r.content, vars)}</p>
              <div className="mt-1 text-[11px] text-ink-400">Cập nhật {fmtDate(r.updated_at)}{r.updated_by && ` · ${a.personName(r.updated_by)}`}</div></div>
            <div className="flex shrink-0 gap-1.5"><Button size="sm" variant="primary" onClick={async () => { await copyText(fillReply(r.content, vars)); db.rpc('reply_template_used', { p_id: r.id }).catch(() => {}); toast.ok('Đã sao chép'); }}>📋 Sao chép</Button>
              {canEdit && <Button size="sm" onClick={() => setEdit(r)}>Sửa</Button>}</div>
          </li>)}</ul>}
        <Pager p={pg} total={rows.length} />
      </div>
      {edit && <EditReply r={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); load(); }} />}
    </Layout>
  );
}

function EditReply({ r, onClose, onSaved }: { r: any; onClose: () => void; onSaved: () => void }) {
  const a = useApp(); const [f, setF] = useState<any>({ ...r }); const { busy, run } = useAction();
  const s = (k: string) => (v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const save = () => run(async () => {
    if (!f.title.trim() || !f.content.trim()) throw new Error('Nhập tiêu đề và nội dung');
    const body = { category: f.category, title: f.title.trim(), content: f.content.trim(), sort: f.sort || 0, active: f.active !== false };
    if (f.id) await db.from('reply_templates').update(body).eq('id', f.id); else await db.from('reply_templates').insert(body);
    onSaved();
  }, 'Đã lưu câu mẫu');
  const del = async () => { if (await ask({ title: 'Xóa câu mẫu này?', danger: true, ok: 'Xóa' })) run(async () => { await db.from('reply_templates').delete().eq('id', f.id); onSaved(); }, 'Đã xóa'); };
  return <Modal open onClose={onClose} title={f.id ? 'Sửa câu mẫu' : 'Thêm câu mẫu'} footer={<>{f.id && <Button variant="danger" className="mr-auto" onClick={del}>Xóa</Button>}<Button variant="primary" loading={busy} onClick={save}>Lưu</Button></>}>
    <div className="grid gap-3 sm:grid-cols-[1fr_120px]">
      <Field label="Nhóm"><Select options={a.opts('reply_cat')} value={f.category} onChange={s('category')} /></Field>
      <Field label="Thứ tự"><NumInput value={f.sort} onChange={s('sort')} /></Field>
      <Field label="Tiêu đề (để tìm nhanh)" className="sm:col-span-2"><Input value={f.title} onChange={e => s('title')(e.target.value)} placeholder="VD: Nhắc kiểm hàng trong 48h" /></Field>
      <Field label="Nội dung" className="sm:col-span-2" hint="{danh_xung} = anh/chị · {Danh_xung} = Anh/Chị đầu câu · {ten_sale} = tên người gửi"><Textarea rows={7} value={f.content} onChange={e => s('content')(e.target.value)} /></Field>
    </div>
    {f.content && <div className="mt-3 rounded-xl bg-ink-50 p-3 text-sm"><div className="mb-1 text-xs font-semibold text-ink-500">Xem trước</div><p className="whitespace-pre-wrap">{fillReply(f.content, { danh_xung: 'anh', ten_sale: a.me.full_name })}</p></div>}
  </Modal>;
}
