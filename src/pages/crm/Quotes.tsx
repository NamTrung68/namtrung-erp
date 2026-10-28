import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Button, Empty, Input, Loading, Select, Table, Td, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { fmtDate, money } from '../../lib/format';
import { QUOTE_STATUS, QuoteStatus } from './Customers';

export default function Quotes() {
  const a = useApp(); const { query } = useRoute();
  const [status, setStatus] = useState(query.status || ''); const [q, setQ] = useState(''); const [sale, setSale] = useState('');
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
      <div className="mb-3 grid grid-cols-2 gap-2 md:grid-cols-4">
        <Input placeholder="Tìm mã báo giá…" value={q} onChange={e => setQ(e.target.value)} />
        <Select options={Object.entries(QUOTE_STATUS).map(([k, v]) => [k, v[0]])} value={status} onChange={setStatus} placeholder="Mọi trạng thái" />
        {a.isLead && <Select options={a.people.map(p => [p.id, p.full_name])} value={sale} onChange={setSale} placeholder="Mọi nhân viên" />}
      </div>
      <div className="rounded-xl border border-ink-200 bg-white">
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
