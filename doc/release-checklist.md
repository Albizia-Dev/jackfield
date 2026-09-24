# Проверка экспериментального выпуска Jackfield 0.0.1

**Статус: 0.0.1 готовится как ограниченный экспериментальный выпуск, не как
подтверждённый production-выпуск.** На текущем исходном HEAD `ce1d0f9`
реализованы и зарегистрированы Android, iOS, macOS и Web. Windows и Linux
остались в исходниках как незавершённые scaffolds, но удалены из Flutter plugin
registration и не поддерживаются в 0.0.1. Локальный aggregate от 2026-09-24
остановился на iOS example build до компиляции исходников из-за SwiftPM identity
имени worktree `jackfield-implementation`. Позднее macOS example build/run
прошёл в отдельном detached checkout с basename `jackfield`; это подтверждает
именно macOS host slice, а не полный aggregate или device/provider delivery.
На релизных правках поверх `ce1d0f9` локальные Flutter tests прошли 75/75,
`flutter analyze` сообщил `No issues found`, форматирование и проверка
capability/workflow contract прошли.

## Аудит исходных требований

| Требование | Подтверждено в коде/локальных тестах | Неподтверждённая граница |
| --- | --- | --- |
| Один типизированный Flutter-пакет и единый API | `pubspec.yaml` регистрирует четыре реализованные платформы; `Jackfield.instance` предоставляет команды, события, diagnostics и capabilities; wire v1 проверен canonical fixtures | Windows/Linux остаются незарегистрированным scaffold и не входят в 0.0.1 |
| Входящий и исходящий звонок, системное представление, действия | Android, iOS и macOS имеют оба потока и платформенные unit tests; Web worker проверяет входящий и notification actions; неподдерживаемые функции честно не заявляются в capabilities | Web outgoing, iOS reject и mute/hold требуют реализации либо согласованного изменения исходного контракта; работа заявленных действий в реальном системном UI не проверена |
| Координация доступной системной аудиосессии | Адаптеры оставляют медиатранспорт приложению; Android интегрируется с Core-Telecom, iOS с CallKit | В коде нет явной координации audio focus/`AVAudioSession` или её публичного контракта; macOS guide прямо сообщает об отсутствии управления аудиосессией. Это функциональный пробел, а не пропущенный device test |
| Долговечный replay, монотонный `sequence` внутри `callId`, idempotency | Dart journal/state-machine tests, Android Room/reopen, Swift SQLite/reopen и Web IndexedDB/worker tests покрывают сохранение, порядок и повторы | Остановка Flutter, смерть процесса, миграции и повторный запуск на целевых устройствах/браузерах остаются ручным gate |
| Отдельные `completeAction`, Flutter ACK и HTTP receipt | Dart/native/worker tests проверяют независимость; HTTP success не подтверждает Flutter inbox; action receipts сохраняются | Нужен сквозной опыт с реальным действием ОС, signal/media приложением и callback сервером |
| Опциональный автономный HTTPS callback | Реализованы очереди, TTL, bounded retry, `Retry-After`, 401/403 pause, credential rotation, idempotency header и fixture conformance для Android/Darwin/Web; unit и loopback проверки прошли | Реальный TLS endpoint, auth rotation при сетевых отказах, фоновые ограничения ОС и браузерное расписание не проверены |
| Provider-neutral push entrypoints и токены | Android host FCM entrypoint, iOS PushKit/APNs host integration и Web Service Worker/Push API описаны и имеют локальные тесты; Firebase SDK не входит в библиотеку | Реальные FCM/APNs/Web Push, token rotation и доставка при закрытом приложении не проверены; macOS не заявляет push tokens |
| Человечный API, ошибки, возможности и диагностика | Типизированные результаты и ошибки, явные механизмы, матрица возможностей и пример проверяются Dart/native тестами; docs объясняют отказ разрешения | OS permission, DND, lock screen, notification behavior и OEM различия требуют host/device доказательства |
| Публичная документация | Analyzer-based gate проверил 248/248 публичных объявлений и членов; `dart doc` выполнялся в Task 15; README и платформенные руководства присутствуют | Документация описывает текущие ограничения, но её полнота не доказывает runtime поведение |
| Пример Flutter и Go/FCM ручной стенд | Пример: analyze и 25/25 tests; Go: test, vet и build без credentials; `server_example` не является зависимостью runtime или обязательным provider CI gate | Ручной FCM прогон, server restart и настоящий callback провайдер не проверены; состояние Go стенда in-memory |
| GitHub Actions | Восемь workflow файлов и локальная проверка согласованности команд/fixtures; Windows/Linux workflows явно scaffold-only | Удалённые GitHub runner jobs: **not verified**; run URL не зафиксированы |

