# Матрица проверки платформ

**0.0.1 — экспериментальный выпуск для четырёх платформ.** На исходном HEAD
`ce1d0f9` реализованы и зарегистрированы Android, iOS, macOS и Web.
Windows/Linux существуют лишь как исходные scaffolds, не зарегистрированы в
pubspec и не поддерживаются в 0.0.1. Статус адаптера не равен результату
ручного прогона. Удалённые GitHub Actions runs не подтверждены; ссылки на них
не зафиксированы. Матрица учитывает локальный `tool/verify.sh` от 2026-09-24
и более поздний macOS build/run в checkout с правильным именем. Команды и смысл
workflow приведены в [CI](ci.md), условия выпуска — в
[checklist](release-checklist.md).
На релизных правках поверх `ce1d0f9` локальный Flutter suite прошёл 75/75,
analyzer и форматирование прошли; платформенные строки ниже сохраняют границы
ранее выполненного aggregate и отдельного macOS прогона.

Функциональные пробелы исходного контракта также открыты: Web outgoing,
iOS reject, mute/hold и явная координация доступной системной аудиосессии.
Они требуют реализации или согласованного изменения объёма выпуска; device
test не способен подтвердить отсутствующую функцию. iOS reject не включён в
список проверок уже реализованного поведения.

| Платформа | Адаптер | Автоматические проверки | Ручные OS/device/provider проверки |
| --- | --- | --- | --- |
| Android | Реализован | Свежий aggregate: Kotlin/Robolectric unit, native callback fixture и debug APK прошли; remote CI not run | Не подтверждены FCM, lock screen, DND, force-stop и OEM на устройстве |
| iOS | Реализован | Свежий aggregate: Swift 36/36 и pod lint прошли; iOS simulator build остановился до source compilation из-за SwiftPM identity; remote CI not run | Не подтверждены APNs/PushKit/CallKit, lock screen и завершённый процесс на устройстве |
| Web | Реализован | Свежий aggregate: worker 27/27, JS/Wasm release builds и smoke прошли; remote CI not run | Не подтверждены Web Push, закрытая вкладка, browser scheduling и notification interaction |
| macOS | Реализован и зарегистрирован | Swift 36/36 и pod lint прошли в aggregate; macOS example build/run позднее прошёл в detached checkout с basename `jackfield`; remote CI не подтверждён | Не подтверждены реальные notification actions, фоновая доставка и provider сценарии |
| Windows | Не реализован и не зарегистрирован: Task 11 отложен | `windows-scaffold` проверил только исходный scaffold/contract; remote CI не подтверждён | Native call behavior и OS UI не проверены; платформа не поддерживается в 0.0.1 |
| Linux | Не реализован и не зарегистрирован: Task 12 отложен | `linux-scaffold` проверил только исходный scaffold/contract; remote CI не подтверждён | Native call behavior и OS UI не проверены; платформа не поддерживается в 0.0.1 |

Предыдущий aggregate выполнил Dart format/analyze, 74/74 package tests, example
analyze/25/25 tests, 248/248 публичных DartDoc, consistency fixtures,
Go test/vet/build без Firebase credentials и локальный secret-pattern scan.
`tool/verify.sh` завершился с **exit 1** на указанном iOS Apple blocker; это не
общий PASS. Отдельный macOS build/run не закрывает iOS blocker. Реальные
APNs/FCM/Web Push, TLS/auth rotation, lock screen, DND,
force-stop/process death, browser scheduling и системные уведомления остаются
ручными gates. Для сценариев см. [ручную проверку](manual-validation.md).
