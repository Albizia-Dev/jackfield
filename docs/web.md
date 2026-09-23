# Web integration

Jackfield Web stores call snapshots, the event inbox, callback outbox, action receipts and lease metadata in IndexedDB. A host Service Worker owns this database and handles push notifications. Jackfield installs handlers into the host worker; it does not replace the application's worker or promise that a browser will wake it in the background.

Import the package worker from the application's classic Service Worker and call `install` once. Keep existing application handlers in the same worker:

```js
importScripts('./assets/packages/jackfield/web/jackfield_worker.js');
JackfieldWorker.install({ leaseMs: 45000, heartbeatMs: 15000 });
```

The example's `web/jackfield_host_worker.js` shows the integration. Register it under the application's origin and scope. Push payloads must be JSON with `version: 1`, `type: "incoming"`, stable `callId` and `eventId`, caller `{id, displayName}`, `media: "audio" | "video"`, and a future ISO `expiresAt`. Invalid and expired payloads are rejected with a visible status notification.

Initialization never opens a permission prompt. To opt in, invoke `JackfieldWeb.subscribePushFromUserGesture(applicationServerKey)` directly from a user initiated flow such as a button handler. Pass the VAPID public key in base64url form. The returned string is the Push API endpoint; `pushTokens()` reads an existing subscription without prompting. Browser subscription removal and provider-side token rotation remain the host application's responsibility.

The active tab claims a 45 second IndexedDB lease and renews it every 15 seconds. The owner receives worker events and can replay unacknowledged events after reconnecting. Acknowledgement only removes an event from future replay; it does not complete a pending answer action. Notification Answer and Reject actions persist their event and receipt before delivery.

HTTP callbacks use the shared v1 callback policy: bounded queue admission, HTTPS bearer credentials, per call ordering, retry with a fifteen minute ceiling, TTL expiry and pause on 401/403 until callback credentials change. Queue records and credentials are local to the browser origin's IndexedDB. Use scoped credentials and a trusted origin.

Run `tool/test_web.sh` for worker behavior, package tests, and JavaScript plus Wasm web builds. These checks do not prove delivery on a particular browser, operating system, push provider or background scheduling policy. Browsers may suspend or discard workers, so applications must reconcile state when they return to the foreground.
