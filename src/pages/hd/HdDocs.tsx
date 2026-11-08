// Bản 35 — Xuất nhanh bộ chứng từ đi kèm HĐ đã ký: Đơn đặt hàng, Biên bản giao nhận, HĐ mua bán / HĐ nguyên tắc
//  · Trên từng HĐ: bấm 1 chứng từ (tải .docx) hoặc “Cả bộ” (.zip)
//  · Tab Đã ký: tick nhiều HĐ (hoặc chọn tất cả đang lọc / cả đơn) → chọn loại chứng từ → tải 1 file .zip
import React, { useMemo, useState } from 'react';
import { Button, Card, cx, Input, Modal, toast, useAction } from '../../components/ui';
import { db } from '../../lib/sb';
import { downloadBlob } from '../../lib/format';
import { DOC_NAME, docFile, docsOf, hasHdnt, makeBundle, makeDocx, soDon, type DocInv, type DocKind } from '../../lib/hdDocs';

const loadDocs = async (ids: string[]): Promise<DocInv[]> => (await db.rpc<DocInv[]>('out_docs_data', { p_ids: ids })) || [];
const thieu = (v: DocInv) => !v.buyer?.dai_dien || !v.buyer?.chuc_vu;

/** Bổ sung Người đại diện / Chức vụ trước khi in (lưu vào pháp nhân để lần sau tự có) */
function InfoModal({ invs, onClose, onOk }: { invs: DocInv[]; onClose: () => void; onOk: (invs: DocInv[]) => void }) {
  const miss = invs.filter(thieu); const keyOf = (v: DocInv) => v.buyer?.id || 'mst:' + (v.tax_code || v.id);
  const uniq = Array.from(new Map(miss.map(v => [keyOf(v), v])).values());
  const [f, setF] = useState<Record<string, { dai_dien: string; chuc_vu: string }>>(() => Object.fromEntries(uniq.map(v => [keyOf(v), { dai_dien: v.buyer?.dai_dien || '', chuc_vu: v.buyer?.chuc_vu || '' }])));
  const [save, setSave] = useState(true); const { busy, run } = useAction();
  const go = (fill: boolean) => run(async () => {
    if (fill && save) for (const v of uniq) { const x = f[keyOf(v)]; if (v.buyer?.id && (x.dai_dien.trim() || x.chuc_vu.trim())) await db.rpc('out_buyer_doc_info', { p_id: v.buyer.id, p: { dai_dien: x.dai_dien, chuc_vu: x.chuc_vu } }).catch(e => toast.err(e)); }
    onOk(invs.map(v => { const x = fill ? f[keyOf(v)] : null; return x ? { ...v, buyer: { ...(v.buyer || {}), dai_dien: x.dai_dien.trim() || v.buyer?.dai_dien, chuc_vu: x.chuc_vu.trim() || v.buyer?.chuc_vu } } : v; }));
  });
  return <Modal open onClose={onClose} title={`Bổ sung người đại diện · ${uniq.length} pháp nhân`} footer={<>
    <Button onClick={() => go(false)} loading={busy}>Bỏ qua (để dòng chấm)</Button><Button variant="primary" loading={busy} onClick={() => go(true)}>Xuất chứng từ</Button></>}>
    <p className="mb-2 text-xs text-ink-600">Biên bản giao nhận / hợp đồng cần <b>người đại diện bên mua</b>. Điền 1 lần — ERP lưu vào pháp nhân, lần sau tự có.</p>
    <div className="max-h-[55vh] space-y-2 overflow-auto">{uniq.map(v => { const k = keyOf(v); const x = f[k];
      return <div key={k} className="rounded-xl border border-ink-200 p-2"><div className="text-sm font-semibold">{v.buyer_name}</div><div className="text-[11px] text-ink-500">MST {v.tax_code}{!v.buyer?.id ? ' · chưa có trong danh sách pháp nhân — chỉ dùng cho lần xuất này' : ''}</div>
        <div className="mt-1 grid grid-cols-2 gap-2"><Input placeholder="VD: Ông Trương Văn Dương" value={x.dai_dien} onChange={e => setF(y => ({ ...y, [k]: { ...x, dai_dien: e.target.value } }))} />
          <Input placeholder="VD: Giám đốc / Chủ hộ kinh doanh" value={x.chuc_vu} onChange={e => setF(y => ({ ...y, [k]: { ...x, chuc_vu: e.target.value } }))} /></div></div>; })}</div>
    <label className="mt-2 flex items-center gap-2 text-xs"><input type="checkbox" checked={save} onChange={e => setSave(e.target.checked)} /> Lưu vào pháp nhân nhận HĐ</label>
  </Modal>;
}

