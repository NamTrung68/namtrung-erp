// Bản 51 — Nạp HĐ tồn (bàn làm việc kế toán): cột HĐ chính thức APT + Mã đơn hàng, Username, Tên sale
//  · giá xuất khách = đơn giá nhập × hệ số (mặc định 1,03), làm tròn đồng
//  · không có sale / sale không nhận ra → không nạp · không có username → vẫn nạp, điền sau · mã hàng đã có → bỏ qua
import React, { useMemo, useState } from 'react';
import { Badge, Button, cx, Modal, Stat, toast, useAction } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { readTable } from '../../lib/xlsx';
import { parseSoXuat } from '../../lib/xuathd';
import { downloadMau } from '../../lib/mau';
import { money, num } from '../../lib/format';
import { Pager, usePager } from '../../components/Pager';

const ST: Record<string, [string, string]> = { moi: ['Nạp', 'green'], da_co: ['Đã có — bỏ qua', 'gray'], thieu_sale: ['Không nạp — sale', 'red'], loi: ['Lỗi', 'red'] };

export function ImportTon({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const a = useApp(); const { busy, run } = useAction();
  const [rows, setRows] = useState<any[] | null>(null); const [chk, setChk] = useState<any>(null); const [err, setErr] = useState(''); const [f, setF] = useState('');
  const [heSo, setHeSo] = useState(1.03);
  const payload = (rs: any[]) => rs.map(r => ({ ma_hang: r.ma_hang, part: r.part, stt_so: r.stt_so, ten: r.ten, dvt: r.dvt, vat: r.vat, sl_nhap: r.sl_nhap, dg_nhap: r.dg_nhap,
    so_hd_vao: r.so_hd_vao, ky_hieu: r.ky_hieu, ngay_vao: r.ngay_vao, ncc: r.ncc, stt_hd: r.stt_hd, md: r.md, nvkd: r.nvkd, username: r.username }));
  const check = (rs: any[], h = heSo) => run(async () => { setChk(await db.rpc<any>('out_items_import_ton', { p_rows: payload(rs), p_dry: true, p_he_so: h })); });
  const read = async (fl: File) => {
    setErr(''); setRows(null); setChk(null);
    try { const p = parseSoXuat(await readTable(fl, { fillMerged: true })); if (!p.rows.length) throw new Error('File không có dòng hàng');
      setRows(p.rows); check(p.rows); } catch (e: any) { setErr(e.message || String(e)); }
  };
  const res: any[] = chk?.rows || [];
  const view = useMemo(() => res.filter(x => !f || (f === 'nokh' ? x.st === 'moi' && !x.co_kh : x.st === f)), [res, f]);
  const pg = usePager('imp_ton', [f, res.length]);
  const noKh = res.filter(x => x.st === 'moi' && !x.co_kh).length;
  const tien = res.filter(x => x.st === 'moi').reduce((t, x) => t + Number(rows?.[x.i]?.sl_nhap || 0) * Number(x.gia || 0), 0);
  const save = () => run(async () => {
    const r = await db.rpc<any>('out_items_import_ton', { p_rows: payload(rows || []), p_dry: false, p_he_so: heSo });
    toast.ok(`Đã nạp ${r.moi} dòng HĐ tồn${r.da_co + r.thieu_sale + r.loi ? ` · bỏ qua ${r.da_co + r.thieu_sale + r.loi}` : ''}`); onDone();
  });
  return <Modal open onClose={() => !busy && onClose()} size="xl" title="Nạp HĐ tồn — HĐ chính thức chưa xuất cho khách"
    footer={<><Button onClick={onClose}>Hủy</Button><Button variant="primary" loading={busy} disabled={!chk?.moi} onClick={save}>Nạp {chk?.moi || 0} dòng</Button></>}>
    <div className="mb-3 rounded-xl border border-ink-200 bg-ink-50 px-3 py-2 text-xs text-ink-700">
      File: các cột như <b>HĐ chính thức APT</b> (Mã hàng, Tên hàng hoá, ĐVT, Thuế suất, Số lượng nhập, Đơn giá nhập, Số hóa đơn, Ký hiệu, Ngày nhập, Nhà cung cấp) + <b>Mã đơn hàng</b>, <b>Username</b>, <b>Tên sale</b>.
      <ul className="mt-1 list-disc pl-4">
        <li><b>Giá xuất khách</b> = đơn giá nhập × hệ số bên dưới (làm tròn đồng). Sale vẫn sửa giá được khi lập phiếu.</li>
        <li>Dòng <b>không có sale</b> hoặc tên sale không khớp ai trên ERP → <b>không nạp</b>.</li>
        <li>Dòng <b>không có username</b> → vẫn nạp, nằm ở nhóm "Thiếu ID đơn / username" trong tab Sẵn sàng xuất của sale để điền sau.</li>
        <li>Mã hàng đã có trong ERP → bỏ qua, không đè dòng đang dùng. Dòng HĐ tồn không ghép vào nháp APT / file xe.</li>
      </ul></div>
    <div className="mb-3 flex flex-wrap items-center gap-3 text-sm">
      <label className="cursor-pointer rounded-xl border border-dashed border-ink-300 px-3 py-2 hover:border-brand-400"><input type="file" accept=".xlsx,.xls,.csv" className="hidden" onChange={e => e.target.files?.[0] && read(e.target.files[0])} />⇪ Chọn file Excel</label>
      <button className="text-xs font-semibold text-brand-700 underline" onClick={() => downloadMau('ton')}>⬇ File mẫu</button>
      <label className="flex items-center gap-1.5 text-xs text-ink-600">Hệ số giá xuất
        <select className="h-8 rounded-lg border border-ink-200 bg-white px-2 text-xs" value={heSo} onChange={e => { const h = Number(e.target.value); setHeSo(h); if (rows) check(rows, h); }}>
          {[1.02, 1.025, 1.03, 1.035, 1.04].map(h => <option key={h} value={h}>× {String(h).replace('.', ',')} (+{num((h - 1) * 100, 1)}%)</option>)}</select></label>
    </div>
    {err && <div className="mb-2 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{err}</div>}
    {chk && <>
      <div className="mb-3 grid grid-cols-2 gap-2 sm:grid-cols-5">
        <Stat label="Sẽ nạp" value={chk.moi} sub={money(tien) + ' giá xuất'} onClick={() => setF('moi')} />
        <Stat label="Nạp — chưa có khách" value={noKh} tone={noKh ? 'amber' : undefined} sub="username trống / chưa khớp" onClick={() => setF('nokh')} />
        <Stat label="Không nạp — sale" value={chk.thieu_sale} tone={chk.thieu_sale ? 'red' : undefined} onClick={() => setF('thieu_sale')} />
        <Stat label="Đã có trong ERP" value={chk.da_co} onClick={() => setF('da_co')} />
        <Stat label="Lỗi dữ liệu" value={chk.loi} tone={chk.loi ? 'red' : undefined} onClick={() => setF('loi')} /></div>
      {f && <button className="mb-2 text-xs text-ink-500 underline" onClick={() => setF('')}>Bỏ lọc ({view.length}/{res.length})</button>}
      <div className="overflow-auto rounded-xl border border-ink-200"><table className="w-full text-xs">
        <thead className="bg-ink-50 text-left text-ink-500"><tr>{['', 'Mã hàng', 'Tên hàng', 'SL', 'Giá nhập', 'Giá xuất', 'Mã đơn', 'Username · khách', 'Sale', 'Ghi chú'].map(h => <th key={h} className="px-2 py-1.5">{h}</th>)}</tr></thead>
        <tbody className="divide-y divide-ink-100">{pg.slice(view).map(x => { const r = rows?.[x.i] || {};
          return <tr key={x.i} className={cx(x.st !== 'moi' && 'text-ink-400')}>
            <td className="px-2 py-1"><Badge color={ST[x.st]?.[1]}>{ST[x.st]?.[0]}</Badge></td>
            <td className="whitespace-nowrap px-2 py-1 font-mono">{r.ma_hang}</td><td className="max-w-[260px] px-2 py-1"><div className="line-clamp-1" title={r.ten}>{r.ten}</div></td>
            <td className="px-2 py-1 text-right">{num(r.sl_nhap, 2)} {r.dvt}</td><td className="px-2 py-1 text-right">{money(r.dg_nhap)}</td><td className="px-2 py-1 text-right font-semibold">{x.st === 'moi' ? money(x.gia) : ''}</td>
            <td className="px-2 py-1">{x.md || <span className="text-amber-700">—</span>}</td>
            <td className="px-2 py-1">{x.username ? <>{x.username}{x.kh ? <div className="text-ink-500">{x.kh}</div> : <div className="text-amber-700">chưa khớp khách</div>}</> : <span className="text-amber-700">trống — điền sau</span>}</td>
            <td className="px-2 py-1">{x.sale_id ? a.personName(x.sale_id) : <span className="text-red-600">{r.nvkd || 'trống'}</span>}</td>
            <td className="px-2 py-1 text-red-700">{x.ly_do || ''}</td></tr>; })}</tbody></table>
        <Pager p={pg} total={view.length} /></div>
    </>}
  </Modal>;
}
