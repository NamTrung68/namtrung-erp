import React, { useEffect, useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Chips, cx, Empty, Field, Input, Loading, Modal, Select, Tabs, Textarea, toast, useAction, useLoad, Table, Td, ask, StatusChips } from '../../components/ui';
import { db, fetchAll } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { addDays, daysBetween, fmtDate, fmtDateTime, money, today } from '../../lib/format';
import { CareModal, DuplicateCheck, dupText, DirectiveModal } from '../../components/CrmModals';
import { ImportField, ImportWizard } from '../../components/ImportWizard';
import { writeXlsx } from '../../lib/xlsx';
import { Pager, usePager } from '../../components/Pager';

const EMPTY = {
  contact_name: '', position: '', company_name: '', phone: '', zalo: '', tax_code: '', email: '', facebook: '', province: '', address: '',
  customer_type: '', source: '', industry: '', goods: '', current_provider: '', import_method: '', legal_entity: '', invoice_need: '',
  frequency: '', monthly_value: '', stage: 'moi', temperature: 'lanh', services: [] as string[], goods_traits: [] as string[],
  next_care_date: today(), birthday: '', note: '', group_root_id: null as string | null, sys_code: '', sys_username: '', sys_warehouse: '', salutation: '', legal_rep: '', legal_address: '',
};

