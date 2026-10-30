// Kế toán – Hóa đơn: đối soát xe APT (B1) + HĐ đầu vào XML (B2) + ghép tên sale
import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, Select, Stat, StatusChips, Table, Tabs, Td, Textarea, ask, toast, useAction, useLoad } from '../../components/ui';
import { Pager, usePager } from '../../components/Pager';
import { db, fetchAll } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { readTable, writeXlsx } from '../../lib/xlsx';
import { fmtDate, fmtDateTime, money, num, stripVN, today } from '../../lib/format';
import { aptPriceMsg, DEFAULT_ACC_CFG, INV_RESULT, InvResult, judgeInvoiceLine, LUONG, norm, normMd, parseApt, parseInvoiceXml, parseKhaiBao, parseTkn, reconcile } from '../../lib/doisoat';
import { driveReady, saveToDrive } from '../../lib/drive';
import { bienTone, dueTxt, lineName, LuongBadge, Money, pctTxt, REPLY, ST, StatusBadge } from './common';

export const useAccCfg = () => { const a = useApp(); return { ...DEFAULT_ACC_CFG, ...(a.settings.accounting || {}) }; };
const isAcc = (a: ReturnType<typeof useApp>) => a.isAdmin || a.has('ke_toan');

export default function Acc() {
  const a = useApp(); const { query } = useRoute(); const [tab, setTab] = useState('trucks');
  if (!isAcc(a)) return <Layout title="Kế toán – Hóa đơn"><Card>Chỉ Kế toán, BGĐ. Sale xem ở mục “Việc HĐ của tôi”.</Card></Layout>;
  if (query.truck) return <TruckDetail id={query.truck} />;
  return (
    <Layout title="Kế toán – Hóa đơn">
      <Tabs value={tab} onChange={setTab} tabs={[['trucks', 'Đối soát xe APT'], ['invoices', 'HĐ đầu vào (XML)'], ['track', 'Theo dõi HĐ chưa về · xuất muộn'], ['sales', 'Ghép tên sale']]} />
      <div className="mt-4">{tab === 'trucks' && <Trucks />}{tab === 'invoices' && <Invoices />}{tab === 'track' && <Track />}{tab === 'sales' && <SaleMap />}</div>
    </Layout>
  );
}

// ============ Danh sách xe ============
function Trucks() {
  const [imp, setImp] = useState(false);
  const { data, loading, reload } = useLoad(() => db.from<any[]>('acc_trucks').select('id,name,truck_date,stats,status,created_at,files,is_test').order('created_at', { asc: false }).limit(200), []);
  const { data: open } = useLoad(() => db.from<any[]>('acc_lines').select('truck_id,status').in('status', ['blocked', 'replied', 'pending_approval']).limit(5000), []);
  const cnt = useMemo(() => { const m = new Map<string, Record<string, number>>(); (open || []).forEach(l => { const x = m.get(l.truck_id) || {}; x[l.status] = (x[l.status] || 0) + 1; m.set(l.truck_id, x); }); return m; }, [open]);
  const pg = usePager('acc_trucks', []); const rows = data || [];
  return <>
    <div className="mb-3 flex flex-wrap items-center gap-2"><Button variant="primary" onClick={() => setImp(true)}>+ Nạp xe mới (3 file)</Button>
      <span className="text-xs text-ink-500">File khai báo hệ thống + file check APT + tờ khai nháp TKN → hệ thống tự chấm từng dòng, sale chỉ xử lý dòng bị chặn.</span></div>
    <Card bodyClass="p-0">{loading ? <Loading /> : !rows.length ? <Empty>Chưa nạp xe nào</Empty> :
      <Table head={['Xe', 'Ngày', 'Dòng APT', 'Tự chốt', 'Còn chặn', 'Sale đã trả lời', 'Chờ duyệt', 'Tiền hàng APT', 'Nạp lúc', '']}>{pg.slice(rows).map(t => { const c = cnt.get(t.id) || {}; const s = t.stats || {};
        return <tr key={t.id} className="cursor-pointer hover:bg-ink-50" onClick={() => go(`/acc?truck=${t.id}`)}>
          <Td className="font-semibold text-ink-900">{t.name}</Td><Td>{fmtDate(t.truck_date)}</Td><Td className="text-right">{s.apt ?? ''}</Td>
          <Td className="text-right text-emerald-700">{s.ok ?? ''}{s.apt ? <span className="ml-1 text-[11px] text-ink-400">{Math.round((s.ok || 0) / (s.apt || 1) * 100)}%</span> : ''}</Td>
          <Td className="text-right">{c.blocked ? <b className="text-red-600">{c.blocked}</b> : <span className="text-ink-300">0</span>}</Td>
          <Td className="text-right">{c.replied || ''}</Td><Td className="text-right">{c.pending_approval || ''}</Td>
          <Td className="text-right"><Money v={s.tt_apt} /></Td><Td className="text-xs text-ink-500">{fmtDateTime(t.created_at)}</Td>
          <Td>{t.is_test ? <Badge color="amber">Nạp thử</Badge> : t.status === 'closed' ? <Badge>Đã đóng</Badge> : <Badge color="blue">Đang xử lý</Badge>}</Td></tr>; })}</Table>}
      <Pager p={pg} total={rows.length} /></Card>
    {imp && <ImportTruck onClose={() => setImp(false)} onDone={id => { setImp(false); reload(); go(`/acc?truck=${id}`); }} />}
  </>;
}

// ============ Nạp 3 file + chấm ============
type Dir = { id: string; full_name: string; sale_aliases: string[] }[];
export function useSaleMatcher() {
  const { data } = useLoad(() => db.rpc<Dir>('acc_sale_directory'), []);
  return useMemo(() => {
    const m = new Map<string, { id: string; name: string }>();
    (data || []).forEach(p => [p.full_name, ...(p.sale_aliases || [])].forEach(x => x && m.set(norm(x), { id: p.id, name: p.full_name })));
    return { ready: !!data, dir: data || [], find: (s: string | null | undefined) => (s ? m.get(norm(s)) || null : null) };
  }, [data]);
}

