// HĐ nháp đơn giản: sale gom dòng đã chốt theo khách → bản xem trước gửi khách duyệt (chưa phải HĐ điện tử)
import React, { useMemo, useState } from 'react';
import { Button, Card, Empty, Field, Input, Modal, Select, Table, Td, toast, useLoad } from '../../components/ui';
import { CustomerPicker } from '../../components/CustomerPicker';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { fmtDate, money, num, today } from '../../lib/format';
import { lineName, Money } from './common';

const qty = (l: any) => Number(l.inv_qty ?? l.sl_tk ?? l.sl_apt ?? l.sl_ht ?? 0);
const esc = (s: any) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' } as any)[c]);

export function DraftInvoice({ lines }: { lines: any[] }) {
  const [open, setOpen] = useState<any>(null);
  const ok = lines.filter(l => ['ok', 'approved'].includes(l.status) && ['A', 'B'].includes(l.luong) && Number(l.gia_khach) > 0 && l.apt_stt);
  const groups = useMemo(() => {
    const m = new Map<string, { key: string; customer_id: string | null; label: string; lines: any[] }>();
    ok.forEach(l => { const k = l.customer_id || (l.ma_kh ? 'kh:' + l.ma_kh.toUpperCase() : 'md:' + (l.md || '—'));
      const g = m.get(k) || { key: k, customer_id: l.customer_id || null, label: l.ma_kh || l.md || '—', lines: [] }; g.lines.push(l); m.set(k, g); });
    return Array.from(m.values()).sort((a, b) => b.lines.length - a.lines.length);
  }, [lines]);
  return <>
    <p className="mb-3 text-sm text-ink-600">Gom các dòng <b>đã chốt</b> (qua Nam Trung / hợp quy, có giá khách) theo khách → xem trước HĐ nháp, in hoặc lưu PDF gửi khách kiểm tra. Đây chưa phải HĐ điện tử. Khách có nhiều hộ kinh doanh: chọn lại người mua khi in.</p>
    <Card bodyClass="p-0">{!groups.length ? <Empty>Chưa có dòng đã chốt có giá khách</Empty> :
      <Table head={['Khách / mã', 'Số dòng', 'MD', 'Tiền hàng (chưa VAT)', '']}>{groups.map(g => <tr key={g.key}>
        <Td className="font-semibold">{g.label}{!g.customer_id && <div className="text-[11px] font-normal text-amber-700">chưa gắn khách ERP</div>}</Td><Td className="text-right">{g.lines.length}</Td>
        <Td className="max-w-[260px] truncate text-xs">{Array.from(new Set(g.lines.map(l => l.md).filter(Boolean))).join(', ')}</Td>
        <Td className="text-right"><Money v={g.lines.reduce((t, l) => t + Math.round(qty(l) * Number(l.gia_khach)), 0)} /></Td>
        <Td><Button size="sm" variant="primary" onClick={() => setOpen(g)}>Xem HĐ nháp</Button></Td></tr>)}</Table>}</Card>
    {open && <DraftModal g={open} onClose={() => setOpen(null)} />}
  </>;
}

