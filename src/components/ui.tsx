import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';

export const cx = (...a: any[]) => a.filter(Boolean).join(' ');

type BtnProps = React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'primary' | 'dark' | 'secondary' | 'ghost' | 'danger' | 'success'; size?: 'sm' | 'md'; loading?: boolean };
export function Button({ variant = 'secondary', size = 'md', loading, className, children, disabled, ...p }: BtnProps) {
  const v = {
    primary: 'bg-brand-600 text-white hover:bg-brand-700 border-brand-600 shadow-[0_6px_16px_-8px_rgba(106,69,255,.8)]',
    dark: 'bg-ink-900 text-white hover:bg-ink-800 border-ink-900',
    secondary: 'bg-white text-ink-800 hover:bg-ink-50 border-ink-200',
    ghost: 'bg-transparent text-ink-700 hover:bg-ink-100 border-transparent',
    danger: 'bg-white text-red-700 hover:bg-red-50 border-red-200',
    success: 'bg-emerald-600 text-white hover:bg-emerald-700 border-emerald-600',
  }[variant];
  return (
    <button {...p} disabled={disabled || loading}
      className={cx('inline-flex items-center justify-center gap-1.5 rounded-xl border font-semibold active:translate-y-px transition disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap',
        size === 'sm' ? 'h-8 px-2.5 text-[13px]' : 'h-9 px-3.5 text-sm', v, className)}>
      {loading && <Spinner small />}{children}
    </button>
  );
}

