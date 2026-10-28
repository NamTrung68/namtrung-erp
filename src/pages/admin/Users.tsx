import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Chips, Empty, Field, Input, Loading, Modal, NumInput, Select, Table, Td, Textarea, toast, useAction, useLoad, ask } from '../../components/ui';
import { auth, db } from '../../lib/sb';
import { useApp } from '../../state';
import { BANKS } from '../../lib/vietqr';
import { fmtDate } from '../../lib/format';

export const ROLES: [string, string][] = [['admin', 'Admin hệ thống'], ['bgd', 'Ban giám đốc'], ['hcns', 'HCNS'], ['ke_toan', 'Kế toán'], ['tp_kd', 'Trưởng phòng KD'], ['tn_kd', 'Trưởng nhóm KD'], ['sale', 'Sale'], ['nhan_vien', 'Nhân viên (phòng khác)']];
const SCHED: [string, string][] = [['office', 'Văn phòng (T2–sáng T7, chấm công)'], ['warehouse', 'Kho (T2–T7, không chấm công)'], ['none', 'Không chấm công']];

export default function Users() {
  const a = useApp(); const [q, setQ] = useState(''); const [edit, setEdit] = useState<any>(null); const [inv, setInv] = useState(false);
  const { data, loading, reload } = useLoad(() => db.from('profiles').select('*').order('full_name'), []);
  const { data: invites, reload: ri } = useLoad(() => db.from('invites').select('*').is('used_at', null).order('created_at', { asc: false }), []);
  const { run } = useAction();
  const rows = ((data as any[]) || []).filter(p => !q || (p.full_name + p.email + (p.employee_code || '')).toLowerCase().includes(q.toLowerCase()));
  return (
    <Layout title="Nhân sự & phân quyền" actions={<Button variant="dark" onClick={() => setInv(true)}>Mời nhân sự</Button>}>
      <div className="mb-3 flex gap-2"><Input className="max-w-xs" placeholder="Tìm tên, email, mã NV…" value={q} onChange={e => setQ(e.target.value)} /></div>
      <Card bodyClass="p-0">{loading ? <Loading /> : <Table head={['Mã', 'Họ tên', 'Email', 'Cấp bậc', 'Vai trò', 'Quản lý trực tiếp', 'Phòng', 'Lịch', 'Trạng thái']}>
        {rows.map(p => <tr key={p.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setEdit(p)}>
          <Td>{p.employee_code}</Td><Td className="font-medium">{p.full_name}{p.is_new_hire && <Badge className="ml-1" color="blue">Mới</Badge>}</Td><Td className="text-xs">{p.email}</Td>
          <Td>{a.levels.find(l => l.code === p.job_level)?.name}</Td><Td><div className="flex flex-wrap gap-1">{p.roles.map((r: string) => <Badge key={r} color={['admin', 'bgd'].includes(r) ? 'purple' : 'gray'}>{ROLES.find(x => x[0] === r)?.[1] || r}</Badge>)}</div></Td>
          <Td>{a.personName(p.manager_id)}</Td><Td>{a.units.find(u => u.id === p.org_unit_id)?.name}</Td><Td className="text-xs">{p.work_schedule}</Td>
          <Td><Badge color={p.status === 'active' ? 'green' : 'gray'}>{p.status === 'active' ? 'Đang làm' : 'Đã nghỉ'}</Badge></Td></tr>)}
      </Table>}</Card>
      {((invites as any[]) || []).length > 0 && <Card title="Lời mời chưa kích hoạt" className="mt-4" bodyClass="p-0"><Table head={['Email', 'Họ tên', 'Vai trò', 'Ngày mời', '']}>{(invites as any[]).map(i => (
        <tr key={i.email}><Td>{i.email}</Td><Td>{i.full_name}</Td><Td>{i.roles.join(', ')}</Td><Td>{fmtDate(i.created_at)}</Td>
          <Td><Button size="sm" variant="ghost" onClick={() => run(async () => { await db.from('invites').delete().eq('email', i.email); ri(); }, 'Đã hủy lời mời')}>Hủy</Button></Td></tr>))}</Table>
        <p className="px-4 py-2 text-xs text-ink-500">Gửi link ứng dụng cho nhân sự → chọn "Kích hoạt tài khoản" → nhập đúng email được mời và đặt mật khẩu.</p></Card>}
      {inv && <Invite onClose={() => setInv(false)} onDone={() => { setInv(false); ri(); }} />}
      {edit && <EditUser p={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); reload(); a.reload(); }} />}
    </Layout>
  );
}

