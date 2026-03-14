# NetMax Messenger

Кроссплатформенный Flutter-мессенджер для:
- Android
- iOS
- macOS
- Windows
- Linux
- Web (сайт)

## Что реализовано
- Чат через интернет (WebSocket-сервер).
- Авторизация пользователей через JSON whitelist (без БД).
- Отправка и получение текстовых сообщений между разными устройствами.
- Отправка файлов разных форматов (файл сохраняется на сервере и приходит всем участникам).
- Отправка сообщений по времени (расписание в JSON на сервере).
- Уведомления о действиях пользователя:
  - подключился/отключился;
  - печатает;
  - новые сообщения и файлы.
- Веб-версия (сайт) с тем же функционалом чата/файлов/уведомлений/настроек.
- Светлая тема (синий акцент) и тёмная тема (чёрные оттенки + синий), переключение в приложении.
- Сохранение темы и параметров подключения между запусками.

## Архитектура
- Клиент: Flutter-приложение (`/lib`).
- Сервер: Dart backend (`/backend`) на WebSocket + раздача загруженных файлов.
- В системе одна общая группа (single-room) для всей команды. Подключения к комнатам отсутствуют.
- В приложении есть вкладка `Настройки` с расписанием автоотправки сообщений.

## Авторизация (JSON, без БД)
- Источник авторизации: `/Users/cukw/NetMax/backend/config/authorized_users.json`
- Формат: список `allowedUsers` (имена захардкожены в JSON).
- Вход в чат разрешен только пользователям из этого списка.
- Если имя не в whitelist или пользователь с этим именем уже онлайн, сервер отклоняет подключение.

## Запуск backend сервера
```bash
cd backend
dart pub get
dart run bin/server.dart
```

По умолчанию сервер слушает `0.0.0.0:8080`.
- WebSocket endpoint: `ws://<HOST>:8080/ws`
- Файлы: `http://<HOST>:8080/files/<filename>`
- Health-check: `http://<HOST>:8080/health`
- Список авторизованных пользователей: `http://<HOST>:8080/authorized-users`
- Расписания автоотправки: `http://<HOST>:8080/scheduled-messages`
- Манифест обновлений: `http://<HOST>:8080/update-manifest`

Если запускаете backend на другом порту, меняйте URL подключения по формуле:
- `ws://<HOST>:<PORT>/ws`

## Отправка сообщения по времени
Реализовано через JSON на сервере:
- Файл: `/Users/cukw/NetMax/backend/config/scheduled_messages.json`
- В приложении: вкладка `Настройки` -> флаг `Отправлять сообщение по времени`.
- После включения появляются поля:
  - `Текст сообщения`
  - `Время отправки` (формат `HH:mm`)
- При сохранении сервер проверяет, кто именно отправитель (по авторизованному имени текущего WebSocket-подключения), и не дает задать расписание за другого пользователя.
- В заданное время сервер отправляет сообщение в общий чат автоматически.
- Такие сообщения отмечаются как `по времени`.

## Минимальные требования к серверу
Минимум (до 30 пользователей, одна общая комната, умеренная активность):
- CPU: 1 vCPU
- RAM: 1 GB
- Диск: 10 GB SSD
- Сеть: от 10 Mbps, публичный IP или домен
- ОС: Linux x64 (Ubuntu 22.04 LTS или совместимая)
- ПО: Dart SDK 3.10+ (для запуска `dart run`)

Рекомендуется для стабильной работы и файлов:
- CPU: 2 vCPU
- RAM: 2 GB+
- Диск: 20 GB+ SSD
- Reverse proxy с TLS (Nginx/Caddy) для `wss://`
- Регулярные бэкапы `backend/storage` и `backend/config`

## Nginx в backend
- В самом backend (`/backend`) `nginx` не встроен и не запускается.
- Backend реализован на Dart `shelf` и слушает порт напрямую (`8080` по умолчанию).
- `nginx` ставится отдельно только как reverse-proxy (опционально, обычно для TLS и `wss://`).

