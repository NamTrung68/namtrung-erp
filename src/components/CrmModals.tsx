import React, { useEffect, useMemo, useState } from 'react';
import { Button, Chips, cx, Field, Input, Modal, Select, Textarea, toast, useAction } from './ui';
import { db } from '../lib/sb';
import { useApp } from '../state';
import { addDays, fmtDate, today } from '../lib/format';
import { CustomerPicker } from './CustomerPicker';

export function dupText(d: any) {
  switch (d.status) {
    case 'company_active': return `⛔ KHÁCH ĐANG CHẠY CỦA CÔNG TY: ${d.name || ''} (phụ trách ${d.owner || '?'}, đơn gần nhất ${fmtDate(d.last_order)}). Không được tạo hồ sơ, chăm sóc hay báo giá.`;
    case 'company_sleep': return `Khách cũ đã ngủ của công ty (${d.name || ''}, đơn gần nhất ${fmtDate(d.last_order)}). Được đánh thức — chọn nguồn "Kho khách ngủ".`;
    case 'owned_by_other': return `⛔ Khách ${d.code} đã có chủ: ${d.owner}. Không được tiếp cận.`;
    case 'shared': return `⚠️ Khách ${d.code} đang được ${d.owner} theo (sân chung). Báo Trưởng nhóm thống nhất 1 đầu mối, 1 báo giá.`;
    case 'visible': return `Khách đã có trong hệ thống: ${d.code} – ${d.name} (${d.ownership === 'owned' ? 'chủ khách' : 'đang theo'}: ${d.owner}).`;
    default: return 'Chưa có trong hệ thống — tạo mới được.';
  }
}