function ImportTruck({ truck, onClose, onDone }: { truck?: any; onClose: () => void; onDone: (id: string) => void }) {
  const a = useApp(); const cfg = useAccCfg(); const sm = useSaleMatcher(); const { busy, run } = useAction();
  const [name, setName] = useState(truck?.name || ''); const [date, setDate] = useState(truck?.truck_date || today());
  const [files, setFiles] = useState<Record<string, File | null>>({ kb: null, apt: null, tkn: null });
  const [res, setRes] = useState<any>(null); const [err, setErr] = useState('');
  const [xt, setXt] = useState<string>((truck?.md_xuat_thang || []).join(', ')); const [test, setTest] = useState(false);
  const [target, setTarget] = useState<any>(truck || null); // nạp lại vào xe cũ khi phát hiện trùng
  const xtList = () => Array.from(new Set(xt.split(/[^A-Za-z0-9]+/).map(normMd).filter(Boolean)));
  const analyze = async () => {
    setErr(''); setRes(null);
    try {
      if (!files.kb || !files.apt) throw new Error('Chọn đủ file khai báo hệ thống và file check APT');
      const [kbRows, aptRows, tkRows] = await Promise.all([readTable(files.kb), readTable(files.apt), files.tkn ? readTable(files.tkn) : Promise.resolve(null)]);
      const sys = parseKhaiBao(kbRows); const apt = parseApt(aptRows); const tk = tkRows ? parseTkn(tkRows) : [];
      const r = reconcile(apt.rows, sys, tk, { ...cfg, md_xuat_thang: xtList() }, s => sm.find(s)?.id || null);
      // dòng kế toán đã đánh dấu xuất thẳng ở lần nạp trước
      const keys = new Set<string>(target?.xt_keys || []);
      r.lines.forEach(l => { if (keys.has(l.line_key)) Object.assign(l, { luong: 'C', status: 'info', level: 3, issues: [], phan_hoi: l.apt_stt ? 'XUẤT THẲNG' : '', notes: ['Kế toán đánh dấu APT xuất thẳng.', ...l.notes] }); });
      r.stats.ok = r.lines.filter(l => l.status === 'ok').length; r.stats.blocked = r.lines.filter(l => l.status === 'blocked').length; r.stats.info = r.lines.filter(l => l.status === 'info').length;
      // chống trùng: mã HH / file khai báo đã có ở xe khác
      const hhs = Array.from(new Set(apt.rows.map(x => x.hh).filter(Boolean))).slice(0, 150);
      const dupL: any[] = hhs.length ? await db.from<any[]>('acc_lines').select('truck_id,acc_trucks(id,name,truck_date,is_test,md_xuat_thang,xt_keys)').in('hh', hhs).limit(2000) : [];
      const dupF: any[] = await db.from<any[]>('acc_trucks').select('id,name,truck_date,is_test,md_xuat_thang,xt_keys').eq('files->>kb', files.kb.name).limit(5);
      const dups = new Map<string, any>(); dupL.forEach(x => x.acc_trucks && dups.set(x.truck_id, x.acc_trucks)); dupF.forEach(x => dups.set(x.id, x));
      if (target) dups.delete(target.id);
      r.stats.apt_header_total = apt.total;
      if (!tkRows) r.warnings.push('Chưa có tờ khai nháp: chưa so được thuế NK theo tờ khai.');
      if (apt.total && Math.abs(apt.total - r.stats.tt_apt) > 1000) r.warnings.push(`Tổng tiền dòng đầu file APT ${money(apt.total)} khác tổng cộng các dòng ${money(r.stats.tt_apt)} (do giá NOTE/đề xuất).`);
      const unmapped = Array.from(new Set(r.lines.filter(l => l.sale_name && !sm.find(l.sale_name) && (l.md || l.luong === 'A')).map(l => l.sale_name!)));
      setRes({ ...r, unmapped, sysCount: sys.length, dups: Array.from(dups.values()) });
      if (!name) setName('Xe ' + (date ? fmtDate(date).slice(0, 5) : ''));
    } catch (e: any) { setErr(e.message || String(e)); }
  };
  const save = () => run(async () => {
    const lines = res.lines.map((l: any) => ({ ...l, sale_id: sm.find(l.sale_name)?.id || sm.find(l.sale_apt)?.id || null, sale_acc: sm.find(l.sale_name)?.name || null }));
    const nm = name || 'Xe ' + fmtDate(date);
    const id = await db.rpc<string>('acc_truck_save', { p_truck: target?.id || null, p_info: { name: nm, truck_date: date, stats: res.stats, warnings: res.warnings,
      is_test: target ? undefined : test, md_xuat_thang: xtList(),
      files: { kb: files.kb?.name, apt: files.apt?.name, tkn: files.tkn?.name, by: a.me.full_name } }, p_lines: lines });
    // lưu 3 file gốc lên Drive theo từng xe
    if (driveReady(a.settings.drive)) {
      const links: Record<string, string> = {}; const folder = `Ke toan/Doi soat xe/${(date || today()).slice(0, 7)}/${stripVN(nm).replace(/[^A-Za-z0-9 _-]+/g, '-')}`;
      for (const k of ['kb', 'apt', 'tkn']) { const f = files[k]; if (f) { try { links[k] = await saveToDrive(a.settings.drive, f, f.name, folder); } catch (e: any) { toast.err('Lưu Drive: ' + e.message); break; } } }
      if (Object.keys(links).length) await db.from('acc_trucks').update({ file_links: links }).eq('id', id);
    }
    const n = await db.rpc<number>('acc_relink_truck', { p_truck: id }).catch(() => 0); if (n) toast.info(`${n} dòng HĐ APT đã về trước được ghép vào xe này`);
    onDone(id);
  }, target ? 'Đã nạp lại, giữ nguyên trả lời của sale' : test ? 'Đã lưu xe nạp thử — sale chưa thấy' : 'Đã lưu đối soát, đã báo sale dòng bị chặn');
  const F = ({ k, l, hint }: { k: string; l: string; hint: string }) => <Field label={l} hint={hint}>
    <label className={cx('flex cursor-pointer items-center gap-2 rounded-xl border border-dashed px-3 py-2 text-sm', files[k] ? 'border-emerald-400 bg-emerald-50 text-emerald-800' : 'border-ink-300 hover:border-brand-400')}>
      <input type="file" accept=".xlsx,.csv" className="hidden" onChange={e => { setFiles(f => ({ ...f, [k]: e.target.files?.[0] || null })); setRes(null); }} />
      {files[k] ? '✓ ' + files[k]!.name : '⇪ Chọn file .xlsx'}</label></Field>;
  return <Modal open onClose={onClose} size="lg" title={truck ? `Nạp lại file · ${truck.name}` : 'Nạp xe mới'}
    footer={<>{res && <Button variant="primary" loading={busy} disabled={!sm.ready} onClick={save}>{target && !truck ? `Nạp lại vào “${target.name}”` : test && !target ? 'Lưu xe nạp thử' : `Lưu & báo sale (${res.stats.blocked} dòng chặn)`}</Button>}{!res && <Button variant="dark" disabled={!sm.ready} onClick={analyze}>Phân tích</Button>}</>}>
    <div className="grid gap-3 sm:grid-cols-2"><Field label="Tên xe"><Input value={name} placeholder="VD: Xe 25/10" onChange={e => setName(e.target.value)} /></Field>
      <Field label="Ngày xe"><Input type="date" value={date} onChange={e => setDate(e.target.value)} /></Field></div>
    <div className="mt-3 grid gap-3 sm:grid-cols-3">
      <F k="kb" l="1. File khai báo hệ thống *" hint="Xuất từ NamtrungLog (KhaiBao_XH…)" /><F k="apt" l="2. File check APT *" hint="APT gửi (hoadonnhap…), dòng đầu STT" />
      <F k="tkn" l="3. Tờ khai nháp TKN" hint="Listxe APT gửi — nên có" /></div>
    <div className="mt-3 grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end">
      <Field label="MD APT xuất thẳng của xe này" hint="Gõ hoặc dán danh sách, cách nhau dấu phẩy/xuống dòng. 2411 hay MD2411 đều được. Dòng có NOTE “XUẤT THẲNG” trên file APT tự nhận.">
        <Textarea rows={2} value={xt} onChange={e => { setXt(e.target.value); setRes(null); }} placeholder="VD: MD2744, MD2784" /></Field>
      {!truck && <label className="mb-6 flex items-center gap-2 rounded-xl bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-900"><input type="checkbox" checked={test} onChange={e => setTest(e.target.checked)} /> Nạp thử — không báo sale</label>}
    </div>
    {err && <div className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">{err}</div>}
    {res && <div className="mt-4 space-y-3">
      {!truck && res.dups.length > 0 && <div className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-800"><b>Có thể trùng xe đã nạp:</b> {res.dups.map((d: any) => <span key={d.id} className="ml-1">
        “{d.name}”{d.is_test ? ' (nạp thử)' : ''} <button className={cx('ml-1 rounded-md border px-2 py-0.5 text-xs font-semibold', target?.id === d.id ? 'border-red-600 bg-red-600 text-white' : 'border-red-300 bg-white')}
          onClick={() => { setTarget(target?.id === d.id ? null : d); setXt((d.md_xuat_thang || []).join(', ')); setRes(null); }}>{target?.id === d.id ? '✓ Sẽ nạp lại vào xe này — bấm Phân tích lại' : 'Nạp lại vào xe này'}</button></span>)}
        <div className="mt-1 text-xs">Nạp lại giữ nguyên trả lời của sale và kết quả HĐ đã ghép. Nếu đúng là xe mới thì cứ lưu bình thường.</div></div>}
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Stat label="Dòng file APT" value={res.stats.apt} sub={`hệ thống ${res.sysCount} · tờ khai ${res.stats.tk}`} />
        <Stat label="Tự chốt (TRUE)" value={res.stats.ok} tone="green" sub={`${Math.round(res.stats.ok / Math.max(1, res.stats.apt) * 100)}% dòng · ${res.lines.filter((l: any) => l.gia_de_xuat).length} dòng tự đề xuất giá`} />
        <Stat label="Bị chặn → sale" value={res.stats.blocked} tone={res.stats.blocked ? 'red' : undefined} sub={`hạn ${cfg.han_sale_gio}h`} />
        <Stat label="Theo dõi riêng" value={res.stats.info} sub="hợp quy · xuất thẳng · Lanchi" />
      </div>
      {res.unmapped.length > 0 && <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Tên sale chưa ghép nhân sự: <b>{res.unmapped.join(', ')}</b>. Dòng của các tên này chỉ kế toán thấy — vào tab “Ghép tên sale” rồi nạp lại.</div>}
      {res.warnings.map((w: string, i: number) => <div key={i} className="rounded-lg bg-ink-50 p-2 text-xs text-ink-600">• {w}</div>)}
      <div className="max-h-[40vh] overflow-auto rounded-xl border border-ink-200"><Table head={['STT', 'Sale', 'MD', 'Tên hàng', 'Giá TK → APT', 'Biên APT', 'Biên NT', 'Luồng', 'Trạng thái', 'Vấn đề']}>
        {res.lines.filter((l: any) => l.status !== 'ok' || l.gia_de_xuat).map((l: any) => <tr key={l.line_key}><Td>{l.apt_stt}</Td><Td className="whitespace-nowrap">{sm.find(l.sale_name)?.name || l.sale_name}</Td><Td>{l.md}</Td>
          <Td className="min-w-[200px] text-xs">{lineName(l).slice(0, 80)}</Td><Td className="whitespace-nowrap text-right text-xs"><Money v={l.gia_von} /> → <Money v={l.gia_ap_dung} /></Td>
          <Td className="text-right text-xs">{pctTxt(l.bien_apt)}</Td><Td className={cx('text-right text-xs', bienTone(l.bien_nt, cfg.bien_nt_min, cfg.bien_nt_max))}>{pctTxt(l.bien_nt)}</Td><Td><LuongBadge l={l.luong} /></Td><Td><StatusBadge s={l.status} /></Td><Td className="min-w-[260px] text-xs text-red-700">{l.issues.join(' · ') || <span className="text-ink-500">{l.notes[0]}</span>}</Td></tr>)}</Table></div>
    </div>}
  </Modal>;
}

