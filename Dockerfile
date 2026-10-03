# ─────────────────────────────────────────────────────────────────────────────
# Образ Telegram Bot API с патчем таймаута простоя HTTP-соединения.
#
# Зачем нужен этот образ
# ──────────────────────
# Апстрим tdlib/telegram-bot-api жёстко зашивает таймаут простоя HTTP-соединения
# в telegram-bot-api/HttpServer.h:
#
#     static constexpr td::int32 IDLE_TIMEOUT = 500;   // секунды (~8,3 мин)
#
# Любой запрос, который держит соединение клиента без входящего трафика дольше
# 500 секунд, обрывается сервером (вместо JSON-ответа клиент получает EOF).
# Сам файл при этом успевает загрузиться в Telegram и появляется в чате — но
# ответ (а значит, file_id / message_id) теряется.
#
# С большими стримами (~1,9 ГБ) и скромным аплинком (~20 Мбит/с) один запрос
# sendVideo занимает ~13 минут > 500 с, поэтому это происходит регулярно.
# См. issues #116 и #224 в tdlib/telegram-bot-api (открыты с 2021/2022).
#
# Этот образ поднимает IDLE_TIMEOUT с 500 с до TGBOTAPI_IDLE_TIMEOUT,
# по умолчанию 4 часа.
#
# Почему 4 часа, а не 1 час, который использовался раньше: на 3600 с сервер всё
# ещё обрывал часть размером 1955 МБ — при средних 4,35 Мбит/с, наблюдаемых в
# проде, она передаётся ~64 минуты. Отказ при этом бесшумный: файл сохраняется
# и появляется в чате, но теряется JSON-ответ с file_id / message_id, поэтому
# рекордеру не остаётся ничего, кроме как отправить файл заново и получить
# дубликат.
#
# Расчёт: часть должна дойти до конца раньше этого дедлайна. При
# tools.mkvmerge_split_size = 1500M и пессимистичных 3 Мбит/с это ~70 минут,
# поэтому 4 часа дают запас ~3,4x. Значение остаётся меньше клиентского
# uploadClient.Timeout в 6 ч (internal/recorder/httpclient.go) — это внешняя
# граница и именно она реально ограничивает, сколько мы ждём.
#
# Увеличение дальше ничего не стоит в штатном случае: дедлайн достигается только
# соединением, которое мертво уже столько времени, а watchdog-очистка (reaper,
# staleUploadAfter, 8 ч) подчищает запись, если процесс упал посреди отправки.
# ─────────────────────────────────────────────────────────────────────────────

ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION} AS build

# Ветка/коммит апстрима для сборки. По умолчанию master — то же, что и в
# официальном образе aiogram/telegram-bot-api:latest.
ARG TGBOTAPI_REF=master

# Секунды. Переопределяется на этапе сборки, чтобы не править этот файл.
ARG TGBOTAPI_IDLE_TIMEOUT=14400

ENV CXXFLAGS=""
WORKDIR /usr/src/telegram-bot-api

# Зависимости для сборки + получение исходников апстрима с подмодулями (TDLib).
RUN apk add --no-cache --update alpine-sdk linux-headers git zlib-dev openssl-dev gperf cmake \
 && git init -q \
 && git remote add origin https://github.com/tdlib/telegram-bot-api.git \
 && git fetch -q --depth 1 origin "${TGBOTAPI_REF}" \
 && git checkout -q FETCH_HEAD \
 && git submodule update --init --recursive --depth 1

# Патчим жёстко зашитый таймаут простоя.
#
# Значение в исходниках апстрима ищется как "любые цифры", а не как литерал 500,
# поэтому патч применяется, даже если апстрим поменяет константу. Предыдущая
# версия искала точное совпадение "= 500;" и лишь печатала результат через grep,
# так что при перемещении или переформатировании константы сборка продолжалась
# как ни в чём не бывало — с таймаутом 500 с, то есть образ выглядел
# пропатченным и молча ронял каждую крупную загрузку. Теперь проверка стала
# ошибкой сборки, а не строчкой в логе.
RUN set -eu; \
  if ! grep -q 'IDLE_TIMEOUT' telegram-bot-api/HttpServer.h; then \
    echo "ERROR: no IDLE_TIMEOUT constant in telegram-bot-api/HttpServer.h." >&2; \
    echo "       Upstream may have renamed or removed it; this image cannot be built safely." >&2; \
    exit 1; \
  fi; \
  sed -i -E "s/(static constexpr td::int32 IDLE_TIMEOUT = )[0-9]+;/\1${TGBOTAPI_IDLE_TIMEOUT};/" telegram-bot-api/HttpServer.h; \
  if ! grep -qE "IDLE_TIMEOUT = ${TGBOTAPI_IDLE_TIMEOUT};" telegram-bot-api/HttpServer.h; then \
    echo "ERROR: IDLE_TIMEOUT patch did not apply (wanted ${TGBOTAPI_IDLE_TIMEOUT}s)." >&2; \
    echo "       Upstream declaration may have been reformatted. Found:" >&2; \
    grep -n 'IDLE_TIMEOUT' telegram-bot-api/HttpServer.h >&2 || true; \
    exit 1; \
  fi; \
  echo "--- patched HttpServer.h ---"; \
  grep -n 'IDLE_TIMEOUT = ' telegram-bot-api/HttpServer.h; \
  echo "IDLE_TIMEOUT patched to ${TGBOTAPI_IDLE_TIMEOUT}s"

# nproc — число параллельных задач сборки. По умолчанию 1, чтобы локальная сборка
# на слабой машине не уходила в OOM; в CI сюда передаётся реальное число ядер.
ARG nproc=1
RUN mkdir -p build \
 && cd build \
 && cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX:PATH=.. .. \
 && cmake --build . --target install -j "${nproc}" \
 && strip /usr/src/telegram-bot-api/bin/telegram-bot-api

# ── Этап runtime ──────────────────────────────────────────────────────────────
FROM alpine:${ALPINE_VERSION}

ENV TELEGRAM_WORK_DIR="/var/lib/telegram-bot-api" \
    TELEGRAM_TEMP_DIR="/tmp/telegram-bot-api"

# Непривилегированный пользователь: uid/gid 101 совпадает с официальным образом
# aiogram/telegram-bot-api, поэтому монтируемые каталоги не требуют
# переназначения прав.
RUN apk add --no-cache --update openssl libstdc++ ca-certificates \
 && addgroup -g 101 -S telegram-bot-api \
 && adduser -S -D -H -u 101 -h ${TELEGRAM_WORK_DIR} -s /sbin/nologin -G telegram-bot-api -g telegram-bot-api telegram-bot-api \
 && mkdir -p ${TELEGRAM_WORK_DIR} ${TELEGRAM_TEMP_DIR} \
 && chown telegram-bot-api:telegram-bot-api ${TELEGRAM_WORK_DIR} ${TELEGRAM_TEMP_DIR}

COPY --from=build /usr/src/telegram-bot-api/bin/telegram-bot-api /usr/local/bin/telegram-bot-api
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 8081/tcp 8082/tcp
ENTRYPOINT ["/docker-entrypoint.sh"]