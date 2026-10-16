// ServicePro offline worker: keeps the tech app's screens on the phone so it opens with no signal.
// Data (jobs, actions, photos) is handled by the app itself; this only caches the app's own files.
const CACHE = 'sp-shell-v1';
const SHELL = ['/', '/tech', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // database / storage calls go straight to the network

  // Built files never change once published: cache first.
  if (url.pathname.startsWith('/_next/static/') || url.pathname.startsWith('/icon-')) {
    e.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
        return res;
      })),
    );
    return;
  }

  // Pages: try the network, fall back to the saved copy (the tech app at /tech).
  e.respondWith(
    fetch(req).then((res) => {
      if (res.ok && (req.mode === 'navigate' || url.pathname.startsWith('/tech'))) {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
      }
      return res;
    }).catch(() => caches.match(req).then((hit) => hit || caches.match('/tech'))),
  );
});
