// Bản 54 — In nhanh bộ chứng từ: bấm là mở hộp thoại in của trình duyệt (không phải tải .docx rồi mở Word)
//  · ĐĐH / BBGN: dựng lại đúng nội dung mẫu Word (public/mau-hd/ddh.docx, bbgn.docx) bằng HTML khổ A4, cùng dữ liệu docVars / docRows
//  · HĐ đã ký: in thẳng file PDF (lấy từ Drive / meInvoice)
import { docRows, docVars, type DocInv } from './hdDocs';

const esc = (s: any) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' } as any)[c]);
export type PrintKind = 'ddh' | 'bbgn';

const BAN = {
  ten: 'CÔNG TY TNHH DỊCH VỤ VÀ THƯƠNG MẠI QUỐC TẾ NAM TRUNG', dia_chi: 'Tầng 6, Tòa Icon 4, Số 243A Đê La Thành, Phường Láng, Thành phố Hà Nội, Việt Nam',
  mst: '0108195040', dai_dien: 'Ông Trần Chiến Thắng', chuc_vu: 'Giám đốc', stk: '117634318888', ngan_hang: 'Ngân hàng Vietinbank - Chi nhánh Hà Nội',
};
const QH = '<div class="c b">CỘNG HOÀ XÃ HỘI CHỦ NGHĨA VIỆT NAM</div><div class="c b">Độc lập – Tự do – Hạnh phúc</div><div class="c">-------***-------</div>';
const ky = (a: string, b: string) => `<table class="ky"><tr><td>${a}<div class="i">(Ký, ghi rõ họ tên)</div></td><td>${b}<div class="i">(Ký, ghi rõ họ tên, đóng dấu)</div></td></tr></table>`;

export function ddhHtml(v: DocInv): string {
  const d = docVars(v, 'ddh'); const { rows, tax } = docRows(v);
  return `<section>${QH}<h1>ĐƠN ĐẶT HÀNG</h1><div class="c">Số đơn hàng: <b>${esc(d.so_don)}</b></div>
<ol class="kv"><li>Tên công ty/ cá nhân: <b>${esc(d.ten_mua)}</b></li><li>Địa chỉ: ${esc(d.dia_chi)}</li><li>Mã số thuế: ${esc(d.mst)}</li>
<li>Địa chỉ giao hàng: ${esc(d.dia_chi_giao)}</li><li>Ngày giao hàng dự kiến: ${esc(d.ngay_giao)}</li><li>Thanh toán: ${esc(d.thanh_toan)}</li></ol>
<table class="g"><thead><tr><th>STT</th><th>Tên sản phẩm hàng hóa</th><th>ĐVT</th><th>Số lượng</th><th>Đơn giá</th><th>Thành tiền</th></tr></thead><tbody>
${rows.map(r => `<tr><td class="c">${esc(r.stt)}</td><td>${esc(r.ten_hang)}</td><td class="c">${esc(r.dvt)}</td><td class="r">${esc(r.sl)}</td><td class="r">${esc(r.don_gia)}</td><td class="r">${esc(r.thanh_tien)}</td></tr>`).join('')}
<tr><td colspan="5" class="b">CỘNG TIỀN</td><td class="r b">${esc(d.cong_tien)}</td></tr>
${tax.map(t => `<tr><td colspan="5" class="b">THUẾ GTGT ${esc(t.ts)}</td><td class="r b">${esc(t.tien_thue)}</td></tr>`).join('')}
<tr><td colspan="5" class="b">TỔNG THANH TOÁN</td><td class="r b">${esc(d.tong)}</td></tr></tbody></table>
<p>Viết bằng chữ: <i>${esc(d.bang_chu)}</i> ./.</p><p>Đơn đặt hàng này được lập thành 02 bản, mỗi bên giữ 01 bản và có giá trị pháp lý như nhau.</p>
${ky('<b>ĐẠI DIỆN BÊN MUA</b>', '<b>ĐẠI DIỆN BÊN BÁN</b>')}</section>`;
}

