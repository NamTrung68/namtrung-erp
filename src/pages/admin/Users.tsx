import React, { useState } from 'react';
import { Layout } from '../../components/Layout';
import { Badge, Button, Card, Chips, Empty, Field, Input, Loading, Modal, NumInput, Select, Table, Td, Textarea, toast, useAction, useLoad, ask } from '../../components/ui';
import { Pager, usePager } from '../../components/Pager';
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
  const pg = usePager('users', [q]);
  const rows = ((data as any[]) || []).filter(p => !q || (p.full_name + p.email + (p.employee_code || '')).toLowerCase().includes(q.toLowerCase()));
  return (
    <Layout title="Nhân sự & phân quyền" actions={<Button variant="dark" onClick={() => setInv(true)}>Tạo tài khoản nhân sự</Button>}>
      <div className="mb-3 flex gap-2"><Input className="max-w-xs" placeholder="Tìm tên, email, mã NV…" value={q} onChange={e => setQ(e.target.value)} /></div>
      <Card bodyClass="p-0">{loading ? <Loading /> : <Table head={['Mã', 'Họ tên', 'Email', 'Cấp bậc', 'Vai trò', 'Quản lý trực tiếp', 'Phòng', 'Lịch', 'Trạng thái']}>
        {pg.slice(rows).map(p => <tr key={p.id} className="cursor-pointer hover:bg-ink-50" onClick={() => setEdit(p)}>
          <Td>{p.employee_code}</Td><Td className="font-medium">{p.full_name}{p.is_new_hire && <Badge className="ml-1" color="blue">Mới</Badge>}</Td><Td className="text-xs">{p.email}</Td>
          <Td>{a.levels.find(l => l.code === p.job_level)?.name}</Td><Td><div className="flex flex-wrap gap-1">{p.roles.map((r: string) => <Badge key={r} color={['admin', 'bgd'].includes(r) ? 'purple' : 'gray'}>{ROLES.find(x => x[0] === r)?.[1] || r}</Badge>)}</div></Td>
          <Td>{a.personName(p.manager_id)}</Td><Td>{a.units.find(u => u.id === p.org_unit_id)?.name}</Td><Td className="text-xs">{p.work_schedule}</Td>
          <Td><Badge color={p.status === 'active' ? 'green' : 'gray'}>{p.status === 'active' ? 'Đang làm' : 'Đã nghỉ'}</Badge></Td></tr>)}
      </Table>}<Pager p={pg} total={rows.length} /></Card>
      {((invites as any[]) || []).length > 0 && <Card title="Lời mời chưa kích hoạt" className="mt-4" bodyClass="p-0"><Table head={['Email', 'Họ tên', 'Vai trò', 'Ngày mời', '']}>{(invites as any[]).map(i => (
        <tr key={i.email}><Td>{i.email}</Td><Td>{i.full_name}</Td><Td>{i.roles.join(', ')}</Td><Td>{fmtDate(i.created_at)}</Td>
          <Td><Button size="sm" variant="ghost" onClick={() => run(async () => { await db.from('invites').delete().eq('email', i.email); ri(); }, 'Đã hủy lời mời')}>Hủy</Button></Td></tr>))}</Table>
        <p className="px-4 py-2 text-xs text-ink-500">Lời mời chưa có tài khoản: bấm Hủy rồi tạo lại kèm mật khẩu tạm.</p></Card>}
      {inv && <Invite onClose={() => setInv(false)} onDone={() => { setInv(false); ri(); }} />}
      {edit && <EditUser p={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); reload(); a.reload(); }} />}
    </Layout>
  );
}

