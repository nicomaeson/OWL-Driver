// Service worker: makes the app load offline after the first visit.
// Bump CACHE_NAME whenever the app changes so phones drop the old copy.
const CACHE_NAME = "owl-driver-v8";
const ASSETS = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/apple-touch-icon.png",
  "./icons/icon-maskable-512.png",
  "./icons/logo.png",
  "./icons/favicon-32.png",
  "./icons/logo-mark.png",
  "./icons/logo-mark-360.png",
  "./config.js",
  "./vendor/supabase-2.118.0.js"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(ASSETS.map((u) => new Request(u, { cache: "reload" }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return; // leave external links alone

  // Always go to the network first and skip the browser's HTTP cache,
  // so a new version shows up right away. Fall back to the cache offline.
  const fresh = new Request(url.href, { cache: "no-store", credentials: "same-origin" });
  event.respondWith(
    fetch(fresh)
      .then((response) => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        }
        return response;
      })
      .catch(() => caches.match(event.request).then((cached) => cached || caches.match("./index.html")))
  );
});
