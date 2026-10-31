// Xuất HĐ đầu ra: kế toán nạp sổ HĐ chính thức (mã hàng MISA) → sale lập phiếu (giá + đơn vị nhận HĐ) → kế toán xuất nháp → sale xác nhận ký → kế toán ký
import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, Select, Stat, StatusChips, Table, Tabs, Td, Textarea, ask, toast, useAction, useLoad } from '../../components/ui';
import { Pager, usePager } from '../../components/Pager';
import { CustomerPicker } from '../../components/CustomerPicker';
import { db, fetchAll } from '../../lib/sb';
import { useApp } from '../../state';
import { readTable, readXlsx, writeXlsx } from '../../lib/xlsx';
import { fmtDate, fmtDateTime, money, num, stripVN, today } from '../../lib/format';
import { MISA_HEADER_ROW, misaMap, misaRows, parseBuyers, parseOrders, parseSoXuat, soRows } from '../../lib/xuathd';
import { Money, useAccCfg } from '../acc/common';
import { printDraft } from './print';

export const OST: Record<string, [string, string]> = {
  soan: ['Sale đang soạn', 'slate'], cho_nhap: ['Chờ xuất nháp', 'amber'], da_nhap: ['Đã xuất nháp — chờ sale', 'blue'],
  xac_nhan_ky: ['Sale xác nhận ký', 'purple'], da_ky: ['Đã ký', 'green'], huy: ['Hủy', 'gray'],
};
/** Đơn giá xuất so với giá nhập (APT) và giá khách trên hệ thống */
function giaCheck(gia: number, dgNhap: number | null, gk: number | null, min: number): { tone: string; txt: string; bad: boolean } {
  if (!gia) return { tone: 'text-ink-400', txt: '', bad: false };
  const b = dgNhap ? gia / dgNhap - 1 : null; const parts: string[] = [];
  if (b !== null) parts.push(`biên ${(b * 100).toFixed(2)}%`);
  if (gk && Math.abs(gk - gia) > 0.5) parts.push(`giá HT ${money(gk)}`);
  const bad = b !== null && b < 0;
  return { tone: bad ? 'text-red-600 font-semibold' : b !== null && b < min - 0.001 ? 'text-amber-700' : 'text-ink-500', txt: parts.join(' · '), bad };
}
const OBadge = ({ s }: { s: string }) => <Badge color={OST[s]?.[1] || 'gray'}>{OST[s]?.[0] || s}</Badge>;
const vatTxt = (v: any) => (v === null || v === undefined ? '' : Math.round(Number(v) * 100) + '%');
const INV_SEL = '*,out_invoice_lines(id,item_id,stt,sl,don_gia,vat,out_items(id,ma_hang,ten,dvt,vat,sl_nhap,dg_nhap,gia_khach,so_hd_vao,md))';
const totalOf = (v: any) => (v.out_invoice_lines || []).reduce((t: number, l: any) => { const tt = Math.round(l.sl * l.don_gia); return { tt: t.tt + tt, thue: t.thue + Math.round(tt * Number(l.vat ?? l.out_items?.vat ?? 0)) } as any; }, { tt: 0, thue: 0 } as any);

export default function Out() {
  const a = useApp(); const acc = a.isAdmin || a.has('ke_toan');
  const [tab, setTab] = useState<string>(() => sessionStorage.getItem('nt_out_tab') || (acc ? 'inv' : 'mine'));
  const go2 = (t: string) => { setTab(t); sessionStorage.setItem('nt_out_tab', t); };
  if (!acc && !a.isSales) return <Layout title="Xuất HĐ đầu ra"><Card>Chỉ Kế toán và Kinh doanh.</Card></Layout>;
  const tabs: [string, React.ReactNode][] = acc ? [['inv', 'Phiếu xuất HĐ'], ['items', 'Sổ HĐ đầu vào (mã hàng)']] : [['mine', 'Hàng chờ xuất HĐ'], ['inv', 'Phiếu của tôi'], ['free', 'Dòng chưa có sale']];
  const t = tabs.some(x => x[0] === tab) ? tab : tabs[0][0];
  return <Layout title="Xuất HĐ đầu ra">
    <Tabs value={t} onChange={go2} tabs={tabs} />
    <div className="mt-4">{t === 'inv' && <Invoices acc={acc} />}{t === 'items' && <Items acc />}{t === 'mine' && <Items />}{t === 'free' && <Items free />}</div>
  </Layout>;
}

