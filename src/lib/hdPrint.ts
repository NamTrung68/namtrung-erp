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
const QH = '<div class="qh"><div class="b">CỘNG HOÀ XÃ HỘI CHỦ NGHĨA VIỆT NAM</div><div class="b u2">Độc lập – Tự do – Hạnh phúc</div></div>';
const ky = (a: string, b: string) => `<table class="ky"><tr><td><div class="b">${a}</div><div class="i">(Ký, ghi rõ họ tên)</div></td><td><div class="b">${b}</div><div class="i">(Ký, ghi rõ họ tên, đóng dấu)</div></td></tr></table>`;
/** Bảng thông tin 2 cột: nhãn | giá trị */
const kv = (rows: [string, string][]) => `<table class="kv">${rows.map(([k, v]) => `<tr><td class="k">${k}</td><td>${v}</td></tr>`).join('')}</table>`;
const cols = (w: string[]) => `<colgroup>${w.map(x => `<col style="width:${x}">`).join('')}</colgroup>`;

export function ddhHtml(v: DocInv): string {
  const d = docVars(v, 'ddh'); const { rows, tax } = docRows(v);
  return `<section>${QH}<h1>ĐƠN ĐẶT HÀNG</h1><div class="sub">Số đơn hàng: <b>${esc(d.so_don)}</b></div>
${kv([['Tên công ty / cá nhân:', `<b>${esc(d.ten_mua)}</b>`], ['Địa chỉ:', esc(d.dia_chi)], ['Mã số thuế:', `<b>${esc(d.mst)}</b>`],
    ['Địa chỉ giao hàng:', esc(d.dia_chi_giao)], ['Ngày giao hàng dự kiến:', esc(d.ngay_giao)], ['Thanh toán:', esc(d.thanh_toan)]])}
<table class="g">${cols(['7%', '45%', '9%', '11%', '13%', '15%'])}<thead><tr><th>STT</th><th>Tên sản phẩm hàng hóa</th><th>ĐVT</th><th>Số lượng</th><th>Đơn giá</th><th>Thành tiền</th></tr></thead><tbody>
${rows.map(r => `<tr><td class="c">${esc(r.stt)}</td><td>${esc(r.ten_hang)}</td><td class="c">${esc(r.dvt)}</td><td class="r">${esc(r.sl)}</td><td class="r">${esc(r.don_gia)}</td><td class="r">${esc(r.thanh_tien)}</td></tr>`).join('')}
<tr class="sum"><td colspan="5" class="r">Cộng tiền hàng</td><td class="r b">${esc(d.cong_tien)}</td></tr>
${tax.map(t => `<tr class="sum"><td colspan="5" class="r">Thuế GTGT ${esc(t.ts)}</td><td class="r b">${esc(t.tien_thue)}</td></tr>`).join('')}
<tr class="sum tot"><td colspan="5" class="r b">TỔNG THANH TOÁN</td><td class="r b">${esc(d.tong)}</td></tr></tbody></table>
<p class="chu">Số tiền viết bằng chữ: <i>${esc(d.bang_chu)}</i>./.</p><p class="note">Đơn đặt hàng này được lập thành 02 bản, mỗi bên giữ 01 bản và có giá trị pháp lý như nhau.</p>
${ky('ĐẠI DIỆN BÊN MUA', 'ĐẠI DIỆN BÊN BÁN')}</section>`;
}

export function bbgnHtml(v: DocInv): string {
  const d = docVars(v, 'bbgn'); const { rows } = docRows(v);
  return `<section><table class="hd"><tr><td><div class="b">${BAN.ten}</div><div class="u2s"></div></td><td><div class="b">CỘNG HOÀ XÃ HỘI CHỦ NGHĨA VIỆT NAM</div><div class="b u2">Độc lập – Tự do – Hạnh phúc</div></td></tr></table>
<h1>BIÊN BẢN GIAO NHẬN HÀNG HÓA</h1>
<div class="cc"><div>- Căn cứ hợp đồng số: ${esc(d.can_cu)}</div><div>- Căn cứ vào đơn hàng số: <b>${esc(d.so_don)}</b></div><div>- Căn cứ vào số lượng hàng hóa giao nhận giữa hai bên.</div></div>
<p class="i">Hôm nay, ngày ${esc(d.ngay_chu)}, chúng tôi gồm:</p>
<div class="ben"><b>BÊN BÁN (Bên A): ${BAN.ten}</b></div>
${kv([['Địa chỉ:', BAN.dia_chi], ['Mã số thuế:', BAN.mst], ['Đại diện:', `<b>${BAN.dai_dien}</b><span class="tab">Chức vụ: <b>${BAN.chuc_vu}</b></span>`], ['Số tài khoản:', `${BAN.stk} – ${BAN.ngan_hang}`]])}
<div class="ben"><b>BÊN MUA (Bên B): ${esc(d.ten_mua)}</b></div>
${kv([['Địa chỉ:', esc(d.dia_chi)], ['Mã số thuế:', esc(d.mst)], ['Đại diện:', `<b>${esc(d.dai_dien)}</b><span class="tab">Chức vụ: <b>${esc(d.chuc_vu)}</b></span>`]])}
<p>Hai bên đồng ý xác nhận số lượng vật tư, hàng hóa đã giao nhận như sau:</p>
<table class="g">${cols(['8%', '62%', '14%', '16%'])}<thead><tr><th>STT</th><th>Tên hàng hóa</th><th>Đơn vị tính</th><th>Số lượng</th></tr></thead><tbody>
${rows.map(r => `<tr><td class="c">${esc(r.stt)}</td><td>${esc(r.ten_hang)}</td><td class="c">${esc(r.dvt)}</td><td class="r">${esc(r.sl)}</td></tr>`).join('')}</tbody></table>
<p class="note">Biên bản này được lập thành 02 bản, mỗi bên giữ 01 bản và có giá trị pháp lý như nhau.</p>
${ky('ĐẠI DIỆN BÊN MUA', 'ĐẠI DIỆN BÊN BÁN')}</section>`;
}

