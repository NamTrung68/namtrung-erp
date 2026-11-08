// Bản 25 — Nạp HĐ chính thức APT (chu kỳ 2): đối chiếu 3 nguồn NGAY TRÊN MÀN HÌNH trước khi lưu
//   HĐ chính thức ──tên + SL──► nháp APT của xe (MÃ KHAI BÁO) ──► file xe (ID đơn, username khách, sale, giá khách)
import React, { useMemo, useState } from 'react';
import { Badge, Button, cx, Field, Input, Modal, Select, Stat, toast, useAction, useLoad } from '../../components/ui';
import { db, fetchAll } from '../../lib/sb';
import { useApp } from '../../state';
import { readTable } from '../../lib/xlsx';
import { fmtDate, money, num, today } from '../../lib/format';
import { parseSoXuat } from '../../lib/xuathd';
import { bestTruck, HD_KIND, matchHd, type HdMatch } from '../../lib/hdapt';
import { driveReady, saveToDrive } from '../../lib/drive';
import { downloadMau } from '../../lib/mau';
import { Money } from '../acc/common';
import { kbMd, khLaDon } from '../../lib/doisoat';
import { assignMaHang, parseHdXml, soHdKey, type XmlHd } from '../../lib/hdxml';

/** Bản 32: đơn của dòng nháp (ID đơn trống thì theo mã khai báo) · username thiếu / trùng số đơn = cần điền */
const mdOf = (l: any) => (l ? l.md || kbMd(String(l.ma_dong || l.ma_kb_apt || '').toUpperCase()) || '' : '');
const khBad = (l: any) => !!l && (!l.ma_kh || khLaDon(l.ma_kh, mdOf(l)));

const LSEL = 'id,truck_id,apt_stt,ma_dong,ma_kb_apt,md,ma_kh,sale_id,sale_name,ten_apt,sl_apt,dvt_apt,gia_nhap,gia_note,gia_de_xuat,gia_khach,vat,luong,status';