// ============ Dòng hàng (sổ) ============
function Items({ acc = false, free = false }: { acc?: boolean; free?: boolean }) {
  const a = useApp(); const { busy, run } = useAction();
  const { data, loading, reload } = useLoad(() => fetchAll<any>(() => {
    let q = db.from('out_items_v').select('*').order('stt_so', { asc: false, nulls: 'last' });
    if (free) q = q.is('sale_id', null); else if (!acc) q = q.gt('ton', 0);
    return q;
  }, 50000), [acc, free]);
  const [q, setQ] = useState(''); const [f, setF] = useState(acc ? '' : 'ton'); const [hd, setHd] = useState(''); const [sale, setSale] = useState('');
  const [pick, setPick] = useState<Record<string, boolean>>({}); const [edit, setEdit] = useState<any>(null); const [newInv, setNewInv] = useState<any[] | null>(null); const [up, setUp] = useState(false);
  const all = (data || []).filter((t: any) => acc || free || t.sale_id);
  const rows = all.filter((t: any) => (!f || (f === 'ton' ? t.ton > 0.0001 : f === 'nosale' ? !t.sale_id : f === 'nomd' ? !t.md : f === 'het' ? t.ton <= 0.0001 : true))
    && (!hd || t.so_hd_vao === hd) && (!sale || (t.sale_id || '—') === sale)
    && (!q || stripVN([t.ma_hang, t.ten, t.md, t.nvkd, t.username, t.so_hd_vao].join(' ')).toLowerCase().includes(stripVN(q).toLowerCase())));
  const pg = usePager(acc ? 'out_items' : free ? 'out_free' : 'out_mine', [q, f, hd, sale]);
  const hds = Array.from(new Set(all.map((t: any) => t.so_hd_vao).filter(Boolean))) as string[];
  const sales = Array.from(new Set(all.map((t: any) => t.sale_id || '—'))) as string[];
  const chosen = all.filter((t: any) => pick[t.id]);
  const cnt = (k: string) => all.filter((t: any) => k === 'ton' ? t.ton > 0.0001 : k === 'nosale' ? !t.sale_id : k === 'nomd' ? !t.md : t.ton <= 0.0001).length;
  const claim = (t: any) => run(async () => { const md = await ask({ title: 'Nhận dòng này', message: `${t.ma_hang} · ${t.ten.slice(0, 80)}`, input: { label: 'Mã đơn (MD) của bạn', required: true } }); if (md === null) return;
    await db.rpc('out_item_set', { p_id: t.id, p_md: md, p_sale: null }); reload(); }, 'Đã nhận dòng');
  const exportSo = () => run(async () => {
    const ls = await fetchAll<any>(() => db.from('out_invoice_lines').select('item_id,sl,don_gia,vat,out_invoices(code,status,buyer_name,tax_code,address,email,buyer_info,so_hd,ngay_hd)'));
    await writeXlsx('So_xuat_HD_' + today(), soRows(all, ls, id => a.personName(id)), 'NEW');
  });
  return <>
    {acc && <div className="mb-3 flex flex-wrap items-center gap-2"><Button variant="primary" onClick={() => setUp(true)}>⇪ Nạp sổ Excel · đơn hàng · đơn vị nhận HĐ</Button>
      <Button loading={busy} onClick={exportSo}>⬇ Xuất sổ (đúng mẫu)</Button>
      <span className="text-xs text-ink-500">Nạp lại cả sổ bất cứ lúc nào: hệ thống cập nhật theo mã hàng, giữ nguyên phiếu đã lập.</span></div>}
    {acc && <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-4">
      <Stat label="Dòng trong sổ" value={all.length} sub={`${hds.length} HĐ đầu vào`} />
      <Stat label="Còn tồn chưa lập phiếu" value={cnt('ton')} tone={cnt('ton') ? 'amber' : undefined} onClick={() => setF('ton')} />
      <Stat label="Chưa gắn sale" value={cnt('nosale')} tone={cnt('nosale') ? 'red' : undefined} onClick={() => setF('nosale')} />
      <Stat label="Chưa có ID đơn" value={cnt('nomd')} onClick={() => setF('nomd')} /></div>}
    {free && <p className="mb-3 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">Dòng trên HĐ chính thức chưa xác định được sale. Hàng của bạn thì bấm <b>Nhận</b>, nhập mã đơn.</p>}
    {!acc && !free && <p className="mb-3 text-sm text-ink-600">Hàng đã có HĐ đầu vào, còn tồn chưa xuất cho khách. Tick các dòng cùng 1 đơn vị nhận HĐ → <b>Lập phiếu xuất HĐ</b>: xác nhận giá + thông tin xuất HĐ.</p>}
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Input className="max-w-xs" placeholder="🔎 Mã hàng, tên, ID đơn, NVKD, user, số HĐ…" value={q} onChange={e => setQ(e.target.value)} />
      <Select className="w-44" placeholder="Mọi HĐ đầu vào" options={hds.map(h => [h, 'HĐ ' + h] as [string, string])} value={hd} onChange={setHd} />
      {acc && <Select className="w-44" placeholder="Mọi sale" options={sales.map(s => [s, s === '—' ? '— Chưa có sale' : a.personName(s)] as [string, string])} value={sale} onChange={setSale} />}
      {!free && <Select className="w-44" placeholder="Tất cả dòng" options={[['ton', 'Còn tồn'], ['het', 'Đã lập phiếu hết'], ...(acc ? [['nosale', 'Chưa gắn sale'], ['nomd', 'Chưa có ID đơn']] : [])] as [string, string][]} value={f} onChange={setF} />}
      {!free && chosen.length > 0 && <Button className="hidden sm:inline-flex" variant="primary" onClick={() => setNewInv(chosen)}>Lập phiếu xuất HĐ ({chosen.length} dòng)</Button>}
    </div>
    {!loading && rows.length > 0 && <div className="mb-3 space-y-2 sm:hidden">{pg.slice(rows).map((t: any) =>
      <div key={t.id} className={cx('rounded-2xl border bg-white p-3 shadow-soft', pick[t.id] ? 'border-brand-500 bg-brand-50/60' : 'border-ink-200')}>
        <div className="flex items-start gap-2">{!free && <input type="checkbox" className="mt-1 h-5 w-5" disabled={t.ton <= 0.0001 || (!acc && !t.sale_id)} checked={!!pick[t.id]} onChange={e => setPick(p => ({ ...p, [t.id]: e.target.checked }))} />}
          <div className="min-w-0 flex-1"><div className="text-[11px] text-ink-500">{t.ma_hang} · HĐ {t.so_hd_vao}{t.md ? ' · ' + t.md : ''}{acc ? ' · ' + (a.personName(t.sale_id) || t.nvkd || 'chưa có sale') : t.username ? ' · ' + t.username : ''}</div>
            <div className="line-clamp-2 text-sm font-medium text-ink-900">{t.ten}</div>
            <div className="mt-1 flex flex-wrap gap-x-3 text-xs"><span>SL {num(t.sl_nhap, 2)} {t.dvt}</span><span>Giá nhập <Money v={t.dg_nhap} /></span>{t.gia_khach && <span>Giá khách <b><Money v={t.gia_khach} /></b></span>}
              <span className={t.ton > 0.0001 ? 'font-semibold text-amber-700' : 'text-ink-400'}>Tồn {num(t.ton, 2)}</span></div>
            {t.phieu && <div className="mt-1 text-[11px] text-ink-500">{t.phieu.split(',').map((p: string) => { const [c, st] = p.split(':'); return `${c} · ${OST[st]?.[0] || st}`; }).join(' | ')}</div>}</div>
          {free ? <Button size="sm" variant="primary" loading={busy} onClick={() => claim(t)}>Nhận</Button> : acc ? <Button size="sm" onClick={() => setEdit(t)}>Sửa</Button> : null}</div></div>)}
      <Pager p={pg} total={rows.length} /></div>}
    {!free && chosen.length > 0 && <div className="fixed inset-x-3 bottom-3 z-30 sm:hidden"><Button className="w-full" variant="primary" onClick={() => setNewInv(chosen)}>Lập phiếu xuất HĐ ({chosen.length} dòng)</Button></div>}
    <Card className={rows.length ? 'hidden sm:block' : ''} bodyClass="p-0">{loading ? <Loading /> : !rows.length ? <Empty>{free ? 'Không có dòng chưa có sale' : 'Không có dòng'}</Empty> :
      <div className="overflow-x-auto"><Table head={[...(free ? [] : ['']), 'Mã hàng', 'Tên hàng', 'SL nhập', 'Đơn giá nhập', 'VAT', 'HĐ vào', 'ID đơn', ...(acc ? ['NVKD · User'] : ['Khách']), 'Giá khách', 'Còn tồn', 'Phiếu', '']}>{pg.slice(rows).map((t: any) =>
        <tr key={t.id} className={cx(pick[t.id] && 'bg-brand-50/60')}>
          {!free && <Td><input type="checkbox" disabled={t.ton <= 0.0001 || (!acc && !t.sale_id)} checked={!!pick[t.id]} onChange={e => setPick(p => ({ ...p, [t.id]: e.target.checked }))} /></Td>}
          <Td className="whitespace-nowrap text-xs font-semibold">{t.ma_hang}</Td><Td className="min-w-[220px] max-w-[360px] text-xs"><div className="line-clamp-2">{t.ten}</div></Td>
          <Td className="whitespace-nowrap text-right">{num(t.sl_nhap, 2)} <span className="text-[11px] text-ink-400">{t.dvt}</span></Td><Td className="text-right"><Money v={t.dg_nhap} /></Td><Td className="text-right text-xs">{vatTxt(t.vat)}</Td>
          <Td className="whitespace-nowrap text-xs">{t.so_hd_vao}<div className="text-ink-400">{fmtDate(t.ngay_vao)}</div></Td>
          <Td className="whitespace-nowrap text-xs">{t.md || <span className="text-amber-700">—</span>}{t.match_src === 'hd_xml' && <div className="text-[10px] text-emerald-700">theo HĐ XML</div>}</Td>
          {acc ? <Td className="whitespace-nowrap text-xs">{a.personName(t.sale_id) || <span className="text-red-600">{t.nvkd || 'chưa có sale'}</span>}<div className="text-ink-400">{t.username}</div></Td> : <Td className="text-xs">{t.username}</Td>}
          <Td className="text-right"><Money v={t.gia_khach} /></Td>
          <Td className={cx('whitespace-nowrap text-right font-semibold', t.ton > 0.0001 ? 'text-amber-700' : 'text-ink-400')}>{num(t.ton, 2)}</Td>
          <Td className="min-w-[150px] text-[11px] text-ink-500">{(t.phieu || '').split(',').filter(Boolean).map((p: string) => { const [c, s] = p.split(':'); return <div key={p}>{c} · {OST[s]?.[0]}</div>; })}{!t.phieu && t.legacy?.status ? <div>Sổ cũ: {t.legacy.status}</div> : ''}</Td>
          <Td>{free ? <Button size="sm" variant="primary" loading={busy} onClick={() => claim(t)}>Nhận</Button> : acc ? <Button size="sm" onClick={() => setEdit(t)}>Sửa</Button> : null}</Td></tr>)}</Table></div>}
      <Pager p={pg} total={rows.length} /></Card>
    {up && <ImportSo onClose={() => setUp(false)} onDone={() => { setUp(false); reload(); }} />}
    {edit && <ItemEdit t={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); reload(); }} />}
    {newInv && <InvoiceEditor items={newInv} onClose={() => setNewInv(null)} onDone={() => { setNewInv(null); setPick({}); reload(); }} />}
  </>;
}

