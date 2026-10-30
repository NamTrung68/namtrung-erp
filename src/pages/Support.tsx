import React, { useEffect, useState } from 'react';
import { Layout } from '../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, Select, Tabs, Textarea, useAction, useLoad } from '../components/ui';
import { Pager, usePager } from '../components/Pager';
import { db } from '../lib/sb';
import { go, useApp, useRoute } from '../state';
import { fmtDate, fmtDateTime, money } from '../lib/format';
import { STAGE_TONE, QuoteStatus } from './crm/Customers';
import { PRIORITY } from '../components/CrmModals';

const ST: Record<string, [string, string]> = { moi: ['Mới', 'red'], da_nhan: ['Đã nhận', 'amber'], dang_xu_ly: ['Đang xử lý', 'blue'], xong: ['Đã xong', 'green'], dong: ['Đóng', 'gray'] };
const KIND: Record<string, [string, string]> = { chi_dao: ['🎯 Chỉ đạo', 'purple'], nho_ho_tro: ['🙋 Nhờ hỗ trợ', 'blue'], ho_tro: ['🆘 Hỗ trợ', 'gray'] };
const OPEN = ['moi', 'da_nhan', 'dang_xu_ly'];

export default function Support() {
  const a = useApp(); const { query } = useRoute();
  const [newOpen, setNewOpen] = useState(query.new === '1');
  const [tab, setTab] = useState('todo');
  const { data, loading, reload } = useLoad(() => db.from('support_requests').select('*').order('created_at', { asc: false }).limit(300), []);
  useEffect(() => { if (query.new === '1') setNewOpen(true); }, [query.new]);
  const all = (data as any[]) || [];
  const myUnit = a.people.find(p => p.id === a.me.id)?.org_unit_id;
  const mine = (r: any) => r.assignee_id === a.me.id || (!r.assignee_id && r.org_unit_id && r.org_unit_id === myUnit);
  const lists: Record<string, any[]> = {
    todo: all.filter(r => mine(r) && OPEN.includes(r.status)),
    sent: all.filter(r => r.requester_id === a.me.id && OPEN.includes(r.status)),
    chi_dao: all.filter(r => r.kind === 'chi_dao'),
    done: all.filter(r => !OPEN.includes(r.status)),
    all,
  };
  const rows = lists[tab]; const pg = usePager('support', [tab]);
  const sel = all.find(x => x.id === query.id);
  const { data: custs } = useLoad(() => {
    const ids = Array.from(new Set(all.map(r => r.customer_id).filter(Boolean)));
    return ids.length ? db.from('customers').select('id,code,company_name,contact_name').in('id', ids) : Promise.resolve([]);
  }, [all.length]);
  const cname = (id: string) => { const c = ((custs as any[]) || []).find(x => x.id === id); return c ? `${c.code} · ${c.company_name || c.contact_name}` : ''; };
  return (
    <Layout title="Hỗ trợ khách" actions={<Button variant="dark" onClick={() => setNewOpen(true)}>🆘 Gọi hỗ trợ</Button>}>
      <div className="mb-3"><Tabs value={tab} onChange={setTab} tabs={[['todo', `Cần tôi xử lý ${lists.todo.length}`], ['sent', `Tôi đã gửi ${lists.sent.length}`], ['chi_dao', `Chỉ đạo ${lists.chi_dao.length}`], ['done', 'Đã xong'], ['all', 'Tất cả']]} /></div>
      <div className="grid gap-4 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.4fr)]">
        <Card bodyClass="p-0" className={cx(sel && 'hidden lg:block')}>
          {loading ? <Loading /> : !rows.length ? <Empty>Không có mục nào</Empty> :
            <ul className="divide-y divide-ink-100">{pg.slice(rows).map(r => <li key={r.id}>
              <button onClick={() => go(`/support?id=${r.id}`)} className={cx('w-full px-4 py-3 text-left hover:bg-ink-50', query.id === r.id && 'bg-brand-50')}>
                <div className="flex flex-wrap items-center gap-1.5"><Badge color={KIND[r.kind]?.[1]}>{KIND[r.kind]?.[0]}</Badge><b className="text-sm">{r.title}</b><Badge color={ST[r.status][1]}>{ST[r.status][0]}</Badge>
                  {['gap', 'khan'].includes(r.priority) && <Badge color="solidred">{r.priority === 'khan' ? 'Khẩn' : 'Gấp'}</Badge>}</div>
                {r.customer_id && <div className="mt-0.5 text-xs font-medium text-ink-700">{cname(r.customer_id)}</div>}
                <div className="text-xs text-ink-500">{r.code} · {a.personName(r.requester_id)} → {r.assignee_id ? a.personName(r.assignee_id) : a.units.find(u => u.id === r.org_unit_id)?.name} · {fmtDateTime(r.created_at)}{r.due_date && ` · hạn ${fmtDate(r.due_date)}`}</div>
              </button></li>)}</ul>}
          {rows.length > 0 && <Pager p={pg} total={rows.length} />}
        </Card>
        {sel ? <Thread req={sel} customer={cname(sel.customer_id)} onChanged={reload} /> : <Card className="hidden lg:block"><Empty>Chọn một mục để xem trao đổi</Empty></Card>}
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
      const r: any[] = await db.from('support_requests').insert({ kind: 'ho_tro', requester_id: a.me.id, title: f.title.trim(), content: f.content || null, priority: f.priority, customer_id: customer || null,
        assignee_id: f.to.startsWith('p:') ? f.to.slice(2) : null, org_unit_id: f.to.startsWith('u:') ? f.to.slice(2) : null });
      onDone(r[0].id);
    }, 'Đã gửi yêu cầu hỗ trợ')}>Gửi</Button>}>
      <div className="space-y-3">
        <Field label="Gửi tới" required><Select options={opts} value={f.to} onChange={v => setF({ ...f, to: v })} placeholder="— Chọn người hoặc phòng —" /></Field>
        <Field label="Cần hỗ trợ việc gì" required><Input value={f.title} onChange={e => setF({ ...f, title: e.target.value })} /></Field>
        <Field label="Chi tiết"><Textarea value={f.content} onChange={e => setF({ ...f, content: e.target.value })} /></Field>
        <Field label="Mức độ"><Select options={PRIORITY} value={f.priority} onChange={v => setF({ ...f, priority: v })} /></Field>
        <p className="text-xs text-ink-500">Chỉ đạo / nhờ hỗ trợ gắn với 1 khách: mở hồ sơ khách và bấm nút tương ứng.</p>
      </div>
    </Modal>
  );
}

