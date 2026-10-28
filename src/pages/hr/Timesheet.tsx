import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Loading, NumInput, Select, Table, Td, Tabs, useAction, useLoad, Input } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { downloadCSV, num, today } from '../../lib/format';

const COLORS: Record<string, string> = { '✓': 'text-emerald-600', '½': 'text-emerald-600', P: 'bg-amber-100 text-amber-800', R: 'bg-amber-100 text-amber-800', KL: 'bg-ink-200 text-ink-700',
  KP: 'bg-red-600 text-white', V: 'bg-red-100 text-red-700', Ô: 'bg-violet-100 text-violet-800', TS: 'bg-violet-100 text-violet-800', CT: 'bg-sky-100 text-sky-800', WFH: 'bg-sky-100 text-sky-800',
  G: 'bg-rose-100 text-rose-700', CN: 'text-ink-300', Lễ: 'bg-brand-50 text-brand-700' };
const color = (c: string) => COLORS[c] || COLORS[c?.split('+').slice(-1)[0]?.replace('½', '')] || COLORS[c?.split('+')[0]] || '';

export default function Timesheet() {
  const a = useApp(); const [tab, setTab] = useState('ts');
  const hr = a.isAdmin || a.has('hcns');
  return (
    <Layout title="Bảng công · Chuyên cần">
      {hr && <div className="mb-3"><Tabs value={tab} onChange={setTab} tabs={[['ts', 'Bảng công & chuyên cần'], ['phep', 'Sổ phép năm']]} /></div>}
      {tab === 'ts' ? <Sheet /> : <Entitlements />}
    </Layout>
  );
}