function ImportSo({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction(); const [file, setFile] = useState<File | null>(null); const [ord, setOrd] = useState<File | null>(null); const [buy, setBuy] = useState<File | null>(null);
  const [res, setRes] = useState<any>(null); const [err, setErr] = useState('');
  const analyze = async () => { setErr(''); setRes(null);
    try { if (!file && !ord && !buy) throw new Error('Chọn ít nhất 1 file');
      const p = file ? parseSoXuat(await readTable(file, { fillMerged: true })) : { rows: [], legacy: [], warnings: [] };
      const orders = ord ? parseOrders(await readTable(ord)) : []; const buyers = buy ? parseBuyers(await readXlsx(buy)) : [];
      setRes({ ...p, orders, buyers }); } catch (e: any) { setErr(e.message || String(e)); } };
  const save = () => run(async () => {
    const rows = res.rows.map((r: any) => ({ ...r, row: undefined })); const msg: string[] = [];
    if (rows.length) { let out: any = { new: 0, upd: 0, legacy: 0, no_sale: 0 };
      for (let i = 0; i < rows.length; i += 300) { const x = await db.rpc<any>('out_items_import', { p_rows: rows.slice(i, i + 300), p_legacy: i + 300 >= rows.length ? res.legacy : [] });
        out = { new: out.new + x.new, upd: out.upd + x.upd, legacy: out.legacy + x.legacy, no_sale: x.no_sale }; }
      msg.push(`${out.new} dòng mới, ${out.upd} dòng cập nhật, ${out.legacy} phiếu từ sổ cũ`); }
    if (res.orders.length) { let n = 0; for (let i = 0; i < res.orders.length; i += 1000) n += await db.rpc<number>('out_orders_import', { p_rows: res.orders.slice(i, i + 1000) }); msg.push(`${n} dòng gắn khách/sale theo file đơn hàng`); }
    if (res.buyers.length) { const n = await db.rpc<number>('out_buyers_import', { p_rows: res.buyers }); msg.push(`${n} đơn vị nhận HĐ`); }
    toast.ok('Đã nạp: ' + msg.join(' · ')); onDone();
  });
  const F = ({ f, set, l, hint }: { f: File | null; set: (f: File | null) => void; l: string; hint: string }) => <Field label={l} hint={hint}>
    <label className={cx('flex cursor-pointer items-center gap-2 rounded-xl border border-dashed px-3 py-2 text-sm', f ? 'border-emerald-400 bg-emerald-50 text-emerald-800' : 'border-ink-300 hover:border-brand-400')}>
      <input type="file" accept=".xlsx,.csv" className="hidden" onChange={e => { set(e.target.files?.[0] || null); setRes(null); }} />{f ? '✓ ' + f.name : '⇪ Chọn file .xlsx'}</label></Field>;
  return <Modal open onClose={onClose} size="lg" title="Nạp sổ HĐ chính thức · đơn hàng · đơn vị nhận HĐ"
    footer={res ? <Button variant="primary" loading={busy} onClick={save}>Lưu</Button> : <Button variant="dark" onClick={analyze}>Đọc file</Button>}>
    <div className="grid gap-3 sm:grid-cols-3">
      <F f={file} set={setFile} l="1. Sổ Excel HĐ (mẫu Xuathd)" hint="Mã hàng HH0001-1726-2026, Tên hàng, SL nhập, Số HĐ… ID/NVKD/USER trống cũng được" />
      <F f={ord} set={setOrd} l="2. Danh sách đơn hàng" hint="Order_Export: Mã đơn hàng + Khách hàng (+ Sale) → gắn khách, sale theo chủ khách" />
      <F f={buy} set={setBuy} l="3. Danh sách đơn vị nhận HĐ" hint="Sheet “Thong tin KH” (MST, Tên đơn vị, Địa chỉ, mail) → sale gõ MST là tự điền" /></div>
    <div className="mt-2 text-xs text-ink-500">Nạp file nào cũng được, không cần đủ cả 3. Nạp lại nhiều lần không bị trùng.</div>
    {err && <div className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">{err}</div>}
    {res && <div className="mt-3 space-y-2 text-sm">
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-5"><Stat label="Dòng hàng" value={res.rows.length} /><Stat label="Có ID đơn" value={res.rows.filter((r: any) => r.md).length} />
        <Stat label="Phiếu từ sổ cũ" value={res.legacy.length} sub="tạo sẵn, không làm lại" /><Stat label="Đơn hàng" value={res.orders.length} /><Stat label="Đơn vị nhận HĐ" value={res.buyers.length} /></div>
      {res.warnings.slice(0, 8).map((w: string, i: number) => <div key={i} className="rounded bg-amber-50 px-2 py-1 text-xs text-amber-900">• {w}</div>)}
      <div className="text-xs text-ink-500">Tự gắn ID đơn, sale, khách: theo HĐ XML đã đối chiếu → ID trên sổ → NVKD → mã đơn trong file đơn hàng → username (chủ khách trên ERP).</div>
    </div>}
  </Modal>;
}

function ItemEdit({ t, onClose, onDone }: { t: any; onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction(); const { data: dir } = useLoad(() => db.rpc<{ id: string; full_name: string }[]>('acc_sale_directory'), []);
  const [md, setMd] = useState(t.md || ''); const [sale, setSale] = useState(t.sale_id || ''); const [user, setUser] = useState(t.username || ''); const [note, setNote] = useState(t.note || '');
  return <Modal open onClose={onClose} title={`Sửa dòng ${t.ma_hang}`} footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
    await db.rpc('out_item_set', { p_id: t.id, p_md: md || null, p_sale: sale || null, p_username: user !== (t.username || '') ? user : null, p_note: note || null }); onDone(); }, 'Đã lưu')}>Lưu</Button>}>
    <div className="mb-2 text-sm text-ink-600">{t.ten}</div>
    <div className="grid grid-cols-2 gap-2"><Field label="ID đơn (MD)"><Input value={md} onChange={e => setMd(e.target.value.toUpperCase())} /></Field>
      <Field label="Username khách"><Input value={user} onChange={e => setUser(e.target.value)} /></Field></div>
    <Field className="mt-2" label="Sale phụ trách"><Select placeholder="— Chưa có —" options={(dir || []).map(p => [p.id, p.full_name] as [string, string])} value={sale} onChange={setSale} /></Field>
    <Field className="mt-2" label="Ghi chú"><Input value={note} onChange={e => setNote(e.target.value)} /></Field>
  </Modal>;
}

