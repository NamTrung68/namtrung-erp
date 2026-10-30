import React, { useEffect, useState } from 'react';
import { Layout } from '../components/Layout';
import { Button, Empty, Field, Input, Loading, Modal, NumInput, Table, Td, useAction, useLoad, toast, cx } from '../components/ui';
import { db, fetchAll } from '../lib/sb';
import { useApp } from '../state';
import { fmtDateTime, money, num } from '../lib/format';
import { writeXlsx } from '../lib/xlsx';
import { ImportField, ImportWizard } from '../components/ImportWizard';
import { Pager, usePager } from '../components/Pager';

const INV: ImportField[] = [
  { key: 'name', label: 'Tên hàng', required: true, aliases: ['tên sản phẩm', 'sản phẩm', 'tên sp', 'hàng hóa', 'tên hàng hóa', 'mô tả'] },
  { key: 'sku', label: 'Mã hàng', aliases: ['mã sp', 'sku', 'mã sản phẩm', 'mã vật tư'] },
  { key: 'qty', label: 'Tồn', type: 'number', aliases: ['số lượng tồn', 'tồn kho', 'số lượng', 'sl tồn', 'tồn cuối'] },
  { key: 'unit', label: 'ĐVT', aliases: ['đơn vị', 'đơn vị tính'] },
  { key: 'cost_price', label: 'Đơn giá nhập', type: 'number', aliases: ['giá nhập', 'giá vốn', 'đơn giá vốn'] },
  { key: 'sale_price', label: 'Đơn giá xuất', type: 'number', aliases: ['giá xuất', 'giá bán', 'đơn giá bán'] },
  { key: 'warehouse', label: 'Kho', aliases: ['vị trí', 'kho hàng'] }, { key: 'note', label: 'Ghi chú' },
];

export default function Inventory() {
  const a = useApp(); const [q, setQ] = useState(''); const [dq, setDq] = useState(''); const [imp, setImp] = useState(false); const [replace, setReplace] = useState(true);
  const [edit, setEdit] = useState<any>(null);
  useEffect(() => { const t = setTimeout(() => setDq(q.trim()), 300); return () => clearTimeout(t); }, [q]);
  const canEdit = a.isAdmin || a.has('bgd', 'ke_toan');
  const pg = usePager('inventory', [dq]);
  const build = (count: boolean) => {
    let qq = db.from('inventory_items').select('*', { count }).order('name');
    if (dq) { const s = dq.replace(/[(),*]/g, ' '); const n = s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/đ/gi, 'd').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim(); qq = qq.or(`name_norm.ilike.*${n || s}*,sku.ilike.*${s}*`); }
    return qq;
  };
  const { data: res, loading, reload } = useLoad(() => build(true).range(pg.from, pg.to), [dq, pg.page, pg.size]);
  const { data: tot, reload: rt } = useLoad(() => db.rpc<any>('inventory_totals', { p_q: dq || null }), [dq]);
  const rows: any[] = (res as any)?.data || []; const total = (res as any)?.count ?? 0;
  const refresh = () => { reload(); rt(); };
  const exportAll = async () => { const all = await fetchAll(() => build(false).order('id'), 50000);
    await writeXlsx('ton-kho', [['Mã hàng', 'Tên hàng', 'Tồn', 'ĐVT', 'Đơn giá nhập', 'Đơn giá xuất', 'Giá trị nhập', 'Giá trị xuất', 'Kho', 'Ghi chú'],
      ...all.map(r => [r.sku, r.name, r.qty === null ? '' : Number(r.qty), r.unit, r.cost_price === null ? '' : Number(r.cost_price), r.sale_price === null ? '' : Number(r.sale_price),
        r.qty !== null && r.cost_price !== null ? Number(r.qty) * Number(r.cost_price) : '', r.qty !== null && r.sale_price !== null ? Number(r.qty) * Number(r.sale_price) : '', r.warehouse, r.note])], 'Tồn kho'); };
  const T = ({ l, v, sub, tone }: { l: string; v: React.ReactNode; sub?: string; tone?: string }) =>
    <div className="rounded-2xl border border-ink-200 bg-white px-4 py-3 shadow-soft"><div className="text-xs text-ink-500">{l}</div><div className={cx('text-xl font-extrabold tabular-nums sm:text-2xl', tone)}>{v}</div>{sub && <div className="text-[11px] text-ink-400">{sub}</div>}</div>;
  return (
    <Layout title="Tồn kho công ty" actions={<>{canEdit && <Button variant="dark" onClick={() => setImp(true)}>⇪ Nhập tồn kho</Button>}<Button onClick={exportAll}>⬇ Xuất Excel</Button></>}>
      <div className="mb-3 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <T l="Mặt hàng" v={num(tot?.items ?? 0)} sub={tot?.updated_at ? `cập nhật ${fmtDateTime(tot.updated_at)}` : undefined} />
        <T l="Tổng tồn kho" v={num(tot?.qty ?? 0)} sub="tổng số lượng" />
        <T l="Tổng giá trị nhập" v={money(tot?.cost_value ?? 0)} sub="Σ tồn × đơn giá nhập" tone="text-amber-700" />
        <T l="Tổng giá trị xuất" v={money(tot?.sale_value ?? 0)} sub="Σ tồn × đơn giá xuất" tone="text-emerald-700" />
      </div>
      <div className="mb-3 flex flex-wrap items-center gap-3"><Input className="max-w-md" placeholder="🔎 Tìm tên hàng (không cần dấu) hoặc mã…" value={q} onChange={e => setQ(e.target.value)} />
        <span className="text-xs text-ink-500">Báo giá có tên hàng giống tồn kho sẽ hiện cảnh báo cho Sale và báo quản lý.{canEdit && ' Bấm số tồn để sửa nhanh.'}</span></div>
      <div className="rounded-2xl border border-ink-200 bg-white shadow-soft">
        {loading && !rows.length ? <Loading /> : !rows.length ? <Empty>{dq ? 'Không có mặt hàng phù hợp' : 'Chưa nhập tồn kho'}</Empty> :
          <Table head={['Mã hàng', 'Tên hàng', 'Tồn', 'ĐVT', 'Đơn giá nhập', 'Đơn giá xuất', 'Kho', 'Ghi chú', ...(canEdit ? [''] : [])]}>{rows.map(r => <tr key={r.id}>
            <Td className="whitespace-nowrap font-semibold">{r.sku}</Td><Td className="min-w-[240px]">{r.name}</Td>
            <Td className="text-right">{canEdit ? <QtyCell r={r} onSaved={refresh} /> : <b className="tabular-nums">{num(r.qty)}</b>}</Td>
            <Td>{r.unit}</Td><Td className="text-right tabular-nums">{money(r.cost_price)}</Td><Td className="text-right tabular-nums">{money(r.sale_price)}</Td>
            <Td>{r.warehouse}</Td><Td className="text-xs text-ink-500">{r.note}</Td>
            {canEdit && <Td><button className="text-xs font-semibold text-brand-700 hover:underline" onClick={() => setEdit(r)}>Sửa</button></Td>}</tr>)}</Table>}
        <Pager p={pg} total={total} />
      </div>
      {edit && <EditItem item={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); refresh(); }} />}
      <ImportWizard open={imp} onClose={() => setImp(false)} title="Nhập tồn kho" fields={INV} sampleName="mau-ton-kho"
        options={<label className="ml-auto flex items-center gap-2 rounded-lg bg-amber-50 px-2 py-1 text-xs font-semibold text-amber-900"><input type="checkbox" checked={replace} onChange={e => setReplace(e.target.checked)} /> Thay toàn bộ tồn kho cũ</label>}
        note={<>Nên xuất file tồn kho từ phần mềm kho rồi nhập lại mỗi ngày/tuần. Bật “Thay toàn bộ” để danh sách luôn khớp số tồn mới nhất; tắt để chỉ cập nhật theo Mã hàng.</>}
        onImport={async rs => { if (rs.length > 20000) throw new Error('Tối đa 20.000 dòng mỗi lần'); const n = await db.rpc<number>('import_inventory', { p_rows: rs, p_replace: replace }); refresh(); toast.ok('Đã nhập tồn kho'); return <b>Đã nhập {num(n)} mặt hàng.</b>; }} />
    </Layout>
  );
}

