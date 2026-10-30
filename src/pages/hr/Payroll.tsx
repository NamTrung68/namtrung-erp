import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Field, Input, Loading, Modal, NumInput, Select, Stat, Table, Td, toast, useAction, useLoad, ask } from '../../components/ui';
import { Pager, usePager } from '../../components/Pager';
import { db } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { readXlsx, toISODate, writeXlsx } from '../../lib/xlsx';
import { vietQrUrl } from '../../lib/vietqr';
import { addDays, downloadCSV, fmtDate, fmtDateTime, money, monthStart, num, today, stripVN } from '../../lib/format';

const PS: Record<string, [string, string]> = { open: ['Đang mở', 'blue'], review: ['Chờ nhân sự xác nhận', 'amber'], approval: ['Chờ BGĐ duyệt', 'purple'], closed: ['Đã chốt', 'green'] };
const SS: Record<string, [string, string]> = { draft: ['Nháp', 'gray'], sent: ['Chờ xác nhận', 'amber'], confirmed: ['Đã xác nhận', 'green'], disputed: ['Khiếu nại', 'red'], closed: ['Đã chốt', 'green'] };

export function Payroll() {
  const a = useApp(); const { run, busy } = useAction();
  const defMonth = addDays(monthStart(), -1).slice(0, 7);
  const [month, setMonthRaw] = useState(() => { try { return sessionStorage.getItem('nt_pay_month') || defMonth; } catch { return defMonth; } });
  const setMonth = (m: string) => { if (!/^\d{4}-\d{2}$/.test(m)) return; setMonthRaw(m); try { sessionStorage.setItem('nt_pay_month', m); } catch { /* */ } };
  const [sort, setSort] = useState<{ k: string; d: 1 | -1 }>({ k: 'name', d: 1 }); const [f, setF] = useState<Record<string, string>>({});
  const { data: per, reload: rp } = useLoad(() => db.from('payroll_periods').select('*').eq('month', month + '-01').maybeSingle(), [month]);
  const { data: slips, loading, reload } = useLoad(() => per ? db.from('payslips').select('*').eq('period_id', per.id) : Promise.resolve([]), [per?.id]);
  const { data: orders, reload: ro } = useLoad(() => per ? db.from('order_results').select('id,ext_order_code,sale_name,profile_id,order_profit,completed_at,customer_ext') .eq('period_id', per.id).limit(5000) : Promise.resolve([]), [per?.id]);
  const { data: privs } = useLoad(() => db.from('profile_private').select('profile_id,bank_bin,bank_account,bank_holder'), []);
  const [importOpen, setImportOpen] = useState(false); const [qr, setQr] = useState<any>(null); const [adj, setAdj] = useState<any>(null); const [other, setOther] = useState(false);
  if (!a.canHR) return <Layout title="Bảng lương"><Card>Chỉ HCNS, Kế toán, BGĐ.</Card></Layout>;
  const rows = ((slips as any[]) || []).slice().sort((x, y) => a.personName(x.profile_id).localeCompare(a.personName(y.profile_id)));
  const total = rows.reduce((s, r) => s + Number(r.net), 0);
  const unitOf = (r: any) => a.people.find(x => x.id === r.profile_id)?.org_unit_id || '';
  const levelOf = (r: any) => a.people.find(x => x.id === r.profile_id)?.job_level || '';
  const comDeptOf = (r: any) => Number(r.com_buyer || 0) + Number(r.com_cskh || 0) + Number(r.com_accounting || 0);
  const COLS: { k: string; l: string; v?: (r: any) => any; num?: boolean }[] = [
    { k: 'stt', l: 'STT' }, { k: 'name', l: 'Nhân sự', v: r => a.personName(r.profile_id) }, { k: 'paid_days', l: 'Công', num: true },
    { k: 'salary_by_days', l: 'Lương theo công', num: true }, { k: 'allowance', l: 'Phụ cấp', num: true }, { k: 'profit_total', l: 'LN đơn', num: true }, { k: 'commission', l: 'Hoa hồng Sale', num: true },
    { k: 'com_dept', l: 'COM bộ phận', v: comDeptOf, num: true }, { k: 'team_bonus', l: 'Thưởng đội', num: true }, { k: 'minus', l: 'Trừ', v: r => Number(r.flex_deduction) + Number(r.insurance), num: true },
    { k: 'adjustments', l: 'Điều chỉnh', num: true }, { k: 'net', l: 'Thực lĩnh', num: true }, { k: 'status', l: 'Trạng thái', v: r => SS[r.status]?.[0] }];
  const val = (c: typeof COLS[number], r: any) => c.v ? c.v(r) : c.num ? Number(r[c.k] || 0) : r[c.k];
  const view = rows.filter(r => {
    if (f.unit && unitOf(r) !== f.unit) return false;
    return true;
  }).sort((x, y) => { const c = COLS.find(z => z.k === sort.k); if (!c) return 0; const p = val(c, x), q = val(c, y); return (typeof p === 'number' ? p - q : String(p ?? '').localeCompare(String(q ?? ''), 'vi')) * sort.d; });
  const filtered = view.length !== rows.length; const viewTotal = view.reduce((s, r) => s + Number(r.net), 0);
  const shift = (m: string, k: number) => { const [y, mo] = m.split('-').map(Number); const d = new Date(y, mo - 1 + k, 1); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
  const cur = monthStart().slice(0, 7); const quick = [-4, -3, -2, -1, 0, 1].map(k => shift(cur, k));
  const unmapped = Array.from(new Set(((orders as any[]) || []).filter(o => !o.profile_id).map(o => o.sale_name)));
  const exportXlsx = () => { const H = ['STT', 'Mã NV', 'Họ tên', 'Bộ phận', 'Cấp', 'Công chuẩn', 'Công hưởng lương', 'Đi làm', 'Phép có lương', 'Nghỉ không lương', 'Phút muộn/sớm', 'Vượt quỹ', 'Lương cơ bản', 'Lương theo công', 'Phụ cấp', 'LN đơn', 'LN tính thưởng', 'Hoa hồng Sale', 'Bù trừ lỗ', 'COM Mua hàng', 'COM CSKH', 'COM Kế toán', 'Thưởng đội', 'Trừ vượt quỹ phút', 'BHXH', 'Điều chỉnh', 'Thực lĩnh', 'Trạng thái'];
    const N = (x: any) => Number(x) || 0;
    const body = view.map((r, i) => { const pp = a.people.find(p => p.id === r.profile_id); return [i + 1, pp?.employee_code || '', a.personName(r.profile_id), a.units.find(u => u.id === pp?.org_unit_id)?.name || '', a.levels.find(l => l.code === pp?.job_level)?.name || '',
      N(r.standard_days), N(r.paid_days), N(r.worked_days), N(r.paid_leave_days), N(r.unpaid_days), N(r.late_minutes), N(r.flex_over_minutes), N(r.base_salary), N(r.salary_by_days), N(r.allowance), N(r.profit_total), N(r.commission_base), N(r.commission), N(r.loss_offset),
      N(r.com_buyer), N(r.com_cskh), N(r.com_accounting), N(r.team_bonus), N(r.flex_deduction), N(r.insurance), N(r.adjustments), N(r.net), SS[r.status]?.[0]]; });
    const sum = H.map((_, j) => j === 2 ? 'TỔNG' : j >= 12 && j <= 26 ? body.reduce((t, x) => t + (x[j] as number), 0) : '');
    const unit = f.unit ? '-' + stripVN(a.units.find(u => u.id === f.unit)?.name || '').replace(/\s+/g, '-').toLowerCase() : '';
    return writeXlsx(`bang-luong-${month}${unit}`, [H, ...body, sum], `Lương ${month}`); };
  return (
    <Layout title="Bảng lương" actions={<div className="flex items-center gap-1"><Button size="sm" title="Tháng trước" onClick={() => setMonth(shift(month, -1))}>‹</Button><Input type="month" className="w-40" value={month} onChange={e => setMonth(e.target.value)} /><Button size="sm" title="Tháng sau" onClick={() => setMonth(shift(month, 1))}>›</Button></div>}>
      <div className="mb-3 flex flex-wrap items-center gap-1.5 text-xs"><span className="text-ink-500">Xem nhanh:</span>{quick.map(m => <button key={m} onClick={() => setMonth(m)}
        className={cx('rounded-full border px-3 py-1 font-semibold transition', m === month ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-700 hover:border-brand-400')}>T{Number(m.slice(5))}/{m.slice(0, 4)}{m === cur ? ' · tháng này' : ''}</button>)}</div>
      {!per ? <Card><div className="flex flex-wrap items-center gap-3 text-sm">Chưa mở kỳ lương tháng {month}. <Button variant="dark" loading={busy} onClick={() => run(async () => { await db.rpc('payroll_open', { p_month: month + '-01' }); rp(); }, 'Đã mở kỳ lương')}>Mở kỳ lương</Button></div></Card> : <>
        <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Trạng thái kỳ" value={<Badge color={PS[per.status][1]} className="text-sm">{PS[per.status][0]}</Badge>} sub={per.computed_at ? `Tính lúc ${fmtDateTime(per.computed_at)}` : 'Chưa tính'} />
          <Stat label="Số phiếu lương" value={rows.length} sub={`${rows.filter(r => r.status === 'confirmed').length} đã xác nhận · ${rows.filter(r => r.status === 'disputed').length} khiếu nại`} />
          <Stat label="Đơn hoàn thành đã nhập" value={(orders as any[])?.length || 0} sub={`LN ${money(((orders as any[]) || []).reduce((s, o) => s + Number(o.order_profit), 0))}`} />
          <Stat label="Tổng thực lĩnh" value={money(total)} />
        </div>
        <div className="mb-3 flex flex-wrap gap-2">
          {per.status !== 'closed' && a.has('ke_toan', 'admin', 'bgd') && <Button onClick={() => setImportOpen(true)}>1. Nhập file đơn hoàn thành (Excel)</Button>}
          {['open', 'review'].includes(per.status) && <Button variant="dark" loading={busy} onClick={() => run(async () => { const n = await db.rpc('payroll_compute', { p_period: per.id }); rp(); reload(); return n; }, 'Đã tính lương')}>2. Tính lương</Button>}
          {per.status === 'open' && rows.length > 0 && <Button loading={busy} onClick={() => run(async () => { await db.rpc('payroll_send_review', { p_period: per.id }); rp(); reload(); }, 'Đã gửi phiếu lương cho nhân sự')}>3. Gửi nhân sự xác nhận</Button>}
          {['review', 'approval'].includes(per.status) && a.isAdmin && <Button variant="success" loading={busy} onClick={async () => { if (await ask({ title: 'Chốt lương', message: `Chốt ${rows.length} phiếu, tổng ${money(total)} đ? Sau khi chốt không sửa được.`, ok: 'Chốt lương' })) run(async () => { await db.rpc('payroll_close', { p_period: per.id }); rp(); reload(); }, 'Đã chốt lương'); }}>4. BGĐ chốt lương</Button>}
          {per.status !== 'closed' && rows.length > 0 && a.has('ke_toan', 'admin', 'bgd') && <Button onClick={() => setOther(true)}>± COM hệ thống khác</Button>}
          <Button onClick={() => exportXlsx().catch(e => toast.err(e))}>⬇ Xuất Excel</Button>
        </div>
        {unmapped.length > 0 && <div className="mb-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Tên sale trong file chưa khớp nhân sự: <b>{unmapped.join(', ')}</b>. Vào <a className="underline" href="#/admin/users">Nhân sự & quyền</a> → thêm "Tên trong file đơn" cho đúng người, rồi nhập lại file.</div>}
        {rows.length > 0 && <div className="mb-2 flex flex-wrap items-center gap-1.5 text-xs"><span className="text-ink-500">Bộ phận:</span>
          {[['', 'Tất cả'] as [string, string], ...a.units.filter(u => rows.some(r => unitOf(r) === u.id)).map(u => [u.id, u.name] as [string, string])].map(([id, nm]) => { const n = id ? rows.filter(r => unitOf(r) === id).length : rows.length;
            return <button key={id || 'all'} onClick={() => setF(id ? { unit: id } : {})} className={cx('rounded-full border px-3 py-1 font-semibold transition', (f.unit || '') === id ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-700 hover:border-brand-400')}>{nm} <span className="opacity-60">{n}</span></button>; })}</div>}
        <Card bodyClass="p-0">
          {loading ? <Loading /> : !rows.length ? <Empty>Chưa tính lương kỳ này</Empty> :
            <div className="overflow-x-auto"><table className="w-full text-[13px] [&_td]:px-2 [&_td]:py-2">
              <thead className="sticky top-0 z-10"><tr className="border-b border-ink-200 bg-ink-50 text-left text-xs text-ink-500">{COLS.map(c => <th key={c.k} className={cx('whitespace-nowrap px-2 py-2.5 font-medium', c.num && 'text-right')}>
                {c.k === 'stt' ? c.l : <button className={cx('inline-flex items-center gap-1 hover:text-ink-900', sort.k === c.k && 'font-bold text-ink-900')} onClick={() => setSort(x => ({ k: c.k, d: x.k === c.k ? (x.d === 1 ? -1 : 1) : (c.num ? -1 : 1) }))}>{c.l}{sort.k === c.k && <span className="text-[10px]">{sort.d === 1 ? '▲' : '▼'}</span>}</button>}</th>)}</tr>
</thead>
              <tbody className="divide-y divide-ink-100">
              {!view.length && <tr><td colSpan={COLS.length} className="px-3 py-8 text-center text-ink-400">Không có phiếu lương khớp bộ lọc</td></tr>}
              {view.map((r, i) => { const pp = a.people.find(x => x.id === r.profile_id); const comDept = comDeptOf(r); return (
                <tr key={r.id} className="hover:bg-ink-50">
                  <Td className="text-center text-ink-400">{i + 1}</Td>
                  <Td className="whitespace-nowrap font-medium"><a className="text-ink-900 hover:text-brand-700 hover:underline" href={`#/hr/payslip?id=${r.id}`}>{a.personName(r.profile_id)}</a>
                    <div className="text-[11px] font-normal text-ink-400">{[a.levels.find(l => l.code === pp?.job_level)?.name, a.units.find(u => u.id === pp?.org_unit_id)?.name].filter(Boolean).join(' · ')}</div></Td>
                  <Td className="whitespace-nowrap text-right">{num(r.paid_days, 1)}/{num(r.standard_days, 1)}{(Number(r.unpaid_days) > 0 || r.late_minutes > 0) && <div className="text-[11px] text-ink-400">{Number(r.unpaid_days) > 0 && <span className="text-red-600">KL {num(r.unpaid_days, 1)} </span>}{r.late_minutes > 0 && <span className={r.flex_over_minutes > 0 ? 'text-red-600' : ''}>{r.late_minutes}′</span>}</div>}</Td>
                  <Td className="text-right">{money(r.salary_by_days)}</Td><Td className="text-right">{money(r.allowance)}</Td><Td className="text-right">{money(r.profit_total)}</Td>
                  <Td className="text-right">{money(r.commission)}{Number(r.loss_offset) > 0 && <div className="text-xs text-red-600">−{money(r.loss_offset)} bù lỗ</div>}</Td>
                  <Td className="text-right">{comDept ? money(comDept) : ''}<div className="text-[10px] leading-tight text-ink-400">{Number(r.com_buyer) > 0 && <div>MH {money(r.com_buyer)}</div>}{Number(r.com_cskh) > 0 && <div>CSKH {money(r.com_cskh)}</div>}{Number(r.com_accounting) > 0 && <div>KT {money(r.com_accounting)}</div>}</div></Td>
                  <Td className="text-right">{money(r.team_bonus)}</Td>
                  <Td className="text-right text-red-600">{money(Number(r.flex_deduction) + Number(r.insurance))}</Td>
                  <Td className="text-right">{money(r.adjustments)}{per.status !== 'closed' && <button className="ml-1 text-xs text-brand-700" onClick={() => setAdj(r)}>±</button>}</Td>
                  <Td className="text-right font-semibold">{money(r.net)}</Td>
                  <Td className="whitespace-nowrap"><div className="flex items-center gap-1.5"><Badge color={SS[r.status][1]}>{SS[r.status][0]}</Badge><button title="QR chuyển khoản trả lương" className="rounded-md border border-ink-200 px-1.5 py-0.5 text-[11px] font-semibold text-ink-600 hover:border-brand-400 hover:text-brand-700" onClick={() => setQr(r)}>QR</button></div>{r.dispute_note && <div className="max-w-[160px] whitespace-normal text-xs text-red-600">{r.dispute_note}</div>}</Td>
                </tr>); })}
              </tbody>
              {filtered && <tfoot><tr className="border-t border-ink-200 bg-ink-50 text-xs"><td colSpan={11} className="text-right text-ink-500">{a.units.find(u => u.id === f.unit)?.name} · {view.length}/{rows.length} người · tổng thực lĩnh</td><td className="text-right font-bold">{money(viewTotal)}</td><td /></tr></tfoot>}
            </table></div>}
        </Card>
        <p className="mt-2 text-xs text-ink-500">COM bộ phận: Mua hàng = phí mua hàng × {a.settings.payroll?.buyer_com?.fee_pct ?? 2}% + đàm phán × {(a.settings.payroll?.buyer_com?.nego_pct_by_month || [2, 3, 4, 5]).join('/')}% (tháng thâm niên 1/2/3/4+) × hệ số theo % hoàn thành chỉ tiêu đàm phán {(a.settings.payroll?.buyer_com?.target_pct_by_month || [2, 2.4, 2.7, 3]).join('/')}% · CSKH = phí dịch vụ × {a.settings.payroll?.cskh_com?.fee_pct ?? 2}% + đàm phán × {a.settings.payroll?.cskh_com?.nego_pct ?? 1}% · TP Kế toán = {a.settings.payroll?.accounting_com?.pct ?? 0.5}% × {a.settings.payroll?.accounting_com?.base_pct ?? 60}% LN đơn hoàn thành cả công ty. Hệ thống khác: Kế toán tính ngoài rồi nhập ở “± COM hệ thống khác”.</p>
        <p className="mt-1 text-xs text-ink-500">Hoa hồng = tỷ lệ theo cấp + lũy tiến (0–30tr, 30–65tr +3%, 65–100tr +5%, trên 100tr +7%) trên LN tính thưởng = {a.settings.payroll?.commission_base_pct ?? 60}% LN đơn. Đơn lỗ bù trừ tối đa 50% hoa hồng mỗi kỳ, phần còn lại chuyển kỳ sau. Thưởng quản lý 3% LN tính thưởng của đội (không gồm đơn của chính mình).</p>
        <ImportOrders open={importOpen} periodId={per.id} onClose={() => setImportOpen(false)} onDone={() => { setImportOpen(false); ro(); }} />
        {qr && <PayQr slip={qr} month={month} priv={((privs as any[]) || []).find(p => p.profile_id === qr.profile_id)} onClose={() => setQr(null)} />}
        {other && <OtherCom slips={rows} onClose={() => setOther(false)} onDone={() => { setOther(false); toast.info('Bấm "2. Tính lương" để cập nhật thực lĩnh'); }} />}
        {adj && <Adjust slip={adj} onClose={() => setAdj(null)} onDone={() => { setAdj(null); toast.info('Bấm "Tính lương" để cập nhật thực lĩnh'); }} />}
      </>}
    </Layout>
  );
}

function ImportOrders({ open, periodId, onClose, onDone }: { open: boolean; periodId: string; onClose: () => void; onDone: () => void }) {
  const [rows, setRows] = useState<any[] | null>(null); const [err, setErr] = useState(''); const [onlyDone, setOnlyDone] = useState(true); const { busy, run } = useAction();
  const parse = async (f: File) => {
    setErr(''); setRows(null);
    try {
      const sheets = await readXlsx(f); const s = sheets[0]; if (!s) throw new Error('File không có sheet');
      const hi = s.rows.findIndex(r => r.some(c => String(c ?? '').trim() === 'Mã đơn'));
      if (hi < 0) throw new Error('Không thấy dòng tiêu đề có cột "Mã đơn"');
      const H = s.rows[hi].map(c => stripVN(String(c ?? '')).toLowerCase().replace(/\s+/g, ' ').trim());
      const col = (...names: string[]) => H.findIndex(h => names.some(n => h.startsWith(n)));
      const colAll = (pred: (h: string) => boolean) => H.findIndex(pred);
      const c = { code: col('ma don'), status: col('trang thai don'), done: col('ngay hoan thanh'), cust: col('khach hang'), kho: col('kho nhan'), type: col('loai don'), sale: col('nhan vien kd'),
        goods: col('tong gia tri san pham quy doi'), profit: col('tong loi nhuan'), cskh: col('nhan vien cskh'), buyer: col('nhan vien mua hang'),
        fee: colAll(h => h.startsWith('phi mua hang') && !h.includes('cny')), nego: colAll(h => h.startsWith('tien hoa hong dam pha') && h.includes('vnd')), ship: colAll(h => h.startsWith('phi van chuyen noi dia') && h.includes('vnd')) };
      if (c.code < 0 || c.sale < 0 || c.profit < 0) throw new Error('Thiếu cột bắt buộc: Mã đơn, Nhân viên KD (Sale), Tổng lợi nhuận');
      const out = s.rows.slice(hi + 1).filter(r => r[c.code]).map(r => ({
        ext_order_code: String(r[c.code]).trim(), status: c.status >= 0 ? r[c.status] : '', sale_name: String(r[c.sale] ?? '').trim(), customer_ext: c.cust >= 0 ? String(r[c.cust] ?? '') : null,
        warehouse: c.kho >= 0 ? r[c.kho] : null, order_type: c.type >= 0 ? r[c.type] : null, completed_at: c.done >= 0 ? toISODate(r[c.done]) : null,
        goods_value: c.goods >= 0 ? Number(r[c.goods]) || 0 : 0, order_profit: Number(r[c.profit]) || 0,
        cskh_name: c.cskh >= 0 ? String(r[c.cskh] ?? '').trim() : '', buyer_name: c.buyer >= 0 ? String(r[c.buyer] ?? '').trim() : '',
        purchase_fee: c.fee >= 0 ? Number(r[c.fee]) || 0 : 0, nego_fee: c.nego >= 0 ? Number(r[c.nego]) || 0 : 0, domestic_ship: c.ship >= 0 ? Number(r[c.ship]) || 0 : 0,
        raw: Object.fromEntries(s.rows[hi].map((h: any, i: number) => [String(h ?? i), r[i] ?? null]).filter(([, v]) => v !== null)),
      }));
      setRows(out);
    } catch (e: any) { setErr(e.message); }
  };
  const use = (rows || []).filter(r => !onlyDone || !r.status || /hoan thanh/i.test(stripVN(String(r.status))));
  const bySale = useMemo(() => { const m = new Map<string, [number, number]>(); use.forEach(r => { const x = m.get(r.sale_name) || [0, 0]; m.set(r.sale_name, [x[0] + 1, x[1] + r.order_profit]); }); return Array.from(m.entries()); }, [rows, onlyDone]);
  return (
    <Modal open={open} onClose={onClose} title="Nhập file đơn hoàn thành" size="lg" footer={rows && <Button variant="primary" loading={busy} onClick={() => run(async () => {
      const r = await db.rpc('import_order_results', { p_period: periodId, p_rows: use.map(({ status, ...x }) => x), p_replace: true });
      toast.ok(`Đã nhập ${r.imported} đơn`); if (r.unmapped?.length) toast.err('Chưa khớp nhân sự: ' + r.unmapped.join(', ') + ' — thêm "Tên trong file đơn" ở Nhân sự & phân quyền'); onDone();
    })}>Nhập {use.length} đơn (thay toàn bộ dữ liệu kỳ này)</Button>}>
      <p className="mb-3 text-sm text-ink-600">Dùng file "BC Lợi nhuận" xuất từ hệ thống đơn hàng (.xlsx). Hệ thống đọc các cột: Mã đơn, Trạng thái đơn, Ngày hoàn thành, Khách hàng, Nhân viên KD (Sale), Nhân viên CSKH, Nhân viên mua hàng, Phí mua hàng (VND), Tiền hoa hồng đàm phán (VND), Tổng lợi nhuận.</p>
      <input type="file" accept=".xlsx" onChange={e => e.target.files?.[0] && parse(e.target.files[0])} className="text-sm" />
      {err && <div className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">{err}</div>}
      {rows && <div className="mt-4 space-y-3">
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={onlyDone} onChange={e => setOnlyDone(e.target.checked)} /> Chỉ lấy đơn trạng thái "Hoàn thành" ({use.length}/{rows.length})</label>
        <Table head={['Nhân viên KD trong file', 'Số đơn', 'Tổng lợi nhuận']}>{bySale.map(([s, [n, p]]) => <tr key={s}><Td>{s || <i>(trống)</i>}</Td><Td>{n}</Td><Td className="text-right">{money(p)}</Td></tr>)}</Table>
        <div className="grid gap-3 sm:grid-cols-2">{([['buyer_name', 'Nhân viên mua hàng'], ['cskh_name', 'Nhân viên CSKH']] as const).map(([k, l]) => { const m = new Map<string, [number, number, number]>(); use.forEach((r: any) => { const x = m.get(r[k]) || [0, 0, 0]; m.set(r[k], [x[0] + 1, x[1] + r.purchase_fee, x[2] + r.nego_fee]); });
          return <Table key={k} head={[l, 'Đơn', 'Phí mua hàng', 'Đàm phán']}>{Array.from(m.entries()).map(([n, [c, f, g]]) => <tr key={n}><Td>{n || <i>(trống)</i>}</Td><Td>{c}</Td><Td className="text-right">{money(f)}</Td><Td className="text-right">{money(g)}</Td></tr>)}</Table>; })}</div>
      </div>}
    </Modal>
  );
}

// Kế toán nhập nhanh tiền COM tính ở hệ thống khác cho từng người (ghi thành 1 dòng điều chỉnh)
const OTHER = 'COM hệ thống khác';
function OtherCom({ slips, onClose, onDone }: { slips: any[]; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const { busy, run } = useAction(); const [v, setV] = useState<Record<string, number | null>>({}); const [q, setQ] = useState('');
  const { data } = useLoad(() => db.from('payslip_adjustments').select('id,payslip_id,amount').eq('label', OTHER).in('payslip_id', slips.map(s => s.id)), []);
  const cur = new Map(((data as any[]) || []).map(x => [x.payslip_id, x]));
  const list = slips.filter(s => !q || a.personName(s.profile_id).toLowerCase().includes(q.toLowerCase()));
  const save = () => run(async () => {
    for (const s of slips) {
      if (!(s.id in v)) continue; const amt = v[s.id]; const old: any = cur.get(s.id);
      if (old && !amt) await db.from('payslip_adjustments').delete().eq('id', old.id);
      else if (old && amt !== Number(old.amount)) await db.from('payslip_adjustments').update({ amount: amt }).eq('id', old.id);
      else if (!old && amt) await db.from('payslip_adjustments').insert({ payslip_id: s.id, label: OTHER, amount: amt });
    }
    onDone();
  }, 'Đã lưu COM hệ thống khác');
  return <Modal open onClose={onClose} title="COM hệ thống khác (Sale · Mua hàng · CSKH…)" footer={<Button variant="primary" loading={busy} onClick={save}>Lưu</Button>}>
    <p className="mb-2 text-xs text-ink-500">Kế toán tính COM của các hệ thống phụ ở ngoài, nhập tổng số tiền cho từng người. Mỗi người 1 dòng “{OTHER}” trong phiếu lương, sửa lại bất cứ lúc nào trước khi chốt.</p>
    <Input className="mb-2" placeholder="Tìm nhân sự…" value={q} onChange={e => setQ(e.target.value)} />
    <div className="max-h-[55vh] divide-y divide-ink-100 overflow-y-auto rounded-xl border border-ink-200">{list.map(s => { const old: any = cur.get(s.id); const pp = a.people.find(x => x.id === s.profile_id);
      return <div key={s.id} className="flex items-center gap-3 px-3 py-2"><div className="min-w-0 flex-1"><div className="truncate text-sm font-medium text-ink-900">{a.personName(s.profile_id)}</div><div className="text-[11px] text-ink-400">{a.units.find(u => u.id === pp?.org_unit_id)?.name}</div></div>
        <NumInput className="w-36 shrink-0" placeholder="0" value={s.id in v ? v[s.id] : (old ? Number(old.amount) : null)} onChange={x => setV(m => ({ ...m, [s.id]: x }))} /></div>; })}</div>
  </Modal>;
}

function Adjust({ slip, onClose, onDone }: { slip: any; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [label, setLabel] = useState(''); const [amount, setAmount] = useState<number | null>(null); const { busy, run } = useAction();
  const { data, reload } = useLoad(() => db.from('payslip_adjustments').select('*').eq('payslip_id', slip.id).order('created_at'), [slip.id]);
  return (
    <Modal open onClose={onClose} title={`Điều chỉnh: ${a.personName(slip.profile_id)}`} size="sm" footer={<Button onClick={onDone}>Xong</Button>}>
      <ul className="mb-3 divide-y divide-ink-100 text-sm">{((data as any[]) || []).map(x => <li key={x.id} className="flex justify-between py-1.5"><span>{x.label}</span><span className="flex gap-2"><b>{money(x.amount)}</b>
        <button className="text-red-600" onClick={() => run(async () => { await db.from('payslip_adjustments').delete().eq('id', x.id); reload(); })}>✕</button></span></li>)}</ul>
      <div className="grid grid-cols-[1fr_140px] gap-2"><Input placeholder="VD: Thưởng nóng, BHXH, tạm ứng…" value={label} onChange={e => setLabel(e.target.value)} /><NumInput placeholder="± số tiền" value={amount} onChange={setAmount} /></div>
      <Button className="mt-2" variant="dark" loading={busy} onClick={() => run(async () => { if (!label || !amount) throw new Error('Nhập nội dung và số tiền'); await db.from('payslip_adjustments').insert({ payslip_id: slip.id, label, amount }); setLabel(''); setAmount(null); reload(); })}>Thêm dòng</Button>
      <p className="mt-2 text-xs text-ink-500">Số âm là khoản trừ. Mọi điều chỉnh được ghi nhật ký.</p>
    </Modal>
  );
}

function PayQr({ slip, month, priv, onClose }: { slip: any; month: string; priv: any; onClose: () => void }) {
  const a = useApp(); const name = a.personName(slip.profile_id);
  return (
    <Modal open onClose={onClose} title={`Trả lương: ${name}`} size="sm">
      {!priv?.bank_account || !priv?.bank_bin ? <p className="text-sm text-amber-700">Nhân sự chưa khai tài khoản ngân hàng (vào Tài khoản cá nhân → Ngân hàng).</p> :
        <div className="text-center"><img className="mx-auto w-64" alt="QR" src={vietQrUrl({ bin: priv.bank_bin, account: priv.bank_account, amount: Number(slip.net), content: `Luong T${month.slice(5)} ${month.slice(0, 4)} ${name}`, holder: priv.bank_holder })} />
          <div className="mt-2 text-sm">{priv.bank_holder} · {priv.bank_account}<br /><b className="text-lg">{money(slip.net)} đ</b></div></div>}
    </Modal>
  );
}

export function Payslips() {
  const a = useApp();
  const { data, loading } = useLoad(() => db.from('payslips').select('id,period_id,status,net,payroll_periods(month,status)').eq('profile_id', a.me.id).neq('status', 'draft').limit(36), []);
  const rows = ((data as any[]) || []).sort((x, y) => (y.payroll_periods?.month || '').localeCompare(x.payroll_periods?.month || ''));
  return (
    <Layout title="Phiếu lương của tôi">
      <Card bodyClass="p-0">{loading ? <Loading /> : !rows.length ? <Empty>Chưa có phiếu lương</Empty> :
        <Table head={['Tháng', 'Thực lĩnh', 'Trạng thái', '']}>{rows.map(r => <tr key={r.id} className="cursor-pointer hover:bg-ink-50" onClick={() => go(`/hr/payslip?id=${r.id}`)}>
          <Td>{r.payroll_periods?.month?.slice(5, 7)}/{r.payroll_periods?.month?.slice(0, 4)}</Td><Td className="font-semibold">{money(r.net)} đ</Td><Td><Badge color={SS[r.status][1]}>{SS[r.status][0]}</Badge></Td><Td>Xem →</Td></tr>)}</Table>}
      </Card>
    </Layout>
  );
}

export function PayslipView() {
  const a = useApp(); const { query } = useRoute(); const { busy, run } = useAction();
  const { data: s, loading, reload } = useLoad(() => db.from('payslips').select('*,payroll_periods(month,status)').eq('id', query.id).maybeSingle(), [query.id]);
  const { data: adj } = useLoad(() => db.from('payslip_adjustments').select('*').eq('payslip_id', query.id).order('created_at'), [query.id]);
  const { data: orders } = useLoad(() => s ? db.from('order_results').select('ext_order_code,customer_ext,completed_at,order_profit,profile_id,buyer_id,cskh_id,purchase_fee,nego_fee')
    .eq('period_id', s.period_id).or(`profile_id.eq.${s.profile_id},buyer_id.eq.${s.profile_id},cskh_id.eq.${s.profile_id}`).order('completed_at').limit(3000) : Promise.resolve([]), [s?.id]);
  const [otab, setOtab] = useState('sale');
  if (loading) return <Layout title="Phiếu lương"><Loading /></Layout>;
  if (!s) return <Layout title="Phiếu lương"><Card>Không tìm thấy phiếu lương.</Card></Layout>;
  const m = s.payroll_periods?.month || ''; const d = s.details || {};
  const L = ({ l, v, sub, neg }: { l: string; v: any; sub?: string; neg?: boolean }) => <div className="flex justify-between border-b border-ink-100 py-2 text-sm"><span>{l}{sub && <span className="block text-xs text-ink-400">{sub}</span>}</span><b className={neg ? 'text-red-600' : ''}>{v === null ? '' : (neg && Number(v) > 0 ? '−' : '') + money(v)}</b></div>;
  return (
    <Layout title={`Phiếu lương ${m.slice(5, 7)}/${m.slice(0, 4)} · ${a.personName(s.profile_id)}`} actions={<Button onClick={() => (history.length > 1 ? history.back() : go(a.canHR ? '/hr/payroll' : '/hr/payslips'))}>← Quay lại</Button>}>
      <div className="mb-3 flex flex-wrap items-center gap-2"><button className="text-sm font-semibold text-brand-700 hover:underline" onClick={() => (history.length > 1 ? history.back() : go(a.canHR ? '/hr/payroll' : '/hr/payslips'))}>← Quay lại</button>
        <span className="text-xs text-ink-500">{(() => { const pp = a.people.find(x => x.id === s.profile_id); return [a.personName(s.profile_id), a.levels.find(l => l.code === pp?.job_level)?.name, a.units.find(u => u.id === pp?.org_unit_id)?.name].filter(Boolean).join(' · '); })()}</span></div>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Chi tiết" actions={<Badge color={SS[s.status][1]}>{SS[s.status][0]}</Badge>}>
          <L l="Công chuẩn / công hưởng lương" v={null as any} sub={`${num(s.paid_days, 1)} / ${num(s.standard_days, 1)} công · đi làm ${num(s.worked_days, 1)} · phép có lương ${num(s.paid_leave_days, 1)} · nghỉ không lương ${num(s.unpaid_days, 1)}`} />
          <L l="Lương cơ bản" v={s.base_salary} />
          <L l="Lương theo công" v={s.salary_by_days} sub="lương cơ bản × công hưởng lương ÷ công chuẩn" />
          <L l="Phụ cấp" v={s.allowance} />
          {(Number(d.orders) > 0 || Number(s.profit_total) !== 0 || Number(s.commission) > 0) && <L l="Lợi nhuận đơn hoàn thành" v={s.profit_total} sub={`${d.orders ?? 0} đơn · LN tính thưởng ${d.commission_base_pct ?? 60}% = ${money(s.commission_base)}`} />}
          {(Number(d.orders) > 0 || Number(s.profit_total) !== 0 || Number(s.commission) > 0) && <L l="Hoa hồng lũy tiến" v={s.commission} sub={`tỷ lệ cơ bản ${num(d.commission_pct)}% + lũy tiến`} />}
          {Number(s.loss_offset) > 0 && <L l="Bù trừ đơn lỗ" v={s.loss_offset} neg sub={`còn chuyển kỳ sau ${money(s.carry_loss)}`} />}
          {Number(s.team_bonus) > 0 && <L l="Thưởng quản lý đội" v={s.team_bonus} />}
          {d.buyer_kpi && <L l="Lương theo KPI số đơn" v={null as any} sub={`${num(d.buyer_kpi.orders)} / ${num(d.buyer_kpi.target)} đơn = ${num(d.buyer_kpi.pct, 2)}% · ${num(d.buyer_kpi.share_pct)}% lương xét theo số đơn (đã tính vào lương theo công)`} />}
          {(Number(s.com_buyer) > 0 || d.buyer?.orders > 0) && <L l="COM Mua hàng" v={s.com_buyer} sub={`${d.buyer?.orders ?? 0} đơn · tháng thứ ${d.buyer?.month >= 4 ? '4+' : d.buyer?.month} · đàm phán đạt ${num(d.buyer?.rate_pct, 2)}% / chỉ tiêu ${num(d.buyer?.target_pct, 2)}% = hoàn thành ${num(d.buyer?.ach_pct, 2)}% → hệ số ${num(d.buyer?.coef_pct)}%
            · Phí mua hàng ${money(d.buyer?.purchase_fee)} × ${num(d.buyer?.fee_pct)}%${d.buyer?.coef_on_fee ? ' × hệ số' : ''} + Đàm phán ${money(d.buyer?.nego_fee)} × ${num(d.buyer?.nego_pct)}% × ${num(d.buyer?.coef_pct)}%`} />}
          {Number(s.com_cskh) > 0 && <L l="COM Chăm sóc khách hàng" v={s.com_cskh} sub={`${d.cskh?.orders ?? 0} đơn · phí dịch vụ ${money(d.cskh?.purchase_fee)} × ${num(d.cskh?.fee_pct)}% + đàm phán ${money(d.cskh?.nego_fee)} × ${num(d.cskh?.nego_pct)}%`} />}
          {Number(s.com_accounting) > 0 && <L l="COM Trưởng phòng Kế toán" v={s.com_accounting} sub={`LN đơn hoàn thành cả công ty ${money(d.accounting?.total_profit)} × ${num(d.accounting?.base_pct)}% × ${num(d.accounting?.pct)}%`} />}
          <L l="Đi muộn / về sớm" v={null as any} sub={`${s.late_minutes} phút · quỹ ${d.flex_minutes ?? 100} phút${d.flex_active ? '' : ' (chưa áp dụng)'} · vượt ${s.flex_over_minutes} phút`} />
          {Number(s.flex_deduction) > 0 && <L l="Không tính lương phần vượt quỹ" v={s.flex_deduction} neg />}
          {Number(s.insurance) > 0 && <L l="BHXH, BHYT, BHTN" v={s.insurance} neg />}
          {((adj as any[]) || []).map(x => <L key={x.id} l={x.label} v={x.amount} />)}
          <div className="flex justify-between pt-3"><span className="font-semibold">Thực lĩnh</span><b className="text-2xl">{money(s.net)} đ</b></div>
        </Card>
        <div className="space-y-4">
          {s.profile_id === a.me.id && ['sent', 'disputed', 'confirmed'].includes(s.status) && <Card title="Xác nhận phiếu lương">
            <p className="mb-3 text-sm text-ink-600">Kiểm tra trong 3 ngày. Nếu chưa đúng, ghi rõ dòng nào để HCNS/Kế toán xem lại.</p>
            <div className="flex gap-2"><Button variant="success" loading={busy} onClick={() => run(async () => { await db.rpc('payslip_respond', { p_id: s.id, p_agree: true }); reload(); }, 'Đã xác nhận')}>Đồng ý</Button>
              <Button variant="danger" onClick={async () => { const n = await ask({ title: 'Khiếu nại phiếu lương', input: { label: 'Dòng nào chưa đúng, vì sao', required: true } }); if (n) run(async () => { await db.rpc('payslip_respond', { p_id: s.id, p_agree: false, p_note: n }); reload(); }, 'Đã gửi khiếu nại'); }}>Chưa đúng</Button></div>
            {s.dispute_note && <p className="mt-2 text-sm text-red-600">Khiếu nại: {s.dispute_note}</p>}
          </Card>}
          <OrdersCard orders={(orders as any[]) || []} pid={s.profile_id} tab={otab} setTab={setOtab} />
        </div>
      </div>
    </Layout>
  );
}

export function orderUrl(code: string, tpl?: string) {
  const t = tpl || 'https://ad.namtrunglog.com/don-hang/{so}'; const so = (String(code).match(/\d+/g) || []).join('');
  return so ? t.replace('{so}', so).replace('{ma}', encodeURIComponent(code)) : null;
}
function OrdersCard({ orders, pid, tab, setTab }: { orders: any[]; pid: string; tab: string; setTab: (t: string) => void }) {
  const a = useApp(); const tpl = a.settings.payroll?.order_link;
  const groups: [string, string, any[]][] = [['sale', 'Đơn Sale', orders.filter(o => o.profile_id === pid)], ['buyer', 'Đơn Mua hàng', orders.filter(o => o.buyer_id === pid)], ['cskh', 'Đơn CSKH', orders.filter(o => o.cskh_id === pid)]];
  const shown = groups.filter(g => g[2].length); const cur = shown.find(g => g[0] === tab) || shown[0];
  const pg = usePager('slip_orders', [cur?.[0]]);
  const Code = ({ c }: { c: string }) => { const u = orderUrl(c, tpl); return u ? <a className="font-semibold text-brand-700 hover:underline" href={u} target="_blank" rel="noreferrer">{c} ↗</a> : <>{c}</>; };
  return <Card title="Đơn hoàn thành tính thưởng" actions={shown.length > 1 && <div className="flex gap-1">{shown.map(([k, l, xs]) => <button key={k} onClick={() => setTab(k)} className={cx('rounded-full border px-2.5 py-0.5 text-xs font-semibold', cur?.[0] === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200')}>{l} {xs.length}</button>)}</div>} bodyClass="p-0">
    {!cur ? <Empty>Không có đơn</Empty> : <>
      {cur[0] === 'sale' ? <Table head={['Mã đơn', 'Khách', 'Hoàn thành', 'Lợi nhuận']}>{pg.slice(cur[2]).map(o => <tr key={o.ext_order_code}><Td><Code c={o.ext_order_code} /></Td><Td>{o.customer_ext}</Td><Td>{fmtDate(o.completed_at)}</Td><Td className={Number(o.order_profit) < 0 ? 'text-right text-red-600' : 'text-right'}>{money(o.order_profit)}</Td></tr>)}</Table>
        : <Table head={['Mã đơn', 'Khách', 'Hoàn thành', 'Phí mua hàng', 'Đàm phán']}>{pg.slice(cur[2]).map(o => <tr key={o.ext_order_code}><Td><Code c={o.ext_order_code} /></Td><Td>{o.customer_ext}</Td><Td>{fmtDate(o.completed_at)}</Td><Td className="text-right">{money(o.purchase_fee)}</Td><Td className="text-right">{money(o.nego_fee)}</Td></tr>)}</Table>}
      <Pager p={pg} total={cur[2].length} /></>}
  </Card>;
}
