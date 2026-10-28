import React, { useEffect, useState } from 'react';
import { auth, db } from '../lib/sb';
import { cx, Spinner, toast } from '../components/ui';
import { CARD_COLORS, LoginContent, pickDaily } from '../lib/greeting';

const DEFAULT: LoginContent = {
  headlines: ['Chào ngày mới, chiến binh Nam Trung!'],
  messages: ['Mỗi cuộc gọi là một cơ hội — chúc bạn một ngày làm việc thật vui.'],
  cards: [{ emoji: '🏆', name: 'Chiến binh tuần', sub: 'Phòng Kinh doanh', tag: 'Chốt đơn đẹp', tag2: 'Tuần này', color: 'sun' }],
};

export default function Login() {
  const [tab, setTab] = useState<'login' | 'forgot'>('login');
  const [email, setEmail] = useState(''); const [pw, setPw] = useState(''); const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false); const [msg, setMsg] = useState<string | null>(null);
  const [c, setC] = useState<LoginContent>(() => { try { return JSON.parse(localStorage.getItem('nt_login') || 'null') || DEFAULT; } catch { return DEFAULT; } });
  useEffect(() => { db.rpc<LoginContent>('login_content').then(v => { if (v && Object.keys(v).length) { setC(v); try { localStorage.setItem('nt_login', JSON.stringify(v)); } catch { /* */ } } }, () => {}); }, []);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault(); setMsg(null); setBusy(true);
    try {
      if (tab === 'login') await auth.signIn(email, pw);
      else { await auth.resetPassword(email); setMsg('Đã gửi email đặt lại mật khẩu (nếu email có trong hệ thống).'); }
    } catch (err: any) { toast.err(err); } finally { setBusy(false); }
  };
  const headline = pickDaily(c.headlines, 0) || DEFAULT.headlines![0];
  const message = pickDaily(c.messages, 3) || DEFAULT.messages![0];
  const cards = (c.cards || []).filter(x => x.name).slice(0, 4);
  const pos = ['lg:right-[12%] lg:top-[9%] [--r:-2deg]', 'lg:right-[30%] lg:top-[27%] [--r:2deg]', 'lg:right-[8%] lg:top-[43%] [--r:-1deg]', 'lg:right-[34%] lg:top-[5%] [--r:3deg]'];
  return (
    <div className="grid min-h-screen bg-[#f1f0fb] lg:grid-cols-[minmax(0,1.1fr)_minmax(0,1fr)]">
      {/* Bảng màu bên trái */}
      <section className="relative overflow-hidden bg-[#5b4bff] px-6 pb-8 pt-6 text-white sm:px-10 lg:min-h-screen lg:px-14 lg:pb-14">
        <div className="pointer-events-none absolute -left-24 -top-24 h-72 w-72 rounded-full bg-white/10 blur-2xl" />
        <div className="pointer-events-none absolute -bottom-32 right-[-10%] h-96 w-96 rounded-full bg-[#ff5c7a]/25 blur-3xl" />
        <div className="pointer-events-none absolute bottom-[38%] left-[46%] hidden text-5xl lg:block" style={{ animation: 'nt-spin 18s linear infinite' }}>✳️</div>
        <div className="relative flex items-center gap-3">
          <img src="logo-mark.png" alt="" className="h-11 w-11 rounded-2xl bg-white object-contain p-1 shadow-lg" />
          <div><div className="text-lg font-extrabold leading-none tracking-tight">nt.team</div><div className="text-xs text-white/70">Nam Trung Group</div></div>
        </div>
        {/* Thẻ tích cực bay lơ lửng */}
        <div className="relative mt-6 flex gap-3 overflow-x-auto pb-2 [scrollbar-width:none] lg:static lg:mt-0 lg:block lg:overflow-visible lg:pb-0">
          {c.image && <img src={c.image} alt="" className="nt-float hidden h-56 w-44 rounded-[28px] border-[3px] border-[#17153b] object-cover shadow-[6px_6px_0_#17153b] lg:absolute lg:left-[10%] lg:top-[20%] lg:block [--r:-4deg]" />}
          {cards.map((k, i) => (
            <div key={i} className={cx('nt-pop shrink-0 lg:absolute', pos[i])} style={{ animationDelay: `${0.15 + i * 0.15}s` }}>
              <div className="nt-float w-60 rounded-[22px] border-[3px] border-[#17153b] bg-white p-3.5 text-[#17153b] shadow-[6px_6px_0_#17153b]" style={{ animationDelay: `${i * 1.3}s` }}>
                <div className="flex items-center gap-3">
                  {k.img ? <img src={k.img} alt="" className="h-11 w-11 rounded-full border-2 border-[#17153b] object-cover" />
                    : <div className="grid h-11 w-11 place-items-center rounded-full border-2 border-[#17153b] text-xl" style={{ background: CARD_COLORS[k.color || 'sun'] || CARD_COLORS.sun }}>{k.emoji || '✨'}</div>}
                  <div className="min-w-0"><div className="truncate font-extrabold leading-tight">{k.name}</div>{k.sub && <div className="truncate text-xs text-ink-500">{k.sub}</div>}</div>
                </div>
                {(k.tag || k.tag2) && <div className="mt-2.5 flex flex-wrap gap-1.5">
                  {k.tag && <span className="rounded-full border-2 border-[#17153b] px-2.5 py-0.5 text-xs font-bold" style={{ background: CARD_COLORS[k.color || 'sun'] || CARD_COLORS.sun }}>{k.tag}</span>}
                  {k.tag2 && <span className="rounded-full border-2 border-ink-200 px-2.5 py-0.5 text-xs font-bold">{k.tag2}</span>}</div>}
              </div>
            </div>))}
        </div>
        <div className="relative mt-6 lg:absolute lg:bottom-14 lg:left-14 lg:right-14 lg:mt-0">
          <h1 key={headline} className="nt-pop display max-w-xl text-4xl sm:text-5xl lg:text-6xl xl:text-7xl">{headline}</h1>
          <p key={message} className="nt-pop mt-4 max-w-md text-sm leading-relaxed text-white/85 sm:text-base" style={{ animationDelay: '.2s' }}>💜 {message}</p>
        </div>
      </section>
      {/* Đăng nhập */}
      <section className="grid place-items-center px-6 py-10">
        <form onSubmit={submit} className="nt-pop w-full max-w-sm">
          <h2 className="display text-3xl">{tab === 'login' ? 'Đăng nhập' : 'Quên mật khẩu'}</h2>
          <p className="mb-6 mt-1 text-sm text-ink-500">{tab === 'login' ? 'Chào mừng bạn quay lại 👋' : 'Nhập email công việc, hệ thống gửi link đặt lại mật khẩu.'}</p>
          <label className="mb-1.5 block text-sm font-bold">Email công việc</label>
          <input type="email" autoComplete="email" required value={email} onChange={e => setEmail(e.target.value)} placeholder="ten@namtrunglog.com"
            className="mb-4 h-12 w-full rounded-xl border-2 border-transparent bg-[#e8ecfb] px-4 text-[15px] outline-none transition focus:border-[#5b4bff] focus:bg-white" />
          {tab === 'login' && <>
            <label className="mb-1.5 block text-sm font-bold">Mật khẩu</label>
            <div className="relative mb-5"><input type={show ? 'text' : 'password'} autoComplete="current-password" required value={pw} onChange={e => setPw(e.target.value)}
              className="h-12 w-full rounded-xl border-2 border-transparent bg-[#e8ecfb] px-4 pr-12 text-[15px] outline-none transition focus:border-[#5b4bff] focus:bg-white" />
              <button type="button" onClick={() => setShow(!show)} className="absolute right-3 top-1/2 -translate-y-1/2 text-sm text-ink-400 hover:text-ink-700" aria-label="Hiện mật khẩu">{show ? '🙈' : '👁️'}</button></div></>}
          {msg && <div className="mb-4 rounded-xl bg-emerald-50 p-3 text-sm text-emerald-800">{msg}</div>}
          <button type="submit" disabled={busy} className="h-12 w-full rounded-xl border-2 border-[#17153b] bg-[#5b4bff] text-base font-extrabold text-white shadow-[4px_4px_0_#17153b] transition hover:translate-x-[1px] hover:translate-y-[1px] hover:bg-[#4b3bef] hover:shadow-[3px_3px_0_#17153b] disabled:opacity-70 inline-flex items-center justify-center">
            {busy ? <Spinner small /> : tab === 'login' ? 'Đăng nhập' : 'Gửi email đặt lại'}</button>
          <div className="mt-3 flex justify-between text-xs text-ink-500">
            <button type="button" className="font-semibold text-[#5b4bff] hover:underline" onClick={() => { setTab(tab === 'login' ? 'forgot' : 'login'); setMsg(null); }}>{tab === 'login' ? 'Quên mật khẩu?' : '← Quay lại đăng nhập'}</button>
            <span>Chưa có tài khoản? Liên hệ HCNS.</span></div>
          <p className="mt-10 text-center text-[11px] text-ink-400">© Công ty TNHH DV&TM Quốc tế Nam Trung</p>
        </form>
      </section>
    </div>
  );
}