function Invite({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [f, setF] = useState({ email: '', full_name: '', roles: ['sale'], job_level: 'nhan_vien', manager: '', org: '', schedule: 'office', code: '', pw: '' }); const { busy, run } = useAction();
  const roleOpts = a.isAdmin ? ROLES : ROLES.filter(r => !['admin', 'bgd'].includes(r[0]));
  return (
    <Modal open onClose={onClose} title="Mời nhân sự" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      if (!/^\S+@\S+\.\S+$/.test(f.email)) throw new Error('Email không hợp lệ');
      await db.rpc('invite_user', { p_email: f.email, p_full_name: f.full_name, p_roles: f.roles, p_job_level: f.job_level || null, p_manager: f.manager || null, p_org: f.org || null, p_schedule: f.schedule, p_code: f.code || null });
      if (f.pw) { if (f.pw.length < 8) throw new Error('Mật khẩu tạm tối thiểu 8 ký tự'); await auth.signUp(f.email, f.pw, false); toast.ok('Đã tạo tài khoản. Gửi email + mật khẩu tạm cho nhân sự.'); }
      onDone();
    }, 'Đã tạo lời mời')}>Lưu</Button>}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Email đăng nhập" required><Input value={f.email} onChange={e => setF({ ...f, email: e.target.value })} /></Field>
        <Field label="Họ tên" required><Input value={f.full_name} onChange={e => setF({ ...f, full_name: e.target.value })} /></Field>
        <Field label="Mã nhân viên" hint="để trống = tự sinh"><Input value={f.code} onChange={e => setF({ ...f, code: e.target.value })} /></Field>
        <Field label="Cấp bậc"><Select options={a.levels.map(l => [l.code, l.name])} value={f.job_level} onChange={v => setF({ ...f, job_level: v })} /></Field>
        <Field label="Quản lý trực tiếp (người duyệt đơn)"><Select options={a.people.map(p => [p.id, p.full_name])} value={f.manager} onChange={v => setF({ ...f, manager: v })} placeholder="— Không —" /></Field>
        <Field label="Phòng ban"><Select options={a.units.map(u => [u.id, u.name])} value={f.org} onChange={v => setF({ ...f, org: v })} placeholder="— Chọn —" /></Field>
        <Field label="Lịch làm việc" className="sm:col-span-2"><Select options={SCHED} value={f.schedule} onChange={v => setF({ ...f, schedule: v })} /></Field>
        <Field label="Vai trò" className="sm:col-span-2"><Chips options={roleOpts} value={f.roles} onChange={v => setF({ ...f, roles: v })} /></Field>
        <Field label="Tạo luôn tài khoản với mật khẩu tạm (không bắt buộc)" className="sm:col-span-2" hint="Để trống: nhân sự tự kích hoạt trên màn hình đăng nhập."><Input type="text" value={f.pw} onChange={e => setF({ ...f, pw: e.target.value })} /></Field>
      </div>
    </Modal>
  );
}

