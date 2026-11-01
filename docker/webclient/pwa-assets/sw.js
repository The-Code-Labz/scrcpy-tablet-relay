/*
 * Minimal service worker — exists only to make the app installable
 * (Add to Home Screen) and to let the shell document open offline.
 *
 * It deliberately does NOT cache or intercept anything related to the
 * live stream: scrcpy's video/control/clipboard traffic rides a raw
 * WebSocket (wss://.../?action=proxy-adb&...), which the fetch event
 * never sees in the first place — browsers don't route WS handshakes
 * through the fetch/SW pipeline. The extra `action=` guard below is just
 * defense in depth against any future HTTP polling endpoints.
 */
const CACHE = 'scrcpy-relay-shell-v1';
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
  if (url.pathname.startsWith('/proxy') || url.search.includes('action=')) {
    // Device tracker / stream / adb-proxy endpoints — always go straight to network.
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
