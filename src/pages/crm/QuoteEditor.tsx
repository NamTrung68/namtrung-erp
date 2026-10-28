import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, cx, Field, Input, Loading, Modal, NumInput, Select, Textarea, toast, useAction, ask, Table, Td } from '../../components/ui';
import { db } from '../../lib/sb';
import { go, useApp, useRoute } from '../../state';
import { calcQuote, defaultHeader, priceFrame, QuoteHeader, QuoteLine } from '../../lib/quote-calc';
import { fmtDate, money, num, today, addDays } from '../../lib/format';
import { QuoteStatus } from './Customers';
import { vietQrUrl } from '../../lib/vietqr';
import { CustomerPicker } from '../../components/CustomerPicker';
import { AptSheet } from '../../components/AptSheet';
import { noAccent } from '../../lib/format';

const LOCKED = ['da_chot', 'tu_choi', 'het_han', 'da_thay_the'];
const emptyLine = (): QuoteLine => ({ name: '', spec: '', hs_code: '', unit: 'Chiếc', qty: 0, unit_price_cny: 0, duty_pct: 0, vat_pct: null, freight_pct: null, manual_price: null });

export default function QuoteEditor() {
  const a = useApp(); const { query } = useRoute();
  const qd = a.settings.quote_defaults || {};
  const [loading, setLoading] = useState(!!query.id);
  const [quote, setQuote] = useState<any>(null);
  const [customer, setCustomer] = useState<any>(null);
  const [h, setH] = useState<QuoteHeader>(() => defaultHeader(qd));
  const [lines, setLines] = useState<QuoteLine[]>([emptyLine()]);
  const [note, setNote] = useState('');
  const [printOpen, setPrintOpen] = useState(false); const [aptOpen, setAptOpen] = useState(false);
  const { busy, run } = useAction();
  const rates = useRef<{ ban?: number; san?: number; von?: number }>({});

  const load = async (id?: string) => {
    const fx: any[] = await db.from('exchange_rates').select('rate_type,rate,effective_from').lte('effective_from', new Date().toISOString()).order('effective_from', { asc: false }).limit(30);
    for (const t of ['ban', 'san', 'von'] as const) (rates.current as any)[t] = Number(fx.find(r => r.rate_type === t)?.rate) || undefined;
    if (id) {
      const q = await db.from('quotations').select('*').eq('id', id).maybeSingle();
      if (!q) { toast.err('Không tìm thấy báo giá'); go('/crm/quotes'); return; }
      const ls: any[] = await db.from('quotation_lines').select('*').eq('quotation_id', id).order('line_no');
      const c = await db.from('customers').select('id,code,contact_name,company_name,phone,zalo,import_method').eq('id', q.customer_id).maybeSingle();
      setQuote(q); setCustomer(c); setH({ ...defaultHeader(qd), ...q.header }); setNote(q.note || '');
      setLines(ls.length ? ls.map(l => ({ name: l.name, spec: l.spec, hs_code: l.hs_code, unit: l.unit, qty: Number(l.qty), unit_price_cny: Number(l.unit_price_cny), duty_pct: Number(l.duty_pct), vat_pct: l.vat_pct === null ? null : Number(l.vat_pct), freight_pct: l.freight_pct === null ? null : Number(l.freight_pct), manual_price: l.manual_price === null ? null : Number(l.manual_price) })) : [emptyLine()]);
    } else {
      setQuote(null); setLines([emptyLine()]); setNote('');
      setH({ ...defaultHeader(qd), tyGia: rates.current.ban || qd.tyGia || 4015, tyGiaVon: rates.current.von || 3955 });
      if (query.customer) { const c = await db.from('customers').select('id,code,contact_name,company_name,phone,zalo,import_method').eq('id', query.customer).maybeSingle(); setCustomer(c); if (c?.import_method) setH(x => ({ ...x, hinhThucNK: c.import_method })); }
      else setCustomer(null);
    }
    setLoading(false);
  };
  useEffect(() => { load(query.id); }, [query.id]);
  useEffect(() => { if (query.print === '1' && quote) setPrintOpen(true); }, [query.print, quote?.id]);

  const result = useMemo(() => calcQuote(h, lines, { tyLeCoc: qd.tyLeCoc ?? 80 }), [h, lines]);
  const t = result.totals;
  const frame = priceFrame(h, t, { tyGiaSan: rates.current.san ?? qd.tyGiaSan, phiDVSan: qd.phiDVSan, tyLeXuatMin: qd.tyLeXuatMin });
  const locked = quote && LOCKED.includes(quote.status);
  const canEdit = !locked && (!quote || quote.sale_id === a.me.id || a.isAdmin);
  const set = <K extends keyof QuoteHeader>(k: K) => (v: any) => setH(x => ({ ...x, [k]: v ?? 0 }));
  const setMode = (m: string) => setH(x => ({ ...x, cheDoXuat: m as any, pctXuat: m === 'du' ? 100 : m === 'thap' ? (qd.tyLeXuatMin ?? 70) : 110, coSoUyThac: m === 'thap' ? 'tienHang' : (qd.coSoUyThac || 'giaXuat') }));
  const setLine = (i: number, k: keyof QuoteLine, v: any) => setLines(ls => ls.map((l, j) => (j === i ? { ...l, [k]: v } : l)));

  const save = async (send: boolean) => run(async () => {
    if (!customer) throw new Error('Chọn khách hàng');
    if (frame.cam.length) throw new Error('CẤM: ' + frame.cam.join('; '));
    if (result.errors.length) throw new Error(result.errors.join('; '));
    const payloadLines = lines.filter(l => l.name.trim() && Number(l.qty) > 0).map((l, i) => {
      const r = result.lines.find(x => x.idx === lines.indexOf(l));
      return { ...l, computed: r ? { giaXuat: r.giaXuat, giaDu: r.giaDu, giaKhaiDV: r.giaKhaiDV, cuoc: Math.round(r.cuoc), tongTruocVAT: r.tongTruocVAT, thueNK: r.thueNK, vat: r.vat } : {} };
    });
    if (!payloadLines.length) throw new Error('Nhập ít nhất 1 dòng hàng (tên + số lượng)');
    const totals = { ...t, lnChiTiet: t.lnChiTiet };
    const id: string = await db.rpc('save_quote', { p_id: quote?.id ?? null, p_customer: customer.id, p_header: h, p_lines: payloadLines, p_totals: totals, p_note: note || null });
    let msg = 'Đã lưu nháp';
    if (send) {
      const st = await db.rpc('quote_submit', { p_id: id });
      msg = st === 'cho_duyet' ? 'Báo giá phá khung — đã chuyển Trưởng phòng duyệt' : 'Đã gửi báo giá';
    }
    toast.ok(msg);
    if (id !== quote?.id) go(`/crm/quote?id=${id}`); else load(id);
  });
  const decide = async (ok: boolean) => {
    const note = await ask({ title: ok ? 'Duyệt giá' : 'Không duyệt', input: { label: ok ? 'Ghi chú (không bắt buộc)' : 'Lý do', required: !ok } });
    if (note === null) return;
    run(async () => { await db.rpc('quote_decide', { p_id: quote.id, p_approve: ok, p_note: note || null }); load(quote.id); }, ok ? 'Đã duyệt' : 'Đã từ chối');
  };
  const updateResult = async () => {
    const st = await ask({ title: 'Cập nhật kết quả báo giá', input: { label: 'Kết quả', required: true, options: [['can_nhac', 'Khách đang cân nhắc'], ['da_chot', 'Đã chốt đơn'], ['tu_choi', 'Khách từ chối']] } });
    if (!st) return;
    let order = null, reason = null, rnote = null;
    if (st === 'da_chot') { order = await ask({ title: 'Mã đơn hệ thống', input: { label: 'Mã đơn (VD: NT1234)', required: true, value: h.maDonHeThong || '' } }); if (!order) return; }
    if (st === 'tu_choi') { reason = await ask({ title: 'Lý do từ chối', input: { label: 'Lý do', required: true, options: a.opts('reject_reason') } }); if (!reason) return; rnote = await ask({ title: 'Ghi chú thêm', input: { label: 'Ghi chú' } }); }
    run(async () => { await db.rpc('quote_set_status', { p_id: quote.id, p_status: st, p_order_code: order, p_reason: reason, p_note: rnote }); load(quote.id); }, 'Đã cập nhật');
  };
  const clone = () => run(async () => { const id = await db.rpc('quote_clone', { p_id: quote.id }); go(`/crm/quote?id=${id}`); }, 'Đã nhân bản');
  const canApprove = quote?.status === 'cho_duyet' && quote.sale_id !== a.me.id && (a.isAdmin || a.has('tp_kd'));

  if (loading) return <Layout title="Báo giá"><Loading /></Layout>;
  const dis = !canEdit;
  const lowHigh = h.cheDoXuat !== 'du';
  return (
    <Layout title={quote ? `Báo giá ${quote.code}${quote.version > 1 ? ' v' + quote.version : ''}` : 'Báo giá mới'}>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <div className="min-w-0 space-y-4">
          <section className="rounded-xl border border-ink-200 bg-white p-4">
            <div className="mb-3 flex flex-wrap items-center gap-2">
              <b>{quote ? `${quote.code}` : 'Báo giá mới'}</b>{quote && <QuoteStatus s={quote.status} />}
              {quote?.approved_by && <Badge color="green">Đã duyệt bởi {a.personName(quote.approved_by)}</Badge>}
              {quote?.approval_note && <span className="text-xs text-ink-500">“{quote.approval_note}”</span>}
              <span className="ml-auto" /><Button size="sm" onClick={() => go('/crm/quotes')}>Về danh sách</Button>
            </div>
            <div className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-6">
              <Field label="Khách hàng" required className="col-span-2 md:col-span-3"><CustomerPicker value={customer} onChange={setCustomer} disabled={dis || !!quote} /></Field>
              <Field label="Mã đơn hệ thống"><Input disabled={dis} placeholder="VD: NT1234" value={h.maDonHeThong || ''} onChange={e => set('maDonHeThong')(e.target.value.toUpperCase())} /></Field>
              <Field label="Tỷ giá RMB/VND" required><NumInput disabled={dis} value={h.tyGia} onChange={set('tyGia')} /></Field>
              <Field label="Kho nhận"><Select disabled={dis} options={a.opts('warehouse')} value={h.khoNhan} onChange={set('khoNhan')} /></Field>
              <Field label="Hình thức nhập khẩu" className="col-span-2"><Select disabled={dis} options={a.opts('import_method')} value={h.hinhThucNK || ''} onChange={set('hinhThucNK')} placeholder="— Chọn —" /></Field>
              <Field label="Ship nội địa TQ cả đơn (¥)"><NumInput disabled={dis} value={h.shipNoiDiaCNY} onChange={set('shipNoiDiaCNY')} /></Field>
              <Field label="Cân nặng cả lô (kg)"><NumInput disabled={dis} value={h.soKg} onChange={set('soKg')} /></Field>
              <Field label="Đơn giá / kg"><NumInput disabled={dis} value={h.donGiaKg} onChange={set('donGiaKg')} /></Field>
              <Field label="Số khối cả lô (m³)"><NumInput disabled={dis} value={h.soKhoi} onChange={set('soKhoi')} /></Field>
              <Field label="Đơn giá / m³"><NumInput disabled={dis} value={h.donGiaKhoi} onChange={set('donGiaKhoi')} /></Field>
              <Field label="Phí dịch vụ (%)"><NumInput disabled={dis || h.phiDVCoDinh > 0} value={h.phiDVPct} onChange={set('phiDVPct')} /></Field>
              <Field label="Phí dịch vụ cố định (đ)"><NumInput disabled={dis} value={h.phiDVCoDinh || null} onChange={set('phiDVCoDinh')} placeholder="để trống = tính theo %" /></Field>
              <Field label="Phí ủy thác (%)"><NumInput disabled={dis} value={h.phiUTPct} onChange={set('phiUTPct')} /></Field>
              <Field label="Chế độ xuất hóa đơn"><Select disabled={dis} options={[['du', 'Đủ giá trị'], ['thap', 'Xuất thấp'], ['cao', 'Xuất cao']]} value={h.cheDoXuat} onChange={setMode} /></Field>
              <Field label="% so với giá đủ (xuất thấp/cao)"><NumInput disabled={dis || !lowHigh} value={h.pctXuat} onChange={set('pctXuat')} /></Field>
              <Field label="Phí ủy thác tính trên"><Select disabled={dis} options={[['giaXuat', 'Giá xuất'], ['tienHang', 'Tiền hàng']]} value={h.coSoUyThac} onChange={set('coSoUyThac')} /></Field>
              <Field label="Thuế NK tính trên" className="col-span-2"><Select disabled={dis} options={[['toKhai', 'Trị giá khai APT (giá xuất × 0,9425)'], ['giaXuat', 'Giá xuất (như bảng báo giá cũ)']]} value={h.coSoThueNK} onChange={set('coSoThueNK')} /></Field>
              <Field label="Phí kê khai < 100kg"><NumInput disabled={dis} value={h.phiKeKhai} onChange={set('phiKeKhai')} /></Field>
              <Field label="Phí hợp quy"><NumInput disabled={dis} value={h.phiHopQuy} onChange={set('phiHopQuy')} /></Field>
              <Field label="Phí kiểm tra chất lượng"><NumInput disabled={dis} value={h.phiKTCL} onChange={set('phiKTCL')} /></Field>
              <Field label="Phí khác"><NumInput disabled={dis} value={h.phiKhac} onChange={set('phiKhac')} /></Field>
              <Field label="Tên phí khác (in trên báo giá)" className="col-span-2"><Input disabled={dis} placeholder="VD: Phí kiểm dịch, phí lưu kho…" value={h.tenPhiKhac} onChange={e => set('tenPhiKhac')(e.target.value)} /></Field>
              <Field label="Làm tròn giá đến"><NumInput disabled={dis} value={h.lamTron} onChange={set('lamTron')} /></Field>
              {h.cheDoXuat === 'cao' && <Field label="% TNDN trên phần chênh"><NumInput disabled={dis} value={h.tndnPct} onChange={set('tndnPct')} /></Field>}
              <Field label="Ghi chú trên báo giá" className="col-span-2 md:col-span-4 xl:col-span-6"><Input disabled={dis} value={note} onChange={e => setNote(e.target.value)} /></Field>
            </div>
          </section>
          <section className="rounded-xl border border-ink-200 bg-white">
            <div className="flex flex-wrap items-center justify-between gap-2 px-4 py-3">
              <div><b>Hàng hóa</b> <span className="text-xs text-ink-500">Cước chia theo tiền hàng. Dòng nào hàng to / nặng bất thường thì gõ “% cước” áng chừng, phần còn lại tự chia cho các dòng khác.</span></div>
              {canEdit && <Button size="sm" onClick={() => setLines(l => [...l, emptyLine()])}>Thêm dòng hàng</Button>}
            </div>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[1150px] text-sm [&_td]:align-top">
                <thead><tr className="border-y border-ink-200 bg-ink-50 text-left text-xs text-ink-500">
                  {['#', 'Tên hàng * (tối đa 250 ký tự)', 'HS code', 'ĐVT', 'SL *', 'Đơn giá ¥', 'Thuế NK %', 'VAT %', '% cước', ...(lowHigh ? ['Giá chọn tay'] : []), 'Cước', 'Giá xuất / ĐV', 'Giá khai APT / ĐV', 'Tổng trước VAT', ''].map((x, i) =>
                    <th key={i} className="px-1.5 py-2 font-medium">{x}</th>)}</tr></thead>
                <tbody>
                  {lines.map((l, i) => {
                    const r = result.lines.find(x => x.idx === i);
                    return <tr key={i} className="border-b border-ink-100">
                      <td className="px-1.5 text-xs text-ink-400">{i + 1}</td>
                      <td className="px-1 py-1"><textarea disabled={dis} rows={2} maxLength={250} className="min-h-[56px] w-full min-w-[300px] resize-y rounded-xl border border-ink-200 px-2.5 py-1.5 text-sm leading-snug focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-ink-50" value={l.name} onChange={e => setLine(i, 'name', e.target.value)} /></td>
                      <td className="px-1"><Input disabled={dis} className="w-24" value={l.hs_code || ''} onChange={e => setLine(i, 'hs_code', e.target.value)} /></td>
                      <td className="px-1"><Input disabled={dis} className="w-20" value={l.unit || ''} onChange={e => setLine(i, 'unit', e.target.value)} /></td>
                      <td className="px-1"><NumInput disabled={dis} className="w-24" value={l.qty} onChange={v => setLine(i, 'qty', v ?? 0)} /></td>
                      <td className="px-1"><NumInput disabled={dis} className="w-24" value={l.unit_price_cny} onChange={v => setLine(i, 'unit_price_cny', v ?? 0)} /></td>
                      <td className="px-1"><NumInput disabled={dis} className="w-16" value={l.duty_pct} onChange={v => setLine(i, 'duty_pct', v ?? 0)} /></td>
                      <td className="px-1"><NumInput disabled={dis} className="w-16" value={l.vat_pct} placeholder={String(h.vatPct)} onChange={v => setLine(i, 'vat_pct', v)} /></td>
                      <td className="px-1"><NumInput disabled={dis} className="w-20" value={l.freight_pct} placeholder={r ? `tự ${num(r.freightPct, 0)}%` : 'tự'} onChange={v => setLine(i, 'freight_pct', v)} /></td>
                      {lowHigh && <td className="px-1"><NumInput disabled={dis} className="w-24" value={l.manual_price} onChange={v => setLine(i, 'manual_price', v)} /></td>}
                      <td className="px-1.5 text-right tabular-nums">{r && money(r.cuoc)}</td>
                      <td className="px-1.5 text-right tabular-nums">{r && money(r.giaXuat)}</td>
                      <td className="px-1.5 text-right tabular-nums">{r && money(r.giaKhaiDV)}</td>
                      <td className="px-1.5 text-right font-medium tabular-nums">{r && money(r.tongTruocVAT)}</td>
                      <td className="px-1">{canEdit && lines.length > 1 && <button className="text-ink-400 hover:text-red-600" onClick={() => setLines(ls => ls.filter((_, j) => j !== i))}>✕</button>}</td>
                    </tr>;
                  })}
                </tbody>
              </table>
            </div>
          </section>
        </div>

        <aside className="space-y-3 xl:sticky xl:top-16 xl:self-start">
          <section className="rounded-xl border border-ink-200 bg-white">
            <h3 className="border-b border-ink-100 px-4 py-3 font-semibold">Cấu thành chi phí</h3>
            <div className="space-y-0.5 px-4 py-3 text-sm">
              <Row l="Tiền hàng" sub={`¥${num(t.tienHangCNY)} × ${num(h.tyGia, 0)}`} v={t.tienHang} />
              <Row l="Ship nội địa TQ" v={t.ship} />
              <G>Mục phí chính</G>
              <Row l="Vận chuyển TQ - Việt Nam" sub={`theo ${t.cuocTheoKg >= t.cuocTheoKhoi ? 'cân' : 'khối'}: kg ${money(t.cuocTheoKg)} / khối ${money(t.cuocTheoKhoi)}`} v={t.cuoc} />
              <Row l={h.phiDVCoDinh > 0 ? 'Phí dịch vụ (trọn gói)' : `Phí dịch vụ ${num(h.phiDVPct)}%`} v={t.phiDV} />
              <Row l={`Phí ủy thác ${num(h.phiUTPct)}%`} sub={h.coSoUyThac === 'tienHang' ? 'tính trên tiền hàng' : 'tính trên giá xuất'} v={t.phiUT} />
              <G>Mục phí phát sinh</G>
              <Row l="Phí kê khai < 100kg" v={h.phiKeKhai} /><Row l="Phí hợp quy" v={h.phiHopQuy} />
              {h.phiKTCL > 0 && <Row l="Phí kiểm tra chất lượng" v={h.phiKTCL} />}{h.phiKhac > 0 && <Row l={h.tenPhiKhac || 'Phí khác'} v={h.phiKhac} />}
              <Row l="Thuế nhập khẩu" sub={h.coSoThueNK === 'toKhai' ? 'thuế suất × trị giá khai' : 'thuế suất × giá xuất'} v={t.thueNK} />
              {t.tndn > 0 && <Row l="Thuế TNDN phần chênh (xuất cao)" v={t.tndn} />}
              <G>Giá xuất</G>
              <Row l="Giá đủ giá trị (A)" v={t.giaDu} />
              <Row l="Tổng trước VAT (hóa đơn)" v={t.tongTruocVAT} />
              <Row l="VAT" v={t.vat} />
              <div className="flex items-baseline justify-between py-1.5"><span>Tổng sau VAT</span><b className="text-2xl tabular-nums">{money(t.tongSauVAT)}</b></div>
              <Row l="Số tiền thu của khách (gồm VAT)" sub="tiền hàng + ship + cước + phí + thuế NK + VAT" v={t.soThu} />
              <Row l="Chênh hóa đơn so với số thu" sub={h.cheDoXuat === 'du' ? 'do làm tròn đơn giá xuất' : 'do xuất thấp/cao'} v={t.chenh} cls={t.chenh < 0 ? 'text-red-600' : 'text-emerald-700'} />
              <Row l="Tờ khai APT" sub="giá xuất × 0,9425 ÷ (1 + thuế NK)" v={t.toKhai} />
              <div className="-mt-0.5 mb-1 flex flex-wrap gap-1.5">
                <button className="rounded-full bg-brand-50 px-2.5 py-1 text-xs font-semibold text-brand-700 hover:bg-brand-100" onClick={() => setAptOpen(true)}>📋 Bảng khai gửi APT</button>
                <button className="rounded-full bg-[#e8f0fa] px-2.5 py-1 text-xs font-semibold text-[#2f6db5] hover:bg-[#d8e6f7]" onClick={() => setAptOpen(true)}>⇪ Dán lên hệ thống kê khai</button>
              </div>
              <Row l="LN ước tính (nội bộ, chưa gồm đàm phán NCC)" v={t.lnUocTinh} cls="text-emerald-700" />
              <div className="pl-2 text-[11px] text-ink-400">Tỷ giá {money(t.lnChiTiet.tyGia)} · Cước {money(t.lnChiTiet.cuoc)} · UT {money(t.lnChiTiet.uyThac)} · DV {money(t.lnChiTiet.phiDV)} · Làm tròn {money(t.lnChiTiet.lamTron)}</div>
            </div>
            {(frame.cam.length > 0 || frame.duyet.length > 0 || t.warnings.length > 0 || result.errors.length > 0) && <div className="space-y-1 border-t border-ink-100 px-4 py-3 text-xs">
              {frame.cam.map(x => <div key={x} className="font-medium text-red-700">⛔ CẤM: {x}</div>)}
              {frame.duyet.map(x => <div key={x} className="text-amber-700">⚠️ Cần duyệt: {x}</div>)}
              {[...t.warnings, ...result.errors].map(x => <div key={x} className="text-ink-600">• {x}</div>)}
            </div>}
            <div className="flex flex-wrap gap-2 border-t border-ink-100 px-4 py-3">
              {canEdit && <Button loading={busy} onClick={() => save(false)}>Lưu nháp</Button>}
              {canEdit && <Button variant="primary" loading={busy} onClick={() => save(true)}>{quote && ['da_gui', 'can_nhac'].includes(quote.status) ? 'Lưu phiên bản mới và gửi' : frame.duyet.length && quote?.approved_hash !== quote?.price_hash ? 'Lưu và gửi duyệt' : 'Lưu và gửi khách'}</Button>}
              {quote && <Button onClick={() => setPrintOpen(true)}>Xem và in</Button>}
              {quote && <Button onClick={clone}>Nhân bản</Button>}
              {quote && ['da_gui', 'can_nhac'].includes(quote.status) && quote.sale_id === a.me.id && <Button variant="dark" onClick={updateResult}>Cập nhật kết quả</Button>}
              {canApprove && <><Button variant="success" onClick={() => decide(true)}>Duyệt giá</Button><Button variant="danger" onClick={() => decide(false)}>Không duyệt</Button></>}
            </div>
            {quote && <div className="border-t border-ink-100 px-4 py-2 text-[11px] text-ink-400">Lập {fmtDate(quote.created_at)} · {a.personName(quote.sale_id)}{quote.sent_at && ` · gửi ${fmtDate(quote.sent_at)} · hiệu lực đến ${fmtDate(quote.valid_until)}`}{quote.order_code && ` · đơn ${quote.order_code}`}{quote.reject_reason && ` · từ chối: ${a.label('reject_reason', quote.reject_reason)}`}</div>}
          </section>
        </aside>
      </div>
      <AptSheet open={aptOpen} onClose={() => setAptOpen(false)} code={quote?.code || 'Báo giá mới'} maDon={h.maDonHeThong} h={h} totals={t}
        rows={lines.map((l, i) => ({ l, r: result.lines.find(x => x.idx === i) })).filter(x => x.r && x.l.name.trim()) as any} />
      {quote && <QuotePrint open={printOpen} onClose={() => setPrintOpen(false)} quote={quote} customer={customer} h={h} lines={lines} />}
    </Layout>
  );
}
const G = ({ children }: { children: React.ReactNode }) => <div className="pt-2 text-xs font-semibold text-ink-700">{children}</div>;
const Row = ({ l, v, sub, cls }: { l: string; v: number; sub?: string; cls?: string }) => (
  <div className="flex items-start justify-between gap-3 py-1"><span className="text-ink-700">{l}{sub && <span className="block text-[11px] text-ink-400">{sub}</span>}</span><b className={cx('whitespace-nowrap tabular-nums', cls)}>{money(v)}</b></div>
);

