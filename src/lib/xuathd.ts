// Sổ HĐ đầu vào → đầu ra của kế toán (file Excel "Xuathd"): đọc, và xuất lại đúng mẫu + file nhập HĐ nháp
import { stripAcc, clean, vnNum } from './doisoat';
import { toISODate } from './xlsx';

const H = (s: any) => stripAcc(clean(s)).toUpperCase().replace(/\s+/g, ' ').trim();
export interface SoRow {
  ma_hang: string; part: number; gia_so: number | null; stt_so: number | null; ten: string; dvt: string; vat: number | null; sl_nhap: number; dg_nhap: number | null;
  so_hd_vao: string; ky_hieu: string; ngay_vao: string | null; ncc: string; stt_hd: number | null; md: string; nvkd: string; username: string;
  legacy: Record<string, any> | null; row: number;
}
/** Bóc tên đơn vị, MST, địa chỉ, email từ ô "THÔNG TIN BÁO XUẤT HÓA ĐƠN" gõ tự do */
export function parseInfo(text: string): { buyer_name: string; tax_code: string; address: string; email: string } {
  const ls = String(text || '').split(/\n+/).map(x => x.replace(/^["“”\s]+|["“”\s]+$/g, '').trim()).filter(Boolean);
  const val = (x: string) => x.replace(/^[^:]*:\s*/, '').trim();
  const email = (String(text).match(/[\w.+-]+@[\w-]+(\.[\w-]+)+/) || [''])[0];
  const mstL = ls.find(x => /(MST|mã số thuế|tax code)/i.test(x)); const mst = ((mstL || '').match(/\d{12}|\d{10}(-\d{3})?/) || (String(text).match(/\b(\d{12}|\d{10}(-\d{3})?)\b/) || ['']))[0];
  const addrL = ls.find(x => /^(đ\/c|địa chỉ|dia chi|đc|address)/i.test(stripAcc(x).toLowerCase()) || /^(Đ\/C|Địa chỉ)/i.test(x));
  const nameL = ls.find(x => /(CÔNG TY|CTY|HỘ KINH DOANH|HKD|DOANH NGHIỆP|CHI NHÁNH|Tên đơn vị|Tên:)/i.test(x) && !/xuất giá/i.test(x))
    || ls.find(x => !/(xuất giá|^stt|^sl\b|mst|mã số thuế|địa chỉ|đ\/c|mail|@)/i.test(x) && !/^\d+$/.test(x));
  return { buyer_name: nameL ? val(nameL).replace(/\s*\(.*?\)\s*:?/g, ' ').trim() || nameL : '', tax_code: mst || '', address: addrL ? val(addrL) : '', email };
}
export interface LegacyGroup { status: 'da_ky' | 'da_nhap' | 'xac_nhan_ky'; so_hd: string; ngay: string | null; info: string; buyer_name?: string; tax_code?: string; address?: string; email?: string; lines: { ma_hang: string; part: number; sl: number; gia: number; vat: number | null }[] }

const intStr = (v: any) => { if (v === null || v === undefined || v === '') return ''; if (typeof v === 'number') return Number.isInteger(v) ? String(v) : ''; return clean(v); };
const isoD = (v: any) => (v instanceof Date ? v.toISOString().slice(0, 10) : toISODate(v));

