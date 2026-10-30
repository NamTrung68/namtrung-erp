// Đối soát xe hàng APT — hệ thống NamtrungLog là gốc. Thuần TS (chạy được cả trình duyệt và node để kiểm thử).
// Port từ skill doi-soat-xe-apt (doi_soat_xe.py + doi_soat_goc.py + doi_chieu_hd.py), quy tắc biên chốt 30/10/2026.

export interface AccCfg {
  bien_muc_tieu: number; bien_nt_min: number; bien_nt_max: number; dung_sai_bien: number; tien_bo_qua: number; nguong_ghep: number;
  sale_lanchi: string[]; md_xuat_thang: string[]; hs_hop_quy_chuong: string[]; han_sale_gio: number; han_hd_ngay?: number;
}
export const DEFAULT_ACC_CFG: AccCfg = {
  bien_muc_tieu: 0.03, bien_nt_min: 0.025, bien_nt_max: 0.04, dung_sai_bien: 0.001, tien_bo_qua: 50000, nguong_ghep: 0.65,
  sale_lanchi: ['huyennk29', 'yenttt', 'Yentth'], md_xuat_thang: [], han_hd_ngay: 15,
  hs_hop_quy_chuong: ['50', '51', '52', '53', '54', '55', '56', '57', '58', '59', '60', '61', '62', '63'], han_sale_gio: 24,
};

// ---------------- tiện ích ----------------
export const stripAcc = (s: any) => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/g, 'd').replace(/Đ/g, 'D');
export const norm = (s: any) => stripAcc(s).toLowerCase().replace(/[^a-z0-9]/g, '');
export const clean = (s: any) => (s === null || s === undefined || (typeof s === 'number' && isNaN(s)) ? '' : String(s).replace(/\s+/g, ' ').trim());
/** Số kiểu Việt Nam (1.234.567,5) hoặc số thực */
export function vnNum(v: any): number | null {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'number') return isNaN(v) ? null : v;
  let s = String(v).trim().replace(/\s|đ/g, '');
  if (!s || s === 'nan') return null;
  if (s.includes(',')) s = s.replace(/\./g, '').replace(',', '.');
  else if (/^\d{1,3}(\.\d{3})+$/.test(s)) s = s.replace(/\./g, '');
  const n = Number(s); return isNaN(n) ? null : n;
}
const pct = (v: any) => { const n = vnNum(typeof v === 'string' ? v.replace('%', '') : v) ?? 0; return n > 1 ? n / 100 : n; };
/** Tập mã đơn MDxxxx trong 1 ô (một ô có thể chứa nhiều MD) */
export const mdSet = (s: any) => new Set((String(s ?? '').toUpperCase().match(/MD\d+/g) || []));
/** Chuẩn hóa mã đơn: "MD2411", "2411", 2411 → "MD2411" (hai dạng hiển thị là một đơn) */
export function normMd(v: any): string { const s = clean(v).toUpperCase(); const m = s.match(/(\d+)/); return m ? 'MD' + Number(m[1]) : ''; }

/** Độ giống chuỗi kiểu Ratcliff/Obershelp (giống difflib.ratio, không dùng autojunk) */
export function sim(a: any, b: any): number {
  const x = norm(a), y = norm(b); if (!x || !y) return 0;
  const m = (s: string, t: string): number => {
    if (!s || !t) return 0;
    let best = 0, bi = 0, bj = 0; const prev = new Uint16Array(t.length + 1), cur = new Uint16Array(t.length + 1);
    for (let i = 1; i <= s.length; i++) {
      for (let j = 1; j <= t.length; j++) { cur[j] = s[i - 1] === t[j - 1] ? prev[j - 1] + 1 : 0; if (cur[j] > best) { best = cur[j]; bi = i; bj = j; } }
      prev.set(cur); cur.fill(0);
    }
    if (!best) return 0;
    return best + m(s.slice(0, bi - best), t.slice(0, bj - best)) + m(s.slice(bi), t.slice(bj));
  };
  return (2 * m(x, y)) / (x.length + y.length);
}

