import React, { useEffect, useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Chips, cx, Empty, Field, Input, Loading, Modal, Select, Tabs, Textarea, toast, useAction, useLoad, Table, Td, ask } from '../../components/ui';
import { db } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { addDays, daysBetween, fmtDate, fmtDateTime, money, today } from '../../lib/format';
import { CareModal, DuplicateCheck, dupText, DirectiveModal } from '../../components/CrmModals';

const EMPTY = {
  contact_name: '', position: '', company_name: '', phone: '', zalo: '', tax_code: '', email: '', facebook: '', province: '', address: '',
  customer_type: '', source: '', industry: '', goods: '', current_provider: '', import_method: '', legal_entity: '', invoice_need: '',
  frequency: '', monthly_value: '', stage: 'moi', temperature: 'lanh', services: [] as string[], goods_traits: [] as string[],
  next_care_date: today(), birthday: '', note: '', group_root_id: null as string | null,
};

export function careBadge(d: string | null, t = today()) {
  if (!d) return null;
  const n = daysBetween(d, t);
  if (n > 0) return <Badge color="solidred">Quá {n} ngày</Badge>;
  if (n === 0) return <Badge color="solidamber">Hôm nay</Badge>;
  return <span className="text-xs text-ink-500">{fmtDate(d).slice(0, 5)}</span>;
}