/** Đọc sổ (cần đọc với fillMerged để cột thông tin/trạng thái gộp ô được điền xuống) */
export function parseSoXuat(rows: any[][]): { rows: SoRow[]; legacy: LegacyGroup[]; warnings: string[] } {
  const hi = rows.slice(0, 20).findIndex(r => (r || []).some(x => H(x) === 'MA HANG') && (r || []).some(x => H(x).startsWith('TEN HANG')));
  if (hi < 0) throw new Error('Không thấy dòng tiêu đề có cột "Mã hàng" và "Tên hàng hoá"');
  const hd = (rows[hi] || []).map(H);
  const find = (pred: (h: string) => boolean, from = 0) => { for (let i = from; i < hd.length; i++) if (hd[i] && pred(hd[i])) return i; return -1; };
  const c = {
    stt: find(h => h === 'STT'), ma: find(h => h === 'MA HANG'), ten: find(h => h.startsWith('TEN HANG')), dvt: find(h => h.startsWith('DON VI TINH') || h === 'DVT'),
    ts: find(h => h.startsWith('THUE SUAT')), sln: find(h => h.startsWith('SO LUONG NHAP')), dgn: find(h => h.startsWith('DON GIA NHAP')),
    sohd: find(h => h.startsWith('SO HOA DON')), kh: find(h => h.startsWith('KY HIEU')), ngay: find(h => h.startsWith('NGAY NHAP')), ncc: find(h => h.includes('NHA CUNG CAP')),
    id: find(h => h === 'ID' || h.startsWith('ID ') || h.startsWith('ID\n') || /^ID\b/.test(h)), nvkd: find(h => h === 'NVKD' || h.startsWith('NVKD')), user: find(h => h === 'USER' || h.startsWith('USERNAME')),
    slx: -1, dgx: -1, sohdx: -1, ngayx: -1, info: find(h => h.startsWith('THONG TIN BAO XUAT')), tt: find(h => h.startsWith('TRANG THAI')), kdky: find(h => h.startsWith('KD XAC NHAN')), gc: -1,
  };
  c.slx = find(h => h.startsWith('SO LUONG XUAT')); c.dgx = find(h => h.startsWith('DON GIA XUAT'), Math.max(0, c.slx));
  if (c.dgx < 0) c.dgx = find(h => /^(GIA XUAT|GIA KHACH|DON GIA BAN|GIA BAN)/.test(h));
  c.sohdx = find(h => h.startsWith('SO HOA DON'), Math.max(0, c.slx)); c.ngayx = find(h => h.startsWith('NGAY XUAT'));
  c.gc = c.tt >= 0 ? find(h => h.startsWith('DON GIA XUAT'), c.tt) : -1;
  for (const k of ['ma', 'ten', 'sln', 'sohd'] as const) if ((c as any)[k] < 0) throw new Error('Sổ thiếu cột: ' + ({ ma: 'Mã hàng', ten: 'Tên hàng hoá', sln: 'Số lượng nhập', sohd: 'Số hóa đơn' } as any)[k]);
  const g = (r: any[], i: number) => (i >= 0 ? r[i] : null);
  const out: SoRow[] = []; const warnings: string[] = []; const groups = new Map<string, LegacyGroup>(); const seen = new Map<string, number>();
  rows.slice(hi + 1).forEach((r, k) => {
    const ma = clean(g(r, c.ma)).toUpperCase(); if (!ma || !clean(g(r, c.ten))) return;
    // 1 mã hàng chia nhiều dòng (xuất cho nhiều khách) → mỗi dòng là 1 phần riêng
    const part = (seen.get(ma) || 0) + 1; seen.set(ma, part);
    const m = ma.match(/^HH0*(\d+)-(\d+)/); const idv = g(r, c.id);
    const md = idv === null || idv === undefined || idv === '' ? '' : typeof idv === 'number' ? String(Math.round(idv)) : clean(idv).toUpperCase();
    const slx = vnNum(g(r, c.slx)), dgx = vnNum(g(r, c.dgx)), ngx = isoD(g(r, c.ngayx)), info = clean(String(g(r, c.info) ?? '').replace(/\r/g, '')) ? String(g(r, c.info)).trim() : '';
    const st = H(g(r, c.tt)), kd = H(g(r, c.kdky)), sohdx = intStr(g(r, c.sohdx)).replace(/\s+/g, ', ');
    const status: LegacyGroup['status'] | null = st.includes('DA KY') ? 'da_ky' : st.includes('NHAP') ? (kd.startsWith('KY') ? 'xac_nhan_ky' : 'da_nhap') : ngx ? 'da_ky' : null;
    const sl_nhap = vnNum(g(r, c.sln)) || 0; const vat = vnNum(g(r, c.ts));
    const legacy = status || info || slx ? { status, info: info || null, so_hd_ra: sohdx || null, ngay_ra: ngx, sl_xuat: slx, dg_xuat: dgx, kd_ky: clean(g(r, c.kdky)) || null, ghi_chu: typeof g(r, c.gc) === 'string' ? clean(g(r, c.gc)) : null } : null;
    const gcv = g(r, c.gc); const gia_so = dgx || (typeof gcv === 'number' ? gcv : null);
    out.push({ ma_hang: ma, part, gia_so, stt_so: vnNum(g(r, c.stt)), ten: clean(g(r, c.ten)), dvt: clean(g(r, c.dvt)), vat, sl_nhap, dg_nhap: vnNum(g(r, c.dgn)),
      so_hd_vao: intStr(g(r, c.sohd)) || (m ? m[2] : ''), ky_hieu: clean(g(r, c.kh)), ngay_vao: isoD(g(r, c.ngay)), ncc: clean(g(r, c.ncc)), stt_hd: m ? Number(m[1]) : null,
      md, nvkd: clean(g(r, c.nvkd)), username: clean(g(r, c.user)), legacy, row: hi + 2 + k });
    if (status) {
      const key = [status, sohdx, ngx, info].join('|'); const gr = groups.get(key) || { status, so_hd: sohdx, ngay: ngx, info, ...parseInfo(info), lines: [] };
      gr.lines.push({ ma_hang: ma, part, sl: slx || sl_nhap, gia: dgx || 0, vat }); groups.set(key, gr);
    }
  });
  return { rows: out, legacy: Array.from(groups.values()), warnings };
}

