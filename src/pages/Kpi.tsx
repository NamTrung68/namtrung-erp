import React, { useState } from 'react';
import { Layout } from '../components/Layout';
import { Badge, Button, Card, Empty, Loading, Select, Table, Td, Tabs, useAction, useLoad, ask } from '../components/ui';
import { db } from '../lib/sb';
import { useApp } from '../state';
import { money, num, monthStart, addDays } from '../lib/format';
import { usePeriod } from './crm/Reports';

export default function Kpi() {
  const a = useApp(); const p = usePeriod(); const [tab, setTab] = useState('board');
  const [by, setBy] = useState<'score' | 'profit'>('score');
  const { data, loading } = useLoad(() => db.rpc('leaderboard', { p_from: p.from, p_to: p.to }), [p.from, p.to]);
  const { data: mine } = useLoad(() => a.isSales ? db.rpc('kpi_report', { p_from: p.from, p_to: p.to }) : Promise.resolve([]), [p.from, p.to]);
  const { data: snaps } = useLoad(() => db.from('kpi_snapshots').select('*').order('period', { asc: false }).limit(500), []);
  const { run, busy } = useAction();
  const rows = ((data as any[]) || []).slice().sort((x, y) => by === 'score' ? x.rank_score - y.rank_score : x.rank_profit - y.rank_profit);
  const me = ((mine as any[]) || []).find(r => r.profile_id === a.me.id);
  const metrics = a.settings.kpi?.metrics || {};
  const periods = Array.from(new Set(((snaps as any[]) || []).map(s => s.period)));
  const [period, setPeriod] = useState('');
  const per = period || periods[0];
  const prev = periods[periods.indexOf(per) + 1];
  const snapRows = ((snaps as any[]) || []).filter(s => s.period === per);
  const prevMap = new Map(((snaps as any[]) || []).filter(s => s.period === prev).map(s => [s.profile_id, s]));
  return (
    <Layout title="KPI · Bảng Phong Thần" actions={a.isAdmin && <Button loading={busy} onClick={async () => {
      const m = await ask({ title: 'Chốt KPI tháng', message: 'Snapshot đã chốt không sửa được (chỉ điều chỉnh có lý do). Lương chốt cũng tự chốt KPI.', input: { label: 'Tháng (YYYY-MM)', required: true, placeholder: addDays(monthStart(), -1).slice(0, 7) } });
      if (m) run(async () => { const n = await db.rpc('kpi_close_month', { p_month: m + '-01' }); return n; }, 'Đã chốt KPI');
    }}>Chốt KPI tháng</Button>}>
      <div className="mb-3 flex flex-wrap items-center gap-2">{p.ui}</div>
      <Tabs value={tab} onChange={setTab} tabs={[['board', '🏆 Bảng Phong Thần'], ...(a.isSales ? [['mine', 'KPI của tôi']] as [string, string][] : []), ['history', 'Lịch sử theo tháng']]} />
      <div className="mt-4">
        {tab === 'board' && (loading ? <Loading /> : !rows.length ? <Empty>Chưa có dữ liệu xếp hạng</Empty> : <>
          <div className="mb-3 flex gap-2"><Button size="sm" variant={by === 'score' ? 'dark' : 'secondary'} onClick={() => setBy('score')}>Theo điểm KPI hoạt động</Button>
            <Button size="sm" variant={by === 'profit' ? 'dark' : 'secondary'} onClick={() => setBy('profit')}>Theo lợi nhuận</Button></div>
          <div className="mb-4 grid gap-3 sm:grid-cols-3">{rows.slice(0, 3).map((r, i) => (
            <div key={i} className={['border-amber-300 bg-gradient-to-b from-amber-50', 'border-ink-300 bg-gradient-to-b from-ink-100', 'border-orange-300 bg-gradient-to-b from-orange-50'][i] + ' rounded-2xl border to-white p-4 text-center'}>
              <div className="text-3xl">{['🥇', '🥈', '🥉'][i]}</div><div className="mt-1 text-lg font-semibold">{r.full_name}</div>
              <div className="text-sm text-ink-600">{by === 'score' ? `${num(r.score, 1)} điểm · ${r.grade}` : `${money(r.profit)} đ lợi nhuận`}</div></div>))}</div>
          <Card bodyClass="p-0"><Table head={['Hạng', 'Nhân viên', 'Điểm KPI', 'Xếp loại', 'Lợi nhuận (đơn hoàn thành)']}>{rows.map((r, i) => (
            <tr key={i} className={r.full_name === a.me.full_name ? 'bg-brand-50' : ''}><Td className="font-semibold">#{by === 'score' ? r.rank_score : r.rank_profit}</Td><Td>{r.full_name}</Td>
              <Td className="tabular-nums">{num(r.score, 1)}</Td><Td><Badge color={r.grade === 'Xuất sắc' ? 'green' : r.grade === 'Đạt' ? 'blue' : r.grade === 'Cần cải thiện' ? 'amber' : 'gray'}>{r.grade}</Badge></Td><Td className="text-right tabular-nums">{money(r.profit)}</Td></tr>))}</Table></Card>
          <p className="mt-2 text-xs text-ink-500">Nhóm cuối bảng không bị phạt — được ưu tiên hỗ trợ 1:1. Lợi nhuận lấy từ file đơn hoàn thành kế toán nhập.</p></>)}
        {tab === 'mine' && (!me ? <Empty>Chưa có số liệu</Empty> : <Card title={`Điểm: ${num(me.score, 1)} — ${me.grade}`}>
          <div className="space-y-3">{Object.entries(metrics).map(([k, m]: any) => {
            const target = m.day * me.metrics.days * (me.is_new ? (a.settings.kpi?.new_hire_factor ?? 0.7) : 1); const v = me.metrics[k] ?? 0; const pct = target ? Math.min(120, (v / target) * 100) : 0;
            return <div key={k}><div className="flex justify-between text-sm"><span>{m.label} <span className="text-ink-400">({m.weight}%)</span></span><b className="tabular-nums">{v} / {Math.round(target)}</b></div>
              <div className="mt-1 h-2 rounded-full bg-ink-100"><div className={pct >= 100 ? 'h-2 rounded-full bg-emerald-500' : pct >= 70 ? 'h-2 rounded-full bg-amber-500' : 'h-2 rounded-full bg-red-500'} style={{ width: `${Math.min(100, pct / 1.2)}%` }} /></div></div>;
          })}</div></Card>)}
        {tab === 'history' && <Card title="Snapshot đã chốt" actions={periods.length > 0 && <Select className="w-36" options={periods.map(x => [x, x])} value={per} onChange={setPeriod} />} bodyClass="p-0">
          {!snapRows.length ? <Empty>Chưa chốt tháng nào</Empty> : <Table head={['Hạng', 'Nhân viên', 'Điểm', 'So tháng trước', 'Lợi nhuận', 'So tháng trước']}>{snapRows.sort((x, y) => x.rank - y.rank).map(s => {
            const pv: any = prevMap.get(s.profile_id);
            const d1 = pv ? Number(s.score) - Number(pv.score) : null; const d2 = pv ? Number(s.profit) - Number(pv.profit) : null;
            return <tr key={s.id}><Td>#{s.rank}</Td><Td>{a.personName(s.profile_id)}</Td><Td>{num(s.score, 1)}</Td><Td className={d1 === null ? '' : d1 >= 0 ? 'text-emerald-700' : 'text-red-600'}>{d1 === null ? '—' : (d1 >= 0 ? '+' : '') + num(d1, 1)}</Td>
              <Td className="text-right">{money(s.profit)}</Td><Td className={d2 === null ? '' : d2 >= 0 ? 'text-emerald-700' : 'text-red-600'}>{d2 === null ? '—' : (d2 >= 0 ? '+' : '') + money(d2)}</Td></tr>;
          })}</Table>}
        </Card>}
      </div>
    </Layout>
  );
}