Минимальный пример reverse-proxy для WebSocket:
```nginx
server {
    listen 443 ssl;
    server_name chat.example.com;

    location /ws {
        proxy_pass http://127.0.0.1:8080/ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
}
```

## Подключение клиентов (точно для всех сборок)
### 1) Определите правильный URL
- Без reverse-proxy и TLS: `ws://<PUBLIC_IP>:8080/ws`
- С доменом и TLS через Nginx/Caddy: `wss://<DOMAIN>/ws`
- Локально на самой серверной машине: `ws://127.0.0.1:8080/ws`

Важно:
- Путь должен быть именно `/ws`.
- Порт должен совпадать с портом запуска backend (`PORT`, если переопределяли).
- Если ранее в клиенте был сохранен старый адрес (например `:8000`), замените его вручную в настройках подключения.

### 2) Что указать в приложении
1. Откройте **Настройки подключения** (иконка облака).
2. В поле `Server URL` введите один из форматов выше.
3. В поле пользователя укажите имя строго из `backend/config/authorized_users.json`.
4. Нажмите подключение и дождитесь статуса `Подключено`.

### 3) Особенности по платформам
- Android: поддерживаются `ws://` и `wss://`.
- iOS: поддерживаются `ws://` и `wss://` (в проекте добавлены настройки ATS для небезопасного трафика).
- macOS: поддерживаются `ws://` и `wss://` (включены network entitlements для клиента).
- Windows: поддерживаются `ws://` и `wss://`.
- Linux: поддерживаются `ws://` и `wss://`.
- Web: если сайт открыт по `https://`, подключаться нужно только через `wss://`. `ws://` в этом случае браузер блокирует как mixed content.

### 4) Проверка сети перед подключением
1. Убедитесь, что backend запущен и пишет `NetMax backend is running on ...`.
2. Откройте inbound `8080/tcp` в firewall/security group (или `443`, если используете Nginx с TLS).
3. Проверьте доступ снаружи:
```bash
curl http://<PUBLIC_IP>:8080/health
```

## Системные уведомления (OS notifications)
Уведомления теперь приходят не только внутри приложения, но и в систему (Android/iOS/macOS/Windows/Linux):
- новое сообщение;
- новый файл;
- подключение/отключение пользователей;
- сетевые ошибки;
- доступность новой версии приложения.

Примечания:
- На Android 13+ требуется разрешение на уведомления (`POST_NOTIFICATIONS`), приложение запрашивает его при старте.
- Событие `печатает...` тоже может приходить в систему, но ограничено по частоте, чтобы не спамить.

## Онлайн-обновления
Приложение поддерживает online update через серверный манифест:
- Клиент автоматически проверяет `http(s)://<HOST>:8080/update-manifest` при запуске и далее каждые 15 минут.
- Если найдена новая версия, появляется системное уведомление и баннер в приложении с кнопкой `Установить`.
- Есть ручная проверка через иконку обновления в верхней панели.
- Если ваша CI/CD (workflow/`overflow`) выкладывает новую сборку и обновляет `update_manifest.json`, все клиенты увидят новое обновление автоматически.

Источник данных:
- файл `/Users/cukw/NetMax/backend/config/update_manifest.json`

Формат:
```json
{
  "version": "1.0.1",
  "build": 2,
  "notes": "Release notes",
  "downloads": {
    "android": "https://...",
    "ios": "https://...",
    "macos": "https://...",
    "windows": "https://...",
    "linux": "https://...",
    "web": "https://..."
  }
}
```

Важно по автообновлению:
- Обновление определяется автоматически, но установка зависит от платформы и политики ОС.
- Android/macOS/Windows/Linux: открывается ссылка на новую сборку для установки.
- iOS: без подписи и распространения через App Store/TestFlight полностью автоматическая установка невозможна.
- Для production лучше хранить файлы сборок по постоянным URL (GitHub Releases/S3/другое), а в `update_manifest.json` менять только `version/build/links`.
- Для Web-фронтенда обычно используется деплой `build/web` на статический хостинг (Nginx, Cloudflare Pages, GitHub Pages, S3).

