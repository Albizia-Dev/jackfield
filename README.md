# Jackfield

Flutter-плагин для системного представления входящих и исходящих звонков и долговечной доставки действий. Android, iOS, macOS и Web имеют адаптеры. Windows и Linux пока содержат только scaffold и не считаются реализованными.

Jackfield владеет локальным состоянием и системным UI/уведомлением. Авторизация, серверная сессия, сигналинг и аудио/видео остаются в приложении. `server_example/` — необязательный ручной стенд на Go с FCM; библиотека от него не зависит.

## Подключение

Добавьте пакет в `pubspec.yaml` приложения. Основной импорт — `package:jackfield/jackfield.dart`. Платформенным адаптерам доступны `jackfield_platform_interface.dart`, `jackfield_method_channel.dart` и `jackfield_web.dart`; `WireCodec` находится только в интерфейсе адаптеров. Минимумы: Flutter 3.35, Dart 3.9, Android API 26, iOS 13, macOS 11. Подготовка: [Android](docs/android.md), [iOS](docs/ios.md), [macOS](docs/macos.md), [Web](docs/web.md).

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
      caller: const Caller(id: 'peer-7', displayName: 'Алексей'),
      media: CallMedia.audio,
    ),
  );
  if (outcome case JackfieldFailure<CallSnapshot>(:final error)) {
    print(error.code);
  }
}

await calls.startOutgoingCall(
  OutgoingCall(
    callId: const CallId('outgoing-attempt-43'),
    callee: const Caller(id: 'peer-8', displayName: 'Мария'),
    media: CallMedia.audio,
  ),
);
```

`startOutgoingCall` показывает системное состояние, но не устанавливает медиа или серверное соединение. Приложение обязано сверять бизнес-состояние с сервером и закрывать локальное представление через `endCall` при удалённом завершении.

## Обработка ответа и replay

`CallId` — попытка звонка, `ActionId` — действие ОС, `EventId` — запись доставки. Храните `EventId` и результат работы с ним в устойчивом хранилище приложения. После restart неподтверждённое событие может прийти повторно с тем же `EventId`; обработка сигналинга и медиа должна быть идемпотентной. Здесь `eventStore` и `signaling` обозначают компоненты вашего приложения:

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
      // Сохраните/покажите исход; не выдавайте ACK как будто всё выполнено.
      continue;
    }
  }
  await eventStore.markHandled(event.eventId, event.sequence);
  final ack = await calls.acknowledgeEvents({event.eventId});
  if (ack is JackfieldFailure<void>) {
    // Повторный ACK после следующего replay безопасен.
  }
}
```

Проверяйте `AnswerRequested.deadline` и обрабатывайте `deadlineExceeded`: ACK не продлевает действие. `completeAction` подтверждает действие, `acknowledgeEvents` подтверждает только Flutter inbox; HTTPS callback имеет третий независимый receipt. Подробнее: [автомат состояний](docs/state-machine.md) и [архитектура](docs/architecture.md). Ручной пример в `example/` использует имитацию сигналинга; его in-memory журнал не заменяет устойчивое хранилище production-приложения.

## HTTPS callbacks, push и диагностика

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

Согласование push-токенов реализуйте одним владельцем подписки и последовательной очереди записей:

1. Подпишитесь на `pushTokenUpdates` и буферизуйте `PushTokenUpdate`, пока ожидаете `pushTokens()` (с ограниченным временем ожидания). Если пришёл `JackfieldFailure<PushTokenSnapshot>`, ошибка потока или истёк timeout, переходите к шагу 4.
2. В той же очереди дождитесь полного сохранения `PushTokenSnapshot.tokens`. Во время записи продолжайте буферизацию. Затем **без `await` между операциями** поставьте весь буфер в очередь в порядке получения и переключите обработчик на добавление live-обновлений в ту же очередь. Так снимок не перезапишет уже доставленную ротацию.
3. Каждую операцию очереди обрабатывайте с `try/catch`; ошибка записи останавливает цикл и ведёт к шагу 4. Удаление (`removed == true`) применяйте как удаление, а не как новый токен.
4. Пометьте поколение цикла недействительным; после каждого `await` сверяйте его до новой записи. Отмените прежнюю подписку, дождитесь завершения текущей записи, отбросьте её ожидающие операции и поздний результат старого `pushTokens()`; только затем после ограниченной паузы с backoff запустите **новый** цикл с новой подпиской и новым снимком. Старый цикл не может записать данные после нового. На logout остановите цикл; после restart и периодически запускайте полный цикл сверки с сервером.

Поток не содержит revision/timestamp и не даёт атомарной границы начала подписки со снимком; даже этот порядок не доказывает отсутствие пропуска. `pushTokens()` не запрашивает разрешение. Используйте HTTPS endpoint и отдельный узко ограниченный bearer token. Смена endpoint/token повторной `initialize` возобновляет очередь после `401/403`; сама Flutter-подписка не нужна для разрешённого платформой фонового callback. Получение FCM/APNs/Web Push настраивает host-приложение; см. [push](docs/push.md) и [callbacks](docs/http-callbacks.md). Перед действием проверьте `capabilities()`; `diagnostics()` даёт безопасный снимок очередей и разрешений без секретов. [Матрица возможностей](docs/capabilities.md) отдельно описывает реализацию и ограничения проверок.

## Разработка

```sh
flutter pub get
dart run tool/check_public_api_docs.dart
dart doc
flutter analyze
flutter test
```

Проверка DartDoc разрешает namespace каждого публичного `lib/*.dart`, включая реэкспорты, и проверяет объявления и их публичные члены. `dart doc` генерирует справочник API. [Миграции](docs/migrations.md), [матрица валидации](docs/validation-matrix.md) и [ручной сценарий](docs/manual-validation.md) описывают границы подтверждённого поведения. Реальные APNs/FCM/Web Push, lock screen, DND и force-stop требуют отдельного прогона на устройстве и у провайдера.
