// Service worker for the out-of-band alert PWA (ADR-0027). Shows a notification
// for each web-push the relay delivers — works with the browser/app closed.
self.addEventListener("push", (event) => {
  let data = { title: "infra alert", body: "" };
  try {
    if (event.data) data = { ...data, ...event.data.json() };
  } catch (_) {
    if (event.data) data.body = event.data.text();
  }
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      tag: data.tag || "infra-alert",
      renotify: true,
      requireInteraction: true,
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow("/"));
});
