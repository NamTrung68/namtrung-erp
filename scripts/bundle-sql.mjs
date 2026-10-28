// Gộp extensions + migrations thành 1 file supabase/setup.sql để dán vào SQL Editor của Supabase
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
const dir = 'supabase/migrations';
const parts = ['supabase/00_extensions.sql', ...readdirSync(dir).filter(f => f.endsWith('.sql')).sort().map(f => `${dir}/${f}`)];
const out = parts.map(p => `-- >>>>> ${p}\n${readFileSync(p, 'utf8')}`).join('\n\n');
writeFileSync('supabase/setup.sql', out);
console.log('supabase/setup.sql', out.length, 'bytes from', parts.length, 'files');
