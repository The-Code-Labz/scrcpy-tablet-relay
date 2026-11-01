/*
 * Minimal service worker — exists only to make tango-mirror's page
 * installable (Add to Home Screen) and let the shell document open
 * offline. It does NOT cache or intercept /api/* (device list) or the
 * WebSocket signaling/WebRTC traffic — browsers don't route WS upgrades
 * through the fetch/SW pipeline anyway, and /api/ is excluded as defense
 * in depth.
 */
const CACHE = 'scrcpy-audio-shell-v1';
const SHELL_ASSETS = ['./', './index.html'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.addAll(SHELL_ASSETS))
      .catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') {
    return;
  }

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) {
    return;
  }
  if (url.pathname.startsWith('/api/') || url.search) {
    return;
  }

  const isShellDoc = url.pathname === '/' || url.pathname.endsWith('.html');

  event.respondWith(
    fetch(request)
      .then((response) => {
        if (isShellDoc && response && response.ok) {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put(request, copy));
        }
        return response;
      })
      .catch(() => caches.match(request))
  );
});