// ============ Chi tiết 1 xe ============
function TruckDetail({ id }: { id: string }) {
  const a = useApp(); const cfg = useAccCfg(); const { busy, run } = useAction();
  const { data: t, reload: rt } = useLoad(() => db.from<any>('acc_trucks').select('*').eq('id', id).maybeSingle(), [id]);
  const { data: lines, loading, reload } = useLoad(() => fetchAll<any>(() => db.from('acc_lines').select('*').eq('truck_id', id).order('apt_stt', { nulls: 'last' }).order('line_key')), [id]);
  const [st, setSt] = useState(''); const [sale, setSale] = useState(''); const [q, setQ] = useState(''); const [lu, setLu] = useState('');
  const [sel, setSel] = useState<any>(null); const [re, setRe] = useState(false);
  const all = lines || [];
  const view = all.filter(l => (!st || l.status === st) && (!sale || (l.sale_id || '—') === sale) && (!lu || l.luong === lu)
    && (!q || stripVN([l.md, l.hh, l.ten_apt, l.ten_ht, l.sale_name, l.dh].join(' ')).toLowerCase().includes(stripVN(q).toLowerCase())));
  const pg = usePager('acc_lines', [st, sale, q, lu]);
  const c = (k: string) => all.filter(l => l.status === k).length;
  const sales = Array.from(new Set(all.map(l => l.sale_id || '—')));
  const ttOk = all.filter(l => l.apt_stt && ['ok', 'approved'].includes(l.status)).reduce((x, l) => x + Number(l.tt_apt || 0), 0);
  const kh = all.filter(l => l.apt_stt && l.tt_khach && ['A', 'B'].includes(l.luong)); const sumK = kh.reduce((x, l) => x + Number(l.tt_khach), 0), sumA = kh.reduce((x, l) => x + Number(l.tt_apt), 0);
  const fbRows = () => [['STT', 'Mã hàng', 'Tên hàng', 'SL', 'ĐVT', 'Giá nháp APT', 'KT phản hồi', 'Phản hồi', 'Giá xuất', 'Sale', 'MD', 'Lý do'],
    ...all.filter(l => l.apt_stt).sort((x, y) => x.apt_stt - y.apt_stt).map(l => { const ok = ['ok', 'approved'].includes(l.status);
      const price = l.phan_hoi?.startsWith('XUẤT GIÁ') ? Number(l.phan_hoi.replace(/\D/g, '')) : null;
      return [l.apt_stt, l.hh, lineName(l), Number(l.sl_apt) || '', l.dvt_apt, Number(l.gia_nhap) || '', ok ? 'TRUE' : 'FALSE', l.phan_hoi, price || '', a.personName(l.sale_id) || l.sale_name, l.md, ok ? '' : (l.issues || []).join('; ') || (l.notes || [])[0] || '']; })];
  const fullRows = () => [['STT APT', 'Mã HH', 'Mã dòng', 'MD', 'Sale', 'Luồng', 'Trạng thái', 'Tên (APT)', 'Tên (hệ thống)', 'SL APT', 'SL tờ khai', 'ĐVT APT', 'Giá nháp APT', 'Giá NOTE', 'Giá đề xuất', 'Giá khách', 'Biên NT', 'Thuế NK HT', 'Thuế NK TK', 'Phản hồi APT', 'Vấn đề', 'Ghi chú', 'Sale trả lời', 'Giá sale đề xuất', 'Ghi chú sale', 'Số HĐ vào', 'Kết quả HĐ'],
    ...all.map(l => [l.apt_stt, l.hh, l.ma_dong, l.md, a.personName(l.sale_id) || l.sale_name, l.luong + '. ' + (LUONG as any)[l.luong], ST[l.status]?.[0], l.ten_apt, l.ten_ht, Number(l.sl_apt) || '', Number(l.sl_tk) || '', l.dvt_apt,
      Number(l.gia_nhap) || '', Number(l.gia_note) || '', Number(l.gia_de_xuat) || '', Number(l.gia_khach) || '', l.bien_nt === null ? '' : Number(l.bien_nt), l.nk_ht === null ? '' : Number(l.nk_ht), l.nk_tk === null ? '' : Number(l.nk_tk),
      l.phan_hoi, (l.issues || []).join('; '), (l.notes || []).join('; '), REPLY[l.reply] || '', Number(l.reply_price) || '', l.reply_note, l.inv_no, l.inv_result ? INV_RESULT[l.inv_result as InvResult]?.[0] : ''])];
  const fname = (k: string) => `${k}_${stripVN(t?.name || 'xe').replace(/[^A-Za-z0-9]+/g, '-')}`;
  const exp = (k: 'fb' | 'full', drive = false) => run(async () => {
    const blob = await writeXlsx(fname(k === 'fb' ? 'Phan_hoi_APT' : 'Doi_soat'), k === 'fb' ? fbRows() : fullRows(), k === 'fb' ? 'Phản hồi APT' : 'Đối soát', !drive);
    if (drive) { const url = await saveToDrive(a.settings.drive, blob, fname(k === 'fb' ? 'Phan_hoi_APT' : 'Doi_soat') + '.xlsx', `Ke toan/Doi soat xe/${(t?.truck_date || today()).slice(0, 7)}`); window.open(url, '_blank'); }
  }, drive ? 'Đã lưu lên Drive' : undefined);
  const copyApt = (ls: any[]) => { const t2 = aptPriceMsg(ls, cfg, t?.name); if (!t2) { toast.info('Không có dòng nào biên NT ngoài khung'); return; } navigator.clipboard.writeText(t2).then(() => toast.ok('Đã sao chép — dán vào Zalo gửi APT')); };
  const del = () => run(async () => {
    const n = all.filter(l => l.inv_no).length, r = all.filter(l => l.reply).length;
    if (!(await ask({ title: `Xóa “${t.name}”?`, message: <>Xóa toàn bộ {all.length} dòng đối soát của xe này{r ? `, gồm ${r} dòng sale đã trả lời` : ''}{n ? `, ${n} dòng đã ghép HĐ (chỉ Admin xóa được)` : ''}. Không khôi phục từ màn hình được (có nhật ký và bản sao lưu).</>, ok: 'Xóa xe', danger: true }))) return;
    await db.rpc('acc_truck_delete', { p_id: t.id }); go('/acc');
  }, 'Đã xóa xe');
  if (!t) return <Layout title="Đối soát xe"><Loading /></Layout>;
  return (
    <Layout title={<span>Đối soát · {t.name}</span>} actions={<Button onClick={() => go('/acc')}>← Danh sách xe</Button>}>
      <div className="mb-3 flex flex-wrap items-center gap-2"><Button variant="dark" loading={busy} onClick={() => exp('fb')}>⬇ Phản hồi gửi APT</Button><Button loading={busy} onClick={() => exp('full')}>⬇ Đối soát đầy đủ</Button>
        {driveReady(a.settings.drive) && <Button loading={busy} onClick={() => exp('full', true)}>☁ Lưu Drive</Button>}<Button onClick={() => setRe(true)}>⇪ Nạp lại file</Button>
        <Button onClick={() => copyApt(view.length !== all.length ? view : all)}>📋 Copy đề xuất giá gửi APT{view.length !== all.length ? ' (đang lọc)' : ''}</Button>
        <Button variant="danger" loading={busy} onClick={del}>🗑 Xóa xe</Button>
        <span className="text-xs text-ink-500">Nạp lúc {fmtDateTime(t.created_at)}{t.files?.by ? ' · ' + t.files.by : ''} · {[t.files?.kb, t.files?.apt, t.files?.tkn].filter(Boolean).join(' · ')}</span></div>
      <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-5">
        <Stat label="Dòng file APT" value={all.filter(l => l.apt_stt).length} sub={`${all.filter(l => !l.apt_stt).length} dòng hệ thống không lên xe`} />
        <Stat label="Chốt được (TRUE)" value={c('ok') + c('approved')} tone="green" sub={`${money(ttOk)} đ tiền hàng APT`} onClick={() => setSt('ok')} />
        <Stat label="Còn chặn" value={c('blocked')} tone={c('blocked') ? 'red' : undefined} sub={`quá hạn ${all.filter(l => l.status === 'blocked' && l.due_at && new Date(l.due_at) < new Date()).length}`} onClick={() => setSt('blocked')} />
        <Stat label="Sale trả lời / chờ duyệt" value={`${c('replied')} / ${c('pending_approval')}`} tone={c('replied') ? 'amber' : undefined} onClick={() => setSt('replied')} />
        <Stat label="Biên NT bình quân" value={sumA ? pctTxt(sumK / sumA - 1) : '—'} sub={`mục tiêu ${pctTxt(cfg.bien_muc_tieu)}, khung ${pctTxt(cfg.bien_nt_min)}–${pctTxt(cfg.bien_nt_max)}`} />
      </div>
      {t.is_test && <div className="mb-3 flex flex-wrap items-center gap-3 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900"><b>Xe nạp thử</b> — sale và người duyệt chưa thấy, chưa báo ai, HĐ đầu vào không ghép vào xe này.
        <Button size="sm" variant="primary" loading={busy} onClick={() => run(async () => { if (!(await ask({ title: 'Chuyển thành chính thức', message: `Báo ${c('blocked')} dòng bị chặn cho sale, hạn tính từ bây giờ.`, ok: 'Chuyển & báo sale' }))) return; await db.rpc('acc_truck_publish', { p_id: t.id }); rt(); reload(); }, 'Đã chuyển chính thức, đã báo sale')}>Chuyển thành chính thức & báo sale</Button></div>}
      {Object.keys(t.file_links || {}).length > 0 && <div className="mb-3 flex flex-wrap gap-2 text-xs">File gốc trên Drive: {Object.entries(t.file_links).map(([k, u]: any) => <a key={k} className="font-semibold text-brand-700 underline" href={u} target="_blank" rel="noreferrer">{({ kb: 'Khai báo', apt: 'Check APT', tkn: 'Tờ khai nháp' } as any)[k] || k}</a>)}</div>}
      {(t.warnings || []).length > 0 && <div className="mb-3 space-y-1">{t.warnings.map((w: string, i: number) => <div key={i} className="rounded-lg bg-amber-50 px-3 py-1.5 text-xs text-amber-900">• {w}</div>)}</div>}
      <StatusChips value={st} onChange={setSt} items={[['', 'Tất cả', all.length, 'dark'], ...Object.entries(ST).map(([k, [l, tone]]) => [k, l, c(k), tone] as [string, string, number, string])]} />
      <div className="mb-3 flex flex-wrap gap-2"><Input className="max-w-xs" placeholder="🔎 MD, mã HH, tên hàng, sale…" value={q} onChange={e => setQ(e.target.value)} />
        <Select className="w-52" placeholder="Tất cả sale" options={sales.map(s => [s, s === '—' ? '— Chưa ghép sale' : a.personName(s)] as [string, string])} value={sale} onChange={setSale} />
        <Select className="w-52" placeholder="Tất cả luồng" options={Object.entries(LUONG).map(([k, v]) => [k, `${k}. ${v}`] as [string, string])} value={lu} onChange={setLu} /></div>
      <Card bodyClass="p-0">{loading ? <Loading /> : !view.length ? <Empty>Không có dòng</Empty> :
        <div className="overflow-x-auto"><table className="w-full text-[13px] [&_td]:px-2 [&_td]:py-2 [&_td]:align-top">
          <thead><tr className="border-b border-ink-200 bg-ink-50 text-left text-xs text-ink-500">{['STT', 'Sale · MD', 'Tên hàng', 'SL', 'Giá tờ khai', 'Giá APT', 'Biên APT', 'Giá khách', 'Biên NT', 'Phản hồi APT', 'Trạng thái', 'Vấn đề / ghi chú', 'HĐ'].map(h => <th key={h} className="whitespace-nowrap px-2 py-2.5 font-medium">{h}</th>)}</tr></thead>
          <tbody className="divide-y divide-ink-100">{pg.slice(view).map(l => { const [dt, dc] = dueTxt(l.status === 'blocked' ? l.due_at : null);
            return <tr key={l.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setSel(l)}>
              <td className="text-ink-400">{l.apt_stt ?? '—'}<div className="text-[11px]">{l.hh}</div></td>
              <td className="whitespace-nowrap"><div className="font-medium text-ink-900">{a.personName(l.sale_id) || <span className="text-amber-700">{l.sale_name || '—'}</span>}</div><div className="text-[11px] text-ink-500">{l.ma_dong || l.md || <span className="text-red-600">không có đơn</span>}{l.dh ? ' · ' + l.dh : ''}</div></td>
              <td className="min-w-[220px] max-w-[340px]"><div className="line-clamp-2">{lineName(l)}</div><div className="mt-0.5"><LuongBadge l={l.luong} /></div></td>
              <td className="text-right tabular-nums">{num(l.sl_apt ?? l.sl_ht, 0)}<div className="text-[11px] text-ink-400">{l.dvt_apt || l.dvt_ht}</div></td>
              <td className="text-right text-ink-600"><Money v={l.gia_von} /></td>
              <td className="text-right"><Money v={l.gia_ap_dung ?? l.gia_nhap} />{(l.gia_note || l.gia_de_xuat) && <div className="text-[11px] text-ink-400">nháp <Money v={l.gia_nhap} /></div>}</td>
              <td className="text-right tabular-nums text-ink-600">{pctTxt(l.bien_apt)}</td>
              <td className="text-right"><Money v={l.gia_khach} /></td>
              <td className={cx('text-right tabular-nums', bienTone(l.bien_nt, cfg.bien_nt_min, cfg.bien_nt_max))}>{pctTxt(l.bien_nt)}</td>
              <td className="whitespace-nowrap text-xs font-semibold">{l.phan_hoi}</td>
              <td className="whitespace-nowrap"><StatusBadge s={l.status} />{dt && <div className={cx('text-[11px]', dc)}>{dt}</div>}{l.reply && <div className="text-[11px] text-ink-500">{REPLY[l.reply]}</div>}</td>
              <td className="min-w-[240px] max-w-[380px] text-xs">{(l.issues || []).map((x: string, i: number) => <div key={i} className="text-red-700">• {x}</div>)}{!(l.issues || []).length && (l.notes || []).slice(0, 2).map((x: string, i: number) => <div key={i} className="text-ink-500">• {x}</div>)}</td>
              <td className="whitespace-nowrap text-xs">{l.inv_no && <><div>{l.inv_no}</div><Badge color={INV_RESULT[l.inv_result as InvResult]?.[1]}>{INV_RESULT[l.inv_result as InvResult]?.[0].slice(0, 22)}</Badge></>}</td>
            </tr>; })}</tbody></table></div>}
        <Pager p={pg} total={view.length} /></Card>
      {sel && <LineModal line={sel} onClose={() => setSel(null)} onChanged={() => { setSel(null); reload(); }} />}
      {re && <ImportTruck truck={t} onClose={() => setRe(false)} onDone={() => { setRe(false); rt(); reload(); }} />}
    </Layout>
  );
}

