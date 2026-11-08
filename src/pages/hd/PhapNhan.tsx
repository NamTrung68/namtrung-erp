// Bản 33 — Menu "Pháp nhân": nạp Excel, theo dõi, sửa trực tiếp, chuẩn hóa pháp nhân nhận HĐ (gắn khách theo username)
import React, { useEffect, useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Empty, Input, Loading, Modal, Select, ask, cx, toast, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { readXlsx, writeXlsx } from '../../lib/xlsx';
import { parseBuyers } from '../../lib/xuathd';
import { downloadMau } from '../../lib/mau';
import { today } from '../../lib/format';
import { CopyBtn, MstCheck, MstChip } from '../../components/MstCheck';

/** MST hợp lệ: 10 số, 10-3 số, hoặc CCCD 12 số (giống kiểm tra trước khi gửi MISA) */
export const mstOk = (s: string) => /^(\d{10}|\d{10}-\d{3}|\d{12})$/.test(String(s || '').trim());
const emailOk = (s: string) => !s.trim() || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s.trim());
const lc = (s: any) => String(s || '').trim().toLowerCase();

const FLAGS: [string, string, string][] = [
  ['', 'Tất cả', 'ink'], ['chua_gan', 'Username chưa có khách ERP', 'amber'], ['mst_sai', 'MST sai dạng', 'red'], ['thieu_dc', 'Thiếu địa chỉ', 'amber'],
  ['trung_mst', 'Cùng MST khác tên', 'red'], ['khong_md', 'Khách chưa có ★ mặc định', 'amber'],
  ['co_hdnt', 'Đã ký HĐ nguyên tắc', 'ink'], ['thieu_dd', 'Thiếu người đại diện', 'amber'],
];

interface Row { id: string; customer_id: string | null; username: string | null; own_username: string | null; name: string; tax_code: string; address: string | null; email: string | null; note: string | null;
  is_default: boolean; kh_name: string | null; kh_code: string | null; sale_id: string | null; mst_sai: boolean; thieu_dc: boolean; trung_mst: boolean; khong_md: boolean; so_phieu: number; updated_at: string | null;
  dai_dien: string | null; chuc_vu: string | null; dia_chi_giao: string | null; ma_hdnt: string | null; ngay_hdnt: string | null }
type Draft = { username: string; name: string; tax_code: string; address: string; email: string; note: string; dai_dien: string; chuc_vu: string; dia_chi_giao: string; ma_hdnt: string; ngay_hdnt: string };
const toDraft = (r: Partial<Row>): Draft => ({ username: r.username || '', name: r.name || '', tax_code: r.tax_code || '', address: r.address || '', email: r.email || '', note: r.note || '',
  dai_dien: r.dai_dien || '', chuc_vu: r.chuc_vu || '', dia_chi_giao: r.dia_chi_giao || '', ma_hdnt: r.ma_hdnt || '', ngay_hdnt: r.ngay_hdnt || '' });
const EMPTY: Draft = toDraft({});

