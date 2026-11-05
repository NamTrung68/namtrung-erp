// Bản 24 — Màn hình Hóa đơn theo bộ phận, khớp luồng 3 chu kỳ (đặc tả 02/11/2026)
//  · Sale  (#/hd)     : tab = hàng việc cần làm; "Sẵn sàng xuất" gom khách → đơn → mã khai báo; xuất theo đơn / gộp đơn / chọn mã
//  · Kế toán (#/hd/kt): 4 khối theo thứ tự trong ngày — ① Xe & HĐ APT ② Yêu cầu mới → export MISA ③ PDF nháp ④ Chờ ký
//  · Quản lý (#/hd/ql): duyệt giá biên > 4%, báo cáo tồn HĐ đầu vào theo sale
import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Input, Loading, Select, Stat, Tabs, ask, toast, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { fmtDate, fmtDateTime, money, num } from '../../lib/format';
import { downloadMau, MAU, type MauKind } from '../../lib/mau';
import { Money } from '../acc/common';
import { ImportTruck } from '../acc/Acc';
import { BIEN_CAM, BIEN_DUYET, ImportSo, InvoiceDetail, InvoiceEditor, LechModal, OST, SignBox, TonReport, TraCuu, exportMisaFile, nextStep } from '../out/Out';
import { BulkInvoices } from '../out/Bulk';
import { UploadHdPdf } from '../out/HdFiles';
import { ImportHd } from './ImportHd';
import { exportHdChinhThuc, listHdVao } from '../../lib/hdExport';
import { Chips, Modal } from '../../components/ui';
import { MisaRun, MisaTag } from '../out/MisaRun';
import { exportMisaDoiChieu, misaCall, misaCfgOf, misaOn } from '../../lib/misa';

// ---------------- dùng chung ----------------
const bien = (t: any) => (Number(t.gia_khach) > 0 && Number(t.dg_nhap) > 0 ? Number(t.gia_khach) / Number(t.dg_nhap) - 1 : null);
const locked = (t: any) => !!t.lech && !t.lech_ok_at;
const ageDays = (d?: string | null) => (d ? Math.floor((Date.now() - new Date(d).getTime()) / 864e5) : null);
const pctTxt = (x: number | null) => (x === null ? '' : (x * 100).toFixed(1) + '%');
const SBadge = ({ s }: { s: string }) => <Badge color={OST[s]?.[1] || 'gray'}>{OST[s]?.[0] || s}</Badge>;

/** Nút tải file mẫu */
export function MauBtn({ k, label }: { k: MauKind; label?: string }) {
  return <button type="button" title={MAU[k].note} onClick={() => downloadMau(k)}
    className="inline-flex items-center gap-1 rounded-lg border border-ink-200 bg-white px-2 py-1 text-[11px] font-semibold text-ink-600 hover:border-brand-400 hover:text-brand-700">⬇ {label || 'Mẫu ' + MAU[k].name}</button>;
}

/** Danh sách yêu cầu theo trạng thái (gộp nhiều trạng thái), bấm mở chi tiết */
function useInv(statuses: string[], extra: Record<string, any> = {}, dep: any[] = []) {
  return useLoad(async () => {
    const rs = await Promise.all(statuses.map(st => db.rpc<any>('out_invoices_page', { p: { status: st, limit: 200, sort: 'at', dir: 'asc', ...extra } })));
    return rs.flatMap(r => r?.rows || []);
  }, [statuses.join(), JSON.stringify(extra), ...dep]);
}
function InvRows({ rows, loading, onOpen, empty, action, sale = false, sel, onSel }: { rows: any[]; loading: boolean; onOpen: (id: string) => void; empty: string; action?: (v: any) => React.ReactNode; sale?: boolean; sel?: Record<string, boolean>; onSel?: (id: string, on: boolean) => void }) {
  const a = useApp();
  if (loading && !rows.length) return <Loading />;
  if (!rows.length) return empty ? <div className="px-4 py-6 text-center text-sm text-ink-400">{empty}</div> : null;
  return <div className="divide-y divide-ink-100">{rows.map(v => { const [who, what] = nextStep(v); const tong = Number(v.tien_hang || 0) + Number(v.tien_thue || 0);
    return <div key={v.id} className={cx('flex cursor-pointer flex-wrap items-center gap-x-4 gap-y-1 px-4 py-2.5 hover:bg-ink-50', sel?.[v.id] && 'bg-brand-50/60')} onClick={() => onOpen(v.id)}>
      {onSel && <input type="checkbox" className="h-5 w-5" checked={!!sel?.[v.id]} onClick={e => e.stopPropagation()} onChange={e => onSel(v.id, e.target.checked)} />}
      <div className="w-28 shrink-0"><div className="text-sm font-semibold text-ink-900">{v.code}{v.version > 1 && <span className="ml-1 text-[11px] font-normal text-ink-500">v{v.version}</span>}</div>
        <div className="text-[11px] text-ink-400">{fmtDateTime(v.status_at)}</div></div>
      <div className="min-w-[180px] flex-1"><div className="line-clamp-1 text-sm text-ink-800">{v.buyer_name || '—'}</div>
        <div className="text-[11px] text-ink-500">{v.mds || ''}{v.tax_code ? ' · MST ' + v.tax_code : ''}{!sale ? ' · ' + (a.personName(v.sale_id) || '') : ''}</div>
        {v.mas && <div className="mt-0.5 flex flex-wrap items-center gap-1 text-[11px]">{v.hds && <span className="rounded bg-ink-900 px-1.5 py-px font-semibold text-white">HĐ {v.hds}</span>}{String(v.mas).split(', ').slice(0, 6).map((m: string) => <span key={m} className="rounded bg-brand-50 px-1.5 py-px font-mono text-brand-800">{m}</span>)}{String(v.mas).split(', ').length > 6 && <span className="text-ink-400">+{String(v.mas).split(', ').length - 6} mã</span>}</div>}</div>
      <div className="w-28 text-right text-sm font-semibold tabular-nums">{money(tong)}{v.bien_max != null && Number(v.bien_max) > BIEN_DUYET && <div className="text-[11px] font-semibold text-amber-700">biên {pctTxt(Number(v.bien_max))}</div>}</div>
      <div className="w-48">{v.misa_at && v.status === 'cho_nhap' && !(v.misa && v.misa.st !== 'da_xoa') ? <Badge color="amber">Đã export — chờ PDF nháp</Badge> : <SBadge s={v.status} />}<MisaTag v={v} />
        {v.status === 'da_ky' && v.ma_tra_cuu && <div className="mt-1"><TraCuu ma={v.ma_tra_cuu} /></div>}
        {who && <div className="mt-0.5 text-[11px] text-ink-500"><b className={who === 'Sale' ? 'text-brand-700' : 'text-amber-700'}>{who}</b>: {what}</div>}</div>
      {action && <div onClick={e => e.stopPropagation()}>{action(v)}</div>}
    </div>; })}</div>;
}
function Block({ n, title, sub, actions, children, tone }: { n?: string; title: string; sub?: React.ReactNode; actions?: React.ReactNode; children?: React.ReactNode; tone?: 'red' | 'amber' }) {
  return <section className="mb-4 overflow-hidden rounded-2xl border border-ink-200 bg-white shadow-soft">
    <div className={cx('flex flex-wrap items-center gap-3 border-b border-ink-100 px-4 py-3', tone === 'red' && 'bg-red-50/60', tone === 'amber' && 'bg-amber-50/60')}>
      {n && <span className="flex h-7 w-7 items-center justify-center rounded-full bg-ink-900 text-xs font-bold text-white">{n}</span>}
      <div className="min-w-0 flex-1"><div className="font-semibold text-ink-900">{title}</div>{sub && <div className="text-xs text-ink-500">{sub}</div>}</div>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}</div>
    {children}</section>;
}