export function bbgnHtml(v: DocInv): string {
  const d = docVars(v, 'bbgn'); const { rows } = docRows(v);
  return `<section><table class="hd"><tr><td class="c b">${BAN.ten}<div>------o0o------</div></td><td class="c"><div class="b">CỘNG HOÀ XÃ HỘI CHỦ NGHĨA VIỆT NAM</div><div class="b">Độc lập - Tự do - Hạnh phúc</div><div>------o0o------</div></td></tr></table>
<h1>BIÊN BẢN GIAO NHẬN HÀNG HÓA</h1>
<p class="i">- Căn cứ hợp đồng số: ${esc(d.can_cu)}<br>- Căn cứ vào đơn hàng số: <b>${esc(d.so_don)}</b><br>- Căn cứ vào số lượng hàng hóa giao nhận giữa hai bên</p>
<p class="i">Hôm nay, ngày ${esc(d.ngay_chu)} chúng tôi gồm</p>
<p><b><u>BÊN BÁN:</u> ${BAN.ten}</b><br>Địa chỉ: ${BAN.dia_chi}<br>Mã số thuế: ${BAN.mst}<br>Đại diện: <b>${BAN.dai_dien}</b><span class="tab">Chức vụ: <b>${BAN.chuc_vu}</b></span><br>
Số tài khoản: ${BAN.stk}<br>${BAN.ngan_hang}<br>Sau đây gọi tắt là <b>Bên A</b></p>
<p><b><u>BÊN MUA:</u> ${esc(d.ten_mua)}</b><br>Địa chỉ: ${esc(d.dia_chi)}<br>Mã số thuế: ${esc(d.mst)}<br>Đại diện: <b>${esc(d.dai_dien)}</b><span class="tab">Chức vụ: <b>${esc(d.chuc_vu)}</b></span><br>Sau đây gọi tắt là <b>Bên B</b></p>
<p>Hai bên đồng ý xác nhận số lượng vật tư, hàng hóa đã giao nhận như sau:</p>
<table class="g"><thead><tr><th>STT</th><th>Tên hàng hóa</th><th>Đơn vị tính</th><th>Số lượng</th></tr></thead><tbody>
${rows.map(r => `<tr><td class="c">${esc(r.stt)}</td><td>${esc(r.ten_hang)}</td><td class="c">${esc(r.dvt)}</td><td class="r">${esc(r.sl)}</td></tr>`).join('')}</tbody></table>
<p>Biên bản này được lập thành 02 bản, mỗi bên giữ 01 bản và có giá trị pháp lý như nhau.</p>
${ky('<b>ĐẠI DIỆN BÊN MUA</b>', '<b>ĐẠI DIỆN BÊN BÁN</b>')}</section>`;
}

const CSS = `@page{size:A4;margin:15mm 15mm 15mm 20mm}*{box-sizing:border-box}body{font-family:"Times New Roman",Times,serif;font-size:13pt;line-height:1.35;color:#000;margin:0}
section{page-break-after:always}section:last-child{page-break-after:auto}h1{text-align:center;font-size:16pt;margin:14px 0 8px}p{margin:6px 0}
.c{text-align:center}.r{text-align:right}.b{font-weight:bold}.i{font-style:italic}.tab{margin-left:60px}
table.g{width:100%;border-collapse:collapse;margin:8px 0}table.g th,table.g td{border:1px solid #000;padding:3px 5px;vertical-align:top}table.g th{font-weight:bold;text-align:center}
table.hd{width:100%;border-collapse:collapse}table.hd td{width:50%;vertical-align:top;font-size:12pt}
table.ky{width:100%;margin-top:18px}table.ky td{width:50%;text-align:center;vertical-align:top;height:110px}table.ky .i{font-size:11pt}
ol.kv{margin:8px 0;padding-left:22px}ol.kv li{margin:3px 0}`;

/** In trong khung ẩn — mở hộp thoại in, không mở tab mới */
function printFrame(setup: (f: HTMLIFrameElement) => void) {
  const f = document.createElement('iframe');
  f.style.cssText = 'position:fixed;left:-12000px;top:0;width:210mm;height:297mm;border:0;opacity:0;pointer-events:none';
  document.body.appendChild(f);
  const done = () => setTimeout(() => f.remove(), 60000);
  f.onload = () => { setTimeout(() => { try { f.contentWindow!.focus(); f.contentWindow!.print(); } catch { /* trình duyệt chặn → mở tab */ if (f.src) window.open(f.src, '_blank'); } done(); }, 250); };
  setup(f);
}

/** In ĐĐH / BBGN của nhiều HĐ trong 1 lần (mỗi chứng từ 1 trang mới) */
export function printDocs(invs: DocInv[], kinds: PrintKind[]) {
  const body = invs.flatMap(v => kinds.map(k => (k === 'ddh' ? ddhHtml(v) : bbgnHtml(v)))).join('');
  const html = `<!doctype html><html lang="vi"><head><meta charset="utf-8"><title>In chứng từ</title><style>${CSS}</style></head><body>${body}</body></html>`;
  printFrame(f => { f.srcdoc = html; });
}

/** In HĐ đã ký (PDF) */
export function printPdf(pdf: Blob) {
  const url = URL.createObjectURL(pdf.type === 'application/pdf' ? pdf : new Blob([pdf], { type: 'application/pdf' }));
  printFrame(f => { f.src = url; });
  setTimeout(() => URL.revokeObjectURL(url), 120000);
}
