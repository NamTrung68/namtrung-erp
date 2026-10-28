import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Button, cx, Empty, Input, Loading, Select, Table, Td, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { fmtDate, money } from '../../lib/format';
import { QUOTE_STATUS, QuoteStatus } from './Customers';

export default function Quotes() {
  const a = useApp(); const { query } = useRoute();
  const [status, setStatus] = useState(query.status || ''); const [q, setQ] = useState(''); const [sale, setSale] = useState('');
  const { data: cnt } = useLoad(() => db.from('quotations').select('status,sale_id').neq('status', 'da_thay_the').limit(10000), []);
  const counts: Record<string, number> = { all: 0 };
  ((cnt as any[]) || []).filter(r => !sale || r.sale_id === sale).forEach(r => { counts[r.status] = (counts[r.status] || 0) + 1; counts.all++; });
  const { data, loading } = useLoad(async () => {
    let qq = db.from('quotations').select('id,code,version,status,total_after_vat,est_profit,created_at,sent_at,valid_until,order_code,sale_id,violations,customers(code,contact_name,company_name)')
      .neq('status', 'da_thay_the').order('created_at', { asc: false }).limit(300);
    if (status) qq = qq.eq('status', status);
    if (sale) qq = qq.eq('sale_id', sale);
    if (q.trim()) qq = qq.ilike('code', q.trim());
    return qq;
  }, [status, q, sale]);
  return (
    <Layout title="Báo giá" actions={<Button variant="dark" onClick={() => go('/crm/quote')}>Tạo báo giá</Button>}>
      <div className="mb-3 flex gap-1.5 overflow-x-auto pb-1 [scrollbar-width:none]">
        {[['', 'Tất cả'], ...Object.entries(QUOTE_STATUS).filter(([k]) => k !== 'da_thay_the').map(([k, v]) => [k, v[0]])].map(([k, l]) =>
          <button key={k} onClick={() => setStatus(k)} className={cx('shrink-0 rounded-full border px-3 py-1.5 text-sm font-semibold', status === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white', k && !counts[k] && status !== k && 'opacity-50')}>{l} <span className="opacity-60">{k ? counts[k] || 0 : counts.all || 0}</span></button>)}
      </div>
      <div className="mb-3 grid grid-cols-2 gap-2 md:grid-cols-4">
        <Input placeholder="Tìm mã báo giá…" value={q} onChange={e => setQ(e.target.value)} />
        {a.isLead && <Select options={a.people.map(p => [p.id, p.full_name])} value={sale} onChange={setSale} placeholder="Mọi nhân viên" />}
      </div>
      <div className="rounded-2xl border border-ink-200 bg-white shadow-soft">
        {loading ? <Loading /> : !(data as any[])?.length ? <Empty>Chưa có báo giá</Empty> :
          <Table head={['Mã', 'Khách hàng', 'Ngày', 'Trạng thái', 'Tổng sau VAT', 'LN ước tính', 'Hiệu lực', 'Mã đơn', 'Sale']}>
            {(data as any[]).map(r => (
              <tr key={r.id} className="cursor-pointer hover:bg-ink-50" onClick={() => go(`/crm/quote?id=${r.id}`)}>
                <Td className="whitespace-nowrap font-medium">{r.code}{r.version > 1 && <span className="text-ink-400"> v{r.version}</span>}</Td>
                <Td>{r.customers?.company_name || r.customers?.contact_name}<div className="text-xs text-ink-400">{r.customers?.code}</div></Td>
                <Td className="whitespace-nowrap">{fmtDate(r.created_at)}</Td>
                <Td><QuoteStatus s={r.status} />{r.violations?.length > 0 && r.status === 'nhap' && <div className="text-[11px] text-amber-700">Phá khung</div>}</Td>
                <Td className="text-right tabular-nums">{money(r.total_after_vat)}</Td>
                <Td className="text-right tabular-nums text-emerald-700">{money(r.est_profit)}</Td>
                <Td className="whitespace-nowrap">{fmtDate(r.valid_until)}</Td><Td>{r.order_code}</Td><Td className="whitespace-nowrap text-xs">{a.personName(r.sale_id)}</Td>
              </tr>))}
          </Table>}
      </div>
    </Layout>
  );
}
