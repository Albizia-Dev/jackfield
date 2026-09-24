# Архитектура Jackfield

Jackfield предоставляет типизированный Dart-фасад `Jackfield.instance` для системного представления и локального жизненного цикла звонка. Приложение остаётся владельцем пользователя, авторизации, бизнес-состояния, сигналинга и медиатранспорта. Сервер может инициировать push и принимать callbacks, но не заменяет локальные подтверждения действия и события.

## Слои и границы

`lib/jackfield.dart` экспортирует типы звонков, событий, результатов и фасад. `lib/jackfield_platform_interface.dart` адресован авторам адаптеров: он экспортирует `JackfieldPlatform` и wire v1 `WireCodec`. Неструктурированные карты ограничены границей канала. Android, iOS и macOS используют платформенный канал; Web связывается с host Service Worker. Вызовы `initialize`, `capabilities`, `diagnostics`, `pushTokens`, команды звонка и потоки обрабатываются адаптером текущей платформы. При отсутствии функции адаптер возвращает `unsupported` или пустой capability report.

Команда отвечает типизированным `JackfieldSuccess<T>` либо `JackfieldFailure<T>`. Ошибки запросов и потоков, которым нельзя вернуть result wrapper, представлены `JackfieldTransportException`; неверный wire v1 — `JackfieldProtocolException`. Сырые тексты `PlatformException` и bearer token не переходят в приложение. `capabilities()` сообщает фактический механизм, а не только название ОС.

## Надёжное событие

Адаптер сохраняет snapshot звонка и событие до публикации. `CallId` обозначает попытку звонка, `ActionId` — системное действие, `EventId` — доставку, `sequence` упорядочивает события внутри `CallId`. Flutter inbox и HTTPS outbox имеют отдельные receipts. `completeAction` сохраняет исход действия; `acknowledgeEvents` удаляет только обязанность повторной Flutter-доставки. HTTP 2xx подтверждает только HTTP-доставку. При повторном подключении Flutter адаптер воспроизводит неподтверждённые события; приложение дедуплицирует по `EventId` и повторяет ACK при необходимости.

Дедлайн действия задаёт ОС/адаптер. `completeAction` после срока не превращает звонок в активный. Повтор той же команды с тем же `ActionId` возвращает сохранённый исход, когда адаптер может его восстановить. Старый `sequence` не должен перезаписывать более новое состояние. Сервер и приложение сверяют свои данные отдельно: локальный `ended` не является доказательством завершения медиасессии на сервере.

## Независимые адаптеры

- Android: Core-Telecom и CallStyle notification fallback; Room, WorkManager и AndroidKeyStore.
- iOS: CallKit/PushKit; SQLite, Keychain, фоновые `URLSession` и BGTask.
- macOS: `UNUserNotificationCenter`; SQLite и Keychain. После полного завершения приложения точный фоновый запуск не обещан.
- Web: host Service Worker, Notifications/Push API, IndexedDB и lease одной активной Flutter-вкладки. Планирование браузера не гарантирует своевременный background wake.
- Windows и Linux: сгенерированные платформенные папки пока не реализуют этот контракт.

Платформенные детали: [Android](android.md), [iOS](ios.md), [macOS](macos.md), [Web](web.md), [матрица](capabilities.md). `example/` — ручной клиент; `server_example/` — отдельный Go/FCM стенд, не зависимость библиотеки и не обязательный provider gate CI.
