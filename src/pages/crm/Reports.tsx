import React, { useMemo, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, cx, Empty, Input, Loading, Select, toast, ErrorBox } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { addDays, copyTable, daysBetween, fmtDate, fmtDateTime, money, monthStart, num, today, weekStart } from '../../lib/format';

export function usePeriod(initial = 'month') {
  const [kind, setKind] = useState(initial); const [from, setFrom] = useState(monthStart()); const [to, setTo] = useState(today());
  const apply = (k: string) => {
    setKind(k); const t = today(); const lastM = addDays(monthStart(t), -1); const q = Math.floor((Number(t.slice(5, 7)) - 1) / 3) * 3 + 1;
    const map: Record<string, [string, string]> = {
      today: [t, t], yesterday: [addDays(t, -1), addDays(t, -1)], week: [weekStart(t), t], lastweek: [addDays(weekStart(t), -7), addDays(weekStart(t), -1)],
      month: [monthStart(t), t], lastmonth: [monthStart(lastM), lastM], quarter: [`${t.slice(0, 4)}-${String(q).padStart(2, '0')}-01`, t], year: [`${t.slice(0, 4)}-01-01`, t],
    };
    if (map[k]) { setFrom(map[k][0]); setTo(map[k][1]); }
  };
  const ui = (
    <div className="col-span-2 grid grid-cols-2 gap-2 sm:col-span-1 sm:flex sm:flex-wrap sm:items-center">
      <Select className="col-span-2 sm:w-36" options={[['today', 'Hôm nay'], ['yesterday', 'Hôm qua'], ['week', 'Tuần này'], ['lastweek', 'Tuần trước'], ['month', 'Tháng này'], ['lastmonth', 'Tháng trước'], ['quarter', 'Quý này'], ['year', 'Năm nay'], ['custom', 'Tùy chọn']]} value={kind} onChange={apply} />
      <Input type="date" className="sm:w-40" value={from} onChange={e => { setFrom(e.target.value); setKind('custom'); }} /><span className="hidden text-xs text-ink-400 sm:inline">đến</span>
      <Input type="date" className="sm:w-40" value={to} onChange={e => { setTo(e.target.value); setKind('custom'); }} />
    </div>
  );
  return { from, to, ui };
}

const REPORTS: [string, string][] = [['tong_quan', 'Tổng quan kinh doanh'], ['kpi', 'KPI hoạt động'], ['can_cham', 'Khách cần chăm'], ['nhat_ky', 'Nhật ký chăm sóc'], ['bao_gia', 'Báo giá'],
  ['pheu', 'Phễu theo nhân viên'], ['giu_khach', 'Giữ khách và mua lại'], ['nguon', 'Nguồn và chân dung khách'], ['fb', 'Bài đăng Facebook'], ['nop_bc', 'Nộp báo cáo ngày'],
  ['ho_tro', 'Hỗ trợ và chỉ đạo'], ['trung', 'Trùng khách đang chạy'], ['chuyen', 'Lịch sử chuyển khách']];

