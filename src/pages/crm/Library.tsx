import React, { useEffect, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Empty, Input, Loading, StatusChips, toast } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { fmtDate, money, num } from '../../lib/format';
import { writeXlsx } from '../../lib/xlsx';
import { ImportField, ImportWizard } from '../../components/ImportWizard';
import { QUOTE_STATUS } from './Customers';

const ARCH: ImportField[] = [
  { key: 'item_name', label: 'Tên hàng', required: true, aliases: ['tên sản phẩm', 'sản phẩm', 'tên sp', 'hàng hóa', 'mô tả'] },
  { key: 'src_code', label: 'Mã báo giá', aliases: ['mã bg', 'số báo giá', 'mã đơn'] },
  { key: 'quote_date', label: 'Ngày báo giá', type: 'date', aliases: ['ngày', 'ngày lập'] },
  { key: 'hs_code', label: 'Mã HS', aliases: ['hs', 'hs code'] }, { key: 'unit', label: 'ĐVT', aliases: ['đơn vị', 'đơn vị tính'] },
  { key: 'qty', label: 'Số lượng', type: 'number', aliases: ['sl'] }, { key: 'price_cny', label: 'Đơn giá ¥', type: 'number', aliases: ['đơn giá ncc', 'giá tệ', 'đơn giá tệ', 'đơn giá cny'] },
  { key: 'duty_pct', label: 'Thuế NK %', type: 'number', aliases: ['thuế nk', 'thuế nhập khẩu', 'thuế xnk'] }, { key: 'vat_pct', label: 'VAT %', type: 'number', aliases: ['vat', 'thuế vat'] },
  { key: 'export_price', label: 'Giá xuất / ĐV', type: 'number', aliases: ['giá xuất', 'đơn giá xuất', 'giá xuất trước vat'] }, { key: 'rate', label: 'Tỷ giá', type: 'number' },
  { key: 'import_method', label: 'Hình thức NK', aliases: ['hình thức nhập khẩu'] }, { key: 'warehouse', label: 'Kho', aliases: ['kho nhận'] },
  { key: 'freight', label: 'Cước', aliases: ['đơn giá cước', 'cước vận chuyển'] }, { key: 'sale_name', label: 'Sale', aliases: ['nhân viên', 'người báo giá'] }, { key: 'note', label: 'Ghi chú' },
];

