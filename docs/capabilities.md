# Возможности платформ

`capabilities()` возвращает `platform`, `mechanism`, набор `JackfieldFeature` и причину недоступности. Проверяйте его перед кнопками и фоновыми сценариями; набор может меняться после выдачи разрешения или регистрации системного сервиса. `diagnostics()` даёт текущие разрешения, число ожидающих Flutter/HTTP событий и auth pause без токенов. Ни один механизм сам по себе не обещает видимый UI на каждом устройстве или точное фоновое пробуждение.

| Платформа | Реализация и механизм | Заявляемые функции при доступности | Ограничение доказательства |
| --- | --- | --- | --- |
| Android | Реализован: Core-Telecom `nativeCallUi` либо CallStyle `systemNotification` | incoming, outgoing, answer, reject, end, durableEvents, httpCallbacks, pushTokens; mute/hold не заявлены | Проверены unit/Robolectric и APK; устройство, FCM, OEM, DND и force-stop не подтверждены |
| iOS | Реализован: CallKit `nativeCallUi` | incoming, outgoing, answer, end, durableEvents, httpCallbacks, pushTokens; reject/mute/hold не заявлены в текущем report | Swift/unit и pod/typecheck; APNs/PushKit/CallKit на устройстве не подтверждены |
| macOS | Реализован: уведомления `systemNotification` после разрешения | incoming, outgoing, answer, reject, end, durableEvents, httpCallbacks; pushTokens/mute/hold не заявлены | Swift/unit и pod lint; фактические уведомления и фоновый запуск на host не подтверждены |
| Web | Реализован: `webNotification` с активным host Service Worker | incoming, answer, reject, end, durableEvents, httpCallbacks, pushTokens; outgoing/mute/hold не заявлены | Worker tests и JS/Wasm build; реальные Web Push и background scheduling не подтверждены |
| Windows | Task 11 отложен: только scaffold | Нет подтверждённого рабочего adapter contract | Не реализовано и не проверено |
| Linux | Task 12 отложен: только scaffold | Нет подтверждённого рабочего adapter contract | Не реализовано и не проверено |

При отказе разрешений или хранилища адаптер сообщает `unavailable` либо типизированный отказ команды. Android `nativeCallUi` означает self-managed Telecom, а не экран стандартной телефонной программы. Web Notification не является системным call UI. Проверки исходников/симулятора не заменяют [ручную матрицу](validation-matrix.md).
