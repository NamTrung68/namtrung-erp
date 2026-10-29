import React, { useState } from 'react';
import { Button, cx, Modal, toast } from './ui';
import { copyText, money, num, tsv } from '../lib/format';
import { QuoteHeader, QuoteLine } from '../lib/quote-calc';

// Mã ĐVT hải quan cho các đơn vị hay gặp
const UNIT_CODE: Record<string, string> = { 'chiếc': 'PCE', 'cái': 'PCE', 'c': 'PCE', 'pce': 'PCE', 'pcs': 'PCE', 'bộ': 'SET', 'set': 'SET', 'kg': 'KGM', 'đôi': 'PR', 'mét': 'MTR', 'm': 'MTR', 'cuộn': 'ROL', 'tấm': 'SHT', 'hộp': 'BOX', 'thùng': 'CT', 'lít': 'LTR' };
export const unitCode = (u?: string | null) => UNIT_CODE[(u || '').trim().toLowerCase()] || (u || '');
export const nsxOf = (name: string) => (name.match(/nsx\s*:\s*(.+?)(?:,\s*(?:mới|hàng mới)\b.*)?\.?$/i)?.[1] || '').trim();

type Row = { l: QuoteLine; r: any };
async function doCopy(s: string, what: string) { await copyText(s); toast.ok(`Đã sao chép ${what}`); }

