# NetMax Messenger

Кроссплатформенный корпоративный мессенджер на Flutter с веб-версией и backend на Dart.

## Что уже реализовано
- Авторизация по имени и паролю (список пользователей хранится в `backend/config/authorized_users.json`).
- Общий чат + личные сообщения (ЛС) между пользователями.
- Поиск пользователя по имени для открытия ЛС.
- Отправка и получение текстовых сообщений.
- Ответы на сообщения (reply) в чате.
- Отправка файлов с подписью (комментарием к файлу).
- Скачивание отправленных файлов из чата.
- Отображение автора каждого сообщения.
- Системные уведомления (внутри приложения и в ОС).
- Сохранение истории сообщений на backend в JSON с восстановлением после рестарта.
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

По умолчанию backend стартует на `0.0.0.0:8080`.

## Подключение клиента к серверу
В приложении укажите адрес сервера в формате:
- `ws://<host>:8080/ws` (без TLS)
- `wss://<domain>/ws` (через HTTPS/TLS)

## CI/CD
Workflow: `.github/workflows/build-all-platforms.yml`

На каждый `push` в `main` выполняется:
- анализ и тесты;
- сборка Android, iOS, macOS, Windows, Linux, Web;
- публикация артефактов и формирование GitHub Release.