export function DuplicateCheck({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [phone, setPhone] = useState(''); const [tax, setTax] = useState(''); const [r, setR] = useState<any>(null); const { busy, run } = useAction();
  return (
    <Modal open={open} onClose={onClose} title="Kiểm tra SĐT / MST trước khi tiếp cận" size="sm"
      footer={<Button variant="dark" loading={busy} onClick={() => run(async () => setR(await db.rpc('check_duplicate', { p_phone: phone || null, p_tax: tax || null })))}>Kiểm tra</Button>}>
      <div className="space-y-3">
        <Field label="Số điện thoại / Zalo"><Input value={phone} onChange={e => setPhone(e.target.value)} inputMode="tel" /></Field>
        <Field label="Mã số thuế"><Input value={tax} onChange={e => setTax(e.target.value)} /></Field>
        {r && <div className={cx('rounded-lg border p-3 text-sm', r.status === 'none' || r.status === 'company_sleep' ? 'border-emerald-200 bg-emerald-50 text-emerald-800' : r.status === 'visible' ? 'border-amber-200 bg-amber-50' : 'border-red-200 bg-red-50 text-red-800')}>
          {dupText(r)} {r.status === 'visible' && <a className="text-brand-700 underline" href={`#/crm/customer?id=${r.id}`} onClick={onClose}>Mở hồ sơ</a>}
          {(r.status === 'none' || r.status === 'company_sleep') && <a className="ml-1 text-brand-700 underline" href="#/crm/customers?new=1" onClick={onClose}>Tạo khách mới</a>}</div>}
      </div>
    </Modal>
  );
}

export function CareModal({ open, customer, onClose, onSaved }: { open: boolean; customer: any; onClose: () => void; onSaved: () => void }) {
  const a = useApp();
  const init = () => ({ channel: 'goi_dien', purpose: customer.care_count > 0 ? 'cham_soc_khach_cu' : 'tiep_can_lan_dau', result: '', content: '', stage_after: customer.stage, temperature_after: customer.temperature, next_care_date: '', quotation_code: '' });
  const [f, setF] = useState<any>(init); const { busy, run } = useAction();
  useEffect(() => { if (open) setF(init()); }, [open]);
  const stageCad = (s: string) => a.lk('stage', s)?.extra?.cadence ?? 99; const tempCad = (t: string) => a.lk('temperature', t)?.extra?.cadence ?? 99;
  const suggest = useMemo(() => {
    if (f.stage_after === 'khong_tiem_nang') return '';
    let d = addDays(today(), Math.min(stageCad(f.stage_after), tempCad(f.temperature_after)));
    if (new Date(d + 'T00:00:00Z').getUTCDay() === 0) d = addDays(d, 1);
    return d;
  }, [f.stage_after, f.temperature_after]);
  const pickResult = (r: string) => {
    const ex = a.lk('care_result', r)?.extra || {};
    setF((x: any) => ({ ...x, result: r, stage_after: ex.stage && (a.lk('stage', ex.stage)?.sort ?? 0) > (a.lk('stage', x.stage_after)?.sort ?? 0) ? ex.stage : x.stage_after, temperature_after: ex.temp || x.temperature_after }));
    if (ex.hint) toast.info(ex.hint);
  };
  const save = () => run(async () => {
    if (!f.result) throw new Error('Chọn kết quả');
    if (f.content.trim().length < 15) throw new Error('Nội dung trao đổi tối thiểu 15 ký tự');
    await db.from('care_logs').insert({ customer_id: customer.id, channel: f.channel, purpose: f.purpose, result: f.result, content: f.content.trim(),
      stage_after: f.stage_after, temperature_after: f.temperature_after, next_care_date: f.next_care_date || null, quotation_code: f.quotation_code || null });
    onSaved();
  }, 'Đã lưu chăm sóc');
  const purposes = a.opts('care_purpose').filter(([v]) => customer.care_count === 0 || v !== 'tiep_can_lan_dau');
  return (
    <Modal open={open} onClose={onClose} title={`Ghi chăm sóc: ${customer.company_name || customer.contact_name}`} size="md"
      footer={<><span className="mr-auto text-xs text-ink-400">Ctrl + Enter để lưu</span><Button onClick={onClose}>Hủy</Button><Button variant="primary" loading={busy} onClick={save}>Lưu chăm sóc</Button></>}>
      <div className="space-y-3" onKeyDown={e => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) save(); }}>
        <Field label="Kênh liên hệ"><Chips options={a.opts('channel')} value={[f.channel]} onChange={v => setF({ ...f, channel: v.filter(x => x !== f.channel)[0] || f.channel })} /></Field>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Mục đích"><Select options={purposes} value={f.purpose} onChange={v => setF({ ...f, purpose: v })} /></Field>
          <Field label="Giai đoạn sau lần chăm này"><Select options={a.opts('stage')} value={f.stage_after} onChange={v => setF({ ...f, stage_after: v })} /></Field>
        </div>
        <Field label="Kết quả"><Chips options={a.opts('care_result')} value={f.result ? [f.result] : []} onChange={v => pickResult(v.filter(x => x !== f.result)[0] || f.result)} /></Field>
        <Field label="Nội dung trao đổi (tối thiểu 15 ký tự)"><Textarea rows={4} autoFocus placeholder="Khách nhập mặt hàng gì, khối lượng, đang dùng đơn vị nào, vướng gì, hẹn gì…" value={f.content} onChange={e => setF({ ...f, content: e.target.value })} /></Field>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="Mức độ"><Chips options={a.opts('temperature')} value={[f.temperature_after]} onChange={v => setF({ ...f, temperature_after: v.filter(x => x !== f.temperature_after)[0] || f.temperature_after })} /></Field>
          <Field label="Hẹn chăm tiếp" hint={suggest ? `Gợi ý theo nhịp chăm: ${fmtDate(suggest)}` : 'Không hẹn'}><Input type="date" min={today()} value={f.next_care_date || suggest} onChange={e => setF({ ...f, next_care_date: e.target.value })} /></Field>
          <Field label="Mã báo giá liên quan"><Input placeholder="Không bắt buộc" value={f.quotation_code} onChange={e => setF({ ...f, quotation_code: e.target.value })} /></Field>
        </div>
      </div>
    </Modal>
  );
}


