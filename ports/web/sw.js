/* Filled by tools/build_web.py. An installation only succeeds when every shell,
 * Wasm, and data file matches this build. Saves stay in IndexedDB, outside caches.
 * Normal worker activation waits until all old game tabs close; no skipWaiting. */
const BUILD = /* @build */ null;
const PREFIX = `lemonade:${self.registration.scope}:`;
const CACHE = PREFIX + BUILD.version;
const urlFor = (name) => new URL(name, self.registration.scope).href;
self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      try {
        // Sequential downloads avoid holding several large runtime buffers at once.
        for (const [name, expected] of Object.entries(BUILD.files)) {
          const url = urlFor(name),
            response = await fetch(url, { cache: "reload" });
          if (!response.ok) throw new Error(`Offline download failed: ${name}`);
          const digest = await crypto.subtle.digest(
            "SHA-256",
            await response.clone().arrayBuffer(),
          );
          const actual = Array.from(new Uint8Array(digest), (v) =>
            v.toString(16).padStart(2, "0"),
          ).join("");
          if (actual !== expected)
            throw new Error(`Build changed during download: ${name}`);
          await cache.put(url, response);
        }
      } catch (error) {
        await caches.delete(CACHE);
        throw error;
      }
    })(),
  );
});
self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      for (const name of await caches.keys())
        if (name.startsWith(PREFIX) && name !== CACHE)
          await caches.delete(name);
      await self.clients.claim();
    })(),
  );
});
self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url),
    root = new URL(self.registration.scope);
  if (url.origin !== root.origin || !url.pathname.startsWith(root.pathname))
    return;
  const name = url.pathname.slice(root.pathname.length) || "index.html";
  if (!Object.hasOwn(BUILD.files, name)) return;
  event.respondWith(
    (async () => {
      const cached = await (await caches.open(CACHE)).match(urlFor(name));
      // An active build never falls through to a potentially incompatible runtime.
      return (
        cached ||
        new Response(
          "Offline files are unavailable. Reopen online to repair the installation.",
          { status: 503 },
        )
      );
    })(),
  );
});
