# Jackfield Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Создать надёжный Flutter-плагин управления входящими и исходящими звонками для Android, iOS, macOS, Windows, Linux и Web с долговечными событиями, автономными HTTPS callbacks, полным DartDoc, изолированным Go/FCM стендом и GitHub Actions.

**Architecture:** Один пакет `jackfield` содержит типизированное Dart-ядро, wire protocol v1 и независимые платформенные адаптеры с честным capability report. Команды и события сначала фиксируются, затем публикуются и подтверждаются раздельно; медиа и бизнес-сигналинг остаются в приложении. `server_example` не связан с runtime библиотеки и используется только как пример и ручной FCM/callback стенд.

**Tech Stack:** Flutter 3.44.8, Dart 3.12.2, Kotlin/JVM 17, Swift/XCTest, C++17/CMake, Service Worker/IndexedDB, Go 1.27, Firebase Admin SDK for Go, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-23-jackfield-design.md`

## Global Constraints

- Пакет и идентификатор: `jackfield`, `dev.albizia.jackfield`.
- Платформы: Android, iOS, macOS, Windows, Linux и Web.
- Минимумы: Dart `>=3.9.0 <4.0.0`, Flutter `>=3.35.0`, Android API 26, iOS 13, macOS 11, Windows 10 build 19041, Ubuntu 22.04-class desktop, evergreen browser с Service Worker и IndexedDB.
- Jackfield управляет системным UI и локальным состоянием; медиа, авторизация и бизнес-сигналинг принадлежат приложению.
- `callId`, `actionId`, `eventId` не взаимозаменяемы; `sequence` монотонен внутри `callId`.
- `completeAction` подтверждает действие; `acknowledgeEvents` подтверждает обработку событий.
- События сохраняются до публикации; Flutter inbox и HTTPS outbox подтверждаются независимо.
- Недоступные функции возвращают `unsupported`, а не фиктивный успех.
- `server_example` не является зависимостью, runtime-компонентом или обязательным provider CI gate библиотеки.
- Каждая публичная Dart declaration имеет содержательный DartDoc; CI проверяет 100% покрытия.
- Реальные APNs/FCM/Web Push, DND, lock screen и force-stop учитываются только как ручное device/provider evidence.
- Новое поведение проходит RED → GREEN → REFACTOR; каждый task заканчивается focused и полным доступным suite.

## Review Focus

- Повтор `eventId` после restart даёт одно логическое событие и безопасный повтор ACK — Task 4.
- Два звонка с одинаковым `sequence` не блокируют друг друга — Task 4.
- Истёкший `answerRequested` нельзя успешно завершить — Task 3.
- `401/403` при callback приостанавливает только HTTPS outbox, сохраняя Flutter inbox — Task 6.
- Повреждённый или более новый wire envelope возвращает protocol failure без падения — Task 2.

---

## File Map

- `lib/jackfield.dart` — единственная публичная точка импорта.
- `lib/src/api/` — публичные immutable-типы, результаты, события и конфигурация.
- `lib/src/core/` — автомат состояний, coordinator, дедупликация и deadlines.
- `lib/src/platform/` — platform interface, channel adapter и wire codec.
- `lib/src/storage/` — контракты inbox/outbox и тестовая in-memory реализация.
- `android/`, `ios/`, `macos/`, `windows/`, `linux/`, `web/` — независимые адаптеры.
- `darwin/jackfield/` — общий Swift core для iOS/macOS.
- `test/fixtures/` — canonical wire fixtures.
- `tool/` — DartDoc, fixtures, Web и aggregate verification.
- `example/` — ручная проверка публичного API.
- `server_example/` — изолированный Go/FCM/callback стенд.
- `.github/workflows/` — CI по платформам.

### Task 1: Scaffold пакета и нулевой capability contract

**Files:**
- Create: generated `pubspec.yaml`, `analysis_options.yaml`, `lib/`, platform folders and `example/`
- Create: `lib/src/api/capabilities.dart`, `test/jackfield_test.dart`
- Modify: `lib/jackfield.dart`

**Interfaces:**
- Produces: `JackfieldFeature`, `JackfieldMechanism`, `JackfieldCapabilities.unavailable()`.

- [ ] **Step 1: Generate the scaffold**

```bash
flutter create --template=plugin --platforms=android,ios,macos,windows,linux,web --org dev.albizia --project-name jackfield .
```

Expected: `docs/` сохранён; созданы шесть адаптеров и example.

- [ ] **Step 2: Configure constraints and strict analysis**

Set Dart/Flutter constraints from Global Constraints and enable `strict-casts`, `strict-inference`, `strict-raw-types`, `public_member_api_docs`.

`pubspec.yaml`:

```yaml
environment:
  sdk: ">=3.9.0 <4.0.0"
  flutter: ">=3.35.0"
```

`analysis_options.yaml`:

```yaml
analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
linter:
  rules:
    public_member_api_docs: true