export const inputCls = 'w-full h-9 rounded-xl border border-ink-200 bg-white px-3 text-sm text-ink-900 placeholder:text-ink-400 focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100 disabled:bg-ink-50 disabled:text-ink-500';
export const Input = React.forwardRef<HTMLInputElement, React.InputHTMLAttributes<HTMLInputElement>>(function Input({ className, ...p }, ref) {
  return <input ref={ref} {...p} className={cx(inputCls, className)} />;
});
export function NumInput({ value, onChange, className, ...p }: { value: any; onChange: (v: number | null) => void } & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'value' | 'onChange'>) {
  const [txt, setTxt] = useState(value === null || value === undefined || value === '' ? '' : String(value));
  useEffect(() => { const cur = txt === '' ? null : Number(txt.replace(',', '.')); if (cur !== value && !(cur === null && (value === '' || value === undefined))) setTxt(value === null || value === undefined ? '' : String(value)); }, [value]);
  return <input inputMode="decimal" {...p} value={txt}
    onChange={e => { const t = e.target.value.replace(/[^0-9.,-]/g, ''); setTxt(t); const n = t === '' || t === '-' ? null : Number(t.replace(',', '.')); onChange(n === null || Number.isNaN(n) ? null : n); }}
    className={cx(inputCls, 'text-right tabular-nums', className)} />;
}
export function Textarea({ className, ...p }: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea {...p} className={cx(inputCls, 'h-auto min-h-[72px] py-2', className)} />;
}
export function Select({ options, value, onChange, placeholder, className, ...p }:
  { options: [string, string][]; value: any; onChange: (v: string) => void; placeholder?: string } & Omit<React.SelectHTMLAttributes<HTMLSelectElement>, 'onChange'>) {
  return (
    <select {...p} value={value ?? ''} onChange={e => onChange(e.target.value)} className={cx(inputCls, 'pr-8', className)}>
      {placeholder !== undefined && <option value="">{placeholder}</option>}
      {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
    </select>
  );
}
export function Field({ label, children, hint, required, className }: { label: React.ReactNode; children: React.ReactNode; hint?: React.ReactNode; required?: boolean; className?: string }) {
  return (
    <label className={cx('block min-w-0', className)}>
      <span className="mb-1 block text-xs text-ink-500 truncate">{label}{required && <span className="text-red-500"> *</span>}</span>
      {children}
      {hint && <span className="mt-1 block text-[11px] text-ink-400">{hint}</span>}
    </label>
  );
}
export function Chips({ options, value, onChange, disabled }: { options: [string, string][]; value: string[]; onChange: (v: string[]) => void; disabled?: boolean }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      {options.map(([v, l]) => {
        const on = value.includes(v);
        return <button type="button" key={v} disabled={disabled} onClick={() => onChange(on ? value.filter(x => x !== v) : [...value, v])}
          className={cx('rounded-full border px-3 py-1 text-[13px] font-medium transition', on ? 'border-brand-600 bg-brand-600 text-white shadow-[0_4px_12px_-6px_rgba(106,69,255,.9)]' : 'border-ink-200 bg-white text-ink-700 hover:border-brand-200 hover:bg-brand-50')}>{l}</button>;
      })}
    </div>
  );
}
export function Radio({ options, value, onChange }: { options: [string, string][]; value: string; onChange: (v: string) => void }) {
  return <Chips options={options} value={value ? [value] : []} onChange={v => onChange(v.filter(x => x !== value)[0] ?? value)} />;
}
export function Card({ title, actions, children, className, bodyClass }: { title?: React.ReactNode; actions?: React.ReactNode; children: React.ReactNode; className?: string; bodyClass?: string }) {
  return (
    <section className={cx('rounded-2xl border border-ink-200 bg-white shadow-soft', className)}>
      {(title || actions) && <header className="flex flex-wrap items-center justify-between gap-2 border-b border-ink-100 px-4 py-3">
        <h2 className="text-[15px] font-semibold text-ink-900">{title}</h2><div className="flex flex-wrap gap-2">{actions}</div></header>}
      <div className={cx('p-4', bodyClass)}>{children}</div>
    </section>
  );
}
const badgeColors: Record<string, string> = {
  gray: 'bg-ink-100 text-ink-700', blue: 'bg-blue-50 text-blue-700', green: 'bg-emerald-50 text-emerald-700', red: 'bg-red-50 text-red-700',
  amber: 'bg-amber-50 text-amber-800', purple: 'bg-brand-50 text-brand-700', orange: 'bg-orange-50 text-orange-700', solidred: 'bg-red-600 text-white', solidamber: 'bg-amber-500 text-white',
  sky: 'bg-sky-50 text-sky-700', indigo: 'bg-indigo-50 text-indigo-700', pink: 'bg-pink-50 text-pink-700', teal: 'bg-teal-50 text-teal-700', slate: 'bg-slate-100 text-slate-600', yellow: 'bg-yellow-50 text-yellow-800',
};
// Thẻ trạng thái có màu: [mã, nhãn, số lượng, tông]
const chipTone: Record<string, [string, string, string]> = {
  gray: ['border-ink-200 bg-white text-ink-600', 'bg-ink-100 text-ink-600', 'border-ink-700 bg-ink-700 text-white'],
  slate: ['border-slate-200 bg-slate-50 text-slate-600', 'bg-slate-200 text-slate-700', 'border-slate-600 bg-slate-600 text-white'],
  sky: ['border-sky-200 bg-sky-50 text-sky-700', 'bg-sky-100 text-sky-800', 'border-sky-600 bg-sky-600 text-white'],
  blue: ['border-blue-200 bg-blue-50 text-blue-700', 'bg-blue-100 text-blue-800', 'border-blue-600 bg-blue-600 text-white'],
  indigo: ['border-indigo-200 bg-indigo-50 text-indigo-700', 'bg-indigo-100 text-indigo-800', 'border-indigo-600 bg-indigo-600 text-white'],
  purple: ['border-brand-200 bg-brand-50 text-brand-700', 'bg-brand-100 text-brand-800', 'border-brand-600 bg-brand-600 text-white'],
  pink: ['border-pink-200 bg-pink-50 text-pink-700', 'bg-pink-100 text-pink-800', 'border-pink-600 bg-pink-600 text-white'],
  amber: ['border-amber-200 bg-amber-50 text-amber-800', 'bg-amber-100 text-amber-900', 'border-amber-500 bg-amber-500 text-white'],
  yellow: ['border-yellow-200 bg-yellow-50 text-yellow-800', 'bg-yellow-100 text-yellow-900', 'border-yellow-500 bg-yellow-500 text-white'],
  orange: ['border-orange-200 bg-orange-50 text-orange-700', 'bg-orange-100 text-orange-800', 'border-orange-500 bg-orange-500 text-white'],
  teal: ['border-teal-200 bg-teal-50 text-teal-700', 'bg-teal-100 text-teal-800', 'border-teal-600 bg-teal-600 text-white'],
  green: ['border-emerald-200 bg-emerald-50 text-emerald-700', 'bg-emerald-100 text-emerald-800', 'border-emerald-600 bg-emerald-600 text-white'],
  red: ['border-red-200 bg-red-50 text-red-700', 'bg-red-100 text-red-800', 'border-red-600 bg-red-600 text-white'],
  dark: ['border-ink-200 bg-white text-ink-800', 'bg-ink-100 text-ink-700', 'border-ink-900 bg-ink-900 text-white'],
};
export function StatusChips({ items, value, onChange }: { items: [string, string, number, string][]; value: string; onChange: (v: string) => void }) {
  return <div className="-mx-1 mb-3 flex gap-1.5 overflow-x-auto px-1 pb-1 [scrollbar-width:none]">
    {items.map(([k, l, n, tone]) => { const t = chipTone[tone] || chipTone.gray; const on = value === k;
      return <button key={k || 'all'} onClick={() => onChange(on && k ? '' : k)}
        className={cx('inline-flex shrink-0 items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-semibold transition', on ? t[2] + ' shadow-sm' : t[0], !n && !on && k && 'opacity-60 hover:opacity-100')}>
        {l}<span className={cx('min-w-[1.25rem] rounded-full px-1.5 text-center text-[11px] tabular-nums', on ? 'bg-white/25' : t[1])}>{n}</span></button>; })}
  </div>;
}
export function Badge({ color = 'gray', children, className }: { color?: string; children: React.ReactNode; className?: string }) {
  return <span className={cx('inline-flex items-center rounded-md px-1.5 py-0.5 text-[12px] font-medium whitespace-nowrap', badgeColors[color] || badgeColors.gray, className)}>{children}</span>;
}
export function Spinner({ small }: { small?: boolean }) {
  return <span className={cx('inline-block animate-spin rounded-full border-2 border-current border-r-transparent', small ? 'h-3.5 w-3.5' : 'h-5 w-5')} />;
}
export function Loading({ text = 'Đang tải…' }: { text?: string }) {
  return <div className="flex items-center gap-2 p-6 text-sm text-ink-500"><Spinner /> {text}</div>;
}
export function Empty({ children = 'Chưa có dữ liệu' }: { children?: React.ReactNode }) {
  return <div className="p-8 text-center text-sm text-ink-400">{children}</div>;
}
export function Modal({ open, onClose, title, children, footer, size = 'md' }: { open: boolean; onClose: () => void; title: React.ReactNode; children: React.ReactNode; footer?: React.ReactNode; size?: 'sm' | 'md' | 'lg' | 'xl' }) {
  useEffect(() => { if (!open) return; const f = (e: KeyboardEvent) => e.key === 'Escape' && onClose(); window.addEventListener('keydown', f); return () => window.removeEventListener('keydown', f); }, [open, onClose]);
  if (!open) return null;
  const w = { sm: 'max-w-md', md: 'max-w-2xl', lg: 'max-w-4xl', xl: 'max-w-6xl' }[size];
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-ink-900/40 sm:items-center sm:p-4" onMouseDown={e => e.target === e.currentTarget && onClose()}>
      <div className={cx('flex max-h-[94vh] w-full flex-col rounded-t-3xl bg-white shadow-xl sm:rounded-3xl', w)}>
        <div className="flex items-center justify-between gap-3 border-b border-ink-100 px-5 py-3">
          <h3 className="text-[15px] font-semibold">{title}</h3><Button size="sm" onClick={onClose}>Đóng</Button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer && <div className="flex flex-wrap items-center justify-end gap-2 border-t border-ink-100 px-5 py-3">{footer}</div>}
      </div>
    </div>
  );
}
export function Tabs({ tabs, value, onChange }: { tabs: [string, React.ReactNode][]; value: string; onChange: (v: string) => void }) {
  return (
    <div className="flex gap-1.5 overflow-x-auto pb-1 [scrollbar-width:none]">
      {tabs.map(([k, l]) => <button key={k} type="button" onClick={() => onChange(k)}
        className={cx('whitespace-nowrap rounded-full border px-3.5 py-1.5 text-sm font-semibold transition', value === k ? 'border-ink-900 bg-ink-900 text-white' : 'border-ink-200 bg-white text-ink-600 hover:border-ink-400')}>{l}</button>)}
    </div>
  );
}
export function Stat({ label, value, sub, tone, onClick }: { label: string; value: React.ReactNode; sub?: React.ReactNode; tone?: 'red' | 'amber' | 'green'; onClick?: () => void }) {
  return (
    <button onClick={onClick} disabled={!onClick} className="rounded-2xl border border-ink-200 bg-white p-4 text-left shadow-soft transition enabled:hover:-translate-y-0.5 enabled:hover:border-brand-200">
      <div className="text-xs text-ink-500">{label}</div>
      <div className={cx('mt-1 text-2xl font-semibold tabular-nums', tone === 'red' ? 'text-red-600' : tone === 'amber' ? 'text-amber-600' : tone === 'green' ? 'text-emerald-600' : 'text-ink-900')}>{value}</div>
      {sub && <div className="mt-0.5 text-xs text-ink-400">{sub}</div>}
    </button>
  );
}
export function Table({ head, children, className }: { head: React.ReactNode[]; children: React.ReactNode; className?: string }) {
  return (
    <div className={cx('overflow-x-auto', className)}>
      <table className="w-full text-sm">
        <thead><tr className="border-b border-ink-200 bg-ink-50/60 text-left text-xs text-ink-500">{head.map((h, i) => <th key={i} className="whitespace-nowrap px-3 py-2 font-medium">{h}</th>)}</tr></thead>
        <tbody className="divide-y divide-ink-100">{children}</tbody>
      </table>
    </div>
  );
}
export const Td = ({ children, className, ...p }: React.TdHTMLAttributes<HTMLTableCellElement>) => <td {...p} className={cx('px-3 py-2 align-top', className)}>{children}</td>;

