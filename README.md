<p align="center">
  <img src="docs/assets/cover.jpg" alt="Hermes — голосовой и визуальный помощник для Ray-Ban Meta и iPhone" width="1280">
</p>

# Hermes для Ray-Ban Meta

**Задайте вопрос о том, что перед вами. Получите ответ голосом.**

Экспериментальный помощник для iPhone и очков Ray-Ban Meta: SwiftUI, камера очков и Hermes в одном голосовом сценарии. Приложение различает обычный вопрос и запрос, для которого нужен снимок.

[![Build](https://github.com/Alex-Fintore/rayban-meta-hermes-ios/actions/workflows/build.yml/badge.svg)](https://github.com/Alex-Fintore/rayban-meta-hermes-ios/actions/workflows/build.yml)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-111111?logo=apple)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-F05138?logo=swift&logoColor=white)
![Meta DAT 0.8.0](https://img.shields.io/badge/Meta_DAT-0.8.0-0866FF)

[Быстрый старт](#быстрый-старт) · [Как работает](#как-это-работает) · [Структура](#структура-проекта) · [Текущий статус](#текущий-статус) · [Руководство разработчика](docs/DEVELOPMENT.md)

## Один вопрос — нужный контекст

Включите Hands-free и обратитесь к помощнику: «Гермес» или «Hermes». Он соберёт фразу, при необходимости получит кадр с очков, отправит запрос и озвучит ответ. После ответа прослушивание возобновится.

| Вопрос | Что делает приложение |
| --- | --- |
| «Гермес, что передо мной?» | Получает снимок с очков и отправляет его вместе с вопросом |
| «Гермес, прочитай это» | Запрашивает снимок для визуального ответа |
| «Гермес, какая погода в Алматы?» | Передаёт запрос в Open-Meteo без запуска модели |
| Обычный вопрос | Отправляет текст без лишнего обращения к камере |

Если визуальный запрос не получил снимок, приложение сообщает об этом. Предыдущий кадр очищается перед каждой новой командой.

Также реализованы ручной ввод, кнопка голосового ввода, просмотр видеопотока, Siri Shortcut `Start Hermes` и выбор качественного русского голоса для кириллицы. Токен шлюза хранится в Keychain.

## Как это работает

```mermaid
flowchart LR
    Glasses["Ray-Ban Meta"] -->|Meta DAT| Phone["iPhone · SwiftUI"]
    Phone -->|"Текст + JPEG · HTTPS"| API["Node.js API"]
    API --> Hermes["Hermes CLI"]
    API --> Weather["Open-Meteo"]
    Hermes --> Answer["Ответ"]
    Weather --> Answer
    Answer --> Phone
    Phone --> Output["Экран + голос"]
```

iPhone работает с очками и голосом. Шлюз проверяет Bearer token, обрабатывает запрос и временный снимок. Hermes отвечает на обычные и визуальные вопросы; погода обрабатывается отдельным маршрутом.

## Быстрый старт

Нужны Node.js 20+, настроенный Hermes CLI и полный Xcode с поддержкой Swift tools 6.0+. SDK Meta DAT закреплён на версии `0.8.0`. Для аппаратной проверки понадобятся совместимые очки и iPhone с Developer Mode.

### 1. Запустите шлюз

```bash
git clone https://github.com/Alex-Fintore/rayban-meta-hermes-ios.git
cd rayban-meta-hermes-ios
npm ci --prefix backend
APP_TOKEN=local-development-only PORT=8787 npm start --prefix backend
```

`local-development-only` — пример для локальной проверки. Для своего сервера используйте собственный токен и HTTPS.

Проверьте HTTP-маршрут без вызова модели:

```bash
curl http://127.0.0.1:8787/api/glasses/ask \
  -H 'Authorization: Bearer local-development-only' \
  -F 'text=какая погода'
```

В ответ придёт уточнение города. Для обычного вопроса серверу потребуется работающий Hermes CLI.

### 2. Настройте приложение

```bash
open ios/CameraAccess.xcodeproj
```

1. Выберите схему `CameraAccess` и свою команду в Signing & Capabilities.
2. Настройте очки и регистрацию DAT по [документации Meta](https://wearables.developer.meta.com/docs/develop/).
3. В Settings приложения укажите HTTPS-адрес **своего** шлюза и его Access Token. Адрес по умолчанию пуст; `localhost` на iPhone относится к самому телефону.
4. Запустите приложение, завершите подключение очков и разрешите микрофон и распознавание речи.

### 3. Соберите для симулятора

Откройте **[Actions → Build](https://github.com/Alex-Fintore/rayban-meta-hermes-ios/actions/workflows/build.yml) → Run workflow**. Готовый `RaybanHermes-simulator.zip` появится в артефактах запуска.

Команда локальной сборки, API и переменные окружения описаны в [руководстве разработчика](docs/DEVELOPMENT.md). Для установки на iPhone требуется отдельная подписанная сборка.

## Структура проекта

| Каталог | Что внутри |
| --- | --- |
| [`ios/`](ios/) | SwiftUI-приложение, интеграция DAT, голос, Keychain, unit- и UI-тесты |
| [`backend/`](backend/) | Express-шлюз для запросов с iPhone |
| [`deploy/hermes-glasses-webapp/`](deploy/hermes-glasses-webapp/) | Снимок альтернативного сервера для VPS |
| [`.github/workflows/`](.github/workflows/) | Воспроизводимая сборка для iOS Simulator |
| [`docs/`](docs/) | Техническое руководство и обложка |

Подробная карта классов и схема запросов — в [руководстве разработчика](docs/DEVELOPMENT.md).

## Текущий статус

**Прототип для разработки и экспериментов.** Сборка iOS Simulator проверена на Xcode 26.6; серверные проверки и локальный HTTP-запрос прошли. [Результаты сборок](https://github.com/Alex-Fintore/rayban-meta-hermes-ios/actions/workflows/build.yml) доступны в Actions.

- Полный сценарий на реальных iPhone и Ray-Ban Meta требует повторной аппаратной проверки.
- Приложению нужен ваш работающий HTTPS-шлюз; готовый облачный сервис в комплект не входит.
- В снимке `deploy/` нет файлов прежнего веб-интерфейса. Для запуска API они не нужны.

Оставшиеся направления — в [ROADMAP.md](ROADMAP.md), актуальная проверка — в [STATE.md](STATE.md).

## Основа проекта

iOS-часть основана на примере CameraAccess из [Meta Wearables DAT iOS](https://github.com/facebook/meta-wearables-dat-ios). Уведомления Meta сохранены; условия SDK находятся в [ios/LICENSE](ios/LICENSE). Отдельная лицензия для собственных дополнений пока не выбрана.

Обложка — концептуальная иллюстрация, созданная встроенным ImageGen. [Промпт](docs/assets/cover-prompt.txt).