function EditUser({ p, onClose, onDone }: { p: any; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [f, setF] = useState({ ...p, sale_aliases: (p.sale_aliases || []).join(', ') });
  const { data: priv } = useLoad(() => db.from('profile_private').select('*').eq('profile_id', p.id).maybeSingle(), [p.id]);
  const [pv, setPv] = useState<any>(null); const pp = pv || priv || {};
  const { busy, run } = useAction();
  const roleOpts = a.isAdmin ? ROLES : ROLES.filter(r => !['admin', 'bgd'].includes(r[0]));
  const save = () => run(async () => {
    await db.from('profiles').update({ full_name: f.full_name, employee_code: f.employee_code || null, phone: f.phone || null, job_level: f.job_level || null, manager_id: f.manager_id || null,
      org_unit_id: f.org_unit_id || null, roles: f.roles, work_schedule: f.work_schedule, status: f.status, is_new_hire: f.is_new_hire, hire_date: f.hire_date || null,
      sale_aliases: String(f.sale_aliases || '').split(',').map((s: string) => s.trim()).filter(Boolean) }).eq('id', p.id);
    if (pv && (a.isAdmin || a.has('hcns', 'ke_toan'))) {
      const body = { profile_id: p.id, base_salary: pp.base_salary ?? null, allowance: pp.allowance ?? 0, insurance_deduction: pp.insurance_deduction ?? 0, bank_bin: pp.bank_bin || null, bank_account: pp.bank_account || null, bank_holder: pp.bank_holder || null };
      if (priv) await db.from('profile_private').update(body).eq('profile_id', p.id); else await db.from('profile_private').insert(body);
    }
    onDone();
  }, 'Đã lưu');
  const adjustLeave = async () => {
    const d = await ask({ title: 'Điều chỉnh sổ phép', input: { label: 'Số ngày (+ cộng, − trừ)', required: true } }); if (!d) return;
    const note = await ask({ title: 'Lý do điều chỉnh', input: { label: 'Lý do', required: true } }); if (!note) return;
    run(async () => { await db.from('leave_ledger').insert({ profile_id: p.id, kind: 'adjust', days: Number(d.replace(',', '.')), note }); }, 'Đã điều chỉnh sổ phép');
  };
  const set = (k: string) => (v: any) => setF((x: any) => ({ ...x, [k]: v }));
  const setP = (k: string) => (v: any) => setPv({ ...pp, [k]: v });
  return (
    <Modal open onClose={onClose} title={`${p.full_name} · ${p.email}`} size="lg" footer={<><Button className="mr-auto" onClick={adjustLeave}>Điều chỉnh sổ phép</Button><Button variant="primary" loading={busy} onClick={save}>Lưu</Button></>}>
      <div className="grid gap-3 sm:grid-cols-3">
        <Field label="Họ tên"><Input value={f.full_name} onChange={e => set('full_name')(e.target.value)} /></Field>
        <Field label="Mã nhân viên"><Input value={f.employee_code || ''} onChange={e => set('employee_code')(e.target.value)} /></Field>
        <Field label="Điện thoại"><Input value={f.phone || ''} onChange={e => set('phone')(e.target.value)} /></Field>
        <Field label="Cấp bậc"><Select options={a.levels.map(l => [l.code, l.name])} value={f.job_level || ''} onChange={set('job_level')} placeholder="—" /></Field>
        <Field label="Quản lý trực tiếp"><Select options={a.people.filter(x => x.id !== p.id).map(x => [x.id, x.full_name])} value={f.manager_id || ''} onChange={set('manager_id')} placeholder="— Không —" /></Field>
        <Field label="Phòng ban"><Select options={a.units.map(u => [u.id, u.name])} value={f.org_unit_id || ''} onChange={set('org_unit_id')} placeholder="—" /></Field>
        <Field label="Lịch làm việc"><Select options={SCHED} value={f.work_schedule} onChange={set('work_schedule')} /></Field>
        <Field label="Ngày vào làm"><Input type="date" value={f.hire_date || ''} onChange={e => set('hire_date')(e.target.value)} /></Field>
        <Field label="Trạng thái"><Select options={[['active', 'Đang làm'], ['inactive', 'Đã nghỉ (khóa đăng nhập)']]} value={f.status} onChange={set('status')} /></Field>
        <Field label="Vai trò" className="sm:col-span-3"><Chips options={roleOpts} value={f.roles} onChange={set('roles')} /></Field>
        <Field label="Tên trong file đơn hoàn thành (cột Nhân viên KD), cách nhau dấu phẩy" className="sm:col-span-2"><Input value={f.sale_aliases} onChange={e => set('sale_aliases')(e.target.value)} placeholder="VD: Khơi Lê, Trungdv22" /></Field>
        <label className="flex items-end gap-2 pb-2 text-sm"><input type="checkbox" checked={f.is_new_hire} onChange={e => set('is_new_hire')(e.target.checked)} /> Nhân viên mới (KPI × 0,7)</label>
      </div>
      {(a.isAdmin || a.has('hcns', 'ke_toan')) && <div className="mt-4 rounded-xl border border-ink-200 p-3">
        <div className="mb-2 text-sm font-semibold">Lương & tài khoản (bảo mật)</div>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="Lương cơ bản / tháng"><NumInput value={pp.base_salary} onChange={setP('base_salary')} /></Field>
          <Field label="Phụ cấp / tháng"><NumInput value={pp.allowance} onChange={setP('allowance')} /></Field>
          <Field label="Khấu trừ BHXH / tháng"><NumInput value={pp.insurance_deduction} onChange={setP('insurance_deduction')} /></Field>
          <Field label="Ngân hàng"><Select options={BANKS} value={pp.bank_bin || ''} onChange={setP('bank_bin')} placeholder="—" /></Field>
          <Field label="Số tài khoản"><Input value={pp.bank_account || ''} onChange={e => setP('bank_account')(e.target.value)} /></Field>
          <Field label="Chủ tài khoản"><Input value={pp.bank_holder || ''} onChange={e => setP('bank_holder')(e.target.value.toUpperCase())} /></Field>
        </div>
      </div>}
    </Modal>
  );
}
