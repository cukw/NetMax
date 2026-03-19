# NetMax Messenger

Кроссплатформенный корпоративный мессенджер на Flutter с веб-версией и backend на Dart.

## Что уже реализовано
- Авторизация по имени и паролю (пользователи хранятся в SQLite `backend/config/users.sqlite3`, `authorized_users.json` используется как bootstrap при первом запуске).
- Регистрация и вход по `телефон + email` с подтверждением по email: запрос кода подтверждения на почту и вход по `телефон + email + код`; для нового номера можно создать профиль при первом входе.
- Общий чат + личные сообщения (ЛС) между пользователями.
- Поиск пользователя по имени для открытия ЛС.
- Отправка и получение текстовых сообщений.
- Пересылка сообщений между чатами (включая файлы) с пометкой источника.
- Ответы на сообщения (reply) в чате.
- Редактирование и удаление своих сообщений (с синхронизацией для всех клиентов).
- Реакции на сообщения (toggle).
- Упоминания пользователей в тексте через `@Имя Фамилия`.
- Автоподсказки пользователей при вводе `@` в поле сообщения.
- Квитанции доставки и прочтения сообщений.
- Отправка файлов с подписью (комментарием к файлу).
- Запись и отправка голосовых сообщений из приложения (WAV).
- Встроенное проигрывание голосовых сообщений прямо в чате (play/pause/перемотка).
- Скорость воспроизведения голосовых: `1x / 1.5x / 2x`.
- Поиск по истории сообщений внутри текущего чата.
- Закреп сообщения в чате + избранные сообщения.
- Скачивание отправленных файлов из чата.
- Отображение автора каждого сообщения.
- Шифрование текста/подписей файлов (AES-GCM-256): общий ключ управляется сервером и выдается клиенту после авторизации (вручную не вводится).
- Mesh fallback (UDP multicast) теперь отключен по умолчанию из-за небезопасного plaintext-канала. Можно включить через `NETMAX_ENABLE_MESH_FALLBACK=true`.
- Автоподписки на список серверов: если сервер недоступен > 1 минуты, клиент обновляет подписки, проверяет задержку (`/health`) и переключается на самый быстрый endpoint.
- Автоподписки на прокси (native): `http/https/socks5` список с автопереключением на самый быстрый прокси при потере связи.
- Системные уведомления (внутри приложения и в ОС); в Web — через системные уведомления браузера.
- Нереляционное хранилище сообщений/чатов/вложений: MongoDB (`messages`, `chats`, `files` + GridFS bucket `netmax_files`).
- Автомиграция истории сообщений из legacy JSON (`backend/config/messages_history.json`) в MongoDB при первом запуске.
- Защита от SQL-инъекций: пользовательские данные хранятся в SQLite через prepared statements.
- Базовая защита от XSS: санитизация отображаемого текста, безопасные заголовки ответов API/файлов и запрет inline-рендера небезопасных вложений.
- Сохранение сессии/пароля локально на клиенте.
- Проверка обновлений приложения и переход по ссылке на установку новой сборки.
- Поддержка платформ: Android, iOS, macOS, Windows, Linux, Web.

## Где скачать сборки
Сборки публикуются автоматически через GitHub Actions.

1. Откройте вкладку **Releases** в репозитории.
2. Выберите последний релиз вида `vX.Y.Z-build.N`.
3. Скачайте нужный файл:

- `netmax-android.apk` — Android
- `netmax-ios.ipa` — iOS
- `netmax-macos.app.zip` — macOS
- `netmax-windows-x64.zip` — Windows
- `netmax-linux-x64.tar.gz` — Linux
- `netmax-web.zip` — Web

Альтернатива: **GitHub → Actions → нужный run → Artifacts**.

## Как установить сборку

### Android
1. Скачайте `netmax-android.apk`.
2. На устройстве разрешите установку из неизвестных источников.
3. Установите APK.

### iOS
1. Скачайте `netmax-ios.ipa`.
2. Установите через Sideloadly/AltStore/Xcode.
3. На устройстве откройте `Settings → General → VPN & Device Management` и доверяйте сертификату.

