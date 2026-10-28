import http from 'node:http'; import { readFileSync, existsSync } from 'node:fs'; import { extname, join } from 'node:path';
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json' };
const dir = process.argv[2] || 'dist';
http.createServer((req, res) => { let p = join(dir, decodeURIComponent(new URL(req.url, 'http://x').pathname)); if (p.endsWith('/')) p += 'index.html';
  if (!existsSync(p)) { res.writeHead(404); return res.end(); } res.writeHead(200, { 'Content-Type': types[extname(p)] || 'application/octet-stream' }); res.end(readFileSync(p)); }).listen(8080, () => console.log('static :8080'));
