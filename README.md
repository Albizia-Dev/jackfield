# Jackfield

Jackfield is a Flutter plugin for presenting calls through platform UI and delivering call actions durably. It provides typed calls, events, capabilities, diagnostics, and independent acknowledgements for native actions, Flutter events, and optional HTTPS callbacks.

Version **0.0.1 is an experimental initial release** for Android, iOS, macOS, and Web. Windows and Linux source scaffolds remain in the repository, but the plugin does not register or support those platforms. Real device, push provider, and callback delivery still need host-specific validation; see the [validation matrix](doc/validation-matrix.md) and [release checklist](doc/release-checklist.md).

Jackfield owns local call state and platform presentation. Your application owns authentication, server call state, signaling, and audio/video. The optional Go/FCM [manual server](server_example/README.md) is independent of the plugin runtime.

## Install and configure

Add `jackfield: ^0.0.1` to your application's `pubspec.yaml`, then import `package:jackfield/jackfield.dart`. The minimum versions are Flutter 3.35 and Dart 3.9, Android API 26, iOS 13, and macOS 11. Follow the host setup guides for [Android](doc/android.md), [iOS](doc/ios.md), [macOS](doc/macos.md), or [Web](doc/web.md). Adapter authors can use `jackfield_platform_interface.dart`, `jackfield_method_channel.dart`, and `jackfield_web.dart`; `WireCodec` belongs to the adapter interface, not the application import.

```dart
import 'package:jackfield/jackfield.dart';

final calls = Jackfield.instance;
final initialization = await calls.initialize(const JackfieldConfiguration());
if (initialization case JackfieldFailure<void>(:final error)) {
  print(error.code);
}

final capabilities = await calls.capabilities();
if (capabilities.features.contains(JackfieldFeature.incoming)) {
  final outcome = await calls.reportIncomingCall(
    IncomingCall(
      callId: const CallId('server-call-attempt-42'),
      caller: const Caller(id: 'peer-7', displayName: 'Alex'),
      media: CallMedia.audio,
    ),
  );
  if (outcome case JackfieldFailure<CallSnapshot>(:final error)) {
    print(error.code);
  }
}

if (capabilities.features.contains(JackfieldFeature.outgoing)) {
  final outcome = await calls.startOutgoingCall(
    OutgoingCall(
      callId: const CallId('outgoing-attempt-43'),
      callee: const Caller(id: 'peer-8', displayName: 'Maria'),
      media: CallMedia.audio,
    ),
  );
  if (outcome case JackfieldFailure<CallSnapshot>(:final error)) {
    print(error.code);
  }
}
```

Check `capabilities()` before each platform-sensitive action. Web currently does not advertise outgoing calls. Starting a call does not connect signaling or media. Reconcile business state with your server and call `endCall` when the remote side ends a call. Available capabilities can change with permissions and system registration. See the [capability matrix](doc/capabilities.md).

## Complete actions and acknowledge replay

`CallId` identifies a call attempt, `ActionId` a platform action, and `EventId` a delivery record. Persist handled event IDs and results in application-owned durable storage. An unacknowledged event can reappear after restart with the **same** `EventId`; signaling and media work must be idempotent. In this sketch, `eventStore` and `signaling` are your own components:

```dart
await for (final event in calls.events) {
  if (await eventStore.isHandled(event.eventId)) {
    await calls.acknowledgeEvents({event.eventId});
    continue;
  }
  if (event is AnswerRequested) {
    final connected = await signaling.connectOnce(event.callId, event.actionId);
    final completion = await calls.completeAction(
      event.actionId,
      connected ? const ActionResult.success() : const ActionResult.failure(),
    );
    if (completion is JackfieldFailure<void>) {
      // Keep the event pending; report or persist this failure in your app.
      continue;
    }
  }
  await eventStore.markHandled(event.eventId, event.sequence);
  final ack = await calls.acknowledgeEvents({event.eventId});
  if (ack is JackfieldFailure<void>) {
    // Retrying the acknowledgement after replay is safe.
  }
}
```

Check `AnswerRequested.deadline` and handle `deadlineExceeded`: acknowledging an event does not extend its action deadline. `completeAction` resolves the platform action; `acknowledgeEvents` clears only the Flutter inbox; the HTTPS callback has a third, independent receipt. Read the [state machine](doc/state-machine.md) and [architecture](doc/architecture.md) for the full contract. The Flutter [example](example/README.md) uses `FakeSignaling` and an in-memory journal, so its storage is not a production durability example.

## HTTPS callbacks, push tokens, and diagnostics

```dart
await calls.initialize(JackfieldConfiguration(
  callbacks: CallbackConfiguration(
    endpoint: Uri.parse('https://calls.example.test/jackfield'),
    auth: const CallbackAuth.bearer('short-lived-scoped-token'),
  ),
));

final diagnostics = await calls.diagnostics();
print(diagnostics.pendingFlutterEvents);
print(diagnostics.pendingHttpEvents);
print(diagnostics.httpPausedForAuthentication);
```

Use one owner and one serial write queue to reconcile push tokens:

1. Subscribe to `pushTokenUpdates` and buffer `PushTokenUpdate` values while waiting for `pushTokens()` with a bounded timeout. On `JackfieldFailure<PushTokenSnapshot>`, stream error, or timeout, go to step 4.
2. In the same queue, finish persisting the full `PushTokenSnapshot.tokens` while continuing to buffer updates. Then, **without an `await` between operations**, enqueue the entire buffer in arrival order and switch the listener to enqueue live updates into that queue. This prevents a snapshot write from overwriting a rotation already delivered to the listener.
3. Process every queued write with `try/catch`. On a write error, stop that cycle and go to step 4. Apply `removed == true` as a deletion, not as a new token.
4. Invalidate the cycle generation and check it after every `await` before another write. Cancel the old subscription, wait for the current write to finish, discard pending writes and any late old `pushTokens()` result, and only then start a **new** subscription and snapshot cycle after bounded backoff. An old cycle must not write after a new one. Stop on logout; restart and periodically repeat full server reconciliation.

The stream has no revision or timestamp and no atomic boundary with the snapshot, so this sequence cannot prove that every rotation was observed. `pushTokens()` does not request notification permission. The host application configures FCM, APNs, or Web Push delivery; Jackfield does not bundle a push provider SDK. Use HTTPS and a separate, narrowly scoped bearer token for callbacks. Re-initializing with a rotated endpoint or token resumes a callback queue paused by `401/403`; an active Flutter subscription is not required for a background callback where the platform permits one. See [push integration](doc/push.md) and [HTTPS callbacks](doc/http-callbacks.md). `diagnostics()` reports permission and queue state without secrets.

## Development and evidence

```sh
flutter pub get
dart run tool/check_public_api_docs.dart
dart doc
flutter analyze
flutter test
```

The DartDoc gate checks the namespace, declarations, and public members of every public `lib/*.dart` entrypoint, including re-exports. `dart doc` generates API documentation. See [migration notes](doc/migrations.md) and the [manual validation guide](doc/manual-validation.md). Source and simulator checks do not establish APNs/FCM/Web Push, lock screen, DND, force-stop, browser scheduling, or real callback delivery.