function DraftModal({ g, onClose }: { g: any; onClose: () => void }) {
  const a = useApp(); const co = a.settings.company || {};
  const { data: c0 } = useLoad(() => g.customer_id ? db.from<any>('customers').select('id,code,sys_code,sys_username,company_name,contact_name,tax_code,address,legal_address,email,phone').eq('id', g.customer_id).maybeSingle() : Promise.resolve(null), [g.customer_id]);
  const [cus, setCus] = useState<any>(null); const c = cus || c0;
  const [buyer, setBuyer] = useState<Record<string, string>>({}); const [vat, setVat] = useState('8'); const [pick, setPick] = useState<Record<string, boolean>>({});
  const B = (k: string, d: string) => buyer[k] ?? d;
  const fullC = useLoad(() => cus?.id ? db.from<any>('customers').select('id,company_name,contact_name,tax_code,address,legal_address').eq('id', cus.id).maybeSingle() : Promise.resolve(null), [cus?.id]).data;
  const cc = fullC || c || {};
  const name = B('name', cc.company_name || cc.contact_name || ''), mst = B('mst', cc.tax_code || ''), addr = B('addr', cc.legal_address || cc.address || '');
  const rows = g.lines.filter((l: any) => pick[l.id] !== false).sort((x: any, y: any) => (x.apt_stt || 0) - (y.apt_stt || 0));
  const sub = rows.reduce((t: number, l: any) => t + Math.round(qty(l) * Number(l.gia_khach)), 0); const vt = Math.round(sub * Number(vat) / 100);
  const print = () => {
    const w = window.open('', '_blank'); if (!w) return toast.err('Trình duyệt chặn cửa sổ mới — cho phép popup rồi thử lại');
    const tr = rows.map((l: any, i: number) => `<tr><td class=c>${i + 1}</td><td>${esc(lineName(l))}</td><td class=c>${esc(l.dvt_apt || l.dvt_ht || '')}</td><td class=r>${num(qty(l), 2)}</td><td class=r>${money(l.gia_khach)}</td><td class=r>${money(Math.round(qty(l) * Number(l.gia_khach)))}</td></tr>`).join('');
    w.document.write(`<!doctype html><html><head><meta charset=utf-8><title>HĐ nháp ${esc(name)}</title><style>
      body{font:13px/1.45 Arial,sans-serif;color:#111;margin:28px}h1{text-align:center;font-size:20px;margin:6px 0 2px}.sub{text-align:center;color:#666;margin-bottom:16px}
      .wm{position:fixed;top:40%;left:0;right:0;text-align:center;font-size:90px;color:rgba(200,0,0,.08);transform:rotate(-20deg);pointer-events:none}
      table{width:100%;border-collapse:collapse;margin-top:10px}th,td{border:1px solid #999;padding:5px 6px;vertical-align:top}th{background:#f2f2f2}.c{text-align:center}.r{text-align:right;white-space:nowrap}
      .p p{margin:2px 0}.tot td{font-weight:bold}.note{margin-top:14px;color:#a00;font-size:12px}@media print{button{display:none}}</style></head><body>
      <div class=wm>BẢN NHÁP</div><h1>HÓA ĐƠN GIÁ TRỊ GIA TĂNG (BẢN NHÁP)</h1><div class=sub>Ngày ${fmtDate(today())} — chỉ để khách kiểm tra thông tin, chưa phải hóa đơn điện tử</div>
      <div class=p><p><b>Đơn vị bán:</b> ${esc(co.name || '')}</p><p>MST: ${esc(co.tax_code || '')}</p><p>Địa chỉ: ${esc(co.address || '')}</p><p>Điện thoại: ${esc(co.hotline || '')}${co.email ? ' · Email: ' + esc(co.email) : ''}</p></div><hr>
      <div class=p><p><b>Đơn vị mua:</b> ${esc(name)}</p><p>MST: ${esc(mst)}</p><p>Địa chỉ: ${esc(addr)}</p><p>Sale phụ trách: ${esc(a.me.full_name)}</p></div>
      <table><thead><tr><th>STT</th><th>Tên hàng hóa</th><th>ĐVT</th><th>Số lượng</th><th>Đơn giá</th><th>Thành tiền</th></tr></thead><tbody>${tr}
      <tr class=tot><td colspan=5 class=r>Cộng tiền hàng</td><td class=r>${money(sub)}</td></tr><tr class=tot><td colspan=5 class=r>Thuế GTGT ${vat}%</td><td class=r>${money(vt)}</td></tr>
      <tr class=tot><td colspan=5 class=r>Tổng thanh toán</td><td class=r>${money(sub + vt)}</td></tr></tbody></table>
      <div class=note>Quý khách kiểm tra tên, MST, địa chỉ, số lượng, đơn giá. Sai sót xin báo lại sale trước khi xuất hóa đơn chính thức.</div>
      <p><button onclick="print()">In / Lưu PDF</button></p></body></html>`);
    w.document.close();
  };
  return <Modal open onClose={onClose} size="xl" title={`HĐ nháp · ${g.label}`} footer={<Button variant="primary" disabled={!rows.length} onClick={print}>🖨 In / Lưu PDF</Button>}>
    <div className="grid gap-3 sm:grid-cols-2">
      <Field label="Chọn khách khác (nếu khách có nhiều HKD/công ty)"><CustomerPicker value={cus || c0} onChange={x => { setCus(x); setBuyer({}); }} /></Field>
      <Field label="Thuế GTGT"><Select options={[['0', '0%'], ['5', '5%'], ['8', '8%'], ['10', '10%']]} value={vat} onChange={setVat} /></Field>
      <Field label="Tên đơn vị mua"><Input value={name} onChange={e => setBuyer(b => ({ ...b, name: e.target.value }))} /></Field>
      <Field label="MST"><Input value={mst} onChange={e => setBuyer(b => ({ ...b, mst: e.target.value }))} /></Field>
      <Field className="sm:col-span-2" label="Địa chỉ"><Input value={addr} onChange={e => setBuyer(b => ({ ...b, addr: e.target.value }))} /></Field>
    </div>
    {!co.name && <div className="mt-2 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-900">Chưa có thông tin công ty — Admin nhập ở Cấu hình → Công ty.</div>}
    <div className="mt-3 max-h-[45vh] overflow-auto"><Table head={['', 'Xe · MD', 'Tên hàng', 'SL', 'Đơn giá', 'Thành tiền']}>{g.lines.map((l: any) => <tr key={l.id} className={pick[l.id] === false ? 'opacity-40' : ''}>
      <Td><input type="checkbox" checked={pick[l.id] !== false} onChange={e => setPick(p => ({ ...p, [l.id]: e.target.checked }))} /></Td>
      <Td className="whitespace-nowrap text-xs">{l.acc_trucks?.name}<div className="text-ink-400">{l.md}</div></Td><Td className="min-w-[220px] text-xs">{lineName(l)}</Td>
      <Td className="text-right">{num(qty(l), 2)} {l.dvt_apt || l.dvt_ht}</Td><Td className="text-right"><Money v={l.gia_khach} /></Td><Td className="text-right"><Money v={Math.round(qty(l) * Number(l.gia_khach))} /></Td></tr>)}</Table></div>
    <div className="mt-2 text-right text-sm">Tiền hàng <b>{money(sub)}</b> · VAT {vat}% <b>{money(vt)}</b> · Tổng <b className="text-brand-700">{money(sub + vt)}</b></div>
  </Modal>;
}