### macOS
1. Скачайте `netmax-macos.app.zip`.
2. Распакуйте архив.
3. Переместите `.app` в `Applications` и запустите.
4. Если macOS блокирует запуск:
   - `xattr -dr com.apple.quarantine /Applications/netmax_messenger.app`

### Windows
1. Скачайте `netmax-windows-x64.zip`.
2. Распакуйте архив в папку.
3. Запустите `netmax_messenger.exe`.

### Linux
1. Скачайте `netmax-linux-x64.tar.gz`.
2. Распакуйте:
   - `tar -xzf netmax-linux-x64.tar.gz`
3. Запустите:
   - `./bundle/netmax_messenger`

### Web
1. Скачайте `netmax-web.zip`.
2. Распакуйте содержимое в директорию вашего веб-сервера (например, `/var/www/netmax-web`).
3. Настройте reverse proxy на backend (WebSocket `/ws`).

## Быстрый запуск backend
```bash
cd backend
dart pub get
dart run bin/server.dart
```

По умолчанию backend слушает только локальный интерфейс `127.0.0.1:8080`.
Чтобы открыть наружу (не рекомендуется без reverse proxy/TLS), задайте `NETMAX_BIND_HOST=0.0.0.0`.

## Подключение клиента к серверу
Для Web клиент автоматически берет текущий хост/IP из адресной строки браузера
и подключается к backend по `/ws` на этом же хосте:
- если страница открыта по `https://155.212.141.80/`, клиент использует `wss://155.212.141.80/ws`;
- если страница открыта по `http://127.0.0.1:8080/`, клиент использует `ws://127.0.0.1:8080/ws`.

Допустимые форматы:
- `wss://<host>/ws` (рекомендуется для продакшена)
- `ws://localhost:8080/ws` (только локальная разработка)

В UI поле URL сервера скрыто. Для non-web сборок fallback по умолчанию: `wss://155.212.141.80/ws`.

Для релизных native-сборок (Android/iOS/macOS/Windows/Linux) адрес можно зафиксировать при сборке:
```bash
flutter build apk --release --dart-define=NETMAX_SERVER_URL=wss://155.212.141.80/ws
```

В CI (`.github/workflows/build-all-platforms.yml`) это уже учитывается:
- если задан repo variable `NETMAX_SERVER_URL`, он подставляется в сборки;
- если не задан, используется `wss://155.212.141.80/ws`.

Опционально можно добавить источники подписок (HTTP/HTTPS, одна ссылка на строку) в окне подключения.  
Ключ шифрования теперь управляется сервером и передается клиенту после авторизации (пользователь вручную ключ не вводит).  
Задается на сервере через переменную `NETMAX_E2EE_SHARED_KEY`.
Если переменная не задана, backend создает и хранит стабильный ключ в `backend/config/e2ee_shared_key.txt`.
Лимит истории сообщений на backend настраивается через `NETMAX_HISTORY_LIMIT` (по умолчанию `10000`).
URI MongoDB задается через `NETMAX_MONGO_URI` (по умолчанию `mongodb://127.0.0.1:27017/netmax`).
Для регистрации нового аккаунта по `телефон + email` клиент вызывает `POST /auth/email/request-code` и затем подключается в WebSocket с `authMethod=phone` (payload: `phone`, `email`, `code`, `register=true`, `password`).  
Для существующих аккаунтов используйте обычный вход `логин + пароль`.
Dev-режим возврата OTP-кода в API управляется `NETMAX_EMAIL_AUTH_RETURN_DEV_CODE` (`true` по умолчанию; в проде рекомендуется `false`).
Для реальной отправки писем настройте SMTP:
`NETMAX_SMTP_HOST`, `NETMAX_SMTP_PORT`, `NETMAX_SMTP_FROM`, опционально `NETMAX_SMTP_USERNAME`, `NETMAX_SMTP_PASSWORD`, `NETMAX_SMTP_TLS`.
Хост bind для backend задается через `NETMAX_BIND_HOST` (по умолчанию `127.0.0.1`).
Формат server-подписки: JSON (`servers`/`endpoints`) или текстовый список `ws://`/`wss://` адресов.  
Формат proxy-подписки (native): JSON (`proxies`) или текстовый список `http://...`, `https://...`, `socks5://...`.  
Web-версия не настраивает custom proxy внутри приложения и использует сетевые настройки браузера/ОС.