/** Ghép 1-1 tối ưu (thuật toán Hungary, cực đại tổng điểm); trả map i -> [j, điểm] với điểm ≥ ngưỡng */
export function assign(score: number[][], thr: number): Map<number, [number, number]> {
  const n = score.length, m = n ? score[0].length : 0, out = new Map<number, [number, number]>();
  if (!n || !m) return out;
  const N = Math.max(n, m), INF = 1e9; const cost = (i: number, j: number) => (i < n && j < m ? -score[i][j] : 0);
  const u = new Float64Array(N + 1), v = new Float64Array(N + 1), p = new Int32Array(N + 1), way = new Int32Array(N + 1);
  for (let i = 1; i <= N; i++) {
    p[0] = i; let j0 = 0; const minv = new Float64Array(N + 1).fill(INF), used = new Uint8Array(N + 1);
    do {
      used[j0] = 1; const i0 = p[j0]; let delta = INF, j1 = 0;
      for (let j = 1; j <= N; j++) if (!used[j]) {
        const cur = cost(i0 - 1, j - 1) - u[i0] - v[j];
        if (cur < minv[j]) { minv[j] = cur; way[j] = j0; }
        if (minv[j] < delta) { delta = minv[j]; j1 = j; }
      }
      for (let j = 0; j <= N; j++) if (used[j]) { u[p[j]] += delta; v[j] -= delta; } else minv[j] -= delta;
      j0 = j1;
    } while (p[j0] !== 0);
    do { const j1 = way[j0]; p[j0] = p[j1]; j0 = j1; } while (j0);
  }
  for (let j = 1; j <= N; j++) { const i = p[j] - 1, jj = j - 1; if (i < n && jj < m && score[i][jj] >= thr) out.set(i, [jj, score[i][jj]]); }
  return out;
}

// ---------------- đọc file ----------------
export interface AptRow { apt_stt: number; apt_mahang: string; don: string; sale_apt: string; md_apt: string; dau_khoi: boolean; hh: string; ten: string;
  sl: number | null; dvt: string; nk: number; gia_nhap: number | null; vat: number; note: string; kt: string; note2: string; gia_note: number | null; gia_khach_sale_ghi: number | null }
export interface SysRow { sys_row: number; ten: string; sale: string; md: string; ma_dong: string; sl: number | null; dvt: string; gia_khach: number | null; nk: number; hs: string; ma_kh: string; ma_dong_file: string }
export interface TkRow { tk_row: number; dh: string; sale: string; md_header: string; ten: string; hs: string; sl: number; dvt: string; nh: number | null; nk: number; tnk: number; vat: number | null }

const notePrice = (v: any) => { const t = stripAcc(clean(v)).toLowerCase(); if (!t) return null; const m = t.match(/^\s*(?:xuat\s*gia\s*:?)?\s*(\d[\d.,]*)/); return m ? vnNum(m[1]) : null; };

/** File check APT (bản nháp HĐ dạng bảng, tiêu đề bắt đầu "STT") */
export function parseApt(rows: any[][]): { rows: AptRow[]; total: number | null; vat: number | null } {
  const hi = rows.slice(0, 15).findIndex(r => clean(r?.[0]).toUpperCase() === 'STT');
  if (hi < 0) throw new Error('File check APT: không thấy dòng tiêu đề bắt đầu bằng "STT"');
  const out: AptRow[] = []; let cur = { mahang: '', don: '', sale: '', md: '' };
  for (const r of rows.slice(hi + 1)) {
    if (!r || !/^\d+$/.test(clean(r[0]).replace(/\.0+$/, ''))) continue;
    const head = !!clean(r[6]);
    if (head) cur = { mahang: clean(r[1]), don: clean(r[6]), sale: clean(r[7]), md: clean(r[8]) };
    const gks = vnNum(r[25]);
    out.push({ apt_stt: Number(clean(r[0])), apt_mahang: cur.mahang, don: cur.don, sale_apt: clean(r[7]) || cur.sale, md_apt: cur.md, dau_khoi: head,
      hh: clean(r[10]), ten: clean(r[11]), sl: vnNum(r[12]), dvt: clean(r[13]), nk: pct(r[15]), gia_nhap: vnNum(r[17]), vat: pct(r[18]),
      note: clean(r[22]), kt: clean(r[23]), note2: (clean(r[24]) + ' ' + clean(r[25])).trim(), gia_note: notePrice(r[22]), gia_khach_sale_ghi: gks && gks > 100 ? gks : null });
  }
  if (!out.length) throw new Error('File check APT: không có dòng hàng nào');
  return { rows: out, total: hi > 0 ? vnNum(rows[hi - 1]?.[19]) : null, vat: hi > 0 ? vnNum(rows[hi - 1]?.[20]) : null };
}