// ---------- Toast ----------
type ToastItem = { id: number; text: string; kind: 'ok' | 'err' | 'info'; title?: string; onClick?: () => void };
let pushToast: (t: Omit<ToastItem, 'id'>) => void = () => {};
export function Toaster() {
  const [items, setItems] = useState<ToastItem[]>([]);
  const idRef = useRef(0);
  useEffect(() => {
    pushToast = t => { const id = ++idRef.current; setItems(x => [...x.slice(-3), { ...t, id }]); setTimeout(() => setItems(x => x.filter(i => i.id !== id)), t.kind === 'err' ? 7000 : 4500); };
  }, []);
  return (
    <div className="pointer-events-none fixed bottom-4 right-4 z-[60] flex w-[calc(100%-2rem)] max-w-sm flex-col gap-2">
      {items.map(t => (
        <div key={t.id} onClick={() => { t.onClick?.(); setItems(x => x.filter(i => i.id !== t.id)); }}
          className={cx('pointer-events-auto cursor-pointer rounded-xl border px-4 py-3 text-sm shadow-lg', t.kind === 'err' ? 'border-red-200 bg-red-50 text-red-800' : t.kind === 'ok' ? 'border-emerald-200 bg-emerald-50 text-emerald-800' : 'border-ink-200 bg-white text-ink-800')}>
          {t.title && <div className="font-semibold">{t.title}</div>}{t.text}
        </div>
      ))}
    </div>
  );
}
export const toast = {
  ok: (text: string) => pushToast({ text, kind: 'ok' }),
  err: (e: any) => pushToast({ text: typeof e === 'string' ? e : e?.message || 'Có lỗi xảy ra', kind: 'err' }),
  info: (text: string, title?: string, onClick?: () => void) => pushToast({ text, kind: 'info', title, onClick }),
};