## Установка готовых сборок (без запуска исходного кода)
1. Откройте `GitHub -> Actions -> Build All Platforms -> нужный run -> Artifacts`.
2. Скачайте артефакт для вашей платформы.
3. Установите приложение по инструкции ниже.

### Android (`android-apk`)
1. Скачайте `app-release.apk` из артефакта `android-apk`.
2. Передайте файл на устройство.
3. Включите разрешение на установку из неизвестных источников (если требуется).
4. Установите APK вручную или через ADB:
```bash
adb install -r app-release.apk
```

### iOS (`ios-app-unsigned`)
1. Скачайте `netmax-ios.app.zip` из артефакта `ios-app-unsigned`.
2. Распакуйте архив на macOS.
3. Подпишите приложение своим сертификатом в Xcode и установите на устройство.

Важно: артефакт iOS собирается без подписи (`--no-codesign`), поэтому прямой установки без подписи нет.

### macOS (`macos-app`)
1. Скачайте `netmax-macos.app.zip` из артефакта `macos-app`.
2. Распакуйте архив.
3. Переместите `netmax_messenger.app` в `Applications`.
4. При первом запуске, если macOS блокирует приложение, откройте его через контекстное меню `Open`.

### Windows (`windows-bundle`)
1. Скачайте `netmax-windows-x64.zip` из артефакта `windows-bundle`.
2. Распакуйте архив в удобную папку.
3. Запустите `netmax_messenger.exe` из распакованной директории.

### Linux (`linux-bundle`)
1. Скачайте `netmax-linux-x64.tar.gz` из артефакта `linux-bundle`.
2. Распакуйте архив:
```bash
tar -xzf netmax-linux-x64.tar.gz
```
3. Запустите приложение:
```bash
chmod +x bundle/netmax_messenger
./bundle/netmax_messenger
```

### Web (`web-bundle`)
1. Скачайте `netmax-web.zip` из артефакта `web-bundle`.
2. Распакуйте архив.
3. Разместите содержимое в любом статическом хостинге (Nginx/Apache/S3/Pages).
4. Откройте сайт в браузере и укажите `ws://`/`wss://` адрес вашего backend.

## Запуск из исходного кода (для разработчиков)
```bash
flutter pub get
flutter run -d macos
```

Примеры для других платформ:
```bash
flutter run -d android
flutter run -d ios
flutter run -d windows
flutter run -d linux
flutter run -d chrome
```

## Проверка
```bash
flutter analyze
flutter test
```

## CI/CD (GitHub Actions)
Для проекта настроен workflow:
- `.github/workflows/build-all-platforms.yml`

Сборки запускаются:
- при каждом `push` в ветку `main`;
- вручную через `workflow_dispatch`.

Workflow выполняет:
- `quality` stage (`flutter pub get`, `flutter analyze`, `flutter test`);
- релизные сборки и публикацию артефактов для Android, iOS, macOS, Windows, Linux, Web;
- создание GitHub Release с файлами сборок;
- автоматическое обновление `backend/config/update_manifest.json` ссылками на свежий Release.

Артефакты в каждом запуске:
- `android-apk`
- `ios-app-unsigned`
- `macos-app`
- `windows-bundle`
- `linux-bundle`
- `web-bundle`

Важно:
- iOS в CI собирается как unsigned (`flutter build ios --release --no-codesign`).
- IPA-файл не формируется без сертификатов и provisioning profile.
- Build number в CI берется из `github.run_number`, поэтому клиенты получают корректный сигнал о новой сборке.

Где забирать артефакты:
- `GitHub -> Actions -> нужный workflow run -> Artifacts`.