/** File đơn hàng (tùy chọn): cột mã đơn/ID, NVKD/Sale, Username; thêm Tên hàng, SL, Đơn giá xuất để có giá theo đơn */
export interface OrderRow { md: string; nvkd: string; username: string; ten?: string; sl?: number | null; gia?: number | null }
export function parseOrders(rows: any[][]): OrderRow[] {
  const hi = rows.slice(0, 15).findIndex(r => (r || []).some(x => /^(ID|MD|MA DON|MA DON HANG|DON HANG)\b/.test(H(x))));
  if (hi < 0) throw new Error('File đơn hàng: không thấy cột mã đơn (ID / Mã đơn / MD)');
  const hd = (rows[hi] || []).map(H); const f = (re: RegExp) => hd.findIndex(h => re.test(h));
  const im = f(/^(ID|MD|MA DON|MA DON HANG|DON HANG)\b/), is = f(/^(NVKD|SALE|NHAN VIEN|NV KINH DOANH)/), iu = f(/^(USERNAME|USER|TAI KHOAN|MA KH|KHACH)/);
  const it = f(/^(TEN HANG|TEN SAN PHAM|SAN PHAM|TEN SP|HANG HOA)/), isl = f(/^(SO LUONG|SL)\b/), ig = f(/^(DON GIA XUAT|GIA XUAT|GIA KHACH|DON GIA BAN|GIA BAN)/);
  if (is < 0 && iu < 0 && ig < 0) throw new Error('File đơn hàng cần thêm cột NVKD/Sale, Username hoặc Đơn giá xuất');
  const idStr = (v: any) => (typeof v === 'number' ? String(Math.round(v)) : clean(v));
  return rows.slice(hi + 1).map(r => ({ md: idStr(r?.[im]), nvkd: is >= 0 ? clean(r?.[is]) : '', username: iu >= 0 ? clean(r?.[iu]) : '',
    ten: it >= 0 ? clean(r?.[it]) : '', sl: isl >= 0 ? vnNum(r?.[isl]) : null, gia: ig >= 0 ? vnNum(r?.[ig]) : null })).filter(x => x.md);
}

