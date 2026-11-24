/* 404 Gaming Zone — offline shell.
   This caches the PAGE so it still opens with no internet. It does NOT hold
   your sessions: unsent work lives in the app's own outbox (localStorage),
   which survives independently of this file.
   Bump CACHE whenever you upload a new index.html. */

const CACHE = "404zone-v30";

const SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icon.svg",
  "./icon-192.png",
  "./icon-512.png",
  "./games/astro_bot.jpg",
  "./games/black_myth_wukong.jpg",
  "./games/blur.jpg",
  "./games/cod_modern_warfare_3.jpg",
  "./games/days_gone.jpg",
  "./games/fifa_2025_ps4.jpg",
  "./games/fifa_2025_xbox.jpg",
  "./games/fifa_2026.jpg",
  "./games/fifa_2026_online.jpg",
  "./games/ghost_of_tsushima.jpg",
  "./games/god_of_war_ragnarok.jpg",
  "./games/gta_v.jpg",
  "./games/little_nightmares.jpg",
  "./games/mortal_kombat_1.jpg",
  "./games/nfs_heat.jpg",
  "./games/nfs_most_wanted.jpg",
  "./games/prince_of_persia_forgotten_sands.jpg",
  "./games/pubg.jpg",
  "./games/red_dead_redemption_2.jpg",
  "./games/resident_evil_4.jpg",
  "./games/roblox.jpg",
  "./games/rocket_league.jpg",
  "./games/splinter_cell_conviction.jpg",
  "./games/tekken_7.jpg",
  "./games/tekken_8.jpg",
  "./games/the_last_of_us_part_ii.jpg",
  "./games/uncharted_4.jpg",
  "./games/watch_dogs.jpg",
  "./games/watch_dogs_2.jpg",
  // The database library. Without this cached, a reload with no signal cannot
  // even build the client, so the app could not sync the moment signal returns.
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"
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

  // Never cache database traffic — session data must always be live, and a
  // stale cached reply would be worse than an honest failure.
  if (url.hostname.endsWith("supabase.co")) return;

  // The app itself: serve instantly from cache, refresh in the background.
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

  // Fonts and the database library: try the network, fall back to the cache.
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
