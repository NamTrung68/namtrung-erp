import React, { useEffect, useRef, useState } from 'react';
import { useApp, go, useRoute } from '../state';
import { auth, db } from '../lib/sb';
import { Button, cx, toast } from './ui';
import { fmtDateTime } from '../lib/format';
import { DuplicateCheck, QuickCare } from './CrmModals';

const P: Record<string, string> = {
  home: 'M3 10.5 12 3l9 7.5V21h-6v-6H9v6H3z',
  users: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8m13 10v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75',
  quote: 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6M8 13h8M8 17h5',
  report: 'M3 3v18h18M7 15l4-4 3 3 5-6',
  daily: 'M9 11l3 3L22 4M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11',
  help: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM9.1 9a3 3 0 0 1 5.8 1c0 2-3 3-3 3M12 17h.01',
  folder: 'M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z',
  clock: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 6v6l4 2',
  leave: 'M8 2v4M16 2v4M3 10h18M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z',
  check: 'M22 11.08V12a10 10 0 1 1-5.93-9.14M22 4 12 14.01l-3-3',
  money: 'M12 1v22M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6',
  trophy: 'M6 9H4.5a2.5 2.5 0 0 1 0-5H6M18 9h1.5a2.5 2.5 0 0 0 0-5H18M4 22h16M10 14.66V17c0 .55-.47.98-.97 1.21C7.85 18.75 7 20.24 7 22M14 14.66V17c0 .55.47.98.97 1.21C16.15 18.75 17 20.24 17 22M18 2H6v7a6 6 0 0 0 12 0z',
  news: 'M4 22h16a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v16a2 2 0 0 1-2 2zm0 0a2 2 0 0 1-2-2v-9c0-1.1.9-2 2-2h2M18 14h-8M15 18h-5M10 6h8v4h-8z',
  ticket: 'M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2zM13 5v2M13 17v2M13 11v2',
  shield: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z',
  gear: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z',
  db: 'M12 8c4.97 0 9-1.34 9-3s-4.03-3-9-3-9 1.34-9 3 4.03 3 9 3zM21 12c0 1.66-4 3-9 3s-9-1.34-9-3M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5',
  user: 'M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z',
  bell: 'M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9M13.73 21a2 2 0 0 1-3.46 0',
  menu: 'M3 12h18M3 6h18M3 18h18',
  logout: 'M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9',
};
export const Icon = ({ name, className = 'h-[18px] w-[18px]' }: { name: string; className?: string }) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" className={className}><path d={P[name] || P.home} /></svg>
);

interface NavItem { to: string; label: string; icon: string; show: boolean }
export function useNav() {
  const a = useApp();
  const groups: [string, NavItem[]][] = [
    ['', [{ to: '/', label: 'Hôm nay', icon: '🌞', show: true }, { to: '/news', label: 'Bảng tin', icon: '📢', show: true }]],
    ['Bán hàng', [
      { to: '/dashboard', label: 'Bảng điều khiển', icon: '📊', show: true },
      { to: '/crm/customers', label: 'Khách hàng', icon: '👥', show: a.isSales },
      { to: '/crm/quotes', label: 'Báo giá', icon: '🧾', show: a.isSales },
      { to: '/crm/library', label: 'Kho báo giá', icon: '📚', show: true },
      { to: '/support', label: 'Hỗ trợ khách', icon: '🆘', show: true },
      { to: '/crm/daily', label: 'Báo cáo ngày', icon: '📝', show: a.isSales },
      { to: '/crm/reports', label: 'Báo cáo và KPI', icon: '📈', show: a.isSales },
      { to: '/kpi', label: 'Bảng Phong Thần', icon: '🏆', show: true },
    ]],
    ['Nhân sự', [
      { to: '/hr/attendance', label: 'Chấm công', icon: '📷', show: true },
      { to: '/hr/leave', label: 'Xin nghỉ', icon: '🏖️', show: true },
      { to: '/hr/timesheet', label: 'Bảng công · Chuyên cần', icon: '🗓️', show: true },
      { to: '/hr/approvals', label: 'Duyệt đơn', icon: '✅', show: a.isLead || a.has('hcns') },
      { to: '/hr/payslips', label: 'Phiếu lương', icon: '💰', show: true },
      { to: '/hr/payroll', label: 'Bảng lương', icon: '💵', show: a.canHR },
      { to: '/hr/staff', label: a.isAdmin || a.has('hcns', 'bgd') ? 'Hồ sơ nhân sự' : 'Hồ sơ của tôi', icon: '🗂️', show: true },
    ]],
    ['Vận hành', [
      { to: '/tickets', label: 'Claim & hỏi đáp', icon: '❓', show: true },
      { to: '/inventory', label: 'Tồn kho', icon: '📦', show: true },
      { to: '/docs', label: 'Chứng từ', icon: '📁', show: a.canDocs },
    ]],
    ['Quản trị', [
      { to: '/admin/users', label: 'Nhân sự & phân quyền', icon: '🛡️', show: a.isAdmin || a.has('hcns') },
      { to: '/admin/settings', label: 'Cấu hình', icon: '⚙️', show: a.isAdmin || a.has('hcns', 'ke_toan') },
      { to: '/admin/data', label: 'Dữ liệu · Nhật ký', icon: '🗄️', show: a.isAdmin || a.has('hcns') },
    ]],
  ];
  return groups.map(([g, items]) => [g, items.filter(i => i.show)] as [string, NavItem[]]).filter(([, i]) => i.length);
}