// ============ 1 dòng: chi tiết + hành động ============
export function LineModal({ line: l, onClose, onChanged }: { line: any; onClose: () => void; onChanged: () => void }) {
  const a = useApp(); const cfg = useAccCfg(); const { busy, run } = useAction();
  const { data: ev } = useLoad(() => db.from<any[]>('acc_events').select('*').eq('line_id', l.id).order('at', { asc: false }), [l.id]);
  const acc = isAcc(a);
  const R = ({ k, v, tone }: { k: string; v: React.ReactNode; tone?: string }) => <div className="flex justify-between gap-3 border-b border-ink-100 py-1.5 text-sm"><span className="text-ink-500">{k}</span><span className={cx('text-right', tone)}>{v}</span></div>;
  const set = (s: 'ok' | 'blocked') => run(async () => { const note = await ask({ title: s === 'ok' ? 'Chốt dòng (TRUE)' : 'Trả lại cho sale', input: { label: 'Ghi chú', required: s === 'blocked' } }); if (note === null) return; await db.rpc('acc_line_set', { p_id: l.id, p_status: s, p_note: note }); onChanged(); }, 'Đã cập nhật');
  return <Modal open onClose={onClose} size="lg" title={<span>{l.ma_dong || l.md || 'Dòng không có đơn'} · STT APT {l.apt_stt ?? '—'}</span>}
    footer={acc ? <>{l.status !== 'ok' && l.status !== 'approved' && <Button variant="success" loading={busy} onClick={() => set('ok')}>✓ Chốt dòng</Button>}
      {l.status !== 'blocked' && l.luong !== 'C' && l.luong !== 'D' && <Button variant="danger" loading={busy} onClick={() => set('blocked')}>Trả lại sale</Button>}
      <Button loading={busy} onClick={() => run(async () => { await db.rpc('acc_line_xuat_thang', { p_id: l.id, p_on: l.luong !== 'C' }); onChanged(); }, 'Đã cập nhật')}>{l.luong === 'C' ? 'Bỏ đánh dấu xuất thẳng' : 'Đánh dấu APT xuất thẳng'}</Button></> : undefined}>
    <div className="mb-3 flex flex-wrap gap-2"><StatusBadge s={l.status} /><LuongBadge l={l.luong} />{l.phan_hoi && <Badge color="dark">{l.phan_hoi}</Badge>}</div>
    {(l.issues || []).map((x: string, i: number) => <div key={i} className="mb-1 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">⚠ {x}</div>)}
    {(l.notes || []).map((x: string, i: number) => <div key={i} className="mb-1 rounded-lg bg-ink-50 px-3 py-1.5 text-xs text-ink-600">• {x}</div>)}
    <div className="mt-3 grid gap-x-6 sm:grid-cols-2">
      <div><div className="mb-1 text-xs font-bold uppercase text-ink-400">Hệ thống (gốc)</div>
        <R k="Sale" v={a.personName(l.sale_id) || l.sale_name} /><R k="MD · mã dòng" v={`${l.md || '—'} · ${l.ma_dong || '—'}`} /><R k="Tên" v={<span className="text-xs">{l.ten_ht || '—'}</span>} />
        <R k="SL · ĐVT" v={`${num(l.sl_ht, 2)} ${l.dvt_ht || ''}`} /><R k="Giá khách" v={<Money v={l.gia_khach} />} /><R k="Thuế NK" v={pctTxt(l.nk_ht)} /></div>
      <div><div className="mb-1 text-xs font-bold uppercase text-ink-400">APT · tờ khai</div>
        <R k="Mã HH · DH" v={`${l.hh || '—'} · ${l.dh || '—'}`} /><R k="Sale ghi trên APT" v={l.sale_apt || '—'} /><R k="SL APT · tờ khai" v={`${num(l.sl_apt, 2)} · ${num(l.sl_tk, 2)} ${l.dvt_apt || ''}`} />
        <R k="Giá nháp APT" v={<Money v={l.gia_nhap} />} />{l.gia_note && <R k="Giá sale ghi NOTE" v={<Money v={l.gia_note} />} />}{l.gia_de_xuat && <R k="Giá đề xuất (biên 3%)" v={<Money v={l.gia_de_xuat} />} tone="text-brand-700 font-semibold" />}
        <R k="Biên NT" v={pctTxt(l.bien_nt)} tone={bienTone(l.bien_nt, cfg.bien_nt_min, cfg.bien_nt_max)} /><R k="Thuế NK tờ khai" v={pctTxt(l.nk_tk)} />
        <R k="Giá vốn tờ khai (giá NH + NK/đv)" v={<Money v={l.gia_von} />} /><R k="Biên APT" v={pctTxt(l.bien_apt)} /></div>
    </div>
    <div className="mt-3 text-xs text-ink-500">Tên trên file APT: {l.ten_apt || '—'}</div>
    {aptPriceMsg([l], cfg) && <div className="mt-3 flex items-center justify-between gap-3 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm"><span>Đề nghị APT xuất giá <b><Money v={Math.round(Number(l.gia_khach) / (1 + cfg.bien_muc_tieu))} /></b> để biên NT về {pctTxt(cfg.bien_muc_tieu)}</span>
      <Button size="sm" variant="primary" onClick={() => navigator.clipboard.writeText(aptPriceMsg([l], cfg)).then(() => toast.ok('Đã sao chép'))}>📋 Copy gửi APT</Button></div>}
    {l.reply && <div className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm"><b>Sale trả lời:</b> {REPLY[l.reply]}{l.reply_price ? ` — giá ${money(l.reply_price)}` : ''}{l.reply_note ? ` — “${l.reply_note}”` : ''}
      <div className="text-xs text-ink-500">{a.personName(l.replied_by)} · {fmtDateTime(l.replied_at)}</div></div>}
    {l.approved_at && <div className="mt-2 rounded-xl border border-teal-200 bg-teal-50 p-3 text-sm"><b>{l.status === 'approved' ? 'Đã duyệt' : 'Từ chối'}:</b> {l.approve_note || ''}<div className="text-xs text-ink-500">{a.personName(l.approved_by)} · {fmtDateTime(l.approved_at)}</div></div>}
    {l.inv_no && <div className="mt-2 rounded-xl border border-ink-200 p-3 text-sm">HĐ vào <b>{l.inv_no}</b> dòng {l.inv_stt}: {num(l.inv_qty, 2)} × <Money v={l.inv_price} /> = <Money v={l.inv_amount} /> → <Badge color={INV_RESULT[l.inv_result as InvResult]?.[1]}>{INV_RESULT[l.inv_result as InvResult]?.[0]}</Badge></div>}
    {!acc && ['blocked', 'replied'].includes(l.status) && <ReplyForm line={l} onDone={onChanged} />}
    {(ev || []).length > 0 && <div className="mt-4"><div className="mb-1 text-xs font-bold uppercase text-ink-400">Nhật ký</div>{(ev || []).map(e => <div key={e.id} className="text-xs text-ink-600">{fmtDateTime(e.at)} · {a.personName(e.actor)} · {e.action}{e.note ? ' — ' + e.note : ''}</div>)}</div>}
  </Modal>;
}

