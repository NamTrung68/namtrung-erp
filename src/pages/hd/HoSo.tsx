// Bản 41 — Lưu trữ hồ sơ HĐ: bản scan (mềm, lưu Google Drive công ty) + bản cứng (vị trí cất)
//  · Tải scan: PDF có sẵn, hoặc chụp / chọn nhiều ảnh → ERP gộp thành 1 PDF → Drive: Ho so khach hang/<MST> - <Tên>/HD <năm> | Hop dong NT-MB
//  · 1 file có thể gồm nhiều loại giấy (scan cả bộ). Đủ hồ sơ = HĐ đã ký + ĐĐH + BBGN + HĐ nguyên tắc (pháp nhân) hoặc HĐ mua bán
//  · Tải scan của HĐ đang chuyển phát → ERP tự xác nhận "Đã thu về"
import React, { useEffect, useRef, useState } from 'react';
import { Badge, Button, Empty, Input, Loading, Modal, ask, cx, toast, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { driveReady, driveUploadMany, scanFile } from '../../lib/drive';
import { downloadBlob, fmtDate, fmtDateTime } from '../../lib/format';
import { imagesToPdf, SCAN_KIND, SCAN_ORDER, scanFolder, scanName, type ScanKind } from '../../lib/hoso';
import { useApp } from '../../state';

export interface ScanSt { invoice_id: string; co: ScanKind[]; can: ScanKind[]; thieu: ScanKind[]; du: boolean; n: number; co_hdnt: boolean; cung_at: string | null; cung_vi_tri: string | null }
export const useIsAcc = () => { const a = useApp(); return a.isAdmin || a.has('ke_toan', 'bgd'); };
const kName = (k: string) => SCAN_KIND[k as ScanKind]?.[0] || k;
export const kindsTxt = (ks: string[]) => SCAN_ORDER.filter(k => ks.includes(k)).map(k => SCAN_KIND[k][1]).join(' · ');

export async function loadScanSt(ids: string[]): Promise<Record<string, ScanSt>> {
  const out: Record<string, ScanSt> = {};
  for (let i = 0; i < ids.length; i += 200) {
    const part = ids.slice(i, i + 200); if (!part.length) continue;
    ((await db.rpc<ScanSt[]>('ho_so_status', { p_ids: part })) || []).forEach(r => { out[r.invoice_id] = r; });
  }
  return out;
}
export type HsScanKey = 'chua' | 'thieu' | 'du';
export const scanKey = (s?: ScanSt | null): HsScanKey => (!s || (!s.n && !s.co.length) ? 'chua' : s.du ? 'du' : 'thieu');
export const HS_SCAN: Record<HsScanKey, [string, string]> = {
  chua: ['Chưa có bản scan', 'border-ink-200 bg-white text-ink-500'], thieu: ['Scan còn thiếu', 'border-amber-300 bg-amber-50 text-amber-800'], du: ['Đủ hồ sơ scan', 'border-emerald-300 bg-emerald-50 text-emerald-800'],
};

/** Chip tình trạng hồ sơ (mềm + cứng) — bấm mở Hồ sơ HĐ */
export function HoSoChip({ s, onClick }: { s?: ScanSt | null; onClick: () => void }) {
  const k = scanKey(s);
  return <button type="button" onClick={e => { e.stopPropagation(); onClick(); }} title={(s ? `Cần: ${kindsTxt(s.can)}\nĐã có: ${kindsTxt(s.co) || '—'}` : '') + (s?.cung_vi_tri ? `\nBản cứng: ${s.cung_vi_tri}` : '\nBản cứng: chưa cất')}
    className={cx('inline-flex max-w-full items-center gap-1 truncate rounded-full border px-2 py-0.5 text-[11px] font-semibold hover:ring-2 hover:ring-brand-200', HS_SCAN[k][1])}>
    🗂 {k === 'thieu' ? 'Thiếu ' + kindsTxt(s!.thieu) : HS_SCAN[k][0]}{s?.cung_at ? <span title={s.cung_vi_tri || ''}> · 🗄</span> : null}</button>;
}

// ---------------- Tải bản scan ----------------
type Target = { inv?: { id: string; so_hd?: string | null; buyer_name?: string | null; tax_code?: string | null; ngay_hd?: string | null }; buyer?: { id: string; name: string; tax_code: string; ma_hdnt?: string | null } };
interface Item { key: string; files: File[]; pdf: boolean; kinds: ScanKind[] }
const ACCEPT = 'application/pdf,image/*';
/** Tải bản scan cho 1 HĐ hoặc 1 pháp nhân (HĐ nguyên tắc / HĐ mua bán). defKinds = loại mặc định cho file mới */
export function ScanUpload({ target, defKinds, onClose, onDone }: { target: Target; defKinds?: ScanKind[]; onClose: () => void; onDone: (n: number) => void }) {
  const a = useApp(); const [items, setItems] = useState<Item[]>([]); const [step, setStep] = useState(''); const { busy, run } = useAction();
  const pick = useRef<HTMLInputElement>(null); const cam = useRef<HTMLInputElement>(null);
  const allow: ScanKind[] = target.inv ? ['hd', 'ddh', 'bbgn', 'hdmb', 'khac'] : ['hdnt', 'hdmb', 'khac'];
  const def = (defKinds?.filter(k => allow.includes(k)).length ? defKinds.filter(k => allow.includes(k)) : target.inv ? ['hd', 'ddh', 'bbgn'] : [target.buyer?.ma_hdnt ? 'hdnt' : 'hdmb']) as ScanKind[];
  const add = (fl: FileList | null, merge: boolean) => {
    if (!fl?.length) return; const fs = Array.from(fl); const pdfs = fs.filter(f => f.type === 'application/pdf' || /\.pdf$/i.test(f.name)); const imgs = fs.filter(f => !pdfs.includes(f) && f.type.startsWith('image/'));
    const bad = fs.length - pdfs.length - imgs.length; if (bad) toast.err(`${bad} file không phải PDF / ảnh — bỏ qua`);
    setItems(x => {
      const n = [...x, ...pdfs.map(f => ({ key: Math.random().toString(36).slice(2), files: [f], pdf: true, kinds: [...def] }))];
      // ảnh: gộp vào file ảnh đang soạn (chụp tiếp trang sau) hoặc tạo file mới
      const last = n.length ? n[n.length - 1] : null;
      if (imgs.length) { if (merge && last && !last.pdf) last.files = [...last.files, ...imgs]; else n.push({ key: Math.random().toString(36).slice(2), files: imgs, pdf: false, kinds: [...def] }); }
      return [...n];
    });
  };
  const tog = (it: Item, k: ScanKind) => setItems(x => x.map(y => (y.key === it.key ? { ...y, kinds: y.kinds.includes(k) ? y.kinds.filter(z => z !== k) : [...y.kinds, k] } : y)));
  const del = (it: Item, i?: number) => setItems(x => x.flatMap(y => (y.key !== it.key ? [y] : i === undefined || y.files.length <= 1 ? [] : [{ ...y, files: y.files.filter((_, j) => j !== i) }])));
  const mst = target.inv?.tax_code || target.buyer?.tax_code || ''; const ten = target.inv?.buyer_name || target.buyer?.name || '';
  const save = () => run(async () => {
    if (!driveReady(a.settings.drive)) throw new Error('Chưa cấu hình Google Drive — Admin bật ở Cấu hình → Sao lưu Google Drive');
    if (items.some(it => !it.kinds.length)) throw new Error('Mỗi file cần chọn ít nhất 1 loại giấy tờ');
    const blobs: { blob: Blob; trang: number }[] = [];
    for (let i = 0; i < items.length; i++) { const it = items[i];
      if (it.pdf) blobs.push({ blob: it.files[0], trang: 0 });
      else { setStep(`Đang gộp ảnh thành PDF (file ${i + 1}/${items.length})…`); blobs.push({ blob: await imagesToPdf(it.files, (k, n) => setStep(`Đang gộp ảnh ${k}/${n} (file ${i + 1}/${items.length})…`)), trang: it.files.length }); } }
    const big = blobs.findIndex(b => b.blob.size > 20 * 1024 * 1024); if (big >= 0) throw new Error(`File ${big + 1} quá 20MB — scan độ phân giải thấp hơn hoặc tách file`);
    setStep('Đang lưu lên Google Drive…');
    const at = new Date();
    const res = await driveUploadMany(a.settings.drive, items.map((it, i) => ({ blob: blobs[i].blob, folder: scanFolder({ mst, ten, kinds: it.kinds, ngay: target.inv?.ngay_hd }),
      name: scanName({ so_hd: target.inv?.so_hd, ma_hdnt: target.inv ? null : target.buyer?.ma_hdnt, kinds: it.kinds, ext: 'pdf', at: new Date(at.getTime() + i * 60000) }) })), (d, n) => setStep(`Đang lưu lên Google Drive ${d}/${n}…`));
    let ok = 0, thu = 0; const errs: string[] = [];
    for (let i = 0; i < res.length; i++) { const r = res[i]; if (!r.ok) { errs.push(`File ${i + 1}: ${r.error}`); continue; }
      try { const x = await db.rpc<any>('ho_so_scan_add', { p: { invoice_id: target.inv?.id || null, buyer_id: target.buyer?.id || null, kinds: items[i].kinds, drive_id: r.id, url: r.url,
        file_name: scanName({ so_hd: target.inv?.so_hd, ma_hdnt: target.buyer?.ma_hdnt, kinds: items[i].kinds, ext: 'pdf', at }), size_kb: Math.round(blobs[i].blob.size / 1024), so_trang: blobs[i].trang || null } });
        ok++; thu += Number(x?.thu || 0); } catch (e: any) { errs.push(`File ${i + 1}: ${e.message}`); } }
    setStep('');
    if (errs.length) toast.err(`Lưu ${ok}/${res.length} file — ${errs.slice(0, 3).join(' · ')}`); else toast.ok(`Đã lưu ${ok} bản scan lên Drive${thu ? ' — phiếu chuyển phát tự chuyển “Đã thu về”' : ''}`);
    if (ok) onDone(ok);
  });
  const nFile = items.length;
  return <Modal open size="lg" onClose={onClose} title={`📎 Tải bản scan · ${target.inv ? 'HĐ ' + (target.inv.so_hd || '') : 'Pháp nhân'} · ${ten}`} footer={<>
    {step && <span className="mr-auto text-xs text-brand-700">{step}</span>}
    <Button onClick={onClose}>Hủy</Button><Button variant="primary" loading={busy} disabled={!nFile} onClick={save}>⇪ Lưu {nFile || ''} file lên Drive</Button></>}>
    <p className="mb-3 rounded-xl bg-brand-50 px-3 py-2 text-xs text-brand-900">File lưu vào Google Drive công ty: <b>ERP_NAMTRUNG/{scanFolder({ mst, ten, kinds: target.inv ? ['hd'] : ['hdnt'], ngay: target.inv?.ngay_hd })}</b>. Scan được tờ nào lưu tờ đó — ERP tự đối chiếu còn thiếu loại nào.
      {target.inv ? ' HĐ đang chuyển phát chưa thu về sẽ tự chuyển “Đã thu về”.' : ' HĐ nguyên tắc lưu 1 lần, dùng cho mọi HĐ của pháp nhân này.'}</p>
    <div className="mb-3 flex flex-wrap gap-2">
      <Button onClick={() => pick.current?.click()}>📁 Chọn file PDF / ảnh</Button>
      <Button onClick={() => cam.current?.click()}>📷 Chụp trang{items.length && !items[items.length - 1].pdf ? ' tiếp (gộp vào file đang soạn)' : ''}</Button>
      <input ref={pick} type="file" multiple accept={ACCEPT} className="hidden" onChange={e => { add(e.target.files, false); e.target.value = ''; }} />
      <input ref={cam} type="file" accept="image/*" capture="environment" className="hidden" onChange={e => { add(e.target.files, true); e.target.value = ''; }} /></div>
    {!nFile ? <Empty>Chưa chọn file. Nhiều ảnh chọn 1 lần = 1 file PDF nhiều trang; chụp bằng điện thoại thì bấm “Chụp trang” lần lượt từng trang.</Empty> :
      <div className="space-y-2">{items.map((it, i) => <div key={it.key} className={cx('rounded-xl border p-2.5', it.kinds.length ? 'border-ink-200' : 'border-amber-300 bg-amber-50/50')}>
        <div className="flex flex-wrap items-center gap-2 text-sm"><b>File {i + 1}</b>
          {it.pdf ? <span className="text-xs text-ink-600">📄 {it.files[0].name} · {Math.round(it.files[0].size / 1024)} KB</span> : <span className="text-xs text-ink-600">🖼 {it.files.length} ảnh → gộp 1 PDF {it.files.length} trang</span>}
          <button className="ml-auto text-xs text-red-600 hover:underline" onClick={() => del(it)}>Bỏ file</button></div>
        {!it.pdf && <div className="mt-1 flex flex-wrap gap-1">{it.files.map((f, j) => <span key={j} className="inline-flex items-center gap-1 rounded bg-ink-100 px-1.5 py-0.5 text-[11px]">Trang {j + 1}<button className="text-ink-400 hover:text-red-600" onClick={() => del(it, j)}>×</button></span>)}</div>}
        <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs"><span className="text-ink-500">File gồm:</span>
          {allow.map(k => <button key={k} onClick={() => tog(it, k)} className={cx('rounded-full border px-2.5 py-0.5 font-semibold', it.kinds.includes(k) ? 'border-brand-500 bg-brand-50 text-brand-800' : 'border-ink-200 text-ink-400')}>{kName(k)}{it.kinds.includes(k) ? ' ✓' : ''}</button>)}
          {!it.kinds.length && <span className="font-semibold text-amber-700">← chọn loại</span>}</div>
      </div>)}</div>}
  </Modal>;
}

// ---------------- Xem file ----------------
function useScanView() {
  const a = useApp(); const [busy, setBusy] = useState('');
  const open = async (s: any, dl = false) => {
    setBusy(s.id);
    try { const b = await scanFile(a.settings.drive, s.id);
      if (dl) downloadBlob(s.file_name || 'scan.pdf', b); else { const u = URL.createObjectURL(b); window.open(u, '_blank'); setTimeout(() => URL.revokeObjectURL(u), 60000); } }
    catch (e: any) { toast.err(e); } finally { setBusy(''); }
  };
  return { open, busy };
}
function ScanRows({ rows, onDel, showHd }: { rows: any[]; onDel?: (s: any) => void; showHd?: boolean }) {
  const a = useApp(); const v = useScanView();
  if (!rows.length) return <div className="px-3 py-3 text-xs text-ink-400">Chưa có bản scan.</div>;
  return <div className="divide-y divide-ink-100">{rows.map(s => <div key={s.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 text-sm">
    <div className="flex flex-wrap gap-1">{SCAN_ORDER.filter(k => s.kinds.includes(k)).map(k => <Badge key={k} color={k === 'hdnt' || k === 'hdmb' ? 'purple' : 'blue'}>{kName(k)}</Badge>)}</div>
    {showHd && s.so_hd && <span className="rounded-md bg-ink-900 px-1.5 py-0.5 text-[11px] font-semibold text-white">HĐ {s.so_hd}</span>}
    <span className="min-w-[140px] flex-1 truncate text-xs text-ink-600" title={s.file_name}>{s.file_name}{s.so_trang ? ` · ${s.so_trang} trang` : ''}{s.size_kb ? ` · ${s.size_kb} KB` : ''}</span>
    <span className="text-[11px] text-ink-400">{a.personName(s.uploaded_by)} · {fmtDateTime(s.uploaded_at)}</span>
    <div className="flex items-center gap-1">
      <Button size="sm" loading={v.busy === s.id} onClick={() => v.open(s)}>👁 Xem</Button>
      <Button size="sm" variant="ghost" disabled={!!v.busy} onClick={() => v.open(s, true)}>⬇</Button>
      {s.url && <a className="px-1 text-xs text-brand-700 hover:underline" href={s.url} target="_blank" rel="noreferrer" title="Mở trong Google Drive (chỉ tài khoản có quyền Drive)">Drive ↗</a>}
      {onDel && <button className="px-1 text-xs text-red-600 hover:underline" onClick={() => onDel(s)}>Gỡ</button>}</div>
  </div>)}</div>;
}

// ---------------- Hồ sơ 1 HĐ ----------------
export function HoSoModal({ inv, onClose, onChanged }: { inv: { id: string; so_hd?: string | null; buyer_name?: string | null; tax_code?: string | null; ngay_hd?: string | null; code?: string }; onClose: () => void; onChanged?: () => void }) {
  const acc = useIsAcc(); const { busy, run } = useAction(); const [rev, setRev] = useState(0); const [up, setUp] = useState(false);
  const { data, loading } = useLoad(async () => {
    const [st, list] = await Promise.all([db.rpc<ScanSt[]>('ho_so_status', { p_ids: [inv.id] }), db.rpc<any[]>('ho_so_list', { p: { invoice_id: inv.id } })]);
    return { st: (st || [])[0] || null, list: list || [] };
  }, [inv.id, rev]);
  const [vt, setVt] = useState(''); useEffect(() => { setVt(data?.st?.cung_vi_tri || ''); }, [data?.st?.cung_vi_tri]);
  const changed = () => { setRev(x => x + 1); onChanged?.(); };
  const st = data?.st; const list = data?.list || [];
  const del = (s: any) => run(async () => { if (!(await ask({ title: 'Gỡ bản scan khỏi ERP?', message: `${kindsTxt(s.kinds)} · ${s.file_name || ''}. File trên Google Drive vẫn giữ nguyên.`, ok: 'Gỡ', danger: true }))) return;
    await db.rpc('ho_so_scan_del', { p_id: s.id }); changed(); }, 'Đã gỡ bản scan');
  const cung = (undo: boolean) => run(async () => { await db.rpc('out_doc_cung', { p_ids: [inv.id], p_vi_tri: vt, p_undo: undo }); changed(); }, undo ? 'Đã bỏ đánh dấu bản cứng' : 'Đã lưu vị trí bản cứng');
  return <Modal open size="lg" onClose={onClose} title={`🗂 Hồ sơ HĐ ${inv.so_hd || inv.code || ''} · ${inv.buyer_name || ''}`}>
    {loading && !data ? <Loading /> : <>
      <div className="mb-3 rounded-2xl border border-ink-200 p-3">
        <div className="mb-2 flex flex-wrap items-center gap-2 text-sm font-semibold">Bản mềm (scan) {st && <span className={cx('rounded-full border px-2 py-0.5 text-[11px]', HS_SCAN[scanKey(st)][1])}>{HS_SCAN[scanKey(st)][0]}</span>}
          {acc && <Button size="sm" variant="primary" className="ml-auto" onClick={() => setUp(true)}>📎 Tải bản scan</Button>}</div>
        <div className="flex flex-wrap gap-1.5">{(st?.can || []).map(k => { const co = st!.co.includes(k);
          return <span key={k} className={cx('inline-flex items-center gap-1 rounded-lg border px-2 py-1 text-xs font-semibold', co ? 'border-emerald-300 bg-emerald-50 text-emerald-800' : 'border-amber-300 bg-amber-50 text-amber-800')}>{co ? '✓' : '○'} {kName(k)}</span>; })}</div>
        {st && <p className="mt-1.5 text-[11px] text-ink-500">{st.co_hdnt ? 'Pháp nhân đã ký HĐ nguyên tắc → cần 1 bản scan HĐNT (lưu ở pháp nhân, dùng chung mọi HĐ), không cần HĐ mua bán.' : 'Pháp nhân chưa ký HĐ nguyên tắc → cần HĐ mua bán của HĐ này.'}</p>}
      </div>
      <div className="mb-3 overflow-hidden rounded-2xl border border-ink-200"><ScanRows rows={list} onDel={acc ? del : undefined} /></div>
      <div className="rounded-2xl border border-ink-200 p-3">
        <div className="mb-1 text-sm font-semibold">Bản cứng {st?.cung_at ? <Badge color="green">🗄 Đã cất · {fmtDate(st.cung_at)}</Badge> : <Badge>Chưa cất</Badge>}</div>
        {acc ? <div className="flex flex-wrap items-center gap-2"><Input className="max-w-xs" value={vt} onChange={e => setVt(e.target.value)} placeholder="Vị trí: VD Tủ 1 · Bìa T11/2026" />
          <Button size="sm" variant="primary" loading={busy} disabled={!vt.trim() || vt.trim() === (st?.cung_vi_tri || '')} onClick={() => cung(false)}>{st?.cung_at ? 'Lưu vị trí' : '🗄 Đã cất bản cứng'}</Button>
          {st?.cung_at && <button className="text-xs text-ink-500 underline" onClick={() => cung(true)}>Bỏ đánh dấu</button>}</div>
          : <div className="text-sm text-ink-600">{st?.cung_vi_tri || 'Kế toán chưa ghi vị trí cất.'}</div>}
      </div>
    </>}
    {up && <ScanUpload target={{ inv }} defKinds={st?.thieu?.length ? st.thieu : undefined} onClose={() => setUp(false)} onDone={() => { setUp(false); changed(); }} />}
  </Modal>;
}

// ---------------- Hồ sơ pháp nhân (HĐ nguyên tắc / mua bán) ----------------
export function BuyerHoSo({ buyer, onClose, onChanged }: { buyer: { id: string; name: string; tax_code: string; ma_hdnt?: string | null; ngay_hdnt?: string | null }; onClose: () => void; onChanged?: () => void }) {
  const acc = useIsAcc(); const { run } = useAction(); const [rev, setRev] = useState(0); const [up, setUp] = useState(false);
  const { data, loading } = useLoad(() => db.rpc<any[]>('ho_so_list', { p: { buyer_id: buyer.id } }), [buyer.id, rev]);
  const rows = data || []; const hopDong = rows.filter(s => s.cap === 'phap_nhan' || s.kinds.includes('hdmb') || s.kinds.includes('hdnt')); const hd = rows.filter(s => !hopDong.includes(s));
  const changed = () => { setRev(x => x + 1); onChanged?.(); };
  const del = (s: any) => run(async () => { if (!(await ask({ title: 'Gỡ bản scan khỏi ERP?', message: 'File trên Google Drive vẫn giữ nguyên.', ok: 'Gỡ', danger: true }))) return;
    await db.rpc('ho_so_scan_del', { p_id: s.id }); changed(); }, 'Đã gỡ');
  const coNt = rows.some(s => s.kinds.includes('hdnt') && s.cap === 'phap_nhan');
  return <Modal open size="lg" onClose={onClose} title={`🗂 Hồ sơ pháp nhân · ${buyer.name}`}>
    <div className="mb-3 flex flex-wrap items-center gap-2 text-sm"><span className="font-mono">{buyer.tax_code}</span>
      {buyer.ma_hdnt ? <Badge color={coNt ? 'green' : 'amber'}>HĐNT {buyer.ma_hdnt}{coNt ? ' · đã có scan' : ' · chưa có bản scan'}</Badge> : <Badge>Chưa ký HĐ nguyên tắc — mỗi HĐ cần HĐ mua bán</Badge>}
      {acc && <Button size="sm" variant="primary" className="ml-auto" onClick={() => setUp(true)}>📎 Tải scan {buyer.ma_hdnt ? 'HĐ nguyên tắc' : 'HĐ mua bán / hợp đồng'}</Button>}</div>
    {loading && !data ? <Loading /> : <>
      <div className="mb-1 text-xs font-semibold text-ink-600">Hợp đồng nguyên tắc / mua bán ({hopDong.length})</div>
      <div className="mb-3 overflow-hidden rounded-2xl border border-ink-200"><ScanRows rows={hopDong} onDel={acc ? del : undefined} showHd /></div>
      <div className="mb-1 text-xs font-semibold text-ink-600">Bộ chứng từ theo HĐ ({hd.length})</div>
      <div className="overflow-hidden rounded-2xl border border-ink-200"><ScanRows rows={hd} onDel={acc ? del : undefined} showHd /></div></>}
    {up && <ScanUpload target={{ buyer }} onClose={() => setUp(false)} onDone={() => { setUp(false); changed(); }} />}
  </Modal>;
}
