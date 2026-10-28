import React, { useState } from 'react';
import { Layout } from '../components/Layout';
import { Button, Empty, Input, Loading, Table, Td, useLoad, toast } from '../components/ui';
import { db } from '../lib/sb';
import { useApp } from '../state';
import { fmtDateTime, num, noAccent } from '../lib/format';
import { writeXlsx } from '../lib/xlsx';
import { ImportField, ImportWizard } from '../components/ImportWizard';

const INV: ImportField[] = [
  { key: 'name', label: 'Tên hàng', required: true, aliases: ['tên sản phẩm', 'sản phẩm', 'tên sp', 'hàng hóa', 'tên hàng hóa', 'mô tả'] },
  { key: 'sku', label: 'Mã hàng', aliases: ['mã sp', 'sku', 'mã sản phẩm', 'mã vật tư'] },
  { key: 'qty', label: 'Tồn', type: 'number', aliases: ['số lượng tồn', 'tồn kho', 'số lượng', 'sl tồn', 'tồn cuối'] },
  { key: 'unit', label: 'ĐVT', aliases: ['đơn vị', 'đơn vị tính'] }, { key: 'warehouse', label: 'Kho', aliases: ['vị trí', 'kho hàng'] }, { key: 'note', label: 'Ghi chú' },
];

export default function Inventory() {
  const a = useApp(); const [q, setQ] = useState(''); const [imp, setImp] = useState(false); const [replace, setReplace] = useState(true);
  const canImport = a.isAdmin || a.has('bgd', 'ke_toan');
  const { data, loading, reload } = useLoad(() => db.from('inventory_items').select('*').order('name').limit(5000), []);
  const all = (data as any[]) || []; const s = noAccent(q.trim().toLowerCase());
  const rows = s ? all.filter(r => r.name_norm.includes(s.replace(/[^a-z0-9]+/g, ' ').trim()) || (r.sku || '').toLowerCase().includes(s)) : all;
  const last = all.reduce((m, r) => (r.updated_at > m ? r.updated_at : m), '');
  return (
    <Layout title="Tồn kho công ty" actions={<>{canImport && <Button variant="dark" onClick={() => setImp(true)}>⇪ Nhập tồn kho</Button>}<Button onClick={() => writeXlsx('ton-kho', [['Mã hàng', 'Tên hàng', 'Tồn', 'ĐVT', 'Kho', 'Ghi chú'], ...rows.map(r => [r.sku, r.name, r.qty === null ? '' : Number(r.qty), r.unit, r.warehouse, r.note])], 'Tồn kho')}>⬇ Xuất Excel</Button></>}>
      <p className="mb-3 text-sm text-ink-500">Khi Sale báo giá mặt hàng có tên giống hàng tồn kho, hệ thống hiện cảnh báo ngay trên dòng hàng và báo quản lý trực tiếp. Sale vẫn báo giá bình thường.</p>
      <div className="mb-3 flex flex-wrap items-center gap-3"><Input className="max-w-md" placeholder="🔎 Tìm tên hàng hoặc mã…" value={q} onChange={e => setQ(e.target.value)} />
        <span className="text-xs text-ink-500">{num(all.length)} mặt hàng{last && ` · cập nhật ${fmtDateTime(last)}`}</span></div>
      <div className="rounded-2xl border border-ink-200 bg-white shadow-soft">
        {loading ? <Loading /> : !rows.length ? <Empty>{all.length ? 'Không có mặt hàng phù hợp' : 'Chưa nhập tồn kho'}</Empty> :
          <Table head={['Mã hàng', 'Tên hàng', 'Tồn', 'ĐVT', 'Kho', 'Ghi chú']}>{rows.slice(0, 500).map(r => <tr key={r.id}>
            <Td className="whitespace-nowrap font-semibold">{r.sku}</Td><Td className="min-w-[260px]">{r.name}</Td><Td className="text-right font-semibold tabular-nums">{num(r.qty)}</Td>
            <Td>{r.unit}</Td><Td>{r.warehouse}</Td><Td className="text-xs text-ink-500">{r.note}</Td></tr>)}</Table>}
        {rows.length > 500 && <p className="p-3 text-center text-xs text-ink-400">Hiển thị 500 dòng đầu — gõ để tìm</p>}
      </div>
      <ImportWizard open={imp} onClose={() => setImp(false)} title="Nhập tồn kho" fields={INV} sampleName="mau-ton-kho"
        options={<label className="ml-auto flex items-center gap-2 rounded-lg bg-amber-50 px-2 py-1 text-xs font-semibold text-amber-900"><input type="checkbox" checked={replace} onChange={e => setReplace(e.target.checked)} /> Thay toàn bộ tồn kho cũ</label>}
        note={<>Nên xuất file tồn kho từ phần mềm kho rồi nhập lại mỗi ngày/tuần. Bật “Thay toàn bộ” để danh sách luôn khớp số tồn mới nhất; tắt để chỉ cập nhật theo Mã hàng.</>}
        onImport={async rs => { if (rs.length > 20000) throw new Error('Tối đa 20.000 dòng mỗi lần'); const n = await db.rpc<number>('import_inventory', { p_rows: rs, p_replace: replace }); reload(); toast.ok('Đã nhập tồn kho'); return <b>Đã nhập {num(n)} mặt hàng.</b>; }} />
    </Layout>
  );
}
