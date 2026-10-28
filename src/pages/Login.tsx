import React, { useState } from 'react';
import { auth } from '../lib/sb';
import { Button, Field, Input, Tabs, toast } from '../components/ui';

export default function Login() {
  const [tab, setTab] = useState('login');
  const [email, setEmail] = useState(''); const [pw, setPw] = useState(''); const [pw2, setPw2] = useState('');
  const [busy, setBusy] = useState(false); const [msg, setMsg] = useState<string | null>(null);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault(); setMsg(null); setBusy(true);
    try {
      if (tab === 'login') await auth.signIn(email, pw);
      else if (tab === 'signup') {
        if (pw.length < 8) throw new Error('Mật khẩu tối thiểu 8 ký tự');
        if (pw !== pw2) throw new Error('Hai mật khẩu không khớp');
        const r = await auth.signUp(email, pw);
        if (r.needConfirm) setMsg('Đã tạo tài khoản. Mở email để xác nhận rồi quay lại đăng nhập.');
      } else {
        await auth.resetPassword(email);
        setMsg('Đã gửi email đặt lại mật khẩu (nếu email có trong hệ thống).');
      }
    } catch (e: any) { toast.err(e); } finally { setBusy(false); }
  };
  return (
    <div className="grid min-h-screen place-items-center bg-ink-50 p-4">
      <div className="w-full max-w-sm">
        <div className="mb-6 flex items-center gap-3">
          <span className="grid h-11 w-11 place-items-center rounded-xl bg-[#F07B3C] text-lg font-bold text-white">NT</span>
          <div><div className="text-lg font-semibold">ERP Nam Trung</div><div className="text-xs text-ink-500">Hệ thống quản trị nội bộ</div></div>
        </div>
        <form onSubmit={submit} className="rounded-2xl border border-ink-200 bg-white p-5 shadow-sm">
          <Tabs value={tab} onChange={t => { setTab(t); setMsg(null); }} tabs={[['login', 'Đăng nhập'], ['signup', 'Kích hoạt tài khoản'], ['forgot', 'Quên mật khẩu']]} />
          <div className="mt-4 space-y-3">
            <Field label="Email công việc"><Input type="email" autoComplete="email" required value={email} onChange={e => setEmail(e.target.value)} /></Field>
            {tab !== 'forgot' && <Field label="Mật khẩu"><Input type="password" autoComplete={tab === 'login' ? 'current-password' : 'new-password'} required value={pw} onChange={e => setPw(e.target.value)} /></Field>}
            {tab === 'signup' && <Field label="Nhập lại mật khẩu" hint="Chỉ email đã được HCNS/Admin mời mới kích hoạt được."><Input type="password" autoComplete="new-password" required value={pw2} onChange={e => setPw2(e.target.value)} /></Field>}
            {msg && <div className="rounded-lg bg-emerald-50 p-3 text-sm text-emerald-800">{msg}</div>}
            <Button variant="dark" className="w-full" loading={busy} type="submit">{tab === 'login' ? 'Đăng nhập' : tab === 'signup' ? 'Kích hoạt' : 'Gửi email đặt lại'}</Button>
          </div>
        </form>
        <p className="mt-4 text-center text-xs text-ink-400">© Công ty TNHH DV&TM Quốc tế Nam Trung</p>
      </div>
    </div>
  );
}
