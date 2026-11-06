// Lập phiếu xuất HĐ hàng loạt: mỗi ID đơn (MD) = 1 phiếu; dòng chưa có ID đơn = 1 phiếu riêng
import React, { useEffect, useMemo, useState } from 'react';
import { Badge, Button, ask, cx, Modal, toast } from '../../components/ui';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { money, num } from '../../lib/format';

const vatTxt = (v: any) => (v === null || v === undefined ? '' : Math.round(Number(v) * 100) + '%');
export const VatBadge = ({ v }: { v: any }) => v === null || v === undefined ? null
  : <span className={cx('rounded px-1 text-[11px] font-semibold', Number(v) >= 0.095 ? 'bg-amber-100 text-amber-800' : 'text-ink-500')}>{vatTxt(v)}</span>;
const SRC: Record<string, string> = { doi_soat: 'đối soát xe', so: 'sổ HĐ', don_hang: 'file đơn hàng', phieu: 'phiếu trước', sale: 'sale nhập' };
export const srcTxt = (s?: string | null) => (s ? SRC[s] || s : '');

/** Chọn giá trong danh sách giá đã biết của đơn (đơn có nhiều giá) */
export function PricePick({ item, onPick, onClose }: { item: any; onPick: (gia: number) => void; onClose: () => void }) {
  const [list, setList] = useState<any[] | null>(null); const [v, setV] = useState('');
  useEffect(() => { db.rpc<any[]>('out_item_prices', { p_id: item.id }).then(setList).catch(() => setList([])); }, [item.id]);
  return <Modal open onClose={onClose} title={`Giá xuất · ${item.ma_hang}`} footer={<><input className="h-9 w-36 rounded-xl border border-ink-200 px-3 text-right text-sm" inputMode="numeric" placeholder="Gõ giá khác" value={v} onChange={e => setV(e.target.value.replace(/[^\d]/g, ''))} />
    <Button variant="primary" disabled={!Number(v)} onClick={() => onPick(Number(v))}>Dùng giá này</Button></>}>
    <div className="mb-2 text-sm text-ink-700">{item.ten}</div>
    <div className="mb-2 text-xs text-ink-500">Đơn {item.md} có {list?.length ?? '…'} giá đã biết — chọn giá đúng mặt hàng này:</div>
    <div className="space-y-1.5">{(list || []).map((p, i) => <button key={i} className="flex w-full items-center gap-3 rounded-xl border border-ink-200 px-3 py-2 text-left text-sm hover:border-brand-400 hover:bg-brand-50" onClick={() => onPick(Number(p.gia))}>
      <b className="w-24 shrink-0 text-right">{money(p.gia)}</b><span className="min-w-0 flex-1"><span className="line-clamp-2">{p.ten || '(không có tên hàng)'}</span>
        <span className="text-[11px] text-ink-500">{p.sl ? `SL ${num(p.sl, 2)} · ` : ''}{srcTxt(p.src)}</span></span></button>)}</div>
  </Modal>;
}

interface G { key: string; md: string | null; items: any[]; customer_id: string | null; khach: string; username: string;
  on: boolean; b: { name: string; mst: string; addr: string; email: string; pay: string; note: string }; src: string; lines: { item: any; sl: string; gia: string }[];
  res?: string; ok?: boolean; buyers: any[]; bid: string }

