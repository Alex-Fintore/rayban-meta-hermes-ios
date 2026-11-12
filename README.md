# Ray-Ban Meta × Hermes

Экспериментальный помощник для iPhone и очков Ray-Ban Meta. Приложение принимает вопрос голосом или текстом, при необходимости получает снимок с очков, отправляет запрос в Hermes и озвучивает ответ.

## Возможности

- Подключение очков через Meta Wearables Device Access Toolkit, видеопоток и снимки.
- Голосовой ввод через Apple Speech и ручной ввод вопроса.
- Hands-free с обращением «Гермес» / «Hermes»: накопление команды, запрос, озвучивание и возврат к прослушиванию.
- «Какая погода» отправляет текст; «что передо мной» сначала запрашивает снимок. Если снимка нет, визуальный вопрос не отправляется.
- Русский голос для кириллицы, предпочтение установленных голосов повышенного качества и Siri Shortcut `Start Hermes`.
- Ответы о погоде через Open-Meteo без запуска Hermes CLI.
- Токен в Keychain; адрес сервера и идентификатор сессии в UserDefaults.

## Архитектура

```text
Ray-Ban Meta ── Meta DAT ── iPhone / SwiftUI
                              │
                    текст + необязательный JPEG
                              │ HTTPS / Bearer token
                              ▼
                     POST /api/glasses/ask
                              │
                  ┌───────────┴───────────┐
                  ▼                       ▼
              Hermes CLI              Open-Meteo
                  └───────────┬───────────┘
                              ▼
                     JSON → экран + голос
```

| Путь | Назначение |
| --- | --- |
| `ios/CameraAccess.xcodeproj` | Xcode-проект, схема `CameraAccess`, приложение `RaybanHermes` |
| `ios/CameraAccess/CameraAccessApp.swift` | Точка входа, настройка DAT и навигация |
| `ios/CameraAccess/Views/` | Подключение, экран запроса, видеопоток, настройки и отладка |
| `ios/CameraAccess/ViewModels/WearablesViewModel.swift` | Регистрация, список устройств и совместимость |
| `ios/CameraAccess/ViewModels/DeviceSessionManager.swift` | Жизненный цикл сессии очков |
| `ios/CameraAccess/ViewModels/StreamSessionViewModel.swift` | Снимки, голосовой цикл, HTTP-клиент, Keychain и аудио |
| `ios/CameraAccess/ViewModels/HermesHandsFreeCommandParser.swift` | Обращение, буфер команды, текстовый или визуальный запрос |
| `ios/CameraAccess/ViewModels/HermesSpeechVoiceSelector.swift` | Язык и качество голоса |
| `ios/CameraAccess/HermesShortcuts.swift` | App Intent и Siri Shortcut |
| `ios/CameraAccessTests/`, `ios/CameraAccessUITests/` | Meta MockDeviceKit и интерфейсные сценарии |
| `backend/` | Самостоятельный Express-шлюз для iOS; основной вариант локального запуска |
| `deploy/hermes-glasses-webapp/` | Снимок Node.js-сервера с `/health`, `/api/chat` и API очков |
| `.github/workflows/build.yml` | Ручной запуск проверок и сборки iOS Simulator в GitHub Actions |
| `PROJECT.md`, `STATE.md`, `ROADMAP.md` | Назначение, текущая проверка и оставшиеся работы |

Два сервера запускаются отдельно. Они реализуют одинаковый маршрут для iOS, но отличаются конфигурацией и поведением при занятости Hermes. В `deploy/` отсутствует каталог `public/` прежнего веб-интерфейса: API запускается, главная страница возвращает 404.

## Локальный сервер

Нужны Node.js 20+, npm и настроенный Hermes CLI в `PATH`. Ключи провайдера модели настраиваются на стороне Hermes; приложение получает отдельный `APP_TOKEN` шлюза.

Из корня репозитория:

```bash
npm ci --prefix backend
APP_TOKEN=local-development-only PORT=8787 npm start --prefix backend
```

`local-development-only` — пример для локальной проверки. Для своего сервера задайте собственный токен и HTTPS. Реальные токены не следует добавлять в репозиторий.

Запрос без обращения к модели:

```bash
curl http://127.0.0.1:8787/api/glasses/ask \
  -H 'Authorization: Bearer local-development-only' \
  -F 'text=какая погода'
```

Сервер вернёт уточнение города. Вопрос с городом обращается к Open-Meteo; остальные вопросы запускают Hermes CLI.