```

- [ ] **Step 3: Write the failing test**

```dart
test('unavailable capabilities advertise no features', () {
  final value = JackfieldCapabilities.unavailable(platform: 'test', reason: 'not-registered');
  expect(value.features, isEmpty);
  expect(value.mechanism, JackfieldMechanism.unavailable);
});
```

- [ ] **Step 4: Verify RED**

Run: `flutter test test/jackfield_test.dart`

Expected: FAIL because `JackfieldCapabilities` is undefined.

- [ ] **Step 5: Implement the minimal types**

```dart
enum JackfieldFeature { incoming, outgoing, answer, reject, end, mute, hold, durableEvents, httpCallbacks, pushTokens }
enum JackfieldMechanism { unavailable, nativeCallUi, systemNotification, webNotification }

final class JackfieldCapabilities {
  const JackfieldCapabilities({required this.platform, required this.mechanism, required this.features, this.reason});
  factory JackfieldCapabilities.unavailable({required String platform, required String reason}) =>
      JackfieldCapabilities(platform: platform, mechanism: JackfieldMechanism.unavailable, features: const {}, reason: reason);
  final String platform;
  final JackfieldMechanism mechanism;
  final Set<JackfieldFeature> features;
  final String? reason;
}
```

- [ ] **Step 6: Verify and commit**

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
git add .
git commit -m "chore: scaffold jackfield flutter plugin"
```

### Task 2: Wire protocol v1 and typed values

**Files:**
- Create: `lib/src/api/identifiers.dart`, `call_models.dart`, `results.dart`, `events.dart`
- Create: `lib/src/platform/wire_codec.dart`
- Create: `test/wire_codec_test.dart`, `test/fixtures/event_answer_requested_v1.json`, `event_ended_v1.json`
- Modify: `lib/jackfield.dart`

**Interfaces:**
- Produces: `CallId`, `ActionId`, `EventId`, call models, push-token models, `JackfieldEvent`, `JackfieldResult<T>`, `WireCodec`.

- [ ] **Step 1: Write failing codec tests**

```dart
test('answer fixture round-trips without identity loss', () {
  final event = WireCodec.decodeEvent(jsonFixture('event_answer_requested_v1.json'));
  expect(event.callId, const CallId('call-1'));
  expect(event.eventId, const EventId('event-7'));
  expect(WireCodec.encodeEvent(event), jsonFixture('event_answer_requested_v1.json'));
});

test('newer version is rejected safely', () {
  expect(() => WireCodec.decodeEvent({'version': 99, 'type': 'ended'}), throwsA(isA<JackfieldProtocolException>()));
});

test('malformed envelope is rejected safely', () {
  expect(() => WireCodec.decodeEvent({'version': 1, 'type': 'ended', 'sequence': -1}), throwsA(isA<JackfieldProtocolException>()));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/wire_codec_test.dart`

Expected: FAIL because identifier and codec types do not exist.

- [ ] **Step 3: Implement strict typed codec**

```dart
extension type const CallId(String value) {}
extension type const ActionId(String value) {}
extension type const EventId(String value) {}

sealed class JackfieldResult<T> { const JackfieldResult(); }
final class JackfieldSuccess<T> extends JackfieldResult<T> { const JackfieldSuccess(this.value); final T value; }
final class JackfieldFailure<T> extends JackfieldResult<T> { const JackfieldFailure(this.error); final JackfieldError error; }
```

Reject empty ids, missing keys, negative sequence, unknown event type and unsupported version with typed protocol errors.

- [ ] **Step 4: Verify and commit**

```bash
flutter test test/wire_codec_test.dart
flutter analyze
flutter test
git add lib test
git commit -m "feat: define jackfield wire protocol"
```

### Task 3: State machine and deadlines

**Files:**
- Create: `lib/src/core/call_state_machine.dart`, `clock.dart`
- Create: `test/call_state_machine_test.dart`

**Interfaces:**
- Produces: `CallStateMachine.apply(CallSnapshot, CallTransition, {required DateTime now})`.

- [ ] **Step 1: Write failing transition tests**

```dart
test('answer moves ringing to connecting once', () {
  final first = machine.apply(ringing, AnswerRequestedTransition(actionId, deadline), now: now);
  final repeated = machine.apply(first.snapshot, AnswerRequestedTransition(actionId, deadline), now: now);
  expect(first.snapshot.state, CallState.connecting);
  expect(repeated.wasDuplicate, isTrue);
});

test('expired answer cannot become active', () {
  final result = machine.apply(connecting, CompleteActionTransition.success(actionId), now: deadline.add(const Duration(seconds: 1)));
  expect(result.error?.code, JackfieldErrorCode.deadlineExceeded);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/call_state_machine_test.dart`

Expected: FAIL because `CallStateMachine` is undefined.

- [ ] **Step 3: Implement legal edges**

Implement `created→ringing|connecting`, `ringing→connecting`, `connecting→active`, every nonterminal state to `ending`, `ending→ended`, and terminal failure. Same `actionId` is idempotent; unrelated illegal transitions return `invalidState`.