/** Bảng khai gửi APT + bảng dán lên hệ thống kê khai hàng hóa */
export function AptSheet({ open, onClose, code, maDon, h, rows, totals }: { open: boolean; onClose: () => void; code: string; maDon?: string; h: QuoteHeader; rows: Row[]; totals: any }) {
  const [tab, setTab] = useState<'apt' | 'sys'>('apt');
  const [hqUnit, setHqUnit] = useState(false);
  const triGia = rows.reduce((s, x) => s + x.r.triGiaKhai, 0);
  const thue = rows.reduce((s, x) => s + Math.round(x.r.dutyPct / 100 * x.r.triGiaKhai), 0);
  const aptOut = (triGia + thue) * 1.03; const ntOut = aptOut * 1.03;
  const aptRows = rows.map((x, i) => [i + 1, x.l.name, x.l.hs_code || '', x.l.qty, x.l.unit, x.r.giaKhaiDV, x.r.triGiaKhai, `${num(x.r.dutyPct)}%`, Math.round(x.r.dutyPct / 100 * x.r.triGiaKhai)]);
  const aptHead = ['STT', 'Tên hàng', 'HS', 'SL', 'ĐVT', 'Đơn giá khai', 'Trị giá khai', 'Thuế suất', 'Thuế NK'];
  const zalo = [`BẢNG KHAI GỬI APT – ${code}${maDon ? ` (đơn ${maDon})` : ''}`,
    ...rows.map((x, i) => `${i + 1}. ${x.l.name}\n   HS: ${x.l.hs_code || '—'} | SL: ${num(x.l.qty)} ${x.l.unit} | ĐG khai: ${money(x.r.giaKhaiDV)} | Trị giá: ${money(x.r.triGiaKhai)} | Thuế NK ${num(x.r.dutyPct)}%: ${money(Math.round(x.r.dutyPct / 100 * x.r.triGiaKhai))}`),
    `Tổng trị giá khai: ${money(triGia)} | Thuế NK: ${money(thue)}`].join('\n');
  const sysRows = rows.map(x => [x.l.name, hqUnit ? unitCode(x.l.unit) : x.l.unit, x.r.giaXuat, x.l.qty, x.r.dutyPct, x.r.vatPct, x.l.hs_code || '', nsxOf(x.l.name)]);
  // Đúng cú pháp nút "Sao chép / Dán" của hệ thống kê khai (mỗi dòng 1 object JSON, giữ nguyên thứ tự khóa)
  const sysJson = (i: number) => { const x = rows[i]; return {
    MoTa: x.l.name.replace(/\s*\n\s*/g, ' ').trim(), DonViTinh: hqUnit ? unitCode(x.l.unit) : (x.l.unit || ''), GiaKhaiHQToiThieu: Math.round(Number(x.r.giaXuat) || 0),
    SoLuong: Number(x.l.qty) || 0, ThueNK: Number(x.r.dutyPct) || 0, ThueVAT: Number(x.r.vatPct) || 0, MaHS: (x.l.hs_code || '').trim(), Consignee: '',
    TenNhaCungCap: nsxOf(x.l.name), HinhAnh: '', ChinhSachNhapKhau: '', Status: 1 }; };
  const copyRow = (i: number) => doCopy(JSON.stringify(sysJson(i)), `dòng ${i + 1} — bấm “Dán” trên hệ thống kê khai`);
  const sysHead = ['Tên SP, hàng hóa', 'Đơn vị tính', 'Đơn giá dự kiến (đ)', 'Số lượng', 'Thuế XNK (%)', 'Thuế VAT (%)', 'Mã HS', 'NSX'];
  const cell = 'border-b border-ink-100 px-2 py-2 align-top';
  const Copyable = ({ v, show, className }: { v: any; show?: React.ReactNode; className?: string }) =>
    <td className={cx(cell, 'cursor-copy hover:bg-brand-50', className)} title="Bấm để sao chép ô này" onClick={() => doCopy(String(v ?? ''), 'ô')}>{show ?? v}</td>;
  return (
    <Modal open={open} onClose={onClose} size="xl" title={<span>Bảng khai hàng – {code}{maDon && <span className="ml-2 text-sm font-medium text-ink-500">đơn {maDon}</span>}</span>}
      footer={tab === 'apt'
        ? <><span className="mr-auto text-xs text-ink-400">Phần sao chép không gồm cột giá Nam Trung xuất khách.</span>
          <Button onClick={() => doCopy(zalo, 'tin nhắn gửi APT')}>Sao chép tin nhắn Zalo</Button>
          <Button variant="primary" onClick={() => doCopy(tsv([aptHead, ...aptRows, ['', 'Tổng', '', '', '', '', triGia, '', thue]]), 'bảng khai APT')}>Sao chép bảng (Excel)</Button></>
        : <><label className="mr-auto flex items-center gap-2 text-xs text-ink-500"><input type="checkbox" checked={hqUnit} onChange={e => setHqUnit(e.target.checked)} /> Đổi ĐVT sang mã hải quan (Chiếc → PCE…)</label>
          <Button size="sm" onClick={() => doCopy(tsv([sysHead, ...sysRows]), 'bảng dạng Excel')}>Sao chép dạng Excel</Button>
          {rows.length > 1 && <Button onClick={() => doCopy(JSON.stringify(rows.map((_, i) => sysJson(i))), `${rows.length} dòng (mảng JSON)`)}>Sao chép tất cả</Button>}
          <Button variant="primary" onClick={() => copyRow(0)}>{rows.length > 1 ? 'Sao chép dòng 1' : 'Sao chép để dán'}</Button></>}>
      <div className="mb-3 inline-flex rounded-full bg-ink-100 p-1 text-sm font-semibold">
        {([['apt', 'Gửi APT'], ['sys', 'Dán lên hệ thống kê khai']] as const).map(([k, l]) =>
          <button key={k} onClick={() => setTab(k)} className={cx('rounded-full px-4 py-1.5', tab === k ? 'bg-white shadow-sm' : 'text-ink-500')}>{l}</button>)}
      </div>
      {tab === 'apt' ? <>
        <p className="mb-2 text-xs text-ink-500">Đơn giá khai = giá xuất cho khách × {num(h.heSoToKhai ?? 0.9425, 4)} ÷ (1 + thuế suất NK). Thuế NK = thuế suất × trị giá khai. Bấm vào ô bất kỳ để sao chép riêng ô đó.</p>
        <div className="overflow-x-auto rounded-xl border border-ink-200">
          <table className="w-full min-w-[900px] text-sm">
            <thead><tr className="bg-ink-50 text-left text-xs text-ink-500">
              {aptHead.map(x => <th key={x} className="px-2 py-2 font-semibold">{x}</th>)}
              <th className="border-l-2 border-dashed border-amber-300 bg-amber-50 px-2 py-2 font-semibold text-amber-800">NT xuất khách / ĐV</th>
              <th className="bg-amber-50 px-2 py-2 font-semibold text-amber-800">NT xuất – thành tiền</th></tr></thead>
            <tbody>{rows.map((x, i) => <tr key={i}>
              <td className={cell}>{i + 1}</td><Copyable v={x.l.name} className="min-w-[260px] whitespace-pre-wrap" /><Copyable v={x.l.hs_code} />
              <Copyable v={x.l.qty} show={num(x.l.qty)} className="text-right tabular-nums" /><Copyable v={x.l.unit} />
              <Copyable v={x.r.giaKhaiDV} show={money(x.r.giaKhaiDV)} className="text-right tabular-nums" />
              <Copyable v={x.r.triGiaKhai} show={money(x.r.triGiaKhai)} className="text-right tabular-nums" />
              <td className={cx(cell, 'text-right')}>{num(x.r.dutyPct)}%</td>
              <Copyable v={Math.round(x.r.dutyPct / 100 * x.r.triGiaKhai)} show={money(Math.round(x.r.dutyPct / 100 * x.r.triGiaKhai))} className="text-right tabular-nums" />
              <td className={cx(cell, 'border-l-2 border-dashed border-amber-300 bg-amber-50/60 text-right font-semibold tabular-nums text-amber-900')}>{money(x.r.giaXuat)}</td>
              <td className={cx(cell, 'bg-amber-50/60 text-right font-semibold tabular-nums text-amber-900')}>{money(x.r.tongTruocVAT)}</td>
            </tr>)}
              <tr className="bg-ink-50 font-bold"><td className="px-2 py-2" colSpan={6}>Tổng</td><td className="px-2 py-2 text-right tabular-nums">{money(triGia)}</td><td /><td className="px-2 py-2 text-right tabular-nums">{money(thue)}</td>
                <td className="border-l-2 border-dashed border-amber-300 bg-amber-50 px-2 py-2" /><td className="bg-amber-50 px-2 py-2 text-right tabular-nums text-amber-900">{money(totals.tongTruocVAT)}</td></tr>
            </tbody>
          </table>
        </div>
        <div className="mt-3 grid gap-3 md:grid-cols-2">
          <div className="rounded-xl bg-ink-50 p-3 text-sm">
            <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-ink-500">Kiểm tra chuỗi giá</div>
            <div className="flex justify-between gap-2"><span>APT xuất cho Nam Trung</span><b className="tabular-nums">({money(triGia)} + {money(thue)}) × 1,03 = {money(aptOut)}</b></div>
            <div className="flex justify-between gap-2"><span>Nam Trung xuất khách</span><b className="tabular-nums">{money(aptOut)} × 1,03 = {money(ntOut)}</b></div>
            <div className={cx('mt-1 text-xs', Math.abs(ntOut - totals.tongTruocVAT) <= Math.max(1000, totals.tongTruocVAT * 0.001) ? 'text-emerald-700' : 'text-amber-700')}>
              ≈ giá xuất {money(totals.tongTruocVAT)} {Math.abs(ntOut - totals.tongTruocVAT) <= Math.max(1000, totals.tongTruocVAT * 0.001) ? '✓ khớp' : `· lệch ${money(ntOut - totals.tongTruocVAT)}`}</div>
          </div>
          <div className="rounded-xl border-2 border-amber-300 bg-amber-50 p-3 text-sm">
            <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-amber-800">Giá Nam Trung xuất khách (nội bộ)</div>
            <div className="flex justify-between"><span>Tổng trước VAT (hóa đơn)</span><b className="tabular-nums">{money(totals.tongTruocVAT)}</b></div>
            <div className="flex justify-between"><span>VAT</span><b className="tabular-nums">{money(totals.vat)}</b></div>
            <div className="flex justify-between text-base"><span>Tổng sau VAT</span><b className="tabular-nums">{money(totals.tongSauVAT)}</b></div>
          </div>
        </div>
      </> : <>
        <p className="mb-2 text-xs text-ink-500">Bấm <b>📋 Sao chép dòng</b> rồi sang hệ thống kê khai bấm nút <b>Dán (Paste sao chép)</b> ở dòng hàng. Nhiều mặt hàng: sao chép & dán lần lượt từng dòng.
          <b> Đơn giá dự kiến = giá Nam Trung xuất cho khách</b> (trước VAT). NSX lấy từ phần “nsx:” trong tên hàng.</p>
        <div className="overflow-x-auto rounded-xl border border-[#2f6db5]">
          <table className="w-full min-w-[980px] text-sm">
            <thead><tr className="bg-[#2f6db5] text-left text-xs text-white">{sysHead.map(x => <th key={x} className="px-2 py-2 font-semibold">{x}</th>)}<th className="px-2 py-2" /></tr></thead>
            <tbody>{sysRows.map((r, i) => <tr key={i}>
              <Copyable v={r[0]} className="min-w-[280px] whitespace-pre-wrap" /><Copyable v={r[1]} />
              <Copyable v={r[2]} show={money(r[2] as number)} className="text-right font-semibold tabular-nums" /><Copyable v={r[3]} show={num(r[3] as number)} className="text-right tabular-nums" />
              <Copyable v={r[4]} className="text-right" /><Copyable v={r[5]} className="text-right" /><Copyable v={r[6]} /><Copyable v={r[7]} className="text-xs" />
              <td className={cell}><button className="rounded-lg border border-ink-200 px-2 py-1 text-xs font-semibold hover:bg-ink-50" onClick={() => copyRow(i)}>📋 Sao chép dòng {i + 1}</button></td>
            </tr>)}</tbody>
            <tfoot><tr className="bg-ink-50 text-xs"><td className="px-2 py-2 text-right" colSpan={2}>Tiền trước VAT</td><td className="px-2 py-2 text-right font-bold tabular-nums">{money(totals.tongTruocVAT)}</td>
              <td className="px-2 py-2 text-right font-bold tabular-nums">{num(rows.reduce((s, x) => s + Number(x.l.qty), 0))}</td><td className="px-2 py-2 text-right" colSpan={2}>Tiền thuế VAT <b className="tabular-nums">{money(totals.vat)}</b></td><td className="px-2 py-2" colSpan={3}>Tổng gồm VAT <b className="tabular-nums">{money(totals.tongSauVAT)}</b></td></tr></tfoot>
          </table>
        </div>
      </>}
    </Modal>
  );
}