export default function PhapNhan() {
  const a = useApp(); const { busy, run } = useAction();
  const [q, setQ] = useState(''); const [qq, setQq] = useState(''); const [flag, setFlag] = useState(''); const [sale, setSale] = useState('');
  const [rev, setRev] = useState(0); const reload = () => setRev(x => x + 1);
  useEffect(() => { const t = setTimeout(() => setQq(q), 300); return () => clearTimeout(t); }, [q]);
  const { data, loading, error } = useLoad(() => db.rpc<any>('out_buyers_page', { p: { q: qq, flag, sale, limit: 2000 } }), [qq, flag, sale, rev]);
  const rows: Row[] = data?.rows || []; const counts = data?.counts || {}; const acc: boolean = data ? !!data.acc : a.isAdmin || a.has('ke_toan');
  const [edit, setEdit] = useState<Record<string, Draft>>({}); const [adding, setAdding] = useState<Draft | null>(null); const [imp, setImp] = useState(false);
  const groups = useMemo(() => { const m = new Map<string, Row[]>(); rows.forEach(r => { const k = r.customer_id || 'u:' + lc(r.username); m.set(k, [...(m.get(k) || []), r]); }); return Array.from(m.values()); }, [rows]);
  const dirty = (r: Row) => { const d = edit[r.id]; if (!d) return false; const o = toDraft(r); return (Object.keys(o) as (keyof Draft)[]).some(k => (d[k] || '').trim() !== (o[k] || '').trim()); };
  const setE = (r: Row, k: keyof Draft, v: string) => setEdit(x => ({ ...x, [r.id]: { ...(x[r.id] || toDraft(r)), [k]: v } }));
  const val = (r: Row, k: keyof Draft) => (edit[r.id] || toDraft(r))[k];
  const save = (r: Row) => run(async () => { const d = edit[r.id]; await db.rpc('out_buyer_save', { p_id: r.id, p: d });
    setEdit(x => { const y = { ...x }; delete y[r.id]; return y; }); reload(); }, 'Đã lưu pháp nhân');
  const saveAll = () => run(async () => { const list = rows.filter(dirty); let ok = 0; const errs: string[] = [];
    for (const r of list) { try { await db.rpc('out_buyer_save', { p_id: r.id, p: edit[r.id] }); ok++; setEdit(x => { const y = { ...x }; delete y[r.id]; return y; }); } catch (e: any) { errs.push(`${r.name}: ${e.message}`); } }
    reload(); if (errs.length) toast.err(`Lưu ${ok}/${list.length} — lỗi: ${errs.slice(0, 3).join(' · ')}`); else toast.ok(`Đã lưu ${ok} pháp nhân`); });
  const setDefault = (r: Row) => run(async () => { await db.rpc('out_buyer_set_default', { p_id: r.id }); reload(); }, `★ ${r.name} là pháp nhân mặc định`);
  const del = (r: Row) => run(async () => {
    if (!(await ask({ title: `Xóa pháp nhân “${r.name}”?`, message: <>MST {r.tax_code} · username {r.username || '—'}.{r.so_phieu ? <> Đã dùng ở <b>{r.so_phieu}</b> phiếu — phiếu cũ giữ nguyên thông tin, chỉ không gợi ý pháp nhân này nữa.</> : ''}</>, ok: 'Xóa', danger: true }))) return;
    await db.rpc('out_buyer_delete', { p_ids: [r.id] }); reload(); }, 'Đã xóa');
  const addSave = () => run(async () => { await db.rpc('out_buyer_save', { p_id: null, p: { ...adding, is_default: false } }); setAdding(null); reload(); }, 'Đã thêm pháp nhân');
  const exportX = () => run(async () => {
    const all: Row[] = (await db.rpc<any>('out_buyers_page', { p: { limit: 20000 } })).rows || [];
    const head = ['MST', 'Tên đơn vị', 'Địa chỉ', 'Mail nhận HĐ', 'Username', 'Mặc định', 'Khách ERP', 'Sale', 'Số phiếu đã dùng', 'Cảnh báo', 'Ghi chú',
      'Người đại diện', 'Chức vụ', 'Địa chỉ giao hàng', 'Mã HĐ nguyên tắc', 'Ngày HĐ nguyên tắc'];
    await writeXlsx('Phap_nhan_nhan_HD_' + today(), [head, ...all.map(r => [r.tax_code || '', r.name, r.address || '', r.email || '', r.username || '', r.is_default ? '★' : '', [r.kh_code, r.kh_name].filter(Boolean).join(' · '),
      a.personName(r.sale_id || ''), r.so_phieu, [!r.customer_id && 'username chưa có khách', r.mst_sai && 'MST sai dạng', r.thieu_dc && 'thiếu địa chỉ', r.trung_mst && 'cùng MST khác tên'].filter(Boolean).join('; '), r.note || '',
      r.dai_dien || '', r.chuc_vu || '', r.dia_chi_giao || '', r.ma_hdnt || '', r.ngay_hdnt ? r.ngay_hdnt.split('-').reverse().join('/') : ''])],
      'Thong tin KH', true, { fmt: { 0: 'plain', 14: 'plain' } });
  }, 'Đã xuất Excel — sửa xong nạp lại ở nút “Nạp Excel”');
  const nDirty = rows.filter(dirty).length;
  const sales = useMemo(() => Array.from(new Set(rows.map(r => r.sale_id).filter(Boolean))) as string[], [rows]);
  const inp = 'h-8 w-full rounded-lg border bg-white px-2 text-xs focus:border-brand-500 focus:outline-none';
  return <Layout title="Pháp nhân nhận HĐ" actions={<div className="flex flex-wrap gap-2">
    {acc && <Button onClick={() => setImp(true)}>⇪ Nạp Excel</Button>}<Button loading={busy} onClick={exportX}>⬇ Xuất Excel</Button>
    <Button variant="primary" onClick={() => setAdding({ ...EMPTY })}>+ Thêm pháp nhân</Button></div>}>
    {!acc && <p className="mb-2 rounded-lg bg-brand-50 px-3 py-2 text-sm text-brand-900">Bạn đang xem <b>pháp nhân của khách mình phụ trách</b>. Sửa tên / MST / địa chỉ / email / người đại diện cho chuẩn rồi bấm Lưu — bấm <b>🔍</b> cạnh MST để lấy thông tin đăng ký thuế. Mã HĐ nguyên tắc do kế toán điền.</p>}
    <p className="mb-3 text-sm text-ink-600">Mỗi <b>username</b> khách có thể có nhiều pháp nhân nhận HĐ; <b>★</b> là pháp nhân tự điền khi sale lập phiếu. Sửa thẳng trên ô rồi bấm <b>Lưu</b>. Đổi username = chuyển pháp nhân sang khách khác (ERP tự gắn theo username). Muốn sửa hàng loạt: <b>Xuất Excel</b> → sửa → <b>Nạp Excel</b> (cùng username + MST thì cập nhật, không tạo trùng).</p>
    <div className="mb-3 flex flex-wrap gap-2">{FLAGS.map(([k, l, c]) => { const n = k ? counts[k] : counts.tat_ca;
      return <button key={k} onClick={() => setFlag(k)} className={cx('rounded-xl border px-3 py-1.5 text-left text-xs', flag === k ? 'border-brand-500 bg-brand-50' : 'border-ink-200 bg-white hover:border-brand-300')}>
        <div className={cx('text-lg font-bold', k && n ? (c === 'red' ? 'text-red-600' : 'text-amber-600') : 'text-ink-900')}>{n ?? '…'}</div><div className="text-ink-600">{l}</div></button>; })}
      {counts.khach !== undefined && <div className="self-center text-xs text-ink-500">{counts.khach} khách / username</div>}</div>
    <div className="mb-3 flex flex-wrap items-center gap-2">
      <Input className="max-w-sm" placeholder="Tìm tên, MST, username, địa chỉ, khách…" value={q} onChange={e => setQ(e.target.value)} />
      <Select className="w-52" placeholder="Tất cả sale" options={[['', 'Tất cả sale'], ...sales.map(s => [s, a.personName(s)] as [string, string])]} value={sale} onChange={setSale} />
      {nDirty > 0 && <Button variant="primary" loading={busy} onClick={saveAll}>Lưu {nDirty} dòng đã sửa</Button>}
      {nDirty > 0 && <button className="text-xs text-ink-500 underline" onClick={() => setEdit({})}>Bỏ sửa</button>}
      <span className="ml-auto text-xs text-ink-500">{data ? `${data.total} pháp nhân` : ''}</span></div>
    {loading && !data ? <Loading /> : error ? <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{String(error)}</div> : !rows.length ? <Empty>Không có pháp nhân nào{flag || qq ? ' khớp bộ lọc' : ''}</Empty> :
    <div className="space-y-3">{groups.map(g => { const h = g[0];
      return <div key={h.customer_id || 'u' + h.username} className="rounded-2xl border border-ink-200 bg-white">
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-ink-100 px-3 py-2 text-sm">
          <b>{h.username || '(chưa có username)'}</b>
          {h.customer_id ? <span className="text-ink-700">{h.kh_code ? h.kh_code + ' · ' : ''}{h.kh_name}</span> : <Badge color="amber">Username chưa có khách ERP</Badge>}
          {h.sale_id && <span className="text-xs text-ink-500">Sale: {a.personName(h.sale_id)}</span>}
          <span className="text-xs text-ink-400">{g.length} pháp nhân</span>
          <button className="ml-auto text-xs font-semibold text-brand-700 underline" onClick={() => setAdding({ ...EMPTY, username: h.username || '' })}>+ thêm pháp nhân cho {h.username || 'khách này'}</button></div>
        <div className="divide-y divide-ink-100">{g.map(r => { const d = dirty(r); const m = val(r, 'tax_code');
          return <div key={r.id} className={cx('grid gap-1.5 px-3 py-2 lg:grid-cols-[28px_2.2fr_1fr_2.4fr_1.4fr_1fr_auto]', d && 'bg-brand-50/50')}>
            <button title={r.is_default ? 'Pháp nhân mặc định' : 'Đặt làm mặc định'} disabled={!r.customer_id || r.is_default || busy} onClick={() => setDefault(r)}
              className={cx('self-center text-lg leading-none', r.is_default ? 'text-amber-500' : 'text-ink-300 hover:text-amber-400 disabled:hover:text-ink-300')}>{r.is_default ? '★' : '☆'}</button>
            <input className={cx(inp, !val(r, 'name').trim() ? 'border-red-300' : 'border-ink-200', 'font-semibold')} value={val(r, 'name')} onChange={e => setE(r, 'name', e.target.value)} title="Tên đơn vị" />
            <div className="flex items-center gap-0.5"><input className={cx(inp, 'font-mono font-semibold', mstOk(m) ? 'border-ink-200' : 'border-red-300 bg-red-50')} value={m} onChange={e => setE(r, 'tax_code', e.target.value.replace(/\s/g, ''))} title="MST / CCCD" />
              {mstOk(m) && <><CopyBtn text={m} title="Copy MST" /><MstChip btnOnly mst={m} onApply={v => setEdit(x => ({ ...x, [r.id]: { ...(x[r.id] || toDraft(r)), name: v.name, address: v.address } }))} /></>}</div>
            <input className={cx(inp, val(r, 'address').trim() ? 'border-ink-200' : 'border-amber-300')} value={val(r, 'address')} onChange={e => setE(r, 'address', e.target.value)} placeholder="Địa chỉ" />
            <input className={cx(inp, emailOk(val(r, 'email')) ? 'border-ink-200' : 'border-red-300')} value={val(r, 'email')} onChange={e => setE(r, 'email', e.target.value)} placeholder="Email nhận HĐ" />
            <input className={cx(inp, 'border-ink-200')} value={val(r, 'username')} onChange={e => setE(r, 'username', e.target.value)} placeholder="Username" title="Đổi username = chuyển sang khách khác" />
            <div className="flex items-center gap-1.5">{d ? <Button size="sm" variant="primary" loading={busy} onClick={() => save(r)}>Lưu</Button> : null}
              <button className="px-1 text-xs text-red-600 hover:underline" onClick={() => del(r)}>Xóa</button></div>
            {/* Bản 35: thông tin in bộ chứng từ (ĐĐH, biên bản giao nhận, HĐ mua bán / HĐ nguyên tắc) */}
            <div className="grid gap-1.5 sm:grid-cols-2 lg:col-start-2 lg:col-end-8 lg:grid-cols-[1.3fr_1fr_1.7fr_130px_2fr]">
              <input className={cx(inp, 'border-ink-200')} value={val(r, 'dai_dien')} onChange={e => setE(r, 'dai_dien', e.target.value)} placeholder="Người đại diện (VD: Ông Trương Văn Dương)" title="Người đại diện — in trên hợp đồng / biên bản" />
              <input className={cx(inp, 'border-ink-200')} value={val(r, 'chuc_vu')} onChange={e => setE(r, 'chuc_vu', e.target.value)} placeholder="Chức vụ" title="Chức vụ người đại diện" />
              <input disabled={!acc} className={cx(inp, 'border-ink-200 disabled:bg-ink-50 disabled:text-ink-600', val(r, 'ma_hdnt') && 'border-emerald-300 bg-emerald-50/50 font-semibold')} value={val(r, 'ma_hdnt')} onChange={e => setE(r, 'ma_hdnt', e.target.value)} placeholder={acc ? 'Mã HĐ nguyên tắc (nếu đã ký)' : 'Chưa có HĐ nguyên tắc'} title={acc ? 'Có mã HĐNT → bộ chứng từ dùng HĐNT, không cần HĐ mua bán từng HĐ' : 'Mã HĐ nguyên tắc do kế toán điền'} />
              <input disabled={!acc} type="date" className={cx(inp, 'border-ink-200 disabled:bg-ink-50')} value={val(r, 'ngay_hdnt')} onChange={e => setE(r, 'ngay_hdnt', e.target.value)} title="Ngày ký HĐ nguyên tắc (trống: đọc từ mã dạng 28/08/2026/...)" />
              <input className={cx(inp, 'border-ink-200')} value={val(r, 'dia_chi_giao')} onChange={e => setE(r, 'dia_chi_giao', e.target.value)} placeholder="Địa chỉ giao hàng (trống = địa chỉ ĐKKD)" /></div>
            <div className="flex flex-wrap gap-1 text-[11px] lg:col-start-2 lg:col-end-8">
              {r.trung_mst && <Badge color="red">Cùng MST {r.tax_code} có tên khác — chuẩn hóa</Badge>}
              {r.mst_sai && <Badge color="red">MST sai dạng</Badge>}{r.khong_md && <Badge color="amber">Khách chưa có ★</Badge>}
              {r.so_phieu > 0 && <span className="text-ink-500">đã dùng {r.so_phieu} phiếu</span>}
              {r.note && <span className="text-ink-400">· {r.note}</span>}
              {r.updated_at && <span className="text-ink-400">· sửa {new Date(r.updated_at).toLocaleString('vi-VN')}</span>}</div>
          </div>; })}</div></div>; })}
      {data?.total > rows.length && <div className="text-center text-xs text-ink-500">Đang hiện {rows.length}/{data.total} — gõ tìm hoặc lọc để thu hẹp</div>}
    </div>}
    {adding && <Modal open onClose={() => setAdding(null)} title="Thêm pháp nhân nhận HĐ" footer={<><Button onClick={() => setAdding(null)}>Hủy</Button>
      <Button variant="primary" loading={busy} disabled={!adding.name.trim() || !mstOk(adding.tax_code)} onClick={addSave}>Thêm</Button></>}>
      <div className="grid gap-2 sm:grid-cols-2">
        <label className="text-xs text-ink-600">Username khách<Input value={adding.username} onChange={e => setAdding({ ...adding, username: e.target.value })} placeholder="VD: phamcong" /></label>
        <label className="text-xs text-ink-600">MST / CCCD *<Input value={adding.tax_code} onChange={e => setAdding({ ...adding, tax_code: e.target.value.replace(/\s/g, '') })} className={adding.tax_code && !mstOk(adding.tax_code) ? 'border-red-300' : ''} /></label>
        <label className="text-xs text-ink-600 sm:col-span-2">Tên đơn vị *<Input value={adding.name} onChange={e => setAdding({ ...adding, name: e.target.value })} placeholder="CÔNG TY … / HỘ KINH DOANH …" /></label>
        <label className="text-xs text-ink-600 sm:col-span-2">Địa chỉ<Input value={adding.address} onChange={e => setAdding({ ...adding, address: e.target.value })} /></label>
        <label className="text-xs text-ink-600">Email nhận HĐ<Input value={adding.email} onChange={e => setAdding({ ...adding, email: e.target.value })} /></label>
        <label className="text-xs text-ink-600">Ghi chú<Input value={adding.note} onChange={e => setAdding({ ...adding, note: e.target.value })} /></label>
        <MstCheck className="sm:col-span-2" mst={adding.tax_code} name={adding.name} address={adding.address} onApply={v => setAdding(x => x && ({ ...x, name: v.name, address: v.address }))} />
        <label className="text-xs text-ink-600">Người đại diện<Input value={adding.dai_dien} onChange={e => setAdding({ ...adding, dai_dien: e.target.value })} placeholder="VD: Ông Trương Văn Dương" /></label>
        <label className="text-xs text-ink-600">Chức vụ<Input value={adding.chuc_vu} onChange={e => setAdding({ ...adding, chuc_vu: e.target.value })} placeholder="VD: Giám đốc / Chủ hộ kinh doanh" /></label>
        <label className="text-xs text-ink-600">Mã HĐ nguyên tắc (nếu đã ký{acc ? '' : ' — kế toán điền'})<Input disabled={!acc} value={adding.ma_hdnt} onChange={e => setAdding({ ...adding, ma_hdnt: e.target.value })} placeholder="VD: 28/08/2026/HĐNTHH/NT/JINVPP" /></label>
        <label className="text-xs text-ink-600">Ngày ký HĐNT<Input disabled={!acc} type="date" value={adding.ngay_hdnt} onChange={e => setAdding({ ...adding, ngay_hdnt: e.target.value })} /></label>
        <label className="text-xs text-ink-600 sm:col-span-2">Địa chỉ giao hàng (trống = địa chỉ trên)<Input value={adding.dia_chi_giao} onChange={e => setAdding({ ...adding, dia_chi_giao: e.target.value })} /></label></div>
      <p className="mt-2 text-xs text-ink-500">Username khớp khách ERP thì gắn ngay; chưa có khách thì ERP tự gắn khi khách có username đó. Khách chưa có ★ → pháp nhân này thành mặc định.</p></Modal>}
    {imp && <ImportBuyers current={rows} onClose={() => setImp(false)} onDone={() => { setImp(false); reload(); }} />}
  </Layout>;
}

