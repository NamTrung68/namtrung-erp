import React from 'react';
import { Badge } from '../../components/ui';
import { money } from '../../lib/format';
import { LUONG } from '../../lib/doisoat';

export const ST: Record<string, [string, string]> = {
  ok: ['Tự chốt', 'green'], blocked: ['Bị chặn — chờ sale', 'red'], replied: ['Sale đã trả lời', 'amber'], pending_approval: ['Chờ duyệt mở chặn', 'purple'],
  approved: ['Đã duyệt mở chặn', 'teal'], info: ['Theo dõi', 'slate'],
};
export const REPLY: Record<string, string> = { da_sua_ht: 'Đã sửa hệ thống', de_xuat_gia: 'Đề xuất giá khác', chuyen_xe_sau: 'Chuyển xe sau', xin_duyet: 'Xin duyệt ngoại lệ' };
export const LUONG_TONE: Record<string, string> = { A: 'blue', B: 'amber', C: 'slate', D: 'indigo', E: 'orange' };
export const StatusBadge = ({ s }: { s: string }) => <Badge color={ST[s]?.[1] || 'gray'}>{ST[s]?.[0] || s}</Badge>;
export const LuongBadge = ({ l }: { l: string }) => <Badge color={LUONG_TONE[l] || 'gray'}>{l}. {(LUONG as any)[l]}</Badge>;
export const pctTxt = (v: any) => (v === null || v === undefined || v === '' ? '' : (Number(v) * 100).toFixed(2).replace('.', ',') + '%');
export const bienTone = (v: any, lo = 0.025, hi = 0.04) => (v === null || v === undefined ? '' : Number(v) < lo - 0.001 ? 'text-red-600 font-semibold' : Number(v) > hi + 0.001 ? 'text-amber-700' : 'text-emerald-700');
/** Thời gian còn lại đến hạn */
export function dueTxt(due: string | null): [string, string] {
  if (!due) return ['', ''];
  const ms = new Date(due).getTime() - Date.now(); const h = Math.round(Math.abs(ms) / 36e5);
  if (ms < 0) return [`Quá hạn ${h < 1 ? '<1' : h}h`, 'text-red-600 font-semibold'];
  return [`Còn ${h < 1 ? '<1' : h}h`, h <= 4 ? 'text-amber-700 font-semibold' : 'text-ink-500'];
}
export const lineName = (l: any) => l.ten_apt || l.ten_tk || l.ten_ht || '';
export const Money = ({ v }: { v: any }) => <span className="tabular-nums">{v === null || v === undefined ? '' : money(v)}</span>;