export default function Customers() {
  const a = useApp(); const { query } = useRoute();
  const [q, setQ] = useState(''); const [stage, setStage] = useState(''); const [temp, setTemp] = useState(''); const [type, setType] = useState('');
  const [owner, setOwner] = useState(query.scope === 'team' ? '' : ''); const [due, setDue] = useState(query.due === '1');
  const [sel, setSel] = useState<string | null>(query.id || null);
  const [creating, setCreating] = useState(false);
  const [checkOpen, setCheckOpen] = useState(query.check === '1');
  useEffect(() => { setSel(query.id || null); if (query.check === '1') setCheckOpen(true); if (query.new === '1') setCreating(true); }, [query.id, query.check, query.new]);
  const { data, loading, reload } = useLoad(async () => {
    let qq = db.from('customers').select('id,code,contact_name,company_name,phone,zalo,tax_code,customer_type,industry,import_method,stage,temperature,next_care_date,owner_id,ownership,last_contact_at,last_result,care_count,quote_count,order_count')
      .is('deleted_at', null).order('next_care_date', { nulls: 'last' }).order('created_at', { asc: false }).limit(300);
    if (q.trim()) { const s = q.trim().replace(/[(),]/g, ' '); qq = qq.or(`contact_name.ilike.*${s}*,company_name.ilike.*${s}*,phone_norm.ilike.*${s.replace(/\D/g, '') || s}*,code.ilike.*${s}*,tax_code.ilike.*${s}*`); }
    if (stage) qq = qq.eq('stage', stage); if (temp) qq = qq.eq('temperature', temp); if (type) qq = qq.eq('customer_type', type);
    if (owner) qq = qq.eq('owner_id', owner); else if (!a.isLead) qq = qq.eq('owner_id', a.me.id);
    if (due) qq = qq.lte('next_care_date', today()).neq('stage', 'khong_tiem_nang');
    return qq;
  }, [q, stage, temp, type, owner, due]);
  const salesOpts = a.people.filter(p => p.status === 'active').map(p => [p.id, p.full_name] as [string, string]);
  const { data: counts, reload: reloadCounts } = useLoad(() => db.rpc<any[]>('customer_stage_counts', { p_owner: owner || null }), [owner]);
  const cmap = new Map(((counts as any[]) || []).map(r => [r.stage, Number(r.n)]));
  const total = Array.from(cmap.values()).reduce((x, y) => x + y, 0);
  const open = (id: string) => go(`/crm/customer?id=${id}`);
  const close = () => { setCreating(false); go('/crm/customers'); };
  const rows = (data as any[]) || [];
  const [careFor, setCareFor] = useState<any>(null);
  const tempDot = (t: string) => <span className={cx('whitespace-nowrap text-sm', t === 'nong' ? 'text-red-600' : t === 'am' ? 'text-amber-600' : 'text-sky-600')}>● {a.label('temperature', t)}</span>;
  const quickCare = async (e: React.MouseEvent, id: string) => { e.stopPropagation(); setCareFor(await db.from('customers').select('*').eq('id', id).maybeSingle()); };
  return (
    <Layout title="Khách hàng" actions={<>
      <Button variant="dark" onClick={() => { setCreating(true); setSel(null); }}>Thêm khách hàng</Button>
      <Button onClick={() => { reload(); reloadCounts(); }}>Tải lại</Button></>}>
      <div className={cx((sel || creating) && 'hidden xl:block')}>
        <div className="mb-3 flex gap-1.5 overflow-x-auto pb-1 [scrollbar-width:none]">
          <button onClick={() => setStage('')} className={cx('shrink-0 rounded-full border px-3 py-1.5 text-sm font-semibold', !stage ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white')}>Tất cả <span className="opacity-60">{total}</span></button>
          {a.opts('stage').map(([k, l]) => <button key={k} onClick={() => setStage(stage === k ? '' : k)}
            className={cx('shrink-0 rounded-full border px-3 py-1.5 text-sm font-semibold', stage === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white', !cmap.get(k) && stage !== k && 'opacity-50')}>{l} <span className="opacity-60">{cmap.get(k) || 0}</span></button>)}
        </div>
        <div className="mb-3 grid grid-cols-2 gap-2 md:grid-cols-4 xl:grid-cols-6">
          <Input className="col-span-2" placeholder="Tìm tên, SĐT, MST, mã KH…" value={q} onChange={e => setQ(e.target.value)} />
          <Select options={a.opts('temperature')} value={temp} onChange={setTemp} placeholder="Mọi mức độ" />
          <Select options={a.opts('customer_type')} value={type} onChange={setType} placeholder="Mọi loại khách" />
          {a.isLead ? <Select options={salesOpts} value={owner} onChange={setOwner} placeholder="Mọi nhân viên" /> : <span className="hidden md:block" />}
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={due} onChange={e => setDue(e.target.checked)} /> Chỉ khách đến hạn</label>
        </div>
      </div>
      <div className="flex gap-4">
        <div className={cx('min-w-0 flex-1 rounded-2xl border border-ink-200 bg-white shadow-soft', (sel || creating) && 'hidden xl:block')}>
          {loading ? <Loading /> : rows.length === 0 ? <Empty>Không có khách phù hợp</Empty> : <>
            <ul className="divide-y divide-ink-100 md:hidden">{rows.map(c => (
              <li key={c.id} onClick={() => open(c.id)} className="flex gap-3 px-3 py-3 active:bg-ink-50">
                <div className="min-w-0 flex-1">
                  <div className="flex items-start justify-between gap-2"><b className="leading-snug">{c.company_name || c.contact_name}</b>{careBadge(c.next_care_date)}</div>
                  <div className="text-xs text-ink-500">{c.code} · {c.phone || c.zalo} · {a.personName(c.owner_id)}</div>
                  <div className="mt-1 flex flex-wrap items-center gap-1.5"><Badge color="green">{a.label('stage', c.stage)}</Badge>{tempDot(c.temperature)}
                    <span className="text-xs text-ink-400">{c.care_count}/{c.quote_count}/{c.order_count}</span></div>
                </div>
                <Button size="sm" onClick={e => quickCare(e, c.id)}>Ghi</Button>
              </li>))}</ul>
            <Table className="hidden md:block" head={['Hẹn chăm', 'Khách hàng', 'Liên hệ', 'Loại / Ngành', 'Hình thức NK', 'Giai đoạn', 'Mức độ', 'Kết quả gần nhất', 'Chăm / BG / Đơn', 'Sale', '']}>
              {rows.map(c => (
                <tr key={c.id} onClick={() => open(c.id)} className={cx('cursor-pointer hover:bg-ink-50', sel === c.id && 'bg-brand-50')}>
                  <Td className="w-24">{careBadge(c.next_care_date)}{c.next_care_date && c.next_care_date <= today() && <div className="text-[11px] text-ink-400">{fmtDate(c.next_care_date).slice(0, 5)}</div>}</Td>
                  <Td className="min-w-[180px]"><div className="font-semibold">{c.company_name || c.contact_name}</div><div className="text-xs text-ink-400">{c.code}{c.company_name ? ` – ${c.contact_name}` : ''}{c.ownership === 'owned' && ' · 👑'}</div></Td>
                  <Td><div className="whitespace-nowrap">{c.phone || c.zalo}</div><div className="text-xs text-ink-400">{c.last_contact_at ? 'LH ' + fmtDate(c.last_contact_at).slice(0, 5) : 'Chưa liên hệ'}</div></Td>
                  <Td><div>{a.label('customer_type', c.customer_type)}</div><div className="text-xs text-ink-400">{a.label('industry', c.industry)}</div></Td>
                  <Td className="max-w-[200px] text-xs">{a.label('import_method', c.import_method)}</Td>
                  <Td><Badge color={['don_dau', 'hoat_dong', 'vip'].includes(c.stage) ? 'green' : c.stage === 'moi' ? 'gray' : ['kho_ngu', 'mat_khach'].includes(c.stage) ? 'red' : 'purple'}>{a.label('stage', c.stage)}</Badge></Td>
                  <Td>{tempDot(c.temperature)}</Td>
                  <Td className="max-w-[160px] text-xs">{a.label('care_result', c.last_result)}</Td>
                  <Td className="whitespace-nowrap text-center tabular-nums">{c.care_count} / {c.quote_count} / <b>{c.order_count}</b></Td>
                  <Td className="whitespace-nowrap text-xs">{a.personName(c.owner_id)}</Td>
                  <Td className="whitespace-nowrap" onClick={e => e.stopPropagation()}><div className="flex gap-1"><Button size="sm" onClick={e => quickCare(e, c.id)}>Ghi chăm sóc</Button><Button size="sm" onClick={() => go(`/crm/quote?customer=${c.id}`)}>Báo giá</Button></div></Td>
                </tr>))}
            </Table></>}
          {rows.length >= 300 && <div className="p-3 text-center text-xs text-ink-400">Hiển thị 300 khách đầu — dùng bộ lọc để thu hẹp</div>}
        </div>
        {(sel || creating) && <div className="fixed inset-0 z-30 overflow-y-auto bg-ink-50 p-2 xl:static xl:z-auto xl:w-[52%] xl:max-w-[920px] xl:overflow-visible xl:bg-transparent xl:p-0">
          <CustomerPanel key={sel || 'new'} id={creating ? null : sel} onClose={close} onSaved={(id) => { reload(); reloadCounts(); setCreating(false); open(id); }} />
        </div>}
      </div>
      {careFor && <CareModal open customer={careFor} onClose={() => setCareFor(null)} onSaved={() => { setCareFor(null); reload(); }} />}
      <DuplicateCheck open={checkOpen} onClose={() => { setCheckOpen(false); if (query.check) go('/crm/customers'); }} />
    </Layout>
  );
}

function CustomerPanel({ id, onClose, onSaved }: { id: string | null; onClose: () => void; onSaved: (id: string) => void }) {
  const a = useApp();
  const [tab, setTab] = useState('info');
  const [f, setF] = useState<any>({ ...EMPTY });
  const [dup, setDup] = useState<any>(null);
  const [careOpen, setCareOpen] = useState(false); const [transferOpen, setTransferOpen] = useState(false); const [directive, setDirective] = useState<string | null>(null);
  const { busy, run } = useAction();
  const { data: c, loading, reload } = useLoad(() => (id ? db.from('customers').select('*').eq('id', id).maybeSingle() : Promise.resolve(null)), [id]);
  useEffect(() => { if (c) setF({ ...EMPTY, ...Object.fromEntries(Object.entries(c).map(([k, v]) => [k, v ?? (Array.isArray((EMPTY as any)[k]) ? [] : '')])) }); }, [c]);
  const set = (k: string) => (v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const ev = (k: string) => (e: any) => set(k)(e.target.value);
  const check = async () => {
    if (!f.phone && !f.tax_code && !f.zalo) return;
    try { const r = await db.rpc('check_duplicate', { p_phone: f.phone || f.zalo || null, p_tax: f.tax_code || null, p_exclude: id }); setDup(r.status === 'none' ? null : r); } catch { /* */ }
  };
  const save = () => run(async () => {
    const payload: any = { ...f };
    ['id', 'code', 'phone_norm', 'zalo_norm', 'owner_id', 'ownership', 'owned_at', 'care_count', 'quote_count', 'order_count', 'first_order_code', 'first_order_at', 'last_order_at',
      'last_contact_at', 'last_result', 'created_by', 'created_at', 'updated_at', 'deleted_at'].forEach(k => delete payload[k]);
    for (const k of Object.keys(payload)) if (payload[k] === '') payload[k] = null;
    if (!payload.contact_name || !payload.customer_type || !payload.source) throw new Error('Nhập đủ: Người liên hệ, Loại khách, Nguồn khách');
    if (!payload.phone && !payload.zalo) throw new Error('Cần ít nhất SĐT hoặc Zalo');
    if (id) { await db.from('customers').update(payload).eq('id', id); toast.ok('Đã lưu khách hàng'); reload(); }
    else { const r: any[] = await db.from('customers').insert(payload); toast.ok(`Đã tạo ${r[0].code}`); onSaved(r[0].id); }
  });
  if (id && loading) return <div className="rounded-xl border border-ink-200 bg-white"><Loading /></div>;
  if (id && !c) return <div className="rounded-xl border border-ink-200 bg-white p-6 text-sm">Không tìm thấy khách hoặc bạn không có quyền. <Button size="sm" onClick={onClose}>Đóng</Button></div>;
  const mine = !c || c.owner_id === a.me.id || a.isLead;
  return (
    <div className="flex flex-col rounded-2xl border border-ink-200 bg-white shadow-soft xl:sticky xl:top-16 xl:max-h-[calc(100vh-5rem)]">
      <button onClick={onClose} className="flex items-center gap-1 px-4 pt-3 text-sm font-semibold text-brand-700 xl:hidden">← Quay lại danh sách</button>
      <div className="flex flex-wrap items-start justify-between gap-2 border-b border-ink-100 px-4 py-3">
        <div className="min-w-0">
          <h2 className="truncate text-lg font-semibold">{c ? (c.company_name || c.contact_name) : 'Khách hàng mới'}</h2>
          {c && <div className="flex flex-wrap items-center gap-1.5 text-xs text-ink-500">{c.code} – {c.contact_name} – {c.phone || c.zalo}
            <Badge color="green">{a.label('stage', c.stage)}</Badge>
            <span className={c.temperature === 'nong' ? 'text-red-600' : c.temperature === 'am' ? 'text-amber-600' : 'text-blue-600'}>● {a.label('temperature', c.temperature)}</span>
            {careBadge(c.next_care_date)}
            <Badge>{c.ownership === 'owned' ? 'Chủ khách' : 'Đang theo'}: {a.personName(c.owner_id)}</Badge></div>}
        </div>
        <div className="flex flex-wrap gap-1.5">
          {c && a.isLead && c.owner_id !== a.me.id && <Button size="sm" onClick={() => setDirective('chi_dao')}>🎯 Chỉ đạo sale</Button>}
          {c && <Button size="sm" onClick={() => setDirective('nho_ho_tro')}>🙋 Nhờ hỗ trợ</Button>}
          {c && <Button size="sm" variant="primary" onClick={() => setCareOpen(true)}>Ghi chăm sóc</Button>}
          {c && <Button size="sm" onClick={() => go(`/crm/quote?customer=${c.id}`)}>Tạo báo giá</Button>}
          {c && a.isLead && <Button size="sm" onClick={() => setTransferOpen(true)}>Chuyển khách</Button>}
          <Button size="sm" onClick={onClose}>Đóng</Button>
        </div>
      </div>
      {c && <div className="px-4 pt-2"><Tabs value={tab} onChange={setTab} tabs={[['info', 'Thông tin'], ['care', `Lịch sử chăm sóc (${c.care_count})`], ['quotes', `Báo giá (${c.quote_count})`], ['support', 'Hỗ trợ · Chỉ đạo'], ['transfer', 'Chuyển giao'], ['history', 'Lịch sử sửa']]} /></div>}
      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        {tab === 'info' && <div className="space-y-3">
          {dup && <div className={cx('rounded-lg border p-3 text-sm', dup.status === 'visible' ? 'border-amber-200 bg-amber-50' : 'border-red-200 bg-red-50 text-red-800')}>{dupText(dup)}</div>}
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <Field label="Người liên hệ" required><Input value={f.contact_name} onChange={ev('contact_name')} /></Field>
            <Field label="Chức vụ"><Input value={f.position} onChange={ev('position')} /></Field>
            <Field label="Tên công ty / shop"><Input value={f.company_name} onChange={ev('company_name')} /></Field>
            <Field label="Số điện thoại" required><Input value={f.phone} onChange={ev('phone')} onBlur={check} inputMode="tel" /></Field>
            <Field label="Zalo (SĐT hoặc link)"><Input value={f.zalo} onChange={ev('zalo')} onBlur={check} /></Field>
            <Field label="Mã số thuế"><Input value={f.tax_code} onChange={ev('tax_code')} onBlur={check} /></Field>
            <Field label="Email"><Input value={f.email} onChange={ev('email')} /></Field>
            <Field label="Facebook (link)"><Input value={f.facebook} onChange={ev('facebook')} /></Field>
            <Field label="Tỉnh / thành phố"><Input value={f.province} onChange={ev('province')} /></Field>
            <Field label="Địa chỉ" className="sm:col-span-2"><Input value={f.address} onChange={ev('address')} /></Field>
            <Field label="Loại khách" required><Select options={a.opts('customer_type')} value={f.customer_type} onChange={set('customer_type')} placeholder="— Chọn —" /></Field>
            <Field label="Nguồn khách" required><Select options={a.opts('source')} value={f.source} onChange={set('source')} placeholder="— Chọn —" /></Field>
            <Field label="Ngành hàng"><Select options={a.opts('industry')} value={f.industry} onChange={set('industry')} placeholder="— Chọn —" /></Field>
            <Field label="Mặt hàng cụ thể" className="sm:col-span-2"><Input value={f.goods} onChange={ev('goods')} /></Field>
            <Field label="Đang dùng đơn vị nào"><Input value={f.current_provider} onChange={ev('current_provider')} /></Field>
            <Field label="Hình thức nhập khẩu" className="sm:col-span-2"><Select options={a.opts('import_method')} value={f.import_method} onChange={set('import_method')} placeholder="— Chọn —" /></Field>
            <Field label="Pháp nhân"><Select options={a.opts('legal_entity')} value={f.legal_entity} onChange={set('legal_entity')} placeholder="— Chọn —" /></Field>
            <Field label="Nhu cầu hóa đơn"><Select options={a.opts('invoice_need')} value={f.invoice_need} onChange={set('invoice_need')} placeholder="— Chọn —" /></Field>
            <Field label="Tần suất nhập"><Select options={a.opts('frequency')} value={f.frequency} onChange={set('frequency')} placeholder="— Chọn —" /></Field>
            <Field label="Giá trị nhập / tháng"><Select options={a.opts('monthly_value')} value={f.monthly_value} onChange={set('monthly_value')} placeholder="— Chọn —" /></Field>
            <Field label="Giai đoạn"><Select options={a.opts('stage')} value={f.stage} onChange={set('stage')} /></Field>
            <Field label="Mức độ"><Select options={a.opts('temperature')} value={f.temperature} onChange={set('temperature')} /></Field>
            <Field label="Ngày hẹn chăm"><Input type="date" value={f.next_care_date || ''} onChange={ev('next_care_date')} /></Field>
            <Field label="Sinh nhật / ngày kỷ niệm"><Input type="date" value={f.birthday || ''} onChange={ev('birthday')} /></Field>
          </div>
          <Field label="Dịch vụ quan tâm"><Chips options={a.opts('service')} value={f.services} onChange={set('services')} /></Field>
          <Field label="Đặc thù hàng hóa"><Chips options={a.opts('goods_trait')} value={f.goods_traits} onChange={set('goods_traits')} /></Field>
          <Field label="Ghi chú (nhu cầu, tính cách, điều cần lưu ý)"><Textarea rows={3} value={f.note} onChange={ev('note')} /></Field>
        </div>}
        {tab === 'care' && c && <CareHistory customerId={c.id} />}
        {tab === 'quotes' && c && <CustomerQuotes customerId={c.id} />}
        {tab === 'support' && c && <CustomerSupport customerId={c.id} />}
        {tab === 'transfer' && c && <TransferHistory customerId={c.id} />}
        {tab === 'history' && c && <AuditHistory table="customers" id={c.id} />}
      </div>
      {tab === 'info' && mine && <div className="flex items-center justify-between gap-2 border-t border-ink-100 px-4 py-3">
        <span className="text-xs text-ink-400">{c ? `Tạo ${fmtDate(c.created_at)}, chăm ${c.care_count} lần, ${c.quote_count} báo giá, ${c.order_count} đơn` : 'Hệ thống kiểm tra trùng SĐT/MST khi lưu'}</span>
        <Button variant="primary" loading={busy} onClick={save}>Lưu khách hàng</Button></div>}
      {c && <CareModal open={careOpen} customer={c} onClose={() => setCareOpen(false)} onSaved={() => { setCareOpen(false); reload(); setTab('care'); }} />}
      {c && directive && <DirectiveModal kind={directive} customer={c} onClose={() => setDirective(null)} onDone={() => { setDirective(null); setTab('support'); }} />}
      {c && <TransferModal open={transferOpen} customer={c} onClose={() => setTransferOpen(false)} onDone={() => { setTransferOpen(false); reload(); }} />}
    </div>
  );
}

function TransferModal({ open, customer, onClose, onDone }: { open: boolean; customer: any; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [to, setTo] = useState(''); const [reason, setReason] = useState(''); const [note, setNote] = useState(''); const { busy, run } = useAction();
  const people = a.people.filter(p => p.status === 'active' && p.id !== customer.owner_id && (a.isAdmin || p.id !== a.me.id)).map(p => [p.id, p.full_name] as [string, string]);
  return (
    <Modal open={open} onClose={onClose} title={`Chuyển khách ${customer.code}`} size="sm"
      footer={<Button variant="primary" loading={busy} onClick={() => run(async () => { await db.rpc('transfer_customer', { p_customer: customer.id, p_to: to, p_reason: reason, p_note: note || null }); onDone(); }, 'Đã chuyển khách')}>Chuyển</Button>}>
      <div className="space-y-3 text-sm">
        <p>Hiện tại: <b>{a.personName(customer.owner_id)}</b> ({customer.ownership === 'owned' ? 'chủ khách' : 'đang theo'})</p>
        <Field label="Chuyển cho" required><Select options={people} value={to} onChange={setTo} placeholder="— Chọn nhân viên —" /></Field>
        <Field label="Lý do" required><Select options={a.opts('transfer_reason')} value={reason} onChange={setReason} placeholder="— Chọn —" /></Field>
        <Field label="Ghi chú"><Textarea value={note} onChange={e => setNote(e.target.value)} /></Field>
        <p className="text-xs text-ink-500">Quản lý không tự nhận khách về mình. Khách đang hoạt động cần chủ cũ đồng ý hoặc BGĐ quyết định.</p>
      </div>
    </Modal>
  );
}

function CareHistory({ customerId }: { customerId: string }) {
  const a = useApp();
  const { data, loading } = useLoad(() => db.from('care_logs').select('*').eq('customer_id', customerId).order('created_at', { asc: false }), [customerId]);
  if (loading) return <Loading />;
  if (!data?.length) return <Empty>Chưa có lần chăm sóc nào</Empty>;
  return <ol className="space-y-3">{(data as any[]).map(l => (
    <li key={l.id} className="rounded-lg border border-ink-100 p-3">
      <div className="flex flex-wrap items-center gap-2 text-xs text-ink-500"><b className="text-ink-800">{fmtDateTime(l.created_at)}</b>
        {a.personName(l.sale_id)} · {a.label('channel', l.channel)} · {a.label('care_purpose', l.purpose)}
        <Badge color={l.is_connected ? 'green' : 'gray'}>{a.label('care_result', l.result)}</Badge></div>
      <p className="mt-1 whitespace-pre-wrap text-sm">{l.content}</p>
      <div className="mt-1 text-xs text-ink-400">→ {a.label('stage', l.stage_after)} · {a.label('temperature', l.temperature_after)}{l.next_care_date && ` · hẹn ${fmtDate(l.next_care_date)}`}{l.quotation_code && ` · ${l.quotation_code}`}</div>
    </li>))}</ol>;
}
function CustomerQuotes({ customerId }: { customerId: string }) {
  const { data, loading } = useLoad(() => db.from('quotations').select('id,code,version,status,total_after_vat,created_at,order_code').eq('customer_id', customerId).order('created_at', { asc: false }), [customerId]);
  if (loading) return <Loading />;
  if (!data?.length) return <Empty>Chưa có báo giá</Empty>;
  return <Table head={['Mã', 'Ngày', 'Trạng thái', 'Tổng sau VAT', 'Mã đơn']}>{(data as any[]).map(q => (
    <tr key={q.id} className="cursor-pointer hover:bg-ink-50" onClick={() => go(`/crm/quote?id=${q.id}`)}>
      <Td>{q.code} v{q.version}</Td><Td>{fmtDate(q.created_at)}</Td><Td><QuoteStatus s={q.status} /></Td><Td className="text-right">{money(q.total_after_vat)}</Td><Td>{q.order_code}</Td></tr>))}</Table>;
}
const SUP_ST: Record<string, string> = { moi: 'Mới', da_nhan: 'Đã nhận', dang_xu_ly: 'Đang xử lý', xong: 'Đã xong', dong: 'Đóng' };
function CustomerSupport({ customerId }: { customerId: string }) {
  const a = useApp();
  const { data, loading } = useLoad(() => db.from('support_requests').select('id,code,title,status,created_at,kind,requester_id,assignee_id,content,response').eq('customer_id', customerId).order('created_at', { asc: false }), [customerId]);
  if (loading) return <Loading />;
  return <div className="space-y-2">{!(data as any[])?.length && <Empty>Chưa có chỉ đạo hay yêu cầu hỗ trợ</Empty>}
    {(data as any[] || []).map(s => <a key={s.id} href={`#/support?id=${s.id}`} className="block rounded-xl border border-ink-100 p-3 text-sm hover:bg-ink-50">
      <div className="flex flex-wrap items-center gap-2"><Badge color={s.kind === 'chi_dao' ? 'purple' : s.kind === 'nho_ho_tro' ? 'blue' : 'gray'}>{s.kind === 'chi_dao' ? '🎯 Chỉ đạo' : s.kind === 'nho_ho_tro' ? '🙋 Nhờ hỗ trợ' : 'Hỗ trợ'}</Badge><b>{s.title}</b><Badge>{SUP_ST[s.status] || s.status}</Badge></div>
      <div className="mt-1 text-xs text-ink-500">{a.personName(s.requester_id)} → {a.personName(s.assignee_id)} · {fmtDateTime(s.created_at)}</div>
      {s.content && <div className="mt-1 line-clamp-2">{s.content}</div>}</a>)}</div>;
}
function TransferHistory({ customerId }: { customerId: string }) {
  const a = useApp();
  const { data, loading } = useLoad(() => db.from('customer_transfers').select('*').eq('customer_id', customerId).order('created_at', { asc: false }), [customerId]);
  if (loading) return <Loading />;
  if (!data?.length) return <Empty>Chưa chuyển giao lần nào</Empty>;
  return <Table head={['Thời gian', 'Từ', 'Sang', 'Lý do', 'Người chuyển']}>{(data as any[]).map(t => (
    <tr key={t.id}><Td>{fmtDateTime(t.created_at)}</Td><Td>{a.personName(t.from_id)}</Td><Td>{a.personName(t.to_id)}</Td><Td>{a.label('transfer_reason', t.reason)}{t.note && <div className="text-xs text-ink-400">{t.note}</div>}</Td><Td>{a.personName(t.created_by)}</Td></tr>))}</Table>;
}
export function AuditHistory({ table, id }: { table: string; id: string }) {
  const a = useApp();
  const { data, loading, error } = useLoad(() => db.from('audit_logs').select('*').eq('table_name', table).eq('record_id', id).order('at', { asc: false }).limit(100), [table, id]);
  if (loading) return <Loading />;
  if (error || !data?.length) return <Empty>{error ? 'Chỉ Admin/BGĐ xem được lịch sử chỉnh sửa' : 'Chưa có lịch sử'}</Empty>;
  return <ul className="space-y-2 text-xs">{(data as any[]).map(l => <li key={l.id} className="rounded-lg border border-ink-100 p-2">
    <b>{fmtDateTime(l.at)}</b> · {a.personName(l.actor_id) || 'Hệ thống'} · {l.action}
    {l.action === 'UPDATE' && <div className="mt-1 text-ink-600">{Object.entries(l.diff || {}).map(([k, v]: any) => <div key={k}>{k}: <s className="text-ink-400">{JSON.stringify(v[0])}</s> → {JSON.stringify(v[1])}</div>)}</div>}</li>)}</ul>;
}

export const QUOTE_STATUS: Record<string, [string, string]> = {
  nhap: ['Nháp', 'gray'], cho_duyet: ['Chờ duyệt giá', 'amber'], da_gui: ['Đã gửi', 'blue'], can_nhac: ['Khách đang cân nhắc', 'purple'],
  da_chot: ['Đã chốt đơn', 'green'], tu_choi: ['Khách từ chối', 'red'], het_han: ['Hết hạn', 'gray'], da_thay_the: ['Đã thay thế', 'gray'],
};
export const QuoteStatus = ({ s }: { s: string }) => <Badge color={QUOTE_STATUS[s]?.[1]}>{QUOTE_STATUS[s]?.[0] || s}</Badge>;