export default function Library() {
  const a = useApp(); const [q, setQ] = useState(''); const [src, setSrc] = useState(''); const [rows, setRows] = useState<any[] | null>(null); const [page, setPage] = useState(0);
  const [imp, setImp] = useState(false); const canImport = a.isAdmin || a.has('bgd', 'tp_kd');
  const total = rows?.[0] ? Number(rows[0].total) : 0; const PER = 100;
  const load = async (p = 0) => { try { setRows(await db.rpc<any[]>('quote_library', { p_q: q.trim() || null, p_source: src || null, p_limit: PER, p_offset: p * PER })); setPage(p); } catch (e) { toast.err(e); setRows([]); } };
  useEffect(() => { const t = setTimeout(() => load(0), 400); return () => clearTimeout(t); }, [q, src]);
  const exportAll = async () => {
    try { const all = await db.rpc<any[]>('quote_library', { p_q: q.trim() || null, p_source: src || null, p_limit: 2000, p_offset: 0 });
      await writeXlsx(`kho-bao-gia-${new Date().toISOString().slice(0, 10)}`, [['Nguồn', 'Mã BG', 'Ngày', 'Trạng thái', 'Tên hàng', 'HS', 'ĐVT', 'SL', 'Đơn giá ¥', 'Thuế NK %', 'VAT %', 'Giá xuất / ĐV', 'Tỷ giá', 'Hình thức NK', 'Kho', 'Cước', 'Sale'],
        ...all.map(r => [r.source === 'he_thong' ? 'Hệ thống' : 'Lưu trữ', r.code, r.quote_date, QUOTE_STATUS[r.status]?.[0] || '', r.item_name, r.hs_code, r.unit, num0(r.qty), num0(r.price_cny), num0(r.duty_pct), num0(r.vat_pct), num0(r.export_price), num0(r.rate), a.label('import_method', r.import_method) || r.import_method, r.warehouse, r.freight, r.sale_name])], 'Kho báo giá');
    } catch (e) { toast.err(e); }
  };
  return (
    <Layout title="Kho báo giá tham khảo" actions={<>{canImport && <Button onClick={() => setImp(true)}>⇪ Nhập báo giá cũ</Button>}<Button onClick={exportAll}>⬇ Xuất Excel</Button></>}>
      <p className="mb-3 text-sm text-ink-500">Toàn bộ dòng hàng đã từng báo giá (hệ thống + dữ liệu cũ) để Sale, CSKH, XNK tham khảo HS, thuế, giá xuất. <b>Không hiển thị thông tin khách hàng.</b></p>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <Input className="max-w-md flex-1" placeholder="🔎 Gõ tên hàng (không cần dấu) hoặc mã HS…" value={q} onChange={e => setQ(e.target.value)} />
        <StatusChips value={src} onChange={setSrc} items={[['', 'Tất cả', total && !src ? total : 0, 'dark'], ['he_thong', 'Báo giá trên hệ thống', src === 'he_thong' ? total : 0, 'purple'], ['luu_tru', 'Dữ liệu cũ', src === 'luu_tru' ? total : 0, 'teal']]} />
      </div>
      <div className="rounded-2xl border border-ink-200 bg-white shadow-soft">
        {!rows ? <Loading /> : !rows.length ? <Empty>Không tìm thấy dòng hàng phù hợp</Empty> : <>
          <ul className="divide-y divide-ink-100 md:hidden">{rows.map((r, i) => <li key={i} className="px-3 py-2.5 text-sm">
            <div className="font-semibold leading-snug">{r.item_name}</div>
            <div className="mt-0.5 flex flex-wrap gap-x-3 text-xs text-ink-500"><span>HS <b className="text-ink-800">{r.hs_code || '—'}</b></span><span>NK {num(r.duty_pct)}% · VAT {num(r.vat_pct)}%</span><span>¥{num(r.price_cny)}</span><span>Xuất <b className="text-ink-800">{money(r.export_price)}</b></span></div>
            <div className="text-[11px] text-ink-400">{r.code} · {fmtDate(r.quote_date)} · {r.sale_name}</div></li>)}</ul>
          <div className="hidden overflow-x-auto md:block"><table className="w-full text-sm">
            <thead><tr className="border-b border-ink-200 bg-ink-50 text-left text-xs text-ink-500">{['Tên hàng', 'HS', 'ĐVT', 'SL', 'Đơn giá ¥', 'Thuế NK', 'VAT', 'Giá xuất / ĐV', 'Tỷ giá', 'Hình thức · kho · cước', 'Báo giá'].map(h => <th key={h} className="whitespace-nowrap px-3 py-2 font-semibold">{h}</th>)}</tr></thead>
            <tbody className="divide-y divide-ink-100">{rows.map((r, i) => <tr key={i} className="align-top hover:bg-ink-50/60">
              <td className="min-w-[280px] max-w-[420px] px-3 py-2">{r.item_name}{q && r.score < 0.99 && <span className="ml-1 text-[10px] text-ink-300">{Math.round(r.score * 100)}%</span>}</td>
              <td className="whitespace-nowrap px-3 py-2 font-semibold">{r.hs_code}</td><td className="px-3 py-2">{r.unit}</td>
              <td className="whitespace-nowrap px-3 py-2 text-right tabular-nums">{num(r.qty)}</td><td className="whitespace-nowrap px-3 py-2 text-right tabular-nums">{r.price_cny !== null && `¥${num(r.price_cny, 4)}`}</td>
              <td className="px-3 py-2 text-right">{r.duty_pct !== null && `${num(r.duty_pct)}%`}</td><td className="px-3 py-2 text-right">{r.vat_pct !== null && `${num(r.vat_pct)}%`}</td>
              <td className="whitespace-nowrap px-3 py-2 text-right font-semibold tabular-nums">{money(r.export_price)}</td><td className="px-3 py-2 text-right tabular-nums">{money(r.rate)}</td>
              <td className="max-w-[220px] px-3 py-2 text-xs text-ink-600">{[a.label('import_method', r.import_method) || r.import_method, r.warehouse, r.freight].filter(Boolean).join(' · ')}</td>
              <td className="whitespace-nowrap px-3 py-2 text-xs"><Badge color={r.source === 'he_thong' ? 'purple' : 'teal'}>{r.source === 'he_thong' ? r.code : (r.code || 'Lưu trữ')}</Badge>
                <div className="mt-0.5 text-ink-400">{fmtDate(r.quote_date)}{r.sale_name && ` · ${r.sale_name}`}</div></td>
            </tr>)}</tbody></table></div>
          <div className="flex items-center justify-between border-t border-ink-100 px-4 py-2 text-xs text-ink-500"><span>{num(total)} dòng · trang {page + 1}/{Math.max(1, Math.ceil(total / PER))}</span>
            <span className="flex gap-1"><Button size="sm" disabled={page === 0} onClick={() => load(page - 1)}>‹ Trước</Button><Button size="sm" disabled={(page + 1) * PER >= total} onClick={() => load(page + 1)}>Sau ›</Button></span></div>
        </>}
      </div>
      <ImportWizard open={imp} onClose={() => setImp(false)} title="Nhập dữ liệu báo giá cũ vào kho tham khảo" fields={ARCH} sampleName="mau-bao-gia-cu"
        note={<>Mỗi dòng là một mặt hàng đã báo giá. <b>Không nhập thông tin khách hàng</b> — kho này mọi nhân sự đều xem được.</>}
        onImport={async rs => { for (let i = 0; i < rs.length; i += 500) await db.from('quote_archive').insert(rs.slice(i, i + 500).map(r => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v === '' ? null : v])))); load(0); return <b>Đã nhập {rs.length} dòng vào kho báo giá.</b>; }} />
    </Layout>
  );
}
const num0 = (v: any) => (v === null || v === undefined || v === '' ? '' : Number(v));