/** File nhập HĐ nháp theo đúng mẫu MISA "Hóa đơn GTGT": 6 dòng hướng dẫn, tiêu đề ở dòng 9, mỗi phiếu = 1 số thứ tự HĐ */
export const MISA_HEAD = ['Số thứ tự hóa đơn (*)', 'Ngày hóa đơn', 'Tên đơn vị mua hàng', 'Địa chỉ', 'Mã số thuế', 'Người mua hàng', 'Email', 'Hình thức thanh toán', 'Mã HH',
  'Tên hàng hóa/dịch vụ (*)', 'ĐVT', 'Số lượng', 'Đơn giá', 'Thành tiền', 'Thuế suất GTGT (%)', 'Tiền thuế GTGT'];
export const MISA_HEADER_ROW = 8;
export function misaRows(invs: any[], ngay = ''): any[][] {
  const out: any[][] = [['File mẫu danh sách hóa đơn để nhập vào phần mềm '], ['Hướng dẫn:'], ['- Điền dữ liệu hóa đơn cần lập trên phần mềm vào các cột tương ứng trên file này'],
    ['- Các cột có dấu (*) là những cột bắt buộc'], ['- Nếu muốn nhập thêm thông tin khác, người dùng có thể tự thêm cột trên file này (VD: Mã khách hàng, Mã hàng, Tỷ lệ chiết khấu,...)'],
    ['- Các dòng dữ liệu phía dưới chỉ là ví dụ minh họa'], [], [], MISA_HEAD];
  invs.forEach((v, i) => (v.out_invoice_lines || []).slice().sort((a: any, b: any) => a.stt - b.stt).forEach((l: any) => {
    const tt = Math.round(Number(l.sl) * Number(l.don_gia)); const vat = l.vat ?? l.out_items?.vat;
    out.push([i + 1, ngay, v.buyer_name, v.address || '', v.tax_code || '', v.buyer_person || '', v.email || '', v.payment || 'TM/CK', l.out_items?.ma_hang, l.out_items?.ten, l.out_items?.dvt,
      Number(l.sl), Number(l.don_gia), tt, vat === null || vat === undefined ? '' : Number(vat), vat === null || vat === undefined ? '' : Math.round(tt * Number(vat))]);
  }));
  return out;
}
/** Bảng đối chiếu số thứ tự HĐ trong file nháp ↔ mã phiếu ERP (kế toán giữ để đánh dấu) */
export function misaMap(invs: any[], personName: (id: string) => string): any[][] {
  return [['Số thứ tự hóa đơn', 'Mã phiếu ERP', 'Sale', 'Đơn vị mua hàng', 'Mã số thuế', 'Số dòng'], ...invs.map((v, i) => [i + 1, v.code, personName(v.sale_id), v.buyer_name, v.tax_code || '', (v.out_invoice_lines || []).length])];
}
/** Danh sách đơn vị nhận HĐ (sheet "Thong tin KH": MST, Tên đơn vị, Địa chỉ, mail nhận HĐ) */
export interface BuyerRow { tax_code: string; name: string; address: string; email: string; username: string; dai_dien?: string; chuc_vu?: string; dia_chi_giao?: string; ma_hdnt?: string; ngay_hdnt?: string }
/** Ngày dd/mm/yyyy, yyyy-mm-dd hoặc số ngày Excel → yyyy-mm-dd; trống → ''; sai → '?' */
const dmy = (v: any): string => { if (v === null || v === undefined || v === '') return ''; if (typeof v === 'number') return new Date(Math.round((v - 25569) * 864e5)).toISOString().slice(0, 10);
  if (v instanceof Date) return v.toISOString().slice(0, 10); const s = String(v).trim(); let m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/); if (m) return `${m[1]}-${m[2].padStart(2, '0')}-${m[3].padStart(2, '0')}`;
  m = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/); return m ? `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}` : '?'; };
