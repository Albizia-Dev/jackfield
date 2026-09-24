# Контракт каналов Jackfield v1

Прикладной API экспортируется из `package:jackfield/jackfield.dart`.
Регистрация адаптеров — `package:jackfield/jackfield_platform_interface.dart`:
класс адаптера наследует `JackfieldPlatform`, затем устанавливает
`JackfieldPlatform.instance` до первого обращения к `Jackfield.instance`.
`Jackfield.withPlatform(adapter)` создаёт отдельный фасад без изменения
глобальной регистрации. Изменяемого глобального тестового адаптера у фасада нет.

Все данные команды и успешные транспортные ответы проходят `WireCodec`.
Методный канал — `jackfield`, события — `jackfield/events`, обновления токенов —
`jackfield/push_token_updates`. Оба EventChannel получают аргумент подписки
`{"version":1}`. Dart-адаптер разделяет одну broadcast-подписку каждого типа
между слушателями. При новом подключении к native event channel адаптер обязан
повторить неподтверждённые события из durable inbox. Прослушивание, отмена
подписки и получение ошибок не подтверждают события.

## Запросы

Каждый объект содержит целочисленное `version: 1`. Имена методов совпадают с
публичными методами. Остальные поля:

| Метод | Поля |
|---|---|
| `initialize` | необязательный `callbacks`; отсутствие отключает callbacks |
| `capabilities`, `diagnostics`, `pushTokens` | нет |
| `reportIncomingCall` | `callId`, `caller`, `media` |
| `startOutgoingCall` | `callId`, `callee`, `media` |
| `updateCall` | `callId`; необязательные `caller`, `media` |
| `endCall` | `callId`, `reason` |
| `completeAction` | `actionId`, логический `succeeded` |
| `acknowledgeEvents` | список строк `eventIds`; пустой список допустим |

`caller`/`callee` — объект с непустыми строками `id` и `displayName`.
Все идентификаторы — непустые строки; исходное значение сохраняется.
`media`, `reason` и остальные enum-значения кодируются именами Dart enum.
Отсутствующие поля `updateCall` оставляют соответствующие значения неизменными.

`callbacks` содержит `endpoint` (HTTPS без userinfo/fragment), `auth`
(`{"type":"bearer","token":"opaque"}`), положительные целочисленные
`timeToLiveMs` и `maxPendingEvents`. По умолчанию TTL — 24 часа, предел — 1000.
Пустые credentials и CR/LF отклоняются. Инициализация не запрашивает разрешения.
Credentials не допускаются в событиях и diagnostics. Native-адаптер хранит их
защищённо там, где это поддерживается. Политика повторов и HTTP envelope
описаны в [HTTPS callbacks](http-callbacks.md).

## Ответы

Команды, включая `pushTokens`, возвращают один из взаимоисключающих объектов:

```json
{"version":1,"status":"success","value":null}
{"version":1,"status":"failure","error":{"code":"permissionDenied"}}
```

`value` обязателен для успеха, `error` — для отказа. Они не могут присутствовать
одновременно. `initialize`, `completeAction` и `acknowledgeEvents` требуют
`value: null`. Все четыре команды звонков возвращают snapshot. `pushTokens`
возвращает `{"tokens":[{"provider":"apns","value":"opaque"}]}`.
Provider/value — непустые строки.

Snapshot содержит обязательные `callId`, `state`, `media`, `actionReceipts`.
Необязательные nullable-поля: `caller`, `actionId`, `actionDeadline`.
`actionDeadline` — UTC ISO8601 с окончанием `Z`.
Каждая action receipt содержит `actionId`, логический `succeeded`,
необязательный nullable `error`. Receipt передаётся без потери истории действий.

Объект ошибки содержит `code` из `JackfieldErrorCode` и необязательные nullable
строки `message`, `nativeCode`. Адаптер обязан передавать безопасный текст.
Неизвестные коды и поля отклоняются. Произвольные `PlatformException` команд
преобразуются в `platformFailure` без переноса исходных details/message.
Отсутствующий обработчик команды возвращает `unsupported`. Повреждённые
прикладные запросы и ответы возвращают `protocolFailure` без исходного payload.

`capabilities` возвращает отдельный envelope с `version`, `platform`, `mechanism`,
списком `features`, необязательным nullable `reason`. Неизвестные enum запрещены.

`diagnostics` возвращает `version`, `mechanism`, объект `permissions`
(произвольные непустые имена → `JackfieldPermissionState`),
`pendingFlutterEvents`, `pendingHttpEvents`, `httpPausedForAuthentication`,
необязательный nullable `lastError`. Размер очереди — неотрицательное целое или
null, если значение неизвестно. Карта разрешений в Dart неизменяема.

У этих двух запросов нет result-обёртки: повреждённый ответ вызывает
`JackfieldProtocolException`, транспортный `PlatformException` преобразуется в
`JackfieldTransportException.platformFailure()` с безопасной категорией.
Исходные native code/message/details/stacktrace не сохраняются.
Отсутствующий адаптер сообщает unavailable/unsupported и
неизвестные размеры очередей, не симулируя рабочую платформу.

## Потоки и независимые подтверждения

Call events используют уже утверждённые fixtures
`test/fixtures/event_answer_requested_v1.json` и `event_ended_v1.json`.
Обновление push-токена:

```json
{"version":1,"token":{"provider":"apns","value":"opaque"},"removed":false}
```

`removed: true` удаляет указанный токен. Для совмещения snapshot и updates
приложение сначала подписывается на updates. Повреждённый payload становится
ошибкой потока; последующие корректные сообщения продолжают доставляться.

Native error envelopes и ошибки подключения потока преобразуются в
`JackfieldTransportException` без исходных code/message/details/stacktrace;
отсутствующий stream handler даёт категорию `unsupported`, остальные transport
сбои — `platformFailure`. Ошибка listen доставляется подписчику, если он ещё
подписан. Ошибка cancel после ухода последнего подписчика попадает в FlutterError
только как безопасное typed exception с пустым stack trace. Такая же безопасная
диагностика используется, если отложенный listen завершился ошибкой уже после
ухода подписчика. Ошибки не подтверждают события и не закрывают поток.

`completeAction` подтверждает результат работы приложения по `actionId`.
`acknowledgeEvents` подтверждает только Flutter delivery по `eventId`.
HTTP receipt не изменяется ни одной из этих операций. Платформенная реализация
обеспечивает долговечность и повторную доставку; Dart facade их не имитирует.

Тесты этого контракта используют Flutter binary messenger и не доказывают
реализацию native persistence, OS UI, разрешений или push-провайдеров.
