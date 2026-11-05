// Xuất HĐ đầu ra: kế toán nạp sổ HĐ chính thức (mã hàng MISA) → sale lập phiếu (giá + đơn vị nhận HĐ) → kế toán xuất nháp → sale xác nhận ký → kế toán ký
import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, Select, Stat, StatusChips, Table, Tabs, Td, Textarea, ask, toast, useAction, useLoad } from '../../components/ui';
import { Pager, usePager } from '../../components/Pager';
import { CustomerPicker } from '../../components/CustomerPicker';
import { db, fetchAll } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { readTable, readXlsx, writeXlsx } from '../../lib/xlsx';
import { fmtDate, fmtDateTime, money, num, stripVN, today } from '../../lib/format';
import { MISA_HEADER_ROW, misaRows, parseBuyers, parseInfo, parseOrders, parseSoXuat, soRows, TPL_BUYERS, TPL_ORDERS, TPL_SO } from '../../lib/xuathd';
import { Money, useAccCfg } from '../acc/common';
import { printDraft } from './print';
import { FileBadge, HdFilesSection, UploadHdPdf, type HdF } from './HdFiles';
import { BulkInvoices, PricePick, VatBadge, srcTxt } from './Bulk';
import { downloadMau } from '../../lib/mau';

export const OST: Record<string, [string, string]> = {
  soan: ['Sale đang soạn', 'slate'], cho_duyet_gia: ['Chờ duyệt giá', 'red'], cho_nhap: ['Đã gửi — chờ export', 'amber'], da_nhap: ['Có nháp — chờ sale duyệt', 'blue'],
  tra_sua: ['Sale trả sửa', 'red'], xac_nhan_ky: ['Đã chốt — chờ ký', 'purple'], da_ky: ['Đã ký', 'green'], huy: ['Hủy', 'gray'],
};
/** Khung biên giá xuất so với giá APT trên HĐ ký (bản 23): < 2% cấm · 2–4% tự do · > 4% chờ duyệt */
export const BIEN_CAM = 0.02, BIEN_DUYET = 0.04;
/** Đơn giá xuất so với giá nhập (APT) và giá khách trên hệ thống */
function giaCheck(gia: number, dgNhap: number | null, gk: number | null, min: number): { tone: string; txt: string; bad: boolean } {
  if (!gia) return { tone: 'text-ink-400', txt: '', bad: false };
  const b = dgNhap ? gia / dgNhap - 1 : null; const parts: string[] = [];
  if (b !== null) parts.push(`biên ${(b * 100).toFixed(2)}%`);
  if (gk && Math.abs(gk - gia) > 0.5) parts.push(`giá HT ${money(gk)}`);
  const bad = b !== null && b < BIEN_CAM - 0.000001; const duyet = b !== null && b > BIEN_DUYET + 0.000001; void min;
  if (bad) parts.push('dưới 2% — không được xuất'); else if (duyet) parts.push('trên 4% — chờ duyệt giá');
  return { tone: bad ? 'text-red-600 font-semibold' : duyet ? 'text-amber-700 font-semibold' : 'text-ink-500', txt: parts.join(' · '), bad };
}
/** Việc tiếp theo của phiếu: ai làm, làm gì */
/** Bản 30: link xem HĐ đã ký trên MISA meInvoice theo mã tra cứu */
export const TRA_CUU_URL = 'https://www.meinvoice.vn/tra-cuu/tra-cuu/DownloadHandler.ashx?Type=pdf&Viewer=1&ext=QXVLM59J&Code={code}';
export const traCuuLink = (ma: string, tpl?: string) => (tpl || TRA_CUU_URL).replace('{code}', encodeURIComponent(ma));
export const normMaTraCuu = (s: string) => s.replace(/\s+/g, '').toUpperCase();
export const maTraCuuOk = (s: string) => /^[A-Z0-9_-]{6,30}$/.test(normMaTraCuu(s));
export function TraCuu({ ma, className }: { ma: string; className?: string }) {
  const a = useApp();
  return <a href={traCuuLink(ma, a.settings.accounting?.tra_cuu_url)} target="_blank" rel="noopener noreferrer" onClick={e => e.stopPropagation()} title="Mở HĐ đã ký trên MISA meInvoice"
    className={cx('inline-flex items-center gap-1 rounded-md bg-emerald-50 px-2 py-0.5 font-mono text-xs font-semibold text-emerald-800 ring-1 ring-emerald-200 hover:bg-emerald-100', className)}>{ma} <span aria-hidden>↗</span></a>;
}

export function nextStep(v: any): [string, string] {
  switch (v.status) {
    case 'soan': return ['Sale', 'gửi kế toán'];
    case 'cho_duyet_gia': return ['Quản lý', `duyệt giá${v.bien_max != null ? ` (biên ${(Number(v.bien_max) * 100).toFixed(1)}%)` : ''}`];
    case 'tra_sua': return ['Sale', 'sửa nội dung rồi gửi lại kế toán'];
    case 'cho_nhap': return v.misa_at ? ['Kế toán', `tải PDF nháp (đã xuất MISA ${fmtDateTime(v.misa_at)})`] : ['Kế toán', v.sua_sau_nhap ? 'sửa nháp theo yêu cầu, xuất file MISA' : 'xuất file nhập MISA'];
    case 'da_nhap': return !v.nhap_v ? ['Kế toán', 'tải PDF nháp'] : v.nhap_sent ? ['Sale', 'chờ khách phản hồi'] : ['Sale', `gửi khách nháp v${v.nhap_v}`];
    case 'xac_nhan_ky': return ['Kế toán', 'ký trên MISA, nhập mã tra cứu'];
    default: return ['', ''];
  }
}
const NextStep = ({ v }: { v: any }) => { const [who, what] = nextStep(v); return who ? <div className="text-[11px] leading-tight text-ink-500"><b className={who === 'Sale' ? 'text-brand-700' : 'text-amber-700'}>{who}</b>: {what}</div> : null; };
const OBadge = ({ s }: { s: string }) => <Badge color={OST[s]?.[1] || 'gray'}>{OST[s]?.[0] || s}</Badge>;
const vatTxt = (v: any) => (v === null || v === undefined ? '' : Math.round(Number(v) * 100) + '%');
export const INV_SEL = '*,out_invoice_lines(id,item_id,stt,sl,don_gia,vat,out_items(id,ma_hang,part,ten,dvt,vat,sl_nhap,dg_nhap,gia_khach,so_hd_vao,md))';
const totalOf = (v: any) => (v.out_invoice_lines || []).reduce((t: number, l: any) => { const tt = Math.round(l.sl * l.don_gia); return { tt: t.tt + tt, thue: t.thue + Math.round(tt * Number(l.vat ?? l.out_items?.vat ?? 0)) } as any; }, { tt: 0, thue: 0 } as any);

export default function Out() {
  const a = useApp(); const acc = a.isAdmin || a.has('ke_toan'); const { query } = useRoute(); const openId = query.inv || null;
  const [tab, setTab] = useState<string>(() => sessionStorage.getItem('nt_out_tab') || (acc ? 'inv' : 'mine'));
  const go2 = (t: string) => { setTab(t); sessionStorage.setItem('nt_out_tab', t); };
  if (!acc && !a.isSales) return <Layout title="Xuất HĐ đầu ra"><Card>Chỉ Kế toán và Kinh doanh.</Card></Layout>;
  const tabs: [string, React.ReactNode][] = acc ? [['inv', 'Yêu cầu xuất HĐ'], ['items', 'Bảng gốc HĐ đầu vào (mã hàng MISA)'], ['ton', 'Báo cáo tồn']]
    : [['mine', 'Sẵn sàng xuất'], ['inv', 'Yêu cầu của tôi'], ['free', 'Dòng chưa có sale'], ...(a.isLead ? [['ton', 'Báo cáo tồn'] as [string, React.ReactNode]] : [])];
  const t = openId ? 'inv' : tabs.some(x => x[0] === tab) ? tab : tabs[0][0];
  return <Layout title="Xuất HĐ đầu ra">
    <Tabs value={t} onChange={go2} tabs={tabs} />
    <div className="mt-4">{t === 'inv' && <Invoices acc={acc} openId={openId} />}{t === 'items' && <Items acc />}{t === 'mine' && <Items />}{t === 'free' && <Items free />}{t === 'ton' && <TonReport />}</div>
  </Layout>;
}