/** Hook chung: tải dữ liệu → (hỏi bổ sung đại diện) → tạo file */
function useDocs() {
  const [ask, setAsk] = useState<{ invs: DocInv[]; then: (x: DocInv[]) => Promise<void> } | null>(null); const [busy, setBusy] = useState('');
  const start = async (ids: string[], then: (x: DocInv[]) => Promise<void>, needRep: boolean) => {
    setBusy('Đang lấy dữ liệu…');
    try { const invs = await loadDocs(ids); if (!invs.length) throw new Error('Không có HĐ nào bạn được xem');
      if (needRep && invs.some(thieu)) { setAsk({ invs, then }); return; } await then(invs); }
    catch (e: any) { toast.err(e); } finally { setBusy(''); }
  };
  const modal = ask && <InfoModal invs={ask.invs} onClose={() => setAsk(null)} onOk={async x => { const t = ask.then; setAsk(null); setBusy('Đang tạo file…'); try { await t(x); } catch (e: any) { toast.err(e); } finally { setBusy(''); } }} />;
  return { start, busy, modal };
}

/** Nút trên từng HĐ: ĐĐH · BBGN · HĐMB/HĐNT · Cả bộ */
export function DocBtns({ v, compact }: { v: { id: string; buyer_name?: string; so_hd?: string }; compact?: boolean }) {
  const d = useDocs(); const [info, setInfo] = useState<DocInv | null>(null);
  const one = (k: DocKind) => d.start([v.id], async ([x]) => { setInfo(x); const kk = k === 'hdmb' && hasHdnt(x) ? 'hdnt' : k; downloadBlob(docFile(x, kk), await makeDocx(x, kk)); }, k !== 'ddh');
  const all = () => d.start([v.id], async ([x]) => { setInfo(x); const kinds = docsOf(x); const { blob } = await makeBundle([x], hasHdnt(x) ? [...kinds, 'hdnt'] : kinds); downloadBlob(`Chung_tu_HD${soDon(x)}.zip`, blob); }, true);
  const b = 'rounded-md border border-ink-200 bg-white px-1.5 py-0.5 text-[11px] font-semibold text-ink-700 hover:border-brand-400 hover:text-brand-700 disabled:opacity-50';
  return <div className={cx('flex flex-wrap items-center gap-1', compact && 'max-w-[220px]')} onClick={e => e.stopPropagation()}>
    <button className={b} disabled={!!d.busy} title="Đơn đặt hàng (.docx)" onClick={() => one('ddh')}>ĐĐH</button>
    <button className={b} disabled={!!d.busy} title="Biên bản giao nhận hàng hóa (.docx)" onClick={() => one('bbgn')}>BBGN</button>
    <button className={b} disabled={!!d.busy} title="Khách chưa ký HĐ nguyên tắc → HĐ mua bán cho HĐ này; đã ký → tải HĐ nguyên tắc" onClick={() => one('hdmb')}>{info ? (hasHdnt(info) ? 'HĐNT' : 'HĐMB') : 'HĐMB/NT'}</button>
    <button className={cx(b, 'border-brand-300 bg-brand-50 text-brand-800')} disabled={!!d.busy} title="Cả bộ chứng từ của HĐ này (.zip)" onClick={all}>{d.busy ? '…' : '⬇ Cả bộ'}</button>
    {d.modal}</div>;
}

