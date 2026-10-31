// Form xử lý dòng HĐ APT: sale trả lời / nhận dòng, kế toán chốt / gán sale
import React, { useState } from 'react';
import { Button, cx, Field, Input, Modal, Select, Textarea, useAction, useLoad } from '../../components/ui';
import { db } from '../../lib/sb';
import { money } from '../../lib/format';
import { REPLY } from './common';

const numIn = (v: string) => v.replace(/[^\d]/g, '');
const MdGia = ({ md, setMd, gk, setGk, needMd, needGk }: { md: string; setMd: (v: string) => void; gk: string; setGk: (v: string) => void; needMd: boolean; needGk: boolean }) =>
  (needMd || needGk) ? <div className="mt-2 grid grid-cols-2 gap-2">
    {needMd && <Field label="Mã đơn (MD) *"><Input value={md} placeholder="VD: MD2650" onChange={e => setMd(e.target.value.toUpperCase())} /></Field>}
    {needGk && <Field label="Giá khách (đ/đv) *" hint={gk ? money(Number(gk)) + ' đ' : 'Giá xuất HĐ cho khách'}><Input inputMode="numeric" value={gk} onChange={e => setGk(numIn(e.target.value))} /></Field>}
  </div> : null;

/** Sale trả lời dòng của mình */
export function ReplyForm({ line: l, onDone }: { line: any; onDone: () => void }) {
  const [r, setR] = useState(l.reply || ''); const [price, setPrice] = useState<string>(l.reply_price ? String(Math.round(l.reply_price)) : l.gia_de_xuat ? String(Math.round(l.gia_de_xuat)) : '');
  const [note, setNote] = useState(l.reply_note || ''); const { busy, run } = useAction();
  const [md, setMd] = useState(l.claim_md || ''); const [gk, setGk] = useState(l.claim_gia ? String(Math.round(l.claim_gia)) : '');
  const ab = ['A', 'B'].includes(l.luong); const needMd = r === 'da_sua_ht' && ab && !l.md; const needGk = r === 'da_sua_ht' && ab && !Number(l.gia_khach);
  const hint: Record<string, string> = { da_sua_ht: 'Đã tạo/sửa đơn trên NamtrungLog. Kế toán nạp lại file là dòng tự chốt.', de_xuat_gia: 'Muốn APT xuất giá khác — ghi giá.', chuyen_xe_sau: 'Hàng chưa đi xe này.',
    xin_duyet: 'Ngoại lệ, cần người duyệt.', xuat_thang: 'APT xuất HĐ thẳng cho khách — dòng chuyển luồng C ngay.' };
  return <div className="mt-3 rounded-xl border border-brand-200 bg-brand-50/50 p-3">
    <div className="mb-2 text-sm font-semibold">Xử lý dòng này</div>
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">{Object.entries(REPLY).map(([k, v]) => <button key={k} onClick={() => setR(k)} title={hint[k]}
      className={cx('rounded-xl border px-3 py-2 text-left text-sm font-semibold transition', r === k ? 'border-brand-600 bg-brand-600 text-white' : 'border-ink-200 bg-white text-ink-800 hover:border-brand-400')}>{v}</button>)}</div>
    {r && <div className="mt-1.5 text-xs text-ink-500">{hint[r]}</div>}
    <MdGia md={md} setMd={setMd} gk={gk} setGk={setGk} needMd={needMd} needGk={needGk} />
    {r === 'de_xuat_gia' && <Field className="mt-2" label="Giá muốn APT xuất (đ/đv)"><Input inputMode="numeric" value={price} onChange={e => setPrice(numIn(e.target.value))} /></Field>}
    <Field className="mt-2" label={r === 'xin_duyet' ? 'Lý do xin duyệt *' : 'Ghi chú'}><Textarea rows={2} value={note} onChange={e => setNote(e.target.value)}
      placeholder={r === 'da_sua_ht' ? 'VD: đã tạo đơn, đã nhập giá khách' : r === 'chuyen_xe_sau' ? 'VD: hàng chưa bốc, đi xe 01/11' : ''} /></Field>
    <div className="mt-2 flex justify-end"><Button variant="primary" loading={busy} disabled={!r || (needMd && !md) || (needGk && !gk)} onClick={() => run(async () => {
      await db.rpc('acc_line_reply', { p_id: l.id, p_reply: r, p_price: price ? Number(price) : null, p_note: note || null, p_md: needMd ? md : null, p_gia_khach: needGk ? Number(gk) : null }); onDone();
    }, r === 'xin_duyet' ? 'Đã gửi xin duyệt' : r === 'xuat_thang' ? 'Đã chuyển sang APT xuất thẳng' : 'Đã gửi kế toán')}>Gửi</Button></div>
  </div>;
}

