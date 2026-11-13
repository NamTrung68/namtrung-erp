// Bản 35–36 — Bộ chứng từ đi kèm HĐ đã ký: Đơn đặt hàng, Biên bản giao nhận, HĐ mua bán / HĐ nguyên tắc
//  · Trên từng HĐ: biểu tượng từng chứng từ (tải .docx) hoặc “Cả bộ” (.zip)
//  · Tab Đã ký: tick nhiều HĐ (hoặc chọn tất cả đang lọc / cả đơn) → chọn loại chứng từ → tải 1 file .zip
//  · Bản 36 — vết hồ sơ: tải (tự ghi loại, ai, lúc nào) → ✉ đã gửi khách → ✍ đã nhận bản ký (file lưu Google Drive)
import React, { useEffect, useMemo, useState } from 'react';
import { useApp } from '../../state';
import { ask, Button, Card, cx, Input, Modal, toast, useAction } from '../../components/ui';
import { db } from '../../lib/sb';
import { downloadBlob } from '../../lib/format';
import { DOC_NAME, docFile, docsOf, hasHdnt, makeBundle, makeDocx, soDon, type DocInv, type DocKind } from '../../lib/hdDocs';
import { kyName, kyNgay, kyPdf } from '../../lib/hdky';
import { HS_SCAN, HoSoChip, HoSoModal, loadScanSt, ScanUpload, scanKey, useIsAcc, type HsScanKey, type ScanSt } from './HoSo';

const loadDocs = async (ids: string[]): Promise<DocInv[]> => {
  const invs = (await db.rpc<DocInv[]>('out_docs_data', { p_ids: ids })) || [];
  // mã đơn (MD…) của từng HĐ — in vào "Số đơn hàng" trên ĐĐH / BBGN
  const md: Record<string, string[]> = {};
  for (let i = 0; i < ids.length; i += 80) {
    let r: any = []; try { r = await db.from('out_invoice_lines').select('invoice_id,out_items(md)').in('invoice_id', ids.slice(i, i + 80)); } catch { /* thiếu mã đơn → dùng số HĐ */ }
    (r?.data ?? r ?? []).forEach((l: any) => { const m = l.out_items?.md; if (m) (md[l.invoice_id] ||= []).push(m); });
  }
  return invs.map(v => ({ ...v, mds: md[v.id] || [] }));
};
const thieu = (v: DocInv) => !v.buyer?.dai_dien || !v.buyer?.chuc_vu;