export function parseBuyers(sheets: { sheet: string; rows: any[][] }[]): BuyerRow[] {
  for (const sh of sheets) {
    const hi = sh.rows.slice(0, 10).findIndex(r => (r || []).some(x => H(x) === 'MST' || H(x).startsWith('MA SO THUE')) && (r || []).some(x => H(x).startsWith('TEN DON VI')));
    if (hi < 0) continue;
    const hd = (sh.rows[hi] || []).map(H); const f = (p: (h: string) => boolean) => hd.findIndex(h => !!h && p(h));
    const im = f(h => h === 'MST' || h.startsWith('MA SO THUE')), it = f(h => h.startsWith('TEN DON VI')), ia = f(h => h.startsWith('DIA CHI')), ie = f(h => h.includes('MAIL'));
    const iu = f(h => /^(USERNAME|USER|TAI KHOAN|MA KH)/.test(h));
    const idd = f(h => h.startsWith('NGUOI DAI DIEN') || h === 'DAI DIEN'), icv = f(h => h.startsWith('CHUC VU')), igh = f(h => h.startsWith('DIA CHI GIAO')),
      inm = f(h => h.startsWith('MA HD NGUYEN TAC') || h.startsWith('MA HOP DONG NGUYEN TAC') || h === 'MA HDNT'), ind = f(h => h.startsWith('NGAY HD NGUYEN TAC') || h.startsWith('NGAY HOP DONG NGUYEN TAC') || h === 'NGAY HDNT');
    const ia2 = ia === igh ? f(h => h.startsWith('DIA CHI') && !h.startsWith('DIA CHI GIAO')) : ia;
    const o = (r: any[], i: number) => (i >= 0 ? clean(r?.[i]) : '');
    return sh.rows.slice(hi + 1).map(r => ({ tax_code: intStr(r?.[im]).replace(/\s/g, ''), name: clean(r?.[it]), address: o(r, ia2), email: ie >= 0 ? clean(r?.[ie]) : '', username: iu >= 0 ? clean(r?.[iu]) : '',
      dai_dien: o(r, idd), chuc_vu: o(r, icv), dia_chi_giao: o(r, igh), ma_hdnt: o(r, inm), ngay_hdnt: ind >= 0 ? dmy(r?.[ind]) : '' }))
      .filter(x => x.name && x.tax_code);
  }
  throw new Error('Không thấy sheet có cột "MST" và "Tên đơn vị"');
}

