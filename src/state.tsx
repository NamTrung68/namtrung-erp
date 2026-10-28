import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { db } from './lib/sb';

export interface Me {
  id: string; email: string; full_name: string; employee_code: string; roles: string[]; job_level: string | null; job_level_name: string | null;
  level_rank: number | null; manager_id: string | null; manager_name: string | null; work_schedule: string; is_manager: boolean; unread: number; selfie_consent: boolean;
}
export interface Lookup { category: string; code: string; label: string; sort: number; extra: any; active: boolean }
export interface Person { id: string; full_name: string; employee_code: string; job_level: string | null; org_unit_id: string | null; manager_id: string | null; roles: string[]; status: string }

interface Ctx {
  me: Me; lookups: Lookup[]; settings: Record<string, any>; people: Person[]; levels: any[]; units: any[];
  opts: (cat: string) => [string, string][]; label: (cat: string, code: string | null | undefined) => string; lk: (cat: string, code: string) => Lookup | undefined;
  has: (...roles: string[]) => boolean; isAdmin: boolean; isSales: boolean; isLead: boolean; canHR: boolean; canDocs: boolean;
  reload: () => Promise<void>; personName: (id: string | null | undefined) => string; refreshMe: () => Promise<void>;
}
const AppCtx = createContext<Ctx | null>(null);
export const useApp = () => useContext(AppCtx)!;

export async function loadContext() {
  const [me, lookups, settings, people, levels, units] = await Promise.all([
    db.rpc<Me>('me'),
    db.from<Lookup[]>('lookups').select('*').eq('active', true).order('category').order('sort'),
    db.from<any[]>('settings').select('key,value'),
    db.rpc<Person[]>('people_directory'),
    db.from<any[]>('job_levels').select('*').order('rank'),
    db.from<any[]>('org_units').select('*').order('sort'),
  ]);
  return { me, lookups, settings: Object.fromEntries((settings || []).map((s: any) => [s.key, s.value])), people: people || [], levels: levels || [], units: units || [] };
}

export function AppProvider({ initial, children }: { initial: Awaited<ReturnType<typeof loadContext>>; children: React.ReactNode }) {
  const [state, setState] = useState(initial);
  const reload = useCallback(async () => setState(await loadContext()), []);
  const refreshMe = useCallback(async () => { const me = await db.rpc<Me>('me'); setState(s => ({ ...s, me })); }, []);
  useEffect(() => { const t = setInterval(refreshMe, 60_000); return () => clearInterval(t); }, [refreshMe]);
  const roles = state.me.roles || [];
  const has = (...r: string[]) => r.some(x => roles.includes(x));
  const isAdmin = has('admin', 'bgd');
  const peopleMap = new Map(state.people.map(p => [p.id, p.full_name]));
  const value: Ctx = {
    ...state,
    opts: cat => state.lookups.filter(l => l.category === cat).map(l => [l.code, l.label]),
    label: (cat, code) => (code ? state.lookups.find(l => l.category === cat && l.code === code)?.label || code : ''),
    lk: (cat, code) => state.lookups.find(l => l.category === cat && l.code === code),
    has, isAdmin,
    isSales: isAdmin || has('sale', 'tn_kd', 'tp_kd'),
    isLead: isAdmin || has('tn_kd', 'tp_kd') || state.me.is_manager,
    canHR: isAdmin || has('hcns', 'ke_toan'),
    canDocs: isAdmin || has('ke_toan') || (state.me.level_rank ?? 0) >= 3,
    reload, refreshMe,
    personName: id => (id ? peopleMap.get(id) || '—' : ''),
  };
  return <AppCtx.Provider value={value}>{children}</AppCtx.Provider>;
}

// ---------- Router (hash) ----------
export function parseHash() {
  const h = location.hash.replace(/^#/, '') || '/';
  const [path, qs] = h.split('?');
  return { path: path || '/', query: Object.fromEntries(new URLSearchParams(qs || '')) as Record<string, string> };
}
export function useRoute() {
  const [r, setR] = useState(parseHash());
  useEffect(() => { const f = () => setR(parseHash()); window.addEventListener('hashchange', f); return () => window.removeEventListener('hashchange', f); }, []);
  return r;
}
export const go = (to: string) => { location.hash = to.startsWith('#') ? to : '#' + to; };
export const Link = ({ to, className, children }: { to: string; className?: string; children: React.ReactNode }) => <a href={'#' + to} className={className}>{children}</a>;
