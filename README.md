<div align="center">

# telegram-bot-api-patched

**Telegram Bot API в Docker-образе с увеличенным таймаутом простоя HTTP-соединения**

[![Docker Image CI](https://github.com/internetson/telegram-bot-api-patched/actions/workflows/docker-image.yml/badge.svg)](https://github.com/internetson/telegram-bot-api-patched/actions/workflows/docker-image.yml)
[![GHCR](https://img.shields.io/badge/image-ghcr.io%2Finternetson%2Ftelegram--bot--api--patched-blue)](https://github.com/internetson/telegram-bot-api-patched/pkgs/container/telegram-bot-api-patched)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Alpine](https://img.shields.io/badge/base-alpine%203.20-0D597F.svg)](https://alpinelinux.org/)

[`ghcr.io/internetson/telegram-bot-api-patched:latest`](https://github.com/internetson/telegram-bot-api-patched/pkgs/container/telegram-bot-api-patched)

</div>

---

## 🇷🇺 Русский

### Проблема

Официальный [telegram-bot-api](https://github.com/tdlib/telegram-bot-api) жёстко
зашивает таймаут простоя HTTP-соединения в `telegram-bot-api/HttpServer.h`:

```cpp
static constexpr td::int32 IDLE_TIMEOUT = 500;   // секунды (~8,3 мин)
```

Любой запрос, который держит соединение клиента без входящего трафика дольше
500 секунд, обрывается на стороне сервера: вместо JSON-ответа клиент получает
EOF. Сам файл при этом успевает загрузиться в Telegram и появляется в чате — но
ответ с `file_id` / `message_id` теряется.

С большими стримами (~1,9 ГБ) и скромным аплинком (~20 Мбит/с) один запрос
`sendVideo` занимает ~13 минут, что заведомо больше 500 секунд. Отказ при этом
**бесшумный**: файл сохранён, сообщение в чате есть, а JSON-ответ потерян, и
отправителю приходится отправлять файл заново и получать дубликат.

Апстрим знает о проблеме с 2021–2022 годов: issues
[#116](https://github.com/tdlib/telegram-bot-api/issues/116) и
[#224](https://github.com/tdlib/telegram-bot-api/issues/224).

### Что делает этот образ

Собирает Telegram Bot API из исходников и патчит константу `IDLE_TIMEOUT`
на значение `TGBOTAPI_IDLE_TIMEOUT` (**по умолчанию 4 часа**). Остальное —
`docker-entrypoint.sh`, непривилегированный пользователь с uid/gid 101,
порты 8081/8082 — совпадает с официальным образом
[`aiogram/telegram-bot-api`](https://hub.docker.com/r/aiogram/telegram-bot-api),
поэтому образ можно подставить вместо него без изменений в инфраструктуре.

Почему именно 4 часа:

| Таймаут | Что происходит |
| --- | --- |
| 500 с (апстрим) | Часть ~1,9 ГБ на 20 Мбит/с не успевает дойти — ответ теряется |
| 3600 с | Часть 1955 МБ при средних 4,35 Мбит/с (~64 мин) всё ещё обрывается |
| **14400 с (4 ч)** | Запас ~3,4x к пессимистичным 70 минутам; меньше клиентского таймаута 6 ч |

### Быстрый старт

```bash
docker run -d \
  --name telegram-bot-api \
  --restart unless-stopped \
  -p 8081:8081 \
  -e TELEGRAM_API_ID=123456 \
  -e TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef \
  -v tgbotapi-data:/var/lib/telegram-bot-api \
  ghcr.io/internetson/telegram-bot-api-patched:latest
```

Проверка, что сервер поднялся (у Bot API нет метода `/health`, поэтому проверяем
либо порт, либо любой метод с токеном бота):

```bash
nc -z localhost 8081 && echo "порт отвечает"
curl "http://localhost:8081/bot<ТОКЕН_БОТА>/getMe"
```

Через Docker Compose — в репозитории есть готовый [`docker-compose.yml`](docker-compose.yml):

```bash
cp .env.example .env   # заполнить TELEGRAM_API_ID и TELEGRAM_API_HASH
docker compose up -d
```

### Переменные окружения

| Переменная | Обязательна | По умолчанию | Назначение |
| --- | :---: | --- | --- |
| `TELEGRAM_API_ID` | ✅ | — | Идентификатор приложения с [my.telegram.org](https://my.telegram.org/apps) |
| `TELEGRAM_API_HASH` | ✅ | — | Хеш приложения с my.telegram.org |
| `TELEGRAM_API_ID_FILE` / `TELEGRAM_API_HASH_FILE` | — | — | Читать учётные данные из файла (Docker secrets) |
| `TELEGRAM_WORK_DIR` | ✅ | `/var/lib/telegram-bot-api` | Рабочий каталог, база и локальные файлы |
| `TELEGRAM_TEMP_DIR` | ✅ | `/tmp/telegram-bot-api` | Каталог временных файлов |
| `TELEGRAM_HTTP_PORT` | — | `8081` | HTTP-порт сервера |
| `TELEGRAM_STAT` | — | — | Включает статистику на порту 8082 |
| `TELEGRAM_LOCAL` | — | — | Локальный режим (`--local`) |
| `TELEGRAM_VERBOSITY` | — | — | Уровень логирования (`--verbosity`) |
| `TELEGRAM_MAX_CONNECTIONS` | — | — | Лимит одновременных подключений |
| `TELEGRAM_MAX_WEBHOOK_CONNECTIONS` | — | — | Лимит соединений для webhook |
| `TELEGRAM_PROXY` | — | — | Прокси для исходящих запросов |
| `TELEGRAM_HTTP_IP_ADDRESS` | — | — | IP для привязки HTTP-сервера |
| `TELEGRAM_FILTER` | — | — | Фильтр апдейтов |
| `TELEGRAM_LOG_FILE` | — | — | Путь к файлу лога |

Учётные данные можно передать и через файлы — удобно для Docker secrets:

```bash
docker run -d \
  -e TELEGRAM_API_ID_FILE=/run/secrets/api_id \
  -e TELEGRAM_API_HASH_FILE=/run/secrets/api_hash \
  -v ./secrets:/run/secrets:ro \
  ghcr.io/internetson/telegram-bot-api-patched:latest
```

### Сборка локально

```bash
docker build -t telegram-bot-api-patched:local .
```

Полезные аргументы сборки:

| Аргумент | По умолчанию | Описание |
| --- | --- | --- |
| `TGBOTAPI_IDLE_TIMEOUT` | `14400` | Таймаут простоя соединения в секундах |
| `TGBOTAPI_REF` | `master` | Ветка или тег апстрима |
| `ALPINE_VERSION` | `3.20` | Версия Alpine |
| `nproc` | `1` | Число параллельных задач компиляции |

```bash
docker build -t telegram-bot-api-patched:local \
  --build-arg TGBOTAPI_IDLE_TIMEOUT=21600 \
  --build-arg nproc=4 .
```

> Локальная сборка компилирует TDLib целиком и занимает от 20 до 60 минут
> в зависимости от числа ядер. В CI этот процесс кэшируется.

### Сборка в GitHub Actions

Сборка запускается автоматически после каждого коммита в `main` и каждого PR:

- **`amd64`** собирается на обычном раннере, **`arm64`** — на нативном ARM-раннере
  (`ubuntu-24.04-arm`), то есть без эмуляции;
- кэш сборки хранится в GitHub Actions Cache, повторные прогоны заметно быстрее;
- образ публикуется в GitHub Container Registry как мультиархитектурный манифест;
- отдельная задача `smoke` проверяет, что бинарник запускается, а entrypoint
  корректно отвергает запуск без учётных данных.

Теги образа:

| Тег | Когда появляется |
| --- | --- |
| `latest` | Коммит в `main` |
| `main` | Коммит в `main` |
| `sha-<коммит>` | Любой коммит |
| `v1.2.3`, `v1.2`, `v1` | Тег вида `v*` в репозитории |

Ручной запуск и переопределение параметров: **Actions → Docker Image → Run
workflow**. Для 32-битного ARM (`linux/arm/v7`) есть закомментированный блок в
[`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml) —
раскомментируйте его, если такая сборка нужна.

### Диагностика

| Симптом | Что делать |
| --- | --- |
| `error: environment variable TELEGRAM_API_ID is required` | Не переданы учётные данные |
| `both TELEGRAM_API_ID and TELEGRAM_API_ID_FILE are set` | Заданы оба способа — оставьте что-то одно |
| `Can't find directory for temporary files` | Проверьте `TELEGRAM_TEMP_DIR` и права наvolume |
| `Permission denied` при записи в рабочий каталог | Внутри образа uid/gid 101 — выставьте права на volume или `user:` в Compose |
| `IDLE_TIMEOUT patch did not apply` | Апстрим переформатировал объявление константы; сборка честно падает вместо того, чтобы тихо собрать непатченный образ |

Убедиться, что патч применён, можно по логам сборки — там есть строка
`IDLE_TIMEOUT patched to 14400s`. Если этой строки нет, сборка была прервана
проверкой и патч не применился: образ в этом случае не публикуется.

### Благодарности

- [tdlib/telegram-bot-api](https://github.com/tdlib/telegram-bot-api) — сам сервер
- [TDLib](https://github.com/tdlib/td) — библиотека, собираемая как подмодуль
- [aiogram/telegram-bot-api](https://hub.docker.com/r/aiogram/telegram-bot-api) — идея
  готового Docker-образа и `docker-entrypoint.sh`, который здесь воспроизводится

## 🇬🇧 English

### The problem

The official [telegram-bot-api](https://github.com/tdlib/telegram-bot-api)
hardcodes the HTTP connection idle timeout in `telegram-bot-api/HttpServer.h`:

```cpp
static constexpr td::int32 IDLE_TIMEOUT = 500;   // seconds (~8.3 min)
```

Any request that keeps the client connection without incoming traffic for more
than 500 seconds is dropped by the server: the client receives EOF instead of a
JSON response. The file itself is still uploaded to Telegram and shows up in the
chat — but the response carrying `file_id` / `message_id` is lost.

With large stream parts (~1.9 GB) and a modest uplink (~20 Mbit/s) a single
`sendVideo` takes ~13 minutes, well over the 500 second limit. The failure is
**silent**: the file is stored, the message appears in the chat, but the sender
loses the response and has to re-upload, producing a duplicate.

Upstream has known about this since 2021–2022: issues
[#116](https://github.com/tdlib/telegram-bot-api/issues/116) and
[#224](https://github.com/tdlib/telegram-bot-api/issues/224).

### What this image does

It builds Telegram Bot API from source and patches the `IDLE_TIMEOUT` constant
to `TGBOTAPI_IDLE_TIMEOUT` (**4 hours by default**). Everything else — the
`docker-entrypoint.sh`, the unprivileged user with uid/gid 101, ports 8081/8082
— matches the official [`aiogram/telegram-bot-api`](https://hub.docker.com/r/aiogram/telegram-bot-api)
image, so this image can replace it without infrastructure changes.

| Idle timeout | Outcome |
| --- | --- |
| 500 s (upstream) | A ~1.9 GB part at 20 Mbit/s never finishes — the response is lost |
| 3600 s | A 1955 MB part at the observed 4.35 Mbit/s (~64 min) is still cut |
| **14400 s (4 h)** | ~3.4x headroom over a pessimistic 70 minutes, still below the 6 h client timeout |

### Quick start

```bash
docker run -d \
  --name telegram-bot-api \
  --restart unless-stopped \
  -p 8081:8081 \
  -e TELEGRAM_API_ID=123456 \
  -e TELEGRAM_API_HASH=0123456789abcdef0123456789abcdef \
  -v tgbotapi-data:/var/lib/telegram-bot-api \
  ghcr.io/internetson/telegram-bot-api-patched:latest
```

Or with Docker Compose using the bundled [`docker-compose.yml`](docker-compose.yml):

```bash
cp .env.example .env   # fill in TELEGRAM_API_ID and TELEGRAM_API_HASH
docker compose up -d
```

### Environment variables

| Variable | Required | Default | Purpose |
| --- | :---: | --- | --- |
| `TELEGRAM_API_ID` | ✅ | — | Application ID from [my.telegram.org](https://my.telegram.org/apps) |
| `TELEGRAM_API_HASH` | ✅ | — | Application hash from my.telegram.org |
| `TELEGRAM_API_ID_FILE` / `TELEGRAM_API_HASH_FILE` | — | — | Read credentials from a file (Docker secrets) |
| `TELEGRAM_WORK_DIR` | ✅ | `/var/lib/telegram-bot-api` | Working directory, database and local files |
| `TELEGRAM_TEMP_DIR` | ✅ | `/tmp/telegram-bot-api` | Temporary file directory |
| `TELEGRAM_HTTP_PORT` | — | `8081` | HTTP server port |
| `TELEGRAM_STAT` | — | — | Enable statistics on port 8082 |
| `TELEGRAM_LOCAL` | — | — | Local mode (`--local`) |
| `TELEGRAM_VERBOSITY` | — | — | Log verbosity level |
| `TELEGRAM_MAX_CONNECTIONS` | — | — | Maximum simultaneous connections |
| `TELEGRAM_MAX_WEBHOOK_CONNECTIONS` | — | — | Maximum webhook connections |
| `TELEGRAM_PROXY` | — | — | Proxy for outgoing requests |
| `TELEGRAM_HTTP_IP_ADDRESS` | — | — | IP address to bind the HTTP server to |
| `TELEGRAM_FILTER` | — | — | Update filter |
| `TELEGRAM_LOG_FILE` | — | — | Path to the log file |

### Build locally

```bash
docker build -t telegram-bot-api-patched:local .
```

| Build argument | Default | Description |
| --- | --- | --- |
| `TGBOTAPI_IDLE_TIMEOUT` | `14400` | Connection idle timeout in seconds |
| `TGBOTAPI_REF` | `master` | Upstream branch or tag |
| `ALPINE_VERSION` | `3.20` | Alpine version |
| `nproc` | `1` | Parallel compile jobs |

A local build compiles all of TDLib and takes 20–60 minutes depending on core
count; CI caches it between runs.

### Builds in GitHub Actions

Every commit to `main` and every pull request triggers a build:

- **`amd64`** builds on a standard runner, **`arm64`** on a native ARM runner
  (`ubuntu-24.04-arm`), so no emulation is involved;
- the build cache is stored in GitHub Actions Cache;
- the image is published to GitHub Container Registry as a multi-platform manifest;
- a separate `smoke` job verifies that the binary runs and that the entrypoint
  refuses to start without credentials.

Image tags: `latest` and `main` for commits to `main`, `sha-<commit>` for every
commit, and `v1.2.3` / `v1.2` / `v1` for `v*` repository tags. Manual runs with
overridable parameters are available under **Actions → Docker Image → Run
workflow**. A commented-out block for 32-bit ARM (`linux/arm/v7`) lives in
[`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml).

### Troubleshooting

| Symptom | Action |
| --- | --- |
| `error: environment variable TELEGRAM_API_ID is required` | Credentials were not passed |
| `both TELEGRAM_API_ID and TELEGRAM_API_ID_FILE are set` | Set only one way to pass credentials |
| `Can't find directory for temporary files` | Check `TELEGRAM_TEMP_DIR` and volume permissions |
| `Permission denied` when writing to the working directory | The image uses uid/gid 101 — fix volume ownership or set `user:` in Compose |
| `IDLE_TIMEOUT patch did not apply` | Upstream reformatted the declaration; the build fails loudly instead of silently shipping an unpatched image |

### Credits

- [tdlib/telegram-bot-api](https://github.com/tdlib/telegram-bot-api) — the server itself
- [TDLib](https://github.com/tdlib/td) — the library built as a submodule
- [aiogram/telegram-bot-api](https://hub.docker.com/r/aiogram/telegram-bot-api) — the
  ready-made image concept and the `docker-entrypoint.sh` reproduced here

---

## Лицензия / License

[MIT](LICENSE) © 2026 internetson.
The bundled third-party sources ([telegram-bot-api](https://github.com/tdlib/telegram-bot-api),
TDLib) are licensed under the Boost Software License 1.0.