// ============ Lập / sửa phiếu ============
function InvoiceEditor({ items, inv, onClose, onDone }: { items?: any[]; inv?: any; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const { busy, run } = useAction(); const cfg = useAccCfg();
  const init = inv ? (inv.out_invoice_lines || []).map((l: any) => ({ item: l.out_items, item_id: l.item_id, sl: String(l.sl), gia: String(Math.round(l.don_gia)), vat: l.vat }))
    : (items || []).map(t => ({ item: t, item_id: t.id, sl: String(+Number(t.ton).toFixed(4)), gia: t.gia_khach ? String(Math.round(t.gia_khach)) : '', vat: t.vat }));
  const [ls, setLs] = useState<any[]>(init);
  const cid0 = inv?.customer_id || (items || []).find(t => t.customer_id)?.customer_id || null;
  const { data: cus0 } = useLoad(() => cid0 ? db.from<any>('customers').select('id,code,sys_code,sys_username,company_name,contact_name,tax_code,address,legal_address,email,phone').eq('id', cid0).maybeSingle() : Promise.resolve(null), [cid0]);
  const [cus, setCus] = useState<any>(null); const c = cus || cus0;
  const { data: buyers } = useLoad(() => c?.id ? db.from<any[]>('out_buyers').select('*').eq('customer_id', c.id).order('created_at', { asc: false }) : Promise.resolve([]), [c?.id]);
  const [b, setB] = useState<any>(inv ? { name: inv.buyer_name || '', mst: inv.tax_code || '', addr: inv.address || '', email: inv.email || '', pay: inv.payment || 'TM/CK', note: inv.note || '' } : { name: '', mst: '', addr: '', email: '', pay: 'TM/CK', note: '' });
  const setF = (k: string, v: string) => setB((x: any) => ({ ...x, [k]: v }));
  const [look, setLook] = useState('');
  const lookup = async () => { const m = (b.mst || '').trim(); if (m.length < 10) { setLook(''); return; }
    try { const r = await db.rpc<any[]>('out_buyer_lookup', { p_mst: m }); const x = (r || [])[0];
      if (!x) { setLook('Chưa có trong danh sách — nhập tay, lưu phiếu là lưu luôn'); return; }
      setB((y: any) => ({ ...y, name: y.name || x.name, addr: y.addr || x.address || '', email: y.email || x.email || '' })); setLook('✓ Đã điền theo danh sách đơn vị nhận HĐ');
    } catch { setLook(''); } };
  const fromCus = () => c && setB((x: any) => ({ ...x, name: c.company_name || c.contact_name || '', mst: c.tax_code || '', addr: c.legal_address || c.address || '', email: c.email || '' }));
  const sub = ls.reduce((t, l) => t + Math.round(Number(l.sl || 0) * Number(l.gia || 0)), 0); const tax = ls.reduce((t, l) => t + Math.round(Number(l.sl || 0) * Number(l.gia || 0) * Number(l.vat ?? 0)), 0);
  const vats = Array.from(new Set(ls.map(l => vatTxt(l.vat))));
  const save = (submit: boolean) => run(async () => {
    if (ls.some(l => !Number(l.sl) || l.gia === '')) throw new Error('Nhập đủ số lượng và đơn giá từng dòng');
    await db.rpc('out_invoice_save', { p_id: inv?.id || null, p_data: { customer_id: c?.id || null, buyer_name: b.name, tax_code: b.mst, address: b.addr, email: b.email, payment: b.pay, note: b.note, submit },
      p_lines: ls.map(l => ({ item_id: l.item_id, sl: Number(l.sl), don_gia: Number(l.gia), vat: l.vat })) });
    onDone();
  }, submit ? 'Đã gửi kế toán xuất nháp' : 'Đã lưu phiếu');
  const after = inv && ['da_nhap', 'xac_nhan_ky'].includes(inv.status);
  return <Modal open onClose={onClose} size="xl" title={inv ? `Sửa phiếu ${inv.code}` : 'Lập phiếu xuất HĐ'}
    footer={<>{!inv || inv.status === 'soan' ? <Button loading={busy} onClick={() => save(false)}>Lưu nháp</Button> : null}
      <Button variant="primary" loading={busy} disabled={!b.name || !ls.length} onClick={() => save(true)}>{after ? 'Lưu — kế toán xuất nháp lại' : 'Xác nhận giá & thông tin → gửi kế toán'}</Button></>}>
    {after && <div className="mb-3 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">Phiếu đã xuất nháp — sửa xong phiếu quay về “Chờ xuất nháp”, kế toán làm nháp lại.</div>}
    {vats.length > 1 && <div className="mb-3 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">Phiếu có nhiều thuế suất ({vats.join(', ')}) — thường phải tách HĐ riêng.</div>}
    <div className="grid gap-3 lg:grid-cols-2">
      <div><Field label="Khách hàng (ERP)"><CustomerPicker value={c} onChange={x => setCus(x)} /></Field>
        <div className="mt-2 flex flex-wrap gap-1.5 text-xs">{c && <button className="rounded-lg border border-ink-200 px-2 py-1 hover:border-brand-400" onClick={fromCus}>Lấy thông tin khách</button>}
          {(buyers || []).map(x => <button key={x.id} className="rounded-lg border border-brand-200 bg-brand-50 px-2 py-1 font-semibold text-brand-800 hover:border-brand-500"
            onClick={() => setB((y: any) => ({ ...y, name: x.name, mst: x.tax_code || '', addr: x.address || '', email: x.email || '' }))}>{x.name}{x.tax_code ? ' · ' + x.tax_code : ''}</button>)}</div>
        {!!(buyers || []).length && <div className="mt-1 text-[11px] text-ink-500">Đơn vị nhận HĐ đã dùng của khách này — bấm để điền.</div>}</div>
      <div className="grid grid-cols-2 gap-2">
        <Field className="col-span-2" label="Tên đơn vị mua hàng *"><Input value={b.name} onChange={e => setF('name', e.target.value)} placeholder="HỘ KINH DOANH … / CÔNG TY …" /></Field>
        <Field label="Mã số thuế" hint={look}><Input value={b.mst} onChange={e => setF('mst', e.target.value.replace(/\s/g, ''))} onBlur={() => lookup()} /></Field>
        <Field label="Hình thức thanh toán"><Select options={[['TM/CK', 'TM/CK'], ['CK', 'CK'], ['TM', 'TM']]} value={b.pay} onChange={v => setF('pay', v)} /></Field>
        <Field className="col-span-2" label="Địa chỉ"><Input value={b.addr} onChange={e => setF('addr', e.target.value)} /></Field>
        <Field className="col-span-2" label="Email nhận HĐ"><Input value={b.email} onChange={e => setF('email', e.target.value)} /></Field>
      </div></div>
    <div className="mt-3 space-y-2 sm:hidden">{ls.map((l, i) => { const g = giaCheck(Number(l.gia || 0), l.item?.dg_nhap ?? null, l.item?.gia_khach ?? null, cfg.bien_nt_min);
      return <div key={l.item_id} className="rounded-xl border border-ink-200 p-2.5">
        <div className="flex items-start justify-between gap-2"><div className="min-w-0"><div className="text-[11px] text-ink-500">{l.item?.ma_hang} · {l.item?.dvt} · VAT {vatTxt(l.vat)}{l.item?.ton !== undefined ? ' · tồn ' + num(l.item.ton, 2) : ''}</div>
          <div className="line-clamp-2 text-sm">{l.item?.ten}</div></div>{ls.length > 1 && <button className="px-1 text-red-600" onClick={() => setLs(x => x.filter((_, j) => j !== i))}>✕</button>}</div>
        <div className="mt-2 grid grid-cols-2 gap-2"><Field label="SL xuất"><Input className="text-right" inputMode="decimal" value={l.sl} onChange={e => setLs(x => x.map((y, j) => j === i ? { ...y, sl: e.target.value.replace(/[^\d.]/g, '') } : y))} /></Field>
          <Field label="Đơn giá xuất"><Input className="text-right" inputMode="numeric" value={l.gia} onChange={e => setLs(x => x.map((y, j) => j === i ? { ...y, gia: e.target.value.replace(/[^\d.]/g, '') } : y))} /></Field></div>
        <div className="mt-1 flex justify-between text-xs"><span className={g.tone}>{g.bad ? '⚠ dưới giá nhập · ' : ''}{g.txt}</span><b><Money v={Math.round(Number(l.sl || 0) * Number(l.gia || 0))} /></b></div></div>; })}</div>
    <div className="mt-3 hidden max-h-[40vh] overflow-auto rounded-xl border border-ink-200 sm:block"><Table head={['Mã hàng', 'Tên hàng (theo HĐ APT)', 'ĐVT', 'Còn tồn', 'SL xuất', 'Đơn giá xuất', 'VAT', 'Thành tiền', '']}>{ls.map((l, i) =>
      <tr key={l.item_id}><Td className="whitespace-nowrap text-xs">{l.item?.ma_hang}</Td><Td className="min-w-[200px] text-xs">{l.item?.ten}</Td><Td className="text-xs">{l.item?.dvt}</Td>
        <Td className="text-right text-xs">{l.item?.ton !== undefined ? num(l.item.ton, 2) : ''}</Td>
        <Td><Input className="w-24 text-right" inputMode="decimal" value={l.sl} onChange={e => setLs(x => x.map((y, j) => j === i ? { ...y, sl: e.target.value.replace(/[^\d.]/g, '') } : y))} /></Td>
        <Td><Input className="w-28 text-right" inputMode="numeric" value={l.gia} onChange={e => setLs(x => x.map((y, j) => j === i ? { ...y, gia: e.target.value.replace(/[^\d.]/g, '') } : y))} />
          {(() => { const g = giaCheck(Number(l.gia || 0), l.item?.dg_nhap ?? null, l.item?.gia_khach ?? null, cfg.bien_nt_min); return g.txt ? <div className={cx('mt-0.5 whitespace-nowrap text-[10px]', g.tone)}>{g.bad ? '⚠ dưới giá nhập · ' : ''}{g.txt}</div> : null; })()}</Td>
        <Td className="text-xs">{vatTxt(l.vat)}</Td><Td className="text-right"><Money v={Math.round(Number(l.sl || 0) * Number(l.gia || 0))} /></Td>
        <Td>{ls.length > 1 && <button className="text-red-600" onClick={() => setLs(x => x.filter((_, j) => j !== i))}>✕</button>}</Td></tr>)}</Table></div>
    <div className="mt-2 text-right text-sm">Tiền hàng <b>{money(sub)}</b> · Thuế GTGT <b>{money(tax)}</b> · Tổng <b className="text-brand-700">{money(sub + tax)}</b></div>
    {ls.some(l => Number(l.gia) > 0 && l.item?.dg_nhap && Number(l.gia) < l.item.dg_nhap) && <div className="mt-2 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">Có dòng xuất giá thấp hơn giá nhập — ghi lý do vào “Ghi chú cho kế toán” mới gửi được.</div>}
    <Field className="mt-2" label="Ghi chú cho kế toán"><Input value={b.note} onChange={e => setF('note', e.target.value)} placeholder="VD: gộp 1 HĐ, khách cần xuất trước ngày…" /></Field>
    <div className="mt-1 text-xs text-ink-500">Một dòng hàng chia cho nhiều đơn vị: giảm số lượng ở phiếu này, phần còn lại lập phiếu khác.</div>
  </Modal>;
}

// ============ Danh sách phiếu ============
function Invoices({ acc }: { acc: boolean }) {
  const a = useApp(); const { busy, run } = useAction();
  const [st, setSt] = useState(acc ? 'cho_nhap' : ''); const [q, setQ] = useState(''); const [sale, setSale] = useState(''); const [sel, setSel] = useState<string | null>(null); const [pick, setPick] = useState<Record<string, boolean>>({});
  const { data, loading, reload } = useLoad(() => fetchAll<any>(() => db.from('out_invoices').select(INV_SEL).order('status_at', { asc: false })), []);
  const all = data || [];
  const c = (k: string) => all.filter((v: any) => v.status === k).length;
  const rows = all.filter((v: any) => (!st ? v.status !== 'huy' : v.status === st) && (!sale || v.sale_id === sale)
    && (!q || stripVN([v.code, v.buyer_name, v.tax_code, v.so_hd, ...(v.out_invoice_lines || []).map((l: any) => l.out_items?.ma_hang + ' ' + l.out_items?.md)].join(' ')).toLowerCase().includes(stripVN(q).toLowerCase())));
  const pg = usePager('out_inv', [st, q, sale]);
  const chosen = rows.filter((v: any) => pick[v.id]);
  const sales = Array.from(new Set(all.map((v: any) => v.sale_id).filter(Boolean))) as string[];
  const exportMisa = () => run(async () => {
    const list = chosen.length ? chosen : rows.filter((v: any) => v.status === 'cho_nhap'); if (!list.length) throw new Error('Không có phiếu chờ xuất nháp');
    await writeXlsx('HD_nhap_MISA_' + today(), misaRows(list), 'Hóa đơn GTGT', true, { headerRow: MISA_HEADER_ROW, fmt: { 11: 'int', 12: 'int', 13: 'int', 14: 'pct', 15: 'int' } });
    await writeXlsx('HD_nhap_doi_chieu_phieu_' + today(), misaMap(list, id => a.personName(id)), 'Đối chiếu');
    const ids = list.filter((v: any) => v.status === 'cho_nhap').map((v: any) => v.id);
    if (ids.length && await ask({ title: `Đánh dấu ${ids.length} phiếu “Đã xuất nháp”?`, message: 'Bấm sau khi đã nạp file lên phần mềm và tạo nháp xong. Sale được báo để kiểm tra, gửi khách, xác nhận ký.', ok: 'Đã xuất nháp' })) {
      await db.rpc('out_invoice_status', { p_ids: ids, p_status: 'da_nhap' }); setPick({}); reload(); toast.ok('Đã báo sale'); }
  });
  const stItems: [string, string, number, string][] = [['cho_nhap', OST.cho_nhap[0], c('cho_nhap'), 'amber'], ['da_nhap', OST.da_nhap[0], c('da_nhap'), 'blue'], ['xac_nhan_ky', OST.xac_nhan_ky[0], c('xac_nhan_ky'), 'purple'],
    ['da_ky', OST.da_ky[0], c('da_ky'), 'green'], ['soan', OST.soan[0], c('soan'), 'slate'], ['', 'Tất cả', all.filter((v: any) => v.status !== 'huy').length, 'dark'], ['huy', 'Hủy', c('huy'), 'gray']];
  return <>
    {!acc && <p className="mb-3 text-sm text-ink-600">Quy trình: lập phiếu (giá + thông tin xuất HĐ) → kế toán xuất nháp → bạn <b>in / lưu PDF bản nháp gửi khách</b> → khách OK thì bấm <b>Xác nhận ký</b> → kế toán ký, gửi mail cho khách → bạn báo khách kiểm tra email.</p>}
    <StatusChips value={st} onChange={setSt} items={stItems} />
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Input className="max-w-xs" placeholder="🔎 Mã phiếu, đơn vị mua, MST, mã hàng, MD, số HĐ…" value={q} onChange={e => setQ(e.target.value)} />
      {(acc || a.isLead) && <Select className="w-48" placeholder="Mọi sale" options={sales.map(s => [s, a.personName(s)] as [string, string])} value={sale} onChange={setSale} />}
      <Button onClick={reload}>↻ Tải lại</Button>
      {acc && <Button variant="primary" loading={busy} onClick={exportMisa}>⬇ Xuất file nháp{chosen.length ? ` (${chosen.length} phiếu)` : ' (tất cả chờ xuất nháp)'}</Button>}
    </div>
    {!loading && rows.length > 0 && <div className="mb-3 space-y-2 sm:hidden">{pg.slice(rows).map((v: any) => { const t = totalOf(v);
      return <button key={v.id} className="block w-full rounded-2xl border border-ink-200 bg-white p-3 text-left shadow-soft" onClick={() => setSel(v.id)}>
        <div className="flex items-center justify-between gap-2"><b>{v.code}</b><OBadge s={v.status} /></div>
        <div className="mt-1 line-clamp-2 text-sm font-medium text-ink-900">{v.buyer_name || v.buyer_info}</div>
        <div className="mt-1 flex flex-wrap gap-x-3 text-xs text-ink-600">{v.tax_code && <span>MST {v.tax_code}</span>}<span>{(v.out_invoice_lines || []).length} dòng</span><span>Tổng <b><Money v={t.tt + t.thue} /></b></span>
          {acc && <span>{a.personName(v.sale_id)}</span>}{v.so_hd && <span>HĐ {v.so_hd}</span>}{v.sua_sau_nhap && <span className="font-semibold text-red-600">sửa sau nháp</span>}</div></button>; })}
      <Pager p={pg} total={rows.length} /></div>}
    <Card className={rows.length ? 'hidden sm:block' : ''} bodyClass="p-0">{loading ? <Loading /> : !rows.length ? <Empty>Không có phiếu</Empty> :
      <div className="overflow-x-auto"><Table head={[...(acc ? [''] : []), 'Phiếu', 'Sale', 'Đơn vị mua', 'MST', 'Dòng', 'Tiền hàng', 'Thuế', 'Trạng thái', 'Số HĐ', 'Cập nhật']}>{pg.slice(rows).map((v: any) => { const t = totalOf(v);
        return <tr key={v.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setSel(v.id)}>
          {acc && <Td><input type="checkbox" checked={!!pick[v.id]} onClick={e => e.stopPropagation()} onChange={e => setPick(p => ({ ...p, [v.id]: e.target.checked }))} /></Td>}
          <Td className="whitespace-nowrap font-semibold">{v.code}{v.legacy && <div className="text-[10px] font-normal text-ink-400">sổ cũ</div>}{v.sua_sau_nhap && <div className="text-[10px] font-semibold text-red-600">sửa sau nháp</div>}{(v.out_invoice_lines || []).some((l: any) => l.out_items?.dg_nhap && Number(l.don_gia) < Number(l.out_items.dg_nhap)) && <div className="text-[10px] font-semibold text-red-600">⚠ dưới giá nhập</div>}</Td>
          <Td className="whitespace-nowrap text-xs">{a.personName(v.sale_id)}</Td><Td className="max-w-[260px] text-xs"><div className="line-clamp-2">{v.buyer_name}</div></Td><Td className="text-xs">{v.tax_code}</Td>
          <Td className="text-right">{(v.out_invoice_lines || []).length}</Td><Td className="text-right"><Money v={t.tt} /></Td><Td className="text-right text-xs"><Money v={t.thue} /></Td>
          <Td><OBadge s={v.status} /></Td><Td className="whitespace-nowrap text-xs">{v.so_hd}<div className="text-ink-400">{v.ngay_hd ? fmtDate(v.ngay_hd) : ''}</div></Td>
          <Td className="whitespace-nowrap text-xs text-ink-500">{fmtDateTime(v.status_at)}</Td></tr>; })}</Table></div>}
      <Pager p={pg} total={rows.length} /></Card>
    {sel && <InvoiceDetail id={sel} acc={acc} onClose={() => setSel(null)} onChanged={reload} />}
  </>;
}

function InvoiceDetail({ id, acc, onClose, onChanged }: { id: string; acc: boolean; onClose: () => void; onChanged: () => void }) {
  const a = useApp(); const { busy, run } = useAction(); const [edit, setEdit] = useState(false); const [msg, setMsg] = useState('');
  const { data: v, reload } = useLoad(() => db.from<any>('out_invoices').select(INV_SEL).eq('id', id).maybeSingle(), [id]);
  const { data: ev, reload: rev } = useLoad(() => db.from<any[]>('out_events').select('*').eq('invoice_id', id).order('at'), [id]);
  const done = () => { reload(); rev(); onChanged(); };
  const go = (status: string, title: string, needNote = false, extra?: () => Promise<any>) => run(async () => {
    const note = needNote ? await ask({ title, input: { label: 'Nội dung', required: true } }) : (await ask({ title, ok: 'Đồng ý' })) ? '' : null;
    if (note === null) return; const x = extra ? await extra() : {}; if (x === null) return;
    await db.rpc('out_invoice_status', { p_ids: [id], p_status: status, p_note: note || null, ...x }); done();
  }, 'Đã cập nhật');
  const sign = () => run(async () => { const so = await ask({ title: 'Xác nhận đã ký HĐ', message: 'Đã ký trên phần mềm và gửi mail cho khách. Sale được báo để nhắc khách kiểm tra email.', input: { label: 'Số HĐ đã ký', required: true }, ok: 'Đã ký' });
    if (so === null) return; await db.rpc('out_invoice_status', { p_ids: [id], p_status: 'da_ky', p_so_hd: so, p_ngay: today() }); done(); }, 'Đã xác nhận ký');
  if (!v) return <Modal open onClose={onClose} title="Phiếu xuất HĐ"><Loading /></Modal>;
  const mine = a.me.id === v.sale_id || a.isLead; const t = totalOf(v); const lines = (v.out_invoice_lines || []).slice().sort((x: any, y: any) => x.stt - y.stt);
  const preview = () => { if (!printDraft({ co: a.settings.company, buyer: { name: v.buyer_name || v.buyer_info || '', mst: v.tax_code, addr: v.address, email: v.email }, sale: a.personName(v.sale_id), code: v.code,
    lines: lines.map((l: any) => ({ ten: l.out_items?.ten, dvt: l.out_items?.dvt, sl: Number(l.sl), gia: Number(l.don_gia), vat: l.vat ?? l.out_items?.vat })) })) toast.err('Trình duyệt chặn cửa sổ mới — cho phép popup'); };
  const s = v.status; const canEdit = !['da_ky', 'huy'].includes(s) && (acc || (mine && s !== 'xac_nhan_ky'));
  return <Modal open onClose={onClose} size="xl" title={<span>{v.code} · <OBadge s={s} /></span>} footer={<>
    <Button onClick={preview}>🖨 Xem trước / in nháp</Button>
    {canEdit && <Button onClick={() => setEdit(true)}>✎ Sửa</Button>}
    {!acc && mine && s === 'soan' && <Button variant="primary" loading={busy} onClick={() => go('cho_nhap', 'Gửi kế toán xuất nháp?')}>Gửi kế toán</Button>}
    {!acc && mine && s === 'da_nhap' && <><Button loading={busy} onClick={() => go('cho_nhap', 'Yêu cầu kế toán sửa nháp', true)}>Yêu cầu sửa</Button>
      <Button variant="success" loading={busy} onClick={() => go('xac_nhan_ky', 'Khách đã OK bản nháp — xác nhận ký?')}>✓ Xác nhận ký</Button></>}
    {acc && s === 'cho_nhap' && <Button variant="primary" loading={busy} onClick={() => go('da_nhap', 'Đánh dấu đã xuất nháp (đã tạo nháp trên phần mềm)?')}>Đã xuất nháp</Button>}
    {acc && ['xac_nhan_ky', 'da_nhap'].includes(s) && <Button variant="success" loading={busy} onClick={sign}>✓ Đã ký</Button>}
    {acc && ['cho_nhap', 'da_nhap', 'xac_nhan_ky'].includes(s) && <Button loading={busy} onClick={() => go('soan', 'Trả lại sale', true)}>Trả lại sale</Button>}
    {s !== 'da_ky' && s !== 'huy' && (acc || (mine && ['soan', 'cho_nhap'].includes(s))) && <Button variant="danger" loading={busy} onClick={() => go('huy', 'Hủy phiếu (trả lại tồn cho dòng hàng)?', acc && !mine)}>Hủy</Button>}
  </>}>
    {s === 'da_ky' && <div className="mb-3 rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-900">Đã ký HĐ số <b>{v.so_hd}</b> ngày {fmtDate(v.ngay_hd)} — kế toán đã gửi mail. Sale báo khách kiểm tra email.</div>}
    {s === 'da_nhap' && !acc && <div className="mb-3 rounded-lg bg-blue-50 px-3 py-2 text-sm text-blue-900">Kế toán đã tạo nháp. Bấm <b>Xem trước / in nháp</b> → lưu PDF gửi khách. Khách OK → <b>Xác nhận ký</b>; sai → <b>Sửa</b> hoặc <b>Yêu cầu sửa</b>.</div>}
    <div className="grid gap-x-6 sm:grid-cols-2 text-sm">
      <div><div className="text-xs font-bold uppercase text-ink-400">Đơn vị mua</div><div className="font-semibold">{v.buyer_name}</div><div>MST: {v.tax_code || '—'}</div><div>Địa chỉ: {v.address || '—'}</div><div>Email: {v.email || '—'}</div><div>Thanh toán: {v.payment}</div>
        {v.buyer_info && <pre className="mt-1 whitespace-pre-wrap rounded bg-ink-50 p-2 text-xs">{v.buyer_info}</pre>}</div>
      <div><div className="text-xs font-bold uppercase text-ink-400">Phiếu</div><div>Sale: {a.personName(v.sale_id)}</div><div>Lập lúc {fmtDateTime(v.created_at)}</div>{v.note && <div>Ghi chú: {v.note}</div>}
        <div className="mt-1">Tiền hàng <b><Money v={t.tt} /></b> · Thuế <b><Money v={t.thue} /></b> · Tổng <b><Money v={t.tt + t.thue} /></b></div></div></div>
    <div className="mt-3 max-h-[35vh] overflow-auto"><Table head={['STT', 'Mã hàng', 'Tên hàng', 'ĐVT', 'SL', 'Đơn giá', 'Giá nhập', 'VAT', 'Thành tiền']}>{lines.map((l: any) =>
      <tr key={l.id}><Td>{l.stt}</Td><Td className="whitespace-nowrap text-xs">{l.out_items?.ma_hang}<div className="text-ink-400">{l.out_items?.md}</div></Td><Td className="min-w-[220px] text-xs">{l.out_items?.ten}</Td><Td className="text-xs">{l.out_items?.dvt}</Td>
        <Td className="text-right">{num(l.sl, 2)}</Td><Td className={cx('text-right', l.out_items?.dg_nhap && Number(l.don_gia) < Number(l.out_items.dg_nhap) && 'font-semibold text-red-600')}><Money v={l.don_gia} /></Td>
        <Td className="text-right text-xs text-ink-500"><Money v={l.out_items?.dg_nhap} /></Td><Td className="text-xs">{vatTxt(l.vat ?? l.out_items?.vat)}</Td><Td className="text-right"><Money v={Math.round(l.sl * l.don_gia)} /></Td></tr>)}</Table></div>
    <div className="mt-4"><div className="mb-1 text-xs font-bold uppercase text-ink-400">Trao đổi · nhật ký</div>
      <div className="max-h-48 space-y-1 overflow-auto">{(ev || []).map(e => <div key={e.id} className={cx('rounded-lg px-3 py-1.5 text-sm', e.action === 'comment' ? 'bg-brand-50' : 'bg-ink-50 text-xs text-ink-600')}>
        <b>{a.personName(e.actor)}</b> · <span className="text-xs text-ink-500">{fmtDateTime(e.at)}</span> · {e.action === 'comment' ? '' : e.action === 'status' ? `${OST[e.data?.from]?.[0] || e.data?.from} → ${OST[e.data?.to]?.[0] || e.data?.to}` : e.action === 'create' ? 'lập phiếu' : 'sửa phiếu'}{e.note ? <> — {e.note}</> : ''}</div>)}</div>
      {s !== 'huy' && <div className="mt-2 flex gap-2"><Textarea rows={1} className="flex-1" value={msg} onChange={e => setMsg(e.target.value)} placeholder={acc ? 'Nhắn sale…' : 'Nhắn kế toán…'} />
        <Button loading={busy} disabled={!msg.trim()} onClick={() => run(async () => { await db.rpc('out_comment', { p_invoice: id, p_note: msg }); setMsg(''); rev(); })}>Gửi</Button></div>}</div>
    {edit && <InvoiceEditor inv={v} onClose={() => setEdit(false)} onDone={() => { setEdit(false); done(); }} />}
  </Modal>;
}