// ================= SALE =================
type STab = 'ready' | 'duyet' | 'tra' | 'dang' | 'ky';
export function HdSale() {
  const a = useApp(); const [tab, setTab] = useState<STab>(() => (sessionStorage.getItem('nt_hd_tab') as STab) || 'ready');
  const go2 = (t: string) => { setTab(t as STab); sessionStorage.setItem('nt_hd_tab', t); };
  const { query } = useRoute();
  const [sale, setSale] = useState(''); const [open, setOpen] = useState<string | null>(query.inv || null); const [rev, setRev] = useState(0);
  const [hd, setHd] = useState(''); // bản 29: lọc theo số HĐ đầu vào APT
  const { data: hdOpts } = useLoad(() => db.rpc<any[]>('out_hd_opts', { p_mode: 'mine' }).catch(() => []), [rev]);
  React.useEffect(() => { if (query.inv) setOpen(query.inv); }, [query.inv]);
  const close = () => { setOpen(null); if (location.hash.includes('inv=')) go('/hd'); };
  const { data: saleOpts } = useLoad(() => a.seesTeam ? db.rpc<any[]>('out_sale_opts') : Promise.resolve([]), []);
  const { data: cnt } = useLoad(() => db.rpc<any>('out_invoices_page', { p: { limit: 0, sale, hd } }), [sale, hd, rev]);
  const { data: st } = useLoad(() => db.rpc<any>('out_items_stats', { p_mode: 'mine' }), [rev]);
  const c = (k: string) => Number(cnt?.counts?.[k] || 0);
  if (!a.isSales && !a.isAdmin) return <Layout title="Hóa đơn của tôi"><Card>Chỉ dành cho Kinh doanh.</Card></Layout>;
  const tabs: [string, React.ReactNode][] = [
    ['ready', <>Sẵn sàng xuất <Badge color="amber">{st?.ton ?? '…'}</Badge></>],
    ['duyet', <>Chờ tôi duyệt nháp {c('da_nhap') > 0 && <Badge color="red">{c('da_nhap')}</Badge>}</>],
    ['tra', <>Bị trả / chờ duyệt giá {c('tra_sua') + c('cho_duyet_gia') + c('soan') > 0 && <Badge color="red">{c('tra_sua') + c('cho_duyet_gia') + c('soan')}</Badge>}</>],
    ['dang', <>Đang xử lý <Badge>{c('cho_nhap') + c('xac_nhan_ky')}</Badge></>],
    ['ky', 'Đã ký'],
  ];
  const reload = () => setRev(x => x + 1);
  return <Layout title="Hóa đơn của tôi" actions={<div className="flex flex-wrap items-center gap-2">
    <Select className="w-56" placeholder="Tất cả số HĐ" options={((hdOpts as any[]) || []).map(x => [x.hd, `HĐ ${x.hd}${x.ngay ? ' · ' + fmtDate(x.ngay) : ''} · ${x.n} mã`] as [string, string])} value={hd} onChange={setHd} />
    {a.seesTeam && (saleOpts || []).length > 1 && <Select className="w-48" placeholder={a.isCskh && !a.isLead ? 'Các sale tôi hỗ trợ' : 'Cả nhóm'} options={(saleOpts || []).map((x: any) => [x.id, x.full_name] as [string, string])} value={sale} onChange={setSale} />}
    <Button onClick={() => go('/acc/mine')}>Đối soát xe của tôi</Button></div>}>
    <Tabs value={tab} onChange={go2} tabs={tabs} />
    <div className="mt-4">
      {tab === 'ready' && <Ready sale={sale} hd={hd} rev={rev} onChanged={reload} />}
      {tab === 'duyet' && <SaleList statuses={['da_nhap']} sale={sale} hd={hd} rev={rev} onOpen={setOpen} empty="Không có bản nháp nào chờ bạn" hint="Mở yêu cầu → xem PDF nháp → gửi khách → Chốt, hoặc Yêu cầu sửa." />}
      {tab === 'tra' && <SaleList statuses={['tra_sua', 'cho_duyet_gia', 'soan']} sale={sale} hd={hd} rev={rev} onOpen={setOpen} empty="Không có yêu cầu bị trả hay chờ duyệt" hint="Trả sửa: bấm Sửa rồi gửi lại (lên phiên bản mới). Chờ duyệt giá: biên > 4%, chờ quản lý duyệt. Đang soạn: chưa gửi kế toán." />}
      {tab === 'dang' && <SaleList statuses={['cho_nhap', 'xac_nhan_ky']} sale={sale} hd={hd} rev={rev} onOpen={setOpen} empty="Không có yêu cầu đang ở phía kế toán" hint="Đã gửi → kế toán export MISA → có nháp sẽ chuyển sang tab Chờ tôi duyệt. Đã chốt → chờ kế toán ký." />}
      {tab === 'ky' && <SaleList statuses={['da_ky']} sale={sale} hd={hd} rev={rev} onOpen={setOpen} empty="Chưa có HĐ đã ký" hint="Bấm vào mã tra cứu (ô xanh) để xem / tải HĐ đã ký trên MISA — gửi khách hoặc in hợp đồng." />}
    </div>
    {open && <InvoiceDetail id={open} acc={false} onClose={close} onChanged={reload} />}
  </Layout>;
}
function SaleList({ statuses, sale, hd, rev, onOpen, empty, hint }: { statuses: string[]; sale: string; hd: string; rev: number; onOpen: (id: string) => void; empty: string; hint: string }) {
  const { data, loading } = useInv(statuses, { sale, hd, ...(statuses.includes('da_ky') ? { dir: 'desc' } : {}) }, [rev]); // đã ký: mới nhất lên đầu
  return <><p className="mb-3 text-sm text-ink-600">{hint}</p><Card bodyClass="p-0"><InvRows rows={data || []} loading={loading} onOpen={onOpen} empty={empty} sale /></Card></>;
}

