// Bản 28b — Kế toán: Excel toàn bộ dòng HĐ chính thức APT đã nạp (bảng gốc) để kiểm tiền VAT Nam Trung dự kiến xuất cho khách.
// Mỗi dòng = 1 mã hàng MISA trên HĐ ký APT. Giá xuất dự kiến = giá khách hệ thống đã gắn (đối soát / đơn hàng / sale chọn / phiếu).
// VAT Nam Trung xuất = SL nhập × giá khách × thuế suất (làm tròn từng dòng như MISA).
import { db, fetchAll } from './sb';
import { writeXlsx } from './xlsx';

const GIA_SRC: Record<string, string> = { doi_soat: 'Đối soát xe', don_hang: 'File đơn hàng', sale: 'Sale chọn / sửa', phieu: 'Theo phiếu xuất', so: 'Sổ cũ' };
const MATCH: Record<string, string> = { ten: 'Tên + SL khớp nháp', hd_xml: 'HĐ XML', md: 'Theo mã đơn (ước lượng)', tay: 'Kế toán ghép tay', nvkd: 'Theo NVKD', don_hang: 'Theo file đơn hàng', user: 'Theo username' };
const PST: Record<string, string> = { soan: 'đang soạn', cho_nhap: 'chờ xuất nháp', da_nhap: 'có nháp', xac_nhan_ky: 'chờ ký', da_ky: 'đã ký', cho_duyet_gia: 'chờ duyệt giá', tra_sua: 'trả sửa' };
const r0 = (x: number) => Math.round(x);
const chunks = <T,>(a: T[], n = 150) => Array.from({ length: Math.ceil(a.length / n) }, (_, i) => a.slice(i * n, i * n + n));

/** Danh sách HĐ vào đã nạp (để chọn khi xuất) */
export async function listHdVao(): Promise<{ so: string; ngay: string | null; n: number }[]> {
  const rows = await fetchAll<any>(() => db.from('out_items').select('so_hd_vao,ngay_vao').order('ngay_vao', { asc: false }), 50000);
  const m = new Map<string, { so: string; ngay: string | null; n: number }>();
  rows.forEach(r => { const k = r.so_hd_vao || '—'; const x = m.get(k) || { so: k, ngay: r.ngay_vao, n: 0 }; x.n++; m.set(k, x); });
  return Array.from(m.values()).sort((a, b) => String(b.ngay || '').localeCompare(String(a.ngay || '')) || b.so.localeCompare(a.so));
}