## HTTPS/WSS через Nginx (155.212.141.80)
Готовый конфиг:
- `deploy/nginx/netmax.conf`
- Полный deploy-скрипт (systemd + nginx + self-signed): `deploy/deploy-from-root.sh`

Что делает конфиг:
- редирект `80 -> 443`;
- `wss://155.212.141.80/ws` проксируется на backend `127.0.0.1:8080/ws`;
- API/файлы (`/auth/*`, `/health`, `/files/*`, и т.д.) проксируются на тот же backend;
- при наличии web-сборки отдаёт frontend из `/var/www/netmax-web`.

Пример установки (self-signed):
```bash
sudo /bin/bash ./deploy/nginx/generate-self-signed.sh

sudo cp deploy/nginx/netmax.conf /etc/nginx/conf.d/netmax.conf
sudo nginx -t
sudo systemctl reload nginx
```

Полный автоматический деплой из `/root`:
```bash
cd /root
bash /root/NetMax/deploy/deploy-from-root.sh
```

Для слабого сервера (2 CPU / 2 GB) это рекомендуемый режим: web-сборка в скрипте отключена по умолчанию (`BUILD_WEB=false`).
Если нужно собрать web прямо на сервере:
```bash
cd /root
BUILD_WEB=true bash /root/NetMax/deploy/deploy-from-root.sh
```

Скрипт:
- проверяет проект в `/root/NetMax`;
- ставит backend зависимости;
- собирает web только при `BUILD_WEB=true` (если установлен Flutter);
- генерирует self-signed сертификат только если его нет;
- разворачивает Nginx-конфиг;
- создаёт и запускает `netmax-backend.service`;
- включает `nginx.service`;
- пытается запустить MongoDB (`mongod.service` или `mongodb.service`), если найден;
- выполняет health-check.

Если нужен другой IP:
```bash
sudo CERT_IP=<ваш_ip> /bin/bash ./deploy/nginx/generate-self-signed.sh
```

Используемые файлы:
- `deploy/nginx/generate-self-signed.sh`
- `deploy/nginx/openssl-selfsigned.cnf`

Backend лучше запускать локально на сервере и не публиковать порт 8080 наружу (доступ только через Nginx/443).

Важно для self-signed:
- Клиенты и браузеры должны доверять вашему сертификату, иначе `wss://` будет отклонён.
- Для Web нужно открыть `https://155.212.141.80` в браузере и вручную подтвердить сертификат, либо установить сертификат в доверенные.

## Требования по железу
Минимум для тестового/малого контура (до ~50 одновременно подключенных пользователей):
- CPU: 2 vCPU
- RAM: 2 GB (лучше 4 GB)
- Диск: 20 GB SSD

Рекомендовано для рабочего контура (до ~200 одновременно подключенных пользователей):
- CPU: 4 vCPU
- RAM: 8 GB
- Диск: 40+ GB SSD (с учетом вложений и MongoDB volume)

## Радиус Mesh
Текущий Mesh fallback использует локальную сеть (UDP multicast), а не Bluetooth.
- В одной Wi‑Fi сети радиус обычно равен покрытию точки доступа: примерно 20–50 м в помещении, до ~100 м при прямой видимости.
- Между разными подсетями/гостевыми VLAN multicast может не проходить.

## CI/CD
Workflow: `.github/workflows/build-all-platforms.yml`

На каждый `push` в `main` выполняется:
- анализ и тесты;
- сборка Android, iOS, macOS, Windows, Linux, Web;
- публикация артефактов и формирование GitHub Release.

## License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).
See the [LICENSE](./LICENSE) file for details.
