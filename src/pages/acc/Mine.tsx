// Sale: dòng HĐ APT của mình cần xử lý · Người được cấp quyền: duyệt mở chặn
import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Input, Loading, Select, StatusChips, Table, Tabs, Td, ask, toast, useAction, useLoad } from '../../components/ui';
import { Pager, usePager } from '../../components/Pager';
import { db, fetchAll } from '../../lib/sb';
import { useApp } from '../../state';
import { fmtDateTime, money, num, stripVN } from '../../lib/format';
import { bienTone, deXuat, dueTxt, GiaApt, lineName, LuongBadge, Money, pctTxt, REPLY, ST, StatusBadge, useAccCfg } from './common';
import { LineModal } from './Acc';
import { ClaimForm, ReplyForm } from './forms';
import { DraftInvoice } from './Draft';
import { aptPriceMsg, INV_RESULT, InvResult } from '../../lib/doisoat';

const SEL = 'id,customer_id,ma_kh,claim_md,claim_gia,claimed_by,claimed_at,inv_qty,tt_khach,sl_tk,gia_von,bien_apt,apt_stt,truck_id,line_key,ma_dong,md,sale_id,sale_name,hh,dh,ten_apt,ten_ht,ten_tk,sl_apt,sl_ht,dvt_apt,dvt_ht,gia_khach,gia_nhap,gia_note,gia_de_xuat,gia_ap_dung,bien_nt,nk_ht,nk_tk,luong,status,issues,notes,phan_hoi,due_at,reply,reply_price,reply_note,replied_by,replied_at,approved_by,approved_at,approve_note,inv_no,inv_result,acc_trucks(name)';

function LineCard({ l, children, onOpen }: { l: any; children?: React.ReactNode; onOpen: () => void }) {
  const a = useApp(); const cfg = useAccCfg(); const [dt, dc] = dueTxt(l.status === 'blocked' ? l.due_at : null);
  return <div className="rounded-2xl border border-ink-200 bg-white p-4 shadow-soft">
    <div className="flex flex-wrap items-start justify-between gap-2">
      <div className="min-w-0"><div className="text-xs text-ink-500">{l.acc_trucks?.name} · {l.ma_dong || l.md || <span className="font-semibold text-red-600">chưa có đơn</span>}{!l.sale_id && l.sale_name ? ' · sale ghi: ' + l.sale_name : ''}{l.hh ? ' · ' + l.hh : ''}{l.sale_id && l.sale_id !== a.me.id ? ' · ' + a.personName(l.sale_id) : ''}</div>
        <button className="mt-0.5 text-left font-semibold text-ink-900 hover:text-brand-700" onClick={onOpen}>{lineName(l).slice(0, 140)}</button></div>
      <div className="flex shrink-0 flex-col items-end gap-1"><StatusBadge s={l.status} />{dt && <span className={cx('text-xs', dc)}>{dt}</span>}</div>
    </div>
    <div className="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-sm"><span>SL <b>{num(l.sl_apt ?? l.sl_ht, 0)}</b> {l.dvt_apt || l.dvt_ht}</span><span>Giá khách <b><Money v={l.gia_khach} /></b></span>
      <span>Giá APT <b><Money v={l.gia_nhap} /></b>{l.gia_note && Math.abs(l.gia_note - (l.gia_nhap || 0)) > 0.5 ? <> · NOTE <Money v={l.gia_note} /></> : ''}</span>{l.bien_nt !== null && <span>Biên NT <b className={bienTone(l.bien_nt, cfg.bien_nt_min, cfg.bien_nt_max)}>{pctTxt(l.bien_nt)}</b></span>}<LuongBadge l={l.luong} /></div>
    {(l.issues || []).map((x: string, i: number) => <div key={i} className="mt-2 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">⚠ {x}</div>)}
    {l.reply && <div className="mt-2 text-sm text-ink-600">Đã trả lời: <b>{REPLY[l.reply]}</b>{l.claim_md ? ` — ${l.claim_md}` : ''}{l.claim_gia ? ` — giá khách ${money(l.claim_gia)}` : ''}{l.reply_price ? ` — ${Math.round(l.reply_price)}` : ''}{l.reply_note ? ` — “${l.reply_note}”` : ''} <span className="text-xs text-ink-400">({fmtDateTime(l.replied_at)})</span></div>}
    {l.approve_note && <div className="mt-1 text-sm text-ink-600">{l.status === 'approved' ? 'Đã duyệt' : 'Người duyệt'}: “{l.approve_note}” <span className="text-xs text-ink-400">— {a.personName(l.approved_by)}</span></div>}
    {children}
  </div>;
}

