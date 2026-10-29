import React, { useEffect, useState } from 'react';
import { Input } from './ui';
import { db } from '../lib/sb';

export function CustomerPicker({ value, onChange, disabled }: { value: any; onChange: (c: any) => void; disabled?: boolean }) {
  const [q, setQ] = useState(''); const [opts, setOpts] = useState<any[]>([]); const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!open) return;
    const tm = setTimeout(async () => {
      let qq = db.from('customers').select('id,code,sys_code,contact_name,company_name,phone,zalo,import_method').is('deleted_at', null).order('updated_at', { asc: false }).limit(15);
      if (q.trim()) { const s = q.trim().replace(/[(),]/g, ' '); qq = qq.or(`contact_name.ilike.*${s}*,company_name.ilike.*${s}*,code.ilike.*${s}*,phone_norm.ilike.*${s}*`); }
      try { setOpts(await qq); } catch { /* */ }
    }, 250);
    return () => clearTimeout(tm);
  }, [q, open]);
  const label = value ? `${value.code} | ${value.company_name || value.contact_name} | ${value.phone || value.zalo || ''}` : '';
  return (
    <div className="relative">
      <Input disabled={disabled} value={open ? q : label} placeholder="Gõ tên, mã KH, SĐT…" onFocus={() => { setOpen(true); setQ(''); }} onBlur={() => setTimeout(() => setOpen(false), 200)} onChange={e => setQ(e.target.value)} />
      {open && <div className="absolute z-30 mt-1 max-h-72 w-full overflow-y-auto rounded-lg border border-ink-200 bg-white shadow-lg">
        {opts.length === 0 && <div className="p-3 text-sm text-ink-400">Không tìm thấy</div>}
        {opts.map(o => <button key={o.id} type="button" onMouseDown={() => { onChange(o); setOpen(false); }} className="block w-full px-3 py-2 text-left text-sm hover:bg-ink-50">
          <b>{o.code}</b> · {o.company_name || o.contact_name} <span className="text-ink-400">{o.phone || o.zalo}</span></button>)}
      </div>}
    </div>
  );
}

