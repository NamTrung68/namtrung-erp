// Bản 47 — Đối chiếu người mua của yêu cầu HĐ với nguồn chứng thực cùng MST:
// HĐ ĐÃ KÝ (khách đã nhận) hoặc pháp nhân ĐÃ KÝ HĐ NGUYÊN TẮC. Hàm máy chủ: out_pn_check.
import React from 'react';
import { cx, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { fmtDate } from '../../lib/format';

export type PnSt = 'khop' | 'lech' | 'moi' | 'mst_sai' | 'khong_mst';
export interface PnCheck { st: PnSt; n?: number; diff?: string[]; email_khac?: boolean; src?: { loai: 'hd' | 'hdnt'; so: string; ngay: string | null; ten: string; dia_chi: string | null; email: string | null } }

export const pnCheck = (ids: string[]) => (ids.length ? db.rpc<Record<string, PnCheck>>('out_pn_check', { p_ids: ids }) : Promise.resolve({} as Record<string, PnCheck>));
export const PN_DIFF: Record<string, string> = { ten: 'tên', dia_chi: 'địa chỉ' };
export const srcTxt = (c?: PnCheck) => !c?.src ? '' : c.src.loai === 'hdnt' ? `HĐ nguyên tắc ${c.src.so || ''}`.trim() : `HĐ đã ký ${c.src.so || ''}${c.src.ngay ? ' ngày ' + fmtDate(c.src.ngay) : ''}`;
export const pnLabel = (c?: PnCheck): string => !c ? '' : c.st === 'khop' ? `✓ Khớp ${srcTxt(c)}` : c.st === 'lech' ? `⚠ Khác ${(c.diff || []).map(k => PN_DIFF[k] || k).join(', ')} so với ${srcTxt(c)}`
  : c.st === 'moi' ? '★ MST lần đầu — chưa có HĐ đã ký / HĐNT' : c.st === 'mst_sai' ? '⛔ MST sai dạng' : 'Không có MST';

/** Nhãn nhỏ trên dòng yêu cầu */
export function PnTag({ c }: { c?: PnCheck }) {
  if (!c) return null;
  const cls = c.st === 'khop' ? 'bg-emerald-50 text-emerald-700 ring-emerald-200' : c.st === 'lech' || c.st === 'mst_sai' ? 'bg-red-50 text-red-700 ring-red-200'
    : c.st === 'moi' ? 'bg-amber-50 text-amber-800 ring-amber-200' : 'bg-ink-100 text-ink-600 ring-ink-200';
  const tip = c.src ? `${srcTxt(c)}\nTên: ${c.src.ten}\nĐịa chỉ: ${c.src.dia_chi || '—'}${c.src.email ? '\nEmail: ' + c.src.email : ''}` : c.st === 'moi' ? 'Kiểm tên, địa chỉ với đăng ký thuế (bấm 🔍 cạnh MST)' : '';
  return <span title={tip} className={cx('rounded-md px-1.5 py-0.5 text-[11px] font-semibold ring-1', cls)}>{pnLabel(c)}{c.st === 'khop' && c.email_khac ? ' · email khác' : ''}</span>;
}

/** Bảng so từng trường trong chi tiết yêu cầu: yêu cầu ↔ nguồn chứng thực */
export function PnCompare({ id, v }: { id: string; v: { buyer_name?: string | null; tax_code?: string | null; address?: string | null; email?: string | null } }) {
  const { data } = useLoad(() => pnCheck([id]).catch(() => ({} as Record<string, PnCheck>)), [id, v.buyer_name, v.address, v.tax_code, v.email]);
  const c = data?.[id]; if (!c) return null;
  const tone = c.st === 'khop' ? 'border-emerald-200 bg-emerald-50/60' : c.st === 'moi' ? 'border-amber-200 bg-amber-50/60' : 'border-red-200 bg-red-50/60';
  const row = (k: string, label: string, a?: string | null, b?: string | null) => { const bad = (c.diff || []).includes(k) || (k === 'email' && c.email_khac);
    return <tr key={k} className={bad ? 'text-red-700' : ''}><td className="whitespace-nowrap py-0.5 pr-2 text-ink-500">{label}</td><td className={cx('py-0.5 pr-2', bad && 'font-semibold')}>{a || '—'}</td><td className="py-0.5">{b || '—'}</td><td className="pl-1">{bad ? '✗' : '✓'}</td></tr>; };
  return <div className={cx('mt-2 rounded-xl border px-3 py-2 text-xs', tone)}>
    <div className="font-semibold">{pnLabel(c)}{c.n && c.n > 1 ? ` · MST có ${c.n} nguồn đối chiếu` : ''}</div>
    {c.src ? <table className="mt-1 w-full"><thead><tr className="text-left text-[11px] text-ink-400"><th /><th>Yêu cầu này</th><th>{srcTxt(c)}</th><th /></tr></thead>
      <tbody>{row('ten', 'Tên', v.buyer_name, c.src.ten)}{row('dia_chi', 'Địa chỉ', v.address, c.src.dia_chi)}{(v.email || c.src.email) ? row('email', 'Email', v.email, c.src.email) : null}</tbody></table>
      : c.st === 'moi' ? <div className="mt-0.5 text-ink-600">MST này chưa có HĐ đã ký hay HĐ nguyên tắc — bấm 🔍 cạnh MST để so với đăng ký thuế trước khi tạo nháp.</div> : null}
    <div className="mt-1 text-[11px] text-ink-500">So sánh bỏ qua hoa thường, dấu câu, cách viết TP / Thành phố, TDP / Tổ dân phố, “Số nhà” / “Số”, tiền tố Tỉnh, đuôi “Việt Nam”. Không bỏ dấu tiếng Việt.</div>
  </div>;
}