/** Sẵn sàng xuất: khách → đơn → mã khai báo */
const hdOf = (t: any) => String(t.so_hd_vao || '').replace(/^0+/, '') || (String(t.ma_hang || '').match(/^[A-Za-z]+\d+-0*(\d+)-\d{4}/) || [])[1] || '';
function Ready({ sale, hd, rev, onChanged }: { sale: string; hd: string; rev: number; onChanged: () => void }) {
  const { busy, run } = useAction(); const [q, setQ] = useState(''); const [f, setF] = useState(''); const [kh, setKh] = useState('');
  const { data, loading, reload } = useLoad(() => db.rpc<any>('out_items_page', { p: { mode: 'mine', sale, sort: 'kh', offset: 0, limit: 500 } }), [sale, rev]);
  const items: any[] = (data?.rows || []).filter((t: any) => !hd || hdOf(t) === hd.replace(/^0+/, ''));
  const [pickMd, setPickMd] = useState<Record<string, boolean>>({}); const [pickIt, setPickIt] = useState<Record<string, any>>({}); const [exp, setExp] = useState<Record<string, boolean>>({});
  const [bulk, setBulk] = useState<any[] | null>(null); const [edit, setEdit] = useState<any[] | null>(null); const [dirty, setDirty] = useState<any[] | null>(null);
  const done = () => { setPickMd({}); setPickIt({}); reload(); onChanged(); };
  const groups = useMemo(() => {
    const qq = q.trim().toLowerCase(); const m = new Map<string, { key: string; khach: string; user: string; customer_id: string | null; don: Map<string, any[]> }>();
    for (const t of items) {
      if (f === 'cu' && (ageDays(t.ngay_vao) ?? 0) <= 3) continue;
      if (f === 'bien' && !(() => { const b = bien(t); return b === null || b < BIEN_CAM || b > BIEN_DUYET || locked(t); })()) continue;
      if (qq && ![t.md, t.ten, t.ma_hang, t.ma_kb, t.khach, t.username].some(x => String(x || '').toLowerCase().includes(qq))) continue;
      const k = t.customer_id || t.username || '—'; if (kh && k !== kh) continue;
      const g = m.get(k) || { key: k, khach: t.khach || t.username || 'Chưa gắn khách', user: t.username || '', customer_id: t.customer_id || null, don: new Map() };
      const md = t.md || 'Chưa có ID đơn'; g.don.set(md, [...(g.don.get(md) || []), t]); m.set(k, g);
    }
    return Array.from(m.values()).sort((x, y) => x.khach.localeCompare(y.khach));
  }, [items, q, f, kh]);
  const khOpts = useMemo(() => Array.from(new Map(items.map(t => [t.customer_id || t.username || '—', t.khach || t.username || 'Chưa gắn khách'])).entries()).sort((x, y) => x[1].localeCompare(y[1])) as [string, string][], [items]);
  const donItems = (md: string) => items.filter(t => (t.md || 'Chưa có ID đơn') === md && t.ton > 0.0001 && !locked(t));
  const tien = (ts: any[]) => ts.reduce((x, t) => x + Number(t.ton) * Number(t.gia_khach || 0), 0);
  const chosenMd = Object.keys(pickMd).filter(k => pickMd[k]); const chosenIt = Object.values(pickIt);
  const chosenMdItems = chosenMd.flatMap(donItems);
  const khOf = (ts: any[]) => new Set(ts.map(t => t.customer_id || t.username || '—')).size;
  const bulkClean = () => run(async () => {
    const r = await db.rpc<any[]>('out_clean_orders', { p_mds: null }); const clean = (r || []).filter(x => !x.ly_do).map(x => x.md); const bad = (r || []).filter(x => x.ly_do);
    const its = items.filter(t => clean.includes(t.md) && t.ton > 0.0001);
    if (!its.length) { setDirty(bad); toast.info('Chưa có đơn sạch — xem lý do bên dưới'); return; }
    setDirty(bad.length ? bad : null); setBulk(its);
  });
  const gop = () => { if (khOf(chosenMdItems) > 1) { toast.err('Chỉ gộp các đơn của cùng 1 khách'); return; } setEdit(chosenMdItems); };
  const chonMa = () => { if (khOf(chosenIt) > 1) { toast.err('Chỉ chọn mã của cùng 1 khách'); return; } setEdit(chosenIt); };
  return <>
    <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-4">
      <Stat label="Dòng sẵn sàng xuất" value={items.length} sub={`${groups.reduce((x, g) => x + g.don.size, 0)} đơn · ${groups.length} khách`} />
      <Stat label="Giá trị còn tồn" value={money(tien(items))} sub="theo giá xuất khách" />
      <Stat label="Tồn quá 3 ngày" value={items.filter(t => (ageDays(t.ngay_vao) ?? 0) > 3).length} tone={items.some(t => (ageDays(t.ngay_vao) ?? 0) > 3) ? 'amber' : undefined} onClick={() => setF('cu')} />
      <Stat label="Cần chú ý (biên / khóa)" value={items.filter(t => { const b = bien(t); return locked(t) || (b !== null && (b < BIEN_CAM || b > BIEN_DUYET)); }).length} onClick={() => setF('bien')} /></div>
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Button variant="primary" loading={busy} onClick={bulkClean}>⚡ Xuất hàng loạt các đơn sạch</Button>
      <Input className="max-w-xs" placeholder="🔎 Mã đơn, username, tên hàng, mã khai báo…" value={q} onChange={e => setQ(e.target.value)} />
      <Select className="w-52" placeholder="Tất cả khách" options={khOpts} value={kh} onChange={setKh} />
      <Select className="w-48" placeholder="Tất cả dòng" options={[['cu', 'Tồn quá 3 ngày'], ['bien', 'Biên cảnh báo / đang khóa']] as [string, string][]} value={f} onChange={setF} /></div>
    {dirty && dirty.length > 0 && <details className="mb-3 rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900" open={!bulk}>
      <summary className="cursor-pointer font-semibold">{dirty.length} đơn chưa sạch — xử lý tay</summary>
      <div className="mt-1 grid gap-0.5 sm:grid-cols-2">{dirty.slice(0, 60).map((d: any) => <div key={d.md}><b>{d.md}</b> — {d.ly_do}</div>)}</div></details>}
    {loading && !items.length ? <Loading /> : !groups.length ? <Card><Empty>Không có hàng chờ xuất HĐ. Hàng xuất hiện ở đây khi kế toán nạp HĐ chính thức APT.</Empty></Card> :
    <div className="space-y-3 pb-20">{groups.map(g => { const ds: [string, any[]][] = Array.from(g.don.entries()) as any; const oldest = Math.max(...ds.flatMap(([, ts]) => ts.map(t => ageDays(t.ngay_vao) ?? 0)));
      return <div key={g.key} className="rounded-2xl border border-ink-200 bg-white shadow-soft">
        <div className="flex flex-wrap items-center gap-2 border-b border-ink-100 px-4 py-2.5">
          <div className="min-w-0 flex-1"><div className="font-semibold text-ink-900">{g.khach}</div><div className="text-[11px] text-ink-500">{g.user}{g.user ? ' · ' : ''}{ds.length} đơn sẵn sàng · {money(tien(ds.flatMap(([, ts]) => ts)))}</div></div>
          {oldest > 3 && <Badge color={oldest > 15 ? 'red' : 'amber'}>Tồn {oldest} ngày</Badge>}</div>
        <div className="divide-y divide-ink-100">{ds.map(([md, ts]) => { const ok = ts.filter(t => !locked(t)); const lk = ts.length - ok.length; const isOpen = !!exp[md] || ts.length === 1 && false;
          const bs = ts.map(bien).filter((x): x is number => x !== null); const warn = bs.some(b => b < BIEN_CAM) ? 'dưới 2%' : bs.some(b => b > BIEN_DUYET) ? 'trên 4% — sẽ chờ duyệt' : '';
          const noGia = ts.some(t => !Number(t.gia_khach));
          return <div key={md}>
            <div className="flex flex-wrap items-center gap-3 px-4 py-2">
              <input type="checkbox" className="h-5 w-5" disabled={!ok.length || md === 'Chưa có ID đơn'} checked={!!pickMd[md]} onChange={e => setPickMd(p => ({ ...p, [md]: e.target.checked }))} />
              <button className="min-w-0 flex-1 text-left" onClick={() => setExp(x => ({ ...x, [md]: !x[md] }))}>
                <div className="text-sm"><b className="text-ink-900">{md}</b> <span className="text-ink-500">· {ts.length} mã {isOpen ? '▴' : '▾'}</span></div>
                <div className="text-[11px] text-ink-500">{money(tien(ts))}{ts[0]?.so_hd_vao ? ` · HĐ vào ${Array.from(new Set(ts.map(hdOf).filter(Boolean))).join(', ')} · ${fmtDate(ts[0].ngay_vao)}` : ''}</div>
                <div className="mt-0.5 flex flex-wrap gap-1">{ts.slice(0, 8).map(t => <span key={t.id} className={cx('rounded px-1.5 py-px font-mono text-[11px]', locked(t) ? 'bg-red-50 text-red-700' : 'bg-brand-50 text-brand-800')}>{t.ma_hang}{t.part > 1 ? ` (${t.part})` : ''}</span>)}{ts.length > 8 && <span className="text-[11px] text-ink-400">+{ts.length - 8} mã</span>}</div></button>
              {lk > 0 && <Badge color="red">{lk} mã lệch — khóa</Badge>}{warn && <Badge color="amber">Biên {warn}</Badge>}{noGia && <Badge color="red">Thiếu giá</Badge>}
              <Button size="sm" disabled={!ok.length || md === 'Chưa có ID đơn'} onClick={() => setBulk(ok)}>Xuất theo đơn</Button></div>
            {isOpen && <div className="bg-ink-50/60 px-4 pb-2 pl-12">{ts.map(t => { const b = bien(t);
              return <label key={t.id} className={cx('flex items-start gap-3 border-t border-ink-100 py-1.5 text-xs', locked(t) && 'opacity-60')}>
                <input type="checkbox" className="mt-0.5 h-4 w-4" disabled={locked(t)} checked={!!pickIt[t.id]} onChange={e => setPickIt(p => { const x = { ...p }; if (e.target.checked) x[t.id] = t; else delete x[t.id]; return x; })} />
                <div className="min-w-0 flex-1"><div className="font-semibold text-ink-800">{t.ma_kb || t.ma_hang} <span className="font-normal text-ink-400">· {t.ma_hang}</span></div>
                  <div className="line-clamp-1 text-ink-600" title={t.ten}>{t.ten}</div>
                  {locked(t) && <div className="font-semibold text-red-600">⛔ {t.lech_note || 'Lệch so với nháp — chờ kế toán'}</div>}</div>
                <div className="w-24 text-right tabular-nums">{num(t.ton, 2)} {t.dvt}</div>
                <div className="w-24 text-right"><Money v={t.gia_khach} /><div className={cx('text-[10px]', b !== null && (b < BIEN_CAM || b > BIEN_DUYET) ? 'font-semibold text-amber-700' : 'text-ink-400')}>{b === null ? '' : 'biên ' + pctTxt(b)}</div></div></label>; })}</div>}
          </div>; })}</div></div>; })}</div>}
    {(chosenMd.length > 0 || chosenIt.length > 0) && <div className="fixed inset-x-3 bottom-3 z-30 mx-auto flex max-w-3xl flex-wrap items-center gap-2 rounded-2xl border border-ink-300 bg-white px-4 py-3 shadow-lg">
      <div className="min-w-0 flex-1 text-sm">{chosenMd.length > 0 && <div><b>{chosenMd.length} đơn</b> · {money(tien(chosenMdItems))} · {khOf(chosenMdItems)} khách</div>}
        {chosenIt.length > 0 && <div><b>{chosenIt.length} mã</b> · {money(tien(chosenIt))}</div>}</div>
      {chosenMd.length > 1 && (khOf(chosenMdItems) > 1 ? <span className="text-xs text-amber-700">Khác khách — không gộp được 1 HĐ</span> : <Button variant="primary" onClick={gop}>Gộp {chosenMd.length} đơn → 1 HĐ</Button>)}
      {chosenMd.length > 0 && <Button onClick={() => setBulk(chosenMdItems)}>Mỗi đơn 1 HĐ ({chosenMd.length})</Button>}
      {chosenIt.length > 0 && <Button variant={chosenMd.length ? undefined : 'primary'} onClick={chonMa}>Xuất {chosenIt.length} mã → 1 HĐ</Button>}
      <button className="text-xs text-ink-500 underline" onClick={() => { setPickMd({}); setPickIt({}); }}>Bỏ chọn</button></div>}
    {bulk && <BulkInvoices items={bulk} onClose={() => { setBulk(null); done(); }} onDone={() => reload()} />}
    {edit && <InvoiceEditor items={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); done(); }} />}
  </>;
}

