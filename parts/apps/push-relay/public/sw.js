// Service worker for the out-of-band alert PWA (ADR-0027). For each web-push the
// relay delivers it (a) persists the alert to IndexedDB so the app can show a
// history that survives reloads/closes, (b) shows an OS notification (works with
// the app closed), and (c) pings any open window so its list updates live.

// --- minimal IndexedDB helper (shared shape with index.html) -----------------
const DB_NAME = "infra-alerts";
const STORE = "alerts";

function openDB() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(DB_NAME, 1);
    r.onupgradeneeded = () =>
      r.result.createObjectStore(STORE, { keyPath: "id" });
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

async function idbAdd(alert) {
  const db = await openDB();
  await new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(alert);
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  db.close();
}

self.addEventListener("push", (event) => {
  let data = { title: "infra alert", body: "" };
  try {
    if (event.data) data = { ...data, ...event.data.json() };
  } catch (_) {
    if (event.data) data.body = event.data.text();
  }

  const alert = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    title: data.title,
    body: data.body,
    ts: Date.now(),
  };

  event.waitUntil(
    (async () => {
      await idbAdd(alert);
      await self.registration.showNotification(alert.title, {
        body: alert.body,
        tag: alert.id, // unique tag → alerts stack instead of collapsing
        renotify: true,
        requireInteraction: true,
        timestamp: alert.ts,
      });
      const clientList = await self.clients.matchAll({
        includeUncontrolled: true,
        type: "window",
      });
      for (const c of clientList) c.postMessage({ type: "alert", alert });
    })(),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    (async () => {
      const clientList = await clients.matchAll({
        includeUncontrolled: true,
        type: "window",
      });
      // Focus an existing window if there is one, else open a new one.
      for (const c of clientList) {
        if ("focus" in c) return c.focus();
      }
      return clients.openWindow("/");
    })(),
  );
});
