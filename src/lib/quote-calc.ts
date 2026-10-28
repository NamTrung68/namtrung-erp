// Công thức báo giá Nam Trung (calcCore) — một bản duy nhất, dùng cho cả màn hình và bản in.
// Server kiểm lại khung giá CẤM/DUYỆT trong app.quote_check (SQL).

export type InvoiceMode = 'du' | 'thap' | 'cao';

export interface QuoteHeader {
  tyGia: number;
  shipNoiDiaCNY: number;
  soKg: number;
  donGiaKg: number;
  soKhoi: number;
  donGiaKhoi: number;
  phiDVPct: number;
  phiDVCoDinh: number;      // > 0 thì thay cho % phí dịch vụ, in là "trọn gói"
  phiUTPct: number;
  cheDoXuat: InvoiceMode;
  pctXuat: number;          // % so với giá đủ (xuất thấp/cao)
  tndnPct: number;
  coSoUyThac: 'giaXuat' | 'tienHang';
  coSoThueNK: 'toKhai' | 'giaXuat';
  phiKeKhai: number;
  phiHopQuy: number;
  phiKTCL: number;
  phiKhac: number;
  tenPhiKhac: string;
  lamTron: number;
  lamTronKieu: 'gan' | 'len';
  heSoToKhai: number;
  vatPct: number;
  khoNhan: string;
  hinhThucNK?: string;
  maDonHeThong?: string;
  ghiChu?: string;
  tyGiaVon?: number;
  giaVonKhoi?: Record<string, number>;
  phiUTSan?: number;
}

export interface QuoteLine {
  name: string;
  spec?: string;
  hs_code?: string;
  unit?: string;
  qty: number;
  unit_price_cny: number;
  duty_pct?: number | null;
  vat_pct?: number | null;
  freight_pct?: number | null;
  manual_price?: number | null;
}

export interface LineResult {
  idx: number;
  tienHang: number;
  ship: number;
  cuoc: number;
  phiDV: number;
  phuPhi: number;
  chiPhi: number;
  freightPct: number;
  giaDu: number;        // giá xuất đủ (A) / ĐV, đã làm tròn
  giaXuat: number;      // giá xuất thực tế / ĐV
  tongTruocVAT: number;
  giaKhaiDV: number;
  triGiaKhai: number;
  thueNK: number;
  vat: number;
  vatPct: number;
  dutyPct: number;
}

export interface QuoteTotals {
  tienHangCNY: number;
  tienHang: number;
  ship: number;
  cuoc: number;
  cuocTheoKg: number;
  cuocTheoKhoi: number;
  phiDV: number;
  phiUT: number;
  phuPhi: number;
  thueNK: number;
  giaDu: number;          // tổng giá đủ (A) trước VAT
  tongTruocVAT: number;
  vat: number;
  tongSauVAT: number;
  tndn: number;
  soThu: number;
  chenh: number;          // HĐ sau VAT − số thu
  chenhLamTron: number;   // đưa vào LN (chỉ chế độ đủ giá trị)
  toKhai: number;
  lnUocTinh: number;
  lnChiTiet: { tyGia: number; cuoc: number; uyThac: number; phiDV: number; lamTron: number };
  coc: number;
  warnings: string[];
}

export interface QuoteResult { lines: LineResult[]; totals: QuoteTotals; errors: string[] }

const n = (x: unknown, d = 0) => {
  const v = typeof x === 'string' ? parseFloat(x.replace(/,/g, '')) : Number(x);
  return Number.isFinite(v) ? v : d;
};
const r0 = (x: number) => Math.round(x + (x >= 0 ? 1e-9 : -1e-9));

export function roundTo(x: number, step: number, kieu: 'gan' | 'len' = 'gan') {
  const s = step > 0 ? step : 1;
  const q = x / s;
  const k = kieu === 'len' ? Math.ceil(q - 1e-9) : Math.round(q + 1e-9);
  return +(k * s).toFixed(6);
}

