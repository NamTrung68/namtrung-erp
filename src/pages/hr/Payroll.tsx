import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Empty, Field, Input, Loading, Modal, NumInput, Select, Stat, Table, Td, toast, useAction, useLoad, ask } from '../../components/ui';
import { db } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { readXlsx, toISODate } from '../../lib/xlsx';
import { vietQrUrl } from '../../lib/vietqr';
import { addDays, downloadCSV, fmtDate, fmtDateTime, money, monthStart, num, today, stripVN } from '../../lib/format';

const PS: Record<string, [string, string]> = { open: ['Đang mở', 'blue'], review: ['Chờ nhân sự xác nhận', 'amber'], approval: ['Chờ BGĐ duyệt', 'purple'], closed: ['Đã chốt', 'green'] };
const SS: Record<string, [string, string]> = { draft: ['Nháp', 'gray'], sent: ['Chờ xác nhận', 'amber'], confirmed: ['Đã xác nhận', 'green'], disputed: ['Khiếu nại', 'red'], closed: ['Đã chốt', 'green'] };

export function Payroll() {
  const a = useApp(); const { run, busy } = useAction();
  const [month, setMonth] = useState(addDays(monthStart(), -1).slice(0, 7));
  const { data: per, reload: rp } = useLoad(() => db.from('payroll_periods').select('*').eq('month', month + '-01').maybeSingle(), [month]);
  const { data: slips, loading, reload } = useLoad(() => per ? db.from('payslips').select('*').eq('period_id', per.id) : Promise.resolve([]), [per?.id]);
  const { data: orders, reload: ro } = useLoad(() => per ? db.from('order_results').select('id,ext_order_code,sale_name,profile_id,order_profit,completed_at,customer_ext') .eq('period_id', per.id).limit(5000) : Promise.resolve([]), [per?.id]);
  const { data: privs } = useLoad(() => db.from('profile_private').select('profile_id,bank_bin,bank_account,bank_holder'), []);
  const [importOpen, setImportOpen] = useState(false); const [qr, setQr] = useState<any>(null); const [adj, setAdj] = useState<any>(null);
  if (!a.canHR) return <Layout title="Bảng lương"><Card>Chỉ HCNS, Kế toán, BGĐ.</Card></Layout>;
  const rows = ((slips as any[]) || []).slice().sort((x, y) => a.personName(x.profile_id).localeCompare(a.personName(y.profile_id)));
  const total = rows.reduce((s, r) => s + Number(r.net), 0);
  const unmapped = Array.from(new Set(((orders as any[]) || []).filter(o => !o.profile_id).map(o => o.sale_name)));
  const exportCsv = () => downloadCSV(`bang-luong-${month}`, [['Mã NV', 'Họ tên', 'Công chuẩn', 'Công hưởng lương', 'Đi làm', 'Phép có lương', 'Nghỉ không lương', 'Phút muộn/sớm', 'Vượt quỹ', 'Lương cơ bản', 'Lương theo công', 'Phụ cấp', 'LN đơn', 'LN tính thưởng', 'Hoa hồng', 'Bù trừ lỗ', 'Thưởng đội', 'Trừ vượt quỹ phút', 'BHXH', 'Điều chỉnh', 'Thực lĩnh', 'Trạng thái'],
    ...rows.map(r => [a.people.find(p => p.id === r.profile_id)?.employee_code, a.personName(r.profile_id), r.standard_days, r.paid_days, r.worked_days, r.paid_leave_days, r.unpaid_days, r.late_minutes, r.flex_over_minutes, r.base_salary, r.salary_by_days, r.allowance, r.profit_total, r.commission_base, r.commission, r.loss_offset, r.team_bonus, r.flex_deduction, r.insurance, r.adjustments, r.net, SS[r.status]?.[0]])]);
  return (
    <Layout title="Bảng lương" actions={<Input type="month" className="w-40" value={month} onChange={e => setMonth(e.target.value)} />}>
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
          <Button onClick={exportCsv}>Xuất Excel (CSV)</Button>
        </div>
        {unmapped.length > 0 && <div className="mb-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Tên sale trong file chưa khớp nhân sự: <b>{unmapped.join(', ')}</b>. Vào <a className="underline" href="#/admin/users">Nhân sự & quyền</a> → thêm "Tên trong file đơn" cho đúng người, rồi nhập lại file.</div>}
        <Card bodyClass="p-0">
          {loading ? <Loading /> : !rows.length ? <Empty>Chưa tính lương kỳ này</Empty> :
            <Table head={['Nhân sự', 'Công', 'Muộn/sớm', 'Lương theo công', 'Phụ cấp', 'LN đơn', 'Hoa hồng', 'Thưởng đội', 'Trừ', 'Điều chỉnh', 'Thực lĩnh', 'Trạng thái', '']}>
              {rows.map(r => (
                <tr key={r.id} className="hover:bg-ink-50">
                  <Td className="whitespace-nowrap font-medium"><a className="hover:underline" href={`#/hr/payslip?id=${r.id}`}>{a.personName(r.profile_id)}</a></Td>
                  <Td className="whitespace-nowrap">{num(r.paid_days, 1)}/{num(r.standard_days, 1)}{Number(r.unpaid_days) > 0 && <div className="text-xs text-red-600">KL {num(r.unpaid_days, 1)}</div>}</Td>
                  <Td>{r.late_minutes}′{r.flex_over_minutes > 0 && <div className="text-xs text-red-600">vượt {r.flex_over_minutes}′</div>}</Td>
                  <Td className="text-right">{money(r.salary_by_days)}</Td><Td className="text-right">{money(r.allowance)}</Td><Td className="text-right">{money(r.profit_total)}</Td>
                  <Td className="text-right">{money(r.commission)}{Number(r.loss_offset) > 0 && <div className="text-xs text-red-600">−{money(r.loss_offset)} bù lỗ</div>}</Td><Td className="text-right">{money(r.team_bonus)}</Td>
                  <Td className="text-right text-red-600">{money(Number(r.flex_deduction) + Number(r.insurance))}</Td>
                  <Td className="text-right">{money(r.adjustments)}{per.status !== 'closed' && <button className="ml-1 text-xs text-brand-700" onClick={() => setAdj(r)}>±</button>}</Td>
                  <Td className="text-right font-semibold">{money(r.net)}</Td>
                  <Td><Badge color={SS[r.status][1]}>{SS[r.status][0]}</Badge>{r.dispute_note && <div className="max-w-[160px] text-xs text-red-600">{r.dispute_note}</div>}</Td>
                  <Td><Button size="sm" onClick={() => setQr(r)}>QR trả</Button></Td>
                </tr>))}
            </Table>}
        </Card>
        <p className="mt-2 text-xs text-ink-500">Hoa hồng = tỷ lệ theo cấp + lũy tiến (0–30tr, 30–65tr +3%, 65–100tr +5%, trên 100tr +7%) trên LN tính thưởng = {a.settings.payroll?.commission_base_pct ?? 60}% LN đơn. Đơn lỗ bù trừ tối đa 50% hoa hồng mỗi kỳ, phần còn lại chuyển kỳ sau. Thưởng quản lý 3% LN tính thưởng của đội (không gồm đơn của chính mình).</p>
        <ImportOrders open={importOpen} periodId={per.id} onClose={() => setImportOpen(false)} onDone={() => { setImportOpen(false); ro(); }} />
        {qr && <PayQr slip={qr} month={month} priv={((privs as any[]) || []).find(p => p.profile_id === qr.profile_id)} onClose={() => setQr(null)} />}
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
      const c = { code: col('ma don'), status: col('trang thai don'), done: col('ngay hoan thanh'), cust: col('khach hang'), kho: col('kho nhan'), type: col('loai don'), sale: col('nhan vien kd'),
        goods: col('tong gia tri san pham quy doi'), profit: col('tong loi nhuan') };
      if (c.code < 0 || c.sale < 0 || c.profit < 0) throw new Error('Thiếu cột bắt buộc: Mã đơn, Nhân viên KD (Sale), Tổng lợi nhuận');
      const out = s.rows.slice(hi + 1).filter(r => r[c.code]).map(r => ({
        ext_order_code: String(r[c.code]).trim(), status: c.status >= 0 ? r[c.status] : '', sale_name: String(r[c.sale] ?? '').trim(), customer_ext: c.cust >= 0 ? String(r[c.cust] ?? '') : null,
        warehouse: c.kho >= 0 ? r[c.kho] : null, order_type: c.type >= 0 ? r[c.type] : null, completed_at: c.done >= 0 ? toISODate(r[c.done]) : null,
        goods_value: c.goods >= 0 ? Number(r[c.goods]) || 0 : 0, order_profit: Number(r[c.profit]) || 0,
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
      toast.ok(`Đã nhập ${r.imported} đơn`); if (r.unmapped?.length) toast.err('Chưa khớp nhân sự: ' + r.unmapped.join(', ')); onDone();
    })}>Nhập {use.length} đơn (thay toàn bộ dữ liệu kỳ này)</Button>}>
      <p className="mb-3 text-sm text-ink-600">Dùng file "BC Lợi nhuận" xuất từ hệ thống đơn hàng (.xlsx). Hệ thống đọc các cột: Mã đơn, Trạng thái đơn, Ngày hoàn thành, Khách hàng, Nhân viên KD (Sale), Tổng lợi nhuận.</p>
      <input type="file" accept=".xlsx" onChange={e => e.target.files?.[0] && parse(e.target.files[0])} className="text-sm" />
      {err && <div className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">{err}</div>}
      {rows && <div className="mt-4 space-y-3">
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={onlyDone} onChange={e => setOnlyDone(e.target.checked)} /> Chỉ lấy đơn trạng thái "Hoàn thành" ({use.length}/{rows.length})</label>
        <Table head={['Nhân viên KD trong file', 'Số đơn', 'Tổng lợi nhuận']}>{bySale.map(([s, [n, p]]) => <tr key={s}><Td>{s || <i>(trống)</i>}</Td><Td>{n}</Td><Td className="text-right">{money(p)}</Td></tr>)}</Table>
      </div>}
    </Modal>
  );
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
  const { data: orders } = useLoad(() => s ? db.from('order_results').select('ext_order_code,customer_ext,completed_at,order_profit').eq('period_id', s.period_id).eq('profile_id', s.profile_id).order('completed_at') : Promise.resolve([]), [s?.id]);
  if (loading) return <Layout title="Phiếu lương"><Loading /></Layout>;
  if (!s) return <Layout title="Phiếu lương"><Card>Không tìm thấy phiếu lương.</Card></Layout>;
  const m = s.payroll_periods?.month || ''; const d = s.details || {};
  const L = ({ l, v, sub, neg }: { l: string; v: any; sub?: string; neg?: boolean }) => <div className="flex justify-between border-b border-ink-100 py-2 text-sm"><span>{l}{sub && <span className="block text-xs text-ink-400">{sub}</span>}</span><b className={neg ? 'text-red-600' : ''}>{v === null ? '' : (neg && Number(v) > 0 ? '−' : '') + money(v)}</b></div>;
  return (
    <Layout title={`Phiếu lương ${m.slice(5, 7)}/${m.slice(0, 4)} · ${a.personName(s.profile_id)}`}>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Chi tiết" actions={<Badge color={SS[s.status][1]}>{SS[s.status][0]}</Badge>}>
          <L l="Công chuẩn / công hưởng lương" v={null as any} sub={`${num(s.paid_days, 1)} / ${num(s.standard_days, 1)} công · đi làm ${num(s.worked_days, 1)} · phép có lương ${num(s.paid_leave_days, 1)} · nghỉ không lương ${num(s.unpaid_days, 1)}`} />
          <L l="Lương cơ bản" v={s.base_salary} />
          <L l="Lương theo công" v={s.salary_by_days} sub="lương cơ bản × công hưởng lương ÷ công chuẩn" />
          <L l="Phụ cấp" v={s.allowance} />
          <L l="Lợi nhuận đơn hoàn thành" v={s.profit_total} sub={`${d.orders ?? 0} đơn · LN tính thưởng ${d.commission_base_pct ?? 60}% = ${money(s.commission_base)}`} />
          <L l="Hoa hồng lũy tiến" v={s.commission} sub={`tỷ lệ cơ bản ${num(d.commission_pct)}% + lũy tiến`} />
          {Number(s.loss_offset) > 0 && <L l="Bù trừ đơn lỗ" v={s.loss_offset} neg sub={`còn chuyển kỳ sau ${money(s.carry_loss)}`} />}
          {Number(s.team_bonus) > 0 && <L l="Thưởng quản lý đội" v={s.team_bonus} />}
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
          <Card title="Đơn hoàn thành tính hoa hồng" bodyClass="p-0">{!(orders as any[])?.length ? <Empty>Không có đơn</Empty> :
            <Table head={['Mã đơn', 'Khách', 'Hoàn thành', 'Lợi nhuận']}>{(orders as any[]).map(o => <tr key={o.ext_order_code}><Td>{o.ext_order_code}</Td><Td>{o.customer_ext}</Td><Td>{fmtDate(o.completed_at)}</Td><Td className={Number(o.order_profit) < 0 ? 'text-right text-red-600' : 'text-right'}>{money(o.order_profit)}</Td></tr>)}</Table>}</Card>
        </div>
      </div>
    </Layout>
  );
}
