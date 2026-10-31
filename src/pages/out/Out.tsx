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
import { MISA_HEADER_ROW, misaMap, misaRows, parseBuyers, parseInfo, parseOrders, parseSoXuat, soRows } from '../../lib/xuathd';
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
const INV_SEL = '*,out_invoice_lines(id,item_id,stt,sl,don_gia,vat,out_items(id,ma_hang,part,ten,dvt,vat,sl_nhap,dg_nhap,gia_khach,so_hd_vao,md))';
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
const ITEM_COLS = 'id,ma_hang,part,stt_so,ten,dvt,vat,sl_nhap,dg_nhap,so_hd_vao,ky_hieu,ngay_vao,md,nvkd,username,sale_id,customer_id,gia_khach,match_src,legacy,sl_xuat,ton,phieu,khach,xe';
const LEG: Record<string, string> = { da_ky: 'đã ký', da_nhap: 'đã xuất nháp', xac_nhan_ky: 'KD xác nhận ký' };
const maHang = (t: any) => t.ma_hang + (t.part > 1 ? ` (${t.part})` : '');
function useDebounced<T>(v: T, ms = 350): T { const [d, setD] = useState(v); React.useEffect(() => { const t = setTimeout(() => setD(v), ms); return () => clearTimeout(t); }, [v]); return d; }
function Items({ acc = false, free = false }: { acc?: boolean; free?: boolean }) {
  const a = useApp(); const { busy, run } = useAction(); const mode = acc ? 'acc' : free ? 'free' : 'mine';
  const [q, setQ] = useState(''); const qd = useDebounced(q); const [f, setF] = useState(acc ? 'ton' : ''); const [hd, setHd] = useState(''); const [xe, setXe] = useState(''); const [sale, setSale] = useState(''); const [kh, setKh] = useState('');
  const pg = usePager(acc ? 'out_items' : free ? 'out_free' : 'out_mine', [qd, f, hd, xe, sale, kh]);
  const { data, loading, reload: reloadRows } = useLoad(() => db.rpc<any>('out_items_page', { p: { mode, f, q: qd, hd, xe, sale, kh, offset: pg.from, limit: pg.size } }), [mode, f, qd, hd, xe, sale, kh, pg.from, pg.size]);
  const { data: saleOpts } = useLoad(() => acc || (a.isLead && !free) ? db.rpc<any[]>('out_sale_opts') : Promise.resolve([]), [acc, free]);
  const { data: st, reload: reloadSt } = useLoad(() => db.rpc<any>('out_items_stats', { p_mode: mode }), [mode]);
  const { data: ic } = useLoad(async () => {
    if (acc || free) return null;
    const r = await db.rpc<any>('out_invoices_page', { p: { limit: 0 } }); const m = new Date(); const from = `${m.getFullYear()}-${String(m.getMonth() + 1).padStart(2, '0')}-01`;
    const k = await db.from<any>('out_invoices').select('id', { count: true }).eq('status', 'da_ky').gte('status_at', from).limit(1) as any;
    return { ...(r?.counts || {}), ky_thang: k?.count ?? 0 };
  }, [acc, free]);
  const reload = () => { reloadRows(); reloadSt(); };
  const rows: any[] = data?.rows || []; const total: number = data?.total || 0; const S = st || {};
  const [pick, setPick] = useState<Record<string, any>>({}); const [edit, setEdit] = useState<any>(null); const [newInv, setNewInv] = useState<any[] | null>(null); const [up, setUp] = useState(false);
  const [claimT, setClaimT] = useState<any>(null); const [xeOpen, setXeOpen] = useState(false);
  const hds = ((S.hd || []) as string[]).sort((x, y) => Number(y) - Number(x)); const xes = (S.xe || []) as string[]; const sales = (S.sale || []) as string[];
  const chosen = Object.values(pick);
  const togglePick = (t: any, on: boolean) => setPick(p => { const x = { ...p }; if (on) x[t.id] = t; else delete x[t.id]; return x; });
  const exportSo = () => run(async () => {
    const all = await fetchAll<any>(() => db.from('out_items_v').select(ITEM_COLS).order('stt_so', { asc: false, nulls: 'last' }), 50000);
    const ls = await fetchAll<any>(() => db.from('out_invoice_lines').select('item_id,sl,don_gia,vat,out_invoices(code,status,buyer_name,tax_code,address,email,buyer_info,so_hd,ngay_hd)'));
    await writeXlsx('So_xuat_HD_' + today(), soRows(all, ls, id => a.personName(id)), 'NEW');
  });
  const rematch = () => run(async () => { const n = await db.rpc<number>('out_rematch'); reload(); toast.ok(`Đã gắn lại ${n} dòng còn thiếu sale / khách / giá`); });
  const ActBtn = ({ t }: { t: any }) => free ? <Button size="sm" variant="primary" onClick={() => setClaimT(t)}>Nhận</Button> : acc ? <Button size="sm" onClick={() => setEdit(t)}>Sửa</Button> : null;
  const khachTxt = (t: any) => t.khach || t.username || '';
  const canPick = (t: any) => t.ton > 0.0001 && (acc || !!t.sale_id);
  const icN = (k: string) => Number(ic?.[k] || 0);
  return <>
    {acc && <div className="mb-3 flex flex-wrap items-center gap-2"><Button variant="primary" onClick={() => setUp(true)}>⇪ Nạp sổ Excel · đơn hàng · đơn vị nhận HĐ</Button>
      <Button onClick={() => setXeOpen(true)}>🚚 HĐ vào ↔ xe</Button>
      <Button loading={busy} onClick={rematch}>↻ Gắn lại sale/khách/giá</Button>
      <Button loading={busy} onClick={exportSo}>⬇ Xuất sổ (đúng mẫu)</Button></div>}
    {acc && <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-6">
      <Stat label="Còn tồn chưa xuất" value={S.ton ?? '…'} tone={S.ton ? 'amber' : undefined} onClick={() => setF('ton')} sub={`/ ${S.all ?? '…'} dòng trong sổ`} />
      <Stat label="Chưa gắn sale (còn tồn)" value={S.nosale ?? '…'} tone={S.nosale ? 'red' : undefined} onClick={() => setF('nosale')} />
      <Stat label="Còn tồn, chưa có giá xuất" value={S.nogia ?? '…'} onClick={() => setF('nogia')} />
      <Stat label="Chưa có ID đơn" value={S.nomd ?? '…'} onClick={() => setF('nomd')} />
      <Stat label="Đã xuất hết" value={S.het ?? '…'} onClick={() => setF('het')} />
      <Stat label="Đã ký không sale" value={S.daky_nosale ?? '…'} sub="sổ cũ, tồn 0 — để riêng" onClick={() => setF('daky_nosale')} /></div>}
    {!acc && !free && <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-5">
      <Stat label="Dòng chờ xuất HĐ" value={S.ton ?? '…'} tone={S.ton ? 'amber' : undefined} />
      <Stat label="Giá trị còn tồn" value={S.gia_tri !== undefined ? money(S.gia_tri) : '…'} sub="theo giá xuất khách" />
      <Stat label="Phiếu chờ kế toán xuất nháp" value={icN('cho_nhap') + icN('soan')} sub={icN('soan') ? `${icN('soan')} phiếu đang soạn` : ''} />
      <Stat label="Nháp chờ bạn xác nhận ký" value={icN('da_nhap')} tone={icN('da_nhap') ? 'red' : undefined} />
      <Stat label="Đã ký tháng này" value={icN('ky_thang')} tone="green" /></div>}
    {free && <p className="mb-3 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">Dòng trên HĐ chính thức còn tồn mà chưa xác định được sale (dòng đã ký không hiện ở đây). Hàng của bạn thì bấm <b>Nhận</b>, nhập mã đơn.</p>}
    {!acc && !free && <p className="mb-3 text-sm text-ink-600">Tick các dòng cùng 1 đơn vị nhận HĐ → <b>Lập phiếu xuất HĐ</b>: xác nhận giá + thông tin xuất HĐ. Dòng đã ký nằm ở “Phiếu của tôi → Đã ký”.</p>}
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Input className="max-w-xs" placeholder="🔎 Mã hàng, tên, ID đơn, khách, sale, số HĐ, xe…" value={q} onChange={e => setQ(e.target.value)} />
      <Select className="w-40" placeholder="Tất cả xe" options={xes.map(x => [x, x === '—' ? '— Chưa gán xe' : x] as [string, string])} value={xe} onChange={setXe} />
      <Select className="w-40" placeholder="Tất cả HĐ vào" options={hds.map(h => [h, 'HĐ ' + h] as [string, string])} value={hd} onChange={setHd} />
      {acc && <Select className="w-44" placeholder="Tất cả sale" options={sales.map(x => [x, x === '—' ? '— Chưa có sale' : a.personName(x)] as [string, string])} value={sale} onChange={setSale} />}
      {!acc && !free && a.isLead && (saleOpts || []).length > 1 && <Select className="w-44" placeholder="Tất cả sale" options={(saleOpts || []).map((x: any) => [x.id, x.full_name] as [string, string])} value={sale} onChange={setSale} />}
      {!acc && <Select className="w-52" placeholder="Tất cả khách" options={((S.kh || []) as [string, string][]).map(([k, t]) => [k, t] as [string, string])} value={kh} onChange={setKh} />}
      {!acc && !free && <Select className="w-48" placeholder="Tất cả dòng còn tồn" options={[['nokhach', `Chưa gắn khách (${S.nokhach ?? 0})`], ['nomd', `Chưa gắn đơn (${S.nomd ?? 0})`], ['nogia', `Chưa có giá xuất (${S.nogia ?? 0})`]] as [string, string][]} value={f} onChange={setF} />}
      {acc && <Select className="w-48" placeholder="Tất cả dòng" options={[['ton', 'Còn tồn'], ['het', 'Đã xuất hết'], ['nosale', 'Chưa gắn sale'], ['nomd', 'Chưa có ID đơn'], ['nogia', 'Chưa có giá xuất'], ['daky_nosale', 'Đã ký không sale']] as [string, string][]} value={f} onChange={setF} />}
      {!free && chosen.length > 0 && <Button className="hidden sm:inline-flex" variant="primary" onClick={() => setNewInv(chosen)}>Lập phiếu xuất HĐ ({chosen.length} dòng)</Button>}
      {!free && chosen.length > 0 && <button className="hidden text-xs text-ink-500 underline sm:inline" onClick={() => setPick({})}>Bỏ chọn</button>}
    </div>
    {rows.length > 0 && <div className="mb-3 space-y-2 sm:hidden">{rows.map((t: any) =>
      <div key={t.id} className={cx('rounded-2xl border bg-white p-3 shadow-soft', pick[t.id] ? 'border-brand-500 bg-brand-50/60' : 'border-ink-200')}>
        <div className="flex items-start gap-2">{!free && <input type="checkbox" className="mt-1 h-5 w-5" disabled={!canPick(t)} checked={!!pick[t.id]} onChange={e => togglePick(t, e.target.checked)} />}
          <div className="min-w-0 flex-1"><div className="text-[11px] text-ink-500">{maHang(t)} · {t.xe ? t.xe + ' · ' : ''}HĐ {t.so_hd_vao}{t.md ? ' · ' + t.md : ''}{acc ? ' · ' + (a.personName(t.sale_id) || t.nvkd || 'chưa có sale') : ''}</div>
            <div className="line-clamp-3 text-sm font-medium text-ink-900">{t.ten}</div>
            {khachTxt(t) && <div className="text-xs text-ink-600">Khách: {khachTxt(t)}</div>}
            <div className="mt-1 flex flex-wrap gap-x-3 text-xs"><span>SL {num(t.sl_nhap, 2)} {t.dvt}</span><span>Giá nhập <Money v={t.dg_nhap} /></span>{t.gia_khach && <span>Giá xuất <b><Money v={t.gia_khach} /></b></span>}
              <span className={t.ton > 0.0001 ? 'font-semibold text-amber-700' : 'text-ink-400'}>Tồn {num(t.ton, 2)}</span></div>
            {(t.phieu || t.legacy?.status) && <div className="mt-1 text-[11px] text-ink-500">{t.phieu ? t.phieu.split(',').map((p: string) => { const [c, sx] = p.split(':'); return `${c} · ${OST[sx]?.[0] || sx}`; }).join(' | ') : 'Sổ cũ: ' + (LEG[t.legacy.status] || t.legacy.status)}</div>}</div>
          <ActBtn t={t} /></div></div>)}
      <Pager p={pg} total={total} /></div>}
    {!free && chosen.length > 0 && <div className="fixed inset-x-3 bottom-3 z-30 sm:hidden"><Button className="w-full" variant="primary" onClick={() => setNewInv(chosen)}>Lập phiếu xuất HĐ ({chosen.length} dòng)</Button></div>}
    <Card className={rows.length ? 'hidden sm:block' : ''} bodyClass="p-0">{loading && !rows.length ? <Loading /> : !rows.length ? <Empty>{free ? 'Không có dòng chưa có sale' : 'Không có dòng'}</Empty> :
      <Table scroll className={loading ? 'opacity-60' : ''} head={[...(free ? [] : ['']), 'Mã hàng', 'Tên hàng', 'SL nhập', 'Đơn giá nhập', 'VAT', 'Xe · HĐ vào', 'ID đơn', 'Khách', ...(acc ? ['Sale'] : []), 'Giá xuất', 'Còn tồn', 'Phiếu', '']}>{rows.map((t: any) =>
        <tr key={t.id} className={cx('align-top', pick[t.id] && 'bg-brand-50/60')}>
          {!free && <Td><input type="checkbox" disabled={!canPick(t)} checked={!!pick[t.id]} onChange={e => togglePick(t, e.target.checked)} /></Td>}
          <Td className="whitespace-nowrap text-xs font-semibold">{maHang(t)}</Td><Td className="min-w-[300px] max-w-[440px] text-xs"><div className="line-clamp-3" title={t.ten}>{t.ten}</div></Td>
          <Td className="whitespace-nowrap text-right">{num(t.sl_nhap, 2)} <span className="text-[11px] text-ink-400">{t.dvt}</span></Td><Td className="text-right"><Money v={t.dg_nhap} /></Td><Td className="text-right text-xs">{vatTxt(t.vat)}</Td>
          <Td className="whitespace-nowrap text-xs">{t.xe ? <b className="text-ink-800">{t.xe}</b> : <span className="text-ink-400">—</span>}<div className="text-ink-500">HĐ {t.so_hd_vao} · {fmtDate(t.ngay_vao)}</div></Td>
          <Td className="whitespace-nowrap text-xs">{t.md || <span className="text-amber-700">—</span>}{t.match_src === 'hd_xml' && <div className="text-[10px] text-emerald-700">theo HĐ XML</div>}</Td>
          <Td className="max-w-[200px] text-xs">{t.khach ? <><div className="line-clamp-2 font-medium text-ink-800">{t.khach}</div><div className="text-ink-400">{t.username}</div></> : t.username ? <span className="text-amber-700" title="Username chưa có trong danh sách khách ERP">{t.username}</span> : <span className="text-ink-300">—</span>}</Td>
          {acc && <Td className="whitespace-nowrap text-xs">{a.personName(t.sale_id) || <span className="text-red-600">{t.nvkd || 'chưa có sale'}</span>}</Td>}
          <Td className="text-right"><Money v={t.gia_khach} /></Td>
          <Td className={cx('whitespace-nowrap text-right font-semibold', t.ton > 0.0001 ? 'text-amber-700' : 'text-ink-400')}>{num(t.ton, 2)}</Td>
          <Td className="min-w-[150px] text-[11px] text-ink-500">{(t.phieu || '').split(',').filter(Boolean).map((p: string) => { const [c, sx] = p.split(':'); return <div key={p}>{c} · {OST[sx]?.[0]}</div>; })}{!t.phieu && t.legacy?.status ? <div>Sổ cũ: {LEG[t.legacy.status] || t.legacy.status}</div> : ''}</Td>
          <Td><ActBtn t={t} /></Td></tr>)}</Table>}
      <Pager p={pg} total={total} /></Card>
    {up && <ImportSo onClose={() => setUp(false)} onDone={() => { setUp(false); reload(); }} />}
    {xeOpen && <HdXe hds={hds} onClose={() => setXeOpen(false)} onDone={() => { setXeOpen(false); reload(); }} />}
    {edit && <ItemEdit t={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); reload(); }} />}
    {claimT && <ClaimItem t={claimT} onClose={() => setClaimT(null)} onDone={() => { setClaimT(null); reload(); }} />}
    {newInv && <InvoiceEditor items={newInv} onClose={() => setNewInv(null)} onDone={() => { setNewInv(null); setPick({}); reload(); }} />}
  </>;
}

