// Bản 31 — Tạo HĐ nháp MISA bằng API: cửa sổ 2 bước (Kiểm tra → Tạo), khung MISA trong chi tiết phiếu, nhãn tình trạng
import React, { useMemo, useState } from 'react';
import { Badge, Button, cx, Empty, Loading, Modal, Table, Td, ask, toast, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { fmtDateTime, money, num } from '../../lib/format';
import { writeXlsx } from '../../lib/xlsx';
import { MISA_ST, batchOf, misaCall, misaOn, misaTag, payloadDiff, runCreate, type RunRow } from '../../lib/misa';

/** Nhãn nhỏ tình trạng MISA trên dòng phiếu */
export function MisaTag({ v, className }: { v: any; className?: string }) {
  const t = misaTag(v); if (!t) return null;
  return <div className={cx('mt-1', className)} title={v.misa?.loi || ''}><Badge color={t[1]}>{t[0]}</Badge></div>;
}

// ---------------- Cửa sổ Kiểm tra → Tạo ----------------
export function MisaRun({ ids, recreate = false, onClose, onDone }: { ids: string[]; recreate?: boolean; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const batch = batchOf(a.settings);
  const { data, loading, error } = useLoad(() => db.rpc<any[]>('out_misa_check', { p_ids: ids }), [ids.join()]);
  // Tạo lại: lỗi "đã có nháp" không chặn (hàm máy chủ xóa nháp cũ trước)
  const evs = useMemo(() => (data || []).map((e: any) => { const errs: string[] = (e.errors || []).filter((x: string) => !(recreate && /^(Đã có nháp MISA|Phiếu đang "(có nháp|chờ ký)")/.test(x)));
    return { ...e, errors: errs, ok: errs.length === 0, diff: e.prev ? payloadDiff(e.prev.payload, e.payload) : [] }; }), [data, recreate]);
  const [off, setOff] = useState<Record<string, boolean>>({});
  const chosen = evs.filter(e => e.ok && !off[e.invoice_id]);
  const [rows, setRows] = useState<RunRow[] | null>(null); const [step, setStep] = useState(''); const running = step !== '';
  const start = async (list: string[]) => {
    if (!list.length) return;
    if (!(await ask({ title: `${recreate ? 'Tạo lại' : 'Tạo'} ${list.length} HĐ nháp trên MISA?`, message: <>Gửi theo lô {batch} HĐ. {recreate ? 'Nháp đang có của các phiếu này sẽ bị xóa trên MISA trước. ' : ''}Tổng tiền thanh toán: <b>{money(evs.filter(e => list.includes(e.invoice_id)).reduce((x, e) => x + Number(e.tong), 0))}</b></>, ok: 'Gửi MISA' }))) return;
    setStep('Bắt đầu…');
    try { const r = await runCreate(list, batch, recreate, (rs, s) => { setRows(rs); setStep(s || ''); }); setRows(r); onDone(); }
    catch (e: any) { toast.err(e.message || String(e)); } finally { setStep(''); }
  };
  const retryPdf = () => run2(async () => { const miss = (rows || []).filter(r => r.ok && r.hd_id && r.pdf === 'loi'); for (const r of miss) {
    try { await misaCall('pdf', { hd_id: r.hd_id }); setRows(x => (x || []).map(y => y.invoice_id === r.invoice_id ? { ...y, pdf: 'ok', pdfErr: '' } : y)); } catch (e: any) { setRows(x => (x || []).map(y => y.invoice_id === r.invoice_id ? { ...y, pdfErr: e.message } : y)); } } onDone(); });
  const { busy, run: run2 } = useAction();
  const code = (id: string) => evs.find(e => e.invoice_id === id)?.code || id.slice(0, 8);
  const xls = () => writeXlsx('Ket_qua_tao_nhap_MISA', [['Mã phiếu', 'Kết quả', 'Khớp tiền', 'PDF', 'Lỗi'], ...(rows || []).map(r => [code(r.invoice_id), r.ok ? 'Đã tạo' : 'Lỗi', r.khop === false ? 'LỆCH' : r.khop ? 'Khớp' : '', r.pdf === 'ok' ? 'Có' : r.pdf === 'loi' ? 'Lỗi' : '', [r.error, r.pdfErr, r.warn].filter(Boolean).join(' · ')])], 'Ket qua');
  const nOk = (rows || []).filter(r => r.ok).length, nPdf = (rows || []).filter(r => r.pdf === 'ok').length, nErr = (rows || []).filter(r => !r.ok).length, nPdfErr = (rows || []).filter(r => r.pdf === 'loi').length;
  const done = rows && !running;
  return <Modal open onClose={() => { if (!running) onClose(); }} size="xl" title={recreate ? 'Tạo lại HĐ nháp trên MISA' : 'Tạo HĐ nháp trên MISA'}
    footer={rows ? <>{done && nPdfErr > 0 && <Button loading={busy} onClick={retryPdf}>⬇ Lấy lại PDF còn thiếu ({nPdfErr})</Button>}
      {done && nErr > 0 && <Button onClick={() => { const ids2 = (rows || []).filter(r => !r.ok).map(r => r.invoice_id); setRows(null); setOff({}); setTimeout(() => start(ids2), 0); }}>↻ Thử lại phiếu lỗi ({nErr})</Button>}
      {done && <Button onClick={xls}>⬇ Excel kết quả</Button>}<Button variant="primary" disabled={running} onClick={onClose}>Xong</Button></>
      : <><Button onClick={onClose}>Hủy</Button><Button variant="primary" disabled={!chosen.length || loading} onClick={() => start(chosen.map(e => e.invoice_id))}>⚡ Gửi MISA ({chosen.length} phiếu)</Button></>}>
    {!rows ? <>
      <p className="mb-3 text-sm text-ink-600">Bước 1 — ERP kiểm từng phiếu. Phiếu ✗ không được gửi; sửa xong mở lại. Bỏ tick để giữ lại phiếu chưa muốn gửi. Mỗi phiếu MISA còn tự <b>xem thử</b> trước khi tạo, và ERP <b>đọc lại tiền</b> sau khi tạo.</p>
      {loading ? <Loading /> : error ? <div className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{String(error)}</div> : !evs.length ? <Empty>Không có phiếu</Empty> :
        <div className="max-h-[55vh] overflow-auto"><Table head={['', 'Phiếu', 'Đơn vị mua', 'Dòng', 'Tiền hàng', 'Thuế', 'Tổng', 'Kiểm tra']}>{evs.map(e =>
          <tr key={e.invoice_id} className={cx('align-top', !e.ok && 'bg-red-50/50')}>
            <Td><input type="checkbox" disabled={!e.ok} checked={e.ok && !off[e.invoice_id]} onChange={x => setOff(o => ({ ...o, [e.invoice_id]: !x.target.checked }))} /></Td>
            <Td className="whitespace-nowrap text-sm font-semibold">{e.code}<div className="text-[11px] font-normal text-ink-500">{a.personName(e.sale_id)}</div></Td>
            <Td className="max-w-[240px] text-xs"><div className="line-clamp-2 font-medium">{e.buyer_name}</div><div className="text-ink-500">MST {e.tax_code || '—'}</div></Td>
            <Td className="text-right">{e.so_dong}</Td><Td className="text-right tabular-nums">{money(e.tien_hang)}</Td><Td className="text-right tabular-nums">{money(e.tien_thue)}</Td><Td className="text-right font-semibold tabular-nums">{money(e.tong)}</Td>
            <Td className="min-w-[260px] text-xs">{e.ok ? <span className="font-semibold text-emerald-700">✓ Đạt</span> : <div className="space-y-0.5 text-red-700">{e.errors.map((x: string) => <div key={x}>✗ {x}</div>)}</div>}
              {(e.warnings || []).map((x: string) => <div key={x} className="text-amber-700">⚠ {x}</div>)}
              {e.diff.length > 0 && <div className="mt-1 rounded bg-brand-50 px-2 py-1 text-brand-900"><b>Khác nháp lần {e.prev.lan}:</b>{e.diff.slice(0, 8).map((x: string) => <div key={x}>• {x}</div>)}{e.diff.length > 8 && <div>… +{e.diff.length - 8}</div>}</div>}</Td></tr>)}</Table></div>}
      {!loading && evs.length > 0 && <div className="mt-2 text-sm">Gửi <b>{chosen.length}</b>/{evs.length} phiếu · tổng thanh toán <b>{money(chosen.reduce((x, e) => x + Number(e.tong), 0))}</b> · {Math.ceil(chosen.length / batch) || 0} lô</div>}
    </> : <>
      {running && <div className="mb-3"><div className="mb-1 text-sm font-semibold text-ink-800">{step}</div><div className="h-2 overflow-hidden rounded-full bg-ink-100"><div className="h-full bg-brand-600 transition-all" style={{ width: `${Math.round(((rows.filter(r => r.ok || r.error).length + rows.filter(r => r.pdf).length) / Math.max(1, rows.length * 2)) * 100)}%` }} /></div>
        <p className="mt-1 text-xs text-ink-500">Đừng đóng cửa sổ khi đang gửi. Nếu lỡ đóng: ERP vẫn giữ trạng thái — mở lại phiếu, bấm “Kiểm tra MISA”.</p></div>}
      {done && <div className={cx('mb-3 rounded-xl px-3 py-2 text-sm', nErr || nPdfErr ? 'bg-amber-50 text-amber-900' : 'bg-emerald-50 text-emerald-900')}>Đã tạo <b>{nOk}</b>/{rows.length} nháp · có PDF gửi sale <b>{nPdf}</b>{nErr ? <> · lỗi <b>{nErr}</b></> : ''}{nPdfErr ? <> · thiếu PDF <b>{nPdfErr}</b></> : ''}</div>}
      <div className="max-h-[55vh] overflow-auto"><Table head={['Phiếu', 'Tạo nháp', 'Tiền', 'PDF → sale', 'Ghi chú']}>{rows.map(r =>
        <tr key={r.invoice_id} className="align-top"><Td className="whitespace-nowrap font-semibold">{code(r.invoice_id)}</Td>
          <Td>{r.ok ? <Badge color="green">✓ Đã tạo</Badge> : r.error ? <Badge color="red">✗ Lỗi</Badge> : <span className="text-xs text-ink-400">chờ…</span>}</Td>
          <Td>{r.khop === false ? <Badge color="red">MISA lệch ERP</Badge> : r.khop ? <span className="text-xs text-emerald-700">khớp</span> : ''}</Td>
          <Td>{r.pdf === 'ok' ? <Badge color="green">✓ Đã gửi sale</Badge> : r.pdf === 'loi' ? <Badge color="amber">Chưa có PDF</Badge> : ''}</Td>
          <Td className="max-w-[380px] whitespace-pre-wrap break-words text-xs text-red-700">{[r.error, r.pdfErr].filter(Boolean).join('\n')}{r.warn ? <div className="text-amber-700">{r.warn}</div> : null}</Td></tr>)}</Table></div>
    </>}
  </Modal>;
}

// ---------------- Khung MISA trong chi tiết phiếu ----------------
export function MisaBox({ v, acc, onChanged }: { v: any; acc: boolean; onChanged: () => void }) {
  const a = useApp(); const on = misaOn(a.settings); const { busy, run } = useAction();
  const { data, reload } = useLoad(() => db.from<any[]>('out_misa').select('*').eq('invoice_id', v.id).order('lan', { asc: false }), [v.id, v.status, v.version, v.misa_at]);
  const [runner, setRunner] = useState<{ recreate: boolean } | null>(null); const [show, setShow] = useState<string | null>(null);
  const list = data || []; const act = list.find(m => ['dang_tao', 'da_tao', 'da_phat_hanh'].includes(m.trang_thai));
  if (!list.length && !(acc && on && v.status === 'cho_nhap')) return null;
  const done = () => { reload(); onChanged(); };
  const stale = act && act.trang_thai === 'da_tao' && act.invoice_version < v.version;
  const call = (action: string, body: any, okMsg: string, confirm?: string) => run(async () => {
    if (confirm && !(await ask({ title: confirm, ok: 'Đồng ý', danger: action === 'delete' }))) return;
    const r = await misaCall<any>(action, body); done();
    if (action === 'sync') toast.ok(`Đã dò MISA: ${r.phat_hanh || 0} phát hành · ${r.con_nhap || 0} còn nháp${r.bi_xoa ? ` · ${r.bi_xoa} bị xóa trên web` : ''}`); else toast.ok(okMsg);
  });
  const preview = () => run(async () => { const r = await misaCall<any>('preview', { invoice_id: v.id });
    if (!r.pdf) { toast.err('MISA trả bản xem không phải PDF'); return; }
    const bin = atob(r.data); const u8 = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    window.open(URL.createObjectURL(new Blob([u8], { type: 'application/pdf' })), '_blank'); });
  const shown = list.find(m => m.id === show);
  return <div className="mb-3 rounded-xl border border-ink-200 px-3 py-2">
    <div className="mb-1 flex flex-wrap items-center gap-2"><span className="text-xs font-bold uppercase text-ink-400">MISA (tạo bằng API)</span>
      {!on && acc && <span className="text-[11px] text-ink-400">— chưa bật API, đang làm tay</span>}</div>
    {list.length > 0 && <div className="space-y-1">{list.map(m => <div key={m.id} className={cx('flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg px-2 py-1 text-xs', m.id === act?.id ? 'bg-brand-50' : 'bg-ink-50')}>
      <b>Lần {m.lan}</b><Badge color={m.khop === false ? 'red' : MISA_ST[m.trang_thai]?.[1]}>{m.khop === false && m.trang_thai === 'da_tao' ? 'Lệch tiền ERP' : MISA_ST[m.trang_thai]?.[0]}</Badge>
      {m.id === act?.id && stale && <Badge color="red">bản cũ — sale đã sửa</Badge>}
      <span className="tabular-nums">ERP {money(m.tong_tt)}{m.misa_tong_tt !== null && m.misa_tong_tt !== undefined ? <> · MISA {money(m.misa_tong_tt)}</> : ''}</span>
      {m.so_hd && <span>HĐ <b>{m.so_hd}</b></span>}{m.file_id && <span className="text-emerald-700">PDF ✓</span>}
      <span className="text-ink-400">{fmtDateTime(m.created_at)} · {a.personName(m.created_by)}</span>
      {acc && m.payload && <button className="text-brand-700 underline" onClick={() => setShow(show === m.id ? null : m.id)}>{show === m.id ? 'ẩn dữ liệu' : 'dữ liệu gửi'}</button>}
      {m.loi_text && <div className="w-full whitespace-pre-wrap break-words text-red-700">{m.loi_text}</div>}</div>)}</div>}
    {shown && <div className="mt-2 max-h-56 overflow-auto rounded-lg border border-ink-200">
      <div className="px-2 py-1 text-[11px] text-ink-600">RefID <code>{shown.ref_id}</code> · {shown.payload.AccountObjectName} · MST {shown.payload.AccountObjectTaxCode || '—'} · {shown.payload.AccountObjectAddress || '—'} · {shown.payload.ReceiverEmail || 'không email'} · Ký hiệu {shown.payload.InvSeries}</div>
      <Table head={['#', 'Mã hàng', 'Tên', 'ĐVT', 'SL', 'Đơn giá', 'Thành tiền', 'Thuế', 'Tiền thuế']}>{(shown.payload.InvoiceDetails || []).map((d: any) =>
        <tr key={d.SortOrder} className="text-xs"><Td>{d.SortOrder}</Td><Td className="font-mono">{d.InventoryItemCode}</Td><Td className="min-w-[180px]">{d.Description}</Td><Td>{d.UnitName}</Td>
          <Td className="text-right">{num(d.Quantity, 2)}</Td><Td className="text-right">{money(d.UnitPrice)}</Td><Td className="text-right">{money(d.AmountOC)}</Td><Td>{d.VATRate}%</Td><Td className="text-right">{money(d.VATAmountOC)}</Td></tr>)}</Table>
      <div className="px-2 py-1 text-right text-xs">Tiền hàng <b>{money(shown.payload.TotalSaleAmountOC)}</b> · Thuế <b>{money(shown.payload.TotalVATAmountOC)}</b> · Tổng <b>{money(shown.payload.TotalAmountOC)}</b></div></div>}
    {acc && on && <div className="mt-2 flex flex-wrap gap-2">
      {v.status === 'cho_nhap' && !act && !v.misa_at && <Button size="sm" variant="primary" onClick={() => setRunner({ recreate: false })}>⚡ Tạo nháp MISA</Button>}
      {v.status === 'cho_nhap' && !act && v.misa_at && <Button size="sm" loading={busy} onClick={() => run(async () => {
        if (!(await ask({ title: 'Phiếu đã xuất Excel nhập MISA (làm tay)', message: 'Nếu đã nhập vào MISA: xóa nháp đó trên web MISA trước, rồi mới bỏ mốc để tạo bằng API — tránh 2 nháp cho 1 phiếu.', ok: 'Đã xóa nháp tay — bỏ mốc' }))) return;
        await db.rpc('out_misa_clear_export', { p_ids: [v.id] }); done(); }, 'Đã bỏ mốc export')}>Bỏ mốc export Excel</Button>}
      {stale && <Button size="sm" variant="primary" onClick={() => setRunner({ recreate: false })}>↻ Tạo lại nháp (xóa bản cũ)</Button>}
      {act?.trang_thai === 'da_tao' && !stale && ['cho_nhap', 'da_nhap', 'xac_nhan_ky'].includes(v.status) && <Button size="sm" onClick={() => setRunner({ recreate: true })}>↻ Tạo lại nháp</Button>}
      {act?.trang_thai === 'da_tao' && !act.file_id && act.khop !== false && !stale && <Button size="sm" loading={busy} onClick={() => call('pdf', { hd_id: act.id }, 'Đã lấy PDF nháp — đã báo sale')}>⬇ Lấy PDF nháp</Button>}
      {act && ['da_tao', 'dang_tao'].includes(act.trang_thai) && <Button size="sm" variant="danger" loading={busy} onClick={() => call('delete', { hd_id: act.id, note: 'Kế toán xóa' }, 'Đã xóa nháp trên MISA', `Xóa nháp lần ${act.lan} trên MISA (RefID ${String(act.ref_id).slice(0, 8)}…, ${money(act.tong_tt)})?`)}>🗑 Xóa nháp MISA</Button>}
      {act && ['da_tao', 'dang_tao'].includes(act.trang_thai) && <Button size="sm" loading={busy} onClick={() => call('sync', { ids: [v.id] }, '')}>⟳ Kiểm tra MISA</Button>}
      {v.status === 'cho_nhap' && <Button size="sm" loading={busy} onClick={preview}>👁 Xem thử trên MISA</Button>}
    </div>}
    {!acc && list.some(m => m.trang_thai === 'da_tao' && m.file_id) && <div className="mt-1 text-[11px] text-ink-500">Nháp do kế toán tạo tự động trên MISA — PDF ở mục file phía trên.</div>}
    {runner && <MisaRun ids={[v.id]} recreate={runner.recreate} onClose={() => setRunner(null)} onDone={done} />}
  </div>;
}