export const defaultHeader = (cfg: Partial<QuoteHeader> & Record<string, any> = {}): QuoteHeader => ({
  tyGia: n(cfg.tyGia, 4015),
  shipNoiDiaCNY: 0, soKg: 0, donGiaKg: n(cfg.donGiaKg, 7000), soKhoi: 0, donGiaKhoi: n(cfg.donGiaKhoi, 1100000),
  phiDVPct: n(cfg.phiDVPct, 2), phiDVCoDinh: 0, phiUTPct: n(cfg.phiUTPct, 1),
  cheDoXuat: 'du', pctXuat: 100, tndnPct: n(cfg.tndnPct, 20),
  coSoUyThac: (cfg.coSoUyThac as any) || 'giaXuat', coSoThueNK: (cfg.coSoThueNK as any) || 'toKhai',
  phiKeKhai: 0, phiHopQuy: 0, phiKTCL: 0, phiKhac: 0, tenPhiKhac: '',
  lamTron: n(cfg.lamTron, 1), lamTronKieu: (cfg.lamTronKieu as any) || 'gan',
  heSoToKhai: n(cfg.heSoToKhai, 0.9425), vatPct: n(cfg.vatPct, 8), khoNhan: 'HN',
  tyGiaVon: n(cfg.tyGiaVon, 3955), giaVonKhoi: cfg.giaVonKhoi || { HN: 800000, HCM: 1300000 }, phiUTSan: n(cfg.phiUTSan, 0.8),
});