/** Kế toán gán HĐ vào ↔ xe (tự gắn theo XML; sửa tay ở đây, nạp 1 lần dùng mãi) */
function HdXe({ hds, onClose, onDone }: { hds: string[]; onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction(); const { data } = useLoad(() => db.from<any[]>('out_hd_xe').select('*'), []);
  const cur = useMemo(() => { const m: Record<string, any> = {}; (data || []).forEach(x => { m[x.so_hd] = x; }); return m; }, [data]);
  const [v, setV] = useState<Record<string, string>>({}); const [bulk, setBulk] = useState(''); const [q, setQ] = useState('');
  const list = hds.map(h => String(h).replace(/^0+/, '')).sort((x, y) => Number(y) - Number(x)).filter(h => !q || h.includes(q) || (v[h] ?? cur[h]?.xe ?? '').toLowerCase().includes(q.toLowerCase()));
  const save = () => run(async () => {
    const rows = Object.entries(v).map(([so_hd, xe]) => ({ so_hd, xe }));
    bulk.split('\n').forEach(l => { const m = l.trim().match(/^0*(\d+)[\s,;:\t]+(.+)$/); if (m) rows.push({ so_hd: m[1], xe: m[2].trim() }); });
    if (!rows.length) throw new Error('Chưa có thay đổi'); await db.rpc('out_hd_xe_set', { p_rows: rows }); onDone();
  }, 'Đã lưu HĐ vào ↔ xe');
  return <Modal open onClose={onClose} size="lg" title="HĐ vào ↔ xe" footer={<Button variant="primary" loading={busy} onClick={save}>Lưu</Button>}>
    <p className="mb-2 text-xs text-ink-500">HĐ đã nạp XML và ghép được với xe đối soát thì hệ thống tự điền (chữ xám). Gõ tên xe cho HĐ còn trống — lưu 1 lần, các lần nạp sổ sau tự hiện cột Xe.</p>
    <div className="grid gap-3 sm:grid-cols-[1fr_260px]">
      <div><Input placeholder="🔎 Số HĐ hoặc tên xe" value={q} onChange={e => setQ(e.target.value)} />
        <div className="mt-2 max-h-[50vh] overflow-auto rounded-xl border border-ink-200">{list.map(h => <div key={h} className="flex items-center gap-2 border-b border-ink-100 px-3 py-1.5 text-sm">
          <span className="w-20 font-semibold">HĐ {h}</span>
          <Input className={cx('flex-1', cur[h]?.tu_dong && v[h] === undefined && 'text-ink-500')} placeholder="VD: Xe 25/10" value={v[h] ?? cur[h]?.xe ?? ''} onChange={e => setV(x => ({ ...x, [h]: e.target.value }))} /></div>)}</div></div>
      <div><Field label="Dán nhanh nhiều dòng" hint="Mỗi dòng: số HĐ + tên xe. VD: 2078 Xe 25/10"><Textarea rows={8} value={bulk} onChange={e => setBulk(e.target.value)} placeholder={'2076 Xe 25/10\n2077 Xe 25/10\n2078 Xe 25/10'} /></Field>
        <RenameXe xes={Array.from(new Set((data || []).map((x: any) => x.xe)))} onDone={onDone} /></div></div>
  </Modal>;
}

function RenameXe({ xes, onDone }: { xes: string[]; onDone: () => void }) {
  const { busy, run } = useAction(); const [o, setO] = useState(''); const [n, setN] = useState('');
  return <div className="mt-3 rounded-xl border border-ink-200 p-3"><div className="mb-1 text-xs font-semibold">Đổi tên xe (sửa cho mọi HĐ của xe đó)</div>
    <Select placeholder="Chọn xe" options={xes.map(x => [x, x] as [string, string])} value={o} onChange={v => { setO(v); setN(v); }} />
    <Input className="mt-2" placeholder="Tên mới" value={n} onChange={e => setN(e.target.value)} />
    <Button className="mt-2" size="sm" loading={busy} disabled={!o || !n.trim() || n.trim() === o} onClick={() => run(async () => { await db.rpc('out_xe_rename', { p_old: o, p_new: n }); onDone(); }, 'Đã đổi tên xe')}>Đổi tên</Button></div>;
}

/** Sale nhận dòng chưa có sale: nhập mã đơn → hệ thống tra username, giá xuất khách; không có thì sale nhập */
function ClaimItem({ t, onClose, onDone }: { t: any; onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction(); const [md, setMd] = useState(t.md || ''); const [user, setUser] = useState(t.username || ''); const [gia, setGia] = useState(t.gia_khach ? String(Math.round(t.gia_khach)) : '');
  const [info, setInfo] = useState<any>(null);
  const look = async () => { if (!md.trim()) return; try { const r = await db.rpc<any>('out_md_lookup', { p_md: md }); setInfo(r || {});
    if (r?.username && !user) setUser(r.username); if (r?.gia_khach && !gia) setGia(String(Math.round(r.gia_khach))); } catch { setInfo({}); } };
  React.useEffect(() => { if (t.md) look(); }, []);
  return <Modal open onClose={onClose} title="Nhận dòng hàng" footer={<Button variant="primary" loading={busy} disabled={!md.trim() || !user.trim() || !Number(gia)} onClick={() => run(async () => {
    const n = await db.rpc<number>('out_item_claim', { p_id: t.id, p_md: md, p_username: user, p_gia: Number(gia) }); toast.ok(n > 1 ? `Đã nhận ${n} dòng cùng mã đơn` : 'Đã nhận dòng'); onDone(); })}>Nhận dòng</Button>}>
    <div className="mb-3 text-sm"><b>{maHang(t)}</b> · HĐ {t.so_hd_vao}{t.xe ? ' · ' + t.xe : ''}<div className="text-xs text-ink-600">{t.ten}</div><div className="text-xs">SL {num(t.sl_nhap, 2)} {t.dvt} · giá nhập <Money v={t.dg_nhap} /></div></div>
    <Field label="Mã đơn (MD) *" hint="Gõ 2943 hay MD2943 đều được"><div className="flex gap-2"><Input value={md} onChange={e => { setMd(e.target.value.toUpperCase()); setInfo(null); }} onBlur={look} /><Button onClick={look}>Tra</Button></div></Field>
    {info && <div className={cx('mt-2 rounded-lg px-3 py-2 text-xs', info.username || info.gia_khach ? 'bg-emerald-50 text-emerald-900' : 'bg-amber-50 text-amber-900')}>
      {info.username || info.gia_khach ? <>Hệ thống tìm thấy: {info.username ? <>khách <b>{info.khach || info.username}</b> ({info.username})</> : 'chưa có khách'}{info.gia_khach ? <> · giá xuất khách <b>{money(info.gia_khach)}</b></> : ' · chưa có giá xuất'}</> : 'Chưa có dữ liệu mã đơn này — nhập username khách và giá xuất khách.'}</div>}
    <div className="mt-2 grid grid-cols-2 gap-2"><Field label="Username khách *"><Input value={user} onChange={e => setUser(e.target.value)} /></Field>
      <Field label="Giá xuất khách (đ/đv) *" hint={gia ? money(Number(gia)) + ' đ' : ''}><Input inputMode="numeric" value={gia} onChange={e => setGia(e.target.value.replace(/[^\d]/g, ''))} /></Field></div>
    <div className="mt-2 text-xs text-ink-500">Các dòng khác chưa có sale cùng mã đơn sẽ được nhận luôn.</div>
  </Modal>;
}

function ImportSo({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction(); const [file, setFile] = useState<File | null>(null); const [ord, setOrd] = useState<File | null>(null); const [buy, setBuy] = useState<File | null>(null);
  const [res, setRes] = useState<any>(null); const [err, setErr] = useState(''); const [step, setStep] = useState('');
  const analyze = async () => { setErr(''); setRes(null);
    try { if (!file && !ord && !buy) throw new Error('Chọn ít nhất 1 file');
      const p = file ? parseSoXuat(await readTable(file, { fillMerged: true })) : { rows: [], legacy: [], warnings: [] };
      const orders = ord ? parseOrders(await readTable(ord)) : []; const buyers = buy ? parseBuyers(await readXlsx(buy)) : [];
      setRes({ ...p, orders, buyers }); } catch (e: any) { setErr(e.message || String(e)); } };
  const save = () => run(async () => {
    const rows = res.rows.map((r: any) => ({ ...r, row: undefined })); const msg: string[] = [];
    if (rows.length) { let nn = 0, nu = 0;
      for (let i = 0; i < rows.length; i += 150) { setStep(`Đang nạp sổ ${Math.min(i + 150, rows.length)}/${rows.length}…`); const x = await db.rpc<any>('out_items_import', { p_rows: rows.slice(i, i + 150) }); nn += x.new; nu += x.upd; }
      msg.push(`${nn} dòng mới, ${nu} dòng cập nhật`);
      const leg = res.legacy; let nl = 0;
      for (let i = 0; i < leg.length; i += 40) { setStep(`Đang chuyển dòng đã ký / đã xuất nháp ${Math.min(i + 40, leg.length)}/${leg.length}…`); nl += await db.rpc<number>('out_legacy_import', { p_legacy: leg.slice(i, i + 40) }); }
      if (nl) msg.push(`${nl} phiếu từ sổ cũ (đã ký / đã xuất nháp)`); }
    if (res.orders.length) { let n = 0; for (let i = 0; i < res.orders.length; i += 500) { setStep(`Đang nạp đơn hàng ${Math.min(i + 500, res.orders.length)}/${res.orders.length}…`); n += await db.rpc<number>('out_orders_import', { p_rows: res.orders.slice(i, i + 500) }); } msg.push(`${res.orders.length} mã đơn (${n} dòng được gắn)`); }
    if (res.buyers.length) { setStep('Đang nạp đơn vị nhận HĐ…'); const n = await db.rpc<number>('out_buyers_import', { p_rows: res.buyers }); msg.push(`${n} đơn vị nhận HĐ`); }
    setStep('Đang gắn lại sale / khách / giá…'); await db.rpc<number>('out_rematch'); setStep('');
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
    {step && <div className="mt-3 rounded-lg bg-brand-50 p-3 text-sm font-semibold text-brand-800">{step}</div>}
    {res && <div className="mt-3 space-y-2 text-sm">
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-5"><Stat label="Dòng hàng" value={res.rows.length} /><Stat label="Có ID đơn" value={res.rows.filter((r: any) => r.md).length} />
        <Stat label="Dòng đã ký trên sổ cũ" value={res.legacy.filter((g: any) => g.status === 'da_ky').reduce((x: number, g: any) => x + g.lines.length, 0)} sub="hết tồn, vào phiếu Đã ký" /><Stat label="Đơn hàng" value={res.orders.length} /><Stat label="Đơn vị nhận HĐ" value={res.buyers.length} /></div>
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
  const [b, setB] = useState<any>(() => { if (inv) return { name: inv.buyer_name || '', mst: inv.tax_code || '', addr: inv.address || '', email: inv.email || '', pay: inv.payment || 'TM/CK', note: inv.note || '' };
    // dòng đã xuất nháp trên sổ cũ: điền sẵn thông tin xuất HĐ sale đã báo
    const lg = (items || []).find(t => t.legacy?.info)?.legacy; const p = lg ? parseInfo(lg.info) : null;
    return { name: p?.buyer_name || '', mst: p?.tax_code || '', addr: p?.address || '', email: p?.email || '', pay: 'TM/CK', note: '' }; });
  const legInfo = !inv ? (items || []).map(t => t.legacy?.info).filter(Boolean)[0] : null;
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
    {legInfo && <details className="mb-3 rounded-lg bg-slate-50 px-3 py-2 text-xs text-ink-700"><summary className="cursor-pointer font-semibold">Thông tin xuất HĐ đã báo trên sổ cũ (đã điền sẵn — kiểm tra lại)</summary><pre className="mt-1 whitespace-pre-wrap font-sans">{legInfo}</pre></details>}
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
      <tr key={l.item_id}><Td className="whitespace-nowrap text-xs">{l.item ? maHang(l.item) : ''}</Td><Td className="min-w-[200px] text-xs">{l.item?.ten}</Td><Td className="text-xs">{l.item?.dvt}</Td>
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
  const [st, setSt] = useState('cho_nhap'); const [q, setQ] = useState(''); const qd = useDebounced(q); const [sale, setSale] = useState(''); const [sel, setSel] = useState<string | null>(null);
  const [pick, setPick] = useState<Record<string, any>>({});
  const pg = usePager('out_inv', [st, qd, sale]);
  const { data, loading, reload } = useLoad(() => db.rpc<any>('out_invoices_page', { p: { status: st, q: qd, sale, offset: pg.from, limit: pg.size } }), [st, qd, sale, pg.from, pg.size]);
  const rows: any[] = data?.rows || []; const total = data?.total || 0; const cnt = data?.counts || {};
  const c = (k: string) => Number(cnt[k] || 0); const allN = Object.entries(cnt).filter(([k]) => k !== 'huy').reduce((x, [, v]) => x + Number(v), 0);
  const chosen = Object.values(pick);
  const { data: sales } = useLoad(() => acc || a.isLead ? db.rpc<any[]>('out_sale_opts') : Promise.resolve([]), [acc]);
  const saleOpts = (sales || []).map((x: any) => x.id) as string[];
  const exportMisa = () => run(async () => {
    const ids = chosen.length ? chosen.map((v: any) => v.id) : null;
    let qq = db.from<any[]>('out_invoices').select(INV_SEL).order('status_at');
    qq = ids ? qq.in('id', ids) : qq.eq('status', 'cho_nhap');
    const list = await qq; if (!list.length) throw new Error('Không có phiếu chờ xuất nháp');
    await writeXlsx('HD_nhap_MISA_' + today(), misaRows(list), 'Hóa đơn GTGT', true, { headerRow: MISA_HEADER_ROW, fmt: { 11: 'int', 12: 'int', 13: 'int', 14: 'pct', 15: 'int' } });
    await writeXlsx('HD_nhap_doi_chieu_phieu_' + today(), misaMap(list, id => a.personName(id)), 'Đối chiếu');
    const cho = list.filter((v: any) => v.status === 'cho_nhap').map((v: any) => v.id);
    if (cho.length && await ask({ title: `Đánh dấu ${cho.length} phiếu “Đã xuất nháp”?`, message: 'Bấm sau khi đã nạp file lên phần mềm và tạo nháp xong. Sale được báo để kiểm tra, gửi khách, xác nhận ký.', ok: 'Đã xuất nháp' })) {
      await db.rpc('out_invoice_status', { p_ids: cho, p_status: 'da_nhap' }); setPick({}); reload(); toast.ok('Đã báo sale'); }
  });
  const stItems: [string, string, number, string][] = [['cho_nhap', OST.cho_nhap[0], c('cho_nhap'), 'amber'], ['da_nhap', OST.da_nhap[0], c('da_nhap'), 'blue'], ['xac_nhan_ky', OST.xac_nhan_ky[0], c('xac_nhan_ky'), 'purple'],
    ['soan', OST.soan[0], c('soan'), 'slate'], ['da_ky', OST.da_ky[0], c('da_ky'), 'green'], ['', 'Tất cả', allN, 'dark'], ['huy', 'Hủy', c('huy'), 'gray']];
  const flags = (v: any) => <>{v.legacy && <div className="text-[10px] font-normal text-ink-400">sổ cũ</div>}{v.sua_sau_nhap && <div className="text-[10px] font-semibold text-red-600">sửa sau nháp</div>}{v.duoi_gia && <div className="text-[10px] font-semibold text-red-600">⚠ dưới giá nhập</div>}</>;
  return <>
    {!acc && <p className="mb-3 text-sm text-ink-600">Quy trình: lập phiếu (giá + thông tin xuất HĐ) → kế toán xuất nháp → bạn <b>in / lưu PDF bản nháp gửi khách</b> → khách OK thì bấm <b>Xác nhận ký</b> → kế toán ký, gửi mail cho khách → bạn báo khách kiểm tra email.</p>}
    <StatusChips value={st} onChange={setSt} items={stItems} />
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Input className="max-w-xs" placeholder="🔎 Mã phiếu, đơn vị mua, MST, mã hàng, MD, số HĐ…" value={q} onChange={e => setQ(e.target.value)} />
      {(acc || a.isLead) && saleOpts.length > 1 && <Select className="w-48" placeholder="Tất cả sale" options={(sales || []).map((x: any) => [x.id, x.full_name] as [string, string])} value={sale} onChange={setSale} />}
      <Button onClick={reload}>↻ Tải lại</Button>
      {acc && <Button variant="primary" loading={busy} onClick={exportMisa}>⬇ Xuất file nháp{chosen.length ? ` (${chosen.length} phiếu)` : ' (tất cả chờ xuất nháp)'}</Button>}
      {acc && chosen.length > 0 && <button className="text-xs text-ink-500 underline" onClick={() => setPick({})}>Bỏ chọn</button>}
    </div>
    {!loading && rows.length > 0 && <div className="mb-3 space-y-2 sm:hidden">{rows.map((v: any) =>
      <button key={v.id} className="block w-full rounded-2xl border border-ink-200 bg-white p-3 text-left shadow-soft" onClick={() => setSel(v.id)}>
        <div className="flex items-center justify-between gap-2"><b>{v.code}</b><OBadge s={v.status} /></div>
        <div className="mt-1 line-clamp-2 text-sm font-medium text-ink-900">{v.buyer_name || v.buyer_info}</div>
        <div className="mt-1 flex flex-wrap gap-x-3 text-xs text-ink-600">{v.tax_code && <span>MST {v.tax_code}</span>}<span>{v.so_dong} dòng</span><span>Tổng <b><Money v={Number(v.tien_hang) + Number(v.tien_thue)} /></b></span>
          {acc && <span>{a.personName(v.sale_id)}</span>}{v.so_hd && <span>HĐ {v.so_hd}</span>}{v.sua_sau_nhap && <span className="font-semibold text-red-600">sửa sau nháp</span>}</div></button>)}
      <Pager p={pg} total={total} /></div>}
    <Card className={rows.length ? 'hidden sm:block' : ''} bodyClass="p-0">{loading && !rows.length ? <Loading /> : !rows.length ? <Empty>Không có phiếu</Empty> :
      <Table scroll className={loading ? 'opacity-60' : ''} head={[...(acc ? [''] : []), 'Phiếu', 'Sale', 'Đơn vị mua', 'MST', 'Dòng', 'Tiền hàng', 'Thuế', 'Trạng thái', 'Số HĐ', 'Cập nhật']}>{rows.map((v: any) =>
        <tr key={v.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setSel(v.id)}>
          {acc && <Td><input type="checkbox" checked={!!pick[v.id]} onClick={e => e.stopPropagation()} onChange={e => setPick(p => { const x = { ...p }; if (e.target.checked) x[v.id] = v; else delete x[v.id]; return x; })} /></Td>}
          <Td className="whitespace-nowrap font-semibold">{v.code}{flags(v)}</Td>
          <Td className="whitespace-nowrap text-xs">{a.personName(v.sale_id)}</Td><Td className="max-w-[260px] text-xs"><div className="line-clamp-2">{v.buyer_name || v.buyer_info}</div></Td><Td className="text-xs">{v.tax_code}</Td>
          <Td className="text-right">{v.so_dong}</Td><Td className="text-right"><Money v={v.tien_hang} /></Td><Td className="text-right text-xs"><Money v={v.tien_thue} /></Td>
          <Td><OBadge s={v.status} /></Td><Td className="whitespace-nowrap text-xs">{v.so_hd}<div className="text-ink-400">{v.ngay_hd ? fmtDate(v.ngay_hd) : ''}</div></Td>
          <Td className="whitespace-nowrap text-xs text-ink-500">{fmtDateTime(v.status_at)}</Td></tr>)}</Table>}
      <Pager p={pg} total={total} /></Card>
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
  const preview = () => { if (!printDraft({ co: a.settings.company, cfg: a.settings.accounting, buyer: { name: v.buyer_name || v.buyer_info || '', mst: v.tax_code, addr: v.address, email: v.email, pay: v.payment }, sale: a.personName(v.sale_id), code: v.code,
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