export function ReplyForm({ line: l, onDone }: { line: any; onDone: () => void }) {
  const [r, setR] = useState(l.reply || ''); const [price, setPrice] = useState<string>(l.reply_price ? String(l.reply_price) : l.gia_de_xuat ? String(l.gia_de_xuat) : '');
  const [note, setNote] = useState(l.reply_note || ''); const { busy, run } = useAction();
  return <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50/50 p-3">
    <div className="mb-2 text-sm font-semibold">Xử lý dòng này</div>
    <div className="grid grid-cols-2 gap-2">{Object.entries(REPLY).map(([k, v]) => <button key={k} onClick={() => setR(k)}
      className={cx('rounded-xl border px-3 py-2 text-left text-sm font-semibold transition', r === k ? 'border-brand-600 bg-brand-600 text-white' : 'border-ink-200 bg-white text-ink-800 hover:border-brand-400')}>{v}</button>)}</div>
    {r === 'de_xuat_gia' && <Field className="mt-2" label="Giá muốn APT xuất (đ/đv)"><Input inputMode="numeric" value={price} onChange={e => setPrice(e.target.value.replace(/[^\d]/g, ''))} /></Field>}
    <Field className="mt-2" label={r === 'xin_duyet' ? 'Lý do xin duyệt *' : 'Ghi chú'}><Textarea rows={2} value={note} onChange={e => setNote(e.target.value)}
      placeholder={r === 'da_sua_ht' ? 'VD: đã tạo đơn MD2650 / đã nhập giá khách' : r === 'chuyen_xe_sau' ? 'VD: hàng chưa bốc, đi xe 01/11' : ''} /></Field>
    <div className="mt-2 flex justify-end"><Button variant="primary" loading={busy} disabled={!r} onClick={() => run(async () => {
      await db.rpc('acc_line_reply', { p_id: l.id, p_reply: r, p_price: price ? Number(price) : null, p_note: note || null }); onDone(); }, r === 'xin_duyet' ? 'Đã gửi xin duyệt' : 'Đã gửi kế toán')}>Gửi</Button></div>
  </div>;
}