type MTab = 'todo' | 'all' | 'price' | 'free' | 'draft';
export function AccMine() {
  const a = useApp(); const cfg = useAccCfg(); const [tab, setTab] = useState<MTab>(() => (sessionStorage.getItem('nt_accmine') as MTab) || 'todo');
  const [st, setSt] = useState(''); const [sel, setSel] = useState<any>(null); const [hd, setHd] = useState(''); const [q, setQ] = useState('');
  const go2 = (t: MTab) => { setTab(t); sessionStorage.setItem('nt_accmine', t); };
  const { data, loading, reload } = useLoad(() => fetchAll<any>(() => db.from('acc_lines').select(SEL).eq('is_test', false).order('updated_at', { asc: false }), 20000), []);
  const all = data || [];
  const mine = all.filter(l => l.sale_id && (l.sale_id === a.me.id || a.isLead));
  const free = all.filter(l => !l.sale_id && ['A', 'B'].includes(l.luong) && ['blocked', 'replied'].includes(l.status));
  const todo = mine.filter(l => ['blocked', 'replied', 'pending_approval'].includes(l.status));
  const price = mine.filter(l => ['ok', 'approved'].includes(l.status) && l.apt_stt && !l.inv_no && deXuat(l, cfg));
  const c = (k: string) => todo.filter(l => l.status === k).length;
  const match = (l: any) => !q || stripVN([l.md, l.hh, l.ten_apt, l.ten_ht, l.inv_no, l.acc_trucks?.name].join(' ')).toLowerCase().includes(stripVN(q).toLowerCase());
  const view = (tab === 'todo' ? todo.filter(l => !st || l.status === st) : tab === 'price' ? price : tab === 'free' ? free
    : mine.filter(l => !hd || (hd === 'co' ? !!l.inv_no : hd === 'mot' ? l.inv_result === 'mot_phan' : !l.inv_no))).filter(match);
  const pg = usePager('acc_mine', [tab, st, hd, q]);
  const copyAll = () => { const t = aptPriceMsg(price, cfg); if (!t) return toast.info('Không có dòng'); navigator.clipboard.writeText(t).then(() => toast.ok('Đã sao chép — dán vào Zalo gửi APT')); };
  return <Layout title="Việc HĐ của tôi">
    <Tabs value={tab} onChange={v => go2(v as MTab)} tabs={[['todo', <>Cần xử lý {todo.length > 0 && <Badge color="red">{todo.length}</Badge>}</>], ['all', `Tất cả dòng của tôi (${mine.length})`],
      ['price', <>Đề xuất giá gửi APT {price.length > 0 && <Badge color="purple">{price.length}</Badge>}</>], ['free', <>Dòng chưa có chủ {free.length > 0 && <Badge color="amber">{free.length}</Badge>}</>], ['draft', 'HĐ nháp gửi khách']]} />
    <div className="mt-3">
    {tab === 'draft' ? <DraftInvoice lines={mine} /> : <>
    {tab === 'todo' && <><p className="mb-3 text-sm text-ink-600">Dòng hàng trên HĐ APT <b>chưa đủ điều kiện tự chốt</b>. Chọn 1 cách xử lý trong {cfg.han_sale_gio}h. Sửa trên NamtrungLog trước rồi mới bấm “Đã sửa hệ thống”.</p>
      <StatusChips value={st} onChange={setSt} items={[['', 'Tất cả', todo.length, 'dark'], ['blocked', ST.blocked[0], c('blocked'), 'red'], ['replied', ST.replied[0], c('replied'), 'amber'], ['pending_approval', ST.pending_approval[0], c('pending_approval'), 'purple']]} /></>}
    {tab === 'free' && <p className="mb-3 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">Hàng đã lên xe nhưng <b>không tìm thấy đơn / sale trên hệ thống</b>. Nếu là hàng khách của bạn: tạo đơn trên NamtrungLog → bấm “Nhận dòng này”, nhập MD + giá khách. Kế toán kiểm rồi chốt.</p>}
    {tab === 'price' && price.length > 0 && <div className="mb-3 flex flex-wrap items-center gap-3 rounded-xl border border-brand-200 bg-brand-50 px-4 py-3 text-sm">Biên NT ngoài khung — hệ thống tính giá để biên NT về {pctTxt(cfg.bien_muc_tieu)}.
      <Button size="sm" variant="primary" onClick={copyAll}>📋 Copy tất cả gửi APT</Button></div>}
    <div className="mb-3 flex flex-wrap items-center gap-2"><Input className="max-w-xs" placeholder="🔎 MD, mã HH, tên hàng, số HĐ, xe…" value={q} onChange={e => setQ(e.target.value)} />
      {tab === 'all' && <Select className="w-48" placeholder="HĐ đầu vào: tất cả" options={[['co', 'Đã có HĐ'], ['chua', 'Chưa có HĐ'], ['mot', 'Mới xuất một phần']]} value={hd} onChange={setHd} />}</div>
    {loading ? <Loading /> : !view.length ? <Card><Empty>{tab === 'todo' ? '🎉 Không có dòng nào cần bạn xử lý' : 'Không có dòng'}</Empty></Card> :
      tab === 'all' ? <Card bodyClass="p-0"><Table head={['Xe', 'MD', 'Tên hàng', 'SL', 'Giá APT', 'Giá khách', 'Biên NT', 'Trạng thái', 'HĐ đầu vào']}>{pg.slice(view).map(l =>
        <tr key={l.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setSel(l)}><Td className="whitespace-nowrap text-xs">{l.acc_trucks?.name}<div className="text-ink-400">{l.hh}</div></Td>
          <Td className="whitespace-nowrap text-xs">{l.ma_dong || l.md}{a.isLead && l.sale_id !== a.me.id && <div className="text-ink-400">{a.personName(l.sale_id)}</div>}</Td>
          <Td className="min-w-[200px] text-xs">{lineName(l).slice(0, 90)}</Td><Td className="text-right">{num(l.sl_apt ?? l.sl_ht, 0)} <span className="text-[11px] text-ink-400">{l.dvt_apt || l.dvt_ht}</span></Td>
          <Td className="text-right"><GiaApt l={l} /></Td><Td className="text-right"><Money v={l.gia_khach} /></Td><Td className={cx('text-right', bienTone(l.bien_nt, cfg.bien_nt_min, cfg.bien_nt_max))}>{pctTxt(l.bien_nt)}</Td>
          <Td><StatusBadge s={l.status} /><div className="mt-0.5"><LuongBadge l={l.luong} /></div></Td>
          <Td className="whitespace-nowrap text-xs">{l.inv_no ? <>{l.inv_no}<div><Badge color={INV_RESULT[l.inv_result as InvResult]?.[1]}>{INV_RESULT[l.inv_result as InvResult]?.[0].slice(0, 18)}</Badge></div></> : <span className="text-ink-400">Chưa có</span>}</Td></tr>)}</Table></Card> :
      <div className="space-y-3">{pg.slice(view).map(l => <LineCard key={l.id} l={l} onOpen={() => setSel(l)}>
        {tab === 'price' && <div className="mt-2 flex items-center justify-between rounded-lg bg-brand-50 px-3 py-2 text-sm"><span>Đề nghị APT xuất giá <b>{deXuat(l, cfg)}</b></span>
          <Button size="sm" onClick={() => navigator.clipboard.writeText(aptPriceMsg([l], cfg, l.acc_trucks?.name)).then(() => toast.ok('Đã sao chép'))}>📋 Copy</Button></div>}
        {tab === 'todo' && ['blocked', 'replied'].includes(l.status) && <ReplyForm line={l} onDone={reload} />}
        {tab === 'free' && <ClaimForm line={l} onDone={reload} />}</LineCard>)}</div>}
    <Pager p={pg} total={view.length} /></>}
    </div>
    {sel && <LineModal line={sel} onClose={() => setSel(null)} onChanged={() => { setSel(null); reload(); }} />}
  </Layout>;
}