const ST_TXT: Record<string, string> = { soan: 'Sale đang soạn', cho_nhap: 'Chờ xuất nháp', da_nhap: 'Đã xuất nháp', xac_nhan_ky: 'Đã xuất nháp', da_ky: 'Đã ký', huy: 'Hủy' };
/** Sổ theo đúng mẫu file kế toán (mỗi lần xuất = 1 dòng; dòng chia nhiều đơn vị → nhiều dòng) */
export function soRows(items: any[], lines: any[], personName: (id: string) => string): any[][] {
  const head = ['STT', 'Mã hàng', 'Tên hàng hoá', 'Đơn vị tính', 'Thuế suất', 'Số lượng  nhập ', 'Đơn giá nhập ', 'Thành Tiền', 'Tiền thuế vào', 'Số hóa đơn', 'Ký hiệu HĐ', 'Ngày nhập ', 'Tên nhà cung cấp',
    'ID', 'NVKD', 'USER', 'Số lượng xuất', 'Đơn giá xuất', 'Check', 'Thành tiền', 'Thuế Suất', 'Tiền thuế ra', 'Số hóa đơn', 'Ngày xuất', 'TỒN', 'THÔNG TIN BÁO XUẤT HÓA ĐƠN', 'Trạng thái', 'Đơn giá xuất', 'KD xác nhận ký', 'Mã phiếu ERP'];
  const by = new Map<string, any[]>(); lines.forEach(l => { const a = by.get(l.item_id) || []; a.push(l); by.set(l.item_id, a); });
  const out: any[][] = [head];
  items.slice().sort((a, b) => (a.stt_so ?? 0) - (b.stt_so ?? 0)).forEach(t => {
    const tt = Math.round(Number(t.sl_nhap) * Number(t.dg_nhap || 0)); const ls = (by.get(t.id) || []).filter(l => l.out_invoices?.status !== 'huy');
    const base = [t.stt_so, t.ma_hang, t.ten, t.dvt, t.vat, Number(t.sl_nhap), Number(t.dg_nhap) || '', tt, Math.round(tt * Number(t.vat || 0)), t.so_hd_vao, t.ky_hieu, t.ngay_vao, t.ncc,
      t.md || '', personName(t.sale_id) || t.nvkd || '', t.username || ''];
    const ton = Number(t.sl_nhap) - ls.reduce((x, l) => x + Number(l.sl), 0);
    if (!ls.length) { out.push([...base, '', '', '', '', '', '', '', '', ton, '', '', '', '', '']); return; }
    ls.forEach(l => { const v = l.out_invoices || {}; const ttx = Math.round(Number(l.sl) * Number(l.don_gia)); const vat = l.vat ?? t.vat;
      const info = v.buyer_info || [v.buyer_name, v.tax_code && 'MST: ' + v.tax_code, v.address && 'Địa chỉ: ' + v.address, v.email && 'Email: ' + v.email].filter(Boolean).join('\n');
      out.push([...base, Number(l.sl), Number(l.don_gia), '', ttx, vat, Math.round(ttx * Number(vat || 0)), v.so_hd || '', v.ngay_hd || '', ton, info, ST_TXT[v.status] || '', Number(l.don_gia),
        ['xac_nhan_ky', 'da_ky'].includes(v.status) ? 'Ký' : '', v.code || '']); });
  });
  return out;
}

// ---------- File mẫu để nạp đúng cột ----------
export const TPL_SO: any[][] = [['STT', 'Mã hàng', 'Tên hàng hoá', 'Đơn vị tính', 'Thuế suất', 'Số lượng nhập', 'Đơn giá nhập', 'Số hóa đơn', 'Ký hiệu HĐ', 'Ngày nhập', 'Tên nhà cung cấp', 'ID', 'NVKD', 'USER', 'Đơn giá xuất'],
  [1, 'HH00001-2080-2026', 'Hộp đựng giấy vải polyester, KT 18*12*9.5cm, mới 100%', 'Chiếc', 0.08, 400, 50000, 2080, '1C26TAP', '30/10/2026', 'CÔNG TY TNHH APT', 'MD2638', 'Lê Thị Minh Khơi', 'manhhuynh', 54000],
  [2, 'HH00002-2080-2026', 'Cốc sứ trắng men 350ml, mới 100%', 'Cái', 0.1, 120, 70000, 2080, '1C26TAP', '30/10/2026', 'CÔNG TY TNHH APT', 'MD2638', 'Lê Thị Minh Khơi', 'manhhuynh', 80000]];
export const TPL_ORDERS: any[][] = [['Mã đơn hàng', 'Username', 'Sale', 'Tên hàng', 'Số lượng', 'Đơn giá xuất'],
  ['MD2638', 'manhhuynh', 'Lê Thị Minh Khơi', 'Hộp đựng giấy vải polyester', 400, 54000],
  ['MD2638', 'manhhuynh', 'Lê Thị Minh Khơi', 'Cốc sứ trắng men 350ml', 120, 80000],
  ['MD2474', 'lethucphuong11', 'Vũ Thị Thúy', '', '', '']];
export const TPL_BUYERS: any[][] = [['MST', 'Tên đơn vị', 'Địa chỉ', 'Mail nhận HĐ', 'Username'],
  ['0700871570', 'CÔNG TY TNHH ABC', 'Số 1 Đê La Thành, Hà Nội', 'ketoan@abc.vn', 'abc_shop'],
  ['001190005010', 'Nguyễn Văn A (cá nhân, MST = số CCCD)', 'Hà Nội', 'a@gmail.com', 'nguyenvana']];