function Invite({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [f, setF] = useState({ email: '', full_name: '', roles: ['sale'], job_level: 'nhan_vien', manager: '', org: '', schedule: 'office', code: '', pw: '' }); const { busy, run } = useAction();
  const roleOpts = a.isAdmin ? ROLES : ROLES.filter(r => !['admin', 'bgd'].includes(r[0]));
  return (
    <Modal open onClose={onClose} title="Tạo tài khoản nhân sự" footer={<Button variant="primary" loading={busy} onClick={() => run(async () => {
      if (!/^\S+@\S+\.\S+$/.test(f.email)) throw new Error('Email không hợp lệ');
      await db.rpc('invite_user', { p_email: f.email, p_full_name: f.full_name, p_roles: f.roles, p_job_level: f.job_level || null, p_manager: f.manager || null, p_org: f.org || null, p_schedule: f.schedule, p_code: f.code || null });
      if (f.pw.length < 8) throw new Error('Mật khẩu tạm tối thiểu 8 ký tự');
      await auth.signUp(f.email, f.pw, false);
      toast.ok('Đã tạo tài khoản. Gửi email + mật khẩu tạm cho nhân sự, nhắc đổi mật khẩu ở mục Tài khoản.');
      onDone();
    })}>Tạo tài khoản</Button>}>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Email đăng nhập" required><Input value={f.email} onChange={e => setF({ ...f, email: e.target.value })} /></Field>
        <Field label="Họ tên" required><Input value={f.full_name} onChange={e => setF({ ...f, full_name: e.target.value })} /></Field>
        <Field label="Mã nhân viên" hint="để trống = tự sinh"><Input value={f.code} onChange={e => setF({ ...f, code: e.target.value })} /></Field>
        <Field label="Cấp bậc"><Select options={a.levels.map(l => [l.code, l.name])} value={f.job_level} onChange={v => setF({ ...f, job_level: v })} /></Field>
        <Field label="Quản lý trực tiếp (người duyệt đơn)"><Select options={a.people.map(p => [p.id, p.full_name])} value={f.manager} onChange={v => setF({ ...f, manager: v })} placeholder="— Không —" /></Field>
        <Field label="Phòng ban"><Select options={a.units.map(u => [u.id, u.name])} value={f.org} onChange={v => setF({ ...f, org: v })} placeholder="— Chọn —" /></Field>
        <Field label="Lịch làm việc" className="sm:col-span-2"><Select options={SCHED} value={f.schedule} onChange={v => setF({ ...f, schedule: v })} /></Field>
        <Field label="Vai trò" className="sm:col-span-2"><Chips options={roleOpts} value={f.roles} onChange={v => setF({ ...f, roles: v })} /></Field>
        <Field label="Mật khẩu tạm" required className="sm:col-span-2" hint="Tối thiểu 8 ký tự. Nhân sự đăng nhập rồi tự đổi ở mục Tài khoản."><div className="flex gap-2"><Input type="text" value={f.pw} onChange={e => setF({ ...f, pw: e.target.value })} />
          <Button type="button" onClick={() => setF({ ...f, pw: 'NT' + Math.random().toString(36).slice(2, 8) + Math.floor(10 + Math.random() * 89) })}>Tạo ngẫu nhiên</Button></div></Field>
      </div>
    </Modal>
  );
}

function EditUser({ p, onClose, onDone }: { p: any; onClose: () => void; onDone: () => void }) {
  const a = useApp(); const [f, setF] = useState({ ...p, sale_aliases: (p.sale_aliases || []).join(', ') });
  const { data: priv } = useLoad(() => db.from('profile_private').select('*').eq('profile_id', p.id).maybeSingle(), [p.id]);
  const [pv, setPv] = useState<any>(null); const pp = pv || priv || {};
  const canHR = a.isAdmin || a.has('hcns', 'bgd');
  const { data: rec } = useLoad(() => canHR ? db.from('hr_records').select('profile_id,dob').eq('profile_id', p.id).maybeSingle() : Promise.resolve(null), [p.id]);
  const [dob, setDob] = useState<string | null>(null); const dobVal = dob ?? (rec as any)?.dob ?? '';
  const [newPw, setNewPw] = useState<string | null>(null);
  const resetPw = async () => {
    const pw = await ask({ title: `Đặt lại mật khẩu · ${p.full_name}`, message: 'Tài khoản sẽ bị đăng xuất khỏi mọi thiết bị. Gửi mật khẩu mới cho nhân sự và nhắc đổi lại ở mục Tài khoản.',
      input: { label: 'Mật khẩu mới (tối thiểu 8 ký tự)', required: true, value: 'NT' + Math.random().toString(36).slice(2, 8) + Math.floor(10 + Math.random() * 89) }, ok: 'Đặt lại' });
    if (!pw) return;
    run(async () => { await db.rpc('admin_set_password', { p_user: p.id, p_password: pw }); setNewPw(pw); }, 'Đã đặt lại mật khẩu');
  };
  const { busy, run } = useAction();
  const roleOpts = a.isAdmin ? ROLES : ROLES.filter(r => !['admin', 'bgd'].includes(r[0]));
  const save = () => run(async () => {
    await db.from('profiles').update({ full_name: f.full_name, employee_code: f.employee_code || null, phone: f.phone || null, job_level: f.job_level || null, manager_id: f.manager_id || null,
      org_unit_id: f.org_unit_id || null, roles: f.roles, work_schedule: f.work_schedule, status: f.status, is_new_hire: f.is_new_hire, hire_date: f.hire_date || null,
      sale_aliases: String(f.sale_aliases || '').split(',').map((s: string) => s.trim()).filter(Boolean) }).eq('id', p.id);
    if (canHR && dob !== null) {
      if (rec) await db.from('hr_records').update({ dob: dob || null }).eq('profile_id', p.id); else await db.from('hr_records').insert({ profile_id: p.id, dob: dob || null });
    }
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
    <Modal open onClose={onClose} title={`${p.full_name} · ${p.email}`} size="lg" footer={<><Button onClick={adjustLeave}>Điều chỉnh sổ phép</Button>{(a.isAdmin || (a.has('hcns') && !p.roles.some((r: string) => ['admin', 'bgd'].includes(r)))) && p.id !== a.me.id && <Button className="mr-auto" onClick={resetPw}>🔑 Đặt lại mật khẩu</Button>}<Button variant="primary" loading={busy} onClick={save}>Lưu</Button></>}>
      {newPw && <div className="mb-3 flex flex-wrap items-center gap-2 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm">Mật khẩu mới: <b className="font-mono text-base">{newPw}</b>
        <Button size="sm" onClick={() => navigator.clipboard.writeText(`Tài khoản ERP Nam Trung\nEmail: ${p.email}\nMật khẩu mới: ${newPw}\nĐăng nhập rồi đổi mật khẩu ở mục Tài khoản.`).then(() => toast.ok('Đã sao chép tin nhắn gửi nhân sự'))}>Sao chép tin nhắn</Button></div>}
      <div className="grid gap-3 sm:grid-cols-3">
        <Field label="Họ tên"><Input value={f.full_name} onChange={e => set('full_name')(e.target.value)} /></Field>
        <Field label="Mã nhân viên"><Input value={f.employee_code || ''} onChange={e => set('employee_code')(e.target.value)} /></Field>
        <Field label="Điện thoại"><Input value={f.phone || ''} onChange={e => set('phone')(e.target.value)} /></Field>
        <Field label="Cấp bậc"><Select options={a.levels.map(l => [l.code, l.name])} value={f.job_level || ''} onChange={set('job_level')} placeholder="—" /></Field>
        <Field label="Quản lý trực tiếp"><Select options={a.people.filter(x => x.id !== p.id).map(x => [x.id, x.full_name])} value={f.manager_id || ''} onChange={set('manager_id')} placeholder="— Không —" /></Field>
        <Field label="Phòng ban"><Select options={a.units.map(u => [u.id, u.name])} value={f.org_unit_id || ''} onChange={set('org_unit_id')} placeholder="—" /></Field>
        <Field label="Lịch làm việc"><Select options={SCHED} value={f.work_schedule} onChange={set('work_schedule')} /></Field>
        <Field label="Ngày vào làm"><Input type="date" value={f.hire_date || ''} onChange={e => set('hire_date')(e.target.value)} /></Field>
        {canHR && <Field label="Ngày sinh 🎂" hint="Hiện ngày/tháng ở mục Sinh nhật, không hiện năm"><Input type="date" value={dobVal} onChange={e => setDob(e.target.value)} /></Field>}
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
