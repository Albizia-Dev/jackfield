## 0.0.2 — 2026-09-30

Incoming calls now carry a mandatory, persisted `expiresAt` ringing deadline.
Android, iOS, macOS, and Web reconcile unanswered calls to one durable `missed`
terminal event after live timers or recovery execution. The Go/FCM stand emits
the same deadline, and Android terminal events remain available to Flutter even
when the bounded HTTP callback queue is full.

Fix Android call presentation by running CallStyle notifications from a
phone-call foreground service, and keep the public API available when host
WorkManager initialization is absent. Native Android and Apple failures now
include dense private platform logging while the Dart API continues to expose
sanitized typed failures.

The manual example adds an Android Firebase/FCM stand without adding Firebase
to the plugin runtime. Incoming, outgoing, and end flows were exercised on an
Android 15 device and an iPad running iOS 17.3.1; push-provider, lock-screen,
DND, force-stop, and background-delivery behavior remain separate host gates.

## 0.0.1 — 2026-09-25

Initial experimental release with typed call and event APIs, durable replay,
independent action/Flutter/HTTPS receipts, optional autonomous HTTPS callbacks,
provider-neutral push entrypoints, a Flutter manual example, and an isolated
Go/FCM manual stand.

The plugin registers Android, iOS, macOS, and Web, each with documented
capability limits. Windows and Linux source scaffolds remain in the repository
but are not registered or supported. Web outgoing, iOS reject, mute/hold, and
explicit system audio-session coordination are not implemented. Local automated
checks and the canonical-name macOS example build/run do not establish real
device, push-provider, callback-delivery, or remote CI behavior. See the
[release checklist](doc/release-checklist.md) and
[validation matrix](doc/validation-matrix.md).