```dart
const legalEdges = <CallState, Set<CallState>>{
  CallState.created: {CallState.ringing, CallState.connecting, CallState.ending, CallState.failed},
  CallState.ringing: {CallState.connecting, CallState.ending, CallState.failed},
  CallState.connecting: {CallState.active, CallState.ending, CallState.failed},
  CallState.active: {CallState.ending, CallState.failed},
  CallState.ending: {CallState.ended, CallState.failed},
  CallState.ended: {},
  CallState.failed: {},
};
```

- [ ] **Step 4: Verify and commit**

```bash
flutter test test/call_state_machine_test.dart
flutter test
git add lib/src/core test/call_state_machine_test.dart
git commit -m "feat: add deterministic call state machine"
```

### Task 4: Event journal and replay coordinator

**Files:**
- Create: `lib/src/storage/event_journal.dart`, `memory_event_journal.dart`
- Create: `lib/src/core/event_coordinator.dart`
- Create: `test/event_coordinator_test.dart`

**Interfaces:**
- Produces: `EventJournal.append/pendingFlutter/pendingHttp/acknowledgeFlutter/acknowledgeHttp`, `EventCoordinator.events`.

- [ ] **Step 1: Write failing durability tests**

```dart
test('duplicate event is stored once and ACK is idempotent', () async {
  await coordinator.publish(event);
  await coordinator.publish(event);
  expect(await journal.pendingFlutter(), [event]);
  await journal.acknowledgeFlutter({event.eventId});
  await journal.acknowledgeFlutter({event.eventId});
  expect(await journal.pendingFlutter(), isEmpty);
});

test('ordering is isolated per call', () async {
  await coordinator.publish(callB1);
  await coordinator.publish(callA2);
  await coordinator.publish(callA1);
  expect(await journal.pendingFlutter(), [callB1, callA1, callA2]);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/event_coordinator_test.dart`

Expected: FAIL because journal types are undefined.

- [ ] **Step 3: Implement append-before-publish**

```dart
abstract interface class EventJournal {
  Future<void> append(JackfieldEvent event);
  Future<List<JackfieldEvent>> pendingFlutter();
  Future<List<JackfieldEvent>> pendingHttp();
  Future<void> acknowledgeFlutter(Set<EventId> ids);
  Future<void> acknowledgeHttp(Set<EventId> ids);
  Future<void> pauseHttpForAuthentication();
}
```

The memory journal is test infrastructure; production durability belongs to native adapters.

- [ ] **Step 4: Verify and commit**

```bash
flutter test test/event_coordinator_test.dart
flutter test
git add lib/src/storage lib/src/core/event_coordinator.dart test/event_coordinator_test.dart
git commit -m "feat: add event coordination contract"
```

### Task 5: Platform interface and public facade

**Files:**
- Create: `lib/src/platform/jackfield_platform.dart`, `method_channel_jackfield.dart`
- Create: `lib/src/api/configuration.dart`, `diagnostics.dart`, `callback_configuration.dart`
- Create: `lib/src/jackfield_facade.dart`
- Create: `test/jackfield_facade_test.dart`, `method_channel_contract_test.dart`
- Modify: `lib/jackfield.dart`, `pubspec.yaml`

**Interfaces:**
- Produces: stable `Jackfield` facade and `JackfieldPlatform` adapter contract.

- [ ] **Step 1: Write failing separation test**

```dart
test('action completion and event ACK remain independent', () async {
  final jackfield = Jackfield.withPlatform(fakePlatform);
  await fakePlatform.emit(answerRequested);
  expect(await jackfield.events.first, answerRequested);
  await jackfield.completeAction(actionId, const ActionResult.success());
  expect(fakePlatform.acknowledgedEvents, isEmpty);
  await jackfield.acknowledgeEvents({answerRequested.eventId});
  expect(fakePlatform.acknowledgedEvents.single, {answerRequested.eventId});
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/jackfield_facade_test.dart test/method_channel_contract_test.dart`

Expected: FAIL because `Jackfield` is undefined.

- [ ] **Step 3: Implement the public signatures**

```dart
abstract class Jackfield {
  static final Jackfield instance = JackfieldImpl(JackfieldPlatform.instance);
  factory Jackfield.withPlatform(JackfieldPlatform platform) = JackfieldImpl;
  Future<JackfieldResult<void>> initialize(JackfieldConfiguration configuration);
  Future<JackfieldCapabilities> capabilities();
  Future<JackfieldResult<CallSnapshot>> reportIncomingCall(IncomingCall call);
  Future<JackfieldResult<CallSnapshot>> startOutgoingCall(OutgoingCall call);
  Future<JackfieldResult<CallSnapshot>> updateCall(CallUpdate update);
  Future<JackfieldResult<CallSnapshot>> endCall(CallId id, EndReason reason);
  Future<JackfieldResult<void>> completeAction(ActionId id, ActionResult result);
  Future<JackfieldResult<void>> acknowledgeEvents(Set<EventId> ids);
  Stream<JackfieldEvent> get events;
  Future<JackfieldDiagnostics> diagnostics();
  Future<JackfieldResult<PushTokenSnapshot>> pushTokens();
  Stream<PushTokenUpdate> get pushTokenUpdates;
}
```

