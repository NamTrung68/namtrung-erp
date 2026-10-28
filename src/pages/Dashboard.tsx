import React, { useState } from 'react';
import { Layout } from '../components/Layout';
import { Stat, Loading, ErrorBox, useLoad, Button, cx, Empty } from '../components/ui';
import { db } from '../lib/sb';
import { useApp, go } from '../state';
import { fmtDate, money, num, today } from '../lib/format';
import { KpiStrip } from '../components/KpiStrip';
import { CareModal } from '../components/CrmModals';
import { CUSTOMER_COLS, CustomerTable, QuoteStatus, STAGE_BAR } from './crm/Customers';

export default function Dashboard() {
  const a = useApp();
  const [scope, setScope] = useState<'team' | 'me'>(a.isLead ? 'team' : 'me');
  const { data: d, loading, error } = useLoad(() => db.rpc<any>('dashboard'), []);
  const { data: kpi } = useLoad(() => a.isSales || a.isLead ? db.rpc<any[]>('kpi_report', { p_from: today(), p_to: today() }) : Promise.resolve([]), []);
  const kpiRows = ((kpi as any[]) || []).filter(r => scope === 'team' || r.profile_id === a.me.id);
  const { data: due, reload: reloadDue } = useLoad(() => {
    if (!a.isSales && !a.isLead) return Promise.resolve([]);
    let q = db.from('customers').select(CUSTOMER_COLS).is('deleted_at', null).lte('next_care_date', today()).neq('stage', 'khong_tiem_nang').order('next_care_date').limit(60);
    if (scope === 'me') q = q.eq('owner_id', a.me.id);
    return q;
  }, [scope]);
  const { data: funnel } = useLoad(() => db.rpc<any[]>('customer_stage_counts', { p_owner: scope === 'me' ? a.me.id : null }), [scope]);
  const { data: hot } = useLoad(() => { let q = db.from('customers').select('id').is('deleted_at', null).eq('temperature', 'nong').limit(2000); if (scope === 'me') q = q.eq('owner_id', a.me.id); return q; }, [scope]);
  const { data: waiting } = useLoad(() => { let q = db.from('quotations').select('id,code,status,total_after_vat,sent_at,customers(contact_name,company_name)').in('status', ['da_gui', 'can_nhac']).order('sent_at', { asc: false }).limit(12); if (scope === 'me') q = q.eq('sale_id', a.me.id); return q; }, [scope]);
  const [careFor, setCareFor] = useState<any>(null);
  const dueRows = (due as any[]) || [];
  const overdue = dueRows.filter(c => c.next_care_date < today()).length;
  const fmap = new Map(((funnel as any[]) || []).map(r => [r.stage, Number(r.n)]));
  const ftotal = Array.from(fmap.values()).reduce((x, y) => x + y, 0);
  const fmax = Math.max(1, ...Array.from(fmap.values()));
  const sales = a.isSales || a.isLead;
  return (
    <Layout title="Bảng điều khiển" actions={a.isLead && <div className="inline-flex rounded-full bg-ink-100 p-1 text-xs font-semibold">
      {([['team', 'Cả đội'], ['me', 'Của tôi']] as const).map(([k, l]) => <button key={k} onClick={() => setScope(k)} className={cx('rounded-full px-3 py-1', scope === k ? 'bg-white shadow-sm' : 'text-ink-500')}>{l}</button>)}</div>}>
      <ErrorBox error={error} />
      {loading || !d ? <Loading /> : (
        <div className="space-y-4">
          {sales && <KpiStrip rows={kpiRows} />}
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-6">
            <Stat label="Chấm công hôm nay" value={d.my_checkin || '—'} sub={d.my_checkout ? `Ra ${d.my_checkout}` : a.me.work_schedule === 'office' ? 'Chưa chấm ra' : 'Không cần chấm'} onClick={() => go('/hr/attendance')} />
            <Stat label="Phép năm còn" value={num(d.leave?.available, 1)} sub="ngày" onClick={() => go('/hr/leave')} />
            {a.isSales && <Stat label="Báo giá đang mở" value={d.my_quotes_open} onClick={() => go('/crm/quotes')} />}
            {(a.isLead || a.has('hcns')) && <Stat label="Đơn chờ tôi duyệt" value={d.approvals_pending} tone={d.approvals_pending ? 'amber' : undefined} onClick={() => go('/hr/approvals')} />}
            {(a.isAdmin || a.has('tp_kd')) && <Stat label="Báo giá chờ duyệt giá" value={d.quotes_pending_me} tone={d.quotes_pending_me ? 'amber' : undefined} onClick={() => go('/crm/quotes?status=cho_duyet')} />}
            <Stat label="Hỗ trợ đang mở" value={d.support_open} onClick={() => go('/support')} />
          </div>
          {a.isSales && !d.report_today && <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
            Bạn chưa nộp báo cáo ngày hôm nay (hạn 18:00). <Button size="sm" onClick={() => go('/crm/daily')}>Nộp báo cáo</Button></div>}
          <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_380px]">
            {sales && <section className="min-w-0 rounded-2xl border border-ink-200 bg-white shadow-soft">
              <div className="flex flex-wrap items-center justify-between gap-2 border-b border-ink-100 px-4 py-3">
                <div><b>Cần chăm hôm nay</b> <span className="ml-1 text-xs text-ink-500"><b className="text-red-600">{overdue}</b> quá hạn, <b className="text-amber-600">{dueRows.length - overdue}</b> đến hạn</span></div>
                <Button size="sm" onClick={() => go('/crm/customers?due=1')}>Toàn bộ khách hàng</Button>
              </div>
              {dueRows.length === 0 ? <Empty>Không có khách đến hạn 🎉</Empty> :
                <CustomerTable compact rows={dueRows} onOpen={id => go(`/crm/customer?id=${id}`)} onCare={async (e, id) => { e.stopPropagation(); setCareFor(await db.from('customers').select('*').eq('id', id).maybeSingle()); }} />}
            </section>}
            <div className={cx('space-y-4', !sales && 'xl:col-span-2')}>
              {sales && <section className="rounded-2xl border border-ink-200 bg-white shadow-soft">
                <div className="border-b border-ink-100 px-4 py-3"><b>Phễu khách hàng</b> <span className="ml-1 text-xs text-ink-500">{ftotal} khách, {((hot as any[]) || []).length} khách nóng</span></div>
                <div className="space-y-1.5 px-4 py-3">{a.opts('stage').filter(([k]) => k !== 'khong_tiem_nang').map(([k, l]) => (
                  <button key={k} onClick={() => go(`/crm/customers`)} className="grid w-full grid-cols-[150px_1fr_28px] items-center gap-2 text-left text-xs">
                    <span className="truncate text-ink-600">{l}</span>
                    <span className="h-3 rounded-full bg-ink-100"><span className={cx('block h-3 rounded-full', STAGE_BAR[k])} style={{ width: `${((fmap.get(k) || 0) / fmax) * 100}%` }} /></span>
                    <b className="text-right tabular-nums">{fmap.get(k) || 0}</b></button>))}</div>
              </section>}
              {sales && <section className="rounded-2xl border border-ink-200 bg-white shadow-soft">
                <div className="border-b border-ink-100 px-4 py-3"><b>Báo giá chờ phản hồi</b> <span className="ml-1 text-xs text-ink-500">{((waiting as any[]) || []).length}</span></div>
                {!((waiting as any[]) || []).length ? <Empty>Không có báo giá đang chờ</Empty> :
                  <ul className="divide-y divide-ink-100">{(waiting as any[]).map(q => <li key={q.id}><a href={`#/crm/quote?id=${q.id}`} className="grid grid-cols-[1fr_auto] gap-x-2 px-4 py-2 text-sm hover:bg-ink-50">
                    <span className="truncate"><b>{q.code}</b> · {q.customers?.company_name || q.customers?.contact_name}</span><b className="text-right tabular-nums">{money(q.total_after_vat)}</b>
                    <span className="text-xs text-ink-400">gửi {fmtDate(q.sent_at)}</span><span className="text-right"><QuoteStatus s={q.status} /></span></a></li>)}</ul>}
              </section>}
              <section className="rounded-2xl border border-ink-200 bg-white shadow-soft">
                <div className="flex items-center justify-between border-b border-ink-100 px-4 py-3"><b>Bảng tin</b><Button size="sm" onClick={() => go('/news')}>Tất cả</Button></div>
                {d.news.length === 0 ? <Empty>Chưa có thông báo</Empty> :
                  <ul className="divide-y divide-ink-100">{d.news.slice(0, 6).map((n: any) => <li key={n.id}><a href={`#/news?id=${n.id}`} className="flex items-center justify-between gap-2 px-4 py-2.5 hover:bg-ink-50">
                    <span className={n.is_read ? 'text-sm text-ink-600' : 'text-sm font-semibold'}>{n.pinned && '📌 '}{n.title}</span><span className="shrink-0 text-xs text-ink-400">{fmtDate(n.publish_at)}</span></a></li>)}</ul>}
              </section>
            </div>
          </div>
        </div>
      )}
      {careFor && <CareModal open customer={careFor} onClose={() => setCareFor(null)} onSaved={() => { setCareFor(null); reloadDue(); }} />}
    </Layout>
  );
}
