import React, { useEffect, useMemo, useState } from 'react';
import { Button, cx, Input, Loading, Modal, Select, toast } from './ui';
import { db } from '../lib/sb';
import { useApp } from '../state';
import { copyText, noAccent } from '../lib/format';

export const fillReply = (t: string, v: { danh_xung: string; ten_sale: string; ten_khach?: string }) => {
  const cap = (x: string) => x.charAt(0).toUpperCase() + x.slice(1);
  return t.replace(/\{Danh_xung\}/g, cap(v.danh_xung)).replace(/\{danh_xung\}/g, v.danh_xung).replace(/\{ten_sale\}/g, v.ten_sale).replace(/\{ten_khach\}/g, v.ten_khach || v.danh_xung);
};
export function useReplies() {
  const [list, setList] = useState<any[] | null>(null);
  const load = () => db.from('reply_templates').select('*').eq('active', true).order('category').order('sort').order('title').then(setList, () => setList([]));
  return { list, load };
}
const norm = (s: string) => noAccent(s).toLowerCase();

/** Chọn câu mẫu → sao chép 1 chạm để dán vào Zalo */
export function ReplyPicker({ open, onClose, customerName }: { open: boolean; onClose: () => void; customerName?: string }) {
  const a = useApp(); const { list, load } = useReplies();
  const [q, setQ] = useState(''); const [cat, setCat] = useState('');
  const [dx, setDx] = useState(() => { try { return localStorage.getItem('nt_danh_xung') || 'anh/chị'; } catch { return 'anh/chị'; } });
  useEffect(() => { if (open && !list) load(); }, [open]);
  useEffect(() => { try { localStorage.setItem('nt_danh_xung', dx); } catch { /* */ } }, [dx]);
  const cats = a.opts('reply_cat');
  const rows = useMemo(() => (list || []).filter(r => (!cat || r.category === cat) && (!q.trim() || norm(r.title + ' ' + r.content).includes(norm(q.trim())))), [list, q, cat]);
  const vars = { danh_xung: dx, ten_sale: a.me.full_name, ten_khach: customerName };
  const copy = async (r: any) => { await copyText(fillReply(r.content, vars)); db.rpc('reply_template_used', { p_id: r.id }).catch(() => {}); toast.ok('Đã sao chép — dán vào Zalo'); };
  return (
    <Modal open={open} onClose={onClose} title="💬 Câu trả lời mẫu" size="lg" footer={<a className="mr-auto text-xs font-semibold text-brand-700" href="#/crm/replies" onClick={onClose}>Quản lý câu mẫu →</a>}>
      <div className="mb-3 grid gap-2 sm:grid-cols-[1fr_170px]">
        <Input autoFocus placeholder="🔎 Tìm câu mẫu (không cần dấu)…" value={q} onChange={e => setQ(e.target.value)} />
        <Select options={[['anh/chị', 'Gọi khách: anh/chị'], ['anh', 'anh'], ['chị', 'chị'], ['em', 'em'], ['quý khách', 'quý khách']]} value={dx} onChange={setDx} />
      </div>
      <div className="-mx-1 mb-3 flex gap-1.5 overflow-x-auto px-1 pb-1 [scrollbar-width:none]">
        {[['', 'Tất cả'], ...cats].map(([k, l]) => <button key={k} onClick={() => setCat(k)} className={cx('shrink-0 rounded-full border px-3 py-1 text-xs font-semibold', cat === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white')}>{l}</button>)}
      </div>
      {!list ? <Loading /> : !rows.length ? <p className="py-6 text-center text-sm text-ink-400">Không có câu mẫu phù hợp</p> :
        <ul className="max-h-[55vh] space-y-2 overflow-y-auto pr-1">{rows.map(r => (
          <li key={r.id} className="group rounded-xl border border-ink-200 p-3 hover:border-brand-300 hover:bg-brand-50/40">
            <div className="flex items-start justify-between gap-2"><b className="text-sm">{r.title}</b>
              <Button size="sm" variant="primary" onClick={() => copy(r)}>📋 Sao chép</Button></div>
            <p className="mt-1 line-clamp-4 whitespace-pre-wrap text-[13px] text-ink-600 group-hover:line-clamp-none">{fillReply(r.content, vars)}</p>
            <div className="mt-1 text-[11px] text-ink-400">{a.label('reply_cat', r.category)}{r.use_count > 0 && ` · đã dùng ${r.use_count} lần`}</div>
          </li>))}</ul>}
    </Modal>
  );
}