Use `plugin_platform_interface`; every channel payload passes through `WireCodec`.

- [ ] **Step 4: Verify and commit**

```bash
flutter test test/jackfield_facade_test.dart test/method_channel_contract_test.dart
flutter analyze
flutter test
git diff --check
git add lib test pubspec.yaml pubspec.lock
git commit -m "feat: expose jackfield public api"
```

### Task 6: Shared HTTPS outbox policy

**Files:**
- Create: `test/callback_configuration_test.dart`, `test/fixtures/callback_answer_requested_v1.json`
- Create: `lib/src/core/callback_dispatcher.dart`
- Create: `docs/http-callbacks.md`
- Modify: `lib/src/api/callback_configuration.dart`

**Interfaces:**
- Produces: `CallbackConfiguration`, `CallbackAuth`, `RetryPolicy.classify`, `CallbackDispatcher.deliver`, canonical callback envelope.

- [ ] **Step 1: Write failing policy tests**

```dart
test('401 pauses HTTP without acknowledging Flutter inbox', () {
  final decision = RetryPolicy.standard.classify(statusCode: 401, attempt: 1, retryAfter: null);
  expect(decision, isA<PauseForAuthentication>());
});

test('retry-after is bounded', () {
  final decision = RetryPolicy.standard.classify(statusCode: 429, attempt: 2, retryAfter: const Duration(days: 1));
  expect((decision as RetryLater).delay, const Duration(minutes: 15));
});

test('authentication pause keeps both delivery records pending', () async {
  await journal.append(event);
  await dispatcher.deliver(event, responseStatus: 401, attempt: 1);
  expect(await journal.pendingHttp(), [event]);
  expect(await journal.pendingFlutter(), [event]);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/callback_configuration_test.dart`

Expected: FAIL because retry decision types are absent.

- [ ] **Step 3: Implement deterministic classification**

Use terminal failure for non-auth `4xx`, pause for `401/403`, bounded retry for `429/5xx/network`, and terminal expiry after TTL. Platform adapters inject jitter. Credentials remain opaque and never enter event payloads.

```dart
RetryDecision classify({int? statusCode, required int attempt, Duration? retryAfter}) => switch (statusCode) {
  >= 200 && < 300 => const DeliverySucceeded(),
  401 || 403 => const PauseForAuthentication(),
  429 || >= 500 => RetryLater(boundedDelay(attempt, retryAfter)),
  >= 400 => const DoNotRetry(),
  null => RetryLater(boundedDelay(attempt, retryAfter)),
  _ => const DoNotRetry(),
};

Future<void> deliver(JackfieldEvent event, {required int responseStatus, required int attempt}) async {
  final decision = retryPolicy.classify(statusCode: responseStatus, attempt: attempt, retryAfter: null);
  if (decision is DeliverySucceeded) await journal.acknowledgeHttp({event.eventId});
  if (decision is PauseForAuthentication) await journal.pauseHttpForAuthentication();
}
```

- [ ] **Step 4: Verify and commit**

```bash
flutter test test/callback_configuration_test.dart
flutter test
git add lib test docs/http-callbacks.md
git commit -m "feat: define reliable callback policy"
```

### Task 7: Android durable adapter

**Files:**
- Create: `android/src/main/kotlin/dev/albizia/jackfield/JackfieldPlugin.kt`, `CallController.kt`
- Create: `android/src/main/kotlin/dev/albizia/jackfield/store/JackfieldDatabase.kt`, `EventEntity.kt`, `EventDao.kt`
- Create: `android/src/main/kotlin/dev/albizia/jackfield/http/CallbackWorker.kt`
- Create: `android/src/main/kotlin/dev/albizia/jackfield/push/JackfieldPushReceiver.kt`
- Create: `android/src/test/kotlin/dev/albizia/jackfield/CallControllerTest.kt`, `EventDaoTest.kt`, `CallbackWorkerTest.kt`
- Modify: `android/build.gradle`, `android/src/main/AndroidManifest.xml`, `docs/android.md`

**Interfaces:**
- Consumes: wire v1, state rules, retry policy.
- Produces: channel backend, Core-Telecom/notification mechanism, Room replay, WorkManager callbacks.

- [ ] **Step 1: Write failing Robolectric tests**

```kotlin
@Test fun `event is committed before emission`() = runTest {
  controller.reportIncoming(fixture)
  assertThat(dao.pendingFlutter().single().eventId).isEqualTo("event-1")
  assertThat(events.single().eventId).isEqualTo("event-1")
}

@Test fun `calls do not head-of-line block callbacks`() = runTest {
  enqueue(callASequence2, callBSequence1, callASequence1)
  assertThat(worker.ready()).containsExactly(callBSequence1, callASequence1)
}
```

