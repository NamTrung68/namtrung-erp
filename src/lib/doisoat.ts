// Đối soát xe hàng APT — hệ thống NamtrungLog là gốc. Thuần TS (chạy được cả trình duyệt và node để kiểm thử).
// Port từ skill doi-soat-xe-apt (doi_soat_xe.py + doi_soat_goc.py + doi_chieu_hd.py), quy tắc biên chốt 30/10/2026.

export interface AccCfg {
  bien_muc_tieu: number; bien_nt_min: number; bien_nt_max: number; dung_sai_bien: number; tien_bo_qua: number; nguong_ghep: number;
  sale_lanchi: string[]; md_xuat_thang: string[]; kh_xuat_thang?: string[]; hs_hop_quy_chuong: string[]; han_sale_gio: number; han_hd_ngay?: number;
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
export interface AptRow { apt_stt: number; apt_mahang: string; don: string; sale_apt: string; md_apt: string; dau_khoi: boolean; ma_kb: string; hh: string; ten: string;
  sl: number | null; dvt: string; nk: number; gia_nhap: number | null; vat: number; note: string; kt: string; note2: string; gia_note: number | null; gia_khach_sale_ghi: number | null }
export interface SysRow { sys_row: number; ten: string; sale: string; md: string; ma_dong: string; sl: number | null; dvt: string; gia_khach: number | null; nk: number; hs: string; ma_kh: string; ma_dong_file: string }
export interface TkRow { tk_row: number; dh: string; sale: string; md_header: string; ten: string; hs: string; sl: number; dvt: string; nh: number | null; nk: number; tnk: number; vat: number | null }

const notePrice = (v: any) => { const t = stripAcc(clean(v)).toLowerCase(); if (!t) return null; const m = t.match(/^\s*(?:xuat\s*gia\s*:?)?\s*(\d[\d.,]*)/); return m ? vnNum(m[1]) : null; };

/** Tiêu đề chuẩn hóa để dò cột: bỏ dấu, viết hoa, gộp khoảng trắng */
const HD = (s: any) => stripAcc(clean(s)).toUpperCase().replace(/\s+/g, ' ').trim();
/** Mã khai báo chuẩn: "md2415 - 2" → "MD2415-2"; không đúng dạng → '' */
export function normKb(v: any): string { const s = clean(v).toUpperCase().replace(/\s+/g, ''); const m = s.match(/^MD0*(\d+)-0*(\d+)$/); return m ? `MD${Number(m[1])}-${Number(m[2])}` : ''; }
/** Mã đơn của 1 mã khai báo: MD2415-2 → MD2415 */
export const kbMd = (kb: string) => (kb ? kb.replace(/-\d+$/, '') : '');

/** File check APT (bản nháp HĐ). Bản 23: đọc theo TIÊU ĐỀ cột (có cột MÃ KHAI BÁO); file cũ không có cột này thì đọc theo vị trí như trước */
export function parseApt(rows: any[][]): { rows: AptRow[]; total: number | null; vat: number | null } {
  const hi = rows.slice(0, 15).findIndex(r => clean(r?.[0]).toUpperCase() === 'STT');
  if (hi < 0) throw new Error('File check APT: không thấy dòng tiêu đề bắt đầu bằng "STT"');
  const H = (rows[hi] || []).map(HD);
  const ikb = H.findIndex(h => h === 'MA KHAI BAO');
  if (ikb >= 0) return parseAptByHeader(rows, hi, H, ikb);
  return parseAptLegacy(rows, hi);
}
function parseAptByHeader(rows: any[][], hi: number, H: string[], ikb: number): { rows: AptRow[]; total: number | null; vat: number | null } {
  const f = (p: (h: string) => boolean, from = 0, to = H.length) => { for (let i = from; i < to; i++) if (H[i] && p(H[i])) return i; return -1; };
  const c = {
    mahang: f(h => h === 'MA HANG', 0, ikb), don: f(h => h === 'DON HANG' || h.startsWith('DON HANG')), sale: f(h => h === 'SALE'),
    hh: f(h => h === 'MA HANG', ikb + 1), ten: f(h => h.startsWith('TEN HANG')), sl: f(h => h === 'LUONG' || h.startsWith('SO LUONG')), dvt: f(h => h === 'DVT' || h.startsWith('DON VI TINH')),
    nk: f(h => h.startsWith('TS NK')), gia: f(h => h.startsWith('DON GIA BAN')), vat: f(h => h.startsWith('THUE SUAT VAT')),
    note: f(h => h === 'NOTE'), kt: f(h => h.startsWith('KT PHAN HOI')), note2: f(h => h.startsWith('NOTE XUAT')),
  };
  for (const [k, n] of [['ten', 'Tên hàng'], ['sl', 'Lượng'], ['gia', 'Đơn giá bán']] as const) if ((c as any)[k] < 0) throw new Error(`File check APT: thiếu cột "${n}"`);
  const g = (r: any[], i: number) => (i >= 0 ? r[i] : null);
  // Cột mã đơn (MDxxxx) không có tiêu đề: nằm giữa cột Sale và MÃ KHAI BÁO
  const mdCell = (r: any[]) => { for (let i = Math.max(0, c.sale + 1); i < ikb; i++) { const s = clean(r[i]).toUpperCase(); if (/^MD\s*\d+$/.test(s)) return normMd(s); } return ''; };
  const out: AptRow[] = []; let cur = { mahang: '', don: '', sale: '', md: '' };
  for (const r of rows.slice(hi + 1)) {
    if (!r || !/^\d+$/.test(clean(r[0]).replace(/\.0+$/, '')) || !clean(g(r, c.ten))) continue;
    const kb = normKb(r[ikb]); const md = mdCell(r);
    const head = !!(md || clean(g(r, c.don)) || clean(g(r, c.mahang)));
    if (head) cur = { mahang: clean(g(r, c.mahang)), don: clean(g(r, c.don)), sale: clean(g(r, c.sale)) || cur.sale, md: md || kbMd(kb) };
    const mdRow = kbMd(kb) || cur.md;
    out.push({ apt_stt: Number(clean(r[0])), apt_mahang: cur.mahang, don: cur.don, sale_apt: clean(g(r, c.sale)) || cur.sale, md_apt: mdRow, dau_khoi: head, ma_kb: kb,
      hh: clean(g(r, c.hh)), ten: clean(g(r, c.ten)), sl: vnNum(g(r, c.sl)), dvt: clean(g(r, c.dvt)), nk: pct(g(r, c.nk)), gia_nhap: vnNum(g(r, c.gia)), vat: pct(g(r, c.vat)),
      note: clean(g(r, c.note)), kt: clean(g(r, c.kt)), note2: clean(g(r, c.note2)), gia_note: ((x, gn) => (x && gn && Math.abs(x - gn) <= 0.5 ? null : x))(notePrice(g(r, c.note)), vnNum(g(r, c.gia))), gia_khach_sale_ghi: null });
  }
  if (!out.length) throw new Error('File check APT: không có dòng hàng nào');
  const tot = (k: string) => { const i = f(h => h.startsWith(k)); return i >= 0 && hi > 0 ? vnNum(rows[hi - 1]?.[i]) : null; };
  return { rows: out, total: tot('THANH TIEN THANH TOAN') ?? tot('THANH TIEN'), vat: tot('TIEN VAT') };
}
function parseAptLegacy(rows: any[][], hi: number): { rows: AptRow[]; total: number | null; vat: number | null } {
  const out: AptRow[] = []; let cur = { mahang: '', don: '', sale: '', md: '' };
  for (const r of rows.slice(hi + 1)) {
    if (!r || !/^\d+$/.test(clean(r[0]).replace(/\.0+$/, ''))) continue;
    const head = !!clean(r[6]);
    if (head) cur = { mahang: clean(r[1]), don: clean(r[6]), sale: clean(r[7]), md: clean(r[8]) };
    const gks = vnNum(r[25]);
    out.push({ apt_stt: Number(clean(r[0])), apt_mahang: cur.mahang, don: cur.don, sale_apt: clean(r[7]) || cur.sale, md_apt: cur.md, dau_khoi: head, ma_kb: '',
      hh: clean(r[10]), ten: clean(r[11]), sl: vnNum(r[12]), dvt: clean(r[13]), nk: pct(r[15]), gia_nhap: vnNum(r[17]), vat: pct(r[18]),
      note: clean(r[22]), kt: clean(r[23]), note2: (clean(r[24]) + ' ' + clean(r[25])).trim(), gia_note: notePrice(r[22]), gia_khach_sale_ghi: gks && gks > 100 ? gks : null });
  }
  if (!out.length) throw new Error('File check APT: không có dòng hàng nào');
  return { rows: out, total: hi > 0 ? vnNum(rows[hi - 1]?.[19]) : null, vat: hi > 0 ? vnNum(rows[hi - 1]?.[20]) : null };
}

/** File khai báo xuất từ hệ thống NamtrungLog (cột SALES NTG, ĐƠN HÀNG NTG, GIÁ TRÊN TỜ KHAI = giá khách) */
/** File xe hệ thống (KhaiBao_XH…). Bản 23: lấy theo tiêu đề — ID ĐƠN, USERNAME KHÁCH, SALE, MÃ KHAI BÁO… (file cũ: SALES NTG, ĐƠN HÀNG NTG) */
export function parseKhaiBao(rows: any[][]): SysRow[] {
  const hi = rows.slice(0, 15).findIndex(r => (r || []).some(x => { const h = HD(x); return h === 'MA KHAI BAO' || h.includes('SALES'); }) && (r || []).some(x => HD(x).startsWith('TEN KHAI BAO')));
  if (hi < 0) throw new Error('File khai báo: không thấy dòng tiêu đề có cột "MÃ KHAI BÁO" / "SALE" và "Tên KHAI BÁO"');
  const H = (rows[hi] || []).map(HD);
  const f = (p: (h: string) => boolean) => H.findIndex(h => !!h && p(h));
  const ci = (p: (h: string) => boolean, name: string, req = true) => { const i = f(p); if (i < 0 && req) throw new Error(`File khai báo: thiếu cột "${name}"`); return i; };
  const sale = f(h => h === 'SALE');
  const m = { ten: ci(h => h.startsWith('TEN KHAI BAO'), 'Tên KHAI BÁO'), sale: sale >= 0 ? sale : ci(h => h.includes('SALES'), 'SALE'),
    don: f(h => h === 'ID DON') >= 0 ? f(h => h === 'ID DON') : ci(h => h.includes('DON HANG'), 'ID ĐƠN'), kb: f(h => h === 'MA KHAI BAO'),
    sl: ci(h => h.startsWith('SO LUONG'), 'SỐ LƯỢNG'), dvt: ci(h => h === 'DVT' || h.startsWith('DON VI TINH'), 'DVT'), gia: ci(h => h.startsWith('GIA TREN TO KHAI'), 'GIÁ TRÊN TỜ KHAI'),
    nk: f(h => h.startsWith('THUE NK')), hs: f(h => h.startsWith('HS CODE')), mahang: f(h => h === 'MA HANG'),
    makh: f(h => h.startsWith('USERNAME') || h.startsWith('MA KH') || h.includes('MA KHACH') || h === 'USER' || h.includes('TAI KHOAN KH') || h.includes('MA HE THONG')) };
  const out: SysRow[] = []; let saleCur = '', md = '', kh = ''; const cnt: Record<string, number> = {};
  rows.slice(hi + 1).forEach((r, k) => {
    const ten = clean(r?.[m.ten]); if (!ten) return;
    const kb = m.kb >= 0 ? normKb(r[m.kb]) : '';
    if (clean(r[m.don])) md = normMd(r[m.don]); else if (kb) md = kbMd(kb);
    if (clean(r[m.sale])) saleCur = clean(r[m.sale]);
    if (m.makh >= 0 && clean(r[m.makh])) kh = clean(r[m.makh]); else if (clean(r[m.don])) kh = '';
    cnt[md] = (cnt[md] || 0) + 1;
    const mdf = m.mahang >= 0 ? clean(r[m.mahang]) : '';
    out.push({ sys_row: hi + 2 + k, ten, sale: saleCur, md, ma_dong: kb || (/^MD\d+-\d+$/i.test(mdf) ? normKb(mdf) : `${md}-${cnt[md]}`), ma_dong_file: kb || mdf,
      sl: vnNum(r[m.sl]), dvt: clean(r[m.dvt]), gia_khach: vnNum(r[m.gia]), nk: m.nk >= 0 ? pct(r[m.nk]) : 0, hs: m.hs >= 0 ? clean(r[m.hs]).replace(/\.0+$/, '') : '',
      ma_kh: kh });
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
  ma_kb_apt: string | null; match_kind: MatchKind | null;
}
/** Cách ghép dòng APT ↔ file xe: ma = đúng mã khai báo + SL · don = theo mã đơn + SL (lệch mã) · ma_lech_sl = đúng mã nhưng SL lệch */
export type MatchKind = 'ma' | 'don' | 'ma_lech_sl';
export const MATCH_KIND: Record<MatchKind, string> = { ma: 'Khớp mã', don: 'Ghép theo đơn – lệch mã', ma_lech_sl: 'Khớp mã – lệch số lượng' };
const eqSl = (a: number | null | undefined, b: number | null | undefined) => a != null && b != null && Math.abs(a - b) < 0.0001;

/** Bản 23 — ghép nháp APT ↔ file xe:
 *  1) đúng MÃ KHAI BÁO đầy đủ + cùng SL
 *  2) còn lại: cùng mã đơn MD + cùng SL, trong các dòng xe chưa ghép (1 ứng viên → ghép; nhiều → giữ ứng viên biên 0–10%)
 *  3) còn lại: đúng mã nhưng SL lệch → ghép, cảnh báo sai số SL
 *  Không đoán theo tên (APT viết lại tên hàng). Trả map chỉ số dòng APT → [chỉ số dòng xe, cách ghép] */
export function matchAptSys(apt: AptRow[], sys: SysRow[]): Map<number, [number, MatchKind]> {
  const out = new Map<number, [number, MatchKind]>(); const used = new Set<number>();
  const free = (j: number) => !used.has(j);
  const put = (i: number, j: number, k: MatchKind) => { out.set(i, [j, k]); used.add(j); };
  apt.forEach((a, i) => { if (!a.ma_kb) return; const j = sys.findIndex((s, j) => free(j) && s.ma_dong === a.ma_kb && eqSl(s.sl, a.sl)); if (j >= 0) put(i, j, 'ma'); });
  // lượt 2: ưu tiên dòng APT ít ứng viên trước để không "giành" nhầm
  const mdOf = (a: AptRow) => kbMd(a.ma_kb) || [...mdSet(a.md_apt)][0] || '';
  const cands = (a: AptRow) => { let c = sys.map((s, j) => j).filter(j => free(j) && sys[j].md === mdOf(a) && eqSl(sys[j].sl, a.sl));
    if (c.length > 1 && a.gia_nhap) { const b = c.filter(j => { const g = sys[j].gia_khach; const x = g ? g / a.gia_nhap! - 1 : NaN; return x >= 0 && x <= 0.1; }); if (b.length) c = b; }
    return c; };
  const rest = apt.map((a, i) => i).filter(i => !out.has(i) && mdOf(apt[i]));
  for (let round = 0; round < 3; round++) {
    let moved = false;
    rest.filter(i => !out.has(i)).sort((x, y) => cands(apt[x]).length - cands(apt[y]).length).forEach(i => { const c = cands(apt[i]); if (c.length === 1) { put(i, c[0], 'don'); moved = true; } });
    if (!moved) break;
  }
  apt.forEach((a, i) => { if (out.has(i) || !a.ma_kb) return; const j = sys.findIndex((s, j) => free(j) && s.ma_dong === a.ma_kb); if (j >= 0) put(i, j, 'ma_lech_sl'); });
  return out;
}
export interface ReconcileResult { lines: AccLine[]; stats: Record<string, any>; warnings: string[] }

/** saleAcc: tên sale (họ tên/tài khoản) → tài khoản chuẩn; trả null nếu chưa biết */
export function reconcile(apt: AptRow[], sys: SysRow[], tk: TkRow[], cfg: AccCfg = DEFAULT_ACC_CFG, saleAcc: (s: string) => string | null = s => s || null): ReconcileResult {
  const warnings: string[] = [];
  const acc = (s: string | null | undefined) => (s ? saleAcc(s) ?? null : null);
  // 1) file APT ↔ hệ thống: mã khai báo → mã đơn + SL (bản 23, không ghép theo tên)
  const mSys = matchAptSys(apt, sys);
  // 2) file APT ↔ tờ khai: thường 1:1 cùng thứ tự; lệch thì ghép theo tên + SL
  const tmap = new Map<number, TkRow>(); const sorted = [...apt].sort((a, b) => a.apt_stt - b.apt_stt);
  if (tk.length && sorted.length === tk.length && sorted.every((a, i) => sim(a.ten, tk[i].ten) >= 0.9)) sorted.forEach((a, i) => tmap.set(a.apt_stt, tk[i]));
  else if (tk.length) {
    const T = sorted.map(a => tk.map(t => sim(a.ten, t.ten) + (Math.abs((a.sl || 0) - t.sl) < 0.01 ? 0.2 : 0)));
    assign(T, 0.8).forEach(([j], i) => tmap.set(sorted[i].apt_stt, tk[j]));
    warnings.push(`Tờ khai ${tk.length} dòng, file APT ${apt.length} dòng — ghép theo tên + số lượng (${tmap.size} dòng).`);
  }
  const lanchi = new Set(cfg.sale_lanchi.map(norm)); const thang = new Set(cfg.md_xuat_thang.map(normMd)); const khThang = new Set((cfg.kh_xuat_thang || []).map(norm));
  const hq = cfg.hs_hop_quy_chuong; const { bien_nt_min: lo, bien_nt_max: hi, dung_sai_bien: tol, bien_muc_tieu: tgt } = cfg;
  const lines: AccLine[] = []; const usedSys = new Set<number>();

  const build = (s: SysRow | null, a: AptRow | null, t: TkRow | null, kind: MatchKind | null): AccLine => {
    const issues: string[] = [], notes: string[] = []; let level: 1 | 2 | 3 = 3;
    const add = (l: 1 | 2, x: string) => { issues.push(x); if (l < level) level = l; };
    // luồng
    const noteAll = stripAcc(((a?.note || '') + ' ' + (a?.note2 || '')).toUpperCase());
    const hs2 = (t?.hs || s?.hs || '').slice(0, 2);
    let luong: Luong = 'A';
    if (!a) luong = 'E';
    else if (noteAll.includes('XUAT THANG') || (s && (thang.has(s.md) || (!!s.ma_kh && khThang.has(norm(s.ma_kh))))) || [...mdSet(a.md_apt)].some(x => thang.has(x))) luong = 'C';
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
      if (!s && a && sys.some(x => x.md === (kbMd(a.ma_kb) || [...mdSet(a.md_apt)][0]))) add(1, `Đơn ${kbMd(a.ma_kb) || a.md_apt} có trên xe nhưng không ghép được dòng nào cùng mã/SL → kế toán ghép tay.`);
      else if (!s) add(1, 'Có trên file APT nhưng KHÔNG có đơn trên file xe → không có giá khách; nếu APT xuất HĐ, Nam Trung nhận hàng vào sổ mà không xuất được đầu ra. Sale nhập đơn lên hệ thống.');
      else if (!gk) add(1, 'Giá khách trên hệ thống = 0 → không xuất được HĐ đầu ra. Sale nhập giá khách đã chốt.');
      else if (ga && bien !== null) {
        // Bản 23: nháp đã chốt với APT qua Google Sheet → biên ngoài khung chỉ CẢNH BÁO + giá đề xuất (= giá khách ÷ 1,03, số liền) để sale copy, không chặn
        const de = Math.round(gk / (1 + tgt)); const gvon0 = t && t.nh ? t.nh + (t.sl ? t.tnk / t.sl : 0) : null;
        if (bien > hi + tol) { gde = de; add(2, `Biên NT ${(bien * 100).toFixed(2)}% > ${pc(hi)}% → đề xuất APT xuất giá ${de}.`); }
        else if (bien < lo - tol) {
          gde = de;
          if (gvon0 && de < gvon0) add(2, `Biên NT ${(bien * 100).toFixed(2)}% < ${pc(lo)}%; giá ${de} thấp hơn giá vốn tờ khai ${Math.round(gvon0)} → APT khó hạ, sale cân nhắc giá khách.`);
          else add(2, `Biên NT ${(bien * 100).toFixed(2)}% < ${pc(lo)}% → đề xuất APT xuất giá ${de}.`);
        }
        void ttApt;
      }
      if (s && t && Math.abs((s.nk || 0) - t.nk) > 0.001) add(2, `Thuế NK hệ thống ${Math.round((s.nk || 0) * 100)}% ≠ tờ khai ${Math.round(t.nk * 100)}% → sửa hệ thống theo tờ khai.`);
      if (s && a && a.gia_khach_sale_ghi && gk && Math.abs(a.gia_khach_sale_ghi - gk) > 1) add(2, `Sale ghi giá khách ${a.gia_khach_sale_ghi.toLocaleString('vi-VN')} trên file APT nhưng hệ thống là ${gk.toLocaleString('vi-VN')}.`);
      if (s) {
        const sAcc = acc(s.sale), aAcc = acc(a?.sale_apt || t?.sale || '');
        if (!sAcc) add(1, `Tên sale "${s.sale}" trên hệ thống chưa ghép với nhân sự ERP → vào Cấu hình kế toán ghép tên.`);
        else if (norm(sAcc) !== norm(aAcc || '')) notes.push(`Gộp đơn: file APT ghi sale "${a?.sale_apt || t?.sale || 'trống'}", hệ thống là ${s.sale} (${s.md}) → đã gán lại theo hệ thống.`);
        if (t && !mdSet(t.md_header).has(s.md)) notes.push(`${s.md} không có trong cột MÃ DH NTG của ${t.dh} (đầu khối ghi ${t.md_header || 'trống'}).`);
      }
      if (s && a && Math.abs((s.nk || 0) - a.nk) > 0.001 && !t) add(2, `Thuế NK file xe ${Math.round((s.nk || 0) * 100)}% ≠ APT ${Math.round(a.nk * 100)}%.`);
      if (kind === 'don') notes.push(`Ghép theo đơn ${s?.md} + SL: mã APT ${a?.ma_kb || 'trống'} ↔ mã xe ${s?.ma_dong} (lệch mã).`);
      if (kind === 'ma_lech_sl') add(2, `Lệch số lượng: xe ${s?.sl}, APT ${a?.sl} — 1 đơn = 1 xe, kiểm sai số.`);
    }
    if (s && a && s.dvt && a.dvt && norm(s.dvt) !== norm(a.dvt)) notes.push(`ĐVT hệ thống "${s.dvt}" → HĐ dùng "${a.dvt}".`);
    const vat = t?.vat ?? (a ? a.vat : null);
    if (vat !== null && vat !== undefined && vat > 0 && Math.abs(vat - 0.08) > 0.001) notes.push(`VAT ${Math.round(vat * 100)}% — thường tách HĐ riêng.`);
    // Bản 23: chỉ mức 1 mới chặn (thiếu đơn / giá khách / sale / cần ghép tay); mức 2 = cảnh báo
    const status: LineStatus = (level as number) === 1 ? 'blocked' : luong === 'A' || luong === 'E' ? 'ok' : 'info';
    let phan_hoi = '';
    if (a) {
      if (luong === 'C') phan_hoi = 'XUẤT THẲNG'; else if (luong === 'D') phan_hoi = 'CHỜ QUYẾT ĐỊNH (Lanchi)'; else if (status === 'blocked') phan_hoi = 'CHỜ SALE — chưa xuất';
      else if (luong === 'B') phan_hoi = 'CHỜ HỢP QUY';
      else if (gnote && Math.abs(gnote - (gn || 0)) > 0.5) phan_hoi = `XUẤT GIÁ ${Math.round(gnote)}`;
      else phan_hoi = 'CHỐT';
    }
    const gad = ga; const gvon = t && t.nh ? t.nh + (t.sl ? t.tnk / t.sl : 0) : null;
    return {
      line_key: a ? `A${a.apt_stt}` : `S${s!.ma_dong}`, ma_dong: s?.ma_dong || null, md: s?.md || null, sale_name: s?.sale || a?.sale_apt || t?.sale || null,
      sale_acc: acc(s?.sale || a?.sale_apt || t?.sale || ''), ma_kh: s?.ma_kh || null,
      sys_row: s?.sys_row ?? null, ten_ht: s?.ten ?? null, sl_ht: s?.sl ?? null, dvt_ht: s?.dvt ?? null, gia_khach: gk, nk_ht: s ? s.nk : null,
      apt_stt: a?.apt_stt ?? null, hh: a?.hh || null, dh: t?.dh || a?.don || null, sale_apt: a?.sale_apt || null, ten_apt: a?.ten ?? null, sl_apt: a?.sl ?? null, dvt_apt: a?.dvt || null,
      gia_nhap: gn, gia_note: gnote, note_apt: a?.note || null, nk_apt: a ? a.nk : null, vat: vat ?? null,
      tk_row: t?.tk_row ?? null, ten_tk: t?.ten ?? null, hs: t?.hs || s?.hs || null, sl_tk: t?.sl ?? null, dvt_tk: t?.dvt || null, gia_tk_nh: t?.nh ?? null, nk_tk: t ? t.nk : null,
      tnk_dv: t && t.sl ? t.tnk / t.sl : null, md_header: t?.md_header || a?.md_apt || null,
      luong, gia_ap_dung: gad, gia_de_xuat: gde, bien_nt: gk && gad ? gk / gad - 1 : bien, gia_von: gvon, bien_apt: gvon && gad ? gad / gvon - 1 : null, tt_apt: Math.round((gad || 0) * (sl || 0)), tt_khach: gk ? Math.round(gk * (sl || 0)) : null,
      status, level, issues, notes, phan_hoi, match_score: null, ma_kb_apt: a?.ma_kb || null, match_kind: kind,
    };
  };
  apt.forEach((a, i) => { const m = mSys.get(i); const s = m ? sys[m[0]] : null; if (m) usedSys.add(m[0]); lines.push(build(s, a, tmap.get(a.apt_stt) || null, m ? m[1] : null)); });
  const kinds = [...mSys.values()].reduce((o, [, k]) => ((o[k] = (o[k] || 0) + 1), o), {} as Record<string, number>);
  sys.forEach((s, j) => { if (!usedSys.has(j)) lines.push(build(s, null, null, null)); });
  const st = { apt: apt.length, sys: sys.length, tk: tk.length, matched_sys: mSys.size, matched_tk: tmap.size, khop_ma: kinds.ma || 0, ghep_don: kinds.don || 0, lech_sl: kinds.ma_lech_sl || 0,
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

/** Copy giá đề xuất dán vào Google Sheet APT: mỗi dòng "STT<Tab>giá" (số liền, không dấu chấm/phẩy), theo thứ tự STT */
export function aptPriceList(lines: any[]): string {
  return lines.filter(l => l.apt_stt && l.gia_de_xuat && !['C', 'D'].includes(l.luong)).sort((a, b) => a.apt_stt - b.apt_stt)
    .map(l => `${l.apt_stt}\t${Math.round(Number(l.gia_de_xuat))}`).join('\n');
}
/** % gọn: 0.035 → 3.5 (tránh 3.5000000000000004) */
export const pc = (x: number) => String(+(x * 100).toFixed(2));
/** Nội dung gửi APT đề nghị xuất lại giá (biên NT ngoài khung → đưa về mục tiêu). Trả '' nếu không có dòng nào */
export function aptPriceMsg(lines: any[], cfg: Pick<AccCfg, 'bien_muc_tieu' | 'bien_nt_min' | 'bien_nt_max'>, title = ''): string {
  const out = lines.filter(l => l.apt_stt && l.gia_khach && (l.gia_nhap || l.gia_ap_dung) && !['C', 'D'].includes(l.luong)).map(l => {
    const target = Math.round(Number(l.gia_khach) / (1 + cfg.bien_muc_tieu)); const cur = Number(l.gia_note || l.gia_nhap);
    const b = Number(l.gia_khach) / cur - 1;
    return b > cfg.bien_nt_max + 0.001 || b < cfg.bien_nt_min - 0.001 ? { l, target, cur } : null;
  }).filter(Boolean) as { l: any; target: number; cur: number }[];
  if (!out.length) return '';
  const f = (n: number) => String(Math.round(n * 100) / 100);
  return [`Nam Trung đề nghị APT xuất giá các dòng sau${title ? ' — ' + title : ''}:`,
    ...out.sort((a, b) => a.l.apt_stt - b.l.apt_stt).map(({ l, target, cur }) => `• STT ${l.apt_stt} | ${l.hh || ''} | ${String(l.ten_apt || l.ten_ht || '').slice(0, 60)} | SL ${f(Number(l.sl_apt || 0))} | giá nháp ${f(cur)} → Đề nghị APT xuất giá ${target}`),
    `(${out.length} dòng)`].join('\n');
}
