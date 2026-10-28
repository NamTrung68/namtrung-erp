import React from 'react';
import { Layout } from '../components/Layout';
import { Card, Stat, Loading, ErrorBox, useLoad, Badge, Button } from '../components/ui';
import { db } from '../lib/sb';
import { useApp, go } from '../state';
import { fmtDate, num } from '../lib/format';

export default function Dashboard() {
  const a = useApp();
  const { data: d, loading, error } = useLoad(() => db.rpc<any>('dashboard'), []);
  const { data: due } = useLoad(() => a.isSales
    ? db.from('customers').select('id,code,contact_name,company_name,next_care_date,stage,temperature').eq('owner_id', a.me.id)
        .lte('next_care_date', new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Ho_Chi_Minh' })).neq('stage', 'khong_tiem_nang').order('next_care_date').limit(12)
    : Promise.resolve([]), []);
  return (
    <Layout title={`Xin chào, ${a.me.full_name}`}>
      <ErrorBox error={error} />
      {loading || !d ? <Loading /> : (
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-6">
            <Stat label="Chấm công hôm nay" value={d.my_checkin || '—'} sub={d.my_checkout ? `Ra ${d.my_checkout}` : a.me.work_schedule === 'office' ? 'Chưa chấm ra' : 'Không cần chấm'} onClick={() => go('/hr/attendance')} />
            <Stat label="Phép năm còn" value={num(d.leave?.available, 1)} sub={`Đã dùng năm nay ${num(d.leave?.used_year, 1)}`} onClick={() => go('/hr/leave')} />
            {a.isSales && <Stat label="Khách quá hạn chăm" value={d.care_overdue} tone={d.care_overdue ? 'red' : undefined} sub={`Hôm nay: ${d.care_today}`} onClick={() => go('/crm/customers?due=1')} />}
            {a.isSales && <Stat label="Báo giá đang mở" value={d.my_quotes_open} onClick={() => go('/crm/quotes')} />}
            {(a.isLead || a.has('hcns')) && <Stat label="Đơn chờ tôi duyệt" value={d.approvals_pending} tone={d.approvals_pending ? 'amber' : undefined} onClick={() => go('/hr/approvals')} />}
            {(a.isAdmin || a.has('tp_kd')) && <Stat label="Báo giá chờ duyệt giá" value={d.quotes_pending_me} tone={d.quotes_pending_me ? 'amber' : undefined} onClick={() => go('/crm/quotes?status=cho_duyet')} />}
            {a.isLead && <Stat label="Khách quá hạn của đội" value={d.team_overdue} onClick={() => go('/crm/customers?due=1&scope=team')} />}
            <Stat label="Hỗ trợ đang mở" value={d.support_open} onClick={() => go('/support')} />
          </div>
          {a.isSales && !d.report_today && <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
            Bạn chưa nộp báo cáo ngày hôm nay (hạn 18:00). <Button size="sm" onClick={() => go('/crm/daily')}>Nộp báo cáo</Button></div>}
          <div className="grid gap-4 lg:grid-cols-3">
            {a.isSales && <Card title="Cần chăm hôm nay" className="lg:col-span-2" actions={<Button size="sm" onClick={() => go('/crm/customers?due=1')}>Xem tất cả</Button>} bodyClass="p-0">
              {(due || []).length === 0 ? <div className="p-6 text-sm text-ink-400">Không có khách đến hạn 🎉</div> :
                <ul className="divide-y divide-ink-100">{(due as any[]).map(c => (
                  <li key={c.id}><a href={`#/crm/customer?id=${c.id}`} className="flex items-center justify-between gap-2 px-4 py-2.5 hover:bg-ink-50">
                    <span className="min-w-0"><span className="block truncate text-sm font-medium">{c.company_name || c.contact_name}</span>
                      <span className="text-xs text-ink-400">{c.code} · {a.label('stage', c.stage)}</span></span>
                    <Badge color={c.next_care_date < d.today ? 'solidred' : 'solidamber'}>{c.next_care_date < d.today ? `Quá ${Math.round((Date.parse(d.today) - Date.parse(c.next_care_date)) / 864e5)} ngày` : 'Hôm nay'}</Badge>
                  </a></li>))}</ul>}
            </Card>}
            <Card title="Hôm nay ai nghỉ" bodyClass="p-0">
              {d.off_today.length === 0 ? <div className="p-6 text-sm text-ink-400">Không ai nghỉ</div> :
                <ul className="divide-y divide-ink-100">{d.off_today.map((o: any, i: number) => <li key={i} className="px-4 py-2 text-sm">{o.name} <span className="text-ink-400">{o.part === 'am' ? '(sáng)' : o.part === 'pm' ? '(chiều)' : ''}</span></li>)}</ul>}
            </Card>
            <Card title="Bảng tin" className={a.isSales ? 'lg:col-span-3' : 'lg:col-span-2'} actions={<Button size="sm" onClick={() => go('/news')}>Tất cả</Button>} bodyClass="p-0">
              {d.news.length === 0 ? <div className="p-6 text-sm text-ink-400">Chưa có thông báo</div> :
                <ul className="divide-y divide-ink-100">{d.news.map((n: any) => <li key={n.id}><a href={`#/news?id=${n.id}`} className="flex items-center justify-between gap-2 px-4 py-2.5 hover:bg-ink-50">
                  <span className={n.is_read ? 'text-sm text-ink-600' : 'text-sm font-semibold'}>{n.pinned && '📌 '}{n.title}</span><span className="text-xs text-ink-400">{fmtDate(n.publish_at)}</span></a></li>)}</ul>}
            </Card>
          </div>
        </div>
      )}
    </Layout>
  );
}
