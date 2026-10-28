import React, { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { auth, Session } from './lib/sb';
import { AppProvider, loadContext, useRoute } from './state';
import { Toaster, Loading, Button } from './components/ui';
import { Layout } from './components/Layout';
import Login from './pages/Login';
import Dashboard from './pages/Dashboard';
import Customers from './pages/crm/Customers';
import Quotes from './pages/crm/Quotes';
import QuoteEditor from './pages/crm/QuoteEditor';
import Daily from './pages/crm/Daily';
import Reports from './pages/crm/Reports';
import Support from './pages/Support';
import Docs from './pages/Docs';
import Attendance from './pages/hr/Attendance';
import Leave from './pages/hr/Leave';
import Approvals from './pages/hr/Approvals';
import { Payroll, Payslips, PayslipView } from './pages/hr/Payroll';
import Kpi from './pages/Kpi';
import News from './pages/News';
import Tickets from './pages/Tickets';
import Users from './pages/admin/Users';
import Settings from './pages/admin/Settings';
import DataAdmin from './pages/admin/Data';
import Account from './pages/Account';

const routes: Record<string, React.FC> = {
  '/': Dashboard,
  '/crm/customers': Customers, '/crm/customer': Customers,
  '/crm/quotes': Quotes, '/crm/quote': QuoteEditor,
  '/crm/daily': Daily, '/crm/reports': Reports,
  '/support': Support, '/docs': Docs, '/news': News, '/tickets': Tickets, '/kpi': Kpi,
  '/hr/attendance': Attendance, '/hr/leave': Leave, '/hr/approvals': Approvals,
  '/hr/payroll': Payroll, '/hr/payslips': Payslips, '/hr/payslip': PayslipView,
  '/admin/users': Users, '/admin/settings': Settings, '/admin/data': DataAdmin,
  '/account': Account,
};

function Router() {
  const { path } = useRoute();
  const Page = routes[path];
  useEffect(() => { window.scrollTo(0, 0); }, [path]);
  if (!Page) return <Layout title="Không tìm thấy"><div className="p-8 text-center">Trang không tồn tại. <a className="text-brand-700" href="#/">Về trang chủ</a></div></Layout>;
  return <Page />;
}

function App() {
  const [session, setSession] = useState<Session | null>(auth.session);
  const [ctx, setCtx] = useState<Awaited<ReturnType<typeof loadContext>> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => auth.onChange(s => setSession(s)) as any, []);
  useEffect(() => {
    setCtx(null); setErr(null);
    if (!session) return;
    loadContext().then(c => { if (!c.me) throw new Error('Tài khoản chưa được kích hoạt hoặc đã bị khóa. Liên hệ quản trị.'); setCtx(c); }).catch(e => setErr(e.message));
  }, [session?.access_token && session.user?.id, session === null]);
  if (!session) return <Login />;
  if (err) return <div className="grid min-h-screen place-items-center p-6"><div className="max-w-md rounded-xl border bg-white p-6 text-center">
    <p className="mb-4 text-sm text-red-700">{err}</p><Button onClick={() => auth.signOut()}>Đăng xuất</Button></div></div>;
  if (!ctx) return <div className="grid min-h-screen place-items-center"><Loading text="Đang tải dữ liệu…" /></div>;
  return <AppProvider initial={ctx}><Router /></AppProvider>;
}

const recovery = auth.consumeUrlToken();
if (recovery === 'recovery') sessionStorage.setItem('nt_recovery', '1');
if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js').catch(() => {});
createRoot(document.getElementById('root')!).render(<><App /><Toaster /></>);