/** File khai báo xuất từ hệ thống NamtrungLog (cột SALES NTG, ĐƠN HÀNG NTG, GIÁ TRÊN TỜ KHAI = giá khách) */
export function parseKhaiBao(rows: any[][]): SysRow[] {
  const hi = rows.slice(0, 15).findIndex(r => (r || []).some(x => clean(x).toUpperCase().includes('SALES')));
  if (hi < 0) throw new Error('File khai báo: không thấy dòng tiêu đề có cột "SALES NTG"');
  const H = (rows[hi] || []).map(x => clean(x).toUpperCase());
  const ci = (k: string, req = true) => { const i = H.findIndex(c => c.includes(k)); if (i < 0 && req) throw new Error(`File khai báo: thiếu cột "${k}"`); return i; };
  const m = { ten: ci('TÊN KHAI BÁO'), sale: ci('SALES'), don: ci('ĐƠN HÀNG'), sl: ci('SỐ LƯỢNG'), dvt: ci('DVT'), gia: ci('GIÁ TRÊN TỜ KHAI'),
    nk: ci('THUẾ NK', false), hs: ci('HS CODE', false), mahang: ci('MÃ HÀNG', false), makh: H.findIndex(c => c === 'MÃ KH' || c.startsWith('MÃ KH') || c.includes('MÃ KHÁCH')) };
  const out: SysRow[] = []; let sale = '', md = ''; const cnt: Record<string, number> = {};
  rows.slice(hi + 1).forEach((r, k) => {
    const ten = clean(r?.[m.ten]); if (!ten) return;
    if (clean(r[m.don])) md = normMd(r[m.don]);
    if (clean(r[m.sale])) sale = clean(r[m.sale]);
    cnt[md] = (cnt[md] || 0) + 1;
    const mdf = m.mahang >= 0 ? clean(r[m.mahang]) : '';
    out.push({ sys_row: hi + 2 + k, ten, sale, md, ma_dong: /^MD\d+-\d+$/i.test(mdf) ? mdf.toUpperCase() : `${md}-${cnt[md]}`, ma_dong_file: mdf,
      sl: vnNum(r[m.sl]), dvt: clean(r[m.dvt]), gia_khach: vnNum(r[m.gia]), nk: m.nk >= 0 ? pct(r[m.nk]) : 0, hs: m.hs >= 0 ? clean(r[m.hs]).replace(/\.0+$/, '') : '',
      ma_kh: m.makh >= 0 ? clean(r[m.makh]) : '' });
  });
  if (!out.length) throw new Error('File khai báo: không có dòng hàng nào');
  return out;
}

/** Tờ khai nháp TKN (listxe APT gửi): MÃ DH APT, MÃ SALE, MÃ DH NTG, Tên hàng, Mã HS, Lượng, ĐƠN GIÁ THEO TỶ GIÁ NH, TS NK, Tiền thuế NK */
export function parseTkn(rows: any[][]): TkRow[] {
  const hi = rows.slice(0, 15).findIndex(r => (r || []).some(x => stripAcc(clean(x)).toLowerCase().startsWith('ten hang')));
  if (hi < 0) throw new Error('Tờ khai nháp: không thấy dòng tiêu đề "Tên hàng"');
  const H = (rows[hi] || []).map(x => stripAcc(clean(x)).toLowerCase());
  const col = (...ns: string[]) => { for (const n of ns) { const i = H.findIndex(h => h.startsWith(n)); if (i >= 0) return i; } return -1; };
  const c = { dh: col('ma dh apt'), sale: col('ma sale'), md: col('ma dh ntg'), ten: col('ten hang'), hs: col('ma hs'), sl: col('luong'), dvt: col('don vi tinh'),
    nh: col('don gia theo ty gia nh'), nk: col('ts nk'), tnk: col('tien thue nk'), vat: col('thue suat vat') };
  const g = (r: any[], k: keyof typeof c) => (c[k] >= 0 ? r[c[k]] : null);
  const out: TkRow[] = []; let cur = { dh: '', sale: '', md: '' };
  rows.slice(hi + 1).forEach((r, k) => {
    if (!r || !clean(g(r, 'ten'))) return;
    if (clean(g(r, 'dh'))) cur = { dh: clean(g(r, 'dh')), sale: clean(g(r, 'sale')), md: [...mdSet(g(r, 'md'))].sort().join(' ') || clean(g(r, 'md')) };
    const hs = g(r, 'hs');
    out.push({ tk_row: hi + 2 + k, dh: cur.dh, sale: cur.sale, md_header: cur.md, ten: clean(g(r, 'ten')), hs: typeof hs === 'number' ? String(Math.trunc(hs)) : clean(hs).replace(/\.0+$/, ''),
      sl: vnNum(g(r, 'sl')) || 0, dvt: clean(g(r, 'dvt')), nh: vnNum(g(r, 'nh')), nk: pct(g(r, 'nk')), tnk: vnNum(g(r, 'tnk')) || 0, vat: g(r, 'vat') === null ? null : pct(g(r, 'vat')) });
  });
  return out;
}

