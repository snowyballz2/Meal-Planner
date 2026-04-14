const CACHE = 'meal-planner-v2';
const ASSETS = ['./', 'index.html', 'icon.jpeg', 'manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)));
  self.skipWaiting(); // Activate immediately, don't wait for old tabs to close
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    )
  );
  self.clients.claim(); // Take over all tabs immediately
});

self.addEventListener('fetch', e => {
  // Let API calls (GitHub Gist sync) go straight to network
  if (e.request.url.includes('api.github.com')) return;

  // Network-first: always try fresh, fall back to cache for offline
  e.respondWith(
    fetch(e.request)
      .then(res => {
        const clone = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, clone));
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});