export function BulkInvoices({ items, onClose, onDone }: { items: any[]; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [gs, setGs] = useState<G[] | null>(null); const [run, setRun] = useState(false); const [step, setStep] = useState(''); const [pp, setPp] = useState<{ g: number; l: number } | null>(null);
  useEffect(() => {
    const m = new Map<string, any[]>(); items.forEach(t => { const k = t.md ? 'md:' + t.md : 'row:' + t.id; m.set(k, [...(m.get(k) || []), t]); });
    const cids = Array.from(new Set(items.map(t => t.customer_id).filter(Boolean)));
    const users = Array.from(new Set(items.map(t => t.username).filter(Boolean)));
    // Bản 33: danh sách pháp nhân của khách (theo khách ERP hoặc username) để chọn
    Promise.all([(cids.length ? db.rpc<Record<string, any>>('out_buyer_suggest', { p_customers: cids }) : Promise.resolve({} as Record<string, any>)).catch(() => ({} as Record<string, any>)),
      db.rpc<any[]>('out_buyers_for', { p_customers: cids, p_usernames: users }).catch(() => [] as any[])]).then(([sug, bl]) => {
      setGs(Array.from(m.entries()).map(([key, its]) => { const c = its.find(t => t.customer_id)?.customer_id || null; const s = c ? sug[c] : null;
        const un = String(its.find(t => t.username)?.username || '').toLowerCase();
        const buyers = (bl || []).filter(x => (c && x.customer_id === c) || (!x.customer_id && un && String(x.username || '').toLowerCase() === un));
        const b0 = !s && buyers.length ? buyers[0] : null; // khách chưa có ERP nhưng username có pháp nhân
        const bid = s?.buyer_id || (b0 ? b0.id : buyers.find(x => x.name === s?.name && (x.tax_code || '') === (s?.tax_code || ''))?.id) || '';
        return { key, md: its[0].md || null, items: its, customer_id: c, khach: its.find(t => t.khach)?.khach || '', username: its.find(t => t.username)?.username || '', buyers, bid,
          on: true, src: b0 ? 'pháp nhân theo username' : s?.src || '', b: b0 ? { name: b0.name, mst: b0.tax_code || '', addr: b0.address || '', email: b0.email || '', pay: 'TM/CK', note: '' }
            : { name: s && !s.weak ? s.name || '' : '', mst: s?.tax_code || '', addr: s?.address || '', email: s?.email || '', pay: s?.payment || 'TM/CK', note: '' },
          lines: its.map(t => ({ item: t, sl: String(+Number(t.ton).toFixed(4)), gia: t.gia_khach ? String(Math.round(t.gia_khach)) : '' })) };
      }).sort((x, y) => (x.md || 'zz').localeCompare(y.md || 'zz')));
    });
  }, []);
  const set = (i: number, f: (g: G) => G) => setGs(x => x!.map((g, j) => j === i ? f(g) : g));
  const check = (g: G) => {
    const err: string[] = [], warn: string[] = [];
    if (!g.b.name.trim()) err.push('Chưa có tên đơn vị mua');
    const noGia = g.lines.filter(l => l.gia === '').length; if (noGia) err.push(`Thiếu giá xuất ${noGia} dòng`);
    if (g.lines.some(l => !Number(l.sl) || Number(l.sl) > Number(l.item.ton) + 0.0001)) err.push('SL xuất phải > 0 và ≤ tồn');
    // Bản 23: biên so với giá APT trên HĐ ký — dưới 2% cấm, trên 4% vào "Chờ duyệt giá"
    const bien = (l: G['lines'][number]) => (Number(l.gia) > 0 && Number(l.item.dg_nhap) > 0 ? Number(l.gia) / Number(l.item.dg_nhap) - 1 : null);
    const low = g.lines.some(l => { const b = bien(l); return b !== null && b < 0.02 - 0.000001; });
    const high = g.lines.some(l => { const b = bien(l); return b !== null && b > 0.04 + 0.000001; });
    if (low) err.push('Có dòng dưới biên 2% so với giá APT — không được xuất');
    if (g.lines.some(l => l.item.lech && !l.item.lech_ok_at)) err.push('Có dòng lệch nháp — chờ kế toán mở khóa');
    if (new Set(g.items.map(t => t.customer_id).filter(Boolean)).size > 1) err.push('Đơn có hàng của 2 khách');
    if (high) warn.push('Biên trên 4% — sẽ vào Chờ duyệt giá');
    if (!g.b.mst.trim()) warn.push('Chưa có MST');
    if (!g.customer_id) warn.push(g.username ? `Username ${g.username} chưa có trong khách ERP` : 'Chưa gắn khách');
    if (new Set(g.lines.map(l => vatTxt(l.item.vat))).size > 1) warn.push('Nhiều thuế suất trong 1 HĐ');
    return { err, warn, low };
  };
  const lookup = async (i: number) => { const g = gs![i]; const m = g.b.mst.trim(); if (m.length < 10) return;
    try { const r = await db.rpc<any[]>('out_buyer_lookup', { p_mst: m }); const x = (r || [])[0];
      if (x) set(i, g => ({ ...g, src: g.src || 'danh sách đơn vị', b: { ...g.b, name: g.b.name || x.name, addr: g.b.addr || x.address || '', email: g.b.email || x.email || '' } })); } catch { /* bỏ qua */ } };
  const save = async (submit: boolean) => {
    const list = gs!.map((g, i) => ({ g, i })).filter(({ g }) => g.on && !g.ok && !check(g).err.length); if (!list.length) return;
    if (submit) { // màn xác nhận tổng trước khi tạo hàng loạt
      const tong = list.reduce((x, { g }) => x + g.lines.reduce((y, l) => { const tt = Math.round(Number(l.sl || 0) * Number(l.gia || 0)); return y + tt + Math.round(tt * Number(l.item.vat ?? 0)); }, 0), 0);
      const kh = new Set(list.map(({ g }) => g.customer_id || g.username || g.key)).size; const duyet = list.filter(({ g }) => check(g).warn.some(w => w.startsWith('Biên trên'))).length;
      if (!(await ask({ title: `Tạo ${list.length} yêu cầu · ${kh} khách · tổng ${money(tong)}`, message: duyet ? `${duyet} yêu cầu có biên trên 4% sẽ vào Chờ duyệt giá.` : 'Gửi kế toán export MISA.', ok: 'Tạo & gửi' }))) return;
    }
    setRun(true); let ok = 0;
    for (let k = 0; k < list.length; k++) { const { g, i } = list[k]; setStep(`Đang lập phiếu ${k + 1}/${list.length}…`);
      try {
        await db.rpc('out_invoice_save', { p_id: null, p_data: { customer_id: g.customer_id, buyer_name: g.b.name.trim(), tax_code: g.b.mst.trim(), address: g.b.addr.trim(), email: g.b.email.trim(), payment: g.b.pay, note: g.b.note.trim(), submit },
          p_lines: g.lines.map(l => ({ item_id: l.item.id, sl: Number(l.sl), don_gia: Number(l.gia), vat: l.item.vat })) });
        ok++; set(i, x => ({ ...x, ok: true, on: false, res: submit ? 'Đã gửi kế toán' : 'Đã lưu nháp' }));
      } catch (e: any) { set(i, x => ({ ...x, ok: false, res: e.message || String(e) })); }
    }
    setStep(''); setRun(false); toast.ok(`${submit ? 'Đã gửi kế toán' : 'Đã lưu'} ${ok}/${list.length} phiếu`); if (ok) onDone();
  };
  /** Chỉ giữ đơn sạch: bỏ tick đơn còn lỗi hoặc cảnh báo */
  const onlyClean = () => setGs(x => x!.map(g => g.ok ? g : { ...g, on: (() => { const c = check(g); return !c.err.length && !c.warn.length; })() }));
  const stats = useMemo(() => { if (!gs) return null; let ready = 0, bad = 0, done = 0; gs.forEach(g => { if (g.ok) done++; else if (check(g).err.length) bad++; else if (g.on) ready++; }); return { ready, bad, done }; }, [gs]);
  const inp = 'h-9 w-full rounded-xl border border-ink-200 bg-white px-3 text-sm focus:border-brand-500 focus:outline-none';
  return <Modal open onClose={() => !run && onClose()} size="xl" title={<span>Lập nhanh theo ID đơn · {gs?.length ?? '…'} phiếu từ {items.length} dòng</span>}
    footer={<><span className="mr-auto text-xs text-ink-500">{stats ? `${stats.ready} sẵn sàng · ${stats.bad} cần bổ sung · ${stats.done} đã lập` : ''}{step && <b className="ml-2 text-brand-700">{step}</b>}</span>
      <Button disabled={run || !gs} onClick={onlyClean}>Chỉ giữ đơn sạch</Button>
      <Button loading={run} disabled={!stats?.ready} onClick={() => save(false)}>Lưu nháp ({stats?.ready || 0})</Button>
      <Button variant="primary" loading={run} disabled={!stats?.ready} onClick={() => save(true)}>Gửi kế toán ({stats?.ready || 0} phiếu)</Button></>}>
    {!gs ? <div className="py-10 text-center text-sm text-ink-500">Đang lấy thông tin khách…</div> :
    <div className="space-y-3">
      <p className="text-xs text-ink-500">Mỗi ID đơn = 1 phiếu. Pháp nhân ★ mặc định của khách tự điền sẵn — bấm pháp nhân khác để đổi, hoặc nhập tay; gõ MST để tra. Phiếu có ô đỏ phải bổ sung mới lập được; muốn gộp / tách khác thì bỏ tick và lập phiếu riêng.</p>
      {gs.map((g, i) => { const c = check(g); const tt = g.lines.reduce((x, l) => x + Math.round(Number(l.sl || 0) * Number(l.gia || 0)), 0);
        const thue = g.lines.reduce((x, l) => x + Math.round(Math.round(Number(l.sl || 0) * Number(l.gia || 0)) * Number(l.item.vat ?? 0)), 0);
        return <div key={g.key} className={cx('rounded-2xl border p-3', g.ok ? 'border-emerald-300 bg-emerald-50/50' : c.err.length ? 'border-red-200' : 'border-ink-200')}>
          <div className="flex flex-wrap items-center gap-2">
            <input type="checkbox" className="h-5 w-5" disabled={g.ok || run} checked={g.on} onChange={e => set(i, x => ({ ...x, on: e.target.checked }))} />
            <b className="text-sm">{g.md || 'Chưa có ID đơn'}</b><span className="text-sm text-ink-700">{g.khach || g.username || ''}{g.khach && g.username ? <span className="text-ink-400"> · {g.username}</span> : null}</span>
            <span className="ml-auto text-sm">Tổng <b className="text-brand-700">{money(tt + thue)}</b></span>
          </div>
          {!g.ok && <div className="mt-2 flex flex-wrap items-center gap-1.5 text-xs">
            <span className="text-ink-500">Pháp nhân:</span>
            {g.buyers.map(x => <button key={x.id} disabled={run} title={[x.tax_code, x.address].filter(Boolean).join(' · ')} onClick={() => set(i, y => ({ ...y, bid: x.id, src: 'pháp nhân đã chọn', b: { ...y.b, name: x.name, mst: x.tax_code || '', addr: x.address || '', email: x.email || '' } }))}
              className={cx('max-w-[340px] truncate rounded-lg border px-2 py-1', g.bid === x.id ? 'border-brand-500 bg-brand-600 font-semibold text-white' : 'border-brand-200 bg-brand-50 text-brand-800 hover:border-brand-500')}>
              {x.is_default ? '★ ' : ''}{x.name}{x.tax_code ? ' · ' + x.tax_code : ''}</button>)}
            <button disabled={run} onClick={() => set(i, y => ({ ...y, bid: '', src: 'nhập tay', b: { ...y.b, name: '', mst: '', addr: '', email: '' } }))}
              className={cx('rounded-lg border px-2 py-1', g.bid === '' && g.src === 'nhập tay' ? 'border-ink-500 bg-ink-100 font-semibold' : 'border-ink-200 hover:border-ink-400')}>+ Pháp nhân khác (nhập tay)</button>
            {!g.buyers.length && <span className="text-amber-700">Khách chưa có pháp nhân nào trong danh sách — nhập tay; kế toán chuẩn hóa ở menu Pháp nhân nhận HĐ</span>}</div>}
          {!g.ok && <div className="mt-2 grid gap-2 sm:grid-cols-[2fr_1fr]">
            <input className={cx(inp, !g.b.name.trim() && 'border-red-300')} placeholder="Tên đơn vị mua hàng *" value={g.b.name} onChange={e => set(i, x => ({ ...x, bid: '', b: { ...x.b, name: e.target.value } }))} />
            <input className={cx(inp, !g.b.mst.trim() && 'border-amber-300')} placeholder="MST / CCCD" value={g.b.mst} onChange={e => set(i, x => ({ ...x, bid: '', b: { ...x.b, mst: e.target.value.replace(/\s/g, '') } }))} onBlur={() => lookup(i)} />
            <input className={inp} placeholder="Địa chỉ" value={g.b.addr} onChange={e => set(i, x => ({ ...x, bid: '', b: { ...x.b, addr: e.target.value } }))} />
            <input className={inp} placeholder="Email nhận HĐ" value={g.b.email} onChange={e => set(i, x => ({ ...x, bid: '', b: { ...x.b, email: e.target.value } }))} />
            {g.src && <div className="text-[11px] text-ink-500 sm:col-span-2">Thông tin lấy theo: {g.src}</div>}
          </div>}
          <div className="mt-2 divide-y divide-ink-100 rounded-xl border border-ink-100">{g.lines.map((l, j) => { const t = l.item; const low = Number(l.gia) > 0 && t.dg_nhap && Number(l.gia) / Number(t.dg_nhap) - 1 < 0.02 - 0.000001;
            return <div key={t.id} className="flex flex-wrap items-center gap-2 px-2 py-1.5 text-xs">
              <div className="min-w-0 flex-1 basis-56"><div className="font-semibold">{t.ma_hang}{t.part > 1 ? ` (${t.part})` : ''} <VatBadge v={t.vat} /></div><div className="line-clamp-1 text-ink-600" title={t.ten}>{t.ten}</div></div>
              <label className="flex items-center gap-1">SL<input className="h-8 w-20 rounded-lg border border-ink-200 px-2 text-right" inputMode="decimal" disabled={g.ok} value={l.sl}
                onChange={e => set(i, x => ({ ...x, lines: x.lines.map((y, k) => k === j ? { ...y, sl: e.target.value.replace(/[^\d.]/g, '') } : y) }))} /><span className="text-ink-400">/{num(t.ton, 2)} {t.dvt}</span></label>
              <label className="flex items-center gap-1">Giá<input className={cx('h-8 w-24 rounded-lg border px-2 text-right', l.gia === '' ? 'border-red-300 bg-red-50' : low ? 'border-red-300' : 'border-ink-200')} inputMode="numeric" disabled={g.ok} value={l.gia}
                onChange={e => set(i, x => ({ ...x, lines: x.lines.map((y, k) => k === j ? { ...y, gia: e.target.value.replace(/[^\d.]/g, '') } : y) }))} /></label>
              {t.gia_n > 1 && !g.ok && <button className={cx('text-[11px] underline', l.gia ? 'text-ink-400' : 'font-semibold text-amber-700')} onClick={() => setPp({ g: i, l: j })}>{l.gia ? `đổi (${t.gia_n} giá)` : `${t.gia_n} giá — chọn`}</button>}
              <span className="w-24 text-right font-semibold">{money(Math.round(Number(l.sl || 0) * Number(l.gia || 0)))}</span>
            </div>; })}</div>
          <div className="mt-1.5 flex flex-wrap gap-1">{g.res ? <Badge color={g.ok ? 'green' : 'red'}>{g.res}</Badge> : <>
            {c.err.map(e => <Badge key={e} color="red">{e}</Badge>)}{c.warn.map(w => <Badge key={w} color="amber">{w}</Badge>)}{!c.err.length && <Badge color="green">Sẵn sàng</Badge>}</>}</div>
        </div>; })}
    </div>}
    {pp && gs && <PricePick item={gs[pp.g].lines[pp.l].item} onClose={() => setPp(null)} onPick={gia => { const { g, l } = pp; set(g, x => ({ ...x, lines: x.lines.map((y, k) => k === l ? { ...y, gia: String(gia) } : y) })); setPp(null); }} />}
  </Modal>;
}
