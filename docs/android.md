# Android-адаптер Jackfield

Требования: Android 8.0 / API 26+, `compileSdk 36`, Java 17. Пакет использует
Room 2.8.4, KSP 2.3.5, WorkManager 2.10.1 и Core-Telecom 1.0.1. Example явно
устанавливает `minSdk = 26`; стандартный Flutter минимум 24 здесь недостаточен.

## Системное представление

Адаптер регистрирует приложение через `CallsManager.registerAppWithTelecom`.
После успешной регистрации входящие и исходящие звонки добавляются через
`addCall`. Параллельно публикуется обязательное call-style уведомление с
действиями. Если регистрация или добавление звонка не состоялись, последующие
звонки используют уведомления. При недоступных уведомлениях fallback возвращает
`permissionDenied`.

`nativeCallUi` обозначает успешную интеграцию с Telecom и связанное уведомление.
Это не обещание UI стандартного телефонного приложения: Core-Telecom обслуживает
self-managed VoIP calls. `systemNotification` означает notification fallback,
`unavailable` — отсутствие доступного представления. `capabilities()` повторно
проверяет доступные разрешения; `diagnostics()` сообщает текущий механизм,
состояние уведомлений и `MANAGE_OWN_CALLS`, очереди и безопасную категорию ошибки.
Регистрация и CallStyle следуют [контракту Core-Telecom](https://developer.android.com/develop/connectivity/telecom/voip-app/telecom).

Manifest включает `INTERNET`, `MANAGE_OWN_CALLS` и `POST_NOTIFICATIONS`.
Инициализация не показывает системных запросов разрешений. Приложение отвечает
за разрешение уведомлений, свои media permissions, аудио/видео и foreground
service медиатранспорта. Плагин не включает Firebase, signaling или media SDK,
не запрашивает full-screen intent и не обходит DND.

В `features` входят durable events, HTTPS callbacks, push tokens; при доступном
представлении добавляются incoming, outgoing, answer, reject, end. Mute и hold
не объявляются: wire v1 не содержит соответствующих событий и подтверждений.
Telecom calls создаются без capability удержания. Неподдержанный системный запрос
смены media state не подтверждается как выполненный.

Исходящий звонок регистрируется в `connecting`. Wire v1 не предоставляет команды
«исходящий медиаканал подключён», поэтому `startOutgoingCall` не означает переход
в `active`; этот переход требует будущего расширения контракта. Приложение может
обновить отображение и завершить такой звонок через существующие команды.

## Хранение, действия и replay

Room хранит snapshots, action receipts, события и два независимых delivery
receipt. Для `answer_requested` и `ended` snapshot и событие фиксируются в одной
транзакции до вызова Flutter listener. Wire v1 не определяет событие создания
звонка: `reportIncomingCall` сохраняет snapshot без придуманного event type.

Повторный event ID и старый sequence не меняют snapshot. Отказ admission не
резервирует event ID. При достижении HTTP queue limit возвращается `storageFull`;
просроченные записи освобождают HTTP capacity. Flutter ACK, успешный HTTPS и
`completeAction` изменяют разные записи подтверждения. Повторное завершение
действия возвращает сохранённый исход, включая `deadlineExceeded`.

Подключение к `jackfield/events` повторяет все неподтверждённые Flutter события.
Detach, cancel и ошибки listener не являются ACK. Нативный runtime живёт
независимо от Flutter engine. Поддерживается один активный Flutter consumer;
приложение дедуплицирует replay по `eventId`.

Для ответа используется deadline 4,5 секунды: Core-Telecom ограничивает свой
callback пятью секундами. Flutter/HTTPS обработчик должен выполнить бизнес-
операцию и вызвать `completeAction` до этого срока. HTTP 2xx и Flutter ACK сами
не отвечают на звонок. При живом процессе действует таймер; после его потери
просроченные action receipts восстанавливаются при следующем входе в runtime
или recovery worker. WorkManager не обеспечивает точный deadline во сне ОС.

При серверном `endCall` системное представление закрывается даже при отказе
записи события. Команда возвращает безопасный частичный отказ; после устранения
проблемы хранения приложение повторяет `endCall` для reconciliation.

Если при `endCall` Core-Telecom возвращает ошибку на `disconnect`, вызов сообщает
`temporarilyUnavailable`, но сессия `addCall` уже завершается и control удаляется.
Сохранённый snapshot остаётся `ended`; повторный `endCall` идемпотентен и не
повторяет системный `disconnect`. Результат ошибки не означает, что прежний
Telecom control можно использовать снова.

База `jackfield-v1.db` находится в `noBackupFilesDir`. Схемы v1 и v2 включены в
`android/schemas`; v2 добавляет отпечаток отвергнутых credentials с
миграцией v1→v2 без удаления данных. Записи дедупликации и
action receipts сохраняются, автоматического удаления истории пока нет.

## Автономные callbacks

WorkManager создаёт уникальную последовательность работ
`jackfield.callback.<callId>` на каждый звонок. Только первое pending событие
этого звонка допускается к HTTP, поэтому его задержка не задерживает другие
звонки. Отдельная periodic recovery работа с интервалом 15 минут восстанавливает
окно между Room commit и постановкой работы в планировщик; восстановление также
запускается при создании runtime. Все entrypoints должны работать в одном
процессе приложения.

POST использует системный HTTPS client, bearer auth и `Idempotency-Key`.
Redirects отключены. Ответ, попытка и время следующей отправки сохраняются;
backoff, jitter, Retry-After, TTL и терминальные ответы соответствуют
[общей callback policy](http-callbacks.md). Сетевые ограничения WorkManager,
Doze и ОС могут увеличить фактическую задержку. Просроченное событие больше
не отправляется, даже если очередь приостановлена из-за авторизации.

401/403 приостанавливают все HTTP работы до замены token или endpoint. Повторная
инициализация с теми же credentials паузу не снимает. Устаревший ответ от старых
credentials не приостанавливает уже ротированную конфигурацию. Отсутствие callbacks
в `initialize` отключает отправку. Ранее накопленные записи сохраняются до TTL,
новые события в этом режиме не добавляются в HTTP outbox.

При 401/403 Room сохраняет паузу вместе с SHA-256 отпечатком отвергнутых
endpoint/token. После `initialize` отпечаток текущего защищённого файла
сравнивается с ним: ротация снимает паузу даже после сбоя между записью файла
и обновлением Room; прежние отвергнутые credentials остаются на паузе.
Сам token и endpoint в Room не сохраняются.

Вся callback-конфигурация шифруется AES-GCM, ключ создаётся в AndroidKeyStore,
ciphertext записывается через AtomicFile в `noBackupFilesDir`. В Room, события,
ошибки и diagnostics token не попадает. При недоступном защищённом хранилище
адаптер возвращает отказ; plaintext fallback отсутствует. Приложение может явно
заменить или отключить повреждённую конфигурацию через `initialize`.

## Push без Flutter

Host-приложение проверяет подлинность/TTL provider payload и преобразует его в
`reportIncomingCall` wire v1. Внутри разрешённого provider execution window оно
может дождаться suspend entrypoint:

```kotlin
val result = JackfieldPushReceiver.reportIncomingCall(context, mapOf(
    "version" to 1,
    "callId" to "call-1",
    "caller" to mapOf("id" to "peer-1", "displayName" to "Caller"),
    "media" to "audio",
))
```

`JackfieldPushReceiver.updatePushToken(context, provider, value, removed)`
сохраняет добавление/удаление токена и публикует `jackfield/push_token_updates`.
Сначала подпишитесь на updates, затем запросите `pushTokens`. При ротации host
явно удаляет прежний token и добавляет новый. Значения остаются непрозрачными.

Альтернатива — explicit broadcast в `JackfieldPushReceiver`: action
`dev.albizia.jackfield.INCOMING` и строковый extra `payload` с JSON команды;
для завершения — `dev.albizia.jackfield.END` и JSON `{version, callId, reason}`.
Receiver не экспортируется, использует `goAsync` и не создаёт Flutter engine.
Обработчики действий уведомления также не экспортируются; PendingIntent immutable
и различается по полной идентичности звонка и действия.

## Проверка и ограничения

Автоматические проверки: Room-транзакции/перезапуск, replay, отдельные receipts,
admission, deadlines, retry/TTL/auth, уникальные WorkManager chains, шифрование
конфигурации, CallStyle notification, HTTPS loopback и canonical channel replies.
Robolectric использует API 34 с Java 17. Команда тестов выполняется из host example,
поскольку Flutter embedding и Gradle wrapper подключены там:

```sh
flutter pub get
cd example/android
./gradlew :jackfield:testDebugUnitTest
```

Отдельные gates: `flutter test` в корне и `flutter build apk --debug` в example.
Unit/Robolectric и APK build не доказывают работу AndroidKeyStore на устройстве,
Telecom с OEM, реального push provider, блокировки экрана, DND, Doze и force-stop.
Эти сценарии требуют устройства. После force-stop фоновые запуски не гарантируются.
После потери процесса сохраняются события/receipts, но медиасессия и живой
Telecom control не реконструируются из snapshot; приложение выполняет reconciliation.
