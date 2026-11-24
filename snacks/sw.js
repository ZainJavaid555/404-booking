/* 404 Snacks — offline service worker
   Caches the app shell so it opens with no internet.
   Bump CACHE when you upload a new version of index.html. */

const CACHE = "404snacks-v47";
const SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icon.svg",
  "./icon-192.png",
  "./icon-512.png",
  "./products/7up_345.png?v=2",
  "./products/aquafina_500.png?v=2",
  "./products/big_apple_345.png?v=2",
  "./products/big_lychee_345.png?v=2",
  "./products/booster_regular.png?v=2",
  "./products/chilli_mili.png?v=2",
  "./products/choco_licious.png?v=2",
  "./products/chocolate_chip_cookie.png?v=2",
  "./products/chocolate_sandwich.png?v=2",
  "./products/chocolato_biscuit.png?v=2",
  "./products/click_biscuit.png?v=2",
  "./products/cocomo.png?v=2",
  "./products/coke_345.png?v=2",
  "./products/dew_345.png?v=2",
  "./products/hearts_biscuit.png?v=2",
  "./products/kurkray_red-black.png?v=2",
  "./products/kurkuray_green.png?v=2",
  "./products/lays_classic.png?v=2",
  "./products/lays_french_cheese.png?v=2",
  "./products/lays_masala.png?v=2",
  "./products/lays_yogurt.png?v=2",
  "./products/lemon_malt.png?v=2",
  "./products/lemon_sandwich.png?v=2",
  "./products/party_biscuit.png?v=2",
  "./products/pepsi_345.png?v=2",
  "./products/prince_biscuit.png?v=2",
  "./products/salva_20rs.png?v=2",
  "./products/salva_50rs.png?v=2",
  "./products/slice_juice.png?v=2",
  "./products/sting_500.png?v=2",
  "./products/super_biscuit.png?v=2",
  "./products/super_cake.png?v=2",
  "./products/super_chocolate.png?v=2",
  "./products/wavy.png?v=2"
];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => Promise.allSettled(SHELL.map(u => c.add(u))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);

  // Never cache Supabase API traffic — it must always be live.
  if (url.hostname.endsWith("supabase.co")) return;

  // App shell: serve from cache first, refresh in background.
  // The page itself: always try the network first, so a new version shows on
  // the very next refresh. The cached copy is only for when there is no signal.
  if (url.origin === location.origin && (req.mode === "navigate" || url.pathname.endsWith("/") || url.pathname.endsWith("index.html"))) {
    e.respondWith(
      fetch(req).then(res => {
        if (res && res.status === 200) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
        return res;
      }).catch(() => caches.match(req).then(hit => hit || caches.match("./index.html")))
    );
    return;
  }

  if (url.origin === location.origin) {
    e.respondWith(
      caches.match(req).then(hit => {
        const net = fetch(req).then(res => {
          if (res && res.status === 200) {
            const copy = res.clone();
            caches.open(CACHE).then(c => c.put(req, copy));
          }
          return res;
        }).catch(() => hit);
        return hit || net;
      })
    );
    return;
  }

  // Third-party (e.g. the Supabase library on CDN): try network, fall back to cache.
  e.respondWith(
    fetch(req).then(res => {
      if (res && res.status === 200) {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(req, copy));
      }
      return res;
    }).catch(() => caches.match(req))
  );
});
