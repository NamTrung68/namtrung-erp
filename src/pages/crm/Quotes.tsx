import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Button, Empty, Input, Loading, Select, StatusChips, Table, Td, toast, useLoad } from '../../components/ui';
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
    let qq = db.from('quotations').select('id,code,version,status,total_after_vat,est_profit,created_at,sent_at,valid_until,order_code,sale_id,violations,ma_don:header->>maDonHeThong,customers(code,contact_name,company_name)')
      .neq('status', 'da_thay_the').order('created_at', { asc: false }).limit(300);
    if (status) qq = qq.eq('status', status);
    if (sale) qq = qq.eq('sale_id', sale);
    if (q.trim()) qq = qq.ilike('code', q.trim());
    return qq;
  }, [status, q, sale]);
  const clone = async (id: string) => { try { const nid = await db.rpc('quote_clone', { p_id: id }); toast.ok('Đã nhân bản'); go(`/crm/quote?id=${nid}`); } catch (e) { toast.err(e); } };
  return (
    <Layout title="Báo giá" actions={<Button variant="dark" onClick={() => go('/crm/quote')}>Tạo báo giá</Button>}>
      <StatusChips value={status} onChange={setStatus} items={[['', 'Tất cả', counts.all || 0, 'dark'],
        ...Object.entries(QUOTE_STATUS).filter(([k]) => k !== 'da_thay_the').map(([k, v]) => [k, v[0], counts[k] || 0, v[1]] as [string, string, number, string])]} />
      <div className="mb-3 grid grid-cols-2 gap-2 md:grid-cols-4">
        <Input placeholder="Tìm mã báo giá…" value={q} onChange={e => setQ(e.target.value)} />
        {a.isLead && <Select options={a.people.map(p => [p.id, p.full_name])} value={sale} onChange={setSale} placeholder="Mọi nhân viên" />}
      </div>
      <div className="rounded-2xl border border-ink-200 bg-white shadow-soft">
        {loading ? <Loading /> : !(data as any[])?.length ? <Empty>Chưa có báo giá</Empty> :
          <><ul className="divide-y divide-ink-100 md:hidden">{(data as any[]).map(r => (
            <li key={r.id} onClick={() => go(`/crm/quote?id=${r.id}`)} className="px-3 py-3 active:bg-ink-50">
              <div className="flex items-start justify-between gap-2"><span className="min-w-0"><b>{r.code}</b>{r.version > 1 && <span className="text-ink-400"> v{r.version}</span>}
                <span className="block truncate text-sm">{r.customers?.company_name || r.customers?.contact_name}</span></span><QuoteStatus s={r.status} /></div>
              <div className="mt-1 flex items-center justify-between text-xs text-ink-500"><span>{fmtDate(r.created_at)}{(r.order_code || r.ma_don) && <b className="ml-1 text-brand-700">· {r.order_code || r.ma_don}</b>}</span><b className="text-sm text-ink-900 tabular-nums">{money(r.total_after_vat)}</b></div>
              <div className="mt-1.5 flex gap-1.5" onClick={e => e.stopPropagation()}>
                <button className="rounded-md border border-ink-200 px-2 py-0.5 text-[11px] font-semibold" onClick={() => go(`/crm/quote?id=${r.id}&print=1`)}>🖨 In</button>
                <button className="rounded-md border border-ink-200 px-2 py-0.5 text-[11px] font-semibold" onClick={() => clone(r.id)}>⧉ Nhân bản</button></div>
            </li>))}</ul>
          <Table className="hidden md:block" head={['Mã', 'Khách hàng', 'Ngày', 'Trạng thái', 'Tổng sau VAT', 'LN ước tính', 'Hiệu lực', 'Mã đơn', 'Sale']}>
            {(data as any[]).map(r => (
              <tr key={r.id} className="cursor-pointer hover:bg-ink-50" onClick={() => go(`/crm/quote?id=${r.id}`)}>
                <Td className="whitespace-nowrap font-medium">{r.code}{r.version > 1 && <span className="text-ink-400"> v{r.version}</span>}
                  <div className="mt-1 flex gap-1" onClick={e => e.stopPropagation()}>
                    <button className="rounded-md border border-ink-200 bg-white px-2 py-0.5 text-[11px] font-semibold text-ink-600 hover:border-brand-300 hover:text-brand-700" onClick={() => go(`/crm/quote?id=${r.id}&print=1`)}>🖨 In</button>
                    <button className="rounded-md border border-ink-200 bg-white px-2 py-0.5 text-[11px] font-semibold text-ink-600 hover:border-brand-300 hover:text-brand-700" onClick={() => clone(r.id)}>⧉ Nhân bản</button>
                  </div></Td>
                <Td>{r.customers?.company_name || r.customers?.contact_name}<div className="text-xs text-ink-400">{r.customers?.code}</div></Td>
                <Td className="whitespace-nowrap">{fmtDate(r.created_at)}</Td>
                <Td><QuoteStatus s={r.status} />{r.violations?.length > 0 && r.status === 'nhap' && <div className="text-[11px] text-amber-700">Phá khung</div>}</Td>
                <Td className="text-right tabular-nums">{money(r.total_after_vat)}</Td>
                <Td className="text-right tabular-nums text-emerald-700">{money(r.est_profit)}</Td>
                <Td className="whitespace-nowrap">{fmtDate(r.valid_until)}</Td><Td className="whitespace-nowrap font-semibold text-brand-700">{r.order_code || r.ma_don}</Td><Td className="whitespace-nowrap text-xs">{a.personName(r.sale_id)}</Td>
              </tr>))}
          </Table></>}
      </div>
    </Layout>
  );
}