- [ ] **Step 2: Verify RED**

Run: `cd android && ./gradlew testDebugUnitTest --tests '*CallControllerTest' --tests '*EventDaoTest' --tests '*CallbackWorkerTest'`

Expected: FAIL because adapter classes are absent.

- [ ] **Step 3: Implement Android persistence and call control**

Persist event and snapshot in one Room transaction before emission. Prefer Core-Telecom when registration succeeds; fall back to call-style notification and report the chosen mechanism. Use unique WorkManager work per `callId`; HTTP success never removes Flutter receipt.

```kotlin
database.withTransaction {
  calls.upsert(snapshot)
  events.insertIgnore(event)
}
eventSink.emit(event.toWireMap())
```

- [ ] **Step 4: Verify and commit**

```bash
(cd android && ./gradlew testDebugUnitTest)
flutter test
(cd example && flutter build apk --debug)
git add android docs/android.md
git commit -m "feat(android): add durable call adapter"
```

### Task 8: Shared Darwin core and iOS adapter

**Files:**
- Create: `darwin/jackfield/Package.swift`
- Create: `darwin/jackfield/Sources/JackfieldCore/EventStore.swift`, `CallbackQueue.swift`, `WireEnvelope.swift`
- Create: `darwin/jackfield/Tests/JackfieldCoreTests/EventStoreTests.swift`, `CallbackQueueTests.swift`
- Create: `ios/Classes/JackfieldPlugin.swift`, `IOSCallController.swift`, `JackfieldPushRegistry.swift`
- Modify: `ios/jackfield.podspec`, example iOS configuration, `docs/ios.md`

**Interfaces:**
- Produces: shared Swift store/outbox and iOS CallKit/PushKit facade.

- [ ] **Step 1: Write failing Swift tests**

```swift
func testAppendIsDurableBeforePublish() async throws {
  try await store.append(answerRequested)
  XCTAssertEqual(try await store.pendingFlutter().map(\.eventId), ["event-1"])
}

func testExpiredAnswerDoesNotActivateCall() async throws {
  let result = try await controller.complete(actionId: "action-1", at: deadline.addingTimeInterval(1))
  XCTAssertEqual(result.errorCode, .deadlineExceeded)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path darwin/jackfield`

Expected: FAIL because Swift core types are absent.

- [ ] **Step 3: Implement durable core and iOS facade**

Use serialized SQLite transactions, protected Application Support storage, Keychain credentials, background URLSession policy, `CXProvider`, `CXCallController` and PushKit entrypoint forwarding. Do not claim media ownership.

```swift
public actor EventStore {
  public func append(_ event: WireEnvelope) throws
  public func pendingFlutter() throws -> [WireEnvelope]
  public func acknowledgeFlutter(_ ids: Set<String>) throws
  public func acknowledgeHTTP(_ ids: Set<String>) throws
}
```

- [ ] **Step 4: Verify and commit**

```bash
swift test --package-path darwin/jackfield
(cd example && flutter build ios --simulator --debug)
git add darwin ios example/ios docs/ios.md
git commit -m "feat(ios): add callkit pushkit adapter"
```

If the installed Xcode lacks the simulator runtime, record its exact error; Swift tests remain the only positive claim.

### Task 9: macOS adapter

**Files:**
- Create: `macos/Classes/JackfieldPlugin.swift`, `MacOSCallController.swift`
- Create: `darwin/jackfield/Tests/JackfieldCoreTests/MacOSCapabilityTests.swift`
- Modify: `macos/jackfield.podspec`, example entitlements, `docs/macos.md`

**Interfaces:**
- Consumes: Task 8 Swift core.
- Produces: notification-backed actions and honest `systemNotification` capabilities.

- [ ] **Step 1: Write failing capability test**

```swift
func testMacOSDoesNotAdvertiseIOSCallKit() {
  let value = MacOSCapabilities.current
  XCTAssertEqual(value.mechanism, .systemNotification)
  XCTAssertFalse(value.features.contains(.nativeCallUi))
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path darwin/jackfield`

Expected: FAIL because `MacOSCapabilities` is absent.

- [ ] **Step 3: Implement UserNotifications actions**

Register answer/reject/end categories, route actions through wire v1, reuse durable Swift store/outbox, expose only features backed by macOS APIs.

```swift
static let current = Capabilities(
  mechanism: .systemNotification,
  features: [.incoming, .outgoing, .answer, .reject, .end, .durableEvents, .httpCallbacks]
)
```

- [ ] **Step 4: Verify and commit**

```bash
swift test --package-path darwin/jackfield
(cd example && flutter build macos --debug)
git add macos darwin example/macos docs/macos.md
git commit -m "feat(macos): add notification call adapter"
```

### Task 10: Web worker, IndexedDB and Push API