/** Ghi chăm sóc nhanh từ bất kỳ trang nào */
export function QuickCare({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [c, setC] = useState<any>(null);
  const [full, setFull] = useState<any>(null);
  useEffect(() => { if (!open) { setC(null); setFull(null); } }, [open]);
  useEffect(() => { if (c) db.from('customers').select('*').eq('id', c.id).maybeSingle().then(setFull, (e: any) => toast.err(e)); }, [c?.id]);
  if (!open) return null;
  if (full) return <CareModal open customer={full} onClose={onClose} onSaved={onClose} />;
  return (
    <Modal open onClose={onClose} title="Ghi chăm sóc nhanh" size="sm">
      <Field label="Chọn khách (gõ tên, mã KH, SĐT)"><CustomerPicker value={c} onChange={setC} /></Field>
      <p className="mt-2 text-xs text-ink-500">Chọn khách xong sẽ mở ngay form ghi chăm sóc.</p>
    </Modal>
  );
}

export const PRIORITY: [string, string][] = [['thuong', 'Bình thường'], ['gap', 'Gấp'], ['khan', 'Khẩn']];
/** Chỉ đạo sale (quản lý → sale phụ trách) hoặc Nhờ hỗ trợ (sale → quản lý/đồng nghiệp) gắn với khách */
export function DirectiveModal({ kind, customer, onClose, onDone }: { kind: string; customer: any; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const isDir = kind === 'chi_dao';
  const [f, setF] = useState({ topic: '', priority: 'thuong', due_date: '', content: '', assignee: isDir ? customer.owner_id : (a.me.manager_id || '') });
  const { busy, run } = useAction();
  const send = () => run(async () => {
    if (!f.topic || f.content.trim().length < 5) throw new Error('Chọn chủ đề và ghi rõ nội dung');
    if (!f.assignee) throw new Error('Chọn người nhận');
    await db.from('support_requests').insert({ kind, requester_id: a.me.id, assignee_id: f.assignee, customer_id: customer.id, topic: f.topic,
      title: a.label(isDir ? 'directive_topic' : 'help_topic', f.topic), content: f.content.trim(), priority: f.priority, due_date: f.due_date || null });
    onDone();
  }, isDir ? 'Đã gửi chỉ đạo' : 'Đã gửi nhờ hỗ trợ');
  return (
    <Modal open onClose={onClose} title={`${isDir ? 'Chỉ đạo sale' : 'Nhờ hỗ trợ'}: ${customer.company_name || customer.contact_name}`} size="md"
      footer={<><Button onClick={onClose}>Hủy</Button><Button variant="primary" loading={busy} onClick={send}>Gửi</Button></>}>
      <div className="space-y-3">
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="Chủ đề" required><Select options={a.opts(isDir ? 'directive_topic' : 'help_topic')} value={f.topic} onChange={v => setF({ ...f, topic: v })} placeholder="— Chọn —" /></Field>
          <Field label="Mức ưu tiên"><Select options={PRIORITY} value={f.priority} onChange={v => setF({ ...f, priority: v })} /></Field>
          <Field label="Hạn hoàn thành"><Input type="date" value={f.due_date} onChange={e => setF({ ...f, due_date: e.target.value })} /></Field>
        </div>
        {isDir ? <p className="text-sm">Gửi tới sale phụ trách: <b>{a.personName(customer.owner_id)}</b></p> :
          <Field label="Nhờ ai" required><Select options={a.people.filter(p => p.id !== a.me.id && p.status === 'active').map(p => [p.id, p.full_name])} value={f.assignee} onChange={v => setF({ ...f, assignee: v })} placeholder="— Chọn —" /></Field>}
        <Field label={isDir ? 'Việc sale cần làm với khách này, hạn và kết quả mong muốn' : 'Cần hỗ trợ gì, tình hình khách hiện tại'}>
          <Textarea rows={4} value={f.content} onChange={e => setF({ ...f, content: e.target.value })} placeholder={isDir ? 'VD: Gọi lại trước thứ 6, đề xuất gom 2 lô để đủ khối, gửi case khách gia dụng tương tự…' : 'VD: Khách chê giá cước, xin anh/chị gọi cùng để chốt…'} /></Field>
        <p className="text-xs text-ink-500">{isDir ? 'Sale sẽ nhận thông báo, thấy chỉ đạo ở mục Hỗ trợ khách và phải phản hồi hoặc báo kết quả.' : 'Người nhận được thông báo ngay; trao đổi tiếp ở mục Hỗ trợ khách.'}</p>
      </div>
    </Modal>
  );
}
