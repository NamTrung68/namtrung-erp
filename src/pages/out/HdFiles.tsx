// File PDF hóa đơn MISA (nháp / đã ký) lưu kín trên Google Drive — xem qua vé dùng 1 lần
import React, { useEffect, useRef, useState } from 'react';
import { ask, Badge, Button, cx, Modal, toast, useAction } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { driveUploadMany, hdFile } from '../../lib/drive';
import { parseHdName, parseHdText, type HdInfo } from '../../lib/hdfile';
import { pdfText, renderPdf } from '../../lib/pdf';
import { fmtDateTime, money, today } from '../../lib/format';

export interface HdF { id: string; kind: 'nhap' | 'ky'; version: number; file_name: string; size_kb: number; tong: number | null; so_hd: string | null; ky_hieu: string | null;
  uploaded_at: string; uploaded_by: string; sent_at: string | null; sent_by: string | null; latest: boolean }
export const fileLabel = (f: HdF) => f.kind === 'ky' ? `HĐ đã ký${f.so_hd ? ' số ' + f.so_hd : ''}${f.version > 1 ? ' (bản ' + f.version + ')' : ''}` : `HĐ nháp v${f.version}`;
const isMobile = () => window.matchMedia('(pointer: coarse)').matches || window.innerWidth < 640;
const saveBlob = (b: Blob, name: string) => { const u = URL.createObjectURL(b); const a = document.createElement('a'); a.href = u; a.download = name; document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(u), 60000); };

/** Nhãn file trên danh sách phiếu */
export function FileBadge({ v }: { v: any }) {
  if (v.ky_v) return <Badge color="green">📄 Có PDF đã ký</Badge>;
  if (!v.nhap_v) return null;
  if (v.status === 'da_nhap' && !v.nhap_sent) return <Badge color="red">{v.nhap_v > 1 ? `Nháp mới v${v.nhap_v} — chưa gửi khách` : 'Nháp chưa gửi khách'}</Badge>;
  return <Badge color="blue">📄 Nháp v{v.nhap_v}</Badge>;
}

// ============ Màn xem toàn màn hình ============
export function HdViewer({ file, title, onClose, actions }: { file: HdF; title: React.ReactNode; onClose: () => void; actions?: (blob: Blob | null) => React.ReactNode }) {
  const a = useApp(); const box = useRef<HTMLDivElement>(null); const scroller = useRef<HTMLDivElement>(null);
  const [blob, setBlob] = useState<Blob | null>(null); const [err, setErr] = useState(''); const [busy, setBusy] = useState(true);
  const touch = useRef<number | null>(null);
  useEffect(() => { const f = (e: KeyboardEvent) => e.key === 'Escape' && onClose(); window.addEventListener('keydown', f);
    const ov = document.body.style.overflow; document.body.style.overflow = 'hidden'; return () => { window.removeEventListener('keydown', f); document.body.style.overflow = ov; }; }, []);
  useEffect(() => { let alive = true; setBusy(true); setErr('');
    hdFile(a.settings.drive, file.id).then(async b => { if (!alive) return; setBlob(b); if (box.current) await renderPdf(b, box.current, () => alive); })
      .catch(e => alive && setErr(e.message || String(e))).finally(() => alive && setBusy(false));
    return () => { alive = false; }; }, [file.id]);
  const fname = file.file_name || fileLabel(file) + '.pdf';
  const share = async () => { if (!blob) return; const f = new File([blob], fname, { type: 'application/pdf' });
    if ((navigator as any).canShare?.({ files: [f] })) { try { await navigator.share({ files: [f], title: fname }); } catch { /* người dùng hủy */ } } else saveBlob(blob, fname); };
  const openTab = () => { if (!blob) return; const u = URL.createObjectURL(blob); const w = window.open(u, '_blank'); if (!w) saveBlob(blob, fname); setTimeout(() => URL.revokeObjectURL(u), 120000); };
  return <div data-hd-viewer className="fixed inset-0 z-[60] flex flex-col bg-ink-900/95">
    <div className="flex items-center gap-2 bg-white px-3 py-2 shadow sm:px-5" style={{ paddingTop: 'max(0.5rem, env(safe-area-inset-top))' }}
      onTouchStart={e => { touch.current = e.touches[0].clientY; }} onTouchEnd={e => { if (touch.current !== null && e.changedTouches[0].clientY - touch.current > 70) onClose(); touch.current = null; }}>
      <div className="min-w-0 flex-1"><div className="truncate text-sm font-semibold">{title}</div><div className="truncate text-[11px] text-ink-500">{fileLabel(file)} · {fmtDateTime(file.uploaded_at)}</div></div>
      <button className="flex h-10 shrink-0 items-center gap-1 rounded-xl bg-ink-900 px-4 text-sm font-bold text-white active:scale-95" onClick={onClose}>✕ Đóng</button>
    </div>
    <div ref={scroller} className="min-h-0 flex-1 overflow-auto px-2 py-3 sm:px-6">
      {busy && !blob && <div className="mt-20 text-center text-sm text-white/80">Đang tải hóa đơn…</div>}
      {err && <div className="mx-auto mt-10 max-w-md rounded-xl bg-red-50 p-4 text-sm text-red-800">{err}<div className="mt-3"><Button size="sm" onClick={onClose}>Đóng</Button></div></div>}
      <div ref={box} className="mx-auto max-w-4xl" />
    </div>
    <div className="flex flex-wrap items-center justify-center gap-2 bg-white px-3 py-2.5" style={{ paddingBottom: 'max(0.625rem, env(safe-area-inset-bottom))' }}>
      {isMobile() ? <Button disabled={!blob} onClick={share}>↗ Chia sẻ (Zalo…)</Button> : <Button disabled={!blob} onClick={openTab}>🖨 Mở / in PDF</Button>}
      <Button disabled={!blob} onClick={() => blob && saveBlob(blob, fname)}>⬇ Tải về</Button>
      {isMobile() && file.kind === 'ky' && <Button disabled={!blob} onClick={openTab}>🖨 In</Button>}
      {actions?.(blob)}
      <Button className="sm:hidden" onClick={onClose}>Đóng</Button>
    </div>
  </div>;
}

