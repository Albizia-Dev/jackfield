# iOS-адаптер

Адаптер CocoaPods/Swift Package показывает звонки через CallKit и принимает VoIP push через PushKit. Он не управляет медиа и сигнализацией. Приложение подключает медиа после `answer_requested` и вызывает `completeAction` до `actionDeadline`. Для исходящего после готовности сигналинга приложение вызывает `setCallConnected`; CallKit получает `connectedAt`, а snapshot становится `active`.

В примере указаны фоновые режимы `voip`, `remote-notification` и `fetch`. Для настоящего приложения нужны собственные Push Notifications entitlement, APNs environment, provisioning и серверная отправка VoIP push. Incoming payload содержит объект `jackfield` с `callId`, `caller: {id, displayName}` и `media: audio|video`. Remote end payload содержит `{type: ended, callId, reason}`. После обработки CallKit завершается PushKit callback. Сборка в симуляторе не подтверждает доставку push и поведение CallKit на устройстве.

`requestPermissions()` из Flutter запрашивает микрофон, если host объявил
`NSMicrophoneUsageDescription`, и возвращает типизированный отчёт; CallKit и
PushKit не имеют отдельного интерактивного permission prompt. При принятии
звонка адаптер настраивает `AVAudioSession` как `playAndRecord/voiceChat` с
Bluetooth routing. Hold, grouping, ungrouping и DTMF явно не заявляются CallKit.

PushKit, CallKit, audio session и callback runtime пишут privacy-safe этапы в
unified logging с category `Jackfield`. Токены, payload и имена участников не
выводятся; `callId` заменяется коротким SHA-256 отпечатком. Их можно фильтровать
по subsystem host-приложения и category в Console.app.

База данных хранится в защищённом Application Support. Snapshot звонка и событие записываются одной транзакцией SQLite до публикации в stream; индекс `(call_id, sequence)` исключает повтор последовательности. Версия схемы `1` вводится транзакционной миграцией из старой схемы `0`: дубли старых последовательностей сначала перенумеровываются по `(call_id, sequence, rowid)` без сброса receipts. Будущая неизвестная версия отвергается. Если база не открылась, каналы возвращают безопасную ошибку `platformFailure` и PushKit не запускается. Flutter ACK, HTTP receipt и action receipt независимы. UUID CallKit хранится в snapshot: после перезапуска адаптер сверяет его с `CXCallObserver` и не создаёт новый UUID для существующего звонка.

Ответ CallKit остаётся открытым до `completeAction`. Успех до дедлайна вызывает `CXAnswerCallAction.fulfill()`. Отказ или истечение срока атомарно сохраняет action receipt, terminal snapshot и `ended(reason: failed)` до `fail()` и закрытия системного звонка; событие остаётся в outbox для replay. Это терминальное событие допускается даже при достигнутом HTTP admission limit, чтобы не потерять исход системного действия. Дедлайн не превышает `CXAction.timeoutDate`. После перезапуска невосстановимое ожидающее действие завершается как неуспешное; приложение должно начать новый звонок, если требуется повтор.

Bearer token хранится в Keychain. Настроенный HTTPS callback отправляется через фоновый `URLSession` с file-backed body и `Idempotency-Key`; перенаправления запрещены. Каждая передача хранит отпечаток использованных endpoint/token, поэтому поздний `401/403` от старых credentials не ставит новые credentials на паузу. Attempts и next-at сохраняются в SQLite; `BGAppRefreshTask` с идентификатором `dev.albizia.jackfield.callbackRefresh` запрашивает следующий шанс доставки, включая достижение TTL при auth pause. iOS выбирает время запуска сама: точное пробуждение, доставка после force-quit и сроки retry не гарантируются.

Хост-приложение должно объявить `BGTaskSchedulerPermittedIdentifiers` с этим идентификатором и вызвать `JackfieldPlugin.registerBackgroundProcessing()` в `didFinishLaunchingWithOptions`, до запуска Flutter. Этот вызов также немедленно создаёт PushKit registry и CallKit controller; отдельный `prepareForVoIPPushes()` доступен host-приложению, которое не использует background callbacks. В `application(_:handleEventsForBackgroundURLSession:completionHandler:)` приложение передаёт идентификатор и completion в `JackfieldPlugin.handleBackgroundURLSessionEvents(_:completionHandler:)`; для чужого идентификатора использует свой обработчик. При переходе в foreground вызывает `JackfieldPlugin.resumeCallbackDelivery()`. [Пример AppDelegate](../example/ios/Runner/AppDelegate.swift) показывает все три точки. Эти entrypoints восстанавливают SQLite, Keychain, PushKit, CallKit и URLSession без запуска Flutter engine. Completion вызывается после обработки полученных delegate events.

Wire v1 публикует только `answer_requested` и `ended`. Mute и hold CallKit не заявлены. Истёкшее действие получает `deadlineExceeded` и не переводит snapshot в `active`. PushKit, CallKit и серверные callbacks требуют проверки на устройстве и у провайдера; Swift tests и сборка CocoaPods подтверждают только кодовые контракты.

Системный `CXEndCallAction` без ранее запрошенного приложением reason
классифицируется по durable snapshot: завершение из `ringing` публикуется как
`rejected`, из активного/исходящего состояния — как `local`. Явно заданный
сервером или приложением reason сохраняется.
