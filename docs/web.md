# Web integration

Jackfield Web stores call snapshots, the event inbox, callback outbox, action receipts and lease metadata in IndexedDB. A host Service Worker owns this database and handles push notifications. Jackfield installs handlers into the host worker; it does not replace the application's worker or promise that a browser will wake it in the background.

Import the package worker from the application's classic Service Worker and call `install` once. Keep existing application handlers in the same worker:

```js
importScripts('./assets/packages/jackfield/web/jackfield_worker.js');
JackfieldWorker.install({ leaseMs: 45000, heartbeatMs: 15000 });
```

The example's `web/jackfield_host_worker.js` shows the integration. Register it under the application's origin and scope, and expose the exact ready registration as `window.JackfieldHostWorkerRegistration` before Flutter initializes. The bridge awaits this promise and sends commands only to its active worker. Call `JackfieldWeb.bindPushIdentity(installationId: ..., sessionId: ...)` with server-issued opaque IDs for the current login session. Rotate the session ID on account change. Push payloads must be JSON with `version: 1`, `type: "incoming"`, matching `installationId` and `sessionId`, stable `callId` and `eventId`, caller `{id, displayName}`, `media: "audio" | "video"`, and an ISO `expiresAt` no more than five minutes ahead. Missing or mismatched binding and malformed or expired payloads produce a visible status notification. Duplicate events, existing calls, and ended calls do not ring again.

Initialization never opens a permission prompt. To opt in, invoke `JackfieldWeb.subscribePushFromUserGesture(applicationServerKey)` directly from a user initiated flow such as a button handler. Pass the VAPID public key in base64url form. The returned string is the Push API endpoint; `pushTokens()` reads an existing subscription without prompting. Browser subscription removal and provider-side token rotation remain the host application's responsibility.

The active tab claims a 45 second IndexedDB lease and renews it every 15 seconds. A new owner immediately receives unacknowledged events; pending reads and acknowledgements require the current owner and lease token. Acknowledgement only removes an event from future replay; it does not complete a pending answer action. Notification Answer and Reject actions persist their event and receipt before delivery.

HTTP callbacks use the shared v1 callback envelope and policy: bounded queue admission, HTTPS bearer credentials, per call ordering, retry with a fifteen minute ceiling, TTL from `occurredAt`, and pause on 401/403 until callback credentials change. The worker persists each attempt, next retry time and terminal outcome. Fetch uses `redirect: "manual"` so an opaque redirect can be classified as terminal without following it; network failures remain retryable. Callback admission is in the same IndexedDB transaction as the Flutter inbox and call snapshot. Queue overflow or scheduler failure leaves the Flutter event intact; diagnostics report HTTP delivery problems separately. The earliest due time is persisted; one-shot Background Sync is registered again after an early wake, Periodic Background Sync is requested where supported, and an owning live tab also drains the queue every 15 seconds. Browsers do not guarantee a background wake at the retry time. Queue records and credentials are local to the browser origin's IndexedDB. Use scoped credentials and a trusted origin.

If the Service Worker is unsupported or registration fails, the example still starts Flutter. The adapter reports unavailable capabilities until the intended host worker becomes active.

Run `tool/test_web.sh` for worker behavior, package tests, and JavaScript plus Wasm web builds. These checks do not prove delivery on a particular browser, operating system, push provider or background scheduling policy. Browsers may suspend or discard workers, so applications must reconcile state when they return to the foreground.