// ============ Mục file trong chi tiết phiếu ============
export function HdFilesSection({ v, files, acc, onChanged }: { v: any; files: HdF[]; acc: boolean; onChanged: () => void }) {
  const a = useApp(); const { busy, run } = useAction(); const [view, setView] = useState<HdF | null>(null);
  const nhap = files.find(f => f.kind === 'nhap' && f.latest); const ky = files.find(f => f.kind === 'ky' && f.latest);
  const main = ky || nhap;
  useEffect(() => { if (main) hdFile(a.settings.drive, main.id).catch(() => {}); }, [main?.id]);   // tải sẵn để bấm Xem là hiện ngay
  const mine = a.me.id === v.sale_id || a.seesTeam;
  const sent = (f: HdF) => run(async () => { await db.rpc('out_file_sent', { p_file: f.id }); onChanged(); }, 'Đã ghi nhận gửi khách');
  const okSign = () => run(async () => { await db.rpc('out_confirm_sign', { p_invoice: v.id, p_version: nhap?.version ?? null }); setView(null); onChanged(); }, 'Đã báo kế toán ký');
  const fix = () => run(async () => { const note = await ask({ title: 'Khách yêu cầu sửa', input: { label: 'Nội dung cần sửa', required: true } });
    if (note === null) return; await db.rpc('out_invoice_status', { p_ids: [v.id], p_status: 'cho_nhap', p_note: note }); setView(null); onChanged(); }, 'Đã báo kế toán sửa');
  const saleActs = (f: HdF) => !acc && mine && f.kind === 'nhap' && f.latest && v.status === 'da_nhap' ? <>
    {!f.sent_at && <Button loading={busy} onClick={() => sent(f)}>✓ Đã gửi khách</Button>}
    <Button loading={busy} onClick={fix}>✎ Khách yêu cầu sửa</Button>
    <Button variant="success" loading={busy} onClick={okSign}>✓ Khách OK — đề nghị ký</Button></> : null;
  if (!files.length) return null;
  return <div className="mb-3 space-y-2">
    {ky && <div className="flex flex-wrap items-center gap-2 rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2">
      <div className="min-w-0 flex-1 text-sm text-emerald-900"><b>{fileLabel(ky)}</b> — in làm hợp đồng, báo khách kiểm tra email.</div>
      <Button variant="success" onClick={() => setView(ky)}>📄 Xem / in bản đã ký</Button></div>}
    {nhap && !ky && <div className={cx('flex flex-wrap items-center gap-2 rounded-xl border px-3 py-2', v.status === 'da_nhap' && !nhap.sent_at ? 'border-red-200 bg-red-50' : 'border-blue-200 bg-blue-50')}>
      <div className="min-w-0 flex-1 text-sm">
        {v.status === 'da_nhap' && !nhap.sent_at ? <b className="text-red-700">{nhap.version > 1 ? `Có bản nháp mới v${nhap.version} — chưa gửi khách` : 'HĐ nháp chưa gửi khách'}</b>
          : <b className="text-blue-900">{fileLabel(nhap)}</b>}
        <div className="text-xs text-ink-600">{nhap.sent_at ? `Đã gửi khách ${fmtDateTime(nhap.sent_at)}` : `Tải lên ${fmtDateTime(nhap.uploaded_at)}`}{v.status === 'xac_nhan_ky' ? ' · khách đã OK — chờ kế toán ký' : ''}</div></div>
      <Button variant="primary" onClick={() => setView(nhap)}>📄 Xem HĐ nháp v{nhap.version}</Button></div>}
    {files.length > 1 && <details className="rounded-xl border border-ink-200 px-3 py-1.5 text-xs"><summary className="cursor-pointer font-semibold text-ink-600">Các bản đã tải ({files.length})</summary>
      <div className="mt-1 divide-y divide-ink-100">{files.map(f => <div key={f.id} className="flex items-center gap-2 py-1.5">
        <div className="min-w-0 flex-1"><b>{fileLabel(f)}</b>{f.latest ? '' : <span className="text-ink-400"> · bản cũ</span>}
          <div className="text-ink-500">{fmtDateTime(f.uploaded_at)} · {a.personName(f.uploaded_by)}{f.sent_at ? ` · đã gửi khách ${fmtDateTime(f.sent_at)}` : ''}</div></div>
        <Button size="sm" onClick={() => setView(f)}>Xem</Button></div>)}</div></details>}
    {view && <HdViewer file={view} title={<>{v.code} · {v.buyer_name}</>} onClose={() => setView(null)} actions={() => saleActs(view)} />}
  </div>;
}