// ================= KẾ TOÁN =================
export function HdKeToan() {
  const a = useApp(); const acc = a.isAdmin || a.has('ke_toan'); const { busy, run } = useAction();
  const [rev, setRev] = useState(0); const reload = () => setRev(x => x + 1);
  const { query } = useRoute();
  const [imp, setImp] = useState<'' | 'xe' | 'hd' | 'ds' | 'xls'>(''); const [pdf, setPdf] = useState(false); const [open, setOpen] = useState<string | null>(query.inv || null); const [lechT, setLechT] = useState<any>(null);
  React.useEffect(() => { if (query.inv) setOpen(query.inv); }, [query.inv]);
  const close = () => { setOpen(null); if (location.hash.includes('inv=')) go('/hd/kt'); };
  const { data: st } = useLoad(() => db.rpc<any>('out_items_stats', { p_mode: 'acc' }), [rev]);
  const { data: trucks } = useLoad(() => db.from<any[]>('acc_trucks').select('id,name,truck_date,stats,created_at,is_test').order('created_at', { asc: false }).limit(5), [rev]);
  const { data: blk } = useLoad(() => db.from<any[]>('acc_lines').select('truck_id,status,sale_id').in('status', ['blocked', 'replied', 'pending_approval']).eq('is_test', false).limit(5000), [rev]);
  const { data: lech, loading: lLoad } = useLoad(async () => {
    const [x, y] = await Promise.all(['lech', 'chua_ghep'].map(f => db.rpc<any>('out_items_page', { p: { mode: 'acc', f, offset: 0, limit: 30 } })));
    return [...(x?.rows || []), ...(y?.rows || [])];
  }, [rev]);
  const moi = useInv(['cho_duyet_gia', 'cho_nhap'], { flag: '' }, [rev]);
  // Bản 31: API MISA chạy song song cách làm tay
  const api = misaOn(a.settings); const mcfg = misaCfgOf(a.settings);
  const [pick, setPick] = useState<Record<string, boolean>>({}); const [runner, setRunner] = useState<string[] | null>(null);
  const onSel = (id: string, on: boolean) => setPick(p => ({ ...p, [id]: on }));
  const ky = useInv(['xac_nhan_ky'], {}, [rev]);
  const traSua = useInv(['tra_sua', 'da_nhap'], {}, [rev]);
  if (!acc) return <Layout title="Bàn làm việc kế toán"><Card>Chỉ Kế toán, BGĐ.</Card></Layout>;
  const S = st || {}; const rows = moi.data || [];
  const chuaExport = rows.filter(v => v.status === 'cho_nhap' && !v.misa_at); const choPdf = rows.filter(v => v.status === 'cho_nhap' && v.misa_at); const duyet = rows.filter(v => v.status === 'cho_duyet_gia');
  const apiReady = chuaExport.filter(v => !v.misa || ['loi', 'da_xoa'].includes(v.misa.st) || v.misa.cu);
  const picked = chuaExport.filter(v => pick[v.id]).map(v => v.id);
  const taoNhap = () => { const ids = picked.length ? picked : apiReady.map(v => v.id); if (!ids.length) { toast.info('Không có phiếu sẵn sàng tạo nháp'); return; } setRunner(ids); };
  const doMisa = () => run(async () => { const r = await misaCall<any>('sync'); reload(); toast.ok(`Đã dò MISA ${r.checked || 0} nháp: ${r.phat_hanh || 0} đã phát hành${r.bi_xoa ? ` · ${r.bi_xoa} bị xóa trên web` : ''}`); });
  const layPdf = (v: any) => run(async () => { await misaCall('pdf', { hd_id: v.misa.hd_id }); reload(); }, 'Đã lấy PDF nháp — đã báo sale');
  const exportAll = () => run(async () => { const n = await exportMisaFile(null, id => a.personName(id)); reload(); toast.ok(`Đã export ${n} yêu cầu — nhập vào MISA, tạo nháp, tải PDF về khối ③`); });
  // Bản 28: yêu cầu đã export nhưng chưa có PDF nháp vẫn ở khối ②, export lại được (từng phiếu hoặc tất cả)
  const reExport = (ids: string[]) => run(async () => { const n = await exportMisaFile(ids, id => a.personName(id)); reload(); toast.ok(`Đã export lại ${n} yêu cầu`); });
  const approve = (v: any) => run(async () => { const note = await ask({ title: `Duyệt giá ${v.code} — biên ${pctTxt(Number(v.bien_max))}`, input: { label: 'Ghi chú (không bắt buộc)' }, ok: 'Duyệt' }); if (note === null) return;
    await db.rpc('out_price_approve', { p_ids: [v.id], p_note: note || null }); reload(); }, 'Đã duyệt giá');
  const nBlk = (blk || []).filter(l => l.status === 'blocked').length;
  return <Layout title="Bàn làm việc kế toán" actions={<div className="flex gap-2">{api && <Button loading={busy} onClick={() => run(async () => { const n = await exportMisaDoiChieu(id => a.personName(id)); toast.ok(`Đã xuất ${n} lần tạo nháp`); })}>⬇ Excel đối chiếu ERP ↔ MISA</Button>}<Button onClick={() => go('/acc')}>Danh sách xe</Button></div>}>
    <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-5">
      <Stat label="Dòng xe chờ sale xử lý" value={nBlk} tone={nBlk ? 'red' : undefined} onClick={() => go('/acc')} sub="thiếu đơn / giá khách / sale" />
      <Stat label="Dòng HĐ lệch nháp — khóa" value={S.lech ?? '…'} tone={S.lech ? 'red' : undefined} />
      <Stat label="Dòng HĐ chưa ghép nháp" value={S.chua_ghep ?? '…'} tone={S.chua_ghep ? 'amber' : undefined} />
      <Stat label="Yêu cầu chưa export" value={chuaExport.length} tone={chuaExport.length ? 'amber' : undefined} />
      <Stat label="Chờ ký" value={(ky.data || []).length} tone={(ky.data || []).length ? 'amber' : undefined} /></div>

    <Block n="1" title="Xe & HĐ APT" sub="Chu kỳ 1: nạp nháp APT + file xe → hệ thống ghép, tính biên. Chu kỳ 2: nạp HĐ chính thức APT → ghép về nháp, đối chiếu từng dòng."
      actions={<><Button variant="primary" onClick={() => setImp('xe')}>⇪ ① Nạp nháp APT + file xe</Button><Button variant="dark" onClick={() => setImp('hd')}>⇪ ② Nạp HĐ chính thức APT</Button><Button onClick={() => setImp('xls')}>⬇ Excel HĐ chính thức · VAT dự kiến</Button><Button onClick={() => setImp('ds')}>⇪ Đơn hàng · pháp nhân</Button></>}>
      <div className="flex flex-wrap items-center gap-2 border-b border-ink-100 bg-ink-50/60 px-4 py-2 text-xs text-ink-600">File mẫu: <MauBtn k="xe" /><MauBtn k="apt" /><MauBtn k="hd" /><MauBtn k="buyers" /><MauBtn k="orders" />
        <span className="text-ink-400">Đọc theo tiêu đề cột — thêm / đổi thứ tự cột vẫn được.</span></div>
      {(trucks || []).length > 0 && <div className="flex flex-wrap gap-2 border-b border-ink-100 px-4 py-2 text-xs">Xe gần đây: {(trucks || []).map(t => { const n = (blk || []).filter(l => l.truck_id === t.id && l.status === 'blocked').length;
        return <button key={t.id} onClick={() => go('/acc?truck=' + t.id)} className="rounded-lg border border-ink-200 px-2 py-1 hover:border-brand-400"><b>{t.name}</b>{t.is_test ? ' (thử)' : ''} · {t.stats?.apt ?? 0} dòng · khớp mã {t.stats?.khop_ma ?? '—'} · theo đơn {t.stats?.ghep_don ?? '—'}{n ? <span className="ml-1 font-semibold text-red-600">· {n} chờ sale</span> : ''}</button>; })}</div>}
      <div className="px-4 pt-3 text-sm font-semibold text-ink-800">Dòng HĐ cần kế toán xử lý</div>
      {lLoad ? <Loading /> : !(lech || []).length ? <div className="px-4 py-4 text-sm text-ink-400">Không có dòng lệch hay chưa ghép. 👍</div> :
        <div className="divide-y divide-ink-100">{(lech || []).map(t => <div key={t.id} className="flex flex-wrap items-center gap-3 px-4 py-2 text-sm">
          <div className="w-44 text-xs font-semibold">{t.ma_hang}<div className="font-normal text-ink-500">HĐ {t.so_hd_vao} · {fmtDate(t.ngay_vao)}</div></div>
          <div className="min-w-[220px] flex-1"><div className="line-clamp-1">{t.ten}</div><div className="text-xs">{locked(t) ? <span className="font-semibold text-red-600">⛔ {t.lech_note}</span> : <span className="text-amber-700">Chưa ghép được dòng nháp (tên / SL không khớp)</span>}</div></div>
          <div className="w-24 text-right text-xs">SL {num(t.sl_nhap, 2)}<div><Money v={t.dg_nhap} /></div></div>
          <Button size="sm" variant={locked(t) ? 'danger' : undefined} onClick={() => setLechT(t)}>{locked(t) ? 'Xử lý lệch' : 'Ghép tay'}</Button></div>)}</div>}
    </Block>

    <Block n="2" title={api ? 'Yêu cầu mới → tạo nháp MISA' : 'Yêu cầu mới → export MISA'} sub={<>Chỉ yêu cầu đã gửi (biên 2–4%, hoặc đã được duyệt giá). Tạo nháp / export xong, sale không hủy được nữa. {api ? <><b>⚡ API</b>: tick phiếu (hoặc để trống = mọi phiếu sẵn sàng) → ERP kiểm, gửi MISA, lấy PDF, báo sale. <b>Làm tay</b> khi MISA lỗi: Excel → nhập MISA → khối ③. </> : <>Yêu cầu <b>đã export</b> vẫn nằm đây tới khi nạp PDF nháp. </>}<b>{chuaExport.length}</b> chưa tạo nháp · <b>{choPdf.length}</b> chờ PDF nháp.</>}
      actions={<>{api && picked.length > 0 && <button className="text-xs text-ink-500 underline" onClick={() => setPick({})}>Bỏ chọn ({picked.length})</button>}
        {api && chuaExport.length > 0 && picked.length < chuaExport.length && <button className="text-xs text-brand-700 underline" onClick={() => setPick(Object.fromEntries(chuaExport.map(v => [v.id, true])))}>Chọn tất cả ({chuaExport.length})</button>}
        {choPdf.length > 0 && <Button loading={busy} onClick={() => reExport(choPdf.map(v => v.id))}>↻ Export lại đã export ({choPdf.filter(v => !v.misa || v.misa.st === 'da_xoa').length})</Button>}
        <Button variant={api ? undefined : 'primary'} loading={busy} disabled={!chuaExport.length} onClick={api && picked.length ? () => reExport(picked) : exportAll}>⬇ {api ? 'Excel nhập MISA — làm tay' : 'Export file nhập MISA'} ({api && picked.length ? picked.length : chuaExport.length})</Button>
        {api && <Button variant="primary" disabled={!chuaExport.length} onClick={taoNhap}>⚡ Tạo nháp MISA ({picked.length || apiReady.length})</Button>}</>}>
      {duyet.length > 0 && <div className="border-b border-ink-100 bg-red-50/40"><div className="px-4 pt-2 text-xs font-semibold text-red-700">Chờ duyệt giá (biên &gt; 4%) — 1 người duyệt là đủ</div>
        <InvRows rows={duyet} loading={false} onOpen={setOpen} empty="" action={v => <Button size="sm" variant="primary" onClick={() => approve(v)}>Duyệt</Button>} /></div>}
      {chuaExport.length > 0 && <div className="px-4 pt-2 text-xs font-semibold text-amber-700">Chưa export ({chuaExport.length})</div>}
      <InvRows rows={chuaExport} loading={moi.loading} onOpen={setOpen} empty={choPdf.length ? '' : 'Không có yêu cầu mới chờ export'} sel={api ? pick : undefined} onSel={api ? onSel : undefined} />
      {choPdf.length > 0 && <div className="border-t border-ink-100"><div className="px-4 pt-2 text-xs font-semibold text-ink-600">Đã export — chờ nạp PDF nháp ({choPdf.length})</div>
        <InvRows rows={choPdf} loading={false} onOpen={setOpen} empty="" action={v => v.misa && v.misa.st === 'da_tao' && !v.misa.cu ? (v.misa.khop === false ? <Button size="sm" onClick={() => setOpen(v.id)}>Xử lý lệch</Button> : <Button size="sm" variant="primary" loading={busy} onClick={() => layPdf(v)}>⬇ Lấy PDF</Button>) : <Button size="sm" onClick={() => reExport([v.id])}>Export lại</Button>} /></div>}
    </Block>

    <Block n="3" title="PDF nháp từ MISA" sub={<>Tải PDF nháp hàng loạt, tên file dạng <code>NHAP_MST_TổngTiền_yyyymmdd</code> — ERP khớp theo MST + tổng tiền và báo sale.</>}
      actions={<Button variant="dark" onClick={() => setPdf(true)}>⇪ Tải PDF nháp / đã ký</Button>}>
      <div className="px-4 py-3 text-sm text-ink-600">{choPdf.length ? <><b>{choPdf.length}</b> yêu cầu đã export đang chờ PDF nháp (danh sách ở khối ②). Nạp PDF xong, yêu cầu tự rời khối ② và báo sale.</> : 'Không có yêu cầu đã export chờ PDF nháp.'}</div>
      {(traSua.data || []).filter(v => v.status === 'tra_sua').length > 0 && <div className="border-t border-ink-100"><div className="px-4 pt-2 text-xs font-semibold text-red-700">Sale trả sửa — chờ sale sửa và gửi lại (xóa nháp cũ trên MISA)</div>
        <InvRows rows={(traSua.data || []).filter(v => v.status === 'tra_sua')} loading={false} onOpen={setOpen} empty="" /></div>}
      {(traSua.data || []).filter(v => v.status === 'da_nhap').length > 0 && <div className="border-t border-ink-100 px-4 py-2 text-xs text-ink-500">{(traSua.data || []).filter(v => v.status === 'da_nhap').length} yêu cầu có nháp, đang chờ sale duyệt.</div>}
    </Block>

    <Block n="4" title="Chờ ký — sale đã chốt" sub={<>Ký trên MISA đúng bản sale chốt → dán <b>mã tra cứu</b> MISA vào ô của phiếu → bấm <b>✓ Đã ký</b>. Sale được báo và bấm mã để xem HĐ.{api && <> Nháp tạo bằng API: ERP <b>tự dò MISA 15 phút/lần</b> (7h–21h) và tự chuyển Đã ký{mcfg.last_sync_at ? ` — lần dò gần nhất ${fmtDateTime(mcfg.last_sync_at)}` : ''}.</>}</>}
      actions={api ? <Button loading={busy} onClick={doMisa}>⟳ Dò MISA ngay</Button> : undefined}>
      <InvRows rows={ky.data || []} loading={ky.loading} onOpen={setOpen} empty="Không có yêu cầu chờ ký" action={v => <SignBox v={v} onDone={reload} compact />} />
    </Block>

    {imp === 'xe' && <ImportTruck onClose={() => setImp('')} onDone={id => { setImp(''); go('/acc?truck=' + id); }} />}
    {imp === 'hd' && <ImportHd onClose={() => setImp('')} onDone={() => { setImp(''); reload(); }} />}
    {imp === 'xls' && <ExportHdModal onClose={() => setImp('')} />}
    {imp === 'ds' && <ImportSo onClose={() => setImp('')} onDone={() => { setImp(''); reload(); }} />}
    {pdf && <UploadHdPdf onClose={() => setPdf(false)} onDone={() => { setPdf(false); reload(); }} />}
    {lechT && <LechModal t={lechT} onClose={() => setLechT(null)} onDone={() => { setLechT(null); reload(); }} />}
    {open && <InvoiceDetail id={open} acc onClose={close} onChanged={reload} />}
    {runner && <MisaRun ids={runner} onClose={() => { setRunner(null); setPick({}); }} onDone={reload} />}
  </Layout>;
}

