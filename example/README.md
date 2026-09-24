# Jackfield manual Flutter example

This app exercises Jackfield's public API on Android, iOS, macOS, and Web. Its Calls tab can present an incoming call, start an outgoing call where `capabilities()` permits it, end the selected call, and simulate a successful or failed signaling response. The Diagnostics tab displays capabilities, queue state, permissions, and push tokens, and lets you configure an optional HTTPS callback endpoint.

## Run locally

From the package checkout:

```sh
flutter pub get
cd example
flutter pub get
flutter devices
flutter run -d DEVICE_ID
```

Use a supported Android, iOS, macOS, or Web target and complete its [host setup](../README.md#install-and-configure). The app uses `FakeSignaling`: its switch changes the simulated answer result, but no server or media session is connected. The example's event journal is in memory and does not demonstrate production persistence. Check the displayed capabilities before testing a control; Web does not support outgoing calls. Platform permissions and notification presentation depend on the host environment.

On Apple platforms, SwiftPM can derive package identity from the checkout directory. If an example build fails on a package identity mismatch, build from a checkout whose directory basename is exactly `jackfield`. The [validation matrix](../doc/validation-matrix.md) records which local builds have actually passed.

## Optional callback and FCM stand

The Diagnostics tab accepts an **HTTPS** callback URL and a separate bearer token. It clears the token entry after applying it. Use test credentials only. A local server on `127.0.0.1` must be exposed through a trusted HTTPS reverse proxy or tunnel before a device can reach it. Re-entering an endpoint/token re-initializes the plugin and can resume an HTTP queue paused after `401/403`.

The separate [Go/FCM server example](../server_example/README.md) documents environment variables, Android host FCM integration, `/calls` and `/calls/{callId}/end`, and the `/callbacks/jackfield` endpoint. It is a manual integration stand, not a dependency of this app. The Flutter example does **not** register an FCM SDK/service or automatically connect `FakeSignaling` to the server; host push wiring and real media/signaling must be supplied by an integrating app.

For a manual pass, present a call from the Calls tab, perform an available OS action, inspect the event log and queue diagnostics, then end it. To exercise autonomous callbacks, configure the HTTPS endpoint and verify the callback's `eventId` and `Idempotency-Key` at the server. For real push delivery, follow the [push guide](../doc/push.md) and the [manual validation guide](../doc/manual-validation.md). Automated checks do not establish device, provider, background, or lock-screen behavior.