/** Sale nhận dòng chưa có chủ (hàng lên xe nhưng không thấy trên hệ thống) */
export function ClaimForm({ line: l, onDone }: { line: any; onDone: () => void }) {
  const { busy, run } = useAction(); const [md, setMd] = useState(''); const [gk, setGk] = useState(''); const [note, setNote] = useState('');
  return <div className="mt-3 rounded-xl border border-amber-300 bg-amber-50 p-3">
    <div className="text-sm font-semibold">Đây là hàng khách của bạn?</div>
    <div className="text-xs text-ink-600">Tạo đơn trên NamtrungLog trước, rồi nhập MD + giá khách. Kế toán kiểm 1 lần rồi chốt.</div>
    <MdGia md={md} setMd={setMd} gk={gk} setGk={setGk} needMd needGk={!Number(l.gia_khach)} />
    <Field className="mt-2" label="Ghi chú"><Input value={note} onChange={e => setNote(e.target.value)} placeholder="VD: khách anh Tuấn, hàng đặt qua Zalo" /></Field>
    <div className="mt-2 flex justify-end"><Button variant="primary" loading={busy} disabled={!md || (!Number(l.gia_khach) && !gk)} onClick={() => run(async () => {
      await db.rpc('acc_line_claim', { p_id: l.id, p_md: md, p_gia_khach: gk ? Number(gk) : null, p_note: note || null }); onDone(); }, 'Đã nhận dòng — chờ kế toán chốt')}>Nhận dòng này</Button></div>
  </div>;
}

/** Kế toán chốt: bắt buộc có giá khách; bổ sung MD nếu thiếu */
export function ChotModal({ line: l, onClose, onDone }: { line: any; onClose: () => void; onDone: () => void }) {
  const { busy, run } = useAction(); const ab = ['A', 'B'].includes(l.luong);
  const [gk, setGk] = useState(String(Math.round(Number(l.gia_khach) || Number(l.claim_gia) || 0) || ''));
  const [md, setMd] = useState(l.md || l.claim_md || ''); const [note, setNote] = useState('');
  const warn = !Number(l.gia_khach) || (l.issues || []).some((x: string) => /giá/i.test(x));
  return <Modal open onClose={onClose} title="Chốt dòng (TRUE)" footer={<Button variant="success" loading={busy} disabled={ab && !gk} onClick={() => run(async () => {
    await db.rpc('acc_line_set', { p_id: l.id, p_status: 'ok', p_note: note || null, p_gia_khach: gk ? Number(gk) : null, p_md: md && md !== l.md ? md : null }); onDone(); }, 'Đã chốt')}>✓ Chốt</Button>}>
    {warn && <div className="mb-2 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">Dòng có cảnh báo giá — kiểm lại <b>giá khách</b> theo hệ thống trước khi chốt.</div>}
    <div className="grid grid-cols-2 gap-2">
      <Field label={ab ? 'Giá khách (đ/đv) *' : 'Giá khách (đ/đv)'} hint={gk ? money(Number(gk)) + ' đ' : ''}><Input inputMode="numeric" value={gk} onChange={e => setGk(numIn(e.target.value))} /></Field>
      <Field label="Mã đơn (MD)"><Input value={md} onChange={e => setMd(e.target.value.toUpperCase())} disabled={!!l.md} /></Field></div>
    {l.claim_md && <div className="mt-1 text-xs text-ink-500">Sale nhập: {l.claim_md}{l.claim_gia ? ` · giá khách ${money(l.claim_gia)}` : ''}</div>}
    <Field className="mt-2" label="Ghi chú"><Input value={note} onChange={e => setNote(e.target.value)} /></Field>
    <div className="mt-2 text-xs text-ink-500">Hệ thống tự tính lại biên NT; biên ngoài khung → phản hồi APT “XUẤT GIÁ …” để biên về mục tiêu.</div>
  </Modal>;
}

/** Kế toán / Admin gán dòng cho sale (kèm MD, giá khách) */
export function AssignModal({ line: l, onClose, onDone }: { line: any; onClose: () => void; onDone: () => void }) {
  const { data: dir } = useLoad(() => db.rpc<{ id: string; full_name: string }[]>('acc_sale_directory'), []);
  const { busy, run } = useAction(); const [sale, setSale] = useState(l.sale_id || ''); const [md, setMd] = useState(l.md || l.claim_md || '');
  const [gk, setGk] = useState(String(Math.round(Number(l.gia_khach) || Number(l.claim_gia) || 0) || '')); const [note, setNote] = useState('');
  return <Modal open onClose={onClose} title="Gán sale / đơn cho dòng" footer={<Button variant="primary" loading={busy} disabled={!sale || !md || !gk} onClick={() => run(async () => {
    await db.rpc('acc_line_claim', { p_id: l.id, p_md: md, p_gia_khach: Number(gk), p_note: note || null, p_sale: sale }); onDone(); }, 'Đã gán — bấm Chốt dòng khi đã kiểm')}>Gán</Button>}>
    <Field label="Sale phụ trách *"><Select placeholder="— Chọn —" options={(dir || []).map(p => [p.id, p.full_name] as [string, string])} value={sale} onChange={setSale} /></Field>
    <div className="mt-2 grid grid-cols-2 gap-2"><Field label="Mã đơn (MD) *"><Input value={md} onChange={e => setMd(e.target.value.toUpperCase())} /></Field>
      <Field label="Giá khách (đ/đv) *" hint={gk ? money(Number(gk)) + ' đ' : ''}><Input inputMode="numeric" value={gk} onChange={e => setGk(numIn(e.target.value))} /></Field></div>
    <Field className="mt-2" label="Ghi chú"><Input value={note} onChange={e => setNote(e.target.value)} /></Field>
  </Modal>;
}