export function Layout({ children, title, actions }: { children: React.ReactNode; title?: React.ReactNode; actions?: React.ReactNode }) {
  const a = useApp(); const { path } = useRoute(); const nav = useNav();
  const [open, setOpen] = useState(false); const [check, setCheck] = useState(false); const [care, setCare] = useState(false);
  useEffect(() => setOpen(false), [path]);
  const side = (
    <nav className="flex h-full flex-col gap-3 overflow-y-auto px-3 py-4">
      <a href="#/" className="mb-1 flex items-center gap-2.5 px-2">
        <img src="logo-mark.png" alt="" className="h-10 w-10 rounded-xl bg-white object-contain p-0.5 ring-1 ring-ink-100" />
        <span className="leading-tight"><b className="block text-[19px] font-extrabold tracking-tight">nt.team</b><span className="text-xs text-ink-400">Nam Trung Group</span></span>
      </a>
      {nav.map(([g, items]) => (
        <div key={g}>
          {g && <div className="mb-1 mt-1 px-3 text-[11px] font-bold uppercase tracking-wider text-ink-400">{g}</div>}
          {items.map(i => {
            const on = i.to === '/' ? path === '/' : path.startsWith(i.to);
            return <a key={i.to} href={'#' + i.to} className={cx('mb-0.5 flex items-center gap-3 rounded-2xl px-3 py-2 text-[14.5px] transition', on ? 'bg-ink-900 font-bold text-white shadow-soft' : 'font-semibold text-ink-600 hover:bg-white hover:text-ink-900')}>
              <span className="w-6 text-center text-[17px] leading-none">{i.icon}</span>{i.label}</a>;
          })}
        </div>
      ))}
      <div className="mt-auto border-t border-ink-200 pt-3">
        <a href="#/account" className="flex items-center gap-2 rounded-2xl px-2 py-1.5 text-sm hover:bg-white">
          <span className="grid h-8 w-8 place-items-center rounded-full bg-gradient-to-br from-brand-500 to-hot text-xs font-bold text-white">{(a.me.full_name || a.me.email)[0]?.toUpperCase()}</span>
          <span className="min-w-0 leading-tight"><span className="block truncate font-semibold">{a.me.full_name}</span><span className="block truncate text-[11px] text-ink-400">{a.me.job_level_name || a.me.roles.join(', ')}</span></span>
        </a>
        <button onClick={() => auth.signOut()} className="mt-1 flex w-full items-center gap-2 rounded-xl px-3 py-1.5 text-sm text-ink-500 hover:bg-white"><Icon name="logout" />Đăng xuất</button>
      </div>
    </nav>
  );
  return (
    <div className="min-h-screen bg-ink-50 lg:pl-64">
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-64 border-r border-ink-200/70 bg-ink-50 lg:block">{side}</aside>
      {open && <div className="fixed inset-0 z-40 lg:hidden" onClick={() => setOpen(false)}><div className="absolute inset-0 bg-ink-900/40 backdrop-blur-sm" />
        <aside className="absolute inset-y-0 left-0 w-72 bg-ink-50" onClick={e => e.stopPropagation()}>{side}</aside></div>}
      <header className="sticky top-0 z-20 flex h-14 items-center gap-2 border-b border-ink-200/70 bg-white/80 px-3 backdrop-blur-xl sm:px-5">
        <button className="rounded-xl p-1.5 hover:bg-ink-100 lg:hidden" onClick={() => setOpen(true)} aria-label="Menu"><Icon name="menu" /></button>
        <h1 className="min-w-0 flex-1 truncate text-base font-extrabold tracking-tight sm:text-lg">{title}</h1>
        <div className="hidden items-center gap-2 md:flex">{actions}</div>
        {a.isSales && <>
          <Button size="sm" className="hidden sm:inline-flex" onClick={() => setCheck(true)}>Kiểm tra SĐT / MST</Button>
          <Button size="sm" variant="primary" onClick={() => setCare(true)}><span className="sm:hidden">+ Chăm sóc</span><span className="hidden sm:inline">Ghi chăm sóc nhanh</span></Button>
        </>}
        <span className="hidden text-xs font-medium text-ink-400 xl:inline">{new Date().toLocaleDateString('vi-VN', { weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' })}</span>
        <Bell />
      </header>
      {actions && <div className="flex flex-wrap gap-2 border-b border-ink-200 bg-white px-3 py-2 md:hidden">{actions}</div>}
      <main className="mx-auto max-w-[1600px] p-3 sm:p-5">{children}</main>
      <DuplicateCheck open={check} onClose={() => setCheck(false)} />
      <QuickCare open={care} onClose={() => setCare(false)} />
    </div>
  );
}

function Bell() {
  const a = useApp(); const [open, setOpen] = useState(false); const [items, setItems] = useState<any[]>([]);
  const lastId = useRef<number>(0);
  const load = async (notify = false) => {
    try {
      const rows: any[] = await db.from('notifications').select('*').order('created_at', { asc: false }).limit(30);
      if (notify && lastId.current) {
        rows.filter(r => r.id > lastId.current && !r.read_at).reverse().forEach(r => {
          toast.info(r.body || '', r.title, () => r.link && (location.hash = r.link));
          showSystemNotification(r.title, r.body || '', r.link);
        });
      }
      if (rows[0]) lastId.current = Math.max(lastId.current, rows[0].id);
      setItems(rows);
    } catch { /* ignore */ }
  };
  useEffect(() => { load(); const t = setInterval(() => load(true), 30_000); return () => clearInterval(t); }, []);
  const unread = items.filter(i => !i.read_at).length;
  const markAll = async () => { await db.from('notifications').update({ read_at: new Date().toISOString() }).is('read_at', null); load(); a.refreshMe(); };
  return (
    <div className="relative">
      <button onClick={() => setOpen(o => !o)} className="relative rounded-xl p-2 hover:bg-ink-100" aria-label="Thông báo">
        <Icon name="bell" />{unread > 0 && <span className="absolute right-1 top-1 grid h-4 min-w-4 place-items-center rounded-full bg-red-600 px-1 text-[10px] font-semibold text-white">{unread > 9 ? '9+' : unread}</span>}
      </button>
      {open && <div className="absolute right-0 top-11 z-50 w-[min(92vw,380px)] rounded-xl border border-ink-200 bg-white shadow-xl">
        <div className="flex items-center justify-between border-b border-ink-100 px-4 py-2.5"><b className="text-sm">Thông báo</b>
          <button className="text-xs text-brand-700" onClick={markAll}>Đánh dấu đã đọc</button></div>
        <div className="max-h-[60vh] overflow-y-auto">
          {items.length === 0 && <div className="p-6 text-center text-sm text-ink-400">Chưa có thông báo</div>}
          {items.map(n => <button key={n.id} onClick={async () => { setOpen(false); if (!n.read_at) await db.from('notifications').update({ read_at: new Date().toISOString() }).eq('id', n.id); if (n.link) location.hash = n.link; load(); }}
            className={cx('block w-full border-b border-ink-50 px-4 py-2.5 text-left hover:bg-ink-50', !n.read_at && 'bg-brand-50/50')}>
            <div className="text-sm font-medium">{n.title}</div>{n.body && <div className="line-clamp-2 text-xs text-ink-500">{n.body}</div>}
            <div className="mt-0.5 text-[11px] text-ink-400">{fmtDateTime(n.created_at)}</div></button>)}
        </div>
      </div>}
    </div>
  );
}

export async function showSystemNotification(title: string, body: string, link?: string) {
  try {
    if (!('Notification' in window) || Notification.permission !== 'granted') return;
    const reg = 'serviceWorker' in navigator ? await navigator.serviceWorker.getRegistration() : undefined;
    const opts: any = { body, icon: 'icons/icon-192.png', badge: 'icons/icon-192.png', data: { link } };
    if (reg) await reg.showNotification(title, opts); else new Notification(title, opts);
  } catch { /* ignore */ }
}