export function calcQuote(h: QuoteHeader, rawLines: QuoteLine[], opts: { tyLeCoc?: number } = {}): QuoteResult {
  const errors: string[] = [];
  const warnings: string[] = [];
  const lines = rawLines
    .map((l, idx) => ({ ...l, idx }))
    .filter(l => (l.name || '').trim() !== '' && n(l.qty) > 0);
  const rate = n(h.tyGia);
  const u = n(h.phiUTPct) / 100;
  const utOnTH = h.coSoUyThac === 'tienHang';
  const tienHangCNY = lines.reduce((s, l) => s + n(l.qty) * n(l.unit_price_cny), 0);
  const thArr = lines.map(l => r0(n(l.qty) * n(l.unit_price_cny) * rate));
  const TH = thArr.reduce((a, b) => a + b, 0);
  const ship = r0(n(h.shipNoiDiaCNY) * rate);
  const cuocKg = r0(n(h.soKg) * n(h.donGiaKg));
  const cuocKhoi = r0(n(h.soKhoi) * n(h.donGiaKhoi));
  const cuoc = Math.max(cuocKg, cuocKhoi);
  const phuPhi = n(h.phiKeKhai) + n(h.phiHopQuy) + n(h.phiKTCL) + n(h.phiKhac);
  const w = thArr.map(t => (TH > 0 ? t / TH : lines.length ? 1 / lines.length : 0));

  // phân bổ cước
  const fixed = lines.map(l => (l.freight_pct === null || l.freight_pct === undefined || (l.freight_pct as any) === '' ? null : n(l.freight_pct)));
  let fixedSum = fixed.reduce<number>((s, f) => s + (f ?? 0), 0);
  const freeIdx = fixed.map((f, i) => (f === null ? i : -1)).filter(i => i >= 0);
  let scale = 1;
  if (fixedSum > 100 || (freeIdx.length === 0 && fixedSum > 0)) { scale = 100 / fixedSum; if (fixedSum > 100) warnings.push('Tổng "% cước" tự nhập vượt 100%, đã quy về 100%'); }
  fixedSum = Math.min(100, fixedSum * scale);
  const freeTH = freeIdx.reduce((s, i) => s + thArr[i], 0);
  const fpct = lines.map((_, i) => {
    if (fixed[i] !== null) return (fixed[i] as number) * scale;
    const share = freeTH > 0 ? thArr[i] / freeTH : 1 / freeIdx.length;
    return (100 - fixedSum) * share;
  });

  const res: LineResult[] = lines.map((l, i) => {
    const qty = n(l.qty);
    const d = n(l.duty_pct) / 100;
    const vatPct = l.vat_pct === null || l.vat_pct === undefined || (l.vat_pct as any) === '' ? n(h.vatPct) : n(l.vat_pct);
    const kDong = n(h.heSoToKhai, 0.9425) / (1 + d);
    const kThue = h.coSoThueNK === 'toKhai' ? kDong : 1;
    const tienHang = thArr[i];
    const shipI = ship * w[i];
    const cuocI = cuoc * fpct[i] / 100;
    const phiDV = n(h.phiDVCoDinh) > 0 ? n(h.phiDVCoDinh) * w[i] : tienHang * n(h.phiDVPct) / 100;
    const phuPhiI = phuPhi * w[i];
    const chiPhi = tienHang + shipI + cuocI + phiDV + phuPhiI;
    const denom = 1 - (utOnTH ? 0 : u) - d * kThue;
    let giaDuRaw = 0;
    if (denom <= 0) errors.push(`Dòng ${l.idx + 1}: tỷ lệ ủy thác + thuế NK quá lớn, không tính được giá xuất`);
    else giaDuRaw = (chiPhi + (utOnTH ? tienHang * u : 0)) / denom / qty;
    const giaDu = roundTo(giaDuRaw, n(h.lamTron, 1), h.lamTronKieu);
    let giaXuat = giaDu;
    if (h.cheDoXuat !== 'du') {
      giaXuat = n(l.manual_price) > 0 ? n(l.manual_price) : roundTo(giaDuRaw * n(h.pctXuat, 100) / 100, n(h.lamTron, 1), h.lamTronKieu);
    }
    const tongTruocVAT = r0(giaXuat * qty);
    const giaKhaiDV = r0(giaXuat * kDong);
    const triGiaKhai = giaKhaiDV * qty;
    const thueNK = r0(d * (h.coSoThueNK === 'toKhai' ? triGiaKhai : tongTruocVAT));
    const vat = r0(tongTruocVAT * vatPct / 100);
    return { idx: l.idx, tienHang, ship: shipI, cuoc: cuocI, phiDV, phuPhi: phuPhiI, chiPhi, freightPct: fpct[i], giaDu, giaXuat,
      tongTruocVAT, giaKhaiDV, triGiaKhai, thueNK, vat, vatPct, dutyPct: d * 100 };
  });

  const sum = (k: keyof LineResult) => res.reduce((s, x) => s + (x[k] as number), 0);
  const tongTruocVAT = sum('tongTruocVAT');
  const giaDuTotal = res.reduce((s, x) => s + r0(x.giaDu * n(lines.find(l => l.idx === x.idx)!.qty)), 0);
  const phiDV = r0(sum('phiDV'));
  const phiUT = r0(u * (utOnTH ? TH : tongTruocVAT));
  const thueNK = sum('thueNK');
  const vat = sum('vat');
  let tndn = 0;
  if (h.cheDoXuat === 'cao') {
    const thueNKatA = res.reduce((s, x) => {
      const qty = n(lines.find(l => l.idx === x.idx)!.qty);
      const kD = n(h.heSoToKhai, 0.9425) / (1 + x.dutyPct / 100);
      const base = h.coSoThueNK === 'toKhai' ? r0(x.giaDu * kD) * qty : r0(x.giaDu * qty);
      return s + r0(x.dutyPct / 100 * base);
    }, 0);
    tndn = r0(Math.max(0, tongTruocVAT - giaDuTotal) * n(h.tndnPct) / 100 + Math.max(0, thueNK - thueNKatA));
    if (n(h.pctXuat) <= 100 && !res.some((_, i) => n(lines[i].manual_price) > 0)) warnings.push('Xuất cao nhưng % so với giá đủ ≤ 100');
  }
  if (h.cheDoXuat === 'thap' && n(h.pctXuat) >= 100) warnings.push('Xuất thấp nhưng % so với giá đủ ≥ 100');
  const soThu = TH + ship + cuoc + phiDV + phiUT + phuPhi + thueNK + vat + tndn;
  const tongSauVAT = tongTruocVAT + vat;
  const chenhLamTron = h.cheDoXuat === 'du' ? tongTruocVAT - (TH + ship + cuoc + phiDV + phiUT + phuPhi + thueNK) : 0;
  const tyGiaVon = n(h.tyGiaVon, 3955);
  const giaVonKhoi = n((h.giaVonKhoi || {})[h.khoNhan || 'HN'], 800000);
  const ln = {
    tyGia: r0(tienHangCNY * (rate - tyGiaVon)),
    cuoc: n(h.soKhoi) > 0 ? r0(cuoc - giaVonKhoi * n(h.soKhoi)) : 0,
    uyThac: r0(phiUT - TH * n(h.phiUTSan, 0.8) / 100),
    phiDV,
    lamTron: chenhLamTron,
  };
  const tyLeCoc = opts.tyLeCoc ?? 80;
  const coc = Math.ceil(((TH + phiDV) * tyLeCoc / 100) / 1000 - 1e-9) * 1000;
  return {
    lines: res,
    errors,
    totals: {
      tienHangCNY, tienHang: TH, ship, cuoc, cuocTheoKg: cuocKg, cuocTheoKhoi: cuocKhoi, phiDV, phiUT, phuPhi, thueNK,
      giaDu: giaDuTotal, tongTruocVAT, vat, tongSauVAT, tndn, soThu, chenh: tongSauVAT - soThu, chenhLamTron,
      toKhai: sum('triGiaKhai'), lnUocTinh: ln.tyGia + ln.cuoc + ln.uyThac + ln.phiDV + ln.lamTron, lnChiTiet: ln, coc, warnings,
    },
  };
}

