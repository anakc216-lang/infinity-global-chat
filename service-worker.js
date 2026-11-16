const CACHE_NAME = 'infinity-chat-shell-v21';
const APP_SHELL = ['./', './index.html', './manifest.json', './logo.png'];

function getPushNotificationData(event) {
  try {
    return event.data ? event.data.json() : {};
  } catch (error) {
    console.warn('Invalid chat push payload:', error);
    return {};
  }
}

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('push', event => {
  const payload = getPushNotificationData(event);
  const messageId = String(payload.messageId || '');
  const title = String(payload.title || 'Infinity Global Chat');
  const body = String(payload.body || 'A new message was posted.');
  const room = String(payload.room || '');
  const url = `./${room ? `?chatRoom=${encodeURIComponent(room)}` : ''}`;

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const focusedWindows = windows.filter(client => client.visibilityState === 'visible' && client.focused);
    if (focusedWindows.length) {
      focusedWindows.forEach(client => client.postMessage({ type: 'CHAT_PUSH', messageId, room }));
    }

    const hasFocusedWindow = focusedWindows.length > 0;
    await self.registration.showNotification(title, {
      body,
      icon: './logo.png',
      badge: './logo.png',
      tag: messageId ? `chat-message-${messageId}` : 'chat-message',
      data: { url },
      // Use the app sound while focused; otherwise allow the system notification sound.
      silent: hasFocusedWindow
    });
  })());
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const targetUrl = new URL(event.notification.data?.url || './', self.location.href).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const existing = windows.find(client => new URL(client.url).origin === self.location.origin);
    if (existing) {
      await existing.focus();
      if ('navigate' in existing) await existing.navigate(targetUrl);
      return;
    }
    await self.clients.openWindow(targetUrl);
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    const hasPreviousAppCache = keys.some(key => key.startsWith('infinity-chat-shell-v') && key !== CACHE_NAME);
    await Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key)));
    await self.clients.claim();

    if (!hasPreviousAppCache) return;

    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    windows.forEach(client => client.postMessage({ type: 'IGC_UPDATE_AVAILABLE', cacheName: CACHE_NAME }));

    if ('Notification' in self && self.Notification.permission === 'granted') {
      try {
        await self.registration.showNotification('Infinity Global Chat updated', {
          body: 'Tap to reload and use the latest version. Your device ID and saved data will be kept.',
          icon: './logo.png',
          badge: './logo.png',
          tag: `igc-app-update-${CACHE_NAME}`,
          data: { url: './' }
        });
      } catch (error) {
        console.warn('App update notification failed:', error);
      }
    }
  })());
});

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);

  if (request.method !== 'GET' || url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then(response => {
          if (!response.ok) {
            return caches.match('./index.html').then(cached => cached || response);
          }
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put('./index.html', copy));
          return response;
        })
        .catch(() => caches.match('./index.html').then(cached => cached || caches.match('./')))
    );
    return;
  }

  event.respondWith(
    caches.match(request).then(cached => {
      if (cached) return cached;
      return fetch(request).then(response => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
        }
        return response;
      });
    })
  );
});