export async function exportHdChinhThuc(hds: string[] | null, personName: (id: string) => string): Promise<number> {
  const items = await fetchAll<any>(() => { let q = db.from('out_items_v').select('*').order('so_hd_vao').order('stt_so'); if (hds && hds.length) q = q.in('so_hd_vao', hds); return q; }, 100000);
  if (!items.length) throw new Error('Chưa có dòng HĐ chính thức nào');
  const lineIds = Array.from(new Set(items.map(t => t.acc_line_id).filter(Boolean))); const cusIds = Array.from(new Set(items.map(t => t.customer_id).filter(Boolean)));
  const lines = new Map<string, any>(); const cus = new Map<string, any>(); const trucks = new Map<string, string>();
  for (const c of chunks(lineIds)) (await db.from<any[]>('acc_lines').select('id,truck_id,ma_dong,md,hh,ten_apt,sl_apt,gia_nhap,gia_note,gia_de_xuat,gia_khach,bien_nt,luong,status,phan_hoi,vat').in('id', c) || []).forEach(l => lines.set(l.id, l));
  const tIds = Array.from(new Set(Array.from(lines.values()).map(l => l.truck_id).filter(Boolean)));
  for (const c of chunks(tIds)) (await db.from<any[]>('acc_trucks').select('id,name').in('id', c) || []).forEach(t => trucks.set(t.id, t.name));
  for (const c of chunks(cusIds)) (await db.from<any[]>('customers').select('id,code,sys_code,sys_username,company_name,contact_name').in('id', c) || []).forEach(x => cus.set(x.id, x));

  // tổng theo mã đơn để kế toán đối chiếu nhanh theo đơn
  const byMd = new Map<string, { tien: number; vat: number; n: number }>();
  const calc = (t: any) => { const sl = Number(t.sl_nhap) || 0; const gk = Number(t.gia_khach) || 0; const v = t.vat === null || t.vat === undefined ? null : Number(t.vat);
    const tienRa = gk ? r0(sl * gk) : 0; const vatRa = gk && v !== null ? r0(tienRa * v) : 0; return { sl, gk, v, tienRa, vatRa }; };
  items.forEach(t => { const k = t.md || '(chưa có mã đơn)'; const c = calc(t); const x = byMd.get(k) || { tien: 0, vat: 0, n: 0 }; x.tien += c.tienRa; x.vat += c.vatRa; x.n++; byMd.set(k, x); });

  const head = ['STT', 'Mã hàng (MISA)', 'Số HĐ APT', 'Ký hiệu', 'Ngày HĐ', 'Nhà cung cấp', 'STT dòng trên HĐ', 'Tên hàng hóa', 'ĐVT', 'Thuế suất',
    'SL nhập', 'Đơn giá nhập (APT)', 'Thành tiền nhập', 'Tiền thuế vào',
    'MÃ ĐƠN HÀNG', 'Mã khai báo', 'Xe đối soát', 'Mã KH', 'Tên khách', 'Username', 'Sale phụ trách', 'NVKD trên file',
    'Giá xuất khách (dự kiến)', 'Nguồn giá xuất', 'Biên NT (%)', 'Thành tiền xuất (dự kiến)', 'VAT NAM TRUNG XUẤT (dự kiến)', 'Tổng thanh toán xuất (dự kiến)', 'Chênh VAT ra − vào',
    'Tổng tiền xuất của mã đơn', 'Tổng VAT xuất của mã đơn',
    'SL đã lập phiếu', 'SL còn tồn', 'Phiếu xuất HĐ', 'Cách ghép nháp', 'Giá nháp APT', 'Giá đề xuất APT', 'Thuế suất nháp', 'Phản hồi APT', 'Lệch so với nháp', 'Kế toán chấp nhận lệch', 'Cảnh báo'];
  const out: any[][] = [head];
  let sum = { tienVao: 0, thueVao: 0, tienRa: 0, vatRa: 0 };
  items.forEach((t, i) => {
    const l = t.acc_line_id ? lines.get(t.acc_line_id) : null; const c = t.customer_id ? cus.get(t.customer_id) : null; const k = calc(t);
    const dg = Number(t.dg_nhap) || 0; const tienVao = r0(k.sl * dg); const thueVao = k.v !== null ? r0(tienVao * k.v) : 0;
    const bien = k.gk && dg ? Math.round((k.gk / dg - 1) * 10000) / 100 : '';
    const md = byMd.get(t.md || '(chưa có mã đơn)')!;
    const warn = [!t.md && 'Chưa có mã đơn', !k.gk && 'Chưa có giá xuất', k.v === null && 'Chưa có thuế suất', t.lech && !t.lech_ok_at && 'Lệch nháp — đang khóa',
      typeof bien === 'number' && bien < 2 && 'Biên dưới 2%', typeof bien === 'number' && bien > 4 && 'Biên trên 4% (chờ duyệt khi lập phiếu)', !t.customer_id && 'Chưa gắn khách'].filter(Boolean).join('; ');
    sum.tienVao += tienVao; sum.thueVao += thueVao; sum.tienRa += k.tienRa; sum.vatRa += k.vatRa;
    out.push([t.stt_so ?? i + 1, t.ma_hang + (t.part > 1 ? ` (phần ${t.part})` : ''), t.so_hd_vao || '', t.ky_hieu || '', t.ngay_vao || '', t.ncc || '', t.stt_hd ?? '', t.ten || '', t.dvt || '', k.v ?? '',
      k.sl, dg || '', tienVao, thueVao,
      t.md || '', t.ma_kb || l?.ma_dong || '', l ? trucks.get(l.truck_id) || '' : '', c?.sys_code || c?.code || '', c ? c.company_name || c.contact_name || '' : '', t.username || c?.sys_username || '', personName(t.sale_id) || '', t.nvkd || '',
      k.gk || '', GIA_SRC[t.gia_src] || t.gia_src || '', bien, k.tienRa || '', k.vatRa || '', k.tienRa ? k.tienRa + k.vatRa : '', k.vatRa ? k.vatRa - thueVao : '',
      md.tien || '', md.vat || '',
      Number(t.sl_xuat) || 0, Number(t.ton) || 0, (t.phieu || '').split(',').filter(Boolean).map((p: string) => { const [cd, st] = p.split(':'); return `${cd} (${PST[st] || st})`; }).join(', '),
      MATCH[t.match_src] || t.match_src || 'Chưa ghép', l ? Number(l.gia_note || l.gia_nhap) || '' : '', l?.gia_de_xuat ? Math.round(l.gia_de_xuat) : '', l?.vat ?? '', l?.phan_hoi || '',
      t.lech_note || '', t.lech_ok_at ? (t.lech_ok_note || 'Đã chấp nhận') : '', warn]);
  });
  const blank = head.map(() => ''); const tot = [...blank]; tot[7] = 'TỔNG CỘNG'; tot[12] = sum.tienVao; tot[13] = sum.thueVao; tot[25] = sum.tienRa; tot[26] = sum.vatRa; tot[27] = sum.tienRa + sum.vatRa; tot[28] = sum.vatRa - sum.thueVao;
  out.push(blank, tot);
  const ten = hds && hds.length === 1 ? `HD_APT_${hds[0]}` : hds && hds.length ? `HD_APT_${hds.length}_hoa_don` : 'HD_APT_tat_ca';
  const money = [11, 12, 13, 22, 25, 26, 27, 28, 29, 30, 35, 36];
  await writeXlsx(`${ten}_VAT_NT_du_kien_${new Date().toISOString().slice(0, 10)}`, out, 'HĐ chính thức APT', true,
    { fmt: { 9: 'pct', 37: 'pct', ...Object.fromEntries(money.map(j => [j, 'int'])) } as any });
  return items.length;
}