// ============ HĐ đầu vào (XML) ============
function Invoices() {
  const a = useApp(); const { busy, run } = useAction(); const [sel, setSel] = useState<any>(null); const [last, setLast] = useState<any[]>([]);
  const { data, loading, reload } = useLoad(() => db.from<any[]>('acc_invoices').select('id,ky_hieu,so_hd,ngay,ten_ban,tong_truoc_thue,tien_thue,tong,stats,file_name,created_at').order('created_at', { asc: false }).limit(500), []);
  const pg = usePager('acc_invoices', []); const rows = data || [];
  const upload = (fl: FileList | null) => run(async () => {
    if (!fl?.length) return; const out: any[] = [];
    for (const f of Array.from(fl)) {
      if (!/\.xml$/i.test(f.name)) { out.push({ file: f.name, error: 'Chỉ nhận file .xml (PDF không đối chiếu chính xác được)' }); continue; }
      try {
        const inv = parseInvoiceXml(await f.text()); const hhs = Array.from(new Set(inv.lines.map(l => l.hh).filter(Boolean)));
        const found: any[] = hhs.length ? await db.from<any[]>('acc_lines').select('id,hh,md,gia_khach,gia_note,gia_de_xuat,gia_nhap,sl_tk,sl_apt').eq('is_test', false).in('hh', hhs).order('updated_at', { asc: false }) : [];
        const byHH = new Map<string, any>(); found.forEach(x => { if (!byHH.has(x.hh)) byHH.set(x.hh, x); });
        const lines = inv.lines.map(l => { const m = byHH.get(l.hh) || null; return { ...l, line_id: m?.id || null, result: judgeInvoiceLine(l, m) }; });
        const stats: Record<string, number> = {}; lines.forEach(l => { stats[l.result] = (stats[l.result] || 0) + 1; });
        stats.tien_khong_don = lines.filter(l => l.result === 'khong_don' || l.result === 'gia_khach_0').reduce((x, l) => x + l.tt, 0);
        await db.rpc('acc_invoice_save', { p_inv: { ...inv, lines: undefined, file_name: f.name, stats }, p_lines: lines });
        if (driveReady(a.settings.drive)) await saveToDrive(a.settings.drive, f, f.name, `Ke toan/HD dau vao/${(inv.ngay || today()).slice(0, 7)}`).catch(() => null);
        out.push({ file: f.name, so: inv.so_hd, stats });
      } catch (e: any) { out.push({ file: f.name, error: e.message }); }
    }
    setLast(out); reload();
  });
  return <>
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <label className="inline-flex cursor-pointer items-center rounded-xl bg-brand-600 px-4 py-2 text-sm font-semibold text-white hover:bg-brand-700">{busy ? 'Đang đối chiếu…' : '⇪ Nạp XML HĐ APT (chọn nhiều file)'}
        <input type="file" multiple accept=".xml" className="hidden" disabled={busy} onChange={e => { upload(e.target.files); e.target.value = ''; }} /></label>
      <span className="text-xs text-ink-500">Ghép theo mã hàng APT (HH…) với các xe đã nạp — khớp chính xác, không ghép theo tên.{driveReady(a.settings.drive) ? ' File XML tự lưu lên Drive.' : ''}</span></div>
    {last.length > 0 && <Card className="mb-3" title="Kết quả lần nạp vừa rồi">{last.map((x, i) => <div key={i} className="flex flex-wrap items-center gap-2 border-b border-ink-100 py-1.5 text-sm">
      <b>{x.so || x.file}</b>{x.error ? <span className="text-red-600">{x.error}</span> : Object.entries(INV_RESULT).filter(([k]) => x.stats[k]).map(([k, [l, c]]) => <Badge key={k} color={c}>{l}: {x.stats[k]}</Badge>)}
      {x.stats?.tien_khong_don > 0 && <span className="text-xs font-semibold text-red-700">{money(x.stats.tien_khong_don)} đ chưa có đơn/giá khách</span>}</div>)}</Card>}
    <Card bodyClass="p-0">{loading ? <Loading /> : !rows.length ? <Empty>Chưa nạp HĐ</Empty> :
      <Table head={['Số HĐ', 'Ngày', 'Người bán', 'Trước thuế', 'Tổng', 'Khớp', 'Lệch', 'Không đơn / giá 0', 'Thuộc xe khác', '']}>{pg.slice(rows).map(r => { const s = r.stats || {};
        return <tr key={r.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setSel(r)}><Td className="font-semibold">{r.ky_hieu}-{r.so_hd}</Td><Td>{fmtDate(r.ngay)}</Td><Td className="max-w-[220px] truncate text-xs">{r.ten_ban}</Td>
          <Td className="text-right"><Money v={r.tong_truoc_thue} /></Td><Td className="text-right"><Money v={r.tong} /></Td><Td className="text-right text-emerald-700">{s.khop || ''}</Td>
          <Td className="text-right font-semibold text-red-600">{s.lech || ''}</Td><Td className="text-right font-semibold text-red-600">{(s.khong_don || 0) + (s.gia_khach_0 || 0) || ''}{s.tien_khong_don ? <div className="text-[11px]">{money(s.tien_khong_don)}</div> : ''}</Td>
          <Td className="text-right text-ink-400">{s.khong_thuoc_xe || ''}</Td><Td className="text-xs text-ink-400">{r.file_name}</Td></tr>; })}</Table>}
      <Pager p={pg} total={rows.length} /></Card>
    {sel && <InvoiceModal inv={sel} onClose={() => setSel(null)} />}
  </>;
}
function InvoiceModal({ inv, onClose }: { inv: any; onClose: () => void }) {
  const a = useApp(); const { data } = useLoad(() => db.from<any[]>('acc_invoice_lines').select('*,acc_lines(md,sale_id,sale_name,gia_khach,truck_id)').eq('invoice_id', inv.id).order('stt'), [inv.id]);
  const rows = data || [];
  const exp = () => writeXlsx(`HD_${inv.so_hd}_doi_chieu`, [['STT', 'Mã HH', 'Tên hàng', 'ĐVT', 'SL', 'Đơn giá', 'Thành tiền', 'VAT', 'Kết luận', 'MD', 'Sale', 'Giá khách'],
    ...rows.map(r => [r.stt, r.hh, r.ten, r.dvt, Number(r.sl), Number(r.dg), Number(r.tt), r.vat, INV_RESULT[r.result as InvResult]?.[0], r.acc_lines?.md, a.personName(r.acc_lines?.sale_id) || r.acc_lines?.sale_name, Number(r.acc_lines?.gia_khach) || ''])], 'Đối chiếu HĐ');
  return <Modal open onClose={onClose} size="xl" title={`HĐ ${inv.ky_hieu}-${inv.so_hd} · ${fmtDate(inv.ngay)}`} footer={<Button onClick={exp}>⬇ Excel</Button>}>
    <div className="max-h-[65vh] overflow-auto"><Table head={['STT', 'Mã HH', 'Tên hàng', 'SL', 'Đơn giá', 'Thành tiền', 'Kết luận', 'Sale · MD']}>{rows.map(r =>
      <tr key={r.id}><Td>{r.stt}</Td><Td>{r.hh}</Td><Td className="min-w-[240px] text-xs">{r.ten}</Td><Td className="text-right">{num(r.sl, 2)} {r.dvt}</Td><Td className="text-right"><Money v={r.dg} /></Td><Td className="text-right"><Money v={r.tt} /></Td>
        <Td><Badge color={INV_RESULT[r.result as InvResult]?.[1]}>{INV_RESULT[r.result as InvResult]?.[0]}</Badge></Td><Td className="whitespace-nowrap text-xs">{a.personName(r.acc_lines?.sale_id) || r.acc_lines?.sale_name}{r.acc_lines?.md ? ' · ' + r.acc_lines.md : ''}</Td></tr>)}</Table></div>
  </Modal>;
}

