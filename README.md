# NetMax Messenger

Кроссплатформенный Flutter-мессенджер для:
- Android
- iOS
- macOS
- Windows
- Linux

## Что реализовано
- Отправка и получение текстовых сообщений.
- Отправка файлов разных форматов через системный файловый диалог.
- Уведомления о действиях пользователя:
  - онлайн/оффлайн;
  - печатает;
  - новые сообщения и файлы.
- Светлая тема (синий акцент) и тёмная тема (чёрные оттенки + синий), переключение в приложении.
- Сохранение выбранной темы между запусками.

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
- релизные сборки и публикацию артефактов для Android, iOS, macOS, Windows, Linux.

Артефакты в каждом запуске:
- `android-apk`
- `ios-app-unsigned`
- `macos-app`
- `windows-bundle`
- `linux-bundle`

Важно:
- iOS в CI собирается как unsigned (`flutter build ios --release --no-codesign`).
- IPA-файл не формируется без сертификатов и provisioning profile.

Где забирать артефакты:
- `GitHub -> Actions -> нужный workflow run -> Artifacts`.