export function AccApprove() {
  const a = useApp(); const { busy, run } = useAction(); const [sel, setSel] = useState<any>(null);
  const ids: string[] = a.settings.accounting?.approver_ids || []; const can = a.isAdmin || ids.includes(a.me.id);
  const { data, loading, reload } = useLoad(() => can ? db.from<any[]>('acc_lines').select(SEL).eq('status', 'pending_approval').order('replied_at').limit(500) : Promise.resolve([]), [can]);
  const act = (l: any, ok: boolean) => run(async () => {
    const note = await ask({ title: ok ? 'Duyệt mở chặn' : 'Từ chối', message: ok ? 'Dòng sẽ được chốt TRUE gửi APT.' : 'Dòng trả về sale xử lý tiếp.', input: { label: ok ? 'Ghi chú (nếu có)' : 'Lý do từ chối', required: !ok } });
    if (note === null) return; await db.rpc('acc_line_approve', { p_id: l.id, p_ok: ok, p_note: note }); reload();
  }, ok ? 'Đã duyệt' : 'Đã từ chối');
  if (!can) return <Layout title="Duyệt mở chặn HĐ"><Card>Bạn chưa được cấp quyền duyệt. Admin/BGĐ thêm người duyệt ở Cấu hình → Kế toán – Hóa đơn.</Card></Layout>;
  const rows = data || [];
  return <Layout title="Duyệt mở chặn HĐ">
    <p className="mb-3 text-sm text-ink-600">Dòng chưa có đơn, giá khách = 0 hoặc biên NT dưới khung — sale xin duyệt ngoại lệ. Duyệt → dòng được chốt; hệ thống ghi tên, lý do, thời điểm.</p>
    {loading ? <Loading /> : !rows.length ? <Card><Empty>Không có dòng chờ duyệt</Empty></Card> :
      <div className="space-y-3">{rows.map(l => <LineCard key={l.id} l={l} onOpen={() => setSel(l)}>
        <div className="mt-3 flex gap-2"><Button variant="success" loading={busy} onClick={() => act(l, true)}>✓ Duyệt</Button><Button variant="danger" loading={busy} onClick={() => act(l, false)}>Từ chối</Button>
          <span className="self-center text-xs text-ink-500">Sale: {a.personName(l.replied_by)}</span></div></LineCard>)}</div>}
    {sel && <LineModal line={sel} onClose={() => setSel(null)} onChanged={() => { setSel(null); reload(); }} />}
  </Layout>;
}