// ---------------- đối soát ----------------
export type Luong = 'A' | 'B' | 'C' | 'D' | 'E';
export const LUONG: Record<Luong, string> = { A: 'Qua Nam Trung', B: 'Chờ hợp quy', C: 'APT xuất thẳng', D: 'Khách Lanchi', E: 'Có trên hệ thống, không lên xe' };
export type LineStatus = 'ok' | 'blocked' | 'info';
export interface AccLine {
  line_key: string; ma_dong: string | null; md: string | null; sale_name: string | null; sale_acc: string | null; ma_kh: string | null;
  sys_row: number | null; ten_ht: string | null; sl_ht: number | null; dvt_ht: string | null; gia_khach: number | null; nk_ht: number | null;
  apt_stt: number | null; hh: string | null; dh: string | null; sale_apt: string | null; ten_apt: string | null; sl_apt: number | null; dvt_apt: string | null;
  gia_nhap: number | null; gia_note: number | null; note_apt: string | null; nk_apt: number | null; vat: number | null;
  tk_row: number | null; ten_tk: string | null; hs: string | null; sl_tk: number | null; dvt_tk: string | null; gia_tk_nh: number | null; nk_tk: number | null; tnk_dv: number | null; md_header: string | null;
  luong: Luong; gia_ap_dung: number | null; gia_de_xuat: number | null; bien_nt: number | null; gia_von: number | null; bien_apt: number | null; tt_apt: number; tt_khach: number | null;
  status: LineStatus; level: 1 | 2 | 3; issues: string[]; notes: string[]; phan_hoi: string; match_score: number | null;
}
export interface ReconcileResult { lines: AccLine[]; stats: Record<string, any>; warnings: string[] }