/** Nạp Excel pháp nhân: xem trước mới / cập nhật / không đổi / lỗi rồi mới lưu */
function ImportBuyers({ current, onClose, onDone }: { current: Row[]; onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction(); const [res, setRes] = useState<any[] | null>(null); const [err, setErr] = useState(''); const [step, setStep] = useState('');
  const [all, setAll] = useState<Row[] | null>(null);
  useEffect(() => { db.rpc<any>('out_buyers_page', { p: { limit: 20000 } }).then(x => setAll(x.rows || [])).catch(() => setAll(current)); }, []);
  const read = async (f: File) => { setErr(''); setRes(null);
    try { const list = parseBuyers(await readXlsx(f)); const base = all || current;
      const seen = new Set<string>();
      setRes(list.map(x => { const key = lc(x.username) + '|' + x.tax_code.trim(); const dup = seen.has(key); seen.add(key);
        const old = base.find(r => lc(r.username) === lc(x.username) && (r.tax_code || '').trim() === x.tax_code.trim());
        const errs = [!mstOk(x.tax_code) && 'MST sai dạng', !emailOk(x.email) && 'email sai', dup && 'trùng dòng trên trong file', x.ngay_hdnt === '?' && 'ngày HĐNT sai dạng (dd/mm/yyyy)'].filter(Boolean) as string[];
        const ch = old ? [old.name.trim() !== x.name.trim() && `tên: ${old.name} → ${x.name}`, x.address && (old.address || '').trim() !== x.address.trim() && 'địa chỉ', x.email && (old.email || '').trim() !== x.email.trim() && 'email',
          x.dai_dien && (old.dai_dien || '') !== x.dai_dien && 'người đại diện', x.chuc_vu && (old.chuc_vu || '') !== x.chuc_vu && 'chức vụ', x.dia_chi_giao && (old.dia_chi_giao || '') !== x.dia_chi_giao && 'địa chỉ giao',
          x.ma_hdnt && (old.ma_hdnt || '') !== x.ma_hdnt && 'mã HĐNT', x.ngay_hdnt && (old.ngay_hdnt || '') !== x.ngay_hdnt && 'ngày HĐNT'].filter(Boolean) as string[] : [];
        return { ...x, st: errs.length ? 'loi' : !old ? 'moi' : ch.length ? 'sua' : 'giu', errs, ch };
      })); } catch (e: any) { setErr(e.message || String(e)); } };
  const ok = (res || []).filter(x => x.st === 'moi' || x.st === 'sua');
  const [loi, setLoi] = useState<any[] | null>(null);
  const save = () => run(async () => { let moi = 0, sua = 0; const bad: any[] = [];
    for (let i = 0; i < ok.length; i += 300) { setStep(`Đang nạp ${Math.min(i + 300, ok.length)}/${ok.length}…`); const part = ok.slice(i, i + 300);
      const r = await db.rpc<any>('out_buyers_import_v2', { p_rows: part.map(x => ({ tax_code: x.tax_code, name: x.name, address: x.address, email: x.email, username: x.username,
        dai_dien: x.dai_dien, chuc_vu: x.chuc_vu, dia_chi_giao: x.dia_chi_giao, ma_hdnt: x.ma_hdnt, ngay_hdnt: x.ngay_hdnt })) });
      moi += r.moi || 0; sua += r.sua || 0; (r.loi || []).forEach((e: any) => bad.push(e)); }
    setStep('');
    if (bad.length) { setLoi(bad); toast.err(`Đã lưu ${moi + sua}/${ok.length} (${moi} mới, ${sua} cập nhật) — ${bad.length} dòng bị bỏ qua, xem danh sách`); }
    else { toast.ok(`Đã nạp ${moi} mới, ${sua} cập nhật`); onDone(); } });
  const cnt = (s: string) => (res || []).filter(x => x.st === s).length;
  const ST: Record<string, [string, string]> = { moi: ['Mới', 'green'], sua: ['Cập nhật', 'blue'], giu: ['Không đổi', 'gray'], loi: ['Lỗi — bỏ qua', 'red'] };
  return <Modal open onClose={() => !busy && onClose()} size="xl" title="Nạp Excel pháp nhân nhận HĐ"
    footer={<><span className="mr-auto text-xs text-brand-700">{step}</span><Button onClick={onClose}>Hủy</Button><Button variant="primary" loading={busy} disabled={!ok.length} onClick={save}>Lưu {ok.length} dòng</Button></>}>
    <div className="mb-3 flex flex-wrap items-center gap-3 text-sm">
      <label className="cursor-pointer rounded-xl border border-dashed border-ink-300 px-3 py-2 hover:border-brand-400"><input type="file" accept=".xlsx" className="hidden" onChange={e => e.target.files?.[0] && read(e.target.files[0])} />⇪ Chọn file .xlsx</label>
      <button className="text-xs font-semibold text-brand-700 underline" onClick={() => downloadMau('buyers')}>⬇ File mẫu</button>
      <span className="text-xs text-ink-500">Cột: MST, Tên đơn vị, Địa chỉ, Mail nhận HĐ, Username (+ tùy chọn: Người đại diện, Chức vụ, Địa chỉ giao hàng, Mã HĐ nguyên tắc, Ngày HĐ nguyên tắc). Cùng username + MST = cập nhật; ô trống không xóa dữ liệu đang có.</span></div>
    {err && <div className="mb-2 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
    {loi && <div className="mb-3 rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800"><b>{loi.length} dòng chưa lưu được</b> (các dòng khác đã lưu) — sửa trên menu hoặc trong file rồi nạp lại:
      <div className="mt-1 max-h-40 overflow-auto">{loi.map((e, i) => <div key={i}>• {e.username || '—'} · {e.tax_code} · {e.name}: {e.error}</div>)}</div>
      <button className="mt-1 font-semibold underline" onClick={onDone}>Đóng và xem danh sách</button></div>}
    {!all && <Loading />}
    {res && <>
      <div className="mb-2 flex flex-wrap gap-2 text-xs">{(['moi', 'sua', 'giu', 'loi'] as const).map(s => <Badge key={s} color={ST[s][1]}>{ST[s][0]}: {cnt(s)}</Badge>)}</div>
      <div className="max-h-[55vh] overflow-auto rounded-xl border border-ink-200"><table className="w-full text-xs"><thead className="sticky top-0 bg-ink-50"><tr className="text-left">
        {['', 'Username', 'MST', 'Tên đơn vị', 'Địa chỉ', 'Email', 'Ghi chú'].map(h => <th key={h} className="px-2 py-1.5">{h}</th>)}</tr></thead>
        <tbody className="divide-y divide-ink-100">{res.map((x, i) => <tr key={i} className={x.st === 'loi' ? 'bg-red-50/60' : x.st === 'giu' ? 'text-ink-400' : ''}>
          <td className="px-2 py-1"><Badge color={ST[x.st][1]}>{ST[x.st][0]}</Badge></td><td className="px-2 py-1">{x.username || '—'}</td><td className="px-2 py-1 font-mono">{x.tax_code}</td>
          <td className="px-2 py-1">{x.name}</td><td className="max-w-[260px] px-2 py-1">{x.address}</td><td className="px-2 py-1">{x.email}</td>
          <td className="px-2 py-1 text-red-700">{x.errs.join(', ')}<span className="text-brand-700">{x.ch.join(' · ')}</span></td></tr>)}</tbody></table></div></>}
  </Modal>;
}