// ============ Ghép tên sale trong file với nhân sự ============
function SaleMap() {
  const a = useApp(); const cfg = useAccCfg(); const sm = useSaleMatcher(); const { busy, run } = useAction();
  const { data: unm } = useLoad(() => db.from<any[]>('acc_lines').select('sale_name').is('sale_id', null).limit(2000), []);
  const [pick, setPick] = useState<Record<string, string>>({});
  const groups: { acc: string; names: string[] }[] = [...(cfg.sale_names || [])];
  Array.from(new Set((unm || []).map(x => x.sale_name).filter(Boolean))).filter(n => !groups.some(g => [g.acc, ...g.names].some(x => norm(x) === norm(n)))).forEach(n => groups.push({ acc: n, names: [] }));
  const save = (g: { acc: string; names: string[] }) => run(async () => {
    const pid = pick[g.acc] || sm.find(g.acc)?.id || g.names.map(n => sm.find(n)?.id).find(Boolean); if (!pid) throw new Error('Chọn nhân sự');
    await db.rpc('acc_set_sale_alias', { p_profile: pid, p_names: [g.acc, ...g.names].filter(Boolean) }); location.reload();
  }, 'Đã ghép');
  if (!sm.ready) return <Loading />;
  return <Card title="Ghép tên sale trong file với nhân sự ERP" bodyClass="p-0">
    <p className="px-4 pt-3 text-xs text-ink-500">File khai báo ghi họ tên đầy đủ, file APT và tờ khai ghi tài khoản. Chọn đúng người cho từng dòng → hệ thống tự gán dòng hàng cho sale đó. Đổi người phụ trách: chọn lại và bấm Lưu.</p>
    <Table head={['Tài khoản', 'Tên trong file', 'Đang ghép với', 'Chọn nhân sự', '']}>{groups.map(g => { const all = [g.acc, ...g.names].filter(Boolean); const hits = all.map(n => sm.find(n)); const cur = hits.find(Boolean) || null;
      const missing = all.filter((n, i) => !hits[i] || hits[i]!.id !== cur?.id);
      return <tr key={g.acc}><Td className="font-semibold">{g.acc}</Td><Td className="text-xs">{g.names.join(', ') || '—'}</Td>
        <Td>{cur ? <span className={missing.length ? 'text-amber-700' : 'text-emerald-700'}>{missing.length ? '◐' : '✓'} {cur.name}{missing.length ? <div className="text-[11px]">Thiếu tên: {missing.join(', ')} — bấm Lưu</div> : ''}</span> : <span className="text-amber-700">Chưa ghép</span>}</Td>
        <Td><Select className="w-56" placeholder="— Chọn —" options={sm.dir.map(p => [p.id, p.full_name] as [string, string])} value={pick[g.acc] || cur?.id || ''} onChange={v => setPick(x => ({ ...x, [g.acc]: v }))} /></Td>
        <Td><Button size="sm" loading={busy} disabled={!(pick[g.acc] || cur?.id) || (!missing.length && (pick[g.acc] || cur?.id) === cur?.id)} onClick={() => save(g)}>Lưu</Button></Td></tr>; })}</Table>
  </Card>;
}