**Files:**
- Create: `lib/jackfield_web.dart`, `lib/src/web/jackfield_web_platform.dart`, `web_bridge.dart`
- Create: `web/jackfield_worker.js`, `example/web/jackfield_host_worker.js`
- Create: `tool/web_test/worker_test.mjs`, `flutter_smoke.mjs`, `tool/test_web.sh`
- Modify: `pubspec.yaml`, example web host files, `docs/web.md`

**Interfaces:**
- Produces: Web registrar, `JackfieldWorker.install()`, IndexedDB queues, single-tab event lease and push subscription API.

- [ ] **Step 1: Write failing worker tests**

```javascript
test('push persists before notification', async () => {
  await dispatchPush(answerInvite);
  assert.equal(await db.count('inbox'), 1);
  assert.equal(notifications[0].data.eventId, 'event-1');
});

test('two clients elect one owner', async () => {
  const [a, b] = await openClients(2);
  assert.equal((await Promise.all([a.claim(), b.claim()])).filter(Boolean).length, 1);
});
```

- [ ] **Step 2: Verify RED**

Run: `node --test tool/web_test/worker_test.mjs`

Expected: FAIL because worker runtime is absent.

- [ ] **Step 3: Implement worker and Dart JS interop**

Use IndexedDB transactions, 45-second owner lease, 15-second heartbeat, visible status notification for rejected pushes where required, bounded callbacks and user-gesture-only permission requests. Host worker imports the asset and calls `JackfieldWorker.install()`.

```javascript
importScripts('./assets/packages/jackfield/web/jackfield_worker.js');
JackfieldWorker.install({ leaseMs: 45000, heartbeatMs: 15000 });
```

- [ ] **Step 4: Verify and commit**

```bash
tool/test_web.sh
git add lib web example/web tool docs/web.md pubspec.yaml
git commit -m "feat(web): add durable service worker adapter"
```

### Task 11: Windows adapter

**Files:**
- Create: `windows/jackfield_plugin.cpp`, `.h`, `event_store.cpp`, `.h`, `callback_queue.cpp`, `.h`
- Create: `windows/test/event_store_test.cpp`, `capabilities_test.cpp`
- Modify: `windows/CMakeLists.txt`, `docs/windows.md`

**Interfaces:**
- Produces: Windows channel backend, SQLite journal, WinHTTP outbox and toast actions.

- [ ] **Step 1: Write failing native test**

```cpp
TEST(EventStore, DuplicateEventIdIsIdempotent) {
  EventStore store(TestDatabasePath());
  EXPECT_TRUE(store.Append(EventFixture("event-1")));
  EXPECT_TRUE(store.Append(EventFixture("event-1")));
  EXPECT_EQ(store.PendingFlutter().size(), 1u);
}
```

- [ ] **Step 2: Verify RED on Windows**

Run: `cmake -S windows -B build/windows-tests -DJACKFIELD_BUILD_TESTS=ON && cmake --build build/windows-tests --config Debug && ctest --test-dir build/windows-tests -C Debug --output-on-failure`

Expected: build fails because `EventStore` is absent.

- [ ] **Step 3: Implement Windows durability and toast routing**

Persist before emission, use Windows Credential Manager, route toast activation into durable events, and advertise `systemNotification`, never a fictitious native call UI.

```cpp
class EventStore {
 public:
  bool Append(const WireEvent& event);
  std::vector<WireEvent> PendingFlutter() const;
  bool AcknowledgeFlutter(const std::set<std::string>& event_ids);
};
```

- [ ] **Step 4: Verify and commit on Windows**

```powershell
cmake -S windows -B build/windows-tests -DJACKFIELD_BUILD_TESTS=ON
cmake --build build/windows-tests --config Debug
ctest --test-dir build/windows-tests -C Debug --output-on-failure
(cd example; flutter build windows --debug)
git add windows docs/windows.md
git commit -m "feat(windows): add durable notification adapter"
```

### Task 12: Linux adapter

**Files:**
- Create: `linux/jackfield_plugin.cc`, `.h`, `event_store.cc`, `.h`, `callback_queue.cc`, `.h`
- Create: `linux/test/event_store_test.cc`, `capabilities_test.cc`
- Modify: `linux/CMakeLists.txt`, `docs/linux.md`

**Interfaces:**
- Produces: Linux channel backend, SQLite journal, DBus notification actions, libsecret credentials and runtime capability detection.

- [ ] **Step 1: Write failing capability test**

```cpp
TEST(Capabilities, MissingDbusActionsAreUnsupported) {
  FakeDesktopBus bus(/*supports_actions=*/false);
  const auto value = DetectCapabilities(bus);
  EXPECT_FALSE(value.answer);
  EXPECT_EQ(value.mechanism, Mechanism::kSystemNotification);
}
```

- [ ] **Step 2: Verify RED on Ubuntu**

Run: `cmake -S linux -B build/linux-tests -DJACKFIELD_BUILD_TESTS=ON && cmake --build build/linux-tests && ctest --test-dir build/linux-tests --output-on-failure`

Expected: build fails because capability detection is absent.

- [ ] **Step 3: Implement DBus adapter and outbox**

