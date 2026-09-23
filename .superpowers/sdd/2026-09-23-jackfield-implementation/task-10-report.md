# Task 10 report: Web worker, IndexedDB and Push API

Implemented the Web registrar and Dart JS interop adapter, and completed the worker integration already present in this worktree. The host worker installs handlers into the app's Service Worker and retains a 45 second IndexedDB delivery lease with 15 second renewals. IndexedDB persists call snapshots, event inbox entries, callback outbox entries, action receipts and metadata. Push payloads are validated before persistence and notification. Answer and Reject notification actions persist durable events before callback delivery.

Added `JackfieldWeb.subscribePushFromUserGesture`, which prompts for notification permission only when explicitly called, creates a Push API subscription, returns its endpoint and publishes token updates. Existing subscriptions are read through `pushTokens()` without prompting. Added documentation, worker tests, a JavaScript/Wasm artifact smoke check and `tool/test_web.sh`.

## Verification

- `node --test tool/web_test/worker_test.mjs` — 6 passed.
- `flutter analyze` — no issues.
- `flutter test` — all tests passed.
- JavaScript web release build — passed; smoke check found compiled Dart and Jackfield worker assets.
- Wasm web release build — passed; smoke check found the Wasm module and Jackfield worker assets.
- `git diff --check` — clean.

These checks do not demonstrate push delivery or worker scheduling on a deployed browser. Service Worker wakeups remain browser controlled and are not guaranteed.

## Fix round 1

- Push requires a persisted installation/session binding, caller identity and a bounded expiry. Event and call IDs suppress replay; stale notifications cannot act after a session rotation, and ended snapshots cannot ring again.
- Flutter snapshot, inbox and action receipt are persisted before independent HTTP admission. Overflow and scheduler failure leave them intact and expose a typed diagnostic. Notification actions preserve caller/media, store the connecting deadline and complete idempotently.
- HTTP POST uses the canonical v1 envelope, `redirect: "error"`, persisted claim/retry/terminal state, `Retry-After`, jitter and TTL from `occurredAt`. Transactional claims avoid concurrent sends; Background Sync and a live-tab drain are both best effort.
- Lease reads and ACKs require current owner/token, and a new owner receives pending events on takeover. The browser bridge awaits the exact host worker registration before initialization.
- Added `node_modules/` to `.gitignore`; no user data was removed.

Verification after fix round 1: `tool/test_web.sh` passed (19 worker tests, 65 Flutter tests, JavaScript and Wasm release builds, artifact smoke); `flutter analyze` found no issues; Dart format and `git diff --check` were clean. Browser/provider delivery and Background Sync timing remain unverified without a deployed browser.
