# Проверка кандидата реализации Jackfield 0.0.1

**Статус: выпуск не готов.** Реализованы Android, iOS, macOS и Web. Windows и
Linux зарегистрированы как Flutter plugin scaffolds, но их native adapters
остались незавершёнными после явного переноса Tasks 11/12. Зелёная проверка
scaffold не превращает их в поддерживаемые платформы. Ниже приведены результаты
аудита исходников на `6d9d0a9` (Task 16 fixture fix) и свежего локального
`tool/verify.sh` от 2026-09-24. Результат общего прогона — **exit 1** на iOS
example build до компиляции исходников: worktree называется
`jackfield-implementation`, а SwiftPM override требует identity `jackfield`.
Этот результат не засчитывается как пройденный Apple build.

## Аудит исходных требований

| Требование | Подтверждено в коде/локальных тестах | Неподтверждённая граница |
| --- | --- | --- |
| Один типизированный Flutter-пакет, единый API и шесть регистраций | `pubspec.yaml` регистрирует все шесть; `Jackfield.instance` предоставляет команды, события, diagnostics и capabilities; wire v1 проверен canonical fixtures | Реально реализованы четыре адаптера; Windows/Linux только scaffold |
| Входящий и исходящий звонок, системное представление, действия | Android, iOS и macOS имеют оба потока и платформенные unit tests; Web worker проверяет входящий и notification actions; неподдерживаемые функции честно не заявляются в capabilities | Web не заявляет outgoing; mute/hold не заявлены текущими адаптерами; Android/iOS/macOS/Web не проверены в реальном системном UI |
| Долговечный replay, монотонный `sequence` внутри `callId`, idempotency | Dart journal/state-machine tests, Android Room/reopen, Swift SQLite/reopen и Web IndexedDB/worker tests покрывают сохранение, порядок и повторы | Остановка Flutter, смерть процесса, миграции и повторный запуск на целевых устройствах/браузерах остаются ручным gate |
| Отдельные `completeAction`, Flutter ACK и HTTP receipt | Dart/native/worker tests проверяют независимость; HTTP success не подтверждает Flutter inbox; action receipts сохраняются | Нужен сквозной опыт с реальным действием ОС, signal/media приложением и callback сервером |
| Опциональный автономный HTTPS callback | Реализованы очереди, TTL, bounded retry, `Retry-After`, 401/403 pause, credential rotation, idempotency header и fixture conformance для Android/Darwin/Web; unit и loopback проверки прошли | Реальный TLS endpoint, auth rotation при сетевых отказах, фоновые ограничения ОС и браузерное расписание не проверены |
| Provider-neutral push entrypoints и токены | Android host FCM entrypoint, iOS PushKit/APNs host integration и Web Service Worker/Push API описаны и имеют локальные тесты; Firebase SDK не входит в библиотеку | Реальные FCM/APNs/Web Push, token rotation и доставка при закрытом приложении не проверены; macOS не заявляет push tokens |
| Человечный API, ошибки, возможности и диагностика | Типизированные результаты и ошибки, явные механизмы, матрица возможностей и пример проверяются Dart/native тестами; docs объясняют отказ разрешения | OS permission, DND, lock screen, notification behavior и OEM различия требуют host/device доказательства |
| Публичная документация | Analyzer-based gate проверил 248/248 публичных объявлений и членов; `dart doc` выполнялся в Task 15; README и платформенные руководства присутствуют | Документация описывает текущие ограничения, но её полнота не доказывает runtime поведение |
| Пример Flutter и Go/FCM ручной стенд | Пример: analyze и 25/25 tests; Go: test, vet и build без credentials; `server_example` не является зависимостью runtime или обязательным provider CI gate | Ручной FCM прогон, server restart и настоящий callback провайдер не проверены; состояние Go стенда in-memory |
| GitHub Actions | Восемь workflow файлов и локальная проверка согласованности команд/fixtures; Windows/Linux workflows явно scaffold-only | Все удалённые GitHub runner jobs: **not run**; эти workflow commits ещё не pushed, run URL отсутствуют |

## Свежая локальная проверка

`tool/verify.sh` на macOS выполнил до Apple build: consistency checks; Dart
format/analyze, 74/74 package tests, 248/248 DartDoc gate, example
analyze/25/25 tests; Android JVM/Robolectric unit и debug APK; 27/27 Web worker
tests, JS/Wasm release builds и artifact smoke; Go test/vet/build;
Windows/Linux scaffold checks и локальный secret-pattern scan; 36/36 Swift
tests, iOS/macOS pod lint. Pod lint прошёл с предупреждениями о metadata и
внешнем linker search path. Android unit suite на локальной Java 17 сообщил,
что SDK 36 Robolectric требует Java 21; workflow настроен на Java 21, но
удалённый запуск ещё не выполнен. Полный вывод остановился на iOS simulator
build из-за SwiftPM identity; macOS example build в этом общем прогоне не
достигнут. Отдельная сборка macOS из Task 16 встретила тот же identity blocker.
Локальный secret-pattern scan означает только поиск известных шаблонов.

## Открытые условия перед стабильным выпуском

- Завершить Windows и Linux native adapters и проверку вызовов, либо изменить
  объявленную цель продукта и registration/metadata отдельным решением.
- Собрать iOS simulator и macOS example в checkout с корректной SwiftPM
  identity; затем получить реальные GitHub Actions run URL и результаты для
  Dart, Android, Apple, Web, Go, Windows/Linux scaffold и secret scan.
- Протестировать Android и iOS на устройствах: FCM/APNs/PushKit, входящий и
  исходящий звонок, ответ/отклонение/завершение, lock screen, DND,
  force-stop, процесс без Flutter, expiry, OEM notification policy.
- Протестировать macOS host notifications/actions и фоновый запуск; Web Push,
  закрытую вкладку, Service Worker eviction, Background/Periodic Sync и
  notification interaction в поддерживаемых браузерах.
- Проверить HTTPS callback на реальном TLS сервере: duplicate `eventId`,
  порядок в одном звонке, задержку/восстановление, `401/403`, ротацию endpoint
  и bearer, предел очереди и независимость Flutter ACK при смерти процесса.
- Зафиксировать модель устройства/ОС/браузера, provider, разрешения, шаги и
  фактические результаты в [ручной матрице](manual-validation.md). Go/FCM
  пример использовать лишь как один из ручных стендов.
- Перед публикацией уточнить package/pod metadata: в локальном pod lint
  предупреждения о license type, `source` и совпадающих summary/description;
  `pubspec.yaml` пока имеет пустой `homepage`.

Отложенные minor тесты не меняют проверенное поведение, но остаются видимыми:
границы shared retry policy (attempt 10/11 и <=0, `Retry-After` <=0, статусы
199/300/600), инъекция mid-query SQLite failure и задержанная отмена прежнего
macOS listener, mismatched snapshot `callId` в Flutter примере, отдельный
extension-type fixture для DartDoc gate. `WireCodec` уже перенесён из
приложенческого импорта в adapter-facing interface в Task 15.

Tag, push, pub.dev publication, Go deployment и merge на этом шаге не
выполнялись. Перед ними требуется отдельное решение по открытому списку.
