# Матрица проверки платформ

**Не готово к шестиплатформенному выпуску.** Реализованы четыре адаптера:
Android, iOS, macOS и Web. Windows/Linux зарегистрированы, но остаются
scaffold/incomplete после явного переноса Tasks 11/12. Статус адаптера не равен
результату ручного прогона. Ни один GitHub Actions workflow из этих commits
ещё не запускался; ссылки на run отсутствуют. Эта матрица отражает свежий
локальный `tool/verify.sh` на `6d9d0a9` от 2026-09-24. Команды и смысл
workflow приведены в [CI](ci.md), условия выпуска — в
[checklist](release-checklist.md).

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
| macOS | Реализован | Свежий aggregate: общий Swift 36/36 и pod lint прошли; macOS example build не достигнут после iOS blocker. Отдельный запуск Task 16 имел тот же SwiftPM identity failure; remote CI not run | Не подтверждены системные уведомления/actions, фоновая доставка и конкретный host |
| Windows | Не реализован: Task 11 отложен | Свежий aggregate: `windows-scaffold` проверил только scaffold/contract; remote CI not run | Native call behavior и OS UI не проверены |
| Linux | Не реализован: Task 12 отложен | Свежий aggregate: `linux-scaffold` проверил только scaffold/contract; remote CI not run | Native call behavior и OS UI не проверены |

Свежий aggregate выполнил Dart format/analyze, 74/74 package tests, example
analyze/25/25 tests, 248/248 публичных DartDoc, consistency fixtures,
Go test/vet/build без Firebase credentials и локальный secret-pattern scan.
`tool/verify.sh` завершился с **exit 1** на указанном Apple blocker; это не
общий PASS. Реальные APNs/FCM/Web Push, TLS/auth rotation, lock screen, DND,
force-stop/process death, browser scheduling и системные уведомления остаются
ручными gates. Для сценариев см. [ручную проверку](manual-validation.md).