/** saleAcc: tên sale (họ tên/tài khoản) → tài khoản chuẩn; trả null nếu chưa biết */
export function reconcile(apt: AptRow[], sys: SysRow[], tk: TkRow[], cfg: AccCfg = DEFAULT_ACC_CFG, saleAcc: (s: string) => string | null = s => s || null): ReconcileResult {
  const warnings: string[] = [];
  const acc = (s: string | null | undefined) => (s ? saleAcc(s) ?? null : null);
  // 1) file APT ↔ hệ thống (tên 60% + SL 30% + MD 10%)
  const S = apt.map(r => { const mds = mdSet(r.md_apt); return sys.map(s => 0.6 * sim(r.ten, s.ten) + 0.3 * (r.sl != null && s.sl != null && Math.abs(r.sl - s.sl) < 0.5 ? 1 : 0) + 0.1 * (mds.has(s.md) ? 1 : 0)); });
  const mSys = assign(S, cfg.nguong_ghep);
  // 2) file APT ↔ tờ khai: thường 1:1 cùng thứ tự; lệch thì ghép theo tên + SL
  const tmap = new Map<number, TkRow>(); const sorted = [...apt].sort((a, b) => a.apt_stt - b.apt_stt);
  if (tk.length && sorted.length === tk.length && sorted.every((a, i) => sim(a.ten, tk[i].ten) >= 0.9)) sorted.forEach((a, i) => tmap.set(a.apt_stt, tk[i]));
  else if (tk.length) {
    const T = sorted.map(a => tk.map(t => sim(a.ten, t.ten) + (Math.abs((a.sl || 0) - t.sl) < 0.01 ? 0.2 : 0)));
    assign(T, 0.8).forEach(([j], i) => tmap.set(sorted[i].apt_stt, tk[j]));
    warnings.push(`Tờ khai ${tk.length} dòng, file APT ${apt.length} dòng — ghép theo tên + số lượng (${tmap.size} dòng).`);
  }
  const lanchi = new Set(cfg.sale_lanchi.map(norm)); const thang = new Set(cfg.md_xuat_thang.map(normMd));
  const hq = cfg.hs_hop_quy_chuong; const { bien_nt_min: lo, bien_nt_max: hi, dung_sai_bien: tol, bien_muc_tieu: tgt } = cfg;
  const lines: AccLine[] = []; const usedSys = new Set<number>();

  const build = (s: SysRow | null, a: AptRow | null, t: TkRow | null, score: number | null): AccLine => {
    const issues: string[] = [], notes: string[] = []; let level: 1 | 2 | 3 = 3;
    const add = (l: 1 | 2, x: string) => { issues.push(x); if (l < level) level = l; };
    // luồng
    const noteAll = stripAcc(((a?.note || '') + ' ' + (a?.note2 || '')).toUpperCase());
    const hs2 = (t?.hs || s?.hs || '').slice(0, 2);
    let luong: Luong = 'A';
    if (!a) luong = 'E';
    else if (noteAll.includes('XUAT THANG') || (s && thang.has(s.md)) || [...mdSet(a.md_apt)].some(x => thang.has(x))) luong = 'C';
    else if (lanchi.has(norm(a.sale_apt)) || (a.md_apt && !mdSet(a.md_apt).size)) luong = 'D';
    else if (hs2 && hq.some(h => hs2 === h)) luong = 'B';
    const gk = s?.gia_khach || null; const gn = a?.gia_nhap ?? null; const gnote = a?.gia_note || null;
    const ga = gnote || gn; let gde: number | null = null; let bien: number | null = gk && ga ? gk / ga - 1 : null;
    const sl = a?.sl ?? s?.sl ?? 0; const ttApt = (ga || 0) * (sl || 0);
    if (luong === 'E') add(2, 'Có trên hệ thống nhưng không có trên tờ khai/file APT xe này → chưa bốc, chuyển xe sau, hoặc dòng thừa trên hệ thống.');
    else if (luong === 'C') { if (s && gk) notes.push('APT xuất thẳng cho khách nhưng dòng vẫn có giá khách trên hệ thống → gắn cờ xuất thẳng trên hệ thống để không tính doanh thu/lãi.'); }
    else if (luong === 'D') notes.push('Khách Lanchi — xuất HĐ theo quyết định riêng.');
    else if (luong === 'B') {
      if (!s) add(1, 'Hàng dệt may (chờ hợp quy) nhưng KHÔNG có đơn trên hệ thống → sale nhập đơn trước khi APT xuất HĐ.');
      else { notes.push('Hàng dệt may chờ hợp quy (~12–15 ngày từ ngày về kho) — theo dõi xe sau.'); if (!gk) add(1, 'Giá khách trên hệ thống = 0 → sale nhập giá khách trước khi APT xuất HĐ.'); }
    }
    else {
      if (!s) add(1, 'Có trên tờ khai/file APT nhưng KHÔNG có đơn trên hệ thống → không có giá khách; nếu APT xuất HĐ, Nam Trung nhận hàng vào sổ mà không xuất được đầu ra. Sale nhập đơn lên hệ thống.');
      else if (!gk) add(1, 'Giá khách trên hệ thống = 0 → không xuất được HĐ đầu ra. Sale nhập giá khách đã chốt.');
      else if (ga && bien !== null) {
        if (bien > hi + tol) {
          if (gnote) add(2, `Biên NT ${(bien * 100).toFixed(2)}% > ${hi * 100}% ngay cả theo giá sale ghi NOTE.`);
          else { gde = Math.round(gk / (1 + tgt)); notes.push(`Biên NT ${(bien * 100).toFixed(2)}% > ${hi * 100}% → tự đề xuất APT xuất giá ${gde.toLocaleString('vi-VN')}`); }
        } else if (bien < lo - tol && (lo - bien) * ttApt > cfg.tien_bo_qua) add(1, `Biên NT ${(bien * 100).toFixed(2)}% < ${lo * 100}% → đề nghị APT xuất giá ${Math.round(gk / (1 + tgt)).toLocaleString('vi-VN')} (biên NT ${tgt * 100}%), hoặc sale giải trình / xin duyệt.`);
        else if (bien < lo - tol) notes.push(`Biên NT ${(bien * 100).toFixed(2)}% < ${lo * 100}% nhưng tiền chênh dưới ${cfg.tien_bo_qua.toLocaleString('vi-VN')}đ — bỏ qua.`);
      }
      if (s && t && Math.abs((s.nk || 0) - t.nk) > 0.001) add(1, `Thuế NK hệ thống ${Math.round((s.nk || 0) * 100)}% ≠ tờ khai ${Math.round(t.nk * 100)}% → sửa hệ thống theo tờ khai.`);
      if (s && a && a.gia_khach_sale_ghi && gk && Math.abs(a.gia_khach_sale_ghi - gk) > 1) add(2, `Sale ghi giá khách ${a.gia_khach_sale_ghi.toLocaleString('vi-VN')} trên file APT nhưng hệ thống là ${gk.toLocaleString('vi-VN')}.`);
      if (s) {
        const sAcc = acc(s.sale), aAcc = acc(a?.sale_apt || t?.sale || '');
        if (!sAcc) add(1, `Tên sale "${s.sale}" trên hệ thống chưa ghép với nhân sự ERP → vào Cấu hình kế toán ghép tên.`);
        else if (norm(sAcc) !== norm(aAcc || '')) notes.push(`Gộp đơn: file APT ghi sale "${a?.sale_apt || t?.sale || 'trống'}", hệ thống là ${sAcc} (${s.md}) → đã gán lại theo hệ thống.`);
        if (t && !mdSet(t.md_header).has(s.md)) notes.push(`${s.md} không có trong cột MÃ DH NTG của ${t.dh} (đầu khối ghi ${t.md_header || 'trống'}).`);
      }
      if (s && score !== null && score < 0.8) notes.push(`Độ khớp tên với hệ thống thấp (${Math.round(score * 100)}%) — kế toán liếc lại.`);
    }
    if (s && t && sim(s.ten, t.ten) < 0.9) notes.push('Tên tờ khai khác hệ thống → HĐ đầu ra theo tên HĐ APT.');
    if (s && a && s.dvt && a.dvt && norm(s.dvt) !== norm(a.dvt)) notes.push(`ĐVT hệ thống "${s.dvt}" → HĐ dùng "${a.dvt}".`);
    const vat = t?.vat ?? (a ? a.vat : null);
    if (vat !== null && vat !== undefined && vat > 0 && Math.abs(vat - 0.08) > 0.001) notes.push(`VAT ${Math.round(vat * 100)}% — thường tách HĐ riêng.`);
    const status: LineStatus = level < 3 ? 'blocked' : luong === 'A' || luong === 'E' ? 'ok' : 'info';
    // nếu chỉ có lỗi mức 2 (cần xác nhận) mà không chặn: vẫn để sale xác nhận
    let phan_hoi = '';
    if (a) {
      if (luong === 'C') phan_hoi = 'XUẤT THẲNG'; else if (luong === 'D') phan_hoi = 'CHỜ QUYẾT ĐỊNH (Lanchi)'; else if (status === 'blocked') phan_hoi = 'CHỜ SALE — chưa xuất';
      else if (luong === 'B') phan_hoi = 'CHỜ HỢP QUY';
      else if (gnote && Math.abs(gnote - (gn || 0)) > 0.5) phan_hoi = `XUẤT GIÁ ${gnote.toLocaleString('vi-VN')}`;
      else if (gde) phan_hoi = `XUẤT GIÁ ${gde.toLocaleString('vi-VN')}`;
      else phan_hoi = 'CHỐT';
    }
    const gad = gde || ga; const gvon = t && t.nh ? t.nh + (t.sl ? t.tnk / t.sl : 0) : null;
    return {
      line_key: a ? `A${a.apt_stt}` : `S${s!.ma_dong}`, ma_dong: s?.ma_dong || null, md: s?.md || null, sale_name: s?.sale || a?.sale_apt || t?.sale || null,
      sale_acc: acc(s?.sale || a?.sale_apt || t?.sale || ''), ma_kh: s?.ma_kh || null,
      sys_row: s?.sys_row ?? null, ten_ht: s?.ten ?? null, sl_ht: s?.sl ?? null, dvt_ht: s?.dvt ?? null, gia_khach: gk, nk_ht: s ? s.nk : null,
      apt_stt: a?.apt_stt ?? null, hh: a?.hh || null, dh: t?.dh || a?.don || null, sale_apt: a?.sale_apt || null, ten_apt: a?.ten ?? null, sl_apt: a?.sl ?? null, dvt_apt: a?.dvt || null,
      gia_nhap: gn, gia_note: gnote, note_apt: a?.note || null, nk_apt: a ? a.nk : null, vat: vat ?? null,
      tk_row: t?.tk_row ?? null, ten_tk: t?.ten ?? null, hs: t?.hs || s?.hs || null, sl_tk: t?.sl ?? null, dvt_tk: t?.dvt || null, gia_tk_nh: t?.nh ?? null, nk_tk: t ? t.nk : null,
      tnk_dv: t && t.sl ? t.tnk / t.sl : null, md_header: t?.md_header || a?.md_apt || null,
      luong, gia_ap_dung: gad, gia_de_xuat: gde, bien_nt: gk && gad ? gk / gad - 1 : bien, gia_von: gvon, bien_apt: gvon && gad ? gad / gvon - 1 : null, tt_apt: Math.round((gad || 0) * (sl || 0)), tt_khach: gk ? Math.round(gk * (sl || 0)) : null,
      status, level, issues, notes, phan_hoi, match_score: score === null ? null : Math.round(score * 100) / 100,
    };
  };
  apt.forEach((a, i) => { const m = mSys.get(i); const s = m ? sys[m[0]] : null; if (m) usedSys.add(m[0]); lines.push(build(s, a, tmap.get(a.apt_stt) || null, m ? m[1] : null)); });
  sys.forEach((s, j) => { if (!usedSys.has(j)) lines.push(build(s, null, null, null)); });
  const st = { apt: apt.length, sys: sys.length, tk: tk.length, matched_sys: mSys.size, matched_tk: tmap.size,
    ok: lines.filter(l => l.status === 'ok').length, blocked: lines.filter(l => l.status === 'blocked').length, info: lines.filter(l => l.status === 'info').length,
    tt_apt: lines.reduce((x, l) => x + (l.apt_stt ? l.tt_apt : 0), 0), apt_header_total: null as number | null };
  return { lines, stats: st, warnings };
}