// ============ Kế toán tải PDF hàng loạt ============
interface Row { file: File; info: HdInfo | null; err?: string; cands: any[]; pick: string; dup: boolean; on: boolean; res?: string; ok?: boolean; batchDup?: boolean }
const ST: Record<string, string> = { soan: 'đang soạn', cho_nhap: 'chờ xuất nháp', da_nhap: 'đã xuất nháp', xac_nhan_ky: 'khách OK', da_ky: 'đã ký' };
const clean = (s: string) => (s || 'Chua co sale').replace(/[\\/]+/g, '-').trim();

export function UploadHdPdf({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [rows, setRows] = useState<Row[]>([]); const [step, setStep] = useState(''); const [running, setRunning] = useState(false); const [drag, setDrag] = useState(false);
  const read = async (fs: File[]) => {
    const pdfs = fs.filter(f => /\.pdf$/i.test(f.name)); if (!pdfs.length) { toast.err('Chọn file .pdf'); return; }
    setRunning(true); const out: Row[] = [];
    try {
      for (let i = 0; i < pdfs.length; i++) { const f = pdfs[i]; setStep(`Đang đọc ${i + 1}/${pdfs.length}: ${f.name}`);
        let info = parseHdName(f.name); let err: string | undefined;
        if (!info) { try { info = parseHdText(await pdfText(f)); } catch (e: any) { console.warn('pdf', e); err = 'Không đọc được file PDF (' + (e?.message || e) + ')'; } }
        if (!info && !err) err = 'Không thấy MST / tổng tiền — đặt tên theo mẫu NHAP_… / KY_…';
        out.push({ file: f, info, err, cands: [], pick: '', dup: false, on: false }); }
      setStep('Đang ghép với phiếu xuất HĐ…');
      const q = out.map((r, i) => ({ i, r })).filter(x => x.r.info);
      for (let k = 0; k < q.length; k += 100) {
        const part = q.slice(k, k + 100);
        const m = await db.rpc<any[]>('out_file_match', { p_rows: part.map(({ i, r }) => ({ i, kind: r.info!.kind, mst: r.info!.mst, tong: r.info!.tong, so_hd: r.info!.so_hd, ky_hieu: r.info!.ky_hieu, name: r.file.name })) });
        m.forEach(x => { const r = out[x.i]; r.cands = x.cands || []; r.pick = x.auto || ''; r.dup = !!x.dup; r.on = !!x.auto && !x.dup; });
      }
      // 2 file trong lô cùng ghép vào 1 phiếu → chỉ giữ file đầu, file sau để chọn tay
      setRows(x => { const all = [...x, ...out]; const seen = new Set<string>();
        all.forEach(r => { if (!r.pick || !r.info) return; const key = r.pick + r.info.kind; if (seen.has(key) && r.on && !r.ok) { r.on = false; r.batchDup = true; } if (r.on || r.ok) seen.add(key); });
        return all; });
    } catch (e: any) { toast.err(e.message || String(e)); } finally { setStep(''); setRunning(false); }
  };
  const set = (i: number, p: Partial<Row>) => setRows(x => x.map((r, j) => j === i ? { ...r, ...p } : r));
  const chosen = rows.map((r, i) => ({ r, i })).filter(({ r }) => r.on && r.pick && r.info && !r.ok);
  const upload = async () => {
    if (!chosen.length) return; setRunning(true);
    try {
      const month = today().slice(0, 7);
      const items = chosen.map(({ r }) => { const c = r.cands.find(x => x.id === r.pick);
        return { blob: r.file, name: r.file.name, folder: `${r.info!.kind === 'ky' ? 'HD da ky' : 'HD nhap'}/${month}/${clean(a.personName(c?.sale_id))}` }; });
      setStep(`Đang lưu lên Drive 0/${items.length}…`);
      const res = await driveUploadMany(a.settings.drive, items, (d, t) => setStep(`Đang lưu lên Drive ${d}/${t}…`));
      let ok = 0;
      for (let k = 0; k < chosen.length; k++) { const { r, i } = chosen[k]; const u = res[k];
        if (!u.ok) { set(i, { res: u.error, ok: false }); continue; }
        setStep(`Đang gắn vào phiếu ${k + 1}/${chosen.length}…`);
        try { const x = await db.rpc<any>('out_file_attach', { p_invoice: r.pick, p_kind: r.info!.kind, p_drive_id: u.id, p_name: r.file.name, p_size_kb: Math.round(r.file.size / 1024),
            p_tong: r.info!.tong, p_mst: r.info!.mst, p_so_hd: r.info!.so_hd || null, p_ky_hieu: r.info!.ky_hieu || null, p_ngay: r.info!.ngay || (r.info!.kind === 'ky' ? today() : null) });
          ok++; set(i, { res: r.info!.kind === 'ky' ? 'Đã gắn · phiếu Đã ký' : `Đã gắn nháp v${x.version} · sale được báo`, ok: true, on: false });
        } catch (e: any) { set(i, { res: 'Đã lưu Drive nhưng chưa gắn phiếu: ' + (e.message || e), ok: false }); }
      }
      toast.ok(`Đã tải ${ok}/${chosen.length} file`); if (ok) onDone();
    } catch (e: any) { toast.err(e.message || String(e)); } finally { setStep(''); setRunning(false); }
  };
  const nAuto = rows.filter(r => r.on).length, nPick = rows.filter(r => !r.dup && !r.pick && r.cands.length && !r.ok).length, nNone = rows.filter(r => !r.cands.length && !r.ok).length, nDup = rows.filter(r => r.dup).length;
  return <Modal open onClose={() => !running && onClose()} size="xl" title="Tải PDF hóa đơn (nháp / đã ký)"
    footer={<><span className="mr-auto text-xs text-ink-500">{rows.length ? `${rows.length} file · ${nAuto} sẵn sàng · ${nPick} cần chọn phiếu · ${nNone} không có phiếu · ${nDup} đã tải trước` : ''}</span>
      <Button variant="primary" loading={running} disabled={!chosen.length} onClick={upload}>⇪ Lưu Drive & gắn phiếu ({chosen.length})</Button></>}>
    <label className={cx('flex cursor-pointer flex-col items-center justify-center rounded-2xl border-2 border-dashed px-4 py-6 text-center text-sm', drag ? 'border-brand-500 bg-brand-50' : 'border-ink-300 hover:border-brand-400')}
      onDragOver={e => { e.preventDefault(); setDrag(true); }} onDragLeave={() => setDrag(false)} onDrop={e => { e.preventDefault(); setDrag(false); read(Array.from(e.dataTransfer.files)); }}>
      <input type="file" accept=".pdf,application/pdf" multiple className="hidden" disabled={running} onChange={e => { read(Array.from(e.target.files || [])); e.target.value = ''; }} />
      <b>Kéo thả hoặc bấm chọn nhiều file PDF</b>
      <span className="mt-1 text-xs text-ink-500">Tên chuẩn: <code>NHAP_MST_TổngTiền_yyyymmdd_stt.pdf</code> · <code>KY_KýHiệu-SốHĐ_MST_TổngTiền.pdf</code>. Tên khác thì ERP đọc chữ trong file.</span></label>
    {step && <div className="mt-3 rounded-lg bg-brand-50 p-3 text-sm font-semibold text-brand-800">{step}</div>}
    {rows.length > 0 && <div className="mt-3 divide-y divide-ink-100 rounded-xl border border-ink-200">{rows.map((r, i) => { const c = r.cands.find(x => x.id === r.pick);
      const lech = c && r.info?.tong != null ? r.info.tong - Number(c.nhap_tong ?? c.tong) : 0;
      return <div key={i} className={cx('flex flex-wrap items-start gap-2 px-3 py-2 text-sm', r.ok && 'bg-emerald-50/60')}>
        <input type="checkbox" className="mt-1 h-4 w-4" disabled={!r.pick || r.ok || running} checked={r.on} onChange={e => set(i, { on: e.target.checked })} />
        <div className="min-w-0 flex-1 basis-60">
          <div className="truncate text-xs font-semibold" title={r.file.name}>{r.file.name}</div>
          {r.info && <div className="mt-0.5 flex flex-wrap gap-x-2 text-xs text-ink-600"><Badge color={r.info.kind === 'ky' ? 'green' : 'blue'}>{r.info.kind === 'ky' ? 'Đã ký' : 'Nháp'}</Badge>
            <span>MST {r.info.mst || '—'}</span><span>Tổng <b>{r.info.tong != null ? money(r.info.tong) : '—'}</b></span>{r.info.so_hd && <span>Số HĐ {r.info.ky_hieu} {r.info.so_hd}</span>}
            {r.info.from === 'noi_dung' && <span className="text-ink-400">(đọc trong file)</span>}</div>}
          {r.err && <div className="text-xs text-red-700">{r.err}</div>}
        </div>
        <div className="min-w-0 flex-1 basis-72">
          {r.info && (r.cands.length ? <select className="h-9 w-full rounded-xl border border-ink-200 bg-white px-2 text-xs" disabled={r.ok || running} value={r.pick}
              onChange={e => set(i, { pick: e.target.value, on: !!e.target.value })}>
              <option value="">— Chọn phiếu —</option>
              {r.cands.map(x => <option key={x.id} value={x.id} disabled={!x.ok}>{x.khop ? '✓ ' : ''}{x.code} · {a.personName(x.sale_id)} · {money(Number(x.tong))} · {ST[x.status] || x.status}{x.nhap_v ? ` · đã có nháp v${x.nhap_v}` : ''}{!x.ok ? ' (không gắn được)' : ''}</option>)}
            </select> : <div className="text-xs text-amber-800">Không có phiếu cùng MST{r.info.so_hd ? ' / số HĐ' : ''} — kiểm tra sale đã lập phiếu chưa</div>)}
          {c && <div className="mt-0.5 truncate text-[11px] text-ink-500">{c.buyer_name}</div>}
          {r.batchDup && !r.ok && !r.on && <div className="text-xs text-amber-700">Trùng phiếu với 1 file khác trong lô — kiểm tra, tick nếu đây là bản mới hơn</div>}
          {r.dup && !r.ok && <div className="text-xs text-amber-700">File này đã tải trước đây — bỏ qua (tick lại nếu muốn tải bản mới)</div>}
          {c && Math.abs(lech) > 100 && <div className="text-xs font-semibold text-red-700">Lệch {money(lech)} đ so với phiếu — kiểm tra trước khi gắn</div>}
          {c && r.info?.kind === 'ky' && c.status === 'da_nhap' && <div className="text-xs text-amber-700">Sale chưa xác nhận khách OK</div>}
          {r.res && <div className={cx('text-xs font-semibold', r.ok ? 'text-emerald-700' : 'text-red-700')}>{r.ok ? '✓ ' : '✗ '}{r.res}</div>}
        </div></div>; })}</div>}
  </Modal>;
}
