// Service worker: cache vỏ ứng dụng + nhận/hiển thị thông báo
const CACHE = 'nt-erp-__BUILD__';
const SHELL = ['./', 'index.html', 'app.js?v=__BUILD__', 'app.css?v=__BUILD__', 'manifest.webmanifest', 'icons/icon-192.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.endsWith('config.js')) return;
  e.respondWith(fetch(e.request).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); return r; }).catch(() => caches.match(e.request).then(r => r || caches.match('index.html'))));
});
self.addEventListener('push', e => {
  let d = {}; try { d = e.data.json(); } catch { d = { title: 'ERP Nam Trung', body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'ERP Nam Trung', { body: d.body || '', icon: 'icons/icon-192.png', data: { link: d.link } }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const link = (e.notification.data && e.notification.data.link) || '#/';
  e.waitUntil(self.clients.matchAll({ type: 'window' }).then(cs => {
    for (const c of cs) { c.navigate ? c.focus().then(() => c.postMessage({ link })) : c.focus(); return; }
    return self.clients.openWindow('./' + link);
  }));
});
