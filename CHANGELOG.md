## 0.0.1 — implementation candidate (unreleased)

Jackfield now has typed call and event APIs, durable replay with separate action,
Flutter and HTTPS receipts, optional autonomous callbacks, provider-neutral push
entrypoints, an integration example, an isolated Go/FCM manual stand and GitHub
Actions workflows.

Android, iOS, macOS and Web have implemented adapters with documented capability
limits. Windows and Linux remain registered scaffolds because their implementation
tasks were explicitly deferred. This is **not a six-platform-complete or
release-ready version**. The Apple example build and remote CI are not verified;
real device, push-provider and callback delivery gates remain open. See the
[release checklist](docs/release-checklist.md) and
[validation matrix](docs/validation-matrix.md) before any release decision.
