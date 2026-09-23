# Task 10 report: Web worker, IndexedDB and Push API

Implemented the Web registrar and Dart JS interop adapter, and completed the worker integration already present in this worktree. The host worker installs handlers into the app's Service Worker and retains a 45 second IndexedDB delivery lease with 15 second renewals. IndexedDB persists call snapshots, event inbox entries, callback outbox entries, action receipts and metadata. Push payloads are validated before persistence and notification. Answer and Reject notification actions persist durable events before callback delivery.

Added `JackfieldWeb.subscribePushFromUserGesture`, which prompts for notification permission only when explicitly called, creates a Push API subscription, returns its endpoint and publishes token updates. Existing subscriptions are read through `pushTokens()` without prompting. IndexedDB transaction failures abort all queued changes, including when callback admission is full. Added documentation, worker tests, a JavaScript/Wasm artifact smoke check and `tool/test_web.sh`.

## Verification

- `node --test tool/web_test/worker_test.mjs` — 6 passed.
- `flutter analyze` — no issues.
- `flutter test` — all tests passed.
- JavaScript web release build — passed; smoke check found compiled Dart and Jackfield worker assets.
- Wasm web release build — passed; smoke check found the Wasm module and Jackfield worker assets.
- `git diff --check` — clean.

These checks do not demonstrate push delivery or worker scheduling on a deployed browser. Service Worker wakeups remain browser controlled and are not guaranteed.
