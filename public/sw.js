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
// Bản 28: thông báo đẩy từ máy chủ (app chưa mở vẫn hiện) — chạm vào mở đúng mục
self.addEventListener('push', e => {
  let d = {}; try { d = e.data.json(); } catch { d = { title: 'ERP Nam Trung', body: e.data && e.data.text() }; }
  const opts = { body: d.body || '', icon: 'icons/icon-192.png', badge: 'icons/icon-192.png', tag: d.tag || undefined, renotify: !!d.tag, data: { link: d.link || '#/' } };
  e.waitUntil(Promise.all([
    self.registration.showNotification(d.title || 'ERP Nam Trung', opts),
    (self.navigator && self.navigator.setAppBadge && d.unread) ? self.navigator.setAppBadge(d.unread).catch(() => {}) : Promise.resolve(),
  ]));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const link = (e.notification.data && e.notification.data.link) || '#/';
  const url = new URL('./' + (link.startsWith('#') ? link : '#' + link), self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const c = cs.find(x => x.url.startsWith(self.registration.scope)) || cs[0];
    if (c) { c.postMessage({ link }); return c.focus().catch(() => {}).then(() => (c.navigate ? c.navigate(url).catch(() => {}) : null)); }
    return self.clients.openWindow(url);
  }));
});