// Kiểm tra khung giá phía trình duyệt (để cảnh báo sớm; server kiểm lại)
export function priceFrame(h: QuoteHeader, t: QuoteTotals, cfg: { tyGiaSan?: number; phiDVSan?: number; tyLeXuatMin?: number } = {}) {
  const cam: string[] = []; const duyet: string[] = [];
  if (n(h.tyGia) < n(h.tyGiaVon, 3955)) cam.push(`Tỷ giá ${h.tyGia} thấp hơn tỷ giá vốn ${h.tyGiaVon}`);
  if (n(h.phiUTPct) < n(h.phiUTSan, 0.8)) cam.push(`Phí ủy thác ${h.phiUTPct}% thấp hơn sàn ${h.phiUTSan}%`);
  if (n(h.tyGia) < n(cfg.tyGiaSan, 4015)) duyet.push(`Tỷ giá < ${cfg.tyGiaSan ?? 4015}`);
  const dvMin = n(cfg.phiDVSan, 1.2);
  if (n(h.phiDVCoDinh) > 0 ? n(h.phiDVCoDinh) < Math.round(t.tienHang * dvMin / 100) : n(h.phiDVPct) < dvMin) duyet.push(`Phí dịch vụ < ${dvMin}%`);
  const gv = n((h.giaVonKhoi || {})[h.khoNhan || 'HN'], 800000);
  if (n(h.soKhoi) > 0 && t.cuoc / n(h.soKhoi) < gv) duyet.push(`Cước < giá vốn khối ${gv.toLocaleString('vi-VN')}đ`);
  if (h.cheDoXuat === 'thap' && n(h.pctXuat) < n(cfg.tyLeXuatMin, 70)) duyet.push(`Xuất thấp < ${cfg.tyLeXuatMin ?? 70}%`);
  return { cam, duyet };
}