Detect freedesktop actions at runtime, persist with SQLite before emission, use libsecret when available and return `unsupported` for actions the desktop service cannot deliver.

```cpp
Capabilities DetectCapabilities(const DesktopBus& bus) {
  return Capabilities{.mechanism = Mechanism::kSystemNotification, .answer = bus.SupportsActions()};
}
```

- [ ] **Step 4: Verify and commit on Ubuntu**

```bash
cmake -S linux -B build/linux-tests -DJACKFIELD_BUILD_TESTS=ON
cmake --build build/linux-tests
ctest --test-dir build/linux-tests --output-on-failure
(cd example && flutter build linux --debug)
git add linux docs/linux.md
git commit -m "feat(linux): add durable notification adapter"
```

### Task 13: Isolated Go/FCM manual stand

**Files:**
- Create: `server_example/go.mod`, `cmd/server/main.go`
- Create: `server_example/internal/calls/store.go`, `fcm/sender.go`, `callbacks/handler.go`, `httpapi/router.go`
- Create: `server_example/internal/callbacks/handler_test.go`, `fcm/sender_test.go`
- Create: `server_example/Dockerfile`, `.env.example`, `README.md`

**Interfaces:**
- Consumes: documented wire v1 via JSON fixtures; imports no plugin runtime.
- Produces: `POST /calls`, `POST /callbacks/jackfield`, `POST /calls/{callId}/end`, injectable `PushSender`.

- [ ] **Step 1: Write failing server tests**

```go
func TestCallbackIsIdempotentByEventID(t *testing.T) {
	server := newTestServer()
	postCallback(t, server, answerRequested)
	postCallback(t, server, answerRequested)
	if got := server.store.EventCount("event-1"); got != 1 { t.Fatalf("got %d events", got) }
}

func TestInviteUsesDataMessageWithTTL(t *testing.T) {
	msg := BuildInvite(callFixture)
	if msg.Data["version"] != "1" || msg.Android.TTL <= 0 { t.Fatalf("invalid invite: %#v", msg) }
}
```

- [ ] **Step 2: Verify RED**

Run: `cd server_example && go test ./...`

Expected: FAIL because packages are absent.

- [ ] **Step 3: Implement the isolated stand**

```go
type PushSender interface {
	SendIncoming(ctx context.Context, token string, call calls.Call) (string, error)
}
```

Use Firebase credentials only from `GOOGLE_APPLICATION_CREDENTIALS`, an intentionally in-memory call store, constant-time bearer comparison, and explicit TLS/production-hardening documentation.

- [ ] **Step 4: Verify isolation and commit**

```bash
(cd server_example && gofmt -w cmd/server/main.go internal/calls/store.go internal/fcm/sender.go internal/callbacks/handler.go internal/callbacks/handler_test.go internal/httpapi/router.go internal/fcm/sender_test.go && go vet ./... && go test ./... && go build -o /tmp/jackfield-server-example ./cmd/server)
flutter test
git add server_example test/fixtures
git commit -m "feat(example): add isolated go fcm stand"
```

Expected: all checks pass without Firebase credentials or network access.

### Task 14: Cross-platform example and manual flows

**Files:**
- Create: `example/lib/app.dart`, `call_controller.dart`, `screens/home_screen.dart`, `screens/diagnostics_screen.dart`
- Create: `example/test/call_controller_test.dart`
- Create: `docs/manual-validation.md`, `validation-matrix.md`
- Modify: `example/lib/main.dart` and platform manifests/entitlements

**Interfaces:**
- Consumes: only `package:jackfield/jackfield.dart`.
- Produces: manual incoming/outgoing, complete/ACK, diagnostics, callbacks and push token flows.

- [ ] **Step 1: Write failing example test**

```dart
test('answer completes only after signaling result', () async {
  signaling.nextResult = false;
  await controller.handle(answerRequested);
  expect(fakeJackfield.completed.single.result, const ActionResult.failure());
  expect(fakeJackfield.acknowledged, contains(answerRequested.eventId));
});
```

- [ ] **Step 2: Verify RED**

Run: `cd example && flutter test test/call_controller_test.dart`

Expected: FAIL because the example controller is absent.

- [ ] **Step 3: Implement accessible manual UI**

Use injectable fake signaling with visible success/failure controls. Show capability limitations and diagnostics. Never import `lib/src` or duplicate plugin internals.

```dart
Future<void> handle(AnswerRequested event) async {
  final connected = await signaling.connect(event.callId);
  await jackfield.completeAction(event.actionId, connected ? const ActionResult.success() : const ActionResult.failure());
  await jackfield.acknowledgeEvents({event.eventId});
}
```

- [ ] **Step 4: Verify and commit**

```bash
(cd example && flutter test test/call_controller_test.dart)
(cd example && flutter build macos --debug)
(cd example && flutter build web --debug)
git add example docs/manual-validation.md docs/validation-matrix.md
git commit -m "feat(example): add jackfield integration harness"
```