| Переменная `backend/` | Значение по умолчанию / смысл |
| --- | --- |
| `APP_TOKEN` | Обязательный Bearer token |
| `PORT` | `8787` |
| `HERMES_GLASSES_MODEL` | Не задана; используется настройка Hermes |
| `HERMES_GLASSES_IGNORE_RULES` | Только `1` добавляет `--ignore-rules` |
| `HERMES_MAX_TURNS` | `1` |
| `HERMES_MAX_CONCURRENT` | `1`; остальные запросы ожидают в очереди |
| `HERMES_GLASSES_SOURCE` | `rayban-ios` |

API принимает `multipart/form-data`: обязательное поле `text` до 2000 символов, необязательные `image` (JPEG/PNG до 5 MiB) и `sessionId`. Ответ: `{"answer":"…","sessionId":"…"}`. Express-шлюз удаляет временный снимок до отправки успешного ответа; на ошибке также выполняется очистка. Вопросы с очков запускают Hermes без `--resume`: `sessionId` не означает сохранённый контекст диалога модели.

Альтернативный сервер:

```bash
APP_TOKEN=local-development-only node deploy/hermes-glasses-webapp/server.mjs
```

Он слушает `127.0.0.1:8765`, ищет Hermes в `/usr/local/bin/hermes` (переопределяется через `HERMES_CMD`) и возвращает 429, когда Hermes занят. Здесь `HERMES_GLASSES_IGNORE_RULES` включён по умолчанию; `0` отключает флаг. Этот сервер сохранён как существующая реализация для VPS; команды выше не выполняют развёртывание.

## Сборка и запуск iOS

В проекте задан iOS 17.0+, SDK Meta DAT закреплён на версии `0.8.0` в `Package.resolved`. Нужен полный Xcode: его Command Line Tools недостаточно. Манифест закреплённого SDK требует Swift tools 6.0 ([Package.swift](https://github.com/facebook/meta-wearables-dat-ios/blob/2e30f1253ab76ee3c448a29dce39114ab09763c3/Package.swift)).

```bash
open ios/CameraAccess.xcodeproj
```

Для запуска на iPhone выберите свою команду в Signing & Capabilities и включите Developer Mode. Настройте очки и регистрацию DAT по [документации Meta](https://wearables.developer.meta.com/docs/develop/). В Settings приложения укажите HTTPS-адрес своего шлюза и его Access Token. Для доступа с iPhone нужен доступный телефону адрес сервера: `localhost` относится к самому телефону.

Сборка для симулятора без подписи:

```bash
xcodebuild \
  -project ios/CameraAccess.xcodeproj \
  -scheme CameraAccess \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Результат: `ios/DerivedData/Build/Products/Debug-iphonesimulator/RaybanHermes.app`. Для iPhone нужна отдельная подписанная сборка.

В GitHub откройте **Actions → Build → Run workflow**. Workflow выполняет серверные проверки и ту же сборку на macOS с Xcode, затем сохраняет `RaybanHermes-simulator.zip` в артефактах запуска. Используется [стандартный macOS runner GitHub](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Проверки серверов отдельно:

```bash
npm test --prefix backend
node --test deploy/hermes-glasses-webapp/server.test.mjs
```

## Состояние проверки

12 ноября 2026 года: зависимости Express-шлюза установлены из lock-файла; 9 его тестов и 1 тест альтернативного сервера прошли. Локальный HTTP-запрос получил 401 без авторизации и 200 с тестовым токеном. Чистая Swift-логика обращения, буфера команд, визуального маршрута и выбора голоса скомпилирована и проверена отдельно.

Сборка iOS Simulator прошла на Xcode 26.6 в [GitHub Actions](https://github.com/Alex-Fintore/rayban-meta-hermes-ios/actions/runs/43159923089). В этом запуске также прошли серверные проверки; [архив приложения](https://github.com/Alex-Fintore/rayban-meta-hermes-ios/actions/runs/43159923089/artifacts/13916754429) доступен участникам приватного репозитория. Артефакты Actions имеют срок хранения; workflow позволяет повторить сборку.

На проверенном Mac установлен только Command Line Tools, поэтому использована сборка в GitHub. Текущий снимок и оставшиеся шаги — в [STATE.md](STATE.md).

В коде сохранился прежний адрес `https://hermes.178.104.38.60.sslip.io`. При текущей проверке TLS-сертификат не соответствует этому имени. Для работы приложения требуется исправить HTTPS на сервере либо указать другой работающий адрес в Settings. Изменения сервера и повторная проверка с настоящими очками в эту подготовку репозитория не входят.

## Происхождение iOS-кода

iOS-часть основана на примере CameraAccess из [Meta Wearables DAT iOS](https://github.com/facebook/meta-wearables-dat-ios). Уведомления Meta сохранены; [ios/LICENSE](ios/LICENSE) содержит условия использования SDK из закреплённой версии. Отдельная лицензия для собственных дополнений проекта не выбрана.
