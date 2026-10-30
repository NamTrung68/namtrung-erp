// Sale: dòng HĐ APT của mình cần xử lý · Người được cấp quyền: duyệt mở chặn
import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, cx, Empty, Loading, StatusChips, ask, toast, useAction, useLoad } from '../../components/ui';
import { Pager, usePager } from '../../components/Pager';
import { db } from '../../lib/sb';
import { useApp } from '../../state';
import { fmtDateTime, money, num } from '../../lib/format';
import { bienTone, dueTxt, lineName, LuongBadge, Money, pctTxt, REPLY, ST, StatusBadge } from './common';
import { LineModal, ReplyForm, useAccCfg } from './Acc';
import { aptPriceMsg } from '../../lib/doisoat';

const SEL = 'id,gia_von,bien_apt,apt_stt,truck_id,line_key,ma_dong,md,sale_id,sale_name,hh,dh,ten_apt,ten_ht,ten_tk,sl_apt,sl_ht,dvt_apt,dvt_ht,gia_khach,gia_nhap,gia_note,gia_de_xuat,gia_ap_dung,bien_nt,nk_ht,nk_tk,luong,status,issues,notes,phan_hoi,due_at,reply,reply_price,reply_note,replied_by,replied_at,approved_by,approved_at,approve_note,inv_no,inv_result,acc_trucks(name)';

function LineCard({ l, children, onOpen }: { l: any; children?: React.ReactNode; onOpen: () => void }) {
  const a = useApp(); const cfg = useAccCfg(); const [dt, dc] = dueTxt(l.status === 'blocked' ? l.due_at : null);
  return <div className="rounded-2xl border border-ink-200 bg-white p-4 shadow-soft">
    <div className="flex flex-wrap items-start justify-between gap-2">
      <div className="min-w-0"><div className="text-xs text-ink-500">{l.acc_trucks?.name} · {l.ma_dong || l.md || <span className="font-semibold text-red-600">chưa có đơn</span>}{l.hh ? ' · ' + l.hh : ''}{l.sale_id && l.sale_id !== a.me.id ? ' · ' + a.personName(l.sale_id) : ''}</div>
        <button className="mt-0.5 text-left font-semibold text-ink-900 hover:text-brand-700" onClick={onOpen}>{lineName(l).slice(0, 140)}</button></div>
      <div className="flex shrink-0 flex-col items-end gap-1"><StatusBadge s={l.status} />{dt && <span className={cx('text-xs', dc)}>{dt}</span>}</div>
    </div>
    <div className="mt-2 flex flex-wrap gap-x-5 gap-y-1 text-sm"><span>SL <b>{num(l.sl_apt ?? l.sl_ht, 0)}</b> {l.dvt_apt || l.dvt_ht}</span><span>Giá khách <b><Money v={l.gia_khach} /></b></span>
      <span>Giá APT <b><Money v={l.gia_ap_dung ?? l.gia_nhap} /></b></span>{l.bien_nt !== null && <span>Biên NT <b className={bienTone(l.bien_nt, cfg.bien_nt_min, cfg.bien_nt_max)}>{pctTxt(l.bien_nt)}</b></span>}<LuongBadge l={l.luong} /></div>
    {(l.issues || []).map((x: string, i: number) => <div key={i} className="mt-2 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">⚠ {x}</div>)}
    {l.reply && <div className="mt-2 text-sm text-ink-600">Đã trả lời: <b>{REPLY[l.reply]}</b>{l.reply_price ? ` — ${money(l.reply_price)}` : ''}{l.reply_note ? ` — “${l.reply_note}”` : ''} <span className="text-xs text-ink-400">({fmtDateTime(l.replied_at)})</span></div>}
    {l.approve_note && <div className="mt-1 text-sm text-ink-600">{l.status === 'approved' ? 'Đã duyệt' : 'Người duyệt'}: “{l.approve_note}” <span className="text-xs text-ink-400">— {a.personName(l.approved_by)}</span></div>}
    {children}
  </div>;
}

export function AccMine() {
  const a = useApp(); const [st, setSt] = useState('blocked'); const [sel, setSel] = useState<any>(null);
  const cfg = useAccCfg();
  const { data, loading, reload } = useLoad(() => db.from<any[]>('acc_lines').select(SEL).in('status', ['blocked', 'replied', 'pending_approval', 'approved']).order('due_at', { nulls: 'last' }).limit(1000), []);
  const { data: okL } = useLoad(() => db.from<any[]>('acc_lines').select(SEL).in('status', ['ok', 'approved']).gt('apt_stt', 0).is('inv_no', null).order('updated_at', { asc: false }).limit(1000), []);
  const price = (okL || []).filter(l => aptPriceMsg([l], cfg));
  const all = data || []; const view = st === 'price' ? price : all.filter(l => !st || l.status === st); const pg = usePager('acc_mine', [st]);
  const c = (k: string) => all.filter(l => l.status === k).length;
  return <Layout title="Việc HĐ của tôi">
    <p className="mb-3 text-sm text-ink-600">Đây là các dòng hàng trên hóa đơn APT <b>chưa đủ điều kiện tự chốt</b>. Mỗi dòng chọn 1 cách xử lý trong {useAccCfg().han_sale_gio}h. Dòng đạt điều kiện hệ thống đã tự chốt, bạn không cần làm gì.</p>
    <StatusChips value={st} onChange={setSt} items={[['blocked', ST.blocked[0], c('blocked'), 'red'], ['replied', ST.replied[0], c('replied'), 'amber'], ['pending_approval', ST.pending_approval[0], c('pending_approval'), 'purple'], ['approved', ST.approved[0], c('approved'), 'teal'], ['price', 'Đề xuất giá gửi APT', price.length, 'purple'], ['', 'Tất cả', all.length, 'dark']]} />
    {st === 'price' && price.length > 0 && <div className="mb-3 flex flex-wrap items-center gap-3 rounded-xl border border-brand-200 bg-brand-50 px-4 py-3 text-sm">Các dòng biên NT ngoài khung, hệ thống đã tính giá để biên NT về {(cfg.bien_muc_tieu * 100).toFixed(0)}%.
      <Button size="sm" variant="primary" onClick={() => navigator.clipboard.writeText(aptPriceMsg(price, cfg)).then(() => toast.ok('Đã sao chép — dán vào Zalo gửi APT'))}>📋 Copy tất cả gửi APT</Button></div>}
    {loading ? <Loading /> : !view.length ? <Card><Empty>{st === 'blocked' ? '🎉 Không có dòng nào cần bạn xử lý' : 'Không có dòng'}</Empty></Card> :
      <div className="space-y-3">{pg.slice(view).map(l => <LineCard key={l.id} l={l} onOpen={() => setSel(l)}>
        {st === 'price' && <div className="mt-2 flex items-center justify-between rounded-lg bg-brand-50 px-3 py-2 text-sm"><span>Đề nghị APT xuất giá <b>{Math.round(Number(l.gia_khach) / (1 + cfg.bien_muc_tieu)).toLocaleString('vi-VN')}</b></span>
          <Button size="sm" onClick={() => navigator.clipboard.writeText(aptPriceMsg([l], cfg, l.acc_trucks?.name)).then(() => toast.ok('Đã sao chép'))}>📋 Copy</Button></div>}
        {st !== 'price' && ['blocked', 'replied'].includes(l.status) && (l.sale_id === a.me.id || a.isLead) && <ReplyForm line={l} onDone={reload} />}</LineCard>)}</div>}
    <Pager p={pg} total={view.length} />
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
