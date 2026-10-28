// Câu chào + lời chúc màn hình đăng nhập: mỗi máy / mỗi người, mỗi ngày một câu khác nhau
export interface LoginCard { emoji?: string; img?: string; name: string; sub?: string; tag?: string; tag2?: string; color?: string }
export interface LoginContent { headlines?: string[]; messages?: string[]; cards?: LoginCard[]; image?: string | null }
export const CARD_COLORS: Record<string, string> = { sun: '#ffcf3f', mint: '#22d3a0', aqua: '#58b7ff', hot: '#ff5c7a', brand: '#a996ff', nt: '#F07B3C' };
const dayNum = () => Math.floor((Date.now() + 7 * 3600e3) / 864e5);
function seedOf(key?: string) {
  if (key) { let h = 0; for (const c of key) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h % 997; }
  try { let s = localStorage.getItem('nt_seed'); if (!s) { s = String(Math.floor(Math.random() * 997)); localStorage.setItem('nt_seed', s); } return Number(s); } catch { return 0; }
}
export function pickDaily(list: string[] | undefined, salt = 0, key?: string) {
  const l = (list || []).map(x => x.trim()).filter(Boolean); if (!l.length) return '';
  return l[(dayNum() * (salt * 2 + 1) + seedOf(key)) % l.length];
}
