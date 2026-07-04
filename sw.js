// MeuPet — Service Worker v1.0
// Estratégia: Cache First para assets, Network First para dados da API

const CACHE_NAME    = 'meupet-v1';
const RUNTIME_CACHE = 'meupet-runtime-v1';

const PRECACHE_URLS = [
  '/',
  '/index.html',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
];

// Instala e pré-cacheia os assets essenciais.
// Usamos add() individual + allSettled em vez de cache.addAll() porque
// addAll() rejeita a instalação inteira se UM único asset der 404
// (ex.: ícone que ainda não foi gerado) — aqui um 404 isolado não quebra o SW.
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => Promise.allSettled(
        PRECACHE_URLS.map(url => cache.add(url).catch(err =>
          console.warn('MeuPet SW: falha ao pré-cachear', url, err)
        ))
      ))
      .then(() => self.skipWaiting())
  );
});

// Remove caches antigos ao ativar nova versão
self.addEventListener('activate', event => {
  const validCaches = [CACHE_NAME, RUNTIME_CACHE];
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => !validCaches.includes(k)).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

// Estratégia de fetch
self.addEventListener('fetch', event => {
  const { request } = event;
  const url = new URL(request.url);

  // Supabase e APIs externas → sempre Network (não cachear dados sensíveis/dinâmicos)
  if (
    url.hostname.includes('supabase.co') ||
    url.hostname.includes('ipapi.co') ||
    url.hostname.includes('bigdatacloud.net') ||
    url.hostname.includes('overpass-api.de') ||
    request.method !== 'GET'
  ) {
    return; // deixa o browser resolver normalmente
  }

  // Google Fonts → Cache First
  if (url.hostname.includes('fonts.googleapis.com') || url.hostname.includes('fonts.gstatic.com')) {
    event.respondWith(
      caches.open(RUNTIME_CACHE).then(cache =>
        cache.match(request).then(cached => {
          if (cached) return cached;
          return fetch(request).then(response => {
            cache.put(request, response.clone());
            return response;
          });
        })
      )
    );
    return;
  }

  // HTML principal → Network First (conteúdo sempre fresco), fallback cache
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then(response => {
          const clone = response.clone();
          caches.open(CACHE_NAME).then(c => c.put(request, clone));
          return response;
        })
        .catch(() => caches.match('/index.html'))
    );
    return;
  }

  // Demais assets (ícones, imagens, scripts) → Cache First
  event.respondWith(
    caches.match(request).then(cached => {
      if (cached) return cached;
      return fetch(request).then(response => {
        if (response.ok) {
          const clone = response.clone();
          caches.open(RUNTIME_CACHE).then(c => c.put(request, clone));
        }
        return response;
      });
    })
  );
});

// Push notifications (preparado para o futuro)
self.addEventListener('push', event => {
  const data = event.data?.json() ?? {};
  event.waitUntil(
    self.registration.showNotification(data.title || 'MeuPet', {
      body: data.body || 'Você tem uma nova notificação!',
      icon: '/icons/icon-192.png',
      badge: '/icons/icon-72.png',
      data: { url: data.url || '/' },
    })
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url));
});
