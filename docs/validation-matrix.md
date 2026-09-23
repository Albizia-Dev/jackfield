# Матрица проверки платформ

Статус адаптера не равен результату ручного прогона. Эта матрица отражает состояние реализации на момент Task 14; она не утверждает, что все платформы прошли device/provider приёмку.

| Платформа | Адаптер | Автоматические проверки | Ручные OS/device/provider проверки |
| --- | --- | --- | --- |
| Android | Реализован | Kotlin unit, Dart suite и APK build ранее выполнялись | Не подтверждены на устройстве с FCM, lock screen, DND и force stop |
| iOS | Реализован | Swift unit, pod lint и typecheck ранее выполнялись; Flutter simulator build блокировался несовпадением имени SwiftPM worktree до компиляции исходников | Не подтверждены на устройстве с APNs/PushKit/CallKit, lock screen и завершённым процессом |
| Web | Реализован | Service Worker unit и JS/Wasm build ранее выполнялись; `flutter build web --debug` для примера прошёл в Task 14 | Не подтверждены реальные Web Push, браузерное планирование background sync и поведение закрытой вкладки |
| macOS | Реализован | Swift unit и pod lint ранее выполнялись; `flutter build macos --debug` для примера в Task 14 остановился до компиляции исходников: SwiftPM identity `jackfield-implementation` конфликтует с `jackfield` | Не подтверждены системные уведомления, actions, фоновая доставка и конкретный macOS host |
| Windows | Не реализован: Task 11 отложен | Сгенерированный scaffold не считается адаптером | Не проверено |
| Linux | Не реализован: Task 12 отложен | Сгенерированный scaffold не считается адаптером | Не проверено |

В Task 14 прошли тесты примера, корневые `flutter analyze` и `flutter test`. Для сценариев см. [ручную проверку](manual-validation.md).
