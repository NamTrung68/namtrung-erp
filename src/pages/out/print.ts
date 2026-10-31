// Bản xem trước HĐ nháp theo mẫu HĐ GTGT (MISA meInvoice) — dựng từ dữ liệu ERP, sale gửi khách kiểm tra
import { money, num, today } from '../../lib/format';

const esc = (s: any) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' } as any)[c]);
const SO = ['không', 'một', 'hai', 'ba', 'bốn', 'năm', 'sáu', 'bảy', 'tám', 'chín'];
function ba(n: number, full: boolean): string {
  const t = Math.floor(n / 100), c = Math.floor((n % 100) / 10), d = n % 10; const w: string[] = [];
  if (full || t) w.push(SO[t] + ' trăm');
  if (c === 0) { if (d && (full || t)) w.push('lẻ'); }
  else if (c === 1) w.push('mười'); else w.push(SO[c] + ' mươi');
  if (d) w.push(d === 1 && c > 1 ? 'mốt' : d === 5 && c > 0 ? 'lăm' : d === 4 && c > 1 ? 'tư' : SO[d]);
  return w.join(' ');
}
/** 29160000 → "Hai mươi chín triệu một trăm sáu mươi nghìn đồng chẵn." */
export function docTien(v: number): string {
  let n = Math.round(Math.abs(v)); if (!n) return 'Không đồng.';
  const units = ['', ' nghìn', ' triệu', ' tỷ']; const parts: string[] = []; let i = 0; const groups: number[] = [];
  while (n > 0) { groups.push(n % 1000); n = Math.floor(n / 1000); }
  for (i = groups.length - 1; i >= 0; i--) {
    const g = groups[i]; if (!g) { if (i % 3 === 0 && i > 0 && parts.length) parts.push(units[3]); continue; }
    parts.push(ba(g, parts.length > 0) + (i % 3 === 0 ? (i ? units[3] : '') : units[i % 3]) + (i >= 3 && i % 3 ? units[3] : ''));
  }
  const s = parts.join(' ').replace(/\s+/g, ' ').trim();
  return s.charAt(0).toUpperCase() + s.slice(1) + ' đồng chẵn.';
}
export interface PrintLine { ten: string; dvt: string; sl: number; gia: number; vat: number | null }
export function printDraft(o: { co: any; cfg?: any; buyer: { name: string; mst?: string; addr?: string; email?: string; pay?: string }; sale: string; code?: string; lines: PrintLine[] }): boolean {
  const w = window.open('', '_blank'); if (!w) return false;
  const co = o.co || {}; const cfg = o.cfg || {}; const d = today().split('-');
  const g: Record<string, { tt: number; th: number }> = {}; let sub = 0, tax = 0;
  const tr = o.lines.map((l, i) => { const tt = Math.round(l.sl * l.gia); const v = Number(l.vat ?? 0); const th = Math.round(tt * v); sub += tt; tax += th;
    const k = Math.round(v * 100) + '%'; g[k] = { tt: (g[k]?.tt || 0) + tt, th: (g[k]?.th || 0) + th };
    return `<tr><td class=c>${i + 1}</td><td>${esc(l.ten)}</td><td class=c>${esc(l.dvt)}</td><td class=r>${num(l.sl, 2)}</td><td class=r>${money(l.gia)}</td><td class=r>${money(tt)}</td><td class=c>${k}</td><td class=r>${money(th)}</td></tr>`; }).join('');
  const rate = (lbl: string, k: string | null) => { const x = k ? g[k] : null; return `<tr><td>${lbl}</td><td class=r>${x ? money(x.tt) : ''}</td><td class=r>${x ? money(x.th) : ''}</td><td class=r>${x ? money(x.tt + x.th) : ''}</td></tr>`; };
  const khac = Object.keys(g).filter(k => !['0%', '5%', '8%', '10%'].includes(k));
  w.document.write(`<!doctype html><html><head><meta charset=utf-8><title>HĐ nháp ${esc(o.buyer.name)}</title><style>
  @page{size:A4;margin:10mm}body{font:12.5px/1.45 "Times New Roman",Times,serif;color:#111;margin:0;background:#f3f4f6}
  .pg{width:190mm;min-height:270mm;margin:12px auto;background:#fff;padding:9mm 10mm;box-sizing:border-box;border:7px double #3b82c4;outline:2px solid #9cc3e6;outline-offset:-12px;position:relative}
  .wm{position:absolute;top:42%;left:0;right:0;text-align:center;font-size:84px;font-weight:bold;color:rgba(200,30,30,.06);transform:rotate(-22deg);pointer-events:none}
  .hd{display:grid;grid-template-columns:1fr auto;align-items:start}.ttl{text-align:center}.ttl h1{font-size:21px;margin:0}.ttl div{font-style:italic}.nhap{color:#c00;font-weight:bold;font-style:normal!important;font-size:12px;margin-top:2px}
  .kh{font-size:12.5px;text-align:left;white-space:nowrap}.kh b{font-weight:bold}
  .sel{border-bottom:1px solid #555;padding:6px 0 5px}.sel .n{font-size:15.5px;font-weight:bold}.p{margin:1.5px 0}.buy{padding:6px 0}
  .row{display:flex;justify-content:space-between}
  table{width:100%;border-collapse:collapse;margin-top:4px}th,td{border:1px solid #333;padding:3px 5px;vertical-align:top}th{font-weight:bold;text-align:center}
  .c{text-align:center}.r{text-align:right;white-space:nowrap}.sum td{font-weight:normal}.tot td{font-weight:bold}
  .chu{border:1px solid #333;border-top:0;padding:4px 5px}.sig{display:grid;grid-template-columns:1fr 1fr;text-align:center;margin-top:14px}.sig i{font-size:12px}
  .ks{margin:10px auto 0;width:200px;border:1px solid #5a9;background:#e8f5ec;color:#c00;font-style:italic;font-weight:bold;text-align:left;padding:8px 10px;line-height:1.8}
  .ft{position:absolute;left:10mm;right:10mm;bottom:8mm;text-align:center;font-size:12px}.ft .l{text-align:left}
  .bar{text-align:center;margin:10px}@media print{body{background:#fff}.pg{margin:0}.bar{display:none}}
  </style></head><body><div class=bar><button onclick="print()" style="font-size:15px;padding:8px 18px">🖨 In / Lưu PDF</button></div><div class=pg><div class=wm>BẢN NHÁP</div>
  <div class=hd><div class=ttl><h1>HÓA ĐƠN GIÁ TRỊ GIA TĂNG</h1><div>Ngày ${d[2]} tháng ${d[1]} năm ${d[0]}</div><div>Mã CQT:</div><div class=nhap>BẢN NHÁP – CHƯA KÝ PHÁT HÀNH</div></div>
    <div class=kh>Ký hiệu: <b>${esc(cfg.ky_hieu_ra || '1C26TYY')}</b><br>Số: <b>&lt;Chưa cấp số&gt;</b>${o.code ? `<br><span style="font-size:11px;color:#666">Phiếu ERP: ${esc(o.code)}</span>` : ''}</div></div>
  <div class=sel><div class=n>${esc(co.name || '')}</div><div class=p>Mã số thuế: ${esc(co.tax_code || '')}</div><div class=p>Địa chỉ: ${esc(co.address || '')}</div>
    ${co.email ? `<div class=p>Email: ${esc(co.email)}</div>` : ''}${cfg.stk_hd ? `<div class=p>Số tài khoản: ${esc(cfg.stk_hd)}</div>` : ''}</div>
  <div class=buy><div class=p>Họ tên người mua hàng:</div><div class=p>Tên đơn vị: ${esc(o.buyer.name)}</div><div class=p>Mã số thuế: ${esc(o.buyer.mst || '')}</div>
    <div class=p>Địa chỉ: ${esc(o.buyer.addr || '')}</div><div class=p>CCCD người mua:</div><div class="p row"><span>Hình thức thanh toán: ${esc(o.buyer.pay || 'TM/CK')}</span><span style="width:45%">Số tài khoản:</span></div></div>
  <table><thead><tr><th style="width:5%">STT</th><th>Tên hàng hóa, dịch vụ</th><th style="width:8%">Đơn vị tính</th><th style="width:10%">Số lượng</th><th style="width:11%">Đơn giá</th><th style="width:13%">Thành tiền</th><th style="width:8%">Thuế suất GTGT</th><th style="width:11%">Tiền thuế GTGT</th></tr></thead>
  <tbody>${tr}<tr><td>&nbsp;</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr></tbody></table>
  <table class=sum><thead><tr><th style="width:34%">Tổng hợp</th><th>Thành tiền trước thuế GTGT</th><th>Tiền thuế GTGT</th><th>Cộng tiền thanh toán</th></tr></thead><tbody>
  ${rate('Không kê khai thuế GTGT:', null)}${rate('Không chịu thuế GTGT:', null)}${rate('Thuế suất 0%:', '0%')}${rate('Thuế suất 5%:', '5%')}${rate('Thuế suất 8%:', '8%')}${rate('Thuế suất 10%:', '10%')}
  ${khac.length ? khac.map(k => rate(`Thuế suất ${k}:`, k)).join('') : rate('Thuế suất KHÁC:', null)}
  <tr class=tot><td>Tổng cộng:</td><td class=r>${money(sub)}</td><td class=r>${money(tax)}</td><td class=r>${money(sub + tax)}</td></tr></tbody></table>
  <div class=chu>Số tiền viết bằng chữ: <b><i>${docTien(sub + tax)}</i></b></div>
  <div class=sig><div><b>Người mua hàng</b><br><i>(Chữ ký số (nếu có))</i></div><div><b>Người bán hàng</b><br><i>(Chữ ký điện tử, Chữ ký số)</i><div class=ks>Chưa ký số<br>Ký bởi:<br>Ký ngày:</div></div></div>
  <div class=ft><div class=l>Tra cứu tại Website: https://www.meinvoice.vn/tra-cuu - Mã tra cứu:</div><div>(Cần kiểm tra, đối chiếu khi lập, giao, nhận hóa đơn)</div>
    <div>Bản xem trước lập từ dữ liệu ERP Nam Trung – chưa có giá trị pháp lý · Sale: ${esc(o.sale)}</div></div>
  </div></body></html>`);
  w.document.close(); return true;
}
