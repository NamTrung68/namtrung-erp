import React, { useEffect, useState } from 'react';
import { Layout } from '../components/Layout';
import { Badge, Button, Card, Field, Input, Select, useAction, useLoad, toast } from '../components/ui';
import { auth, db } from '../lib/sb';
import { useApp } from '../state';
import { BANKS } from '../lib/vietqr';
import { stripVN } from '../lib/format';
import { ROLES } from './admin/Users';

export default function Account() {
  const a = useApp(); const { busy, run } = useAction();
  const recovery = sessionStorage.getItem('nt_recovery') === '1';
  const [pw, setPw] = useState(''); const [pw2, setPw2] = useState('');
  const { data: priv } = useLoad(() => db.from('profile_private').select('bank_bin,bank_account,bank_holder').eq('profile_id', a.me.id).maybeSingle(), []);
  const [bank, setBank] = useState<any>({}); useEffect(() => { if (priv) setBank(priv); }, [priv]);
  const [perm, setPerm] = useState(typeof Notification !== 'undefined' ? Notification.permission : 'unsupported');
  const [phone, setPhone] = useState(''); const { data: myDob, reload: rDob } = useLoad(() => db.rpc<string | null>('my_dob'), []); const [dob, setDob] = useState('');
  useEffect(() => { db.from('profiles').select('phone').eq('id', a.me.id).maybeSingle().then((p: any) => setPhone(p?.phone || '')); }, []);
  return (
    <Layout title="Tài khoản của tôi">
      <div className="grid max-w-4xl gap-4 md:grid-cols-2">
        {recovery && <Card title="Đặt mật khẩu mới" className="md:col-span-2"><p className="text-sm">Bạn vừa mở link đặt lại mật khẩu. Nhập mật khẩu mới bên dưới.</p></Card>}
        <Card title="Thông tin">
          <dl className="space-y-1.5 text-sm">
            <div><dt className="inline text-ink-500">Họ tên: </dt><dd className="inline font-medium">{a.me.full_name}</dd></div>
            <div><dt className="inline text-ink-500">Email: </dt><dd className="inline">{a.me.email}</dd></div>
            <div><dt className="inline text-ink-500">Mã NV: </dt><dd className="inline">{a.me.employee_code}</dd></div>
            <div><dt className="inline text-ink-500">Cấp bậc: </dt><dd className="inline">{a.me.job_level_name || '—'}</dd></div>
            <div><dt className="inline text-ink-500">Quản lý trực tiếp: </dt><dd className="inline">{a.me.manager_name || '—'}</dd></div>
            <div className="flex flex-wrap gap-1"><dt className="text-ink-500">Vai trò: </dt>{a.me.roles.map(r => <Badge key={r}>{ROLES.find(x => x[0] === r)?.[1] || r}</Badge>)}</div>
          </dl>
          <Field label="Số điện thoại" className="mt-3"><div className="flex gap-2"><Input value={phone} onChange={e => setPhone(e.target.value)} />
            <Button loading={busy} onClick={() => run(async () => { await db.from('profiles').update({ phone }).eq('id', a.me.id); }, 'Đã lưu')}>Lưu</Button></div></Field>
          <Field label="Ngày sinh 🎂" className="mt-3" hint={myDob ? 'Muốn sửa ngày sinh, liên hệ HCNS.' : 'Khai 1 lần để cả công ty chúc mừng sinh nhật bạn (chỉ hiện ngày/tháng).'}>
            {myDob ? <div className="text-sm font-semibold">{String(myDob).split('-').reverse().join('/')}</div>
              : <div className="flex gap-2"><Input type="date" value={dob} onChange={e => setDob(e.target.value)} />
                <Button loading={busy} onClick={() => run(async () => { await db.rpc('set_my_dob', { p_dob: dob }); rDob(); }, 'Đã lưu ngày sinh')}>Lưu</Button></div>}</Field>
        </Card>
        <Card title="Đổi mật khẩu">
          <div className="space-y-3"><Field label="Mật khẩu mới (≥ 8 ký tự)"><Input type="password" autoComplete="new-password" value={pw} onChange={e => setPw(e.target.value)} /></Field>
            <Field label="Nhập lại"><Input type="password" autoComplete="new-password" value={pw2} onChange={e => setPw2(e.target.value)} /></Field>
            <Button variant="dark" loading={busy} onClick={() => run(async () => { if (pw.length < 8) throw new Error('Tối thiểu 8 ký tự'); if (pw !== pw2) throw new Error('Hai mật khẩu không khớp'); await auth.updatePassword(pw); sessionStorage.removeItem('nt_recovery'); setPw(''); setPw2(''); }, 'Đã đổi mật khẩu')}>Đổi mật khẩu</Button></div>
        </Card>
        <Card title="Tài khoản nhận lương">
          <div className="space-y-3">
            <Field label="Ngân hàng"><Select options={BANKS} value={bank.bank_bin || ''} onChange={v => setBank({ ...bank, bank_bin: v })} placeholder="— Chọn —" /></Field>
            <Field label="Số tài khoản"><Input value={bank.bank_account || ''} onChange={e => setBank({ ...bank, bank_account: e.target.value.replace(/\s/g, '') })} /></Field>
            <Field label="Chủ tài khoản (viết hoa không dấu)"><Input value={bank.bank_holder || ''} onChange={e => setBank({ ...bank, bank_holder: stripVN(e.target.value).toUpperCase() })} /></Field>
            <Button variant="dark" loading={busy} onClick={() => run(async () => { await db.from('profile_private').update({ bank_bin: bank.bank_bin || null, bank_account: bank.bank_account || null, bank_holder: bank.bank_holder || null }).eq('profile_id', a.me.id); }, 'Đã lưu tài khoản')}>Lưu</Button>
          </div>
        </Card>
        <Card title="Thông báo & cài ứng dụng">
          <div className="space-y-3 text-sm">
            <div>Thông báo trên thiết bị: <Badge color={perm === 'granted' ? 'green' : 'amber'}>{perm === 'granted' ? 'Đã bật' : perm === 'denied' ? 'Đã chặn — mở cài đặt trình duyệt để bật' : perm === 'unsupported' ? 'Trình duyệt không hỗ trợ' : 'Chưa bật'}</Badge></div>
            {perm === 'default' && <Button onClick={async () => { const p = await Notification.requestPermission(); setPerm(p); if (p === 'granted') toast.ok('Đã bật thông báo'); }}>Bật thông báo</Button>}
            <p className="text-ink-600"><b>iPhone:</b> mở bằng Safari → nút Chia sẻ → “Thêm vào MH chính”, rồi mở app từ màn hình chính và bấm “Bật thông báo”.<br /><b>Android:</b> Chrome → menu ⋮ → “Cài đặt ứng dụng”.</p>
            <p className="text-xs text-ink-400">Thông báo hiện khi ứng dụng đang mở hoặc chạy nền gần đây; luôn có chuông thông báo trong ứng dụng.</p>
          </div>
        </Card>
      </div>
    </Layout>
  );
}