function Sheet() {
  const a = useApp(); const [month, setMonth] = useState(today().slice(0, 7)); const [unit, setUnit] = useState('');
  const { data, loading } = useLoad(() => db.rpc<any[]>('timesheet', { p_month: month + '-01' }), [month]);
  const rows = ((data as any[]) || []).filter(r => !unit || r.org_unit_id === unit);
  const nd = new Date(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 0).getDate();
  const days = Array.from({ length: nd }, (_, i) => String(i + 1).padStart(2, '0'));
  const wd = (d: string) => new Date(`${month}-${d}T00:00:00Z`).getUTCDay();
  const flex = a.settings.attendance?.flex_minutes ?? 100;
  const exp = () => downloadCSV(`bang-cong-${month}`, [['Mã', 'Họ tên', ...days, 'Công chuẩn', 'Công hưởng lương', 'Đi làm', 'Phép năm', 'Không lương', 'Không phép', 'Vắng không đơn', 'Phút muộn/sớm', 'Vượt quỹ', 'Báo gấp', 'Quên chấm', 'Chuyên cần', 'Xếp loại'],
    ...rows.map(r => [r.employee_code, r.full_name, ...days.map(d => r.days[d]?.c || ''), ...['cong_chuan', 'cong_huong_luong', 'di_lam', 'phep_nam', 'khong_luong', 'khong_phep', 'vang_khong_don', 'phut_muon_som', 'vuot_quy', 'bao_gap', 'quen_cham', 'chuyen_can', 'xep_loai'].map(k => r.summary[k])])]);
  return (
    <>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <Input type="month" className="w-44" value={month} onChange={e => setMonth(e.target.value)} />
        <Select className="w-44" options={a.units.filter(u => u.kind !== 'cong_ty').map(u => [u.id, u.name])} value={unit} onChange={setUnit} placeholder="Mọi phòng ban" />
        <Button onClick={exp}>Xuất Excel (CSV)</Button>
      </div>
      <Card bodyClass="p-0">
        {loading ? <Loading /> : !rows.length ? <Empty /> : <div className="overflow-x-auto"><table className="text-xs">
          <thead><tr className="border-b border-ink-200 bg-ink-50 text-ink-500">
            <th className="sticky left-0 z-10 min-w-[150px] bg-ink-50 px-3 py-2 text-left font-semibold">Nhân sự</th>
            {days.map(d => <th key={d} className={cx('w-8 px-0.5 py-2 text-center font-semibold', wd(d) === 0 && 'text-ink-300', wd(d) === 6 && 'text-brand-600')}>{d}<div className="text-[9px] font-normal">{['CN', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7'][wd(d)]}</div></th>)}
            {['Công', 'Phép', 'KL', 'KP/V', 'Muộn', 'Báo gấp', 'Quên', 'Chuyên cần'].map(h => <th key={h} className="whitespace-nowrap px-2 py-2 text-right font-semibold">{h}</th>)}
          </tr></thead>
          <tbody className="divide-y divide-ink-100">{rows.map(r => { const s = r.summary; return <tr key={r.profile_id} className="hover:bg-ink-50/60">
            <td className="sticky left-0 z-10 bg-white px-3 py-1.5"><b>{r.full_name}</b><div className="text-[10px] text-ink-400">{r.employee_code}</div></td>
            {days.map(d => { const c = r.days[d]?.c || ''; const l = r.days[d]?.l; return <td key={d} className="px-0.5 py-1 text-center" title={l ? `${l} phút muộn/sớm` : c}>
              {c && <span className={cx('inline-block min-w-[1.6rem] rounded px-0.5 py-0.5 text-[10px] font-bold', color(c))}>{c.replace('✓', '✓')}</span>}{l ? <div className="text-[9px] text-rose-600">{l}′</div> : null}</td>; })}
            <td className="whitespace-nowrap px-2 text-right">{num(s.cong_huong_luong, 1)}/{num(s.cong_chuan, 1)}</td><td className="px-2 text-right">{num(s.phep_nam, 1)}</td><td className="px-2 text-right">{num(s.khong_luong, 1)}</td>
            <td className={cx('px-2 text-right', (s.khong_phep + s.vang_khong_don) > 0 && 'font-bold text-red-600')}>{num(Number(s.khong_phep) + Number(s.vang_khong_don), 1)}</td>
            <td className={cx('whitespace-nowrap px-2 text-right', s.vuot_quy > 0 && 'font-bold text-red-600')}>{s.phut_muon_som}/{flex}′</td><td className="px-2 text-right">{s.bao_gap}</td><td className="px-2 text-right">{s.quen_cham}</td>
            <td className="px-2 text-right"><Badge color={s.xep_loai === 'A' ? 'green' : s.xep_loai === 'B' ? 'blue' : s.xep_loai === 'C' ? 'amber' : 'red'}>{num(s.chuyen_can, 0)} · {s.xep_loai}</Badge></td>
          </tr>; })}</tbody></table></div>}
      </Card>
      <div className="mt-3 flex flex-wrap gap-2 text-xs text-ink-600">
        {[['✓', 'Đủ công'], ['½', 'Nửa công'], ['P', 'Phép năm'], ['R', 'Việc riêng có lương'], ['Ô', 'Ốm'], ['KL', 'Không lương'], ['CT', 'Công tác'], ['WFH', 'Làm từ xa'], ['G', 'Vắng theo giờ'], ['V', 'Vắng không đơn'], ['KP', 'Nghỉ không phép'], ['Lễ', 'Nghỉ lễ']].map(([c, l]) =>
          <span key={c} className="flex items-center gap-1"><span className={cx('rounded px-1 font-bold', color(c))}>{c}</span>{l}</span>)}
      </div>
      <p className="mt-2 text-xs text-ink-500">Chuyên cần bắt đầu 100 điểm: trừ 20/ngày nghỉ không phép hoặc vắng không đơn, 5/đơn báo gấp, 3/lần quên chấm, 1 điểm mỗi 10 phút vượt quỹ {flex} phút. A ≥ 95 · B ≥ 85 · C ≥ 70 · D. Tham số chỉnh ở Cấu hình → Chấm công.</p>
    </>
  );
}

function Entitlements() {
  const a = useApp(); const y = Number(today().slice(0, 4)); const [year, setYear] = useState(y); const { run, busy } = useAction();
  const { data, reload } = useLoad(() => db.from('leave_entitlements').select('*').eq('year', year), [year]);
  const map = new Map(((data as any[]) || []).map(r => [r.profile_id, r]));
  const [edit, setEdit] = useState<Record<string, any>>({});
  const val = (id: string, k: string) => edit[id]?.[k] ?? map.get(id)?.[k] ?? (k === 'entitled' ? (a.settings.leave?.annual_days ?? 12) : 0);
  const set = (id: string, k: string, v: any) => setEdit(e => ({ ...e, [id]: { ...(e[id] || {}), [k]: v } }));
  const save = () => run(async () => {
    const rows = Object.entries(edit).map(([id, v]) => ({ profile_id: id, year, entitled: val(id, 'entitled'), carried: val(id, 'carried'), used_before: val(id, 'used_before'), ...v }));
    if (!rows.length) return;
    await db.from('leave_entitlements').upsert(rows, 'profile_id,year'); setEdit({}); reload();
  }, 'Đã lưu sổ phép');
  return (
    <Card title={`Sổ phép năm ${year}`} actions={<><Select className="w-28" options={[[String(y - 1), String(y - 1)], [String(y), String(y)], [String(y + 1), String(y + 1)]]} value={String(year)} onChange={v => setYear(Number(v))} />
      <Button variant="primary" loading={busy} disabled={!Object.keys(edit).length} onClick={save}>Lưu thay đổi</Button></>} bodyClass="p-0">
      <p className="px-4 pt-3 text-sm text-ink-600">Hệ thống bắt đầu dùng giữa năm: nhập <b>Được hưởng năm nay</b>, <b>Tồn năm trước</b> (dùng đến 30/06) và <b>Đã dùng trước khi lên hệ thống</b>. Phép còn lại = được hưởng + tồn − đã dùng − đơn đã duyệt trên hệ thống.</p>
      <Table head={['Nhân sự', 'Được hưởng năm nay', 'Tồn năm trước', 'Đã dùng trước khi lên hệ thống', 'Đã nhập']}>
        {a.people.filter(p => p.status === 'active').map(p => <tr key={p.id}><Td className="font-semibold">{p.full_name}<div className="text-xs font-normal text-ink-400">{p.employee_code}</div></Td>
          {['entitled', 'carried', 'used_before'].map(k => <Td key={k}><NumInput className="w-28" value={val(p.id, k)} onChange={v => set(p.id, k, v ?? 0)} /></Td>)}
          <Td>{map.has(p.id) ? <Badge color="green">Đã nhập</Badge> : <Badge color="amber">Chưa</Badge>}</Td></tr>)}
      </Table>
    </Card>
  );
}
