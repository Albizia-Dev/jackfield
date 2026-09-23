# Матрица проверки платформ

Статус адаптера не равен результату ручного прогона. Эта матрица отражает состояние реализации и локальные проверки Task 16; удалённые GitHub Actions ещё не запускались. Команды и смысл workflow приведены в [CI](ci.md).

| Платформа | Адаптер | Автоматические проверки | Ручные OS/device/provider проверки |
| --- | --- | --- | --- |
| Android | Реализован | Локальный `tool/verify.sh android`: Kotlin/Robolectric unit и debug APK прошли; CI не запущен | Не подтверждены на устройстве с FCM, lock screen, DND и force stop |
| iOS | Реализован | Локальные Swift 35/35 и pod lint прошли; `tool/verify.sh apple` остановился на iOS simulator build до компиляции исходников из-за SwiftPM identity worktree; CI не запущен | Не подтверждены на устройстве с APNs/PushKit/CallKit, lock screen и завершённым процессом |
| Web | Реализован | Локальный `tool/verify.sh web`: worker tests, JS/Wasm builds и smoke прошли; CI не запущен | Не подтверждены реальные Web Push, браузерное планирование background sync и поведение закрытой вкладки |
| macOS | Реализован | Swift unit и pod lint прошли локально; example build остаётся отдельным непроверенным gate из-за SwiftPM identity `jackfield-implementation`/`jackfield`; CI не запущен | Не подтверждены системные уведомления, actions, фоновая доставка и конкретный macOS host |
| Windows | Не реализован: Task 11 отложен | `tool/verify.sh windows-scaffold` проверяет только scaffold/contract; CI не запущен | Не проверено |
| Linux | Не реализован: Task 12 отложен | `tool/verify.sh linux-scaffold` проверяет только scaffold/contract; CI не запущен | Не проверено |

Локальный `tool/verify.sh dart` прошёл: формат, анализ, тесты примера, 248/248 публичных DartDoc и consistency checks; после последнего consistency-теста полный пакет `flutter test --no-pub` прошёл 74/74. `tool/verify.sh go` прошёл без Firebase credentials. Общий `tool/verify.sh` завершился ошибкой Apple example build на указанном SwiftPM identity blocker. Для сценариев см. [ручную проверку](manual-validation.md).