### Task 15: Complete public documentation and DartDoc gate

**Files:**
- Create: `tool/check_public_api_docs.dart`, `test/public_api_docs_test.dart`
- Create: `docs/architecture.md`, `state-machine.md`, `push.md`, `capabilities.md`, `migrations.md`
- Modify: `README.md`, all exported Dart declarations

**Interfaces:**
- Produces: 100% public DartDoc gate and complete integration guides.

- [ ] **Step 1: Write failing documentation test**

```dart
test('all exported declarations have documentation', () async {
  final result = await Process.run('dart', ['run', 'tool/check_public_api_docs.dart', '--machine']);
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/public_api_docs_test.dart`

Expected: FAIL and list undocumented exports.

- [ ] **Step 3: Implement analyzer-based gate and complete documentation**

Resolve `lib/jackfield.dart`, traverse the exported namespace and fail on missing or whitespace-only docs. Add examples for action completion, event ACK, callbacks, push tokens and capabilities.

```dart
final undocumented = await exportedDeclarationsWithoutDocs('lib/jackfield.dart');
if (undocumented.isNotEmpty) {
  stderr.writeln(undocumented.join('\n'));
  exitCode = 1;
}
```

- [ ] **Step 4: Verify and commit**

```bash
dart doc
dart run tool/check_public_api_docs.dart
flutter analyze
flutter test
git add lib README.md docs tool test/public_api_docs_test.dart
git commit -m "docs: complete jackfield public api reference"
```

### Task 16: GitHub Actions and aggregate verification

**Files:**
- Create: `.github/workflows/dart.yml`, `android.yml`, `apple.yml`, `windows.yml`, `linux.yml`, `web.yml`, `go-example.yml`, `secrets.yml`
- Create: `tool/verify.sh`, `check_capability_matrix.dart`, `check_fixtures.dart`
- Create: `docs/ci.md`
- Modify: `docs/capabilities.md`, `validation-matrix.md`

**Interfaces:**
- Produces: reproducible per-platform gates; real provider credentials remain outside required CI.

- [ ] **Step 1: Write failing repository consistency check**

```dart
test('every declared platform has a capability row', () {
  expect(readCapabilityPlatforms(), containsAll(<String>{'android', 'ios', 'macos', 'windows', 'linux', 'web'}));
});
```

Also fail when canonical fixtures diverge or a workflow omits its documented command.

- [ ] **Step 2: Verify RED**

Run: `dart run tool/check_capability_matrix.dart && dart run tool/check_fixtures.dart`

Expected: FAIL before matrices and workflow declarations are complete.

- [ ] **Step 3: Add isolated workflows**

Use Ubuntu for Dart/Android/Linux/Go/Web, macOS for Swift/iOS/macOS, Windows for C++/Windows. Pin action majors, enable caches, set read-only default permissions, upload failing logs and run secret scanning. Required jobs contain no Firebase/APNs credentials.

```yaml
permissions:
  contents: read
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: tool/verify.sh
```

- [ ] **Step 4: Run fresh local aggregate verification**

```bash
tool/verify.sh
git diff --check
git status --short
```

`tool/verify.sh` runs format/analyze/test/doc, Swift tests, Android unit tests, Web tests, Go checks, macOS and Web builds. Windows/Linux evidence comes from their GitHub runners.

- [ ] **Step 5: Commit**

```bash
git add .github tool docs/ci.md docs/capabilities.md docs/validation-matrix.md
git commit -m "ci: validate jackfield on every platform"
```

### Task 17: Final contract audit and release-candidate evidence

**Files:**
- Create: `docs/release-checklist.md`
- Modify: `CHANGELOG.md`, `README.md`, `docs/validation-matrix.md`

**Interfaces:**
- Produces: auditable verified/manual/unverified claims; does not publish.

- [ ] **Step 1: Run the full fresh verification set**

```bash
tool/verify.sh
git diff --check
git status --short
git log --oneline --decorate -20
```

Expected: local supported checks exit 0; only intentional evidence edits remain.

- [ ] **Step 2: Reconcile GitHub runner results**

If workflows were run by the user, record exact links and outcomes for Dart, Android, Apple, Windows, Linux, Web, Go and secret scanning. Without an authorized push/run, mark every remote runner `not run`; do not push merely to obtain evidence. Failed or skipped runners remain visibly unverified.

- [ ] **Step 3: Audit requirements line by line**

Confirm six registered adapters, incoming/outgoing flows, durable replay, independent receipts, 100% DartDoc, isolated Go stand and honest capabilities. Record APNs/FCM/Web Push and device scenarios separately.

- [ ] **Step 4: Commit evidence**

```bash
git add CHANGELOG.md README.md docs/validation-matrix.md docs/release-checklist.md
git commit -m "docs: record jackfield release candidate evidence"
```

- [ ] **Step 5: Stop before publication**

Report the exact commit, checks and remaining manual gates. Tagging, pushing, pub.dev publication and Go deployment require a separate explicit request.