// ---------------- HĐ điện tử XML (chuẩn TCT, MISA meInvoice) ----------------
export interface InvLine { stt: number; hh: string; ten: string; dvt: string; sl: number; dg: number; tt: number; vat: string }
export interface Invoice { so_hd: string; ky_hieu: string; ngay: string | null; mst_ban: string; ten_ban: string; mst_mua: string; ten_mua: string; tong_truoc_thue: number; tien_thue: number; tong: number; lines: InvLine[] }
const tag = (s: string, t: string) => { const m = s.match(new RegExp(`<${t}>([\\s\\S]*?)</${t}>`)); return m ? m[1].replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').trim() : ''; };
export function parseInvoiceXml(xml: string): Invoice {
  const body = xml.replace(/<(\/?)[a-zA-Z0-9]+:/g, '<$1');
  const so = tag(body, 'SHDon'); if (!so) throw new Error('Không phải XML hóa đơn điện tử (thiếu số HĐ)');
  const nban = tag(body, 'NBan'), nmua = tag(body, 'NMua'), ttoan = tag(body, 'TToan');
  const lines: InvLine[] = [];
  for (const m of body.matchAll(/<HHDVu>([\s\S]*?)<\/HHDVu>/g)) {
    const it = m[1]; const ten = tag(it, 'THHDVu'); if (!ten) continue;
    lines.push({ stt: Number(tag(it, 'STT')) || lines.length + 1, hh: tag(it, 'MHHDVu'), ten, dvt: tag(it, 'DVTinh'), sl: Number(tag(it, 'SLuong')) || 0,
      dg: Number(tag(it, 'DGia')) || 0, tt: Number(tag(it, 'ThTien')) || 0, vat: tag(it, 'TSuat') });
  }
  return { so_hd: so, ky_hieu: tag(body, 'KHHDon'), ngay: tag(body, 'NLap') || null, mst_ban: tag(nban, 'MST'), ten_ban: tag(nban, 'Ten'), mst_mua: tag(nmua, 'MST'), ten_mua: tag(nmua, 'Ten'),
    tong_truoc_thue: Number(tag(ttoan, 'TgTCThue')) || lines.reduce((x, l) => x + l.tt, 0), tien_thue: Number(tag(ttoan, 'TgTThue')) || 0, tong: Number(tag(ttoan, 'TgTTTBSo')) || 0, lines };
}
export type InvResult = 'khop' | 'lech' | 'khong_don' | 'gia_khach_0' | 'khong_thuoc_xe' | 'mot_phan';
export const INV_RESULT: Record<InvResult, [string, string]> = {
  khop: ['Khớp', 'green'], lech: ['Lệch giá/SL so với bản đã chốt', 'red'], khong_don: ['Đã xuất HĐ nhưng KHÔNG có đơn trên hệ thống', 'red'],
  gia_khach_0: ['Đã xuất HĐ nhưng giá khách = 0', 'red'], khong_thuoc_xe: ['Chưa thuộc xe nào (tự ghép khi nạp xe)', 'gray'], mot_phan: ['Đã xuất HĐ một phần', 'amber'],
};
/** Kết luận 1 dòng HĐ so với dòng đối soát (theo mã hàng APT) — chỉ xét giá; số lượng được cộng qua nhiều HĐ ở máy chủ (khớp / một phần / vượt) */
export function judgeInvoiceLine(l: InvLine, line: Pick<AccLine, 'md' | 'gia_khach' | 'gia_note' | 'gia_de_xuat' | 'gia_nhap' | 'sl_tk' | 'sl_apt'> | null): InvResult {
  if (!line) return 'khong_thuoc_xe';
  if (!line.md) return 'khong_don';
  if (!line.gia_khach) return 'gia_khach_0';
  const chot = line.gia_note || line.gia_de_xuat || line.gia_nhap; const sl = line.sl_tk ?? line.sl_apt;
  // Giá đề xuất là gợi ý cho APT: APT có thể xuất theo giá nháp hoặc giá đề xuất — chấp nhận cả hai
  const okGia = [line.gia_note, line.gia_de_xuat, line.gia_nhap].filter(Boolean).some(g => Math.abs(l.dg - (g as number)) <= 0.5) || (!chot);
  void sl; if (!okGia) return 'lech';
  return 'khop';
}

/** Nội dung gửi APT đề nghị xuất lại giá (biên NT ngoài khung → đưa về mục tiêu). Trả '' nếu không có dòng nào */
export function aptPriceMsg(lines: any[], cfg: Pick<AccCfg, 'bien_muc_tieu' | 'bien_nt_min' | 'bien_nt_max'>, title = ''): string {
  const out = lines.filter(l => l.apt_stt && l.gia_khach && (l.gia_nhap || l.gia_ap_dung) && !['C', 'D'].includes(l.luong)).map(l => {
    const target = Math.round(Number(l.gia_khach) / (1 + cfg.bien_muc_tieu)); const cur = Number(l.gia_note || l.gia_nhap);
    const b = Number(l.gia_khach) / cur - 1;
    return b > cfg.bien_nt_max + 0.001 || b < cfg.bien_nt_min - 0.001 ? { l, target, cur } : null;
  }).filter(Boolean) as { l: any; target: number; cur: number }[];
  if (!out.length) return '';
  const f = (n: number) => n.toLocaleString('vi-VN');
  return [`Nam Trung đề nghị APT xuất giá các dòng sau${title ? ' — ' + title : ''}:`,
    ...out.sort((a, b) => a.l.apt_stt - b.l.apt_stt).map(({ l, target, cur }) => `• STT ${l.apt_stt} | ${l.hh || ''} | ${String(l.ten_apt || l.ten_ht || '').slice(0, 60)} | SL ${f(Number(l.sl_apt || 0))} | giá nháp ${f(cur)} → xuất giá ${f(target)}`),
    `(${out.length} dòng)`].join('\n');
}