const RICON: Record<string, string> = { tong_quan: '📊', kpi: '🎯', can_cham: '⏰', nhat_ky: '📞', bao_gia: '🧾', pheu: '🔻', giu_khach: '🔁', nguon: '🧭', fb: '📣', nop_bc: '📝', ho_tro: '🆘', trung: '⚠️', chuyen: '🔀' };
type Row = (string | number | React.ReactNode)[];
function Section({ title, head, rows, bar }: { title: string; head: string[]; rows: Row[]; bar?: number }) {
  const max = bar !== undefined ? Math.max(1, ...rows.map(r => Number(r[bar]) || 0)) : 1;
  const total = bar !== undefined ? rows.reduce((s, r) => s + (Number(r[bar]) || 0), 0) : 0;
  const plain = (v: any) => (typeof v === 'object' && v !== null ? (v.props?.['data-v'] ?? '') : v);
  return (
    <section className="mb-4 rounded-2xl border border-ink-200 bg-white shadow-soft">
      <header className="flex items-center justify-between gap-2 border-b border-ink-100 px-4 py-2.5">
        <h3 className="text-sm font-bold">{title} <span className="ml-1 text-xs font-normal text-ink-400">{rows.length} dòng</span></h3>
        <Button size="sm" className="shrink-0" onClick={() => copyTable([head, ...rows.map(r => r.map(plain))]).then(() => toast.ok('Đã sao chép — dán vào Google Sheet'))}>📋<span className="hidden sm:inline"> Sao chép sang Sheet</span></Button>
      </header>
      {!rows.length ? <Empty /> : <div className="max-h-[560px] overflow-auto"><table className="w-full text-sm">
        <thead className="sticky top-0 bg-white"><tr className="border-b border-ink-200 text-left text-xs text-ink-500">{head.map((h, i) => <th key={i} className={cx('whitespace-nowrap px-3 py-2 font-semibold', i > 0 ? 'text-right' : 'sticky left-0 z-[1] bg-white')}>{h}</th>)}{bar !== undefined && <th className="px-3 py-2 text-xs font-semibold text-ink-500">Tỷ trọng</th>}</tr></thead>
        <tbody className="divide-y divide-ink-100">{rows.map((r, i) => <tr key={i} className="hover:bg-ink-50/60">{r.map((c, j) => <td key={j} className={cx('px-3 py-1.5', j > 0 ? 'whitespace-nowrap text-right tabular-nums' : 'sticky left-0 min-w-[130px] bg-white font-medium')}>{c as any}</td>)}
          {bar !== undefined && <td className="w-[38%] min-w-[120px] px-3"><div className="flex items-center gap-2"><div className="h-2 flex-1 rounded-full bg-ink-100"><div className="h-2 rounded-full bg-brand-500" style={{ width: `${(Number(r[bar]) || 0) / max * 100}%` }} /></div><span className="w-10 text-right text-xs text-ink-500">{total ? Math.round((Number(r[bar]) || 0) / total * 100) : 0}%</span></div></td>}</tr>)}</tbody>
      </table></div>}
    </section>
  );
}
const Tiles = ({ items }: { items: [string, React.ReactNode, string?, string?][] }) => (
  <div className="mb-4 grid grid-cols-2 overflow-hidden rounded-2xl border border-ink-200 bg-white shadow-soft sm:grid-cols-3 lg:grid-cols-5">
    {items.map(([l, v, sub, tone], i) => <div key={i} className="border-b border-r border-ink-100 p-3"><div className="text-xs text-ink-500">{l}</div>
      <div className={cx('mt-0.5 text-2xl font-extrabold tabular-nums', tone === 'red' ? 'text-red-600' : tone === 'amber' ? 'text-amber-600' : tone === 'green' ? 'text-emerald-600' : '')}>{v}</div>{sub && <div className="text-[11px] text-ink-400">{sub}</div>}</div>)}
  </div>
);
const pct = (a: number, b: number) => (b ? Math.round(a / b * 1000) / 10 : 0) + '%';
const scoreBadge = (s: any) => <span data-v={s} className={cx('inline-block min-w-[2.5rem] rounded-md px-2 py-0.5 text-center font-bold', Number(s) >= 100 ? 'bg-emerald-100 text-emerald-800' : Number(s) >= 85 ? 'bg-sky-100 text-sky-800' : Number(s) >= 70 ? 'bg-amber-100 text-amber-800' : 'bg-red-100 text-red-700')}>{num(s, 1)}</span>;

