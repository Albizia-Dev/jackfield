# iOS-адаптер

Адаптер CocoaPods показывает звонки через CallKit и принимает VoIP push через PushKit. Он не управляет медиа и сигнализацией. Приложение подключает медиа после `answer_requested` и вызывает `completeAction` до `actionDeadline`.

В примере указаны фоновые режимы `voip` и `remote-notification`. Для настоящего приложения нужны собственные Push Notifications entitlement, APNs environment, provisioning и серверная отправка VoIP push. В payload адаптер ожидает объект `jackfield` с `callId`, `caller: {id, displayName}` и `media: audio|video`. После попытки `reportNewIncomingCall` завершается PushKit callback. Сборка в симуляторе не подтверждает доставку push и поведение CallKit на устройстве.

База данных хранится в защищённом Application Support. Snapshot звонка и событие записываются одной транзакцией SQLite до публикации в stream. Flutter ACK, HTTP receipt и action receipt независимы. Bearer token хранится в Keychain. Настроенный HTTPS callback отправляется через фоновый `URLSession`; перенаправления запрещены. Для завершения фоновой передачи после перезапуска процесса приложение должно передавать `application(_:handleEventsForBackgroundURLSession:completionHandler:)` своей координации фоновой сессии. Текущий плагин не предоставляет обработчик этого completion, поэтому доставку после завершения процесса он пока не гарантирует.

Wire v1 публикует только `answer_requested` и `ended`. Mute и hold CallKit не заявлены. Истёкшее действие получает `deadlineExceeded` и не переводит snapshot в `active`. PushKit, CallKit и серверные callbacks требуют проверки на устройстве и у провайдера; Swift tests и сборка CocoaPods подтверждают только кодовые контракты.
