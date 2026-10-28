// Build tĩnh cho GitHub Pages: esbuild (TS/React) + Tailwind → dist/
import { build } from 'esbuild';
import { cpSync, mkdirSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const out = 'dist';
const version = process.env.BUILD_ID || Date.now().toString(36);
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync('public', out, { recursive: true });

await build({
  entryPoints: ['src/main.tsx'], bundle: true, minify: true, format: 'esm', target: ['es2020', 'safari15'],
  outfile: `${out}/app.js`, jsx: 'automatic', define: { 'process.env.NODE_ENV': '"production"' }, legalComments: 'none', logLevel: 'info',
});

// Tailwind: CLI trong node_modules (CI) hoặc binary chỉ định qua TAILWIND_BIN
const twArgs = ['-c', 'tailwind.config.cjs', '-i', 'src/styles.css', '-o', `${out}/app.css`, '--minify'];
if (process.env.TAILWIND_BIN) execFileSync(process.env.TAILWIND_BIN, twArgs, { stdio: 'inherit' });
else execFileSync(process.execPath, ['node_modules/tailwindcss/lib/cli.js', ...twArgs], { stdio: 'inherit' });

// Ghi đè config.js từ biến môi trường khi build trên CI (nếu có)
if (process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY) {
  writeFileSync(`${out}/config.js`, `window.NT_CONFIG = { supabaseUrl: ${JSON.stringify(process.env.SUPABASE_URL)}, supabaseAnonKey: ${JSON.stringify(process.env.SUPABASE_ANON_KEY)} };\n`);
}
for (const f of ['index.html', 'sw.js']) writeFileSync(`${out}/${f}`, readFileSync(`${out}/${f}`, 'utf8').replaceAll('__BUILD__', version));
writeFileSync(`${out}/404.html`, readFileSync(`${out}/index.html`, 'utf8'));
writeFileSync(`${out}/.nojekyll`, '');
console.log('Built', version);