function Thread({ req, customer, onChanged }: { req: any; customer: string; onChanged: () => void }) {
  const a = useApp(); const [msg, setMsg] = useState(''); const { busy, run } = useAction();
  const { data, reload } = useLoad(() => db.from('support_messages').select('*').eq('request_id', req.id).order('created_at'), [req.id]);
  const myUnit = a.people.find(p => p.id === a.me.id)?.org_unit_id;
  const handler = req.assignee_id === a.me.id || (!req.assignee_id && req.org_unit_id && req.org_unit_id === myUnit) || a.isAdmin;
  const setStatus = (s: string, extra: any = {}) => run(async () => { await db.from('support_requests').update({ status: s, resolved_at: s === 'xong' ? new Date().toISOString() : null, ...extra }).eq('id', req.id); onChanged(); }, 'Đã cập nhật');
  const send = () => msg.trim() && run(async () => { await db.from('support_messages').insert({ request_id: req.id, author_id: a.me.id, body: msg.trim() }); setMsg(''); reload(); });
  const [resp, setResp] = useState(req.response || '');
  return (
    <Card title={<span className="flex flex-wrap items-center gap-2"><button className="text-brand-700 lg:hidden" onClick={() => go('/support')}>←</button><Badge color={KIND[req.kind]?.[1]}>{KIND[req.kind]?.[0]}</Badge>{req.title}</span>} actions={<>
      {handler && req.status === 'moi' && <Button size="sm" onClick={() => setStatus('da_nhan')}>Nhận việc</Button>}
      {handler && ['moi', 'da_nhan'].includes(req.status) && <Button size="sm" onClick={() => setStatus('dang_xu_ly')}>Đang xử lý</Button>}
      {req.requester_id === a.me.id && req.status === 'xong' && <Button size="sm" onClick={() => setStatus('dong')}>Đóng</Button>}</>}>
      <div className="mb-3 text-xs text-ink-500">{req.code} · {a.personName(req.requester_id)} → {a.personName(req.assignee_id) || 'phòng ban'} · {fmtDateTime(req.created_at)}{req.due_date && ` · hạn ${fmtDate(req.due_date)}`}</div>
      {req.customer_id && <CustomerBrief reqId={req.id} />}
      {req.content && <p className="mb-3 whitespace-pre-wrap rounded-xl bg-ink-50 p-3 text-sm">{req.content}</p>}
      {(handler || req.response) && <div className="mb-3 rounded-xl border border-ink-200 p-3">
        <div className="mb-1 text-xs font-semibold text-ink-500">{req.kind === 'chi_dao' ? 'Kết quả sale báo lại' : 'Kết quả xử lý'}</div>
        {handler && req.status !== 'dong' ? <><Textarea rows={2} value={resp} onChange={e => setResp(e.target.value)} placeholder="Đã làm gì, kết quả ra sao…" />
          <Button className="mt-2" size="sm" variant="success" loading={busy} onClick={() => setStatus('xong', { response: resp || null })}>Báo đã xong</Button></> : <p className="whitespace-pre-wrap text-sm">{req.response}</p>}
      </div>}
      <div className="max-h-[45vh] space-y-2 overflow-y-auto">{(data as any[] || []).map(m => <div key={m.id} className={cx('rounded-xl p-2.5 text-sm', m.author_id === a.me.id ? 'ml-8 bg-brand-50' : 'mr-8 bg-ink-50')}>
        <div className="text-xs text-ink-500">{a.personName(m.author_id)} · {fmtDateTime(m.created_at)}</div><div className="whitespace-pre-wrap">{m.body}</div></div>)}</div>
      {req.status !== 'dong' && <div className="mt-3 flex gap-2"><Input placeholder="Nhắn trao đổi…" value={msg} onChange={e => setMsg(e.target.value)} onKeyDown={e => e.key === 'Enter' && send()} />
        <Button variant="dark" loading={busy} onClick={send}>Gửi</Button></div>}
    </Card>
  );
}