// ============ Dòng hàng (sổ) ============
const ITEM_COLS = 'id,ma_hang,part,stt_so,ten,dvt,vat,sl_nhap,dg_nhap,so_hd_vao,ky_hieu,ngay_vao,md,nvkd,username,sale_id,customer_id,gia_khach,gia_src,gia_n,match_src,legacy,sl_xuat,ton,phieu,khach,xe';
const LEG: Record<string, string> = { da_ky: 'đã ký', da_nhap: 'đã xuất nháp', xac_nhan_ky: 'KD xác nhận ký' };
const maHang = (t: any) => t.ma_hang + (t.part > 1 ? ` (${t.part})` : '');
function useDebounced<T>(v: T, ms = 350): T { const [d, setD] = useState(v); React.useEffect(() => { const t = setTimeout(() => setD(v), ms); return () => clearTimeout(t); }, [v]); return d; }
function Items({ acc = false, free = false }: { acc?: boolean; free?: boolean }) {
  const a = useApp(); const { busy, run } = useAction(); const mode = acc ? 'acc' : free ? 'free' : 'mine';
  const [q, setQ] = useState(''); const qd = useDebounced(q); const [f, setF] = useState(acc ? 'ton' : ''); const [hd, setHd] = useState(''); const [xe, setXe] = useState(''); const [sale, setSale] = useState(''); const [kh, setKh] = useState('');
  const [sort, setSortRaw] = useState<string>(() => sessionStorage.getItem('nt_out_sort_' + mode) || (acc ? 'moi' : 'md'));
  const setSort = (v: string) => { setSortRaw(v); sessionStorage.setItem('nt_out_sort_' + mode, v); };
  const pg = usePager(acc ? 'out_items' : free ? 'out_free' : 'out_mine', [qd, f, hd, xe, sale, kh, sort]);
  const filt = { mode, f, q: qd, hd, xe, sale, kh, sort };
  const { data, loading, reload: reloadRows } = useLoad(() => db.rpc<any>('out_items_page', { p: { ...filt, offset: pg.from, limit: pg.size } }), [mode, f, qd, hd, xe, sale, kh, sort, pg.from, pg.size]);
  const { data: saleOpts } = useLoad(() => acc || (a.isLead && !free) ? db.rpc<any[]>('out_sale_opts') : Promise.resolve([]), [acc, free]);
  const { data: st, reload: reloadSt } = useLoad(() => db.rpc<any>('out_items_stats', { p_mode: mode }), [mode]);
  const { data: ic } = useLoad(async () => {
    if (acc || free) return null;
    const r = await db.rpc<any>('out_invoices_page', { p: { limit: 0 } }); const m = new Date(); const from = `${m.getFullYear()}-${String(m.getMonth() + 1).padStart(2, '0')}-01`;
    const k = await db.from<any>('out_invoices').select('id', { count: true }).eq('status', 'da_ky').gte('status_at', from).limit(1) as any;
    return { ...(r?.counts || {}), chua_gui: r?.chua_gui ?? 0, ky_thang: k?.count ?? 0 };
  }, [acc, free]);
  const reload = () => { reloadRows(); reloadSt(); };
  const rows: any[] = data?.rows || []; const total: number = data?.total || 0; const S = st || {};
  const [pick, setPick] = useState<Record<string, any>>({}); const [edit, setEdit] = useState<any>(null); const [newInv, setNewInv] = useState<any[] | null>(null); const [up, setUp] = useState(false);
  const [claimT, setClaimT] = useState<any>(null); const [xeOpen, setXeOpen] = useState(false); const [bulk, setBulk] = useState<any[] | null>(null); const [pp, setPp] = useState<any>(null);
  /** Chọn tất cả dòng đang lọc (mọi trang) hoặc cả 1 ID đơn */
  const pickAll = (md?: string) => run(async () => {
    const r = await db.rpc<any>('out_items_page', { p: { ...filt, ...(md ? { md, f: '', q: '', hd: '', xe: '', kh: '' } : {}), offset: 0, limit: 500 } });
    const list = (r?.rows || []).filter((t: any) => canPick(t)); setPick(p => { const x = { ...p }; list.forEach((t: any) => { x[t.id] = t; }); return x; });
    if (!md && (r?.total || 0) > 500) toast.err('Chỉ chọn được 500 dòng đầu — lọc hẹp lại rồi chọn tiếp');
  });
  const mdsChosen = new Set(Object.values(pick).map((t: any) => t.md || 'row:' + t.id)).size;
  const PriceCell = ({ t }: { t: any }) => t.gia_khach ? <><Money v={t.gia_khach} />{t.gia_src && <div className="text-[10px] text-ink-400">{srcTxt(t.gia_src)}</div>}</>
    : t.gia_n > 1 && !free ? <button className="text-[11px] font-semibold text-amber-700 underline" onClick={e => { e.stopPropagation(); setPp(t); }}>⚠ đơn có {t.gia_n} giá — chọn</button> : <span className="text-[11px] text-red-600">chưa có</span>;
  const MdCell = ({ t }: { t: any }) => t.md ? <span className="whitespace-nowrap"><b className="text-ink-800">{t.md}</b>{!acc && !free && <button className="ml-1 text-[10px] font-semibold text-brand-700 underline" onClick={e => { e.stopPropagation(); pickAll(t.md); }}>chọn cả đơn</button>}</span> : <span className="text-amber-700">—</span>;
  const hds = ((S.hd || []) as string[]).sort((x, y) => Number(y) - Number(x)); const xes = (S.xe || []) as string[]; const sales = (S.sale || []) as string[];
  const chosen = Object.values(pick);
  const togglePick = (t: any, on: boolean) => setPick(p => { const x = { ...p }; if (on) x[t.id] = t; else delete x[t.id]; return x; });
  const exportSo = () => run(async () => {
    const all = await fetchAll<any>(() => db.from('out_items_v').select(ITEM_COLS).order('stt_so', { asc: false, nulls: 'last' }), 50000);
    const ls = await fetchAll<any>(() => db.from('out_invoice_lines').select('item_id,sl,don_gia,vat,out_invoices(code,status,buyer_name,tax_code,address,email,buyer_info,so_hd,ngay_hd)'));
    await writeXlsx('So_xuat_HD_' + today(), soRows(all, ls, id => a.personName(id)), 'NEW');
  });
  const rematch = () => run(async () => { const n = await db.rpc<number>('out_rematch'); reload(); toast.ok(`Đã gắn lại ${n} dòng còn thiếu sale / khách / giá`); });
  const locked = (t: any) => !!t.lech && !t.lech_ok_at;
  const ActBtn = ({ t }: { t: any }) => free ? <Button size="sm" variant="primary" onClick={() => setClaimT(t)}>Nhận</Button>
    : acc ? <div className="flex flex-col gap-1">{(locked(t) || !t.acc_line_id) && <Button size="sm" variant={locked(t) ? 'danger' : undefined} onClick={() => setLechT(t)}>{locked(t) ? 'Xử lý lệch' : 'Ghép tay'}</Button>}<Button size="sm" onClick={() => setEdit(t)}>Sửa</Button></div> : null;
  const [lechT, setLechT] = useState<any>(null);
  const KbTag = ({ t }: { t: any }) => <>{t.ma_kb && <div className="text-[10px] font-normal text-ink-500">{t.ma_kb}</div>}{locked(t) && <div className="text-[10px] font-semibold text-red-600" title={t.lech_note || ''}>⛔ lệch nháp — khóa</div>}</>;
  const khachTxt = (t: any) => t.khach || t.username || '';
  const canPick = (t: any) => t.ton > 0.0001 && (acc || !!t.sale_id) && !locked(t);
  const icN = (k: string) => Number(ic?.[k] || 0);
  return <>
    {acc && <div className="mb-3 flex flex-wrap items-center gap-2"><Button variant="primary" onClick={() => setUp(true)}>⇪ Nạp sổ Excel · đơn hàng · đơn vị nhận HĐ</Button>
      <Button onClick={() => setXeOpen(true)}>🚚 HĐ vào ↔ xe</Button>
      <Button loading={busy} onClick={rematch}>↻ Gắn lại sale/khách/giá</Button>
      <Button loading={busy} onClick={exportSo}>⬇ Xuất sổ (đúng mẫu)</Button></div>}
    {acc && <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-4">
      <Stat label="Còn tồn chưa xuất" value={S.ton ?? '…'} tone={S.ton ? 'amber' : undefined} onClick={() => setF('ton')} sub={`/ ${S.all ?? '…'} dòng trong sổ`} />
      <Stat label="Chưa gắn sale (còn tồn)" value={S.nosale ?? '…'} tone={S.nosale ? 'red' : undefined} onClick={() => setF('nosale')} />
      <Stat label="Còn tồn, chưa có giá xuất" value={S.nogia ?? '…'} onClick={() => setF('nogia')} />
      <Stat label="Chưa có ID đơn" value={S.nomd ?? '…'} onClick={() => setF('nomd')} />
      <Stat label="Đã xuất hết" value={S.het ?? '…'} onClick={() => setF('het')} />
      <Stat label="Đã ký không sale" value={S.daky_nosale ?? '…'} sub="sổ cũ, tồn 0 — để riêng" onClick={() => setF('daky_nosale')} />
      <Stat label="Lệch so với nháp — đang khóa" value={S.lech ?? '…'} tone={S.lech ? 'red' : undefined} onClick={() => setF('lech')} sub="SL / đơn giá / thuế suất" />
      <Stat label="Chưa ghép được dòng nháp" value={S.chua_ghep ?? '…'} tone={S.chua_ghep ? 'amber' : undefined} onClick={() => setF('chua_ghep')} sub="ghép tay" /></div>}
    {!acc && !free && <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-5">
      <Stat label="Dòng chờ xuất HĐ" value={S.ton ?? '…'} tone={S.ton ? 'amber' : undefined} />
      <Stat label="Giá trị còn tồn" value={S.gia_tri !== undefined ? money(S.gia_tri) : '…'} sub="theo giá xuất khách" />
      <Stat label="Phiếu chờ kế toán xuất nháp" value={icN('cho_nhap') + icN('soan')} sub={icN('soan') ? `${icN('soan')} phiếu đang soạn` : ''} />
      <Stat label="Có nháp — chờ bạn gửi khách" value={icN('da_nhap')} tone={icN('da_nhap') ? 'red' : undefined} sub={icN('chua_gui') ? `${icN('chua_gui')} bản chưa gửi khách` : ''} />
      <Stat label="Đã ký tháng này" value={icN('ky_thang')} tone="green" /></div>}
    {free && <p className="mb-3 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">Dòng trên HĐ chính thức còn tồn mà chưa xác định được sale (dòng đã ký không hiện ở đây). Hàng của bạn thì bấm <b>Nhận</b>, nhập mã đơn.</p>}
    {!acc && !free && <p className="mb-3 text-sm text-ink-600">Tick từng dòng → <b>Lập 1 phiếu</b>; hoặc tick nhiều dòng / <b>Chọn tất cả</b> → <b>⚡ Lập nhanh theo ID đơn</b>: mỗi ID đơn thành 1 phiếu, thông tin khách tự điền.</p>}
    {!acc && !free && <div className="mb-3 flex flex-wrap gap-1.5 text-xs">{([['', `Còn tồn (${S.ton ?? 0})`], ['nogia', `Chưa có giá xuất (${S.nogia ?? 0})`], ['nhieu_gia', `Đơn nhiều giá — cần chọn (${S.nhieu_gia ?? 0})`], ['nokhach', `Chưa gắn khách (${S.nokhach ?? 0})`], ['nomd', `Chưa có ID đơn (${S.nomd ?? 0})`]] as [string, string][]).map(([k, l]) =>
      <button key={k || 'all'} onClick={() => setF(k)} className={cx('rounded-full border px-2.5 py-1 font-semibold', f === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-700', k && k !== 'nomd' && Number(S[k] || 0) > 0 && f !== k && 'border-amber-300 text-amber-800')}>{l}</button>)}</div>}
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Input className="max-w-xs" placeholder="🔎 Mã hàng, tên, ID đơn, khách, sale, số HĐ, xe…" value={q} onChange={e => setQ(e.target.value)} />
      <Select className="w-40" placeholder="Tất cả xe" options={xes.map(x => [x, x === '—' ? '— Chưa gán xe' : x] as [string, string])} value={xe} onChange={setXe} />
      <Select className="w-40" placeholder="Tất cả HĐ vào" options={hds.map(h => [h, 'HĐ ' + h] as [string, string])} value={hd} onChange={setHd} />
      {acc && <Select className="w-44" placeholder="Tất cả sale" options={sales.map(x => [x, x === '—' ? '— Chưa có sale' : a.personName(x)] as [string, string])} value={sale} onChange={setSale} />}
      {!acc && !free && a.isLead && (saleOpts || []).length > 1 && <Select className="w-44" placeholder="Tất cả sale" options={(saleOpts || []).map((x: any) => [x.id, x.full_name] as [string, string])} value={sale} onChange={setSale} />}
      {!acc && <Select className="w-52" placeholder="Tất cả khách" options={((S.kh || []) as [string, string][]).map(([k, t]) => [k, t] as [string, string])} value={kh} onChange={setKh} />}
      {!free && <Select className="w-40" options={[['md', 'Sắp theo ID đơn'], ['kh', 'Sắp theo khách'], ['moi', 'Mới nhất']] as [string, string][]} value={sort} onChange={v => setSort(v || 'moi')} />}
      {!free && <Button size="sm" loading={busy} onClick={() => pickAll()}>☑ Chọn tất cả ({total})</Button>}
      {acc && <Select className="w-48" placeholder="Tất cả dòng" options={[['ton', 'Còn tồn'], ['het', 'Đã xuất hết'], ['nosale', 'Chưa gắn sale'], ['nomd', 'Chưa có ID đơn'], ['nogia', 'Chưa có giá xuất'], ['nhieu_gia', 'Đơn nhiều giá — chưa chọn'], ['daky_nosale', 'Đã ký không sale'], ['lech', 'Lệch — đang khóa'], ['chua_ghep', 'Chưa ghép nháp']] as [string, string][]} value={f} onChange={setF} />}
    </div>
    {!free && chosen.length > 0 && <div className="sticky top-2 z-20 mb-3 hidden flex-wrap items-center gap-2 rounded-2xl border border-brand-200 bg-brand-50/95 px-3 py-2 shadow-soft sm:flex">
      <span className="text-sm">Đã chọn <b>{chosen.length}</b> dòng · <b>{mdsChosen}</b> ID đơn</span>
      <Button size="sm" onClick={() => setNewInv(chosen)}>Lập 1 phiếu ({chosen.length} dòng)</Button>
      <Button size="sm" variant="primary" onClick={() => setBulk(chosen)}>⚡ Lập nhanh theo ID đơn ({mdsChosen} phiếu)</Button>
      <button className="text-xs text-ink-500 underline" onClick={() => setPick({})}>Bỏ chọn</button>
    </div>}
    {rows.length > 0 && <div className="mb-3 space-y-2 sm:hidden">{rows.map((t: any) =>
      <div key={t.id} className={cx('rounded-2xl border bg-white p-3 shadow-soft', pick[t.id] ? 'border-brand-500 bg-brand-50/60' : 'border-ink-200')}>
        <div className="flex items-start gap-2">{!free && <input type="checkbox" className="mt-1 h-5 w-5" disabled={!canPick(t)} checked={!!pick[t.id]} onChange={e => togglePick(t, e.target.checked)} />}
          <div className="min-w-0 flex-1"><div className="flex flex-wrap items-center gap-x-2 text-xs"><MdCell t={t} /><VatBadge v={t.vat} /></div>
            <div className="text-[11px] text-ink-500">{maHang(t)} · {t.xe ? t.xe + ' · ' : ''}HĐ {t.so_hd_vao}{acc ? ' · ' + (a.personName(t.sale_id) || t.nvkd || 'chưa có sale') : ''}</div><KbTag t={t} />
            <div className="line-clamp-3 text-sm font-medium text-ink-900">{t.ten}</div>
            {khachTxt(t) && <div className="text-xs text-ink-600">Khách: {khachTxt(t)}</div>}
            <div className="mt-1 flex flex-wrap gap-x-3 text-xs"><span>SL {num(t.sl_nhap, 2)} {t.dvt}</span><span>Giá nhập <Money v={t.dg_nhap} /></span><span className="inline-flex items-center gap-1">Giá xuất <b><PriceCell t={t} /></b></span>
              <span className={t.ton > 0.0001 ? 'font-semibold text-amber-700' : 'text-ink-400'}>Tồn {num(t.ton, 2)}</span></div>
            {(t.phieu || t.legacy?.status) && <div className="mt-1 text-[11px] text-ink-500">{t.phieu ? t.phieu.split(',').map((p: string) => { const [c, sx] = p.split(':'); return `${c} · ${OST[sx]?.[0] || sx}`; }).join(' | ') : 'Sổ cũ: ' + (LEG[t.legacy.status] || t.legacy.status)}</div>}</div>
          <ActBtn t={t} /></div></div>)}
      <Pager p={pg} total={total} /></div>}
    {!free && chosen.length > 0 && <div className="fixed inset-x-3 bottom-3 z-30 grid grid-cols-2 gap-2 sm:hidden"><Button onClick={() => setNewInv(chosen)}>1 phiếu ({chosen.length} dòng)</Button>
      <Button variant="primary" onClick={() => setBulk(chosen)}>⚡ {mdsChosen} phiếu theo đơn</Button></div>}
    <Card className={rows.length ? 'hidden sm:block' : ''} bodyClass="p-0">{loading && !rows.length ? <Loading /> : !rows.length ? <Empty>{free ? 'Không có dòng chưa có sale' : 'Không có dòng'}</Empty> :
      <Table scroll className={loading ? 'opacity-60' : ''} head={[...(free ? [] : ['']), 'Mã hàng', 'Tên hàng', 'SL nhập', 'Đơn giá nhập', 'VAT', 'Xe · HĐ vào', 'ID đơn', 'Khách', ...(acc ? ['Sale'] : []), 'Giá xuất', 'Còn tồn', 'Phiếu', '']}>{rows.map((t: any) =>
        <tr key={t.id} className={cx('align-top', pick[t.id] && 'bg-brand-50/60')}>
          {!free && <Td><input type="checkbox" disabled={!canPick(t)} checked={!!pick[t.id]} onChange={e => togglePick(t, e.target.checked)} /></Td>}
          <Td className="whitespace-nowrap text-xs font-semibold">{maHang(t)}<KbTag t={t} /></Td><Td className="min-w-[300px] max-w-[440px] text-xs"><div className="line-clamp-3" title={t.ten}>{t.ten}</div></Td>
          <Td className="whitespace-nowrap text-right">{num(t.sl_nhap, 2)} <span className="text-[11px] text-ink-400">{t.dvt}</span></Td><Td className="text-right"><Money v={t.dg_nhap} /></Td><Td className="text-right text-xs"><VatBadge v={t.vat} /></Td>
          <Td className="whitespace-nowrap text-xs">{t.xe ? <b className="text-ink-800">{t.xe}</b> : <span className="text-ink-400">—</span>}<div className="text-ink-500">HĐ {t.so_hd_vao} · {fmtDate(t.ngay_vao)}</div></Td>
          <Td className="text-xs"><MdCell t={t} />{t.match_src === 'hd_xml' && <div className="text-[10px] text-emerald-700">theo HĐ XML</div>}</Td>
          <Td className="max-w-[200px] text-xs">{t.khach ? <><div className="line-clamp-2 font-medium text-ink-800">{t.khach}</div><div className="text-ink-400">{t.username}</div></> : t.username ? <span className="text-amber-700" title="Username chưa có trong danh sách khách ERP">{t.username}</span> : <span className="text-ink-300">—</span>}</Td>
          {acc && <Td className="whitespace-nowrap text-xs">{a.personName(t.sale_id) || <span className="text-red-600">{t.nvkd || 'chưa có sale'}</span>}</Td>}
          <Td className="text-right"><PriceCell t={t} /></Td>
          <Td className={cx('whitespace-nowrap text-right font-semibold', t.ton > 0.0001 ? 'text-amber-700' : 'text-ink-400')}>{num(t.ton, 2)}</Td>
          <Td className="min-w-[150px] text-[11px] text-ink-500">{(t.phieu || '').split(',').filter(Boolean).map((p: string) => { const [c, sx] = p.split(':'); return <div key={p}>{c} · {OST[sx]?.[0]}</div>; })}{!t.phieu && t.legacy?.status ? <div>Sổ cũ: {LEG[t.legacy.status] || t.legacy.status}</div> : ''}</Td>
          <Td><ActBtn t={t} /></Td></tr>)}</Table>}
      <Pager p={pg} total={total} /></Card>
    {up && <ImportSo onClose={() => setUp(false)} onDone={() => { setUp(false); reload(); }} />}
    {xeOpen && <HdXe hds={hds} onClose={() => setXeOpen(false)} onDone={() => { setXeOpen(false); reload(); }} />}
    {edit && <ItemEdit t={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); reload(); }} />}
    {claimT && <ClaimItem t={claimT} onClose={() => setClaimT(null)} onDone={() => { setClaimT(null); reload(); }} />}
    {newInv && <InvoiceEditor items={newInv} onClose={() => setNewInv(null)} onDone={() => { setNewInv(null); setPick({}); reload(); }} />}
    {bulk && <BulkInvoices items={bulk} onClose={() => { setBulk(null); setPick({}); reload(); }} onDone={() => reload()} />}
    {lechT && <LechModal t={lechT} onClose={() => setLechT(null)} onDone={() => { setLechT(null); reload(); }} />}
    {pp && <PricePick item={pp} onClose={() => setPp(null)} onPick={gia => run(async () => { await db.rpc('out_item_set_price', { p_id: pp.id, p_gia: gia }); setPp(null); reload(); }, 'Đã đặt giá xuất')} />}
  </>;
}

/** Bản 23 — dòng HĐ ký lệch nháp (khóa) hoặc chưa ghép được dòng nháp: ghép lại theo gợi ý, hoặc chấp nhận kèm lý do */
export function LechModal({ t, onClose, onDone }: { t: any; onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction(); const [note, setNote] = useState('');
  const { data: sug, loading } = useLoad(() => db.rpc<any[]>('out_item_suggest', { p_id: t.id }), [t.id]);
  const relink = (line: string) => run(async () => { await db.rpc('out_item_relink', { p_id: t.id, p_line: line }); onDone(); }, 'Đã ghép lại');
  const accept = () => run(async () => { await db.rpc('out_item_lech_ok', { p_ids: [t.id], p_note: note }); onDone(); }, 'Đã chấp nhận — mở khóa dòng');
  return <Modal open onClose={onClose} title={`${t.lech && !t.lech_ok_at ? 'Xử lý dòng lệch' : 'Ghép tay'} · ${maHang(t)}`} size="lg">
    <div className="mb-3 rounded-xl border border-ink-200 bg-ink-50 px-3 py-2 text-sm"><div className="font-medium">{t.ten}</div>
      <div className="text-xs text-ink-600">SL {num(t.sl_nhap, 2)} {t.dvt} · đơn giá HĐ ký <Money v={t.dg_nhap} /> · VAT {vatTxt(t.vat)}{t.ma_kb ? ` · ${t.ma_kb}` : ''}</div>
      {t.lech_note && <div className="mt-1 text-xs font-semibold text-red-700">⛔ {t.lech_note}</div>}</div>
    <div className="mb-1 text-sm font-semibold">Dòng nháp cùng số lượng (tên giống nhất trước)</div>
    {loading ? <Loading /> : !(sug || []).length ? <Empty>Không có dòng nháp cùng số lượng chưa ghép — kiểm lại file nháp / xe, hoặc nhập ID đơn ở nút Sửa.</Empty> :
      <Table head={['Mã khai báo', 'Tên trên nháp', 'SL', 'Giá APT nháp', 'Giá khách', 'Giống', '']}>{(sug || []).map((x: any) =>
        <tr key={x.id}><Td className="whitespace-nowrap text-xs font-semibold">{x.ma_dong || x.md}</Td><Td className="max-w-[320px] text-xs"><div className="line-clamp-2">{x.ten_apt}</div></Td>
          <Td className="text-right">{num(x.sl_apt, 2)}</Td><Td className="text-right"><Money v={x.gia_nhap} /></Td><Td className="text-right"><Money v={x.gia_khach} /></Td>
          <Td className="text-right text-xs">{Math.round(Number(x.diem) * 100)}%</Td><Td><Button size="sm" loading={busy} onClick={() => relink(x.id)}>Ghép</Button></Td></tr>)}</Table>}
    {t.lech && !t.lech_ok_at && <div className="mt-4 border-t border-ink-100 pt-3"><Field label="Chấp nhận như HĐ ký (mở khóa) — ghi lý do"><Textarea rows={2} value={note} onChange={e => setNote(e.target.value)} placeholder="VD: APT làm tròn giá đề xuất 87.379 → 87.400" /></Field>
      <div className="mt-2 flex justify-end"><Button variant="danger" loading={busy} disabled={!note.trim()} onClick={accept}>Chấp nhận & mở khóa</Button></div></div>}
  </Modal>;
}

/** Báo cáo tồn HĐ đầu vào chưa xuất, theo sale (bản 23) */
export function TonReport() {
  const a = useApp(); const { busy, run } = useAction(); const [den, setDen] = useState(today());
  const { data, loading } = useLoad(() => db.rpc<any[]>('out_ton_report', { p_den: den }), [den]);
  const rows = data || []; const sum = (k: string) => rows.reduce((x: number, r: any) => x + Number(r[k] || 0), 0);
  const xls = () => run(async () => { await writeXlsx('Ton_HD_dau_vao_' + den, [['Sale', 'Số dòng', 'Số đơn', 'SL tồn', 'Tiền tồn (giá APT)', 'Tồn lâu nhất (ngày)', 'Dòng tồn > 15 ngày'],
    ...rows.map((r: any) => [a.personName(r.sale_id) || 'Chưa có sale', r.so_dong, r.so_don, Number(r.sl_ton), Number(r.tien), r.ngay_ton_max, r.qua_15])], 'Ton'); });
  return <>
    <div className="mb-3 flex flex-wrap items-end gap-2"><Field label="Chốt đến ngày"><Input type="date" value={den} onChange={e => setDen(e.target.value)} /></Field>
      <Button loading={busy} onClick={xls}>⬇ Xuất Excel</Button></div>
    <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-4"><Stat label="Dòng còn tồn" value={sum('so_dong')} /><Stat label="Tiền tồn (giá APT)" value={money(sum('tien'))} />
      <Stat label="Dòng tồn > 15 ngày" value={sum('qua_15')} tone={sum('qua_15') ? 'red' : undefined} /><Stat label="Số sale có tồn" value={rows.length} /></div>
    <Card bodyClass="p-0">{loading ? <Loading /> : !rows.length ? <Empty>Không còn tồn HĐ đầu vào</Empty> :
      <Table head={['Sale', 'Số dòng', 'Số đơn', 'SL tồn', 'Tiền tồn', 'Tồn lâu nhất', '> 15 ngày']}>{rows.map((r: any) =>
        <tr key={r.sale_id || 'none'}><Td className="font-medium">{a.personName(r.sale_id) || <span className="text-red-600">Chưa có sale</span>}</Td><Td className="text-right">{r.so_dong}</Td><Td className="text-right">{r.so_don}</Td>
          <Td className="text-right">{num(r.sl_ton, 2)}</Td><Td className="text-right"><Money v={r.tien} /></Td><Td className="text-right">{r.ngay_ton_max ?? '—'} ngày</Td>
          <Td className={cx('text-right', r.qua_15 > 0 && 'font-semibold text-red-600')}>{r.qua_15}</Td></tr>)}</Table>}</Card>
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

export function ImportSo({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
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
    if (res.orders.length) {
      // gửi theo từng nhóm trọn ID đơn (giá của 1 đơn không bị tách ra 2 lần gửi)
      const by = new Map<string, any[]>(); res.orders.forEach((o: any) => by.set(o.md, [...(by.get(o.md) || []), o]));
      const chunks: any[][] = []; let cur: any[] = []; by.forEach(g => { if (cur.length && cur.length + g.length > 500) { chunks.push(cur); cur = []; } cur.push(...g); }); if (cur.length) chunks.push(cur);
      let n = 0, done = 0; for (const c of chunks) { done += c.length; setStep(`Đang nạp đơn hàng ${done}/${res.orders.length}…`); n += await db.rpc<number>('out_orders_import', { p_rows: c }); }
      const ng = res.orders.filter((o: any) => Number(o.gia) > 0).length;
      msg.push(`${by.size} mã đơn${ng ? `, ${ng} giá xuất` : ''} (${n} dòng được gắn)`); }
    if (res.buyers.length) { setStep('Đang nạp đơn vị nhận HĐ…'); const n = await db.rpc<number>('out_buyers_import', { p_rows: res.buyers }); msg.push(`${n} đơn vị nhận HĐ`); }
    setStep('Đang gắn lại sale / khách / giá…'); await db.rpc<number>('out_rematch'); setStep('');
    toast.ok('Đã nạp: ' + msg.join(' · ')); onDone();
  });
  const F = ({ f, set, l, hint }: { f: File | null; set: (f: File | null) => void; l: string; hint: string }) => <Field label={l} hint={hint}>
    <label className={cx('flex cursor-pointer items-center gap-2 rounded-xl border border-dashed px-3 py-2 text-sm', f ? 'border-emerald-400 bg-emerald-50 text-emerald-800' : 'border-ink-300 hover:border-brand-400')}>
      <input type="file" accept=".xlsx,.csv" className="hidden" onChange={e => { set(e.target.files?.[0] || null); setRes(null); }} />{f ? '✓ ' + f.name : '⇪ Chọn file .xlsx'}</label></Field>;
  return <Modal open onClose={onClose} size="lg" title="Nạp danh sách đơn hàng · pháp nhân nhận HĐ"
    footer={res ? <Button variant="primary" loading={busy} onClick={save}>Lưu</Button> : <Button variant="dark" onClick={analyze}>Đọc file</Button>}>
    <div className="mb-3 rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900">HĐ chính thức APT nạp ở nút <b>“Nạp HĐ chính thức APT”</b> (Bàn làm việc kế toán) — màn đó đối chiếu với nháp APT + file xe để lấy mã khai báo, đơn, khách, sale trước khi lưu.</div>
    <div className="grid gap-3 sm:grid-cols-2">
      <F f={ord} set={setOrd} l="2. Danh sách đơn hàng (+ giá xuất)" hint="Mã đơn hàng, Username, Sale; thêm Tên hàng, Số lượng, Đơn giá xuất → ERP có giá theo đơn" />
      <F f={buy} set={setBuy} l="3. Danh sách đơn vị nhận HĐ" hint="Sheet “Thong tin KH” (MST, Tên đơn vị, Địa chỉ, mail, Username) → gắn đúng khách, lập phiếu tự điền" /></div>
    <div className="mt-2 text-xs text-ink-500">Nạp 1 hoặc cả 2 file. Nạp lại nhiều lần không bị trùng.</div>
    <div className="mt-2 flex flex-wrap items-center gap-2 rounded-xl bg-ink-50 px-3 py-2 text-xs">⬇ File mẫu (đúng cột):
      <button className="font-semibold text-brand-700 underline" onClick={() => downloadMau('orders')}>2. Đơn hàng + giá xuất</button>
      <button className="font-semibold text-brand-700 underline" onClick={() => downloadMau('buyers')}>3. Pháp nhân nhận HĐ (có Username)</button>
      <span className="text-ink-500">Giá xuất theo ID đơn + tên hàng + SL: ERP tự khớp đúng dòng; đơn nhiều giá mà không khớp được thì để sale chọn.</span></div>
    {err && <div className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">{err}</div>}
    {step && <div className="mt-3 rounded-lg bg-brand-50 p-3 text-sm font-semibold text-brand-800">{step}</div>}
    {res && <div className="mt-3 space-y-2 text-sm">
      <div className="grid grid-cols-2 gap-2"><Stat label="Dòng đơn hàng" value={res.orders.length} sub={res.orders.some((o: any) => Number(o.gia) > 0) ? `${res.orders.filter((o: any) => Number(o.gia) > 0).length} dòng có giá xuất` : ''} /><Stat label="Pháp nhân nhận HĐ" value={res.buyers.length} sub={`${res.buyers.filter((b: any) => b.username).length} dòng có Username → gắn khách`} /></div>
      {res.warnings.slice(0, 8).map((w: string, i: number) => <div key={i} className="rounded bg-amber-50 px-2 py-1 text-xs text-amber-900">• {w}</div>)}
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
export function InvoiceEditor({ items, inv, onClose, onDone }: { items?: any[]; inv?: any; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const { busy, run } = useAction(); const cfg = useAccCfg();
  const init = inv ? (inv.out_invoice_lines || []).map((l: any) => ({ item: l.out_items, item_id: l.item_id, sl: String(l.sl), gia: String(Math.round(l.don_gia)), vat: l.vat }))
    : (items || []).map(t => ({ item: t, item_id: t.id, sl: String(+Number(t.ton).toFixed(4)), gia: t.gia_khach ? String(Math.round(t.gia_khach)) : '', vat: t.vat }));
  const [ls, setLs] = useState<any[]>(init); const [pp, setPp] = useState<number | null>(null);
  const cid0 = inv?.customer_id || (items || []).find(t => t.customer_id)?.customer_id || null;
  const { data: cus0 } = useLoad(() => cid0 ? db.from<any>('customers').select('id,code,sys_code,sys_username,company_name,contact_name,tax_code,address,legal_address,email,phone').eq('id', cid0).maybeSingle() : Promise.resolve(null), [cid0]);
  const [cus, setCus] = useState<any>(null); const c = cus || cus0;
  const { data: buyers, reload: reloadBuyers } = useLoad(() => c?.id ? db.from<any[]>('out_buyers').select('*').eq('customer_id', c.id).order('is_default', { asc: false }).order('created_at', { asc: false }) : Promise.resolve([]), [c?.id]);
  // Bản 23: khách có pháp nhân mặc định → tự điền khi tạo yêu cầu mới
  React.useEffect(() => { const d = (buyers || []).find((x: any) => x.is_default); if (!inv && d) setB((y: any) => y.name ? y : { ...y, name: d.name, mst: d.tax_code || '', addr: d.address || '', email: d.email || '' }); }, [buyers]);
  const setDefault = (id: string) => run(async () => { await db.rpc('out_buyer_set_default', { p_id: id }); reloadBuyers(); }, 'Đã đặt pháp nhân mặc định');
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
  const after = inv && (['da_nhap', 'xac_nhan_ky', 'tra_sua'].includes(inv.status) || !!inv.misa_at);
  return <Modal open onClose={onClose} size="xl" title={inv ? `Sửa phiếu ${inv.code}` : 'Lập phiếu xuất HĐ'}
    footer={<>{!inv || inv.status === 'soan' ? <Button loading={busy} onClick={() => save(false)}>Lưu nháp</Button> : null}
      <Button variant="primary" loading={busy} disabled={!b.name || !ls.length} onClick={() => save(true)}>{after ? 'Lưu — kế toán xuất nháp lại' : 'Xác nhận giá & thông tin → gửi kế toán'}</Button></>}>
    {after && <div className="mb-3 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">Kế toán đã export MISA — sửa xong yêu cầu lên phiên bản mới (v{(inv?.version || 1) + 1}), quay về hàng chờ export; kế toán xóa nháp cũ trên MISA và tạo lại.</div>}
    {legInfo && <details className="mb-3 rounded-lg bg-slate-50 px-3 py-2 text-xs text-ink-700"><summary className="cursor-pointer font-semibold">Thông tin xuất HĐ đã báo trên sổ cũ (đã điền sẵn — kiểm tra lại)</summary><pre className="mt-1 whitespace-pre-wrap font-sans">{legInfo}</pre></details>}
    {vats.length > 1 && <div className="mb-3 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">Phiếu có nhiều thuế suất ({vats.join(', ')}) — thường phải tách HĐ riêng.</div>}
    <div className="grid gap-3 lg:grid-cols-2">
      <div><Field label="Khách hàng (ERP)"><CustomerPicker value={c} onChange={x => setCus(x)} /></Field>
        <div className="mt-2 flex flex-wrap gap-1.5 text-xs">{c && <button className="rounded-lg border border-ink-200 px-2 py-1 hover:border-brand-400" onClick={fromCus}>Lấy thông tin khách</button>}
          {(buyers || []).map(x => <button key={x.id} className="rounded-lg border border-brand-200 bg-brand-50 px-2 py-1 font-semibold text-brand-800 hover:border-brand-500"
            onClick={() => setB((y: any) => ({ ...y, name: x.name, mst: x.tax_code || '', addr: x.address || '', email: x.email || '' }))}>{x.is_default ? '★ ' : ''}{x.name}{x.tax_code ? ' · ' + x.tax_code : ''}</button>)}</div>
        {!!(buyers || []).length && <div className="mt-1 text-[11px] text-ink-500">Pháp nhân nhận HĐ của khách (★ = mặc định) — bấm để điền.
          {(() => { const cur = (buyers || []).find((x: any) => x.name === b.name && (x.tax_code || '') === (b.mst || '')); return cur && !cur.is_default ? <button className="ml-1 font-semibold text-brand-700 underline" onClick={() => setDefault(cur.id)}>Đặt “{cur.name}” làm mặc định</button> : null; })()}</div>}</div>
      <div className="grid grid-cols-2 gap-2">
        <Field className="col-span-2" label="Tên đơn vị mua hàng *"><Input value={b.name} onChange={e => setF('name', e.target.value)} placeholder="HỘ KINH DOANH … / CÔNG TY …" /></Field>
        <Field label="Mã số thuế" hint={look}><Input value={b.mst} onChange={e => setF('mst', e.target.value.replace(/\s/g, ''))} onBlur={() => lookup()} /></Field>
        <Field label="Hình thức thanh toán"><Select options={[['TM/CK', 'TM/CK'], ['CK', 'CK'], ['TM', 'TM']]} value={b.pay} onChange={v => setF('pay', v)} /></Field>
        <Field className="col-span-2" label="Địa chỉ"><Input value={b.addr} onChange={e => setF('addr', e.target.value)} /></Field>
        <Field className="col-span-2" label="Email nhận HĐ"><Input value={b.email} onChange={e => setF('email', e.target.value)} /></Field>
      </div></div>
    <div className="mt-3 space-y-2 sm:hidden">{ls.map((l, i) => { const g = giaCheck(Number(l.gia || 0), l.item?.dg_nhap ?? null, l.item?.gia_khach ?? null, cfg.bien_nt_min);
      return <div key={l.item_id} className="rounded-xl border border-ink-200 p-2.5">
        <div className="flex items-start justify-between gap-2"><div className="min-w-0"><div className="text-[11px] text-ink-500"><b className="text-ink-800">{l.item?.md || 'chưa có ID đơn'}</b> · {l.item?.ma_hang} · {l.item?.dvt} · VAT <VatBadge v={l.vat} />{l.item?.ton !== undefined ? ' · tồn ' + num(l.item.ton, 2) : ''}</div>
          <div className="line-clamp-2 text-sm">{l.item?.ten}</div></div>{ls.length > 1 && <button className="px-1 text-red-600" onClick={() => setLs(x => x.filter((_, j) => j !== i))}>✕</button>}</div>
        <div className="mt-2 grid grid-cols-2 gap-2"><Field label="SL xuất"><Input className="text-right" inputMode="decimal" value={l.sl} onChange={e => setLs(x => x.map((y, j) => j === i ? { ...y, sl: e.target.value.replace(/[^\d.]/g, '') } : y))} /></Field>
          <Field label="Đơn giá xuất"><Input className="text-right" inputMode="numeric" value={l.gia} onChange={e => setLs(x => x.map((y, j) => j === i ? { ...y, gia: e.target.value.replace(/[^\d.]/g, '') } : y))} /></Field></div>
        {l.item?.gia_n > 1 && <button className="mt-1 text-[11px] font-semibold text-amber-700 underline" onClick={() => setPp(i)}>đơn có {l.item.gia_n} giá — chọn</button>}
        <div className="mt-1 flex justify-between text-xs"><span className={g.tone}>{g.txt}</span><b><Money v={Math.round(Number(l.sl || 0) * Number(l.gia || 0))} /></b></div></div>; })}</div>
    <div className="mt-3 hidden max-h-[40vh] overflow-auto rounded-xl border border-ink-200 sm:block"><Table head={['ID đơn', 'Mã hàng', 'Tên hàng (theo HĐ APT)', 'ĐVT', 'Còn tồn', 'SL xuất', 'Đơn giá xuất', 'VAT', 'Thành tiền', '']}>{ls.map((l, i) =>
      <tr key={l.item_id}><Td className="whitespace-nowrap text-xs font-semibold">{l.item?.md || <span className="text-amber-700">—</span>}</Td><Td className="whitespace-nowrap text-xs">{l.item ? maHang(l.item) : ''}</Td><Td className="min-w-[200px] text-xs">{l.item?.ten}</Td><Td className="text-xs">{l.item?.dvt}</Td>
        <Td className="text-right text-xs">{l.item?.ton !== undefined ? num(l.item.ton, 2) : ''}</Td>
        <Td><Input className="w-24 text-right" inputMode="decimal" value={l.sl} onChange={e => setLs(x => x.map((y, j) => j === i ? { ...y, sl: e.target.value.replace(/[^\d.]/g, '') } : y))} /></Td>
        <Td><Input className="w-28 text-right" inputMode="numeric" value={l.gia} onChange={e => setLs(x => x.map((y, j) => j === i ? { ...y, gia: e.target.value.replace(/[^\d.]/g, '') } : y))} />
          {(() => { const g = giaCheck(Number(l.gia || 0), l.item?.dg_nhap ?? null, l.item?.gia_khach ?? null, cfg.bien_nt_min); return g.txt ? <div className={cx('mt-0.5 whitespace-nowrap text-[10px]', g.tone)}>{g.txt}</div> : null; })()}
          {l.item?.gia_n > 1 && <button className="text-[10px] font-semibold text-amber-700 underline" onClick={() => setPp(i)}>đơn có {l.item.gia_n} giá — chọn</button>}</Td>
        <Td className="text-xs"><VatBadge v={l.vat} /></Td><Td className="text-right"><Money v={Math.round(Number(l.sl || 0) * Number(l.gia || 0))} /></Td>
        <Td>{ls.length > 1 && <button className="text-red-600" onClick={() => setLs(x => x.filter((_, j) => j !== i))}>✕</button>}</Td></tr>)}</Table></div>
    <div className="mt-2 text-right text-sm">Tiền hàng <b>{money(sub)}</b> · Thuế GTGT <b>{money(tax)}</b> · Tổng <b className="text-brand-700">{money(sub + tax)}</b></div>
    {ls.some(l => Number(l.gia) > 0 && l.item?.dg_nhap && Number(l.gia) < l.item.dg_nhap) && <div className="mt-2 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">Có dòng xuất giá thấp hơn giá nhập — ghi lý do vào “Ghi chú cho kế toán” mới gửi được.</div>}
    <Field className="mt-2" label="Ghi chú cho kế toán"><Input value={b.note} onChange={e => setF('note', e.target.value)} placeholder="VD: gộp 1 HĐ, khách cần xuất trước ngày…" /></Field>
    <div className="mt-1 text-xs text-ink-500">Một dòng hàng chia cho nhiều đơn vị: giảm số lượng ở phiếu này, phần còn lại lập phiếu khác.</div>
    {pp !== null && ls[pp]?.item && <PricePick item={{ ...ls[pp].item, id: ls[pp].item_id }} onClose={() => setPp(null)} onPick={gia => { setLs(x => x.map((y, j) => j === pp ? { ...y, gia: String(gia) } : y)); setPp(null); }} />}
  </Modal>;
}

// ============ Danh sách phiếu ============
function Invoices({ acc, openId }: { acc: boolean; openId?: string | null }) {
  const a = useApp(); const { busy, run } = useAction(); const [upPdf, setUpPdf] = useState(false);
  const [st, setSt] = useState(acc ? 'cho_nhap' : 'da_nhap'); const [q, setQ] = useState(''); const qd = useDebounced(q); const [sale, setSale] = useState(''); const [sel, setSelRaw] = useState<string | null>(openId || null);
  React.useEffect(() => { if (openId) setSelRaw(openId); }, [openId]);
  const setSel = (id: string | null) => { setSelRaw(id); if (!id && location.hash.includes('inv=')) go('/out'); };
  const [pick, setPick] = useState<Record<string, any>>({}); const [flag, setFlag] = useState(''); const [next, setNext] = useState(''); const [srt, setSrt] = useState<[string, string]>(['at', 'desc']);
  const pg = usePager('out_inv', [st, qd, sale, flag, next, srt.join()]);
  const fl = st === 'cho_nhap' ? flag : ''; const nx = !st || st === 'da_nhap' ? next : '';
  const { data, loading, reload } = useLoad(() => db.rpc<any>('out_invoices_page', { p: { status: st, q: qd, sale, flag: fl, next: nx, sort: srt[0], dir: srt[1], offset: pg.from, limit: pg.size } }), [st, qd, sale, fl, nx, srt.join(), pg.from, pg.size]);
  const SortH = ({ k, l }: { k: string; l: string }) => <button className={cx('inline-flex items-center gap-1 hover:text-ink-900', srt[0] === k && 'font-semibold text-ink-900')}
    onClick={() => setSrt(x => [k, x[0] === k && x[1] === 'asc' ? 'desc' : x[0] === k ? 'asc' : (k === 'tien' || k === 'at' ? 'desc' : 'asc')])}>{l}<span className="text-[10px]">{srt[0] === k ? (srt[1] === 'asc' ? '▲' : '▼') : '↕'}</span></button>;
  const rows: any[] = data?.rows || []; const total = data?.total || 0; const cnt = data?.counts || {};
  const c = (k: string) => Number(cnt[k] || 0); const allN = Object.entries(cnt).filter(([k]) => k !== 'huy').reduce((x, [, v]) => x + Number(v), 0);
  const chosen = Object.values(pick);
  const { data: sales } = useLoad(() => acc || a.isLead ? db.rpc<any[]>('out_sale_opts') : Promise.resolve([]), [acc]);
  const saleOpts = (sales || []).map((x: any) => x.id) as string[];
  const exportMisa = () => run(async () => {
    const n = await exportMisaFile(chosen.length ? chosen.map((v: any) => v.id) : null, id => a.personName(id));
    setPick({}); reload(); toast.ok(`Đã xuất ${n} phiếu — nhập file vào MISA, tạo nháp, rồi bấm ② Tải PDF`);
  });
  const misaN = Number(data?.misa_chua || 0), suaN = Number(data?.sua || 0);
  const stItems: [string, string, number, string][] = [['cho_duyet_gia', OST.cho_duyet_gia[0], c('cho_duyet_gia'), 'red'], ['cho_nhap', OST.cho_nhap[0], c('cho_nhap'), 'amber'], ['da_nhap', OST.da_nhap[0], c('da_nhap'), 'blue'],
    ['tra_sua', OST.tra_sua[0], c('tra_sua'), 'red'], ['xac_nhan_ky', OST.xac_nhan_ky[0], c('xac_nhan_ky'), 'purple'],
    ['soan', OST.soan[0], c('soan'), 'slate'], ['da_ky', OST.da_ky[0], c('da_ky'), 'green'], ['', 'Tất cả', allN, 'dark'], ['huy', 'Hủy', c('huy'), 'gray']];
  const flags = (v: any) => <>{v.version > 1 && <div className="text-[10px] font-semibold text-ink-600">v{v.version}</div>}{v.misa_at && v.status === 'cho_nhap' && <div className="text-[10px] font-semibold text-amber-700">đã export</div>}{v.legacy && <div className="text-[10px] font-normal text-ink-400">sổ cũ</div>}{v.sua_sau_nhap && <div className="text-[10px] font-semibold text-red-600">sửa sau nháp</div>}{v.duoi_gia && <div className="text-[10px] font-semibold text-red-600">⚠ dưới giá nhập</div>}</>;
  return <>
    {!acc && <ol className="mb-3 grid gap-1 rounded-xl border border-ink-200 bg-white px-3 py-2 text-xs text-ink-700 sm:grid-cols-5 sm:gap-3">
      <li><b>① Tạo yêu cầu</b> → gửi kế toán (biên &gt; 4% chờ duyệt giá)</li><li><b>② Kế toán export MISA</b> — sau bước này không hủy được</li><li><b>③ Xem HĐ nháp</b> → gửi khách</li>
      <li><b>④ Chốt</b> · cần sửa → <i>Yêu cầu sửa</i> → sửa → gửi lại (v+1)</li><li><b>⑤ Có bản ký</b> → in làm hợp đồng</li></ol>}
    <StatusChips value={st} onChange={setSt} items={stItems} />
    {acc && st === 'cho_nhap' && <div className="-mt-1 mb-3 flex flex-wrap gap-1.5 text-xs">{([['', 'Tất cả chờ xuất nháp'], ['misa_chua', `Chưa xuất file MISA (${misaN})`], ['sua', `Sửa sau nháp (${suaN})`]] as [string, string][]).map(([k, l]) =>
      <button key={k || 'all'} onClick={() => setFlag(k)} className={cx('rounded-full border px-2.5 py-1 font-semibold', flag === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-700', k === 'sua' && suaN && flag !== k && 'border-red-300 text-red-700')}>{l}</button>)}</div>}
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Input className="max-w-xs" placeholder="🔎 Mã phiếu, đơn vị mua, MST, mã hàng, MD, số HĐ…" value={q} onChange={e => setQ(e.target.value)} />
      {(acc || a.isLead) && saleOpts.length > 1 && <Select className="w-48" placeholder="Tất cả sale" options={(sales || []).map((x: any) => [x.id, x.full_name] as [string, string])} value={sale} onChange={setSale} />}
      {(!st || st === 'da_nhap') && <Select className="w-48" placeholder="Mọi việc tiếp theo" options={[['chua_gui', 'Nháp chưa gửi khách'], ['cho_khach', 'Đã gửi — chờ khách']] as [string, string][]} value={next} onChange={setNext} />}
      <Select className="w-44 sm:hidden" options={[['at|desc', 'Mới cập nhật'], ['md|asc', 'Theo ID đơn'], ['buyer|asc', 'Theo đơn vị mua'], ['tien|desc', 'Tiền lớn trước']] as [string, string][]} value={srt.join('|')} onChange={v => setSrt((v || 'at|desc').split('|') as [string, string])} />
      <Button onClick={reload}>↻ Tải lại</Button>
      {acc && <Button variant="primary" loading={busy} onClick={exportMisa}>⬇ ① Xuất file nhập MISA ({chosen.length ? `${chosen.length} phiếu chọn` : `${misaN} chưa xuất`})</Button>}
      {acc && <Button variant="dark" onClick={() => setUpPdf(true)}>⇪ ② Tải PDF nháp / đã ký</Button>}
      {acc && chosen.length > 0 && <button className="text-xs text-ink-500 underline" onClick={() => setPick({})}>Bỏ chọn</button>}
    </div>
    {!loading && rows.length > 0 && <div className="mb-3 space-y-2 sm:hidden">{rows.map((v: any) =>
      <button key={v.id} className="block w-full rounded-2xl border border-ink-200 bg-white p-3 text-left shadow-soft" onClick={() => setSel(v.id)}>
        <div className="flex items-center justify-between gap-2"><b>{v.code}</b><OBadge s={v.status} /></div>
        {(v.nhap_v || v.ky_v) && <div className="mt-1"><FileBadge v={v} /></div>}
        <div className="mt-1 line-clamp-2 text-sm font-medium text-ink-900">{v.buyer_name || v.buyer_info}</div>
        {v.mds && <div className="text-xs font-semibold text-ink-700">ID đơn: {v.mds}{v.vat10 && <span className="ml-2 rounded bg-amber-100 px-1 text-[11px] text-amber-800">có VAT 10%</span>}</div>}
        <div className="mt-1 flex flex-wrap gap-x-3 text-xs text-ink-600">{v.tax_code && <span>MST {v.tax_code}</span>}<span>{v.so_dong} dòng</span><span>Tổng <b><Money v={Number(v.tien_hang) + Number(v.tien_thue)} /></b></span>
          {acc && <span>{a.personName(v.sale_id)}</span>}{v.so_hd && <span>HĐ {v.so_hd}</span>}{v.sua_sau_nhap && <span className="font-semibold text-red-600">sửa sau nháp</span>}</div>
        <div className="mt-1.5 border-t border-ink-100 pt-1.5"><NextStep v={v} /></div></button>)}
      <Pager p={pg} total={total} /></div>}
    <Card className={rows.length ? 'hidden sm:block' : ''} bodyClass="p-0">{loading && !rows.length ? <Loading /> : !rows.length ? <Empty>Không có phiếu</Empty> :
      <Table scroll className={loading ? 'opacity-60' : ''} head={[...(acc ? [''] : []), <SortH k="code" l="Phiếu" />, <SortH k="md" l="ID đơn" />, <SortH k="sale" l="Sale" />, <SortH k="buyer" l="Đơn vị mua" />, 'MST', 'Dòng', <SortH k="tien" l="Tiền hàng" />, 'Thuế', <SortH k="status" l="Trạng thái" />, <SortH k="at" l="Việc tiếp theo" />, 'Số HĐ']}>{rows.map((v: any) =>
        <tr key={v.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setSel(v.id)}>
          {acc && <Td><input type="checkbox" checked={!!pick[v.id]} onClick={e => e.stopPropagation()} onChange={e => setPick(p => { const x = { ...p }; if (e.target.checked) x[v.id] = v; else delete x[v.id]; return x; })} /></Td>}
          <Td className="whitespace-nowrap font-semibold">{v.code}{flags(v)}</Td>
          <Td className="max-w-[130px] text-xs font-semibold">{v.mds || <span className="font-normal text-ink-300">—</span>}{v.vat10 && <div className="text-[10px] font-semibold text-amber-700">có VAT 10%</div>}</Td>
          <Td className="whitespace-nowrap text-xs">{a.personName(v.sale_id)}</Td><Td className="max-w-[260px] text-xs"><div className="line-clamp-2">{v.buyer_name || v.buyer_info}</div></Td><Td className="text-xs">{v.tax_code}</Td>
          <Td className="text-right">{v.so_dong}</Td><Td className="text-right"><Money v={v.tien_hang} /></Td><Td className="text-right text-xs"><Money v={v.tien_thue} /></Td>
          <Td><OBadge s={v.status} />{(v.nhap_v || v.ky_v) && <div className="mt-1"><FileBadge v={v} /></div>}</Td>
          <Td className="min-w-[180px]"><NextStep v={v} /><div className="text-[10px] text-ink-400">từ {fmtDateTime(v.status_at)}</div></Td>
          <Td className="whitespace-nowrap text-xs">{v.so_hd}<div className="text-ink-400">{v.ngay_hd ? fmtDate(v.ngay_hd) : ''}</div></Td></tr>)}</Table>}
      <Pager p={pg} total={total} /></Card>
    {sel && <InvoiceDetail id={sel} acc={acc} onClose={() => setSel(null)} onChanged={reload} />}
    {upPdf && <UploadHdPdf onClose={() => setUpPdf(false)} onDone={reload} />}
  </>;
}

/** Xuất file nhập MISA cho các yêu cầu chọn (hoặc mọi yêu cầu "Đã gửi" chưa export) + file đối chiếu, rồi ghi mốc export */
export async function exportMisaFile(ids: string[] | null, personName: (id: string) => string): Promise<number> {
  let qq = db.from<any[]>('out_invoices').select(INV_SEL).order('status_at');
  qq = ids ? qq.in('id', ids) : qq.eq('status', 'cho_nhap').is('misa_at', null);
  const list = await qq; if (!list.length) throw new Error(ids ? 'Không có yêu cầu' : 'Không còn yêu cầu chưa export MISA');
  await writeXlsx('HD_nhap_MISA_' + today(), misaRows(list), 'Hóa đơn GTGT', true, { headerRow: MISA_HEADER_ROW, fmt: { 11: 'int', 12: 'int', 13: 'int', 14: 'pct', 15: 'int' } });
  // Bản 28: chỉ 1 file nhập MISA (bỏ file đối chiếu phiếu — PDF nháp khớp theo MST + tổng tiền, không cần bảng đối chiếu)
  const cho = list.filter((v: any) => v.status === 'cho_nhap').map((v: any) => v.id);
  if (cho.length) await db.rpc('out_mark_misa', { p_ids: cho });
  return list.length;
}

export function InvoiceDetail({ id, acc, onClose, onChanged }: { id: string; acc: boolean; onClose: () => void; onChanged: () => void }) {
  const a = useApp(); const { busy, run } = useAction(); const [edit, setEdit] = useState(false); const [msg, setMsg] = useState('');
  const { data: v, loading: vLoading, reload } = useLoad(() => db.from<any>('out_invoices').select(INV_SEL).eq('id', id).maybeSingle(), [id]);
  const { data: ev, reload: rev } = useLoad(() => db.from<any[]>('out_events').select('*').eq('invoice_id', id).order('at'), [id]);
  const { data: files, reload: rf } = useLoad(() => db.rpc<HdF[]>('out_files_list', { p_invoice: id }), [id]);
  const fl: HdF[] = files || []; const nhapV = fl.find(f => f.kind === 'nhap' && f.latest)?.version ?? null;
  const done = () => { reload(); rev(); rf(); onChanged(); };
  const go = (status: string, title: string, needNote = false, extra?: () => Promise<any>) => run(async () => {
    const note = needNote ? await ask({ title, input: { label: 'Nội dung', required: true } }) : (await ask({ title, ok: 'Đồng ý' })) ? '' : null;
    if (note === null) return; const x = extra ? await extra() : {}; if (x === null) return;
    await db.rpc('out_invoice_status', { p_ids: [id], p_status: status, p_note: note || null, ...x }); done();
  }, 'Đã cập nhật');
  const sign = () => run(async () => { const so = await ask({ title: 'Xác nhận đã ký HĐ', message: 'Đã ký trên phần mềm và gửi mail cho khách. Sale được báo để nhắc khách kiểm tra email.', input: { label: 'Số HĐ đã ký', required: true }, ok: 'Đã ký' });
    if (so === null) return; await db.rpc('out_invoice_status', { p_ids: [id], p_status: 'da_ky', p_so_hd: so, p_ngay: today() }); done(); }, 'Đã xác nhận ký');
  if (!v) return <Modal open onClose={onClose} title="Phiếu xuất HĐ">{vLoading ? <Loading /> : <Empty>Không tìm thấy phiếu (đã xóa, hoặc không thuộc bạn)</Empty>}</Modal>;
  const mine = a.me.id === v.sale_id || a.seesTeam; const t = totalOf(v); const lines = (v.out_invoice_lines || []).slice().sort((x: any, y: any) => x.stt - y.stt);
  const preview = () => { if (!printDraft({ co: a.settings.company, cfg: a.settings.accounting, buyer: { name: v.buyer_name || v.buyer_info || '', mst: v.tax_code, addr: v.address, email: v.email, pay: v.payment }, sale: a.personName(v.sale_id), code: v.code,
    lines: lines.map((l: any) => ({ ten: l.out_items?.ten, dvt: l.out_items?.dvt, sl: Number(l.sl), gia: Number(l.don_gia), vat: l.vat ?? l.out_items?.vat })) })) toast.err('Trình duyệt chặn cửa sổ mới — cho phép popup'); };
  const s = v.status; const canEdit = !['da_ky', 'huy'].includes(s) && (acc || (mine && s !== 'xac_nhan_ky'));
  const approver = acc || a.has('tp_kd', 'bgd') || (a.settings.accounting?.approver_ids || []).includes(a.me.id);
  const approve = () => run(async () => { const note = await ask({ title: `Duyệt giá ${v.code}${v.bien_max != null ? ` — biên cao nhất ${(Number(v.bien_max) * 100).toFixed(1)}%` : ''}`, input: { label: 'Ghi chú (không bắt buộc)' }, ok: 'Duyệt' });
    if (note === null) return; await db.rpc('out_price_approve', { p_ids: [id], p_note: note || null }); done(); }, 'Đã duyệt giá');
  return <Modal open onClose={onClose} size="xl" title={<span>{v.code}{v.version > 1 ? ` · v${v.version}` : ''} · <OBadge s={s} />{v.misa_at && s === 'cho_nhap' ? <span className="ml-1 text-xs font-normal text-amber-700">đã export {fmtDateTime(v.misa_at)}</span> : null}</span>} footer={<>
    {s === 'soan' && <Button onClick={preview}>🖨 Xem trước phiếu</Button>}
    {canEdit && <Button onClick={() => setEdit(true)}>✎ Sửa</Button>}
    {!acc && mine && s === 'soan' && <Button variant="primary" loading={busy} onClick={() => go('cho_nhap', 'Gửi kế toán xuất nháp?')}>Gửi kế toán</Button>}
    {s === 'cho_duyet_gia' && approver && <Button variant="primary" loading={busy} onClick={approve}>✓ Duyệt giá</Button>}
    {mine && s === 'tra_sua' && <Button loading={busy} onClick={() => go('cho_nhap', 'Gửi lại kế toán (không đổi nội dung) — ghi kế toán cần sửa gì trên MISA', true)}>Gửi lại kế toán</Button>}
    {!acc && mine && s === 'da_nhap' && <><Button loading={busy} onClick={() => go('tra_sua', 'Yêu cầu sửa — ghi rõ cần sửa gì, rồi bấm Sửa để đổi nội dung', true)}>✎ Yêu cầu sửa</Button>
      <Button variant="success" loading={busy} onClick={() => run(async () => { if (!(await ask({ title: nhapV ? `Khách đã OK bản nháp v${nhapV} — đề nghị kế toán ký?` : 'Khách đã OK bản nháp — xác nhận ký?', ok: 'Đồng ý' }))) return;
        await db.rpc('out_confirm_sign', { p_invoice: id, p_version: nhapV }); done(); }, 'Đã báo kế toán ký')}>✓ Khách OK — đề nghị ký</Button></>}
    {acc && ['cho_duyet_gia', 'cho_nhap', 'da_nhap', 'tra_sua', 'xac_nhan_ky'].includes(s) && <Button loading={busy} onClick={() => go('soan', 'Trả lại sale', true)}>Trả lại sale</Button>}
    {s !== 'da_ky' && s !== 'huy' && (acc || (mine && ['soan', 'cho_nhap', 'cho_duyet_gia'].includes(s) && !v.misa_at)) && <Button variant="danger" loading={busy} onClick={() => go('huy', 'Hủy phiếu (trả lại tồn cho dòng hàng)?', acc && !mine)}>Hủy</Button>}
  </>}>
    {(() => { const [who, what] = nextStep({ ...v, nhap_v: nhapV, nhap_sent: !!fl.find(f => f.kind === 'nhap' && f.latest)?.sent_at }); return who && !(fl.length && ['da_nhap', 'xac_nhan_ky'].includes(s)) ? <div className={cx('mb-3 rounded-xl border px-3 py-2 text-sm', who === 'Sale' ? 'border-brand-200 bg-brand-50' : 'border-amber-200 bg-amber-50')}>
      Việc tiếp theo — <b>{who}</b>: {what}{v.sua_sau_nhap && s === 'cho_nhap' ? <span className="ml-1 font-semibold text-red-700">(sửa sau nháp)</span> : null}</div> : null; })()}
    <HdFilesSection v={v} files={fl} acc={acc} onChanged={done} />
    {s === 'da_ky' && v.ma_tra_cuu && <div className="mb-3 flex flex-wrap items-center gap-2 rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-900">Đã ký{v.so_hd ? <> HĐ số <b>{v.so_hd}</b></> : ''}{v.ngay_hd ? ' ngày ' + fmtDate(v.ngay_hd) : ''} · Mã tra cứu <TraCuu ma={v.ma_tra_cuu} /> <span className="text-xs text-emerald-700">bấm mã để xem HĐ</span></div>}
    {acc && ['xac_nhan_ky', 'da_ky'].includes(s) && <div className="mb-3"><SignBox v={v} onDone={done} /></div>}
    {s === 'da_ky' && !v.ma_tra_cuu && !fl.some(f => f.kind === 'ky') && <div className="mb-3 rounded-lg bg-emerald-50 px-3 py-2 text-sm text-emerald-900">Đã ký HĐ số <b>{v.so_hd}</b> ngày {fmtDate(v.ngay_hd)} — kế toán đã gửi mail. Sale báo khách kiểm tra email.</div>}
    {s === 'da_nhap' && !fl.length && <div className="mb-3 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">Phiếu chưa có PDF nháp từ MISA (phiếu sổ cũ). Kế toán tải PDF nháp lên để sale gửi khách.</div>}
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
        <b>{a.personName(e.actor)}</b> · <span className="text-xs text-ink-500">{fmtDateTime(e.at)}</span> · {e.action === 'comment' ? '' : e.action === 'status' ? `${OST[e.data?.from]?.[0] || e.data?.from} → ${OST[e.data?.to]?.[0] || e.data?.to}` : e.action === 'create' ? 'lập phiếu' : ['file', 'sent', 'misa'].includes(e.action) ? '' : 'sửa phiếu'}{e.note ? <> — {e.note}</> : ''}</div>)}</div>
      {s !== 'huy' && <div className="mt-2 flex gap-2"><Textarea rows={1} className="flex-1" value={msg} onChange={e => setMsg(e.target.value)} placeholder={acc ? 'Nhắn sale…' : 'Nhắn kế toán…'} />
        <Button loading={busy} disabled={!msg.trim()} onClick={() => run(async () => { await db.rpc('out_comment', { p_invoice: id, p_note: msg }); setMsg(''); rev(); })}>Gửi</Button></div>}</div>
    {a.isAdmin && ['da_nhap', 'xac_nhan_ky'].includes(s) && <details className="mt-3 rounded-xl border border-ink-200 px-3 py-2 text-xs"><summary className="cursor-pointer font-semibold text-ink-500">Xử lý ngoại lệ (Admin)</summary>
      <div className="mt-2 flex flex-wrap items-center gap-2"><Button size="sm" loading={busy} onClick={sign}>Đánh dấu đã ký thủ công (không có PDF)</Button><span className="text-ink-500">Chỉ dùng khi không tải được PDF đã ký.</span></div></details>}
    {edit && <InvoiceEditor inv={v} onClose={() => setEdit(false)} onDone={() => { setEdit(false); done(); }} />}
  </Modal>;
}

/** Bản 30: kế toán dán mã tra cứu MISA → nút "Đã ký" bật → bấm là xong (không hộp thoại). HĐ đã ký: sửa mã nếu gõ nhầm. */
export function SignBox({ v, onDone, compact = false }: { v: any; onDone: () => void; compact?: boolean }) {
  const [ma, setMa] = useState(v.ma_tra_cuu || ''); const { busy, run } = useAction(); const signed = v.status === 'da_ky';
  const okMa = maTraCuuOk(ma) && normMaTraCuu(ma) !== (v.ma_tra_cuu || '');
  const save = () => run(async () => { await db.rpc('out_mark_signed', { p_id: v.id, p_ma: normMaTraCuu(ma) }); onDone(); }, signed ? 'Đã sửa mã tra cứu' : `Đã ký ${v.code} — đã báo sale`);
  return <div className="flex items-center gap-2" onClick={e => e.stopPropagation()}>
    <Input className={cx('font-mono uppercase', compact ? 'h-8 w-40 text-xs' : 'w-56')} placeholder="Mã tra cứu MISA" value={ma} onChange={e => setMa(e.target.value)}
      onKeyDown={e => { if (e.key === 'Enter' && okMa && !busy) save(); }} />
    <Button size="sm" variant={signed ? undefined : 'success'} loading={busy} disabled={!okMa} onClick={save}>{signed ? 'Lưu mã' : '✓ Đã ký'}</Button>
  </div>;
}