## Свежая локальная проверка

Исторический `tool/verify.sh` на macOS выполнил до Apple build: consistency checks; Dart
format/analyze, 74/74 package tests, 248/248 DartDoc gate, example
analyze/25/25 tests; Android JVM/Robolectric unit и debug APK; 27/27 Web worker
tests, JS/Wasm release builds и artifact smoke; Go test/vet/build;
Windows/Linux scaffold checks и локальный secret-pattern scan; 36/36 Swift
tests, iOS/macOS pod lint. Pod lint прошёл с предупреждениями о metadata и
внешнем linker search path. Android unit suite на локальной Java 17 сообщил,
что SDK 36 Robolectric требует Java 21; workflow настроен на Java 21, но
удалённый запуск ещё не выполнен. Полный вывод остановился на iOS simulator
build из-за SwiftPM identity; macOS example build в этом общем прогоне не
достигнут. Последующий macOS example build/run в detached checkout с basename
`jackfield` прошёл. Общий `tool/verify.sh` от 2026-09-24 остаётся **exit 1**,
а iOS example build не засчитывается как пройденный.
Локальный secret-pattern scan означает только поиск известных шаблонов.

## Открытые условия перед стабильным выпуском

- **Функциональные блокеры исходного контракта:** реализовать Web outgoing;
  iOS reject как отдельное действие с корректным `ended(reason: rejected)`;
  mute/hold там, где они обещаны исходным дизайном, с типизированными
  действиями/событиями и честным capability report; координацию доступной
  системной аудиосессии без владения медиа. Альтернатива каждому пункту —
  явно согласовать изменение объёма будущего выпуска и обновить публичный
  контракт. Текущие `unsupported`/отсутствие feature являются честным
  поведением API, но не выполнением этих исходных требований.
- Windows/Linux не входят в 0.0.1: перед будущей регистрацией завершить native
  adapters и проверить реальные вызовы на этих платформах.
- Собрать iOS simulator в checkout с корректной SwiftPM identity; получить
  реальные GitHub Actions run URL и результаты для
  Dart, Android, Apple, Web, Go, Windows/Linux scaffold и secret scan.
- Протестировать уже реализованные действия Android и iOS на устройствах:
  FCM/APNs/PushKit, входящий и исходящий звонок, ответ/завершение и Android
  reject, lock screen, DND, force-stop, процесс без Flutter, expiry и OEM
  notification policy. iOS reject проверять только после его реализации.
- Протестировать macOS host notifications/actions и фоновый запуск; Web Push,
  закрытую вкладку, Service Worker eviction, Background/Periodic Sync и
  notification interaction в поддерживаемых браузерах.
- Проверить HTTPS callback на реальном TLS сервере: duplicate `eventId`,
  порядок в одном звонке, задержку/восстановление, `401/403`, ротацию endpoint
  и bearer, предел очереди и независимость Flutter ACK при смерти процесса.
- Зафиксировать модель устройства/ОС/браузера, provider, разрешения, шаги и
  фактические результаты в [ручной матрице](manual-validation.md). Go/FCM
  пример использовать лишь как один из ручных стендов.
- Проверить итоговый `dart pub publish --dry-run` на коммите релизной подготовки;
  Pod lint с `--allow-warnings` может отдельно сообщать о source/linker metadata.

Отложенные minor тесты не меняют проверенное поведение, но остаются видимыми:
границы shared retry policy (attempt 10/11 и <=0, `Retry-After` <=0, статусы
199/300/600), инъекция mid-query SQLite failure и задержанная отмена прежнего
macOS listener, mismatched snapshot `callId` в Flutter примере, отдельный
extension-type fixture для DartDoc gate. `WireCodec` уже перенесён из
приложенческого импорта в adapter-facing interface в Task 15.

Tag, push, pub.dev publication, Go deployment и merge не входят в этот шаг.