// Bản 59: cỡ chữ ~ hóa đơn điện tử (11pt, bảng 10pt), lề A4 gọn, bảng kẻ mảnh, nhãn thẳng cột
const CSS = `@page{size:A4;margin:14mm 14mm 14mm 18mm}*{box-sizing:border-box}
body{font-family:"Times New Roman",Times,serif;font-size:11pt;line-height:1.4;color:#000;margin:0;-webkit-print-color-adjust:exact;print-color-adjust:exact}
section{page-break-after:always}section:last-child{page-break-after:auto}
.c{text-align:center}.r{text-align:right}.b{font-weight:bold}.i{font-style:italic}.tab{margin-left:40px}
.qh{text-align:center;font-size:11pt;line-height:1.35}.u2{display:inline-block;padding-bottom:2px;border-bottom:1px solid #000}
h1{text-align:center;font-size:15pt;letter-spacing:.5px;margin:16px 0 2px}.sub{text-align:center;margin-bottom:12px}
p{margin:5px 0}.note{font-style:italic;font-size:10.5pt;margin-top:8px}.chu{margin-top:6px}
table.hd{width:100%;border-collapse:collapse;margin-bottom:4px}table.hd td{width:50%;vertical-align:top;text-align:center;font-size:10.5pt;line-height:1.35;padding:0 4px}
.u2s{width:35%;margin:3px auto 0;border-bottom:1px solid #000}
.cc{font-style:italic;margin:4px 0 6px 12mm;font-size:10.5pt}
.ben{margin:8px 0 2px}
table.kv{width:100%;border-collapse:collapse;margin:2px 0 6px}table.kv td{padding:1.5px 0;vertical-align:top}table.kv td.k{width:44mm;white-space:nowrap;padding-right:6px}
table.g{width:100%;border-collapse:collapse;margin:8px 0 4px;font-size:10pt;table-layout:fixed}
table.g th,table.g td{border:0.6pt solid #333;padding:3px 5px;vertical-align:middle;word-wrap:break-word}
table.g thead th{font-weight:bold;text-align:center;background:#f0f0f0}table.g thead{display:table-header-group}table.g tr{page-break-inside:avoid}
table.g tr.sum td{background:#fafafa}table.g tr.tot td{background:#eee;font-size:10.5pt}
table.ky{width:100%;margin-top:16px;page-break-inside:avoid}table.ky td{width:50%;text-align:center;vertical-align:top;height:105px}table.ky .i{font-size:10pt}`;

/** In trong khung ẩn — mở hộp thoại in, không mở tab mới. Xong (đóng hộp thoại in) mới resolve để in tiếp chứng từ sau */
function printFrame(setup: (f: HTMLIFrameElement) => void): Promise<void> {
  return new Promise(res => {
    const f = document.createElement('iframe');
    f.style.cssText = 'position:fixed;left:-12000px;top:0;width:210mm;height:297mm;border:0;opacity:0;pointer-events:none';
    document.body.appendChild(f);
    let done = false; const fin = () => { if (done) return; done = true; setTimeout(() => f.remove(), 60000); setTimeout(res, 300); };
    f.onload = () => { setTimeout(() => {
      const w = f.contentWindow;
      try { w?.addEventListener('afterprint', fin); } catch { /* PDF viewer */ }
      try { w!.focus(); w!.print(); } catch { if (f.src) window.open(f.src, '_blank'); fin(); return; }
      // Chrome / Edge / Firefox: print() dừng tới khi đóng hộp thoại in → chạy tới đây là đã in xong (hoặc bấm Hủy)
      fin();
    }, 250); };
    setup(f);
  });
}

/** Bản 58: in từng loại chứng từ thành từng lệnh in riêng (in ĐĐH xong mới mở in BBGN) — mỗi lệnh chọn được số bản */
export async function printDocs(invs: DocInv[], kinds: PrintKind[]) {
  for (const k of kinds) {
    const body = invs.map(v => (k === 'ddh' ? ddhHtml(v) : bbgnHtml(v))).join('');
    const html = `<!doctype html><html lang="vi"><head><meta charset="utf-8"><title>${k === 'ddh' ? 'Đơn đặt hàng' : 'Biên bản giao nhận'}</title><style>${CSS}</style></head><body>${body}</body></html>`;
    await printFrame(f => { f.srcdoc = html; });
  }
}

/** In HĐ đã ký (PDF) */
export async function printPdf(pdf: Blob) {
  const url = URL.createObjectURL(pdf.type === 'application/pdf' ? pdf : new Blob([pdf], { type: 'application/pdf' }));
  setTimeout(() => URL.revokeObjectURL(url), 600000);
  await printFrame(f => { f.src = url; });
}