// ================= QUẢN LÝ =================
export function HdQuanLy() {
  const a = useApp(); const { run } = useAction(); const [rev, setRev] = useState(0); const [open, setOpen] = useState<string | null>(null);
  const approver = a.isAdmin || a.has('ke_toan', 'tp_kd', 'bgd') || (a.settings.accounting?.approver_ids || []).includes(a.me.id);
  const duyet = useInv(['cho_duyet_gia'], {}, [rev]);
  const approve = (ids: string[]) => run(async () => { await db.rpc('out_price_approve', { p_ids: ids, p_note: null }); setRev(x => x + 1); }, 'Đã duyệt giá');
  if (!a.isLead && !approver) return <Layout title="Duyệt giá & tồn HĐ"><Card>Dành cho Trưởng nhóm / Trưởng phòng / Kế toán.</Card></Layout>;
  const rows = duyet.data || [];
  return <Layout title="Duyệt giá & tồn HĐ">
    <Block title="Chờ duyệt giá" sub="Yêu cầu có dòng biên trên 4% so với giá APT. Dưới 2% hệ thống đã chặn, 2–4% không cần duyệt."
      actions={approver && rows.length > 1 ? <Button variant="primary" onClick={() => approve(rows.map(v => v.id))}>Duyệt tất cả ({rows.length})</Button> : null} tone={rows.length ? 'amber' : undefined}>
      <InvRows rows={rows} loading={duyet.loading} onOpen={setOpen} empty="Không có yêu cầu chờ duyệt giá" action={approver ? v => <Button size="sm" variant="primary" onClick={() => approve([v.id])}>Duyệt</Button> : undefined} />
    </Block>
    <Block title="Tồn HĐ đầu vào chưa xuất" sub="Hàng đã có HĐ APT nhưng sale chưa tạo yêu cầu xuất HĐ."><div className="p-4"><TonReport /></div></Block>
    {open && <InvoiceDetail id={open} acc={a.isAdmin || a.has('ke_toan')} onClose={() => setOpen(null)} onChanged={() => setRev(x => x + 1)} />}
  </Layout>;
}