function CustomerBrief({ reqId }: { reqId: string }) {
  const a = useApp(); const [tab, setTab] = useState('care');
  const { data: c, loading } = useLoad(() => db.rpc<any>('support_customer', { p_req: reqId }), [reqId]);
  if (loading) return <Loading />;
  if (!c) return null;
  const I = ({ l, children }: { l: string; children: React.ReactNode }) => <><dt className="text-ink-400">{l}</dt><dd className="min-w-0 font-medium text-ink-800">{children || '—'}</dd></>;
  return (
    <div className="mb-3 overflow-hidden rounded-2xl border border-ink-200">
      <div className="flex flex-wrap items-center justify-between gap-2 bg-ink-50 px-3 py-2">
        <div className="min-w-0"><b className="text-brand-700">{c.company_name || c.contact_name}</b> <span className="text-xs text-ink-500">({c.code})</span></div>
        <div className="flex flex-wrap items-center gap-1.5"><Badge color={STAGE_TONE[c.stage]}>{a.label('stage', c.stage)}</Badge>
          <span className={cx('text-xs font-semibold', c.temperature === 'nong' ? 'text-red-600' : c.temperature === 'am' ? 'text-amber-600' : 'text-sky-600')}>● {a.label('temperature', c.temperature)}</span>
          {c.can_open && <a className="rounded-lg bg-white px-2 py-0.5 text-xs font-semibold text-brand-700 ring-1 ring-ink-200" href={`#/crm/customer?id=${c.id}`}>Mở hồ sơ ↗</a>}</div>
      </div>
      <dl className="grid grid-cols-[110px_1fr] gap-x-3 gap-y-1 px-3 py-2.5 text-sm sm:grid-cols-[110px_1fr_110px_1fr]">
        <I l="Sale phụ trách">{c.owner_name}</I>
        <I l="Liên hệ">{c.contact_name}{c.position && ` (${c.position})`} – <a className="text-brand-700" href={`tel:${c.phone || ''}`}>{c.phone || c.zalo}</a></I>
        <I l="Loại / ngành">{[a.label('customer_type', c.customer_type), a.label('industry', c.industry)].filter(Boolean).join(' / ')}</I>
        <I l="Mặt hàng">{c.goods}</I>
        <I l="Hình thức NK">{a.label('import_method', c.import_method)}</I>
        <I l="Giá trị / tháng">{a.label('monthly_value', c.monthly_value)}</I>
        <I l="Đang dùng">{c.current_provider}</I>
        <I l="Chăm / BG / đơn">{c.care_count} / {c.quote_count} / <b>{c.order_count}</b></I>
        <I l="Tỉnh / MST">{[c.province, c.tax_code].filter(Boolean).join(' · ')}</I>
        <I l="Hẹn chăm">{fmtDate(c.next_care_date)}</I>
        {c.note && <><dt className="text-ink-400">Ghi chú</dt><dd className="whitespace-pre-wrap sm:col-span-3">{c.note}</dd></>}
      </dl>
      <div className="border-t border-ink-100 px-3 pt-2"><Tabs value={tab} onChange={setTab} tabs={[['care', `Lịch sử trao đổi (${c.care.length})`], ['quotes', `Báo giá (${c.quotes.length})`]]} /></div>
      <div className="max-h-[300px] overflow-y-auto px-3 py-2">
        {tab === 'care' ? (!c.care.length ? <Empty>Chưa có lần chăm sóc nào</Empty> : <ol className="relative space-y-2.5 border-l-2 border-brand-100 pl-4">{c.care.map((l: any) => (
          <li key={l.id} className="relative text-sm"><span className={cx('absolute -left-[22px] top-1 h-2.5 w-2.5 rounded-full ring-2 ring-white', l.is_connected ? 'bg-emerald-500' : 'bg-ink-300')} />
            <div className="text-xs text-ink-500"><b className="text-ink-800">{fmtDateTime(l.created_at)}</b> · {a.label('channel', l.channel)} · {a.label('care_result', l.result)} · {l.sale_name}</div>
            {l.content && <div className="whitespace-pre-wrap">{l.content}</div>}
            <div className="text-[11px] text-ink-400">→ {a.label('stage', l.stage_after)}{l.next_care_date && ` · hẹn ${fmtDate(l.next_care_date)}`}{l.quotation_code && ` · ${l.quotation_code}`}</div></li>))}</ol>)
        : (!c.quotes.length ? <Empty>Chưa có báo giá</Empty> : <ul className="divide-y divide-ink-100 text-sm">{c.quotes.map((q: any) => <li key={q.id} className="flex items-center justify-between gap-2 py-1.5">
            <span><b>{q.code}</b>{q.version > 1 && ` v${q.version}`} <span className="text-xs text-ink-400">{fmtDate(q.created_at)}{q.order_code && ` · ${q.order_code}`}</span></span>
            <span className="flex items-center gap-2"><QuoteStatus s={q.status} /><b className="tabular-nums">{money(q.total_after_vat)}</b></span></li>)}</ul>)}
      </div>
    </div>
  );
}