// ============ Theo dõi HĐ chưa về / xuất muộn (xuyên các xe) ============
function Track() {
  const a = useApp(); const cfg = useAccCfg(); const X = Number(cfg.han_hd_ngay) || 15;
  const [mode, setMode] = useState<'open' | 'late'>('open'); const [lu, setLu] = useState(''); const [only, setOnly] = useState(false); const [q, setQ] = useState(''); const [sel, setSel] = useState<any>(null);
  const SEL = 'id,truck_id,line_key,md,ma_dong,hh,sale_id,sale_name,ten_apt,ten_ht,sl_apt,dvt_apt,tt_apt,gia_khach,luong,status,inv_id,inv_no,inv_result,issues,notes,phan_hoi,acc_trucks(name,truck_date)';
  const { data, loading } = useLoad(async () => {
    if (mode === 'open') return fetchAll<any>(() => db.from('acc_lines').select(SEL).or('inv_no.is.null,inv_result.eq.mot_phan').eq('is_test', false).gt('apt_stt', 0).in('luong', ['A', 'B']).in('status', ['ok', 'approved', 'info', 'blocked', 'replied', 'pending_approval']));
    const ls = await fetchAll<any>(() => db.from('acc_lines').select(SEL).eq('is_test', false).gt('apt_stt', 0).gte('inv_no', '0'));
    const ids = Array.from(new Set(ls.map(l => l.inv_id).filter(Boolean))); const inv = new Map<string, any>();
    for (let i = 0; i < ids.length; i += 150) (await db.from<any[]>('acc_invoices').select('id,ngay,ky_hieu,so_hd').in('id', ids.slice(i, i + 150))).forEach(x => inv.set(x.id, x));
    return ls.map(l => ({ ...l, inv: inv.get(l.inv_id) }));
  }, [mode]);
  const days = (from?: string, to?: string) => from ? Math.round((Date.parse((to || today()).slice(0, 10)) - Date.parse(from.slice(0, 10))) / 864e5) : null;
  const rows = (data || []).map(l => ({ ...l, d: mode === 'open' ? days(l.acc_trucks?.truck_date) : days(l.acc_trucks?.truck_date, l.inv?.ngay) }))
    .filter(l => (mode === 'open' || (l.d ?? 0) > X) && (!lu || l.luong === lu) && (!only || (l.d ?? 0) > X)
      && (!q || stripVN([l.md, l.hh, l.ten_apt, l.sale_name, l.acc_trucks?.name].join(' ')).toLowerCase().includes(stripVN(q).toLowerCase())))
    .sort((x, y) => (y.d ?? 0) - (x.d ?? 0));
  const pg = usePager('acc_track', [mode, lu, only, q]); const total = rows.reduce((t, l) => t + Number(l.tt_apt || 0), 0);
  const exp = () => writeXlsx(mode === 'open' ? 'HD_chua_ve' : 'HD_xuat_muon', [['Xe', 'Ngày xe', 'Số ngày', 'Luồng', 'Trạng thái', 'Sale', 'MD', 'Mã HH', 'Tên hàng', 'SL', 'Tiền hàng APT', 'Số HĐ', 'Ngày HĐ'],
    ...rows.map(l => [l.acc_trucks?.name, fmtDate(l.acc_trucks?.truck_date), l.d, l.luong + '. ' + (LUONG as any)[l.luong], ST[l.status]?.[0], a.personName(l.sale_id) || l.sale_name, l.md, l.hh, lineName(l), Number(l.sl_apt) || '', Number(l.tt_apt) || '', l.inv_no || '', l.inv?.ngay ? fmtDate(l.inv.ngay) : ''])], mode === 'open' ? 'HĐ chưa về' : 'HĐ xuất muộn');
  return <>
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Tabs value={mode} onChange={v => setMode(v as any)} tabs={[['open', 'Chưa có HĐ đầu vào'], ['late', `Xuất muộn (> ${X} ngày)`]]} />
      <Input className="max-w-xs" placeholder="🔎 MD, mã HH, tên hàng, sale, xe…" value={q} onChange={e => setQ(e.target.value)} />
      <Select className="w-48" placeholder="Mọi luồng" options={[['A', 'A. Qua Nam Trung'], ['B', 'B. Chờ hợp quy']]} value={lu} onChange={setLu} />
      {mode === 'open' && <label className="flex items-center gap-1.5 text-sm"><input type="checkbox" checked={only} onChange={e => setOnly(e.target.checked)} /> Chỉ dòng quá {X} ngày</label>}
      <Button onClick={exp}>⬇ Excel</Button>
    </div>
    <p className="mb-2 text-xs text-ink-500">{mode === 'open' ? `Dòng đã lên xe (qua Nam Trung hoặc chờ hợp quy) mà chưa nạp được HĐ APT tương ứng. Số ngày tính từ ngày xe; đỏ khi quá ${X} ngày (sửa ở Cấu hình → Kế toán – Hóa đơn).` : `Dòng có HĐ APT nhưng ngày HĐ cách ngày xe quá ${X} ngày.`} Không tính xe nạp thử.</p>
    <Card bodyClass="p-0">{loading ? <Loading /> : !rows.length ? <Empty>Không có dòng</Empty> :
      <Table head={['Xe', 'Số ngày', 'Sale · MD', 'Tên hàng', 'SL', 'Tiền hàng APT', 'Luồng', 'Trạng thái', ...(mode === 'late' ? ['HĐ'] : [])]}>{pg.slice(rows).map(l =>
        <tr key={l.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setSel(l)}><Td className="whitespace-nowrap">{l.acc_trucks?.name}<div className="text-[11px] text-ink-400">{fmtDate(l.acc_trucks?.truck_date)}</div></Td>
          <Td className={cx('text-right font-bold tabular-nums', (l.d ?? 0) > X ? 'text-red-600' : 'text-ink-700')}>{l.d}</Td>
          <Td className="whitespace-nowrap">{a.personName(l.sale_id) || l.sale_name}<div className="text-[11px] text-ink-500">{l.ma_dong || l.md || 'không có đơn'} · {l.hh}</div></Td>
          <Td className="min-w-[220px] text-xs">{lineName(l).slice(0, 110)}</Td><Td className="text-right">{num(l.sl_apt, 0)} <span className="text-[11px] text-ink-400">{l.dvt_apt}</span></Td>
          <Td className="text-right"><Money v={l.tt_apt} /></Td><Td><LuongBadge l={l.luong} /></Td><Td><StatusBadge s={l.status} /></Td>
          {mode === 'late' && <Td className="whitespace-nowrap text-xs">{l.inv_no}<div className="text-ink-400">{l.inv?.ngay ? fmtDate(l.inv.ngay) : ''}</div></Td>}</tr>)}</Table>}
      <div className="flex items-center justify-between border-t border-ink-100 px-4 py-2 text-xs text-ink-500"><span>{rows.length} dòng · tiền hàng APT <b className="text-ink-800">{money(total)} đ</b></span></div>
      <Pager p={pg} total={rows.length} /></Card>
    {sel && <LineModal line={sel} onClose={() => setSel(null)} onChanged={() => setSel(null)} />}
  </>;
}