/** Bổ sung Người đại diện / Chức vụ trước khi in (lưu vào pháp nhân để lần sau tự có) */
function InfoModal({ invs, onClose, onOk }: { invs: DocInv[]; onClose: () => void; onOk: (invs: DocInv[]) => void }) {
  const miss = invs.filter(thieu); const keyOf = (v: DocInv) => v.buyer?.id || 'mst:' + (v.tax_code || v.id);
  const uniq = Array.from(new Map(miss.map(v => [keyOf(v), v])).values());
  const [f, setF] = useState<Record<string, { dai_dien: string; chuc_vu: string }>>(() => Object.fromEntries(uniq.map(v => [keyOf(v), { dai_dien: v.buyer?.dai_dien || '', chuc_vu: v.buyer?.chuc_vu || '' }])));
  const a = useApp(); const [save, setSave] = useState(() => a.isAdmin || a.has('ke_toan') || !!a.settings.accounting?.pn_mo); const { busy, run } = useAction();
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

/** Bản 39: ngày chứng từ = ngày in trên HĐ đã ký (đọc trong PDF). Lệch ngày hệ thống ghi → sửa luôn trên phiếu */
async function syncNgay(drive: any, invs: DocInv[], onStep?: (s: string) => void): Promise<DocInv[]> {
  const out = [...invs]; let next = 0, done = 0;
  const worker = async () => { while (next < out.length) { const i = next++; const v = out[i];
    const ngay = await kyNgay(drive, v.id);
    if (ngay && ngay !== String(v.ngay_hd || '').slice(0, 10)) { out[i] = { ...v, ngay_hd: ngay }; db.rpc('out_ky_fix_ngay', { p_id: v.id, p_ngay: ngay }).catch(() => null); }
    onStep?.(`Đang đối chiếu ngày HĐ ${++done}/${out.length}…`); } };
  await Promise.all(Array.from({ length: Math.min(3, out.length) }, worker));
  return out;
}

/** Hook chung: tải dữ liệu → đối chiếu ngày HĐ → (hỏi bổ sung đại diện) → tạo file */
function useDocs() {
  const a = useApp();
  const [ask, setAsk] = useState<{ invs: DocInv[]; then: (x: DocInv[]) => Promise<void> } | null>(null); const [busy, setBusy] = useState('');
  const start = async (ids: string[], then: (x: DocInv[]) => Promise<void>, needRep: boolean) => {
    setBusy('Đang lấy dữ liệu…');
    try { let invs = await loadDocs(ids); if (!invs.length) throw new Error('Không có HĐ nào bạn được xem');
      invs = await syncNgay(a.settings.drive, invs, setBusy);
      if (needRep && invs.some(thieu)) { setAsk({ invs, then }); return; } await then(invs); }
    catch (e: any) { toast.err(e); } finally { setBusy(''); }
  };
  const modal = ask && <InfoModal invs={ask.invs} onClose={() => setAsk(null)} onOk={async x => { const t = ask.then; setAsk(null); setBusy('Đang tạo file…'); try { await t(x); } catch (e: any) { toast.err(e); } finally { setBusy(''); } }} />;
  return { start, busy, modal };
}

// ---------- Vết hồ sơ ----------
export interface DocSt { invoice_id: string; tai: Record<string, { at: string; by: string; n: number }>; gui_at: string | null; gui_by: string | null; ky_at: string | null; ky_by: string | null; ky_url: string | null; note: string | null;
  cung_at?: string | null; cung_vi_tri?: string | null; scan?: ScanSt | null }
export type HsKey = 'chua' | 'tai' | 'gui' | 'ky';
export const hsOf = (st?: DocSt | null): HsKey => (!st ? 'chua' : st.ky_at ? 'ky' : st.gui_at ? 'gui' : Object.keys(st.tai || {}).length ? 'tai' : 'chua');
export const HS: Record<HsKey, [string, string, string]> = {
  chua: ['Chưa xử lý hồ sơ', '○', 'border-ink-200 bg-ink-50 text-ink-500'],
  tai: ['Đã tải — chưa gửi khách', '⬇', 'border-sky-200 bg-sky-50 text-sky-800'],
  gui: ['Đã gửi khách — chờ bản ký', '✉', 'border-violet-200 bg-violet-50 text-violet-800'],
  ky: ['Đủ hồ sơ — đã có bản ký', '✓', 'border-emerald-300 bg-emerald-50 text-emerald-800'],
};
export async function loadDocStates(ids: string[]): Promise<Record<string, DocSt>> {
  const out: Record<string, DocSt> = {};
  for (let i = 0; i < ids.length; i += 80) {
    const part = ids.slice(i, i + 80); if (!part.length) continue;
    const rows = await db.from('out_doc_state').select('*').in('invoice_id', part) as any;
    (rows?.data ?? rows ?? []).forEach((r: DocSt) => { out[r.invoice_id] = r; });
  }
  // Bản 41: kèm tình trạng hồ sơ scan + bản cứng
  const sc = await loadScanSt(ids).catch(() => ({} as Record<string, ScanSt>));
  for (const id of Object.keys(sc)) out[id] = { ...(out[id] || { invoice_id: id, tai: {}, gui_at: null, gui_by: null, ky_at: null, ky_by: null, ky_url: null, note: null }), scan: sc[id] };
  return out;
}
const mark = (ids: string[], act: string, kinds: string[] = [], url: string | null = null) => db.rpc('out_doc_mark', { p_ids: ids, p_act: act, p_kinds: kinds, p_url: url, p_note: null });

const ICON: Record<DocKind | 'all', [string, string, string]> = {
  ddh: ['🧾', 'ĐĐH', 'Đơn đặt hàng (.docx)'], bbgn: ['🚚', 'BBGN', 'Biên bản giao nhận hàng hóa (.docx)'],
  hdmb: ['📜', 'HĐMB', 'HĐ mua bán cho HĐ này (khách chưa ký HĐ nguyên tắc)'], hdnt: ['🤝', 'HĐNT', 'HĐ nguyên tắc của khách'], all: ['🗂️', 'Cả bộ', 'Cả bộ: Đơn đặt hàng + Biên bản giao nhận + HĐ đã ký (PDF) — 1 file .zip'],
};
function Tile({ k, onClick, busy, done, hint }: { k: DocKind | 'all'; onClick: () => void; busy?: boolean; done?: { at: string; n: number } | null; hint?: string }) {
  const [ic, l, t] = ICON[k];
  return <button type="button" disabled={busy} onClick={onClick} title={t + (done ? `\nĐã tải ${done.n} lần · lần cuối ${new Date(done.at).toLocaleString('vi-VN')}` : '') + (hint ? '\n' + hint : '')}
    className={cx('relative flex h-[46px] w-[46px] flex-col items-center justify-center rounded-xl border text-center transition hover:-translate-y-0.5 hover:shadow-md disabled:opacity-50',
      k === 'all' ? 'border-brand-300 bg-gradient-to-b from-brand-50 to-white' : done ? 'border-emerald-300 bg-emerald-50/70' : 'border-ink-200 bg-white hover:border-brand-400')}>
    <span className="text-[19px] leading-none">{busy ? '⏳' : ic}</span><span className={cx('mt-0.5 text-[9.5px] font-bold leading-none', k === 'all' ? 'text-brand-800' : 'text-ink-700')}>{l}</span>
    {done && <span className="absolute -right-1 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-emerald-500 px-0.5 text-[9px] font-bold text-white">✓</span>}
  </button>;
}

/** Biểu tượng chứng từ + trạng thái hồ sơ trên từng HĐ. st = vết hồ sơ (undefined → tự tải) */
export function DocBtns({ v, st, onChanged, compact }: { v: { id: string; buyer_name?: string; so_hd?: string; tax_code?: string }; st?: DocSt | null; onChanged?: () => void; compact?: boolean }) {
  const a = useApp(); const d = useDocs(); const [info, setInfo] = useState<DocInv | null>(null);
  const [own, setOwn] = useState<DocSt | null | undefined>(st); const [menu, setMenu] = useState(false);
  useEffect(() => { setOwn(st); }, [st]);
  const refresh = async () => { if (onChanged) onChanged(); const m = await loadDocStates([v.id]).catch(() => ({} as Record<string, DocSt>)); setOwn(m[v.id] || null); };
  useEffect(() => { if (st === undefined) refresh(); }, [v.id]);
  const log = (kinds: string[]) => mark([v.id], 'tai', kinds).then(refresh).catch(() => null);
  const one = (k: DocKind) => d.start([v.id], async ([x]) => { setInfo(x); const kk = k === 'hdmb' && hasHdnt(x) ? 'hdnt' : k; downloadBlob(docFile(x, kk), await makeDocx(x, kk)); log([kk]); }, k !== 'ddh');
  // Bản 38: Cả bộ = ĐĐH + BBGN + HĐ đã ký (PDF lấy từ Drive; chưa có thì máy chủ tự tải từ meInvoice theo mã tra cứu)
  const [pdfBusy, setPdfBusy] = useState(false);
  const all = async () => {
    setPdfBusy(true); let pdf: Blob | null = null;
    try { pdf = await kyPdf(a.settings.drive, v.id); }
    catch (e: any) {
      setPdfBusy(false);
      const ok = await ask({ title: 'Chưa lấy được HĐ đã ký', ok: 'Vẫn tải ĐĐH + BBGN', message: <>Không tự tải được PDF HĐ đã ký: <b>{e?.message || String(e)}</b><br /><br />
        Bấm vào <b>mã tra cứu</b> (ô xanh) để tải HĐ trên meInvoice, hoặc báo kế toán kiểm tra mã tra cứu. Bạn có muốn tải trước ĐĐH + BBGN không?</> });
      if (!ok) return;
    } finally { setPdfBusy(false); }
    d.start([v.id], async ([x]) => { setInfo(x); const kinds: DocKind[] = ['ddh', 'bbgn'];
      const { blob } = await makeBundle([x], kinds, undefined, pdf ? { [x.id]: pdf } : {}); downloadBlob(`Chung_tu_HD${soDon(x)}.zip`, blob); log(pdf ? [...kinds, 'hd'] : kinds); }, true);
  };
  const acc = useIsAcc(); const [hoSo, setHoSo] = useState(false); const [scanUp, setScanUp] = useState(false);
  const act = async (x: string, url: string | null = null) => { setMenu(false); try { await mark([v.id], x, [], url); toast.ok(x === 'gui' ? 'Đã đánh dấu: đã gửi khách' : x === 'ky' ? 'Đã lưu: hồ sơ có bản ký' : 'Đã bỏ đánh dấu'); refresh(); } catch (e: any) { toast.err(e); } };
  const s = own || null; const hs = hsOf(s); const isNt = info ? hasHdnt(info) : null;
  return <div className={cx('flex flex-col gap-1.5', compact && 'w-[214px]')} onClick={e => e.stopPropagation()}>
    <div className="flex items-center gap-1.5">
      <Tile k="ddh" busy={!!d.busy} done={s?.tai?.ddh} onClick={() => one('ddh')} />
      <Tile k="bbgn" busy={!!d.busy} done={s?.tai?.bbgn} onClick={() => one('bbgn')} />
      <Tile k={isNt ? 'hdnt' : 'hdmb'} busy={!!d.busy} done={s?.tai?.hdmb || s?.tai?.hdnt} onClick={() => one('hdmb')} hint="Khách đã ký HĐ nguyên tắc → tải HĐ nguyên tắc; chưa ký → HĐ mua bán" />
      <Tile k="all" busy={!!d.busy || pdfBusy} onClick={all} done={s?.tai?.hd && s?.tai?.ddh && s?.tai?.bbgn ? s.tai.hd : null} />
    </div>
    <div className="relative flex items-center gap-1">
      <span className={cx('inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-semibold', HS[hs][2])} title={s ? [s.gui_at && 'Gửi: ' + new Date(s.gui_at).toLocaleString('vi-VN') + ' · ' + a.personName(s.gui_by || ''), s.ky_at && 'Bản ký: ' + new Date(s.ky_at).toLocaleString('vi-VN') + ' · ' + a.personName(s.ky_by || '')].filter(Boolean).join('\n') : ''}>
        <span>{HS[hs][1]}</span>{HS[hs][0]}</span>
      {s?.ky_url && <a href={s.ky_url} target="_blank" rel="noreferrer" title="Mở bản ký đã lưu" className="text-[13px]">📎</a>}
      <button type="button" className="ml-auto rounded-md px-1.5 text-[13px] font-bold text-ink-500 hover:bg-ink-100" title="Cập nhật trạng thái hồ sơ" onClick={() => setMenu(!menu)}>⋯</button>
      {menu && <><div className="fixed inset-0 z-30" onClick={() => setMenu(false)} />
        <div className="absolute right-0 top-6 z-40 w-60 overflow-hidden rounded-xl border border-ink-200 bg-white text-xs shadow-xl">
          {[!s?.gui_at && ['gui', '✉ Đã gửi bộ chứng từ cho khách'], acc && ['up', '📎 Tải bản scan lên (Drive)'], ['hoso', '🗂 Hồ sơ scan · bản cứng'], !s?.ky_at && ['ky', '✔ Đã nhận bản ký (chưa scan)'],
            s?.gui_at && !s?.ky_at && ['bo_gui', '↶ Bỏ đánh dấu đã gửi'], s?.ky_at && ['bo_ky', '↶ Bỏ đánh dấu đã ký']].filter(Boolean).map(x => { const [k, l] = x as [string, string];
            return <button key={k} className="block w-full px-3 py-2 text-left hover:bg-brand-50" onClick={() => (k === 'up' ? (setMenu(false), setScanUp(true)) : k === 'hoso' ? (setMenu(false), setHoSo(true)) : act(k))}>{l}</button>; })}
        </div></>}
    </div>
    <HoSoChip s={s?.scan} onClick={() => setHoSo(true)} />
    {hoSo && <HoSoModal inv={{ id: v.id, so_hd: v.so_hd, buyer_name: v.buyer_name, tax_code: v.tax_code, ngay_hd: (v as any).ngay_hd }} onClose={() => setHoSo(false)} onChanged={refresh} />}
    {scanUp && <ScanUpload target={{ inv: { id: v.id, so_hd: v.so_hd, buyer_name: v.buyer_name, tax_code: v.tax_code, ngay_hd: (v as any).ngay_hd } }} defKinds={s?.scan?.thieu?.length ? s.scan.thieu : undefined} onClose={() => setScanUp(false)} onDone={() => { setScanUp(false); refresh(); }} />}
    {d.modal}</div>;
}

/** Thanh xuất hàng loạt cho danh sách HĐ đã ký */
export function DocsBar({ rows, sel, setSel, onChanged, onShip }: { rows: any[]; sel: Record<string, boolean>; setSel: (x: Record<string, boolean>) => void; onChanged?: () => void; onShip?: (ids: string[]) => void }) {
  const [kinds, setKinds] = useState<DocKind[]>(() => { try { const k = JSON.parse(localStorage.getItem('nt_doc_kinds') || 'null'); return Array.isArray(k) && k.length ? k : ['ddh', 'bbgn', 'hdmb']; } catch { return ['ddh', 'bbgn', 'hdmb']; } });
  const tog = (k: DocKind) => { const n = kinds.includes(k) ? kinds.filter(x => x !== k) : [...kinds, k]; setKinds(n); try { localStorage.setItem('nt_doc_kinds', JSON.stringify(n)); } catch { /* */ } };
  const a = useApp(); const d = useDocs(); const ids = rows.filter(r => sel[r.id]).map(r => r.id); const { busy, run } = useAction(); const acc = useIsAcc();
  const [withPdf, setWithPdf] = useState(() => { try { return localStorage.getItem('nt_doc_pdf') !== '0'; } catch { return true; } });
  const togPdf = () => { setWithPdf(!withPdf); try { localStorage.setItem('nt_doc_pdf', withPdf ? '0' : '1'); } catch { /* */ } };
  const go = () => { if (!ids.length) return toast.info('Tick HĐ cần xuất (hoặc “Chọn tất cả”)'); if (!kinds.length && !withPdf) return toast.info('Chọn ít nhất 1 loại chứng từ');
    d.start(ids, async invs => {
      const pdf: Record<string, Blob> = {}; const miss: string[] = [];
      if (withPdf) for (const v of invs) { try { pdf[v.id] = await kyPdf(a.settings.drive, v.id); } catch { miss.push(soDon(v)); } }
      const { blob, n } = await makeBundle(invs, kinds, undefined, pdf); if (!n) { toast.info('Không có chứng từ nào cần tạo (HĐ mua bán chỉ cho khách chưa ký HĐ nguyên tắc)'); return; }
      downloadBlob(`Chung_tu_${invs.length}HD_${new Date().toISOString().slice(0, 10)}.zip`, blob); toast.ok(`Đã tạo ${n} file chứng từ cho ${invs.length} HĐ`);
      if (miss.length) toast.err(`Chưa lấy được PDF HĐ đã ký: ${miss.slice(0, 8).join(', ')}${miss.length > 8 ? '…' : ''} — bấm mã tra cứu để tải tay`);
      for (const v of invs) await mark([v.id], 'tai', [...kinds.filter(k => (k === 'hdmb' ? !hasHdnt(v) : k === 'hdnt' ? hasHdnt(v) : true)), ...(pdf[v.id] ? ['hd'] : [])]).catch(() => null);
      onChanged?.(); }, kinds.some(k => k !== 'ddh')); };
  const allOn = rows.length > 0 && rows.every(r => sel[r.id]);
  return <Card className="mb-3" bodyClass="flex flex-wrap items-center gap-2 px-3 py-2 text-xs">
    <label className="flex items-center gap-1.5 font-semibold"><input type="checkbox" className="h-4 w-4" checked={allOn} onChange={e => setSel(e.target.checked ? Object.fromEntries(rows.map(r => [r.id, true])) : {})} /> Chọn tất cả đang lọc ({rows.length})</label>
    <span className="text-ink-300">|</span>
    {(['ddh', 'bbgn', 'hdmb', 'hdnt'] as DocKind[]).map(k => <button key={k} onClick={() => tog(k)} title={DOC_NAME[k]} className={cx('flex items-center gap-1 rounded-full border px-2.5 py-1 font-semibold', kinds.includes(k) ? 'border-brand-500 bg-brand-50 text-brand-800' : 'border-ink-200 text-ink-400')}>
      <span className="text-sm">{ICON[k][0]}</span>{DOC_NAME[k]}{k === 'hdmb' ? ' (chưa ký HĐNT)' : k === 'hdnt' ? ' (1 bản/khách)' : ''}{kinds.includes(k) ? ' ✓' : ''}</button>)}
    <button onClick={togPdf} title="HĐ đã ký (PDF) — lấy từ Drive / tự tải từ meInvoice theo mã tra cứu" className={cx('flex items-center gap-1 rounded-full border px-2.5 py-1 font-semibold', withPdf ? 'border-brand-500 bg-brand-50 text-brand-800' : 'border-ink-200 text-ink-400')}>
      <span className="text-sm">📄</span>HĐ đã ký (PDF){withPdf ? ' ✓' : ''}</button>
    <div className="ml-auto flex items-center gap-2">
      {acc && <Button size="sm" disabled={!ids.length} loading={busy} title="Đánh dấu đã cất bản cứng (ghi vị trí tủ / bìa) cho các HĐ đã chọn" onClick={() => run(async () => {
        const vt = await ask({ title: `Cất bản cứng · ${ids.length} HĐ`, message: 'Ghi vị trí để lần sau tìm nhanh.', input: { label: 'Vị trí cất', placeholder: 'VD: Tủ 1 · Bìa T11/2026', required: true }, ok: 'Lưu' }); if (!vt) return;
        const n = await db.rpc<number>('out_doc_cung', { p_ids: ids, p_vi_tri: vt, p_undo: false }); toast.ok(`Đã ghi ${n} HĐ: cất bản cứng tại ${vt}`); onChanged?.(); })}>🗄 Cất bản cứng</Button>}
      {onShip && <Button size="sm" variant="dark" disabled={!ids.length} onClick={() => onShip(ids)} title="Tạo phiếu chuyển phát (gom theo khách) — theo dõi ngày khách nhận và thu về bản ký">📦 Gửi chuyển phát{ids.length ? ` (${ids.length})` : ''}</Button>}
      <Button size="sm" disabled={!ids.length} loading={busy} onClick={() => run(async () => { await mark(ids, 'gui'); onChanged?.(); }, `Đã đánh dấu ${ids.length} HĐ: đã gửi khách`)}>✉ Đã gửi khách</Button>
      <Button size="sm" variant="primary" loading={!!d.busy} disabled={!ids.length} onClick={go}>⬇ Xuất {ids.length || ''} HĐ (.zip)</Button></div>
    {d.busy && <span className="w-full text-brand-700">{d.busy}</span>}{d.modal}</Card>;
}

/** Tab "Đã ký" của sale: lọc theo trạng thái hồ sơ + chọn nhiều + cột chứng từ */
export function KyList({ data, render, onShip }: { data: any[] | null | undefined; onShip?: (ids: string[], clear: () => void) => void; render: (rows: any[], sel: Record<string, boolean>, onSel: (id: string, on: boolean) => void, st: Record<string, DocSt>, reload: () => void) => React.ReactNode }) {
  const [q, setQ] = useState(''); const [sel, setSel] = useState<Record<string, boolean>>({}); const [hs, setHs] = useState<HsKey | ''>(''); const [sc, setSc] = useState<HsScanKey | 'cung_chua' | ''>('');
  const [st, setSt] = useState<Record<string, DocSt>>({}); const [rev, setRev] = useState(0); const reload = () => setRev(x => x + 1);
  const ids = useMemo(() => (data || []).map(v => v.id), [data]);
  useEffect(() => { let on = true; loadDocStates(ids).then(m => on && setSt(m)).catch(() => null); return () => { on = false; }; }, [ids.join(), rev]);
  const base = useMemo(() => { const qq = q.trim().toLowerCase(); return (data || []).filter(v => !qq || [v.code, v.buyer_name, v.tax_code, v.mds, v.hds, v.so_hd, v.mas].some(x => String(x || '').toLowerCase().includes(qq))); }, [data, q]);
  const cnt = useMemo(() => { const c: Record<string, number> = { chua: 0, tai: 0, gui: 0, ky: 0 }; base.forEach(v => { c[hsOf(st[v.id])]++; }); return c; }, [base, st]);
  const cntSc = useMemo(() => { const c: Record<string, number> = { chua: 0, thieu: 0, du: 0, cung_chua: 0 }; base.forEach(v => { c[scanKey(st[v.id]?.scan)]++; if (!st[v.id]?.scan?.cung_at) c.cung_chua++; }); return c; }, [base, st]);
  const rows = useMemo(() => base.filter(v => (!hs || hsOf(st[v.id]) === hs) && (!sc || (sc === 'cung_chua' ? !st[v.id]?.scan?.cung_at : scanKey(st[v.id]?.scan) === sc))), [base, hs, sc, st]);
  return <>
    <div className="mb-2 flex flex-wrap items-center gap-2"><Input className="max-w-sm" placeholder="🔎 Tìm số HĐ, ID đơn (cả đơn), tên / MST khách…" value={q} onChange={e => setQ(e.target.value)} />
      <span className="text-xs text-ink-500">Gõ ID đơn → “Chọn tất cả đang lọc” để xuất chứng từ cả đơn.</span></div>
    <div className="mb-2 flex flex-wrap gap-1.5 text-xs">
      <button onClick={() => setHs('')} className={cx('rounded-full border px-3 py-1 font-semibold', !hs ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-700')}>Tất cả {base.length}</button>
      {(Object.keys(HS) as HsKey[]).map(k => <button key={k} onClick={() => setHs(k)} className={cx('rounded-full border px-3 py-1 font-semibold', hs === k ? 'ring-2 ring-brand-400' : '', HS[k][2])}>{HS[k][1]} {HS[k][0]} · {cnt[k]}</button>)}</div>
    {/* Bản 41: lưu trữ hồ sơ — bản scan + bản cứng */}
    <div className="mb-2 flex flex-wrap items-center gap-1.5 text-xs"><span className="font-semibold text-ink-500">Lưu trữ:</span>
      <button onClick={() => setSc('')} className={cx('rounded-full border px-3 py-1 font-semibold', !sc ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-700')}>Tất cả</button>
      {(Object.keys(HS_SCAN) as HsScanKey[]).map(k => <button key={k} onClick={() => setSc(sc === k ? '' : k)} className={cx('rounded-full border px-3 py-1 font-semibold', sc === k ? 'ring-2 ring-brand-400' : '', HS_SCAN[k][1])}>🗂 {HS_SCAN[k][0]} · {cntSc[k]}</button>)}
      <button onClick={() => setSc(sc === 'cung_chua' ? '' : 'cung_chua')} className={cx('rounded-full border border-ink-200 bg-white px-3 py-1 font-semibold text-ink-700', sc === 'cung_chua' && 'ring-2 ring-brand-400')}>🗄 Chưa cất bản cứng · {cntSc.cung_chua}</button></div>
    <DocsBar rows={rows} sel={sel} setSel={setSel} onChanged={reload} onShip={onShip ? ids => onShip(ids, () => { setSel({}); reload(); }) : undefined} />
    {render(rows, sel, (id, on) => setSel(x => ({ ...x, [id]: on })), st, reload)}
  </>;
}

/** Bản 38: nút tải PDF HĐ đã ký (dưới mã tra cứu). File lưu sẵn trên Google Drive công ty; chưa có thì máy chủ tự tải từ meInvoice rồi lưu */
export function KyBtn({ v, className }: { v: { id: string; so_hd?: string | null; code?: string; buyer_name?: string | null }; className?: string }) {
  const a = useApp(); const [busy, setBusy] = useState(false);
  const go = async (e: React.MouseEvent) => {
    e.stopPropagation(); setBusy(true);
    try { const b = await kyPdf(a.settings.drive, v.id); downloadBlob(kyName(v), b); mark([v.id], 'tai', ['hd']).catch(() => null); }
    catch (er: any) { toast.err((er?.message || String(er)) + ' — bấm mã tra cứu để tải tay'); } finally { setBusy(false); }
  };
  return <button type="button" disabled={busy} onClick={go} title="Tải PDF HĐ đã ký (lưu sẵn trên Google Drive công ty)"
    className={cx('inline-flex items-center gap-1 rounded-md bg-white px-2 py-0.5 text-xs font-semibold text-brand-700 ring-1 ring-brand-200 hover:bg-brand-50 disabled:opacity-60', className)}>{busy ? '⏳ Đang tải…' : '⬇ Tải HĐ (PDF)'}</button>;
}