function QtyCell({ r, onSaved }: { r: any; onSaved: () => void }) {
  const [v, setV] = useState<number | null>(null); const { busy, run } = useAction();
  if (v === null) return <button className="rounded-md px-1.5 py-0.5 font-bold tabular-nums hover:bg-brand-50 hover:text-brand-700" title="Bấm để sửa số tồn" onClick={() => setV(Number(r.qty) || 0)}>{num(r.qty)}</button>;
  const save = () => { if (v === Number(r.qty)) { setV(null); return; } run(async () => { await db.from('inventory_items').update({ qty: v }).eq('id', r.id); setV(null); onSaved(); }, 'Đã cập nhật tồn'); };
  return <div className="flex justify-end gap-1"><NumInput autoFocus className="w-24" value={v} onChange={x => setV(x ?? 0)} onKeyDown={(e: any) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') setV(null); }} />
    <Button size="sm" variant="primary" loading={busy} onClick={save}>✓</Button></div>;
}

function EditItem({ item, onClose, onSaved }: { item: any; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState<any>({ ...item }); const { busy, run } = useAction();
  const s = (k: string) => (v: any) => setF((x: any) => ({ ...x, [k]: v }));
  return <Modal open onClose={onClose} title={`Sửa tồn kho · ${item.sku || item.name}`} size="sm"
    footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      if (!String(f.name || '').trim()) throw new Error('Nhập tên hàng');
      await db.from('inventory_items').update({ name: f.name.trim(), sku: f.sku || null, qty: f.qty, unit: f.unit || null, cost_price: f.cost_price, sale_price: f.sale_price, warehouse: f.warehouse || null, note: f.note || null }).eq('id', item.id); onSaved();
    }, 'Đã lưu')}>Lưu</Button>}>
    <div className="grid grid-cols-2 gap-3">
      <Field label="Tên hàng" className="col-span-2"><Input value={f.name || ''} onChange={e => s('name')(e.target.value)} /></Field>
      <Field label="Mã hàng"><Input value={f.sku || ''} onChange={e => s('sku')(e.target.value)} /></Field>
      <Field label="ĐVT"><Input value={f.unit || ''} onChange={e => s('unit')(e.target.value)} /></Field>
      <Field label="Số lượng tồn"><NumInput value={f.qty} onChange={s('qty')} /></Field>
      <Field label="Kho"><Input value={f.warehouse || ''} onChange={e => s('warehouse')(e.target.value)} /></Field>
      <Field label="Đơn giá nhập"><NumInput value={f.cost_price} onChange={s('cost_price')} /></Field>
      <Field label="Đơn giá xuất"><NumInput value={f.sale_price} onChange={s('sale_price')} /></Field>
      <Field label="Ghi chú" className="col-span-2"><Input value={f.note || ''} onChange={e => s('note')(e.target.value)} /></Field>
    </div>
    <p className="mt-2 text-xs text-ink-500">Mọi thay đổi số tồn / giá được ghi nhật ký (ai sửa, lúc nào).</p>
  </Modal>;
}