export const STAGE_TONE: Record<string, string> = {
  moi: 'gray', tiep_can: 'sky', khai_thac: 'indigo', da_bao_gia: 'purple', dam_phan: 'pink', don_dau: 'teal',
  hoat_dong: 'green', vip: 'amber', kho_ngu: 'slate', mat_khach: 'red', khong_tiem_nang: 'slate',
};
export const STAGE_BAR: Record<string, string> = {
  moi: 'bg-ink-400', tiep_can: 'bg-sky-500', khai_thac: 'bg-indigo-500', da_bao_gia: 'bg-brand-500', dam_phan: 'bg-pink-500', don_dau: 'bg-teal-500',
  hoat_dong: 'bg-emerald-500', vip: 'bg-amber-500', kho_ngu: 'bg-slate-400', mat_khach: 'bg-red-500', khong_tiem_nang: 'bg-slate-300',
};
export function noOrder(c: any) {
  if (!c.sys_last_order_date) return null; const n = daysBetween(c.sys_last_order_date, today());
  return <div className={cx('text-[11px] font-semibold', n > 60 ? 'text-red-600' : n > 30 ? 'text-amber-600' : 'text-emerald-600')}>Không đơn {n} ngày</div>;
}
const CUSTOMER_IMPORT: ImportField[] = [
  { key: 'sys_username', label: 'Username hệ thống', aliases: ['username', 'tên đăng nhập', 'user'] },
  { key: 'sys_code', label: 'Mã khách hàng', aliases: ['mã kh hệ thống', 'mã kh', 'customer code'] },
  { key: 'last_name', label: 'Họ' }, { key: 'first_name', label: 'Tên' },
  { key: 'phone', label: 'Điện thoại', aliases: ['số điện thoại', 'sđt', 'phone', 'mobile'] },
  { key: 'email', label: 'Email' }, { key: 'address', label: 'Địa chỉ' },
  { key: 'sys_warehouse', label: 'Kho VN', aliases: ['kho', 'kho nhận'] },
  { key: 'sale', label: 'Nhân viên Sale', aliases: ['nhân viên kinh doanh', 'nvkd', 'sale'], hint: 'tên, email hoặc mã NV' },
  { key: 'salutation', label: 'Ông/Bà', aliases: ['danh xưng'] },
  { key: 'legal_rep', label: 'Người Đại Diện', aliases: ['người đại diện pháp luật'] },
  { key: 'position', label: 'Chức danh', aliases: ['chức vụ'] },
  { key: 'tax_code', label: 'Mã Số Thuế', aliases: ['mst'] },
  { key: 'company_name', label: 'Tên Đơn Vị/Công Ty', aliases: ['tên công ty', 'công ty', 'tên đơn vị', 'công ty / shop'] },
  { key: 'legal_address', label: 'Địa Chỉ Pháp nhân', aliases: ['địa chỉ pháp lý', 'địa chỉ công ty'] },
  { key: 'sys_created_date', label: 'Ngày tạo tài khoản', type: 'date' },
  { key: 'first_order_date', label: 'Ngày cọc đơn lần đầu', type: 'date', aliases: ['ngày cọc đầu', 'đơn đầu tiên'] },
  { key: 'last_order_date', label: 'Ngày cọc đơn gần nhất', type: 'date', aliases: ['ngày đơn cuối', 'đơn gần nhất'] },
  { key: 'days_no_order', label: 'Số ngày không có đơn', type: 'number', hint: 'dùng khi không có ngày cọc gần nhất' },
  { key: 'contact_name', label: 'Người liên hệ', hint: 'khi file không tách Họ / Tên' },
  { key: 'zalo', label: 'Zalo' }, { key: 'customer_type', label: 'Loại khách' }, { key: 'source', label: 'Nguồn khách' },
  { key: 'industry', label: 'Ngành hàng' }, { key: 'goods', label: 'Mặt hàng' }, { key: 'province', label: 'Tỉnh / thành' }, { key: 'note', label: 'Ghi chú' },
];

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
  const [dq, setDq] = useState(''); useEffect(() => { const t = setTimeout(() => setDq(q), 350); return () => clearTimeout(t); }, [q]);
  const pg = usePager('customers', [dq, stage, temp, type, owner, due]);
  const build = (count: boolean) => {
    let qq = db.from('customers').select(CUSTOMER_COLS, { count })
      .is('deleted_at', null).order('next_care_date', { nulls: 'last' }).order('created_at', { asc: false });
    if (dq.trim()) { const s = dq.trim().replace(/[(),]/g, ' '); qq = qq.or(`contact_name.ilike.*${s}*,company_name.ilike.*${s}*,phone_norm.ilike.*${s.replace(/\D/g, '') || s}*,code.ilike.*${s}*,sys_code.ilike.*${s}*,sys_username.ilike.*${s}*,tax_code.ilike.*${s}*`); }
    if (stage) qq = qq.eq('stage', stage); if (temp) qq = qq.eq('temperature', temp); if (type) qq = qq.eq('customer_type', type);
    if (owner) qq = qq.eq('owner_id', owner); else if (!a.isLead) qq = qq.eq('owner_id', a.me.id);
    if (due) qq = qq.lte('next_care_date', today()).neq('stage', 'khong_tiem_nang');
    return qq;
  };
  const { data: res, loading, reload } = useLoad(() => build(true).range(pg.from, pg.to), [dq, stage, temp, type, owner, due, pg.page, pg.size]);
  const data = (res as any)?.data; const total = (res as any)?.count ?? 0;
  const salesOpts = a.people.filter(p => p.status === 'active').map(p => [p.id, p.full_name] as [string, string]);
  const { data: counts, reload: reloadCounts } = useLoad(() => db.rpc<any[]>('customer_stage_counts', { p_owner: owner || null }), [owner]);
  const cmap = new Map(((counts as any[]) || []).map(r => [r.stage, Number(r.n)]));
  const stageTotal = Array.from(cmap.values()).reduce((x, y) => x + y, 0);
  const open = (id: string) => go(`/crm/customer?id=${id}`);
  const close = () => { setCreating(false); go('/crm/customers'); };
  const rows = (data as any[]) || [];
  const [careFor, setCareFor] = useState<any>(null);
  const [impOpen, setImpOpen] = useState(false); const [createNew, setCreateNew] = useState(false);
  const canImport = a.isAdmin || a.has('bgd', 'tp_kd');
  const exportList = async () => { const all: any[] = await fetchAll(() => build(false), 50000); return writeXlsx(`khach-hang-${today()}`, [['Mã KH', 'Mã KH hệ thống', 'Người liên hệ', 'Công ty / shop', 'SĐT', 'Zalo', 'MST', 'Loại khách', 'Ngành', 'Hình thức NK', 'Giai đoạn', 'Mức độ', 'Hẹn chăm', 'Lần chăm', 'Báo giá', 'Đơn', 'Ngày đơn cuối (HT)', 'Số ngày không đơn', 'Sale'],
    ...all.map(c => [c.code, c.sys_code, c.contact_name, c.company_name, c.phone, c.zalo, c.tax_code, a.label('customer_type', c.customer_type), a.label('industry', c.industry), a.label('import_method', c.import_method),
      a.label('stage', c.stage), a.label('temperature', c.temperature), c.next_care_date, c.care_count, c.quote_count, c.order_count, c.sys_last_order_date, c.sys_last_order_date ? daysBetween(c.sys_last_order_date, today()) : '', a.personName(c.owner_id)])], 'Khách hàng'); };
  const quickCare = async (e: React.MouseEvent, id: string) => { e.stopPropagation(); setCareFor(await db.from('customers').select('*').eq('id', id).maybeSingle()); };
  return (
    <Layout title="Khách hàng" actions={<>
      <Button variant="dark" onClick={() => { setCreating(true); setSel(null); }}>Thêm khách hàng</Button>
      {canImport && <Button onClick={() => setImpOpen(true)}>⇪ Nhập / đồng bộ</Button>}
      {a.isLead && <Button onClick={exportList}>⬇ Xuất Excel</Button>}
      <Button onClick={() => { reload(); reloadCounts(); }}>Tải lại</Button></>}>
      <div className={cx((sel || creating) && 'hidden xl:block')}>
        <StatusChips value={stage} onChange={setStage} items={[['', 'Tất cả', stageTotal, 'dark'], ...a.opts('stage').map(([k, l]) => [k, l, cmap.get(k) || 0, STAGE_TONE[k] || 'gray'] as [string, string, number, string])]} />
        <div className="mb-3 grid grid-cols-2 gap-2 md:grid-cols-4 xl:grid-cols-6">
          <Input className="col-span-2" placeholder="Tìm tên, SĐT, MST, mã KH, username HT…" value={q} onChange={e => setQ(e.target.value)} />
          <Select options={a.opts('temperature')} value={temp} onChange={setTemp} placeholder="Mọi mức độ" />
          <Select options={a.opts('customer_type')} value={type} onChange={setType} placeholder="Mọi loại khách" />
          {a.isLead ? <Select options={salesOpts} value={owner} onChange={setOwner} placeholder="Mọi nhân viên" /> : <span className="hidden md:block" />}
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={due} onChange={e => setDue(e.target.checked)} /> Chỉ khách đến hạn</label>
        </div>
      </div>
      <div className="flex gap-4">
        <div className={cx('min-w-0 flex-1 rounded-2xl border border-ink-200 bg-white shadow-soft', (sel || creating) && 'hidden xl:block')}>
          {loading ? <Loading /> : rows.length === 0 ? <Empty>Không có khách phù hợp</Empty> : <>
            <CustomerTable rows={rows} sel={sel} onOpen={open} onCare={quickCare} /></>}
          <Pager p={pg} total={total} />
        </div>
        {(sel || creating) && <div className="fixed inset-0 z-30 overflow-y-auto bg-ink-50 p-2 xl:static xl:z-auto xl:w-[52%] xl:max-w-[920px] xl:overflow-visible xl:bg-transparent xl:p-0">
          <CustomerPanel key={sel || 'new'} id={creating ? null : sel} onClose={close} onSaved={(id) => { reload(); reloadCounts(); setCreating(false); open(id); }} />
        </div>}
      </div>
      {careFor && <CareModal open customer={careFor} onClose={() => setCareFor(null)} onSaved={() => { setCareFor(null); reload(); }} />}
      <ImportWizard open={impOpen} onClose={() => setImpOpen(false)} title="Nhập / đồng bộ khách hàng từ hệ thống" fields={CUSTOMER_IMPORT} sampleName="mau-nhap-khach-hang"
        options={<label className="ml-auto flex items-center gap-2 rounded-lg bg-amber-50 px-2 py-1 text-xs font-semibold text-amber-900"><input type="checkbox" checked={createNew} onChange={e => setCreateNew(e.target.checked)} /> Tạo khách mới nếu chưa có trên CRM</label>}
        note={<>Dùng thẳng file <b>Danh sách khách hàng xuất từ hệ thống</b>. Khớp khách theo <b>Mã KH → Username → SĐT → MST</b>. Khách đã có: cập nhật mã, username, kho, ngày cọc đầu / gần nhất (tự tính số ngày chưa mua mới) và điền các ô đang trống — không đổi sale đang chăm.
          Bật “Tạo khách mới” để nhập khách chưa có; khách không có SĐT / MST vẫn nhập được nếu có Mã KH hoặc Username. Khách nhập từ file không tính vào KPI “KH mới”.</>}
        onImport={async rs => { let u = 0, n = 0, k = 0; const errs: any[] = [];
          const rows2 = rs.map(r => ({ ...r, phone: /^\d{9}$/.test(String(r.phone || '').trim()) ? '0' + String(r.phone).trim() : r.phone, tax_code: /^\d{9}$|^\d{11}$/.test(String(r.tax_code || '').trim()) ? '0' + String(r.tax_code).trim() : r.tax_code }));
          for (let i = 0; i < rows2.length; i += 400) { const r: any = await db.rpc('import_customers', { p_rows: rows2.slice(i, i + 400), p_create: createNew }); u += r.updated; n += r.created; k += r.skipped; errs.push(...[...r.errors, ...(r.warnings || [])].map((e: any) => ({ ...e, row: e.row + i + 1 }))); }
          reload(); reloadCounts();
          return <div><b>Cập nhật {u} · tạo mới {n} · bỏ qua {k}</b>{errs.length > 0 && <ul className="mt-1 max-h-32 list-disc overflow-auto pl-5 text-xs text-ink-600">{errs.slice(0, 50).map((e, i) => <li key={i}>Dòng {e.row}: {e.msg}</li>)}</ul>}</div>; }} />
      <DuplicateCheck open={checkOpen} onClose={() => { setCheckOpen(false); if (query.check) go('/crm/customers'); }} />
    </Layout>
  );
}