// ---------- Bản in gửi khách ----------
function QuotePrint({ open, onClose, quote, customer, h, lines }: { open: boolean; onClose: () => void; quote: any; customer: any; h: QuoteHeader; lines: QuoteLine[] }) {
  const a = useApp(); const co = a.settings.company || {}; const qr = a.settings.vietqr || {}; const qd = a.settings.quote_defaults || {};
  const r = useMemo(() => calcQuote(h, lines, { tyLeCoc: qd.tyLeCoc ?? 80 }), [h, lines]);
  const t = r.totals;
  const [salePhone, setSalePhone] = useState('');
  useEffect(() => { db.from('profiles').select('phone').eq('id', quote.sale_id).maybeSingle().then((p: any) => setSalePhone(p?.phone || ''), () => {}); }, [quote.sale_id]);
  const defContent = noAccent(`${customer?.contact_name || customer?.company_name || ''} TT tien hang ${h.maDonHeThong || 'NT'}`).replace(/\s+/g, ' ').trim().slice(0, 50);
  const [content, setContent] = useState(defContent); useEffect(() => { if (open) setContent(defContent); }, [open]);
  const [mode, setMode] = useState('coc'); const [pct, setPct] = useState<number>(qd.tyLeCoc ?? 80); const [custom, setCustom] = useState<number | null>(null);
  const amount = mode === 'coc' ? Math.ceil(((t.tienHang + t.phiDV) * pct / 100) / 1000) * 1000 : mode === 'all' ? t.soThu : (custom ?? 0);
  const validUntil = quote.valid_until || addDays(today(), qd.hieuLuc ?? 5);
  const doPrint = () => { document.body.classList.add('print-mode'); setTimeout(() => { window.print(); document.body.classList.remove('print-mode'); }, 50); };
  const valid = lines.map((l, i) => ({ l, r: r.lines.find(x => x.idx === i) })).filter(x => x.r);
  const utPrint = t.phiUT + (h.cheDoXuat === 'du' ? t.chenhLamTron : 0); // phí ủy thác gánh phần chênh làm tròn để mục B cộng đúng
  const bTotal = t.tienHang + t.ship + t.cuoc + t.phiDV + utPrint + t.phuPhi + t.thueNK + t.vat + t.tndn;
  const C = 'border border-[#d9a27f] px-1.5 py-1';
  return (
    <Modal open={open} onClose={onClose} title={`Xem trước báo giá ${quote.code}`} size="lg"
      footer={<><span className="mr-auto text-xs text-ink-400">Kiểm tra nội dung và số tiền chuyển khoản trước khi gửi khách.</span><Button variant="primary" onClick={doPrint}>In / Lưu PDF từ trình duyệt</Button></>}>
      <div className="mb-3 grid gap-2 rounded-xl border border-orange-200 bg-orange-50 p-3 sm:grid-cols-4">
        <Field label="Nội dung chuyển khoản" hint="Mặc định: Tên khách TT tien hang + mã NT. Sale kiểm tra, sửa nếu cần." className="sm:col-span-2"><Input placeholder="Ten khach TT tien hang NT1234" value={content} onChange={e => setContent(e.target.value)} maxLength={50} /></Field>
        <Field label="Khách chuyển"><Select options={[['coc', 'Cọc theo tiền hàng + phí dịch vụ'], ['all', 'Toàn bộ đơn'], ['custom', 'Tự nhập số tiền']]} value={mode} onChange={setMode} /></Field>
        {mode === 'coc' ? <Field label="% cọc"><NumInput value={pct} onChange={v => setPct(v ?? 0)} /></Field> : mode === 'custom' ? <Field label="Số tiền (0 = QR không số tiền)"><NumInput value={custom} onChange={setCustom} /></Field> : <Field label="Số tiền"><Input disabled value={money(amount)} /></Field>}
      </div>
      <div className="print-area mx-auto max-w-[800px] bg-white p-6 font-serif text-[12.5px] leading-snug text-black" style={{ fontFamily: '"Times New Roman", Times, serif' }}>
        <div className="flex items-start gap-4 border-b-2 border-[#F07B3C] pb-2">
          <img src="logo-mark.png" alt="Nam Trung" className="h-16 w-16 shrink-0 object-contain" />
          <div className="flex-1"><div className="text-[15px] font-bold text-[#1d1d1d]">{co.name}</div><div>Địa chỉ: {co.address}</div><div>Hotline: {co.hotline} | Email: {co.email}</div><div>MST: {co.tax_code} | Website: {co.website}</div></div>
          <div className="text-right"><div>Số: <b>{quote.code}{quote.version > 1 ? `-v${quote.version}` : ''}</b></div><div>Ngày: {fmtDate(quote.sent_at || quote.created_at)}</div></div>
        </div>
        <h2 className="my-3 text-center text-[19px] font-bold">BẢNG BÁO GIÁ NHẬP KHẨU</h2>
        <div className="mb-3 grid grid-cols-2 gap-x-6">
          <div>Kính gửi: <b>{customer?.company_name || customer?.contact_name}</b></div><div>Mã đơn: {h.maDonHeThong}</div>
          <div>Người liên hệ: <b>{customer?.contact_name} – {customer?.phone || customer?.zalo}</b></div><div>Tỷ giá: <b>{money(h.tyGia)} đ/¥</b></div>
          <div>Nhân viên: <b>{a.personName(quote.sale_id)}{salePhone && ` – ${salePhone}`}</b></div><div>Hiệu lực đến: <b>{fmtDate(validUntil)}</b></div>
        </div>
        <div className="mb-1 border-l-4 border-[#F07B3C] pl-2 font-bold">A. HÀNG HÓA VÀ GIÁ XUẤT HÓA ĐƠN</div>
        <table className="mb-3 w-full border-collapse text-[12px]">
          <thead className="bg-[#f8d5bf]"><tr>{['STT', 'Sản phẩm', 'ĐVT', 'SL', 'Đơn giá NCC', 'Giá xuất trước VAT', 'Thành tiền trước VAT', 'VAT', 'Tiền VAT'].map(x => <th key={x} className={C}>{x}</th>)}</tr></thead>
          <tbody>{valid.map(({ l, r: lr }, i) => <tr key={i}><td className={C + ' text-center'}>{i + 1}</td><td className={C + ' whitespace-pre-wrap'}>{l.name}{l.spec && <div className="text-[11px]">{l.spec}</div>}</td><td className={C}>{l.unit}</td>
            <td className={C + ' text-right'}>{num(l.qty)}</td><td className={C + ' text-right'}>¥{num(l.unit_price_cny)}</td><td className={C + ' text-right'}>{money(lr!.giaXuat)}</td>
            <td className={C + ' text-right'}>{money(lr!.tongTruocVAT)}</td><td className={C + ' text-center'}>{num(lr!.vatPct)}%</td><td className={C + ' text-right'}>{money(lr!.vat)}</td></tr>)}
            <tr className="font-bold"><td className={C} colSpan={6}>TỔNG</td><td className={C + ' text-right'}>{money(t.tongTruocVAT)}</td><td className={C} /><td className={C + ' text-right'}>{money(t.vat)}</td></tr>
            <tr className="bg-[#f8d5bf] text-[14px] font-bold"><td className={C + ' text-center'} colSpan={6}>TỔNG CỘNG SAU VAT</td><td className={C + ' text-right'} colSpan={3}>{money(t.tongSauVAT)} đ</td></tr></tbody>
        </table>
        <div className="mb-1 border-l-4 border-[#F07B3C] pl-2 font-bold">B. CHI TIẾT CẤU THÀNH CHI PHÍ</div>
        <table className="mb-3 w-full border-collapse text-[12px]">
          <thead className="bg-[#f8d5bf]"><tr>{['STT', 'Mục chi phí', 'Số lượng / Giá trị', 'Đơn giá / Tỷ lệ', 'Thành tiền (đ)'].map(x => <th key={x} className={C}>{x}</th>)}</tr></thead>
          <tbody>
            <B C={C} n="1" l="Tiền hàng" q={`¥${num(t.tienHangCNY)}`} p={`${money(h.tyGia)} đ/¥`} v={t.tienHang} />
            <B C={C} n="2" l="Phí ship nội địa Trung Quốc" q={`¥${num(h.shipNoiDiaCNY)}`} p={`${money(h.tyGia)} đ/¥`} v={t.ship} />
            <tr className="bg-[#fbeee5] font-bold"><td className={C} colSpan={5}>I. Mục phí chính</td></tr>
            <B C={C} n="3" l={`Phí vận chuyển TQ – ${h.khoNhan === 'HCM' ? 'Hồ Chí Minh' : 'Hà Nội'}`} q={t.cuocTheoKg >= t.cuocTheoKhoi ? `${num(h.soKg)} kg` : `${num(h.soKhoi)} m³`} p={t.cuocTheoKg >= t.cuocTheoKhoi ? `${money(h.donGiaKg)} đ/kg` : `${money(h.donGiaKhoi)} đ/m³`} v={t.cuoc} />
            <B C={C} n="4" l="Phí dịch vụ" q={h.phiDVCoDinh > 0 ? '' : money(t.tienHang)} p={h.phiDVCoDinh > 0 ? 'Trọn gói' : `${num(h.phiDVPct)}%`} v={t.phiDV} />
            <B C={C} n="5" l="Phí ủy thác" q={money(h.coSoUyThac === 'tienHang' ? t.tienHang : t.tongTruocVAT)} p={`${num(h.phiUTPct)}%`} v={utPrint} />
            <tr className="bg-[#fbeee5] font-bold"><td className={C} colSpan={5}>II. Mục phát sinh</td></tr>
            <B C={C} n="6" l="Phí kê khai hàng dưới 100kg" v={h.phiKeKhai} />
            <B C={C} n="7" l="Phí hợp quy" v={h.phiHopQuy} />
            <B C={C} n="8" l="Phí kiểm tra chất lượng" v={h.phiKTCL} />
            {h.phiKhac > 0 && <B C={C} n="" l={h.tenPhiKhac || 'Phí khác'} v={h.phiKhac} />}
            <B C={C} n="9" l="Thuế nhập khẩu" q={money(h.coSoThueNK === 'toKhai' ? t.toKhai : t.tongTruocVAT)} p={valid.length === 1 ? `${num(valid[0].r!.dutyPct)}%` : 'theo HS'} v={t.thueNK} />
            <B C={C} n="10" l="VAT" q={money(t.tongTruocVAT)} p={valid.length === 1 ? `${num(valid[0].r!.vatPct)}%` : 'theo dòng'} v={t.vat} />
            {t.tndn > 0 && <><tr className="bg-[#fbeee5] font-bold"><td className={C} colSpan={5}>III. Phát sinh do xuất hóa đơn cao hơn giá trị thực</td></tr>
              <B C={C} n="11" l="Thuế TNDN trên phần chênh giá xuất" q={money(t.tongTruocVAT - t.giaDu)} p={`${num(h.tndnPct)}%`} v={t.tndn} /></>}
            <tr className="bg-[#f8d5bf] font-bold"><td className={C + ' text-center'} colSpan={4}>TỔNG CHI PHÍ THỰC TẾ ĐƠN HÀNG (ĐÃ GỒM VAT)</td><td className={C + ' text-right'}>{money(bTotal)}</td></tr>
          </tbody>
        </table>
        {h.cheDoXuat !== 'du' && <p className="mb-2 text-[11px] italic">Giá trị hóa đơn (mục A) {h.cheDoXuat === 'cao' ? 'cao' : 'thấp'} hơn giá trị thực của lô hàng theo yêu cầu của quý khách{h.cheDoXuat === 'cao' ? '; thuế TNDN phát sinh trên phần chênh được tính ở mục III' : ''}.</p>}
        {(quote.note || '') && <p className="mb-2">Ghi chú: {quote.note}</p>}
        <div className="grid grid-cols-2 border border-[#d9a27f]">
          <div className="border-r border-[#d9a27f] p-2"><div className="mb-1 font-bold">LƯU Ý</div>
            <ol className="list-decimal space-y-0.5 pl-4 text-[11.5px]"><li>Báo giá có hiệu lực {qd.hieuLuc ?? 5} ngày kể từ ngày báo giá. Tỷ giá áp dụng theo ngày thanh toán tiền hàng.</li>
              <li>Giá trên là dự kiến, tính theo thông tin hàng hóa, cân nặng, số khối do nhà cung cấp gửi. Chi phí thực tế có thể thay đổi khi hàng về kho.</li>
              <li>Cước vận chuyển tính theo cân nặng hoặc thể tích thực tế khi hàng về kho Việt Nam.</li>
              <li>Thuế nhập khẩu, VAT áp dụng theo mã HS dự kiến; nếu Hải quan áp mã khác, chi phí điều chỉnh theo thực tế.</li></ol>
          </div>
          <div className="p-2"><div className="mb-1 font-bold">THÔNG TIN THANH TOÁN</div>
            <div className="flex gap-3">{qr.account && <img alt="QR" className="h-36 w-36" src={vietQrUrl({ bin: qr.bank_bin, account: qr.account, amount, content: content || `${quote.code} ${customer?.code || ''}`, holder: qr.holder, template: qr.template })} />}
              <div className="text-[11.5px]"><div>Ngân hàng: <b>{qr.bank_name}</b></div><div>Số TK: <b>{qr.account}</b></div><div>Chủ TK: <b>{qr.holder}</b></div>
                <div className="mt-1">{mode === 'coc' ? 'Số tiền cọc' : 'Số tiền'}: <b>{amount ? money(amount) + ' đ' : 'khách tự nhập'}</b></div>{mode === 'coc' && <div>({num(pct)}% tiền hàng + phí dịch vụ)</div>}
                <div>Nội dung: {content || `${quote.code} ${customer?.code || ''}`}</div></div></div>
          </div>
        </div>
        <div className="mt-6 grid grid-cols-2 text-center">
          <div><b>XÁC NHẬN CỦA KHÁCH HÀNG</b><div className="text-[11px] italic">(Ký, ghi rõ họ tên)</div><div className="h-16" /></div>
          <div><b>NAM TRUNG GROUP</b><div className="text-[11px] italic">Nhân viên kinh doanh</div><div className="h-12" /><b>{a.personName(quote.sale_id)}</b></div>
        </div>
      </div>
    </Modal>
  );
}
const B = ({ C, n, l, q = '', p = '', v }: { C: string; n: string; l: string; q?: string; p?: string; v: number }) =>
  <tr><td className={C + ' text-center'}>{n}</td><td className={C}>{l}</td><td className={C + ' text-right'}>{q}</td><td className={C + ' text-right'}>{p}</td><td className={C + ' text-right'}>{money(v)}</td></tr>;