export default function Reports() {
  const a = useApp(); const p = usePeriod(); const [rep, setRep] = useState('tong_quan'); const [unit, setUnit] = useState(''); const [sale, setSale] = useState('');
  const [data, setData] = useState<any>(null); const [loading, setLoading] = useState(false); const [err, setErr] = useState<string | null>(null);
  const t0 = new Date(p.from + 'T00:00:00+07:00').toISOString(); const t1 = new Date(addDays(p.to, 1) + 'T00:00:00+07:00').toISOString();
  const load = async () => {
    setLoading(true); setErr(null);
    try {
      const [kpi, customers, logs, quotes, reports, support, transfers, conflicts] = await Promise.all([
        db.rpc<any[]>('kpi_report', { p_from: p.from, p_to: p.to }),
        db.from('customers').select('id,code,contact_name,company_name,phone,owner_id,stage,temperature,next_care_date,source,customer_type,import_method,industry,care_count,quote_count,order_count,last_result,last_contact_at,created_at,first_order_at').is('deleted_at', null).limit(10000),
        db.from('care_logs').select('id,customer_id,sale_id,channel,purpose,result,is_connected,content,temperature_after,next_care_date,created_at').gte('created_at', t0).lt('created_at', t1).order('created_at', { asc: false }).limit(2000),
        db.from('quotations').select('id,code,version,status,sale_id,customer_id,total_after_vat,est_profit,created_at,sent_at,won_at,reject_reason').neq('status', 'da_thay_the').gte('created_at', t0).lt('created_at', t1).limit(5000),
        db.from('daily_reports').select('*').gte('report_date', p.from).lte('report_date', p.to).limit(5000),
        db.from('support_requests').select('*').gte('created_at', t0).lt('created_at', t1).limit(2000),
        db.rpc<any[]>('crm_report', { p_kind: 'transfers', p_from: p.from, p_to: p.to }),
        db.rpc<any[]>('company_conflicts').catch(() => []),
      ]);
      setData({ kpi, customers, logs, quotes, reports, support, transfers, conflicts });
    } catch (e: any) { setErr(e.message); } finally { setLoading(false); }
  };
  React.useEffect(() => { load(); }, []);
  const inScope = (id: string) => (!sale || id === sale) && (!unit || a.people.find(x => x.id === id)?.org_unit_id === unit);
  const v = useMemo(() => {
    if (!data) return null;
    const kpi = (data.kpi as any[]).filter(k => inScope(k.profile_id));
    const ids = new Set(kpi.map(k => k.profile_id));
    const own = (x: any) => ids.has(x.owner_id ?? x.sale_id);
    return { kpi, ids, customers: data.customers.filter(own), logs: data.logs.filter(own), quotes: data.quotes.filter(own), reports: data.reports.filter(own),
      support: data.support.filter((s: any) => ids.has(s.requester_id) || ids.has(s.assignee_id) || (!sale && !unit)), transfers: data.transfers, conflicts: data.conflicts };
  }, [data, unit, sale]);
  const name = a.personName; const t = today();
  const custName = (id: string) => { const c = data?.customers.find((x: any) => x.id === id); return c ? (c.company_name || c.contact_name) : ''; };
  const body = () => {
    if (!v) return null;
    const metrics = a.settings.kpi?.metrics || {}; const nf = a.settings.kpi?.new_hire_factor ?? 0.7;
    const created = v.customers.filter((c: any) => c.created_at >= t0 && c.created_at < t1);
    const sum = (k: string) => v.kpi.reduce((s: number, x: any) => s + (Number(x.metrics[k]) || 0), 0);
    const by = <T,>(arr: T[], key: (x: T) => string) => { const m = new Map<string, T[]>(); arr.forEach(x => { const k = key(x) || ''; m.set(k, [...(m.get(k) || []), x]); }); return Array.from(m.entries()); };
    switch (rep) {
      case 'tong_quan': {
        const sent = v.quotes.filter((q: any) => q.sent_at); const won = v.quotes.filter((q: any) => q.won_at);
        const firstOrders = v.customers.filter((c: any) => c.first_order_at && c.first_order_at >= t0 && c.first_order_at < t1).length;
        return <>
          <Tiles items={[['KH đang quản lý', v.customers.length], ['KH mới trong kỳ', created.length], ['Tiếp cận mới', sum('tiep_can')], ['Kết nối thành công', sum('ket_noi'), 'tỷ lệ ' + pct(sum('ket_noi'), v.logs.length)],
            ['Lượt chăm KH cũ', sum('cham_cu')], ['Báo giá đã gửi', sent.length], ['Đơn chốt', won.length, `${firstOrders} khách mới`], ['BG gửi → chốt', pct(won.length, sent.length)],
            ['KH quá hạn chăm', v.customers.filter((c: any) => c.next_care_date && c.next_care_date < t && c.stage !== 'khong_tiem_nang').length, undefined, 'red'], ['Kho khách ngủ', v.customers.filter((c: any) => c.stage === 'kho_ngu').length, undefined, 'amber']]} />
          <Section title="Phễu khách hàng theo giai đoạn" head={['Giai đoạn', 'Số KH']} bar={1} rows={a.opts('stage').map(([k, l]) => [l, v.customers.filter((c: any) => c.stage === k).length])} />
          <Section title={`Tổng hợp theo nhân viên (${v.kpi[0]?.metrics.days ?? 0} ngày làm việc)`} head={['Nhân viên', 'KH quản lý', 'Quá hạn', 'KH mới', 'Tiếp cận', 'Kết nối', 'Chăm cũ', 'BG gửi', 'Đơn chốt', 'Bài FB', 'Điểm KPI']}
            rows={v.kpi.map((k: any) => { const cs = v.customers.filter((c: any) => c.owner_id === k.profile_id); const m = k.metrics;
              return [k.full_name, cs.length, cs.filter((c: any) => c.next_care_date && c.next_care_date < t).length, m.kh_moi, m.tiep_can, m.ket_noi, m.cham_cu, m.bao_gia, m.don_chot, m.bai_fb, scoreBadge(k.score)]; })} />
        </>;
      }
      case 'kpi': {
        const keys = Object.keys(metrics); const avg = v.kpi.length ? v.kpi.reduce((s: number, k: any) => s + Number(k.score), 0) / v.kpi.length : 0;
        return <>
          <Tiles items={[['Ngày làm việc trong kỳ', v.kpi[0]?.metrics.days ?? 0], ['Nhân viên', v.kpi.length], ['Điểm trung bình', num(avg, 1)], ['Không đạt (<70)', v.kpi.filter((k: any) => Number(k.score) < 70).length, undefined, 'red']]} />
          <p className="mb-2 text-xs text-ink-500">Chỉ tiêu kỳ = chỉ tiêu ngày × số ngày làm việc (T2–T7, tính đến hôm nay) × hệ số KPI. Điểm = Σ min(thực tế/chỉ tiêu, 120%) × trọng số.</p>
          <Section title="Bảng KPI theo nhân viên" head={['Nhân viên', ...keys.map(k => `${metrics[k].label} (${metrics[k].weight}%)`), 'Cuộc gọi có nhật ký', 'Tin nhắn có nhật ký', 'KH Nóng/Ấm được chăm', 'Điểm', 'Xếp loại']}
            rows={v.kpi.map((k: any) => { const f = k.is_new ? nf : 1; const days = k.metrics.days;
              return [k.full_name + (k.is_new ? ' (mới)' : ''), ...keys.map(x => { const tg = Math.round(metrics[x].day * days * f); const val = k.metrics[x] ?? 0;
                return <span data-v={`${val}/${tg}`} className={val >= tg ? 'text-emerald-700' : 'text-red-600'}><b>{val}</b> / {tg}</span>; }),
                k.metrics.cuoc_goi_nhat_ky, k.metrics.tin_nhan_nhat_ky ?? 0, k.metrics.khach_nong_am, scoreBadge(k.score),
                <Badge data-v={k.grade} color={k.grade === 'Xuất sắc' ? 'green' : k.grade === 'Đạt' ? 'blue' : k.grade === 'Cần cải thiện' ? 'amber' : 'red'}>{k.grade}</Badge>]; })} />
          <Section title="Đối chiếu tự khai và hệ thống ghi nhận (phát hiện ghi chép thiếu)" head={['Nhân viên', 'Gọi có nhật ký', 'Gọi tự khai', 'Nhắn có nhật ký', 'Nhắn tự khai', 'Tỷ lệ ghi nhật ký', 'KH nhập hệ thống']}
            rows={v.kpi.map((k: any) => { const m = k.metrics; const self = (m.cuoc_goi_khai || 0) + (m.tin_nhan_khai || 0); const logged = (m.cuoc_goi_nhat_ky || 0) + (m.tin_nhan_nhat_ky || 0);
              return [k.full_name, m.cuoc_goi_nhat_ky, m.cuoc_goi_khai, m.tin_nhan_nhat_ky ?? 0, m.tin_nhan_khai, pct(logged, Math.max(self, logged)), m.kh_moi]; })} />
        </>;
      }
      case 'can_cham': {
        const t3 = addDays(t, 3);
        const due = v.customers.filter((c: any) => c.next_care_date && c.next_care_date <= t3 && !['khong_tiem_nang', 'mat_khach'].includes(c.stage)).sort((x: any, y: any) => x.next_care_date.localeCompare(y.next_care_date));
        const st = (d: string) => d < t ? 'Quá hạn' : d === t ? 'Hôm nay' : '3 ngày tới';
        return <>
          <Tiles items={[['Quá hạn', due.filter((c: any) => c.next_care_date < t).length, undefined, 'red'], ['Hôm nay', due.filter((c: any) => c.next_care_date === t).length, undefined, 'amber'], ['3 ngày tới', due.filter((c: any) => c.next_care_date > t).length]]} />
          <Section title="Theo nhân viên" head={['Nhân viên', 'Quá hạn', 'Hôm nay', '3 ngày tới', 'Quá hạn lâu nhất (ngày)']} rows={v.kpi.map((k: any) => { const cs = due.filter((c: any) => c.owner_id === k.profile_id);
            const od = cs.filter((c: any) => c.next_care_date < t); return [k.full_name, od.length, cs.filter((c: any) => c.next_care_date === t).length, cs.filter((c: any) => c.next_care_date > t).length, od.length ? Math.max(...od.map((c: any) => daysBetween(c.next_care_date, t))) : 0]; })} />
          <Section title="Danh sách" head={['Hẹn chăm', 'Cảnh báo', 'Mã KH', 'Khách hàng', 'SĐT', 'Giai đoạn', 'Mức độ', 'Kết quả gần nhất', 'Sale']}
            rows={due.map((c: any) => [c.next_care_date, <Badge data-v={st(c.next_care_date)} color={c.next_care_date < t ? 'solidred' : c.next_care_date === t ? 'solidamber' : 'gray'}>{st(c.next_care_date)}</Badge>,
              <a data-v={c.code} className="text-brand-700" href={`#/crm/customer?id=${c.id}`}>{c.code}</a>, c.company_name || c.contact_name, c.phone, a.label('stage', c.stage), a.label('temperature', c.temperature), a.label('care_result', c.last_result), name(c.owner_id)])} />
        </>;
      }
      case 'nhat_ky': return <>
        <Tiles items={[['Tổng lượt chăm', v.logs.length], ['Kết nối được', v.logs.filter((l: any) => l.is_connected).length, pct(v.logs.filter((l: any) => l.is_connected).length, v.logs.length)],
          ['KH được chăm', new Set(v.logs.map((l: any) => l.customer_id)).size], ['Lượt KH Nóng', v.logs.filter((l: any) => l.temperature_after === 'nong').length]]} />
        <Section title="Theo kênh" head={['Kênh', 'Lượt', 'Kết nối', 'Tỷ lệ']} rows={by(v.logs, (l: any) => l.channel).map(([k, ls]) => [a.label('channel', k), ls.length, ls.filter((l: any) => l.is_connected).length, pct(ls.filter((l: any) => l.is_connected).length, ls.length)])} />
        <Section title="Theo kết quả" head={['Kết quả', 'Lượt']} bar={1} rows={by(v.logs, (l: any) => l.result).sort((x, y) => y[1].length - x[1].length).map(([k, ls]) => [a.label('care_result', k), ls.length])} />
        <Section title="Chi tiết (tối đa 2.000 dòng mới nhất)" head={['Thời gian', 'Người chăm', 'Khách hàng', 'Kênh', 'Mục đích', 'Kết quả', 'Mức độ', 'Nội dung', 'Hẹn tiếp']}
          rows={v.logs.map((l: any) => [fmtDateTime(l.created_at), name(l.sale_id), custName(l.customer_id), a.label('channel', l.channel), a.label('care_purpose', l.purpose), a.label('care_result', l.result), a.label('temperature', l.temperature_after), <span data-v={l.content} className="block max-w-md truncate text-left">{l.content}</span>, l.next_care_date])} />
      </>;
      case 'bao_gia': {
        const ST: Record<string, string> = { nhap: 'Nháp', cho_duyet: 'Chờ duyệt', da_gui: 'Đã gửi', can_nhac: 'Cân nhắc', da_chot: 'Đã chốt', tu_choi: 'Từ chối', het_han: 'Hết hạn' };
        return <>
          <Tiles items={[['Báo giá tạo', v.quotes.length], ['Đã gửi', v.quotes.filter((q: any) => q.sent_at).length], ['Đã chốt', v.quotes.filter((q: any) => q.status === 'da_chot').length, undefined, 'green'],
            ['Giá trị chốt', money(v.quotes.filter((q: any) => q.status === 'da_chot').reduce((s: number, q: any) => s + Number(q.total_after_vat), 0))], ['LN ước tính chốt', money(v.quotes.filter((q: any) => q.status === 'da_chot').reduce((s: number, q: any) => s + Number(q.est_profit), 0)), undefined, 'green']]} />
          <Section title="Theo nhân viên" head={['Nhân viên', ...Object.values(ST), 'Tỷ lệ chốt']} rows={v.kpi.map((k: any) => { const qs = v.quotes.filter((q: any) => q.sale_id === k.profile_id);
            return [k.full_name, ...Object.keys(ST).map(s => qs.filter((q: any) => q.status === s).length), pct(qs.filter((q: any) => q.status === 'da_chot').length, qs.filter((q: any) => q.sent_at).length)]; })} />
          <Section title="Lý do từ chối" head={['Lý do', 'Số BG']} bar={1} rows={by(v.quotes.filter((q: any) => q.status === 'tu_choi'), (q: any) => q.reject_reason).map(([k, qs]) => [a.label('reject_reason', k), qs.length])} />
        </>;
      }
      case 'pheu': return <Section title="Số khách theo giai đoạn × nhân viên" head={['Nhân viên', ...a.opts('stage').map(s => s[1]), 'Tổng']}
        rows={v.kpi.map((k: any) => { const cs = v.customers.filter((c: any) => c.owner_id === k.profile_id); return [k.full_name, ...a.opts('stage').map(([s]) => cs.filter((c: any) => c.stage === s).length), cs.length]; })} />;
      case 'giu_khach': {
        const buyers = v.customers.filter((c: any) => c.order_count >= 1); const rep2 = buyers.filter((c: any) => c.order_count >= 2);
        return <>
          <Tiles items={[['Khách đã mua', buyers.length], ['Mua lại (≥ 2 đơn)', rep2.length], ['Tỷ lệ mua lại', pct(rep2.length, buyers.length), 'mục tiêu > 80%', rep2.length / Math.max(1, buyers.length) >= .8 ? 'green' : 'red'],
            ['Kho khách ngủ', v.customers.filter((c: any) => c.stage === 'kho_ngu').length, undefined, 'amber'], ['Mất khách', v.customers.filter((c: any) => c.stage === 'mat_khach').length, undefined, 'red']]} />
          <Section title="Theo nhân viên" head={['Nhân viên', 'Khách đã mua', 'Mua lại', 'Tỷ lệ mua lại', 'VIP', 'Kho khách ngủ', 'Mất khách']} rows={v.kpi.map((k: any) => { const cs = v.customers.filter((c: any) => c.owner_id === k.profile_id);
            const b = cs.filter((c: any) => c.order_count >= 1); const r2 = b.filter((c: any) => c.order_count >= 2);
            return [k.full_name, b.length, r2.length, pct(r2.length, b.length), cs.filter((c: any) => c.stage === 'vip').length, cs.filter((c: any) => c.stage === 'kho_ngu').length, cs.filter((c: any) => c.stage === 'mat_khach').length]; })} />
        </>;
      }
      case 'nguon': {
        const dim = (title: string, key: string, cat: string) => <Section key={key} title={title} head={[title.replace('Theo ', ''), 'KH mới', 'Đã tiếp cận', 'Có báo giá', 'Có đơn', 'Tỷ lệ ra đơn']}
          rows={by(created, (c: any) => c[key]).sort((x, y) => y[1].length - x[1].length).map(([k, cs]) => [k ? a.label(cat, k) : '(trống)', cs.length, cs.filter((c: any) => c.care_count > 0).length, cs.filter((c: any) => c.quote_count > 0).length, cs.filter((c: any) => c.order_count > 0).length, pct(cs.filter((c: any) => c.order_count > 0).length, cs.length)])} />;
        return <>
          <Tiles items={[['KH tạo trong kỳ', created.length], ['Đã có đơn', created.filter((c: any) => c.order_count > 0).length, undefined, 'green']]} />
          {dim('Theo nguồn', 'source', 'source')}{dim('Theo loại khách', 'customer_type', 'customer_type')}{dim('Theo hình thức nhập khẩu', 'import_method', 'import_method')}{dim('Theo ngành hàng', 'industry', 'industry')}
        </>;
      }
      case 'fb': return <Section title="Bài đăng Facebook chính ngạch" head={['Nhân viên', 'Ngày có báo cáo', 'Bài đã đăng', 'Đạt', 'Không đạt', 'Chờ duyệt', 'Chỉ tiêu kỳ']}
        rows={v.kpi.map((k: any) => { const rs = v.reports.filter((r: any) => r.sale_id === k.profile_id); const c = (f: (r: any) => boolean) => rs.filter(f).reduce((s: number, r: any) => s + (r.fb_links?.length || 0), 0);
          return [k.full_name, rs.length, c(() => true), c(r => r.fb_status === 'dat'), c(r => r.fb_status === 'khong_dat'), c(r => !r.fb_status), Math.round((metrics.bai_fb?.day ?? 2) * k.metrics.days)]; })} />;
      case 'nop_bc': return <Section title="Nộp báo cáo ngày" head={['Nhân viên', 'Ngày làm việc', 'Đã nộp', 'Đúng hạn', 'Trễ', 'Chưa nộp', 'Đã được nhận xét']}
        rows={v.kpi.map((k: any) => { const rs = v.reports.filter((r: any) => r.sale_id === k.profile_id); return [k.full_name, k.metrics.days, rs.length, rs.filter((r: any) => r.on_time).length, rs.filter((r: any) => !r.on_time).length, Math.max(0, k.metrics.days - rs.length), rs.filter((r: any) => r.reviewed_by).length]; })} />;
      case 'ho_tro': return <>
        <Tiles items={[['Chỉ đạo', v.support.filter((s: any) => s.kind === 'chi_dao').length], ['Nhờ hỗ trợ', v.support.filter((s: any) => s.kind === 'nho_ho_tro').length], ['Hỗ trợ khác', v.support.filter((s: any) => s.kind === 'ho_tro').length],
          ['Đang mở', v.support.filter((s: any) => ['moi', 'da_nhan', 'dang_xu_ly'].includes(s.status)).length, undefined, 'amber'], ['Đã xong', v.support.filter((s: any) => ['xong', 'dong'].includes(s.status)).length, undefined, 'green']]} />
        <Section title="Chi tiết" head={['Thời gian', 'Loại', 'Người gửi', 'Người nhận', 'Khách', 'Nội dung', 'Trạng thái', 'Kết quả']}
          rows={v.support.map((s: any) => [fmtDateTime(s.created_at), s.kind === 'chi_dao' ? 'Chỉ đạo' : s.kind === 'nho_ho_tro' ? 'Nhờ hỗ trợ' : 'Hỗ trợ', name(s.requester_id), name(s.assignee_id), custName(s.customer_id),
            <a data-v={s.title} className="text-brand-700" href={`#/support?id=${s.id}`}>{s.title}</a>, s.status, s.response || ''])} />
      </>;
      case 'trung': return <Section title="Khách trong CRM trùng danh sách khách đang chạy của công ty" head={['Mã KH', 'Khách trong CRM', 'Sale đang giữ', 'Khách công ty', 'Phụ trách (công ty)', 'Đơn gần nhất', 'Trạng thái']}
        rows={(v.conflicts as any[]).map(c => [c.code, c.customer, c.owner_name, c.company_name, c.company_owner, c.last_order_date, c.status === 'active' ? 'Đang chạy (khóa)' : 'Đã ngủ'])} />;
      case 'chuyen': return <Section title="Lịch sử chuyển khách" head={['Thời gian', 'Mã KH', 'Khách', 'Từ', 'Sang', 'Lý do', 'Ghi chú', 'Người chuyển']}
        rows={(v.transfers as any[]).map(x => [x.at, x.code, x.customer, x.from_sale, x.to_sale, a.label('transfer_reason', x.reason), x.note, x.by])} />;
    }
    return null;
  };
  return (
    <Layout title="Báo cáo và KPI">
      <div className="grid gap-4 lg:grid-cols-[236px_minmax(0,1fr)]">
        <nav className="-mx-1 flex gap-1.5 overflow-x-auto px-1 pb-1 [scrollbar-width:none] lg:mx-0 lg:block lg:space-y-0.5 lg:self-start lg:rounded-2xl lg:border lg:border-ink-200 lg:bg-white lg:p-2 lg:shadow-soft lg:sticky lg:top-16">
          {REPORTS.map(([k, l]) => <button key={k} onClick={() => setRep(k)} className={cx('flex shrink-0 items-center gap-2 whitespace-nowrap rounded-full border px-3 py-1.5 text-left text-[13px] lg:w-full lg:rounded-xl lg:border-0 lg:py-2',
            rep === k ? 'border-brand-600 bg-brand-600 font-bold text-white lg:bg-brand-50 lg:text-brand-700' : 'border-ink-200 bg-white text-ink-700 hover:bg-ink-50')}><span>{RICON[k]}</span>{l}</button>)}
        </nav>
        <div className="min-w-0">
          <div className="mb-3 grid grid-cols-2 gap-2 rounded-2xl border border-ink-200 bg-white p-2.5 shadow-soft sm:flex sm:flex-wrap sm:items-center">{p.ui}
            {a.isLead && <Select className="sm:w-40" options={a.units.filter(u => u.kind !== 'cong_ty').map(u => [u.id, u.name])} value={unit} onChange={setUnit} placeholder="Mọi nhóm" />}
            {a.isLead && <Select className="sm:w-44" options={((data?.kpi as any[]) || []).map(k => [k.profile_id, k.full_name])} value={sale} onChange={setSale} placeholder="Mọi nhân viên" />}
            <Button variant="primary" className="col-span-2 sm:ml-auto" loading={loading} onClick={load}>Xem báo cáo</Button>
          </div>
          <div className="mb-3 flex flex-wrap items-baseline justify-between gap-x-3"><h2 className="text-xl font-extrabold">{RICON[rep]} {REPORTS.find(r => r[0] === rep)?.[1]}</h2>
            <p className="text-xs text-ink-500">Kỳ {fmtDate(p.from)} → {fmtDate(p.to)}</p></div>
          <ErrorBox error={err} />
          {loading && !data ? <Loading /> : body()}
        </div>
      </div>
    </Layout>
  );
}