/** Bản 28b: kế toán xuất Excel toàn bộ dòng HĐ chính thức APT đã nạp — kiểm tiền VAT Nam Trung dự kiến xuất cho khách */
function ExportHdModal({ onClose }: { onClose: () => void }) {
  const a = useApp(); const { busy, run } = useAction();
  const { data: hds, loading } = useLoad(() => listHdVao(), []);
  const [pick, setPick] = useState<string[] | null>(null);
  const sel = pick ?? (hds && hds.length ? [hds[0].so] : []);
  const go2 = (all: boolean) => run(async () => { const n = await exportHdChinhThuc(all ? null : sel, id => a.personName(id)); onClose(); toast.ok(`Đã xuất ${n} dòng HĐ`); });
  return <Modal open onClose={onClose} title="Excel HĐ chính thức APT · VAT Nam Trung dự kiến" size="lg"
    footer={<><Button loading={busy} onClick={() => go2(true)}>Xuất tất cả HĐ ({(hds || []).reduce((x, h) => x + h.n, 0)} dòng)</Button>
      <Button variant="primary" loading={busy} disabled={!sel.length} onClick={() => go2(false)}>⬇ Xuất {sel.length} HĐ đã chọn</Button></>}>
    <p className="mb-3 text-sm text-ink-600">Mỗi dòng = 1 mã hàng trên HĐ ký APT, kèm <b>Mã đơn hàng</b>, khách, sale, giá xuất dự kiến, <b>VAT Nam Trung xuất</b> (SL × giá xuất × thuế suất), tổng theo mã đơn, phiếu đã lập, tồn, lệch nháp và cột cảnh báo. Cuối file có dòng tổng cộng.</p>
    {loading ? <Loading /> : !(hds || []).length ? <Empty>Chưa nạp HĐ chính thức APT nào</Empty> :
      <Chips options={(hds || []).map(h => [h.so, `HĐ ${h.so}${h.ngay ? ' · ' + fmtDate(h.ngay) : ''} · ${h.n} dòng`] as [string, string])} value={sel} onChange={setPick} />}
  </Modal>;
}