export function ImportHd({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const a = useApp(); const { busy, run } = useAction(); const lamTron = Number(a.settings.accounting?.gia_de_xuat_lam_tron ?? 100);
  const [file, setFile] = useState<File | null>(null); const [xrows, setRows] = useState<any[] | null>(null); const [err, setErr] = useState('');
  // Bản 35: nạp XML gốc (mặc định) — mỗi file 1 HĐ, số HĐ anh điền (tự gợi ý theo XML), mã hàng = {mã khai báo}-{số HĐ}
  const [mode, setMode] = useState<'xml' | 'excel'>(() => (localStorage.getItem('nt_imphd_mode') === 'excel' ? 'excel' : 'xml'));
  const [xf, setXf] = useState<{ file: File; hd: XmlHd; so: string }[]>([]);
  const setMode2 = (m: 'xml' | 'excel') => { setMode(m); setErr(''); try { localStorage.setItem('nt_imphd_mode', m); } catch { /* */ } };
  const [truck, setTruck] = useState(''); const [f, setF] = useState(''); const [step, setStep] = useState('');
  const [khFill, setKhFill] = useState<Record<string, string>>({}); // bản 32: username điền tay theo mã đơn
  const { data: trucks } = useLoad(() => db.from<any[]>('acc_trucks').select('id,name,truck_date,is_test,stats').order('created_at', { asc: false }).limit(20), []);
  // dòng nháp của các xe gần đây + dòng nháp đã thuộc mã hàng khác
  const { data: src } = useLoad(async () => {
    const ids = (trucks || []).map(t => t.id); if (!ids.length) return { lines: [] as any[], owner: new Map<string, string>(), ownerSo: new Map<string, string>() };
    const lines = await fetchAll<any>(() => db.from('acc_lines').select(LSEL).in('truck_id', ids).gt('apt_stt', 0).order('id'));
    const linked = (await fetchAll<any>(() => db.from('out_items').select('ma_hang,acc_line_id,so_hd_vao,ma_auto').order('id'))).filter(x => x.acc_line_id);
    return { lines, owner: new Map<string, string>(linked.map(x => [x.acc_line_id, x.ma_hang])), ownerSo: new Map<string, string>(linked.filter(x => x.ma_auto).map(x => [x.acc_line_id, soHdKey(x.so_hd_vao)])) };
  }, [(trucks || []).length]);
  const read = async (fl: File) => {
    setErr(''); setRows(null); setFile(fl); setKhFill({});
    try { const p = parseSoXuat(await readTable(fl, { fillMerged: true })); if (!p.rows.length) throw new Error('File không có dòng hàng');
      setRows(p.rows.map((r: any) => ({ ...r, row: undefined })));
    } catch (e: any) { setErr(e.message || String(e)); }
  };
  const readXml = async (fs: FileList | File[]) => {
    setErr(''); const add: { file: File; hd: XmlHd; so: string }[] = []; const errs: string[] = [];
    for (const fl of Array.from(fs)) { try { const hd = parseHdXml(await fl.text()); add.push({ file: fl, hd, so: hd.so_hd }); } catch (e: any) { errs.push(`${fl.name}: ${e.message || e}`); } }
    setXf(x => [...x.filter(o => !add.some(n => n.file.name === o.file.name)), ...add]); setKhFill({}); if (errs.length) setErr(errs.join(' · '));
  };
  // dòng gốc để đối chiếu (XML: mã hàng tạm, đổi sau khi biết mã khai báo)
  const base: any[] | null = useMemo(() => {
    if (mode === 'excel') return xrows;
    if (!xf.length) return null;
    return xf.flatMap((f, fi) => f.hd.lines.map(l => ({ ma_hang: `X${fi}-${l.stt}`, part: 1, gia_so: null, stt_so: l.stt, ten: l.ten, dvt: l.dvt, vat: l.vat, sl_nhap: l.sl, dg_nhap: l.dg,
      so_hd_vao: soHdKey(f.so), ky_hieu: f.hd.ky_hieu, ngay_vao: f.hd.ngay, ncc: f.hd.ncc, stt_hd: l.stt, md: '', nvkd: '', username: '', legacy: null, src: 'xml', fi })));
  }, [mode, xrows, xf]);
  const xmlSoBad = mode === 'xml' && xf.some(f => !soHdKey(f.so));
  const xmlSoDup = mode === 'xml' && new Set(xf.map(f => soHdKey(f.so) + '|' + f.hd.ky_hieu)).size < xf.length;
  const byTruck = useMemo(() => { const m = new Map<string, any[]>(); (src?.lines || []).forEach(l => m.set(l.truck_id, [...(m.get(l.truck_id) || []), l])); return m; }, [src]);
  const auto = useMemo(() => (base ? bestTruck(base, byTruck) : null), [base, byTruck]);
  const tId = truck || auto || '';
  const res: HdMatch[] = useMemo(() => {
    if (!base) return []; const ls = tId === '*' ? (src?.lines || []) : byTruck.get(tId) || [];
    const mine = new Set(base.map(r => r.ma_hang)); const sos = new Set(mode === 'xml' ? base.map(r => r.so_hd_vao) : []); const taken = new Set<string>();
    src?.owner.forEach((mh, id) => { if (!mine.has(mh) && !sos.has(src.ownerSo.get(id) || '#')) taken.add(id); });
    return matchHd(base, ls, taken, lamTron);
  }, [base, tId, src, lamTron, mode]);
  // XML: mã hàng ERP = {mã khai báo của dòng nháp}-{số HĐ}
  const rows: any[] | null = useMemo(() => (!base ? null : mode === 'xml' ? assignMaHang(base, i => { const l = res.find(m => m.i === i)?.line; return l ? l.ma_dong || l.ma_kb_apt || null : null; }) : base), [base, res, mode]);
  const n = (p: (m: HdMatch) => boolean) => res.filter(p).length;
  const S = { khop: n(m => !!m.line && !m.lech && m.kind === 'khop'), gan: n(m => m.kind === 'gan' && !m.lech), lech: n(m => !!m.lech), chua: n(m => !m.line), nosale: n(m => !!m.line && !m.line.sale_id), nogia: n(m => !!m.line && !Number(m.line.gia_khach)), nokh: n(m => khBad(m.line)) };
  const khCon = Array.from(new Set(res.filter(m => khBad(m.line) && mdOf(m.line) && !(khFill[mdOf(m.line)] || '').trim()).map(m => mdOf(m.line)))).length;
  const view = res.filter(m => !f || (f === 'lech' ? !!m.lech : f === 'chua' ? !m.line : f === 'gan' ? m.kind === 'gan' : f === 'nokh' ? khBad(m.line) : f === 'ok' ? !!m.line && !m.lech : true));
  const save = () => run(async () => {
    // bản 32: username điền tay → ghi vào dòng nháp trước (dòng sổ theo dòng nháp)
    const fills = Object.entries(khFill).map(([md, u]) => [md, String(u || '').trim()] as const).filter(([, u]) => u);
    for (const [md, u] of fills) { const ids = Array.from(new Set(res.filter(m => m.line && khBad(m.line) && mdOf(m.line) === md).map(m => m.line.id)));
      if (ids.length) { setStep(`Gắn username ${u} cho ${md}…`); await db.rpc('acc_lines_set_kh', { p_ids: ids, p_username: u }); } }
    if (xmlSoBad) throw new Error('Điền số HĐ cho từng file XML'); if (xmlSoDup) throw new Error('2 file XML trùng số HĐ + ký hiệu');
    const out = res.map(m => { const { fi, ...r } = rows![m.i]; return { ...r, acc_line_id: m.line?.id || null }; });
    let nn = 0, nu = 0;
    for (let i = 0; i < out.length; i += 150) { setStep(`Đang lưu ${Math.min(i + 150, out.length)}/${out.length}…`); const x = await db.rpc<any>('out_items_import', { p_rows: out.slice(i, i + 150) }); nn += x.new; nu += x.upd; }
    const goc = mode === 'xml' ? xf.map(f => ({ fl: f.file, name: `HD_${soHdKey(f.so)}_${f.hd.ky_hieu || ''}.xml` })) : file ? [{ fl: file, name: file.name }] : [];
    if (goc.length && driveReady(a.settings.drive)) { setStep('Lưu file gốc lên Google Drive…');
      for (const g of goc) await saveToDrive(a.settings.drive, g.fl, g.name, `Ke toan/HD dau vao/${(rows![0]?.ngay_vao || today()).slice(0, 7)}`).catch(e => toast.err('Lưu Drive: ' + e.message)); }
    setStep(''); toast.ok(`Đã nạp ${nn} dòng mới, cập nhật ${nu} dòng · ${S.khop + S.gan} dòng có mã khai báo · ${S.lech} dòng khóa lệch${khCon ? ` · ${khCon} đơn còn thiếu username` : ''}`); onDone();
  });
  const t = (trucks || []).find(x => x.id === tId);
  return <Modal open onClose={onClose} size="xl" title="Nạp HĐ chính thức APT — đối chiếu nháp APT + file xe"
    footer={<>{step && <span className="mr-auto text-sm font-semibold text-brand-700">{step}</span>}
      <Button variant="primary" loading={busy} disabled={!rows || !res.length || xmlSoBad || xmlSoDup} onClick={save}>Lưu {rows ? rows.length : ''} dòng vào bảng gốc</Button></>}>
    <div className="mb-3 rounded-xl border border-ink-200 bg-ink-50 px-3 py-2 text-xs text-ink-700">
      <b>Luồng đối chiếu:</b> dòng HĐ chính thức <b>→ (tên + SL)</b> dòng nháp APT của xe → lấy <b>MÃ KHAI BÁO</b> → (đã ghép ở bước nạp xe) file xe hệ thống → lấy <b>ID đơn, username khách, sale, giá xuất khách</b>.
      Nháp APT + file xe phải được nạp trước ở nút <i>Nạp nháp APT + file xe</i>.</div>
    <div className="mb-3 flex flex-wrap items-center gap-1.5 text-xs">
      {([['xml', '📄 File XML gốc (tự sinh mã hàng)'], ['excel', '📊 File Excel sổ kế toán (có sẵn mã hàng)']] as const).map(([k, l]) =>
        <button key={k} onClick={() => setMode2(k)} className={cx('rounded-full border px-3 py-1 font-semibold', mode === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-700')}>{l}</button>)}
      {mode === 'xml' && <span className="text-ink-500">Mã hàng ERP = <b>{'{mã khai báo}-{số HĐ}'}</b>, VD <b>M3433-2-2080</b>. Dòng chưa ghép được nháp → mã tạm CHUAKB-…, ghép tay xong tự đổi.</span>}</div>
    {mode === 'xml' ? <div className="grid gap-3 sm:grid-cols-2">
      <Field label="1. File XML HĐ chính thức APT * (chọn được nhiều file, mỗi file 1 HĐ)" hint="File .xml gốc tải từ email / cổng HĐĐT của APT">
        <label className={cx('flex cursor-pointer items-center gap-2 rounded-xl border border-dashed px-3 py-2 text-sm', xf.length ? 'border-emerald-400 bg-emerald-50 text-emerald-800' : 'border-ink-300 hover:border-brand-400')}>
          <input type="file" accept=".xml,text/xml" multiple className="hidden" onChange={e => { if (e.target.files?.length) readXml(e.target.files); e.target.value = ''; }} />{xf.length ? `✓ ${xf.length} file XML — bấm để thêm` : '⇪ Chọn file .xml'}</label>
        {xf.length > 0 && <div className="mt-2 space-y-1.5">{xf.map((f, k) => <div key={f.file.name} className="flex flex-wrap items-center gap-2 rounded-lg border border-ink-200 bg-white px-2 py-1.5 text-xs">
          <span className="min-w-0 flex-1"><b>{f.hd.ky_hieu}</b> · số {f.hd.so_hd} · {fmtDate(f.hd.ngay)} · {f.hd.lines.length} dòng{f.hd.tong ? ' · ' + money(f.hd.tong) : ''}<div className="line-clamp-1 text-ink-500" title={f.file.name}>{f.hd.ncc || f.file.name}</div>
            {f.hd.bo_qua.length > 0 && <div className="text-amber-700">Bỏ qua {f.hd.bo_qua.length} dòng: {f.hd.bo_qua.slice(0, 2).join('; ')}</div>}</span>
          <label className="flex items-center gap-1 font-semibold">Số HĐ <Input className={cx('h-8 w-24 text-right', !soHdKey(f.so) && 'border-red-400 bg-red-50')} inputMode="numeric" value={f.so} onChange={e => setXf(x => x.map((y, j) => j === k ? { ...y, so: e.target.value.replace(/[^\d]/g, '') } : y))} /></label>
          <button className="px-1 text-red-600" onClick={() => setXf(x => x.filter((_, j) => j !== k))}>✕</button></div>)}
          {xmlSoDup && <div className="text-xs font-semibold text-red-700">2 file trùng số HĐ + ký hiệu — sửa số HĐ.</div>}</div>}</Field>
      <Field label="2. Đối chiếu với nháp APT + file xe của xe" hint={!(trucks || []).length ? 'Chưa nạp xe nào — nạp nháp APT + file xe trước' : auto && !truck ? 'Tự chọn xe khớp nhiều tên hàng nhất' : ''}>
        <Select placeholder={auto ? 'Tự chọn: ' + ((trucks || []).find(x => x.id === auto)?.name || '') : 'Chọn xe'} value={truck} onChange={setTruck}
          options={[...(trucks || []).map(x => [x.id, `${x.name}${x.is_test ? ' (thử)' : ''} · ${x.stats?.apt ?? '?'} dòng nháp · ${fmtDate(x.truck_date)}`] as [string, string]), ['*', 'Tất cả xe gần đây']]} /></Field></div> :
    <div className="grid gap-3 sm:grid-cols-2">
      <Field label={<span>1. File HĐ chính thức APT * <button type="button" className="ml-2 text-[11px] font-semibold text-brand-700 underline" onClick={() => downloadMau('hd')}>⬇ file mẫu</button></span>}
        hint="Mã hàng HH00044-2080-2026, Tên hàng hoá, Số lượng nhập, Đơn giá nhập, Thuế suất, Số hóa đơn, Ký hiệu, Ngày nhập">
        <label className={cx('flex cursor-pointer items-center gap-2 rounded-xl border border-dashed px-3 py-2 text-sm', file ? 'border-emerald-400 bg-emerald-50 text-emerald-800' : 'border-ink-300 hover:border-brand-400')}>
          <input type="file" accept=".xlsx,.csv" className="hidden" onChange={e => { const x = e.target.files?.[0]; if (x) read(x); }} />{file ? '✓ ' + file.name : '⇪ Chọn file .xlsx'}</label></Field>
      <Field label="2. Đối chiếu với nháp APT + file xe của xe" hint={!(trucks || []).length ? 'Chưa nạp xe nào — nạp nháp APT + file xe trước' : auto && !truck ? 'Tự chọn xe khớp nhiều tên hàng nhất' : ''}>
        <Select placeholder={auto ? 'Tự chọn: ' + ((trucks || []).find(x => x.id === auto)?.name || '') : 'Chọn xe'} value={truck} onChange={setTruck}
          options={[...(trucks || []).map(x => [x.id, `${x.name}${x.is_test ? ' (thử)' : ''} · ${x.stats?.apt ?? '?'} dòng nháp · ${fmtDate(x.truck_date)}`] as [string, string]), ['*', 'Tất cả xe gần đây']]} /></Field></div>}
    {err && <div className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">{err}</div>}
    {rows && <>
      <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-6">
        <Stat label="Dòng HĐ" value={rows.length} sub={`HĐ ${Array.from(new Set(rows.map(r => r.so_hd_vao))).join(', ')} · ${t ? t.name : tId === '*' ? 'tất cả xe' : 'chưa chọn xe'}`} />
        <Stat label="Khớp → có mã khai báo" value={S.khop + S.gan} tone="green" sub={S.gan ? `${S.gan} gần đúng — kiểm lại` : 'tên + SL đúng'} onClick={() => setF('ok')} />
        <Stat label="Lệch nháp → sẽ khóa" value={S.lech} tone={S.lech ? 'red' : undefined} sub="SL / đơn giá / thuế suất" onClick={() => setF('lech')} />
        <Stat label="Chưa tìm thấy dòng nháp" value={S.chua} tone={S.chua ? 'amber' : undefined} sub="lưu vào → kế toán ghép tay" onClick={() => setF('chua')} />
        <Stat label="Thiếu sale / giá khách" value={`${S.nosale} / ${S.nogia}`} tone={S.nosale + S.nogia ? 'amber' : undefined} sub="từ file xe" />
        <Stat label="Thiếu username khách" value={S.nokh} tone={khCon ? 'red' : S.nokh ? 'green' : undefined} sub={S.nokh ? (khCon ? `${khCon} đơn chưa điền` : 'đã điền đủ') : 'đủ username'} onClick={() => setF('nokh')} /></div>
      {khCon > 0 && <div className="mt-2 rounded-xl border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">⚠ <b>{khCon} đơn thiếu username khách</b> (hoặc username trùng số đơn — file xe lệch cột). Điền ở cột “Đơn · khách · sale” để ERP gắn đúng khách và pháp nhân xuất HĐ. Không điền vẫn lưu được, hàng nằm ở nhóm “Thiếu đơn / khách” của sale.</div>}
      <div className="mt-3 flex flex-wrap gap-1.5 text-xs">{([['', `Tất cả (${res.length})`], ['ok', `Khớp (${S.khop + S.gan})`], ['gan', `Gần đúng (${S.gan})`], ['lech', `Lệch (${S.lech})`], ['chua', `Chưa ghép (${S.chua})`], ['nokh', `Thiếu username (${S.nokh})`]] as [string, string][]).map(([k, l]) =>
        <button key={k || 'all'} onClick={() => setF(k)} className={cx('rounded-full border px-2.5 py-1 font-semibold', f === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-700')}>{l}</button>)}</div>
      <div className="mt-2 max-h-[52vh] overflow-auto rounded-xl border border-ink-200">
        <table className="w-full text-xs [&_td]:px-2 [&_td]:py-1.5 [&_td]:align-top"><thead className="sticky top-0 bg-ink-50 text-left text-[11px] text-ink-500"><tr>
          {[mode === 'xml' ? 'HĐ chính thức → mã hàng ERP (tự sinh)' : 'HĐ chính thức (mã hàng MISA)', 'SL · đơn giá HĐ', '→ Mã khai báo (nháp)', '→ Đơn · khách · sale (file xe)', 'Giá khách · biên', 'Kết quả'].map(h => <th key={h} className="px-2 py-2 font-medium">{h}</th>)}</tr></thead>
          <tbody className="divide-y divide-ink-100">{view.map(m => { const r = rows[m.i]; const l = m.line; const b = l && Number(l.gia_khach) > 0 && Number(r.dg_nhap) > 0 ? Number(l.gia_khach) / Number(r.dg_nhap) - 1 : null;
            return <tr key={m.i} className={m.lech ? 'bg-red-50/50' : !l ? 'bg-amber-50/40' : ''}>
              <td className="min-w-[240px]"><div className={cx('font-semibold', r.ma_hang.startsWith('CHUAKB-') && 'text-amber-700')}>{r.ma_hang}{r.part > 1 ? ` (${r.part})` : ''}</div>{r.src === 'xml' && <div className="text-[11px] text-ink-400">HĐ {r.so_hd_vao} · dòng {r.stt_hd}</div>}<div className="line-clamp-2 text-ink-600" title={r.ten}>{r.ten}</div></td>
              <td className="whitespace-nowrap text-right">{num(r.sl_nhap, 2)} {r.dvt}<div><Money v={r.dg_nhap} /></div></td>
              <td className="whitespace-nowrap">{l ? <><b>{l.ma_dong || l.ma_kb_apt || '—'}</b><div className="text-ink-500">STT nháp {l.apt_stt}{l.ma_kb_apt && l.ma_dong && l.ma_kb_apt !== l.ma_dong ? ` · APT ghi ${l.ma_kb_apt}` : ''}</div></> : <span className="text-ink-300">—</span>}</td>
              <td className="min-w-[170px]">{l ? <><b>{l.md || (mdOf(l) ? <span title="ID đơn trống trên file xe — lấy theo mã khai báo">{mdOf(l)} <span className="font-normal text-amber-700">(theo mã KB)</span></span> : <span className="text-red-600">không có đơn</span>)}</b>
                {!khBad(l) ? <> · {l.ma_kh}</> : <>{l.ma_kh && <span className="text-red-600"> · {l.ma_kh} — trùng số đơn</span>}
                  {mdOf(l) ? <Input className={cx('mt-0.5 h-7 text-xs', !(khFill[mdOf(l)] || '').trim() && 'border-red-300')} placeholder={`username khách ${mdOf(l)}`} value={khFill[mdOf(l)] || ''} onChange={e => setKhFill(x => ({ ...x, [mdOf(l)]: e.target.value }))} />
                    : <span className="text-amber-700"> · chưa có khách</span>}</>}
                <div className="text-ink-500">{a.personName(l.sale_id) || <span className="text-red-600">{l.sale_name || 'chưa có sale'}</span>}</div></> : null}</td>
              <td className="whitespace-nowrap text-right">{l ? <><Money v={l.gia_khach} />{b !== null && <div className={cx(b < 0.02 || b > 0.04 ? 'font-semibold text-amber-700' : 'text-ink-400')}>biên {(b * 100).toFixed(2)}%</div>}</> : null}</td>
              <td className="min-w-[180px]">{m.lech ? <><Badge color="red">Lệch — sẽ khóa</Badge><div className="mt-0.5 text-red-700">{m.lech}</div></> : <Badge color={HD_KIND[m.kind][1]}>{HD_KIND[m.kind][0]}</Badge>}
                {m.kind === 'gan' && <div className="text-ink-500">giống {Math.round(m.score * 100)}% · nháp: {l?.ten_apt}</div>}</td></tr>; })}</tbody></table></div>
      <div className="mt-2 text-xs text-ink-500">Lưu xong: dòng khớp vào <b>Sẵn sàng xuất</b> của sale; dòng lệch bị khóa chờ kế toán xử lý; dòng chưa ghép nằm ở khối ① để ghép tay. Nạp lại cùng file không bị trùng ({mode === 'xml' ? 'theo số HĐ + ký hiệu + STT dòng' : 'theo mã hàng MISA'}). {money(res.reduce((x, m) => x + Number(rows[m.i].sl_nhap) * Number(rows[m.i].dg_nhap || 0), 0))} tiền hàng.</div>
    </>}
  </Modal>;
}
