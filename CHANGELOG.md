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
