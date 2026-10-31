import React from 'react';
import { Badge } from '../../components/ui';
import { money } from '../../lib/format';
import { DEFAULT_ACC_CFG, LUONG } from '../../lib/doisoat';
import { useApp } from '../../state';

export const ST: Record<string, [string, string]> = {
  ok: ['Tự chốt', 'green'], blocked: ['Bị chặn — chờ sale', 'red'], replied: ['Sale đã trả lời', 'amber'], pending_approval: ['Chờ duyệt mở chặn', 'purple'],
  approved: ['Đã duyệt mở chặn', 'teal'], info: ['Theo dõi', 'slate'],
};
export const REPLY: Record<string, string> = { da_sua_ht: 'Đã sửa hệ thống', de_xuat_gia: 'Đề xuất giá khác', chuyen_xe_sau: 'Chuyển xe sau', xin_duyet: 'Xin duyệt ngoại lệ', xuat_thang: 'Đơn APT xuất thẳng' };
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
export const useAccCfg = () => { const a = useApp(); return { ...DEFAULT_ACC_CFG, ...(a.settings.accounting || {}) }; };
/** Giá đề nghị APT xuất để biên NT về mục tiêu (null nếu biên trong khung) */
export function deXuat(l: any, cfg: { bien_muc_tieu: number; bien_nt_min: number; bien_nt_max: number }): number | null {
  const gk = Number(l.gia_khach || l.claim_gia || 0), g = Number(l.gia_note || l.gia_nhap || 0);
  if (!gk || !g || ['C', 'D'].includes(l.luong)) return null; const b = gk / g - 1;
  return b > cfg.bien_nt_max + 0.001 || b < cfg.bien_nt_min - 0.001 ? Math.round(gk / (1 + cfg.bien_muc_tieu)) : null;
}
/** Cột Giá APT: giá nháp APT (cột R “Đơn giá bán”), dòng phụ NOTE / đề xuất */
export const GiaApt = ({ l }: { l: any }) => <><Money v={l.gia_nhap} />
  {l.gia_note && Math.abs(l.gia_note - (l.gia_nhap || 0)) > 0.5 && <div className="text-[11px] text-ink-500">NOTE <Money v={l.gia_note} /></div>}
  {l.gia_de_xuat && <div className="text-[11px] font-semibold text-brand-700">đề xuất {Math.round(l.gia_de_xuat)}</div>}</>;
/** Dòng chưa có chủ: chưa xác định được sale */
export const unowned = (l: any) => !l.sale_id;
