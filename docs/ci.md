# CI Jackfield

GitHub Actions запускает независимые проверки. Команды ниже являются контрактом
для `tool/check_capability_matrix.dart`: если workflow и документация расходятся,
проверка завершается ошибкой. Локальный `tool/verify.sh` определяет корень
репозитория по своему пути и без аргумента запускает все доступные на host
этапы. Каждый workflow получает только `contents: read` и не использует
Firebase, APNs, Web Push или реальные callback credentials.

| Workflow | Команда | Доказательство |
| --- | --- | --- |
| `dart.yml` | `tool/verify.sh dart` | Format, analyze, Flutter tests, пример, 100% DartDoc и согласованность контрактов |
| `android.yml` | `tool/verify.sh android` | JVM/Robolectric unit и debug APK; реальное устройство вне CI |
| `apple.yml` | `tool/verify.sh apple` | Swift unit, iOS/macOS pod compilation, iOS simulator и macOS example build |
| `web.yml` | `tool/verify.sh web` | Service Worker tests, JS/Wasm builds и smoke; push delivery вне CI |
| `go-example.yml` | `tool/verify.sh go` | Go tests, vet и build изолированного ручного FCM стенда без credentials |
| `windows.yml` | `tool/verify.sh windows-scaffold` | Только scaffold и документированный incomplete contract; native adapter не реализован |
| `linux.yml` | `tool/verify.sh linux-scaffold` | Только scaffold и документированный incomplete contract; native adapter не реализован |
| `secrets.yml` | `tool/verify.sh secrets` | Локальный поиск типовых ключей по исходникам, в log выводятся только имена файлов |

`tool/check_fixtures.dart` сверяет содержимое и типы канонических JSON fixtures.
Реальный Android callback body сравнивается с fixture в `CallbackWorkerTest`, а
HTTPS заголовки проверяются в `HttpsTransportTest`. Общий Darwin encoder,
используемый iOS и macOS runtime, сравнивает body и заголовки с тем же fixture
в `CallbackEnvelopeFixtureTests`; этот тест входит в Swift gate. Go handler
читает canonical fixture в своих тестах. JSON сравнивается по структуре и
значениям, без зависимости от порядка полей и форматирования файла.

Windows и Linux были отложены; зелёные scaffold workflows не доказывают работу
вызовов или системного UI. Все device/provider/OS notification сценарии
требуют [ручной проверки](manual-validation.md). Автоматическая проверка
секретов ловит известные форматы, но не заменяет review или secret manager.

Для локального запуска из любой директории: `/absolute/path/to/jackfield/tool/verify.sh`.
Явный этап (`dart`, `android`, `apple`, `web`, `go`, `windows-scaffold`,
`linux-scaffold`, `secrets`) требует свой toolchain и завершается ошибкой,
если он отсутствует. Общий запуск сообщает каждый host gate, который пропущен.
В worktree с именем `jackfield-implementation` Flutter Apple example build
может остановиться до компиляции исходников из-за SwiftPM identity
`jackfield-implementation`/`jackfield`; это отдельный не пройденный gate,
даже если pod lint и Swift unit успешны. Результаты CI фиксируются в
[матрице валидации](validation-matrix.md) только после реального запуска.
