/* 404 Gaming Zone — shows booking alerts on the phone, even when the site is closed.
   It does not cache anything and does not touch page loading. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) {}
  e.waitUntil(self.registration.showNotification(d.title || 'New booking to check', {
    body: d.body || '', tag: d.tag || 'booking', renotify: true, requireInteraction: true,
    icon: './admin/icon-192.png', badge: './admin/icon-192.png', vibrate: [200, 100, 200, 100, 200]
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    const mine = list.find(c => c.url.startsWith(self.registration.scope) && !/\/book\//.test(c.url));
    return mine ? mine.focus() : self.clients.openWindow(self.registration.scope + '?tab=bookings');
  }));
});