// ---------- Hộp thoại xác nhận / nhập liệu ----------
export function ask(o: { title: string; message?: React.ReactNode; input?: { label: string; placeholder?: string; required?: boolean; options?: [string, string][]; value?: string }; ok?: string; danger?: boolean }): Promise<string | null> {
  return new Promise(resolve => {
    const host = document.createElement('div'); document.body.appendChild(host); const root = createRoot(host);
    const done = (v: string | null) => { root.unmount(); host.remove(); resolve(v); };
    function Dlg() {
      const [v, setV] = useState(o.input?.value || ''); const [err, setErr] = useState('');
      const submit = () => { if (o.input?.required && !v.trim()) { setErr('Bắt buộc nhập'); return; } done(o.input ? v : 'ok'); };
      return (
        <Modal open onClose={() => done(null)} title={o.title} size="sm"
          footer={<><Button onClick={() => done(null)}>Hủy</Button><Button variant={o.danger ? 'danger' : 'primary'} onClick={submit}>{o.ok || 'Đồng ý'}</Button></>}>
          {o.message && <div className="mb-3 text-sm text-ink-700">{o.message}</div>}
          {o.input && <Field label={o.input.label} required={o.input.required}>
            {o.input.options ? <Select options={o.input.options} value={v} onChange={setV} placeholder="— Chọn —" />
              : <Input autoFocus value={v} placeholder={o.input.placeholder} onChange={e => setV(e.target.value)} onKeyDown={e => e.key === 'Enter' && submit()} />}
          </Field>}
          {err && <div className="mt-2 text-sm text-red-600">{err}</div>}
        </Modal>
      );
    }
    root.render(<Dlg />);
  });
}

/** Chạy tác vụ có xử lý lỗi + trạng thái bận */
export function useAction() {
  const [busy, setBusy] = useState(false);
  const run = async <T,>(fn: () => Promise<T>, okMsg?: string): Promise<T | undefined> => {
    setBusy(true);
    try { const r = await fn(); if (okMsg) toast.ok(okMsg); return r; }
    catch (e) { toast.err(e); return undefined; }
    finally { setBusy(false); }
  };
  return { busy, run };
}

export function useLoad<T>(fn: () => Promise<T>, deps: any[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true; setLoading(true);
    fn().then(d => { if (alive) { setData(d); setError(null); } }).catch(e => { if (alive) setError(e?.message || String(e)); }).finally(() => alive && setLoading(false));
    return () => { alive = false; };
  }, [...deps, tick]);
  return { data, loading, error, reload: () => setTick(t => t + 1), setData };
}

export function ErrorBox({ error }: { error: string | null }) {
  return error ? <div className="m-4 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</div> : null;
}