export const CUSTOMER_COLS = 'id,code,contact_name,company_name,phone,zalo,tax_code,customer_type,industry,import_method,stage,temperature,next_care_date,owner_id,ownership,last_contact_at,last_result,care_count,quote_count,order_count,sys_code,sys_username,sys_last_order_date';
export function CustomerTable({ rows, sel, onOpen, onCare, compact }: { rows: any[]; sel?: string | null; onOpen: (id: string) => void; onCare: (e: React.MouseEvent, id: string) => void; compact?: boolean }) {
  const a = useApp();
  const tempDot = (t: string) => <span className={cx('whitespace-nowrap text-sm', t === 'nong' ? 'text-red-600' : t === 'am' ? 'text-amber-600' : 'text-sky-600')}>● {a.label('temperature', t)}</span>;
  const open = onOpen; const quickCare = onCare;
  return <>
            <ul className="divide-y divide-ink-100 md:hidden">{rows.map(c => (
              <li key={c.id} onClick={() => open(c.id)} className="flex gap-3 px-3 py-3 active:bg-ink-50">
                <div className="min-w-0 flex-1">
                  <div className="flex items-start justify-between gap-2"><b className="leading-snug">{c.company_name || c.contact_name}</b>{careBadge(c.next_care_date)}</div>
                  <div className="text-xs text-ink-500">{c.code}{c.sys_code && <b className="text-brand-700"> · {c.sys_code}</b>}{c.sys_username && ` · @${c.sys_username}`} · {c.phone || c.zalo} · {a.personName(c.owner_id)}</div>
                  <div className="mt-1 flex flex-wrap items-center gap-1.5"><Badge color={STAGE_TONE[c.stage]}>{a.label('stage', c.stage)}</Badge>{tempDot(c.temperature)}
                    <span className="text-xs text-ink-400">{c.care_count}/{c.quote_count}/{c.order_count}</span></div>
                </div>
                <Button size="sm" onClick={e => quickCare(e, c.id)}>Ghi</Button>
              </li>))}</ul>
            <Table className="hidden md:block" head={['Hẹn chăm', 'Khách hàng', 'Liên hệ', ...(compact ? [] : ['Loại / Ngành', 'Hình thức NK']), 'Giai đoạn', 'Mức độ', 'Kết quả gần nhất', 'Chăm / BG / Đơn', 'Sale', '']}>
              {rows.map(c => (
                <tr key={c.id} onClick={() => open(c.id)} className={cx('cursor-pointer hover:bg-ink-50', sel === c.id && 'bg-brand-50')}>
                  <Td className="w-24">{careBadge(c.next_care_date)}{c.next_care_date && c.next_care_date <= today() && <div className="text-[11px] text-ink-400">{fmtDate(c.next_care_date).slice(0, 5)}</div>}</Td>
                  <Td className="min-w-[180px]"><div className="font-semibold">{c.company_name || c.contact_name}</div><div className="text-xs text-ink-400">{c.code}{c.sys_code && <b className="text-brand-700"> · {c.sys_code}</b>}{c.sys_username && <span className="text-ink-500"> · @{c.sys_username}</span>}{c.company_name ? ` – ${c.contact_name}` : ''}{c.ownership === 'owned' && ' · 👑'}</div></Td>
                  <Td><div className="whitespace-nowrap">{c.phone || c.zalo}</div><div className="text-xs text-ink-400">{c.last_contact_at ? 'LH ' + fmtDate(c.last_contact_at).slice(0, 5) : 'Chưa liên hệ'}</div></Td>
                  {!compact && <Td><div>{a.label('customer_type', c.customer_type)}</div><div className="text-xs text-ink-400">{a.label('industry', c.industry)}</div></Td>}
                  {!compact && <Td className="max-w-[200px] text-xs">{a.label('import_method', c.import_method)}</Td>}
                  <Td><Badge color={STAGE_TONE[c.stage]}>{a.label('stage', c.stage)}</Badge></Td>
                  <Td>{tempDot(c.temperature)}</Td>
                  <Td className="max-w-[160px] text-xs">{a.label('care_result', c.last_result)}</Td>
                  <Td className="whitespace-nowrap text-center tabular-nums">{c.care_count} / {c.quote_count} / <b>{c.order_count}</b>{noOrder(c)}</Td>
                  <Td className="whitespace-nowrap text-xs">{a.personName(c.owner_id)}</Td>
                  <Td className="whitespace-nowrap" onClick={e => e.stopPropagation()}><div className="flex gap-1"><Button size="sm" onClick={e => quickCare(e, c.id)}>Ghi chăm sóc</Button><Button size="sm" onClick={() => go(`/crm/quote?customer=${c.id}`)}>Báo giá</Button></div></Td>
                </tr>))}
            </Table>
  </>;
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
    ['id', 'code', 'phone_norm', 'zalo_norm', 'owner_id', 'sys_last_order_date', 'sys_order_count', 'sys_revenue', 'sys_synced_at', 'sys_first_order_date', 'sys_created_date', 'ownership', 'owned_at', 'care_count', 'quote_count', 'order_count', 'first_order_code', 'first_order_at', 'last_order_at',
      'last_contact_at', 'last_result', 'created_by', 'created_at', 'updated_at', 'deleted_at'].forEach(k => delete payload[k]);
    for (const k of Object.keys(payload)) if (payload[k] === '') payload[k] = null;
    if (!payload.contact_name || !payload.customer_type || !payload.source) throw new Error('Nhập đủ: Người liên hệ, Loại khách, Nguồn khách');
    if (!payload.phone && !payload.zalo && !payload.sys_code && !payload.sys_username) throw new Error('Cần ít nhất SĐT, Zalo, Mã KH hoặc Username hệ thống');
    if (payload.tax_code && !/^(\d{10}(-\d{3})?|\d{12})$/.test(String(payload.tax_code).replace(/[^\d-]/g, ''))) throw new Error('Mã số thuế phải 10 số, 10-3 số hoặc 12 số');
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
            <Badge color={STAGE_TONE[c.stage]}>{a.label('stage', c.stage)}</Badge>
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
            <Field label="Mã số thuế" hint="10 số, 10-3 số, hoặc 12 số (cá nhân / hộ KD)"><Input value={f.tax_code} onChange={ev('tax_code')} onBlur={check} inputMode="numeric" /></Field>
            <Field label="Username hệ thống" hint="Tên đăng nhập của khách trên hệ thống đơn hàng"><Input value={f.sys_username} onChange={ev('sys_username')} placeholder="VD: luongit" /></Field>
            <Field label="Kho VN"><Input value={f.sys_warehouse} onChange={ev('sys_warehouse')} placeholder="Kho Hà Nội / Kho HCM" /></Field>
            <Field label="Mã KH hệ thống" hint={c?.sys_last_order_date ? `${c.sys_first_order_date ? `Cọc đầu ${fmtDate(c.sys_first_order_date)} · ` : ''}cọc gần nhất ${fmtDate(c.sys_last_order_date)} · chưa mua mới ${daysBetween(c.sys_last_order_date, today())} ngày` : 'Mã khách trên hệ thống đơn hàng, dùng cho nội dung QR'}><Input value={f.sys_code} onChange={e => set('sys_code')(e.target.value.toUpperCase())} placeholder="VD: KH1234" /></Field>
            <Field label="Email"><Input value={f.email} onChange={ev('email')} /></Field>
            <Field label="Facebook (link)"><Input value={f.facebook} onChange={ev('facebook')} /></Field>
            <Field label="Tỉnh / thành phố"><Input value={f.province} onChange={ev('province')} /></Field>
            <Field label="Địa chỉ" className="sm:col-span-2"><Input value={f.address} onChange={ev('address')} /></Field>
            <Field label="Ông / Bà"><Select options={[['Ông', 'Ông'], ['Bà', 'Bà'], ['Anh', 'Anh'], ['Chị', 'Chị']]} value={f.salutation} onChange={set('salutation')} placeholder="—" /></Field>
            <Field label="Người đại diện pháp luật"><Input value={f.legal_rep} onChange={ev('legal_rep')} /></Field>
            <Field label="Địa chỉ pháp nhân" className="sm:col-span-2"><Input value={f.legal_address} onChange={ev('legal_address')} /></Field>
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
  const pg = usePager('care_hist', [customerId]);
  const { data: res, loading } = useLoad(() => db.from('care_logs').select('*', { count: true }).eq('customer_id', customerId).order('created_at', { asc: false }).range(pg.from, pg.to), [customerId, pg.page, pg.size]);
  const data = (res as any)?.data; const total = (res as any)?.count ?? 0;
  if (loading && !data) return <Loading />;
  if (!data?.length) return <Empty>Chưa có lần chăm sóc nào</Empty>;
  return <><ol className="space-y-3">{(data as any[]).map(l => (
    <li key={l.id} className="rounded-lg border border-ink-100 p-3">
      <div className="flex flex-wrap items-center gap-2 text-xs text-ink-500"><b className="text-ink-800">{fmtDateTime(l.created_at)}</b>
        {a.personName(l.sale_id)} · {a.label('channel', l.channel)} · {a.label('care_purpose', l.purpose)}
        <Badge color={l.is_connected ? 'green' : 'gray'}>{a.label('care_result', l.result)}</Badge></div>
      <p className="mt-1 whitespace-pre-wrap text-sm">{l.content}</p>
      <div className="mt-1 text-xs text-ink-400">→ {a.label('stage', l.stage_after)} · {a.label('temperature', l.temperature_after)}{l.next_care_date && ` · hẹn ${fmtDate(l.next_care_date)}`}{l.quotation_code && ` · ${l.quotation_code}`}</div>
    </li>))}</ol><Pager p={pg} total={total} /></>;
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
  da_chot: ['Đã chốt đơn', 'green'], tu_choi: ['Khách từ chối', 'red'], het_han: ['Hết hạn', 'slate'], da_thay_the: ['Đã thay thế', 'gray'],
};
export const QuoteStatus = ({ s }: { s: string }) => <Badge color={QUOTE_STATUS[s]?.[1]}>{QUOTE_STATUS[s]?.[0] || s}</Badge>;
