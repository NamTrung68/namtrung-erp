import { stripVN } from './format';
// Ảnh QR theo chuẩn VietQR (NAPAS) qua dịch vụ img.vietqr.io
export function vietQrUrl(o: { bin: string; account: string; amount?: number; content?: string; holder?: string; template?: string }) {
  const content = stripVN(o.content || '').replace(/[^A-Za-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 50);
  const q = new URLSearchParams();
  if (o.amount && o.amount > 0) q.set('amount', String(Math.round(o.amount)));
  if (content) q.set('addInfo', content);
  if (o.holder) q.set('accountName', stripVN(o.holder));
  return `https://img.vietqr.io/image/${encodeURIComponent(o.bin)}-${encodeURIComponent(o.account)}-${o.template || 'compact2'}.png?${q}`;
}
export const BANKS: [string, string][] = [
  ['970415', 'VietinBank'], ['970436', 'Vietcombank'], ['970418', 'BIDV'], ['970405', 'Agribank'], ['970407', 'Techcombank'],
  ['970422', 'MB Bank'], ['970416', 'ACB'], ['970432', 'VPBank'], ['970423', 'TPBank'], ['970403', 'Sacombank'],
  ['970437', 'HDBank'], ['970441', 'VIB'], ['970443', 'SHB'], ['970431', 'Eximbank'], ['970426', 'MSB'], ['970448', 'OCB'],
  ['970440', 'SeABank'], ['970454', 'Viet Capital'], ['970428', 'Nam A Bank'], ['970429', 'SCB'], ['970449', 'LPBank'], ['970425', 'ABBANK'],
];
