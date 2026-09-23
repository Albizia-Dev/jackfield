# Jackfield: ручной Go/FCM стенд

Это отдельный пример интеграции Android FCM data messages и Jackfield HTTPS callbacks. Библиотека Flutter его не импортирует, сервер не обязателен для её работы, а состояние звонков находится только в памяти процесса. Перезапуск сервера стирает звонки и таблицу полученных `eventId`.

## Запуск

Нужны Go 1.24+, проект Firebase с включённым Cloud Messaging и файл service account. Укажите **только** `GOOGLE_APPLICATION_CREDENTIALS` для Firebase credentials. Не помещайте ключ в репозиторий или Docker image. Скопируйте переменные из `.env.example` в своё окружение и задайте два разных длинных случайных bearer token. Переменные из `.env.example` автоматически не загружаются.

```sh
cd server_example
go run ./cmd/server
```

По умолчанию сервер слушает `127.0.0.1:8080`. Для теста с устройством откройте его через HTTPS reverse proxy или защищённый туннель и укажите URL `https://.../callbacks/jackfield` в `JackfieldConfiguration.callbacks`. Внешний HTTP без TLS недопустим для callback bearer token. В контейнере задайте `JACKFIELD_LISTEN_ADDR=0.0.0.0:8080`, смонтируйте service account read-only и завершайте TLS на proxy.

## Один ручной сценарий

Host Android-приложения должен зарегистрировать свой `FirebaseMessagingService`, передать FCM token вашему backend и преобразовать data message в wire v1 для `JackfieldPushReceiver.reportIncomingCall(context, payload)`. Jackfield не содержит FCM SDK и не читает push автоматически. Payload для входящего вызова:

```json
{"version":1,"callId":"call-1","caller":{"id":"person-1","displayName":"Alice"},"media":"audio"}
```

Сервис получает поля `version`, `type`, `callId`, `callerId`, `callerName`, `media`; он проверяет `version == "1"`, `type == "incoming"` и вызывает native entrypoint с объектом выше. Для `type == "end"` и `reason == "remote"` он вызывает native end entrypoint с `{"version":1,"callId":"call-1","reason":"remote"}`. Доставка push и допуск к системному UI зависят от ОС, конфигурации FCM и реального устройства.

Создать входящий вызов:

```sh
curl -X POST https://YOUR_HOST/calls \
  -H 'Authorization: Bearer YOUR_API_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"callId":"call-1","caller":{"id":"person-1","displayName":"Alice"},"media":"audio","fcmToken":"DEVICE_FCM_TOKEN"}'
```

Успех даёт HTTP 201; одинаковый `callId` повторно даёт 409. FCM отправляется как **data-only** сообщение с высоким Android priority и TTL из `JACKFIELD_FCM_TTL` (по умолчанию 90 секунд). FCM message ID подтверждает принятие провайдером, а не показ системного UI.

Когда пользователь нажмёт «Ответить», Jackfield отправит `answer_requested` на callback endpoint. Сервер сохранит событие один раз по `eventId` и отметит `answer_requested`. Это запрос приложению начать media/signaling; фактический успешный ответ требует `completeAction` в приложении. Подтверждение callback не подтверждает Flutter-событие и не означает успешное media соединение. Отклонение приходит как событие `ended` с `reason: "rejected"`; обычное завершение — как `ended` с другой причиной. Тело соответствует `../test/fixtures/callback_answer_requested_v1.json`; заголовки: `Authorization: Bearer YOUR_CALLBACK_TOKEN`, `Idempotency-Key: event-7`. Callback с уже полученным `eventId` или устаревшим `sequence` получает HTTP 204; устаревшее событие сохраняется для дедупликации, но не меняет состояние. Завершённый звонок не возвращается в состояние ответа даже при более позднем `sequence`.

Завершить со стороны сервера:

```sh
curl -X POST https://YOUR_HOST/calls/call-1/end \
  -H 'Authorization: Bearer YOUR_API_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Успех даёт HTTP 204 и отправляет FCM data message `type=end`, `reason=remote`. Повторное завершение уже завершённого звонка даёт 204 без повторной отправки. Пока первая отправка выполняется, параллельный запрос получает HTTP 409 и может повториться позже. Ошибка FCM даёт 502, освобождает резервирование и допускает повтор запроса. Это гарантирует одну одновременную отправку в памяти процесса; после сбоя процесса для строгой однократности нужны постоянное хранилище и outbox.

## Автоматические проверки и границы

`go test ./...`, `go vet ./...` и `go build ./cmd/server` работают без Firebase credentials и без обращения к провайдеру. Тесты подменяют только отправку FCM; маршруты, JSON, auth, сохранение callback и состояние звонка выполняются в памяти. `flutter test` проверяет библиотеку отдельно. Ручной тест с реальным FCM и устройством — отдельное подтверждение, не CI gate библиотеки.

Для production нужны устойчивая БД вместо памяти, транзакции и очередь/outbox для push и завершений, аутентификация операторов и устройств, rate limit, ограничение CORS и запросов, TLS до конечной точки или доверенного proxy, секреты в secret manager, ротация bearer tokens, мониторинг, аудит без персональных данных, обработка отзыва FCM token и защита от повторов после перезапуска. Этот пример не выполняет этих мер.