/** Thanh xuất hàng loạt cho danh sách HĐ đã ký */
export function DocsBar({ rows, sel, setSel }: { rows: any[]; sel: Record<string, boolean>; setSel: (x: Record<string, boolean>) => void }) {
  const [kinds, setKinds] = useState<DocKind[]>(() => { try { const k = JSON.parse(localStorage.getItem('nt_doc_kinds') || 'null'); return Array.isArray(k) && k.length ? k : ['ddh', 'bbgn', 'hdmb']; } catch { return ['ddh', 'bbgn', 'hdmb']; } });
  const tog = (k: DocKind) => { const n = kinds.includes(k) ? kinds.filter(x => x !== k) : [...kinds, k]; setKinds(n); try { localStorage.setItem('nt_doc_kinds', JSON.stringify(n)); } catch { /* */ } };
  const d = useDocs(); const ids = rows.filter(r => sel[r.id]).map(r => r.id);
  const go = () => { if (!ids.length) return toast.info('Tick HĐ cần xuất (hoặc “Chọn tất cả”)'); if (!kinds.length) return toast.info('Chọn ít nhất 1 loại chứng từ');
    d.start(ids, async invs => { const { blob, n } = await makeBundle(invs, kinds); if (!n) { toast.info('Không có chứng từ nào cần tạo (HĐ mua bán chỉ cho khách chưa ký HĐ nguyên tắc)'); return; }
      downloadBlob(`Chung_tu_${invs.length}HD_${new Date().toISOString().slice(0, 10)}.zip`, blob); toast.ok(`Đã tạo ${n} file chứng từ cho ${invs.length} HĐ`); }, kinds.some(k => k !== 'ddh')); };
  const allOn = rows.length > 0 && rows.every(r => sel[r.id]);
  return <Card className="mb-3" bodyClass="flex flex-wrap items-center gap-2 px-3 py-2 text-xs">
    <label className="flex items-center gap-1.5 font-semibold"><input type="checkbox" className="h-4 w-4" checked={allOn} onChange={e => setSel(e.target.checked ? Object.fromEntries(rows.map(r => [r.id, true])) : {})} /> Chọn tất cả đang lọc ({rows.length})</label>
    <span className="text-ink-300">|</span><span className="text-ink-500">Chứng từ:</span>
    {(['ddh', 'bbgn', 'hdmb', 'hdnt'] as DocKind[]).map(k => <button key={k} onClick={() => tog(k)} className={cx('rounded-full border px-2 py-0.5 font-semibold', kinds.includes(k) ? 'border-brand-500 bg-brand-50 text-brand-800' : 'border-ink-200 text-ink-500')}>
      {kinds.includes(k) ? '✓ ' : ''}{DOC_NAME[k]}{k === 'hdmb' ? ' (khách chưa ký HĐNT)' : k === 'hdnt' ? ' (1 bản / khách)' : ''}</button>)}
    <Button size="sm" variant="primary" className="ml-auto" loading={!!d.busy} disabled={!ids.length} onClick={go}>⬇ Xuất {ids.length || ''} HĐ (.zip)</Button>
    {d.busy && <span className="text-brand-700">{d.busy}</span>}{d.modal}</Card>;
}

/** Tab "Đã ký" của sale: lọc + chọn nhiều + cột chứng từ */
export function KyList({ data, render }: { data: any[] | null | undefined; render: (rows: any[], sel: Record<string, boolean>, onSel: (id: string, on: boolean) => void) => React.ReactNode }) {
  const [q, setQ] = useState(''); const [sel, setSel] = useState<Record<string, boolean>>({});
  const rows = useMemo(() => { const qq = q.trim().toLowerCase(); return (data || []).filter(v => !qq || [v.code, v.buyer_name, v.tax_code, v.mds, v.hds, v.so_hd, v.mas].some(x => String(x || '').toLowerCase().includes(qq))); }, [data, q]);
  return <>
    <div className="mb-2 flex flex-wrap items-center gap-2"><Input className="max-w-sm" placeholder="🔎 Tìm số HĐ, ID đơn (cả đơn), tên / MST khách…" value={q} onChange={e => setQ(e.target.value)} />
      <span className="text-xs text-ink-500">Gõ ID đơn → “Chọn tất cả đang lọc” để xuất chứng từ cả đơn.</span></div>
    <DocsBar rows={rows} sel={sel} setSel={setSel} />
    {render(rows, sel, (id, on) => setSel(x => ({ ...x, [id]: on })))}
  </>;
}
