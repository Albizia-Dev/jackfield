# Матрица проверки платформ

**0.0.2 — экспериментальный выпуск для четырёх платформ.** Реализованы и
зарегистрированы Android, iOS, macOS и Web.
Windows/Linux существуют лишь как исходные scaffolds, не зарегистрированы в
pubspec и не поддерживаются в 0.0.2. Статус адаптера не равен результату
ручного прогона. Удалённые GitHub Actions runs не подтверждены; ссылки на них
не зафиксированы. Матрица учитывает локальный `tool/verify.sh` от 2026-09-24
и более поздний macOS build/run в checkout с правильным именем. Команды и смысл
workflow приведены в [CI](ci.md), условия выпуска — в
[checklist](release-checklist.md).
На текущей ветке локальный Flutter suite прошёл 79/79, worker suite 44/44,
Swift core 58/58, Android unit suite и Go test/vet прошли; iOS device-target
Xcode build и macOS example debug build завершились успешно. Это остаётся
кодовой/сборочной проверкой и не заменяет provider/device proof.

Функциональные пробелы исходного контракта также открыты: Web outgoing,
mute/hold и полная provider/device матрица. iOS системный decline теперь
классифицируется как `rejected` по durable ringing snapshot и покрыт Swift unit
test, но реальный PushKit/CallKit reject relay на двух устройствах ещё не доказан.
Обязательный `expiresAt` и восстановление `missed` после restart покрыты
Android, Swift storage и Web worker tests; точность фонового wake остаётся
ограничением каждой ОС.

| Платформа | Адаптер | Автоматические проверки | Ручные OS/device/provider проверки |
| --- | --- | --- | --- |
| Android | Реализован | Kotlin/Robolectric unit, native callback fixture и debug APK прошли; remote CI not run | 2026-09-30: реальный FCM из test backend разбудил background process, поднял phone-call FGS, wake lock и full-screen поверх locked screen; ringtone playback подтверждён системным audio state. Не подтверждены DND, force-stop и широкая OEM-матрица |
| iOS | Реализован | Swift tests и pod lint прошли; подписанная device-сборка прошла; remote CI not run | Incoming/outgoing/end прошли на iPad с iOS 17.3.1; не подтверждены APNs/PushKit, lock screen и завершённый процесс |
| Web | Реализован | Worker 44/44, включая идемпотентный `missed`; прежние JS/Wasm release builds и smoke прошли; remote CI not run | Не подтверждены Web Push, закрытая вкладка, browser scheduling и notification interaction |
| macOS | Реализован и зарегистрирован | Swift core 58/58; macOS example debug build прошёл после локального обхода basename worktree; remote CI не подтверждён | Не подтверждены реальные notification actions, фоновая доставка и provider сценарии |
| Windows | Не реализован и не зарегистрирован: Task 11 отложен | `windows-scaffold` проверил только исходный scaffold/contract; remote CI не подтверждён | Native call behavior и OS UI не проверены; платформа не поддерживается в 0.0.2 |
| Linux | Не реализован и не зарегистрирован: Task 12 отложен | `linux-scaffold` проверил только исходный scaffold/contract; remote CI не подтверждён | Native call behavior и OS UI не проверены; платформа не поддерживается в 0.0.2 |

Предыдущий aggregate выполнил Dart format/analyze, package tests, example
analyze/25/25 tests, 248/248 публичных DartDoc, consistency fixtures,
Go test/vet/build без Firebase credentials и локальный secret-pattern scan.
`tool/verify.sh` завершился с **exit 1** на указанном iOS Apple blocker; это не
общий PASS. Отдельный macOS build/run не закрывает iOS blocker. Реальные
APNs/FCM/Web Push, TLS/auth rotation, lock screen, DND,
force-stop/process death, browser scheduling и системные уведомления остаются
ручными gates. Для сценариев см. [ручную проверку](manual-validation.md).
