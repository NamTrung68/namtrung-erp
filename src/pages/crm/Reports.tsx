import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Empty, Input, Loading, Select, Table, Td, toast, useLoad, ErrorBox } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { addDays, copyTable, monthEnd, monthStart, money, num, today, weekStart, downloadCSV } from '../../lib/format';

export function usePeriod(initial = 'month') {
  const [kind, setKind] = useState(initial); const [from, setFrom] = useState(monthStart()); const [to, setTo] = useState(today());
  const apply = (k: string) => {
    setKind(k); const t = today();
    const lastM = addDays(monthStart(t), -1);
    const q = Math.floor((Number(t.slice(5, 7)) - 1) / 3) * 3 + 1;
    const map: Record<string, [string, string]> = {
      today: [t, t], yesterday: [addDays(t, -1), addDays(t, -1)], week: [weekStart(t), t], lastweek: [addDays(weekStart(t), -7), addDays(weekStart(t), -1)],
      month: [monthStart(t), t], lastmonth: [monthStart(lastM), lastM], quarter: [`${t.slice(0, 4)}-${String(q).padStart(2, '0')}-01`, t], year: [`${t.slice(0, 4)}-01-01`, t],
    };
    if (map[k]) { setFrom(map[k][0]); setTo(map[k][1]); }
  };
  const ui = (
    <div className="flex flex-wrap gap-2">
      <Select className="w-40" options={[['today', 'Hôm nay'], ['yesterday', 'Hôm qua'], ['week', 'Tuần này'], ['lastweek', 'Tuần trước'], ['month', 'Tháng này'], ['lastmonth', 'Tháng trước'], ['quarter', 'Quý này'], ['year', 'Năm nay'], ['custom', 'Tùy chọn']]} value={kind} onChange={apply} />
      <Input type="date" className="w-40" value={from} onChange={e => { setFrom(e.target.value); setKind('custom'); }} />
      <Input type="date" className="w-40" value={to} onChange={e => { setTo(e.target.value); setKind('custom'); }} />
    </div>
  );
  return { from, to, ui };
}

const KINDS: [string, string][] = [['kpi', 'KPI hoạt động'], ['care_due', 'Khách cần chăm'], ['funnel', 'Phễu theo nhân viên'], ['quotes', 'Báo giá'], ['reject_reasons', 'Lý do từ chối báo giá'],
  ['retention', 'Giữ khách & mua lại'], ['sources', 'Nguồn khách'], ['reports', 'Nộp báo cáo ngày'], ['transfers', 'Lịch sử chuyển khách']];

export default function Reports() {
  const a = useApp(); const p = usePeriod(); const [kind, setKind] = useState('kpi'); const [sale, setSale] = useState('');
  const { data, loading, error } = useLoad(() => kind === 'kpi' ? db.rpc('kpi_report', { p_from: p.from, p_to: p.to }) : db.rpc('crm_report', { p_kind: kind, p_from: p.from, p_to: p.to, p_sale: sale || null }), [kind, p.from, p.to, sale]);
  const metrics = a.settings.kpi?.metrics || {};
  let head: string[] = []; let rows: any[][] = [];
  if (data) {
    if (kind === 'kpi') {
      const keys = Object.keys(metrics);
      head = ['Nhân viên', ...keys.map(k => metrics[k].label), 'Gọi khai / nhật ký', 'Tin nhắn', 'Khách Nóng/Ấm', 'Đơn chốt', 'Quá hạn chăm', 'Điểm', 'Xếp loại'];
      rows = (data as any[]).filter(r => !sale || r.profile_id === sale).map(r => [r.full_name + (r.is_new ? ' (mới)' : ''), ...keys.map(k => `${r.metrics[k] ?? 0} / ${Math.round(metrics[k].day * r.metrics.days * (r.is_new ? (a.settings.kpi?.new_hire_factor ?? 0.7) : 1))}`),
        `${r.metrics.cuoc_goi_khai} / ${r.metrics.cuoc_goi_nhat_ky}`, r.metrics.tin_nhan_khai, r.metrics.khach_nong_am, r.metrics.don_chot, r.metrics.qua_han, num(r.score, 1), r.grade]);
    } else if (kind === 'retention') {
      head = ['Khách đã mua', 'Mua lại (≥ 2 đơn)', 'Tỷ lệ mua lại', 'Kho khách ngủ', 'Mất khách'];
      rows = [[data.buyers, data.repeat, (data.rate ?? 0) + '%', data.sleeping, data.lost]];
    } else {
      const arr = data as any[];
      const labels: Record<string, string> = { sale: 'Nhân viên', stage: 'Giai đoạn', n: 'Số lượng', status: 'Trạng thái', value: 'Giá trị sau VAT', profit: 'LN ước tính', reason: 'Lý do', source: 'Nguồn', won: 'Đã mua',
        overdue: 'Quá hạn', today: 'Hôm nay', forgotten: 'Bỏ quên > 30 ngày', submitted: 'Đã nộp', on_time: 'Đúng hạn', days: 'Ngày làm việc', at: 'Thời gian', code: 'Mã KH', customer: 'Khách', from_sale: 'Từ', to_sale: 'Sang', note: 'Ghi chú', by: 'Người chuyển' };
      head = arr[0] ? Object.keys(arr[0]).map(k => labels[k] || k) : [];
      rows = arr.map(r => Object.entries(r).map(([k, v]) => k === 'stage' ? a.label('stage', v as string) : k === 'reason' && kind === 'transfers' ? a.label('transfer_reason', v as string) : ['value', 'profit'].includes(k) ? money(v) : v));
    }
  }
  return (
    <Layout title="Báo cáo CRM">
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <Select className="w-56" options={KINDS} value={kind} onChange={setKind} />{p.ui}
        {a.isLead && <Select className="w-48" options={a.people.map(x => [x.id, x.full_name])} value={sale} onChange={setSale} placeholder="Cả nhóm" />}
        <Button onClick={() => copyTable([head, ...rows]).then(() => toast.ok('Đã sao chép — dán vào Google Sheet'))}>Sao chép bảng</Button>
        <Button onClick={() => downloadCSV(`bao-cao-${kind}-${p.from}_${p.to}`, [head, ...rows])}>Tải CSV</Button>
      </div>
      <ErrorBox error={error} />
      <Card bodyClass="p-0">
        {loading ? <Loading /> : !rows.length ? <Empty /> :
          <Table head={head}>{rows.map((r, i) => <tr key={i}>{r.map((c, j) => <Td key={j} className={j === r.length - 1 && kind === 'kpi' ? '' : ''}>{kind === 'kpi' && j === r.length - 1 ? <Badge color={c === 'Xuất sắc' ? 'green' : c === 'Đạt' ? 'blue' : c === 'Cần cải thiện' ? 'amber' : 'red'}>{c}</Badge> : String(c ?? '')}</Td>)}</tr>)}</Table>}
      </Card>
      {kind === 'kpi' && <p className="mt-2 text-xs text-ink-500">Điểm = Σ min(thực tế ÷ chỉ tiêu, 120%) × trọng số. Từ 100 điểm: Xuất sắc · 85: Đạt · 70: Cần cải thiện. Nhân viên mới chỉ tiêu × 0,7. Số liệu đếm tự động từ nhật ký; bài FB chỉ tính khi quản lý xác nhận.</p>}
    </Layout>
  );
}
