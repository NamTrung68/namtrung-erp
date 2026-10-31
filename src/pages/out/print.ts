// Bản xem trước HĐ nháp (in / lưu PDF) dựng từ dữ liệu ERP — sale gửi khách kiểm tra, không cần vào phần mềm HĐĐT
import { fmtDate, money, num, today } from '../../lib/format';

const esc = (s: any) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' } as any)[c]);
export interface PrintLine { ten: string; dvt: string; sl: number; gia: number; vat: number | null }
export function printDraft(o: { co: any; buyer: { name: string; mst?: string; addr?: string; email?: string }; sale: string; code?: string; lines: PrintLine[] }): boolean {
  const w = window.open('', '_blank'); if (!w) return false;
  const groups = new Map<string, { tt: number; thue: number }>(); let sub = 0, tax = 0;
  const tr = o.lines.map((l, i) => { const tt = Math.round(l.sl * l.gia); const v = Number(l.vat ?? 0); const th = Math.round(tt * v); sub += tt; tax += th;
    const k = Math.round(v * 100) + '%'; const g = groups.get(k) || { tt: 0, thue: 0 }; g.tt += tt; g.thue += th; groups.set(k, g);
    return `<tr><td class=c>${i + 1}</td><td>${esc(l.ten)}</td><td class=c>${esc(l.dvt)}</td><td class=r>${num(l.sl, 2)}</td><td class=r>${money(l.gia)}</td><td class=r>${money(tt)}</td></tr>`; }).join('');
  const vatRows = Array.from(groups.entries()).map(([k, g]) => `<tr class=tot><td colspan=5 class=r>Thuế GTGT ${k} (trên ${money(g.tt)})</td><td class=r>${money(g.thue)}</td></tr>`).join('');
  const co = o.co || {};
  w.document.write(`<!doctype html><html><head><meta charset=utf-8><title>HĐ nháp ${esc(o.buyer.name)}</title><style>
    body{font:13px/1.45 Arial,sans-serif;color:#111;margin:28px}h1{text-align:center;font-size:20px;margin:6px 0 2px}.sub{text-align:center;color:#666;margin-bottom:16px}
    .wm{position:fixed;top:40%;left:0;right:0;text-align:center;font-size:90px;color:rgba(200,0,0,.08);transform:rotate(-20deg);pointer-events:none}
    table{width:100%;border-collapse:collapse;margin-top:10px}th,td{border:1px solid #999;padding:5px 6px;vertical-align:top}th{background:#f2f2f2}.c{text-align:center}.r{text-align:right;white-space:nowrap}
    .p p{margin:2px 0}.tot td{font-weight:bold}.note{margin-top:14px;color:#a00;font-size:12px}@media print{button{display:none}}</style></head><body>
    <div class=wm>BẢN NHÁP</div><h1>HÓA ĐƠN GIÁ TRỊ GIA TĂNG (BẢN NHÁP)</h1><div class=sub>Ngày ${fmtDate(today())}${o.code ? ' · ' + esc(o.code) : ''} — để khách kiểm tra thông tin, chưa phải hóa đơn điện tử</div>
    <div class=p><p><b>Đơn vị bán:</b> ${esc(co.name || '')}</p><p>MST: ${esc(co.tax_code || '')}</p><p>Địa chỉ: ${esc(co.address || '')}</p><p>Điện thoại: ${esc(co.hotline || '')}${co.email ? ' · Email: ' + esc(co.email) : ''}</p></div><hr>
    <div class=p><p><b>Đơn vị mua:</b> ${esc(o.buyer.name)}</p><p>MST: ${esc(o.buyer.mst || '')}</p><p>Địa chỉ: ${esc(o.buyer.addr || '')}</p>${o.buyer.email ? `<p>Email: ${esc(o.buyer.email)}</p>` : ''}<p>Sale phụ trách: ${esc(o.sale)}</p></div>
    <table><thead><tr><th>STT</th><th>Tên hàng hóa</th><th>ĐVT</th><th>Số lượng</th><th>Đơn giá</th><th>Thành tiền</th></tr></thead><tbody>${tr}
    <tr class=tot><td colspan=5 class=r>Cộng tiền hàng</td><td class=r>${money(sub)}</td></tr>${vatRows}
    <tr class=tot><td colspan=5 class=r>Tổng thanh toán</td><td class=r>${money(sub + tax)}</td></tr></tbody></table>
    <div class=note>Quý khách kiểm tra tên, MST, địa chỉ, email, số lượng, đơn giá. Sai sót xin báo lại sale trước khi xuất hóa đơn chính thức.</div>
    <p><button onclick="print()">In / Lưu PDF</button></p></body></html>`);
  w.document.close(); return true;
}
