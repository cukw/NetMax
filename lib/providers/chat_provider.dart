import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_notification.dart';
import '../models/chat_message.dart';
import '../models/chat_user.dart';
import '../services/system_notification_service.dart';

enum ChatConnectionStatus { disconnected, connecting, connected }

class ChatProvider extends ChangeNotifier {
  ChatProvider() {
    _bootstrap();
  }

  static const String _themeModeKey = 'theme_mode';
  static const String _serverUrlKey = 'server_url';
  static const String _userNameKey = 'user_name';
  static const String _userIdKey = 'user_id';

  static const String _defaultServerUrl = 'ws://localhost:8080/ws';
  static const Duration _updateCheckInterval = Duration(minutes: 15);

  final List<ChatMessage> _messages = <ChatMessage>[];
  final List<AppNotification> _notifications = <AppNotification>[];
  final Set<String> _messageIds = <String>{};
  final Map<String, String> _onlineUsers = <String, String>{};
  final Map<String, String> _typingUsers = <String, String>{};
  final Random _random = Random();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _typingStopTimer;
  Timer? _updateCheckTimer;

  ThemeMode _themeMode = ThemeMode.light;
  ChatConnectionStatus _connectionStatus = ChatConnectionStatus.disconnected;

  String _serverUrl = _defaultServerUrl;
  String _userName = '';
  String _userId = '';

  String? _lastError;
  bool _isPickingFile = false;
  bool _isMeTyping = false;
  bool _disposed = false;
  bool _isCheckingUpdates = false;
  bool _isUpdateAvailable = false;
  bool _isSavingScheduledConfig = false;

  String _appVersion = '0.0.0';
  int _appBuild = 0;
  String? _latestVersion;
  int? _latestBuild;
  String? _updateNotes;
  Uri? _updateDownloadUri;
  String? _updateError;
  DateTime? _lastUpdateCheckAt;

  bool _scheduledEnabled = false;
  String _scheduledText = '';
  String _scheduledTime = '09:00';
  int _scheduledTimezoneOffsetMinutes = 0;
  String? _scheduledLastSentDate;
  DateTime? _scheduledUpdatedAt;
  String? _scheduledConfigError;

  DateTime _lastTypingSystemNotificationAt =
      DateTime.fromMillisecondsSinceEpoch(0);

  ThemeMode get themeMode => _themeMode;
  ChatConnectionStatus get connectionStatus => _connectionStatus;
  bool get isConnected => _connectionStatus == ChatConnectionStatus.connected;

  String get serverUrl => _serverUrl;
  String get userName => _userName;
  String get userId => _userId;
  String? get lastError => _lastError;

  bool get isPickingFile => _isPickingFile;
  int get onlineUsersCount => _onlineUsers.length + (isConnected ? 1 : 0);
  List<String> get typingUsers => _typingUsers.values.toList(growable: false);
  bool get isCheckingUpdates => _isCheckingUpdates;
  bool get isUpdateAvailable => _isUpdateAvailable;
  bool get isSavingScheduledConfig => _isSavingScheduledConfig;
  String get currentVersionLabel => '$_appVersion+$_appBuild';
  String? get latestVersion => _latestVersion;
  int? get latestBuild => _latestBuild;
  String? get updateNotes => _updateNotes;
  String? get updateDownloadUrl => _updateDownloadUri?.toString();
  String? get updateError => _updateError;
  DateTime? get lastUpdateCheckAt => _lastUpdateCheckAt;

  bool get scheduledEnabled => _scheduledEnabled;
  String get scheduledText => _scheduledText;
  String get scheduledTime => _scheduledTime;
  int get scheduledTimezoneOffsetMinutes => _scheduledTimezoneOffsetMinutes;
  String? get scheduledLastSentDate => _scheduledLastSentDate;
  DateTime? get scheduledUpdatedAt => _scheduledUpdatedAt;
  String? get scheduledConfigError => _scheduledConfigError;

  ChatUser get me => ChatUser(id: _userId, name: _userName, isMe: true);

  int get notificationCount => _notifications.length;
  AppNotification? get latestNotification =>
      _notifications.isEmpty ? null : _notifications.last;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  List<AppNotification> get notifications =>
      List<AppNotification>.unmodifiable(_notifications.reversed);

  String get connectionStatusLine {
    if (_connectionStatus == ChatConnectionStatus.connecting) {
      return 'Авторизация на сервере...';
    }

    if (_connectionStatus == ChatConnectionStatus.disconnected) {
      return 'Не подключено';
    }

    if (typingUsers.isNotEmpty) {
      return '${typingUsers.join(', ')} печатает...';
    }

    return 'Авторизован: $_userName • В сети: $onlineUsersCount';
  }

  Future<void> _bootstrap() async {
    await _loadPreferences();
    await _loadAppInfo();
    if (_disposed) {
      return;
    }

    _messages.add(
      ChatMessage.system(
        id: _nextId(),
        createdAt: DateTime.now(),
        text: _userName.isEmpty
            ? 'Выберите имя из списка авторизованных пользователей и подключитесь к серверу.'
            : 'NetMax Messenger готов. Выполняется подключение к серверу...',
      ),
    );
    _safeNotify();

    _startUpdateChecks();
    await checkForUpdates();

    if (_userName.isNotEmpty) {
      await connect();
    }
  }

  Future<void> _loadAppInfo() async {
    try {
      final package = await PackageInfo.fromPlatform();
      final version = package.version.trim();
      _appVersion = version.isEmpty ? '0.0.0' : version;
      _appBuild = int.tryParse(package.buildNumber.trim()) ?? 0;
    } catch (_) {
      _appVersion = '0.0.0';
      _appBuild = 0;
    }
  }

  void _startUpdateChecks() {
    _updateCheckTimer?.cancel();
    _updateCheckTimer = Timer.periodic(_updateCheckInterval, (_) {
      unawaited(checkForUpdates());
    });
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    final rawTheme = prefs.getString(_themeModeKey);
    _themeMode = switch (rawTheme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    _serverUrl = prefs.getString(_serverUrlKey) ?? _defaultServerUrl;
    _userName = (prefs.getString(_userNameKey) ?? '').trim();

    final storedUserId = (prefs.getString(_userIdKey) ?? '').trim();
    _userId = storedUserId.isEmpty ? _nextId() : storedUserId;

    await prefs.setString(_userIdKey, _userId);
    await prefs.setString(_serverUrlKey, _serverUrl);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) {
      return;
    }

    _themeMode = mode;
    _safeNotify();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.name);
  }

  Future<void> applyConnectionSettings({
    required String serverUrl,
    required String userName,
  }) async {
    final normalizedServerUrl = _normalizeServerUrl(serverUrl);
    final normalizedUserName = userName.trim();

    if (normalizedUserName.isEmpty) {
      throw const FormatException(
        'Введите имя пользователя из списка 30 авторизованных.',
      );
    }

    _serverUrl = normalizedServerUrl;
    _userName = normalizedUserName;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, _serverUrl);
    await prefs.setString(_userNameKey, _userName);

    await connect(force: true);
    await checkForUpdates();
  }

  Future<void> connect({bool force = false}) async {
    if (_disposed) {
      return;
    }

    if (_connectionStatus == ChatConnectionStatus.connecting) {
      return;
    }

    if (_connectionStatus == ChatConnectionStatus.connected && !force) {
      return;
    }

    if (_userName.trim().isEmpty) {
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Авторизация',
        description: 'Введите имя пользователя из whitelist.',
        showInSystem: false,
      );
      _safeNotify();
      return;
    }

    await _closeSocket(sendTypingOff: false, notify: false);

    _setConnectionStatus(ChatConnectionStatus.connecting);
    _lastError = null;
    _safeNotify();

    try {
      final uri = Uri.parse(_serverUrl);
      _channel = WebSocketChannel.connect(uri);

      _channelSubscription = _channel!.stream.listen(
        _onSocketData,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: true,
      );

      _sendEnvelope(
        type: 'join',
        payload: {'userId': _userId, 'userName': _userName},
      );
    } catch (error) {
      _setConnectionStatus(ChatConnectionStatus.disconnected);
      _lastError = error.toString();
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Ошибка подключения',
        description: 'Не удалось подключиться к серверу.',
        showInSystem: true,
      );
      _safeNotify();
    }
  }

  Future<void> disconnect() async {
    await _closeSocket(sendTypingOff: true, notify: true);
  }

  Future<void> _closeSocket({
    required bool sendTypingOff,
    required bool notify,
  }) async {
    if (sendTypingOff && _isMeTyping) {
      _sendTyping(isTyping: false);
    }

    _typingStopTimer?.cancel();
    _typingStopTimer = null;

    _typingUsers.clear();
    _onlineUsers.clear();
    _isSavingScheduledConfig = false;

    await _channelSubscription?.cancel();
    _channelSubscription = null;

    await _channel?.sink.close();
    _channel = null;

    _setConnectionStatus(ChatConnectionStatus.disconnected);

    if (notify) {
      _safeNotify();
    }
  }

  void _onSocketData(dynamic rawData) {
    if (rawData is! String) {
      return;
    }

    try {
      final decoded = jsonDecode(rawData);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final type = decoded['type']?.toString() ?? '';
      final payload = _asMap(decoded['payload']);

      switch (type) {
        case 'auth_ok':
          _handleAuthOk(payload);
          break;
        case 'snapshot':
          _handleSnapshot(payload);
          break;
        case 'presence':
          _handlePresence(payload);
          break;
        case 'typing':
          _handleTyping(payload);
          break;
        case 'message':
          _handleMessage(payload);
          break;
        case 'scheduled_config':
          _handleScheduledConfig(payload);
          break;
        case 'error':
          _handleServerError(payload);
          break;
        default:
          break;
      }
    } catch (_) {
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Ошибка',
        description: 'Получены данные в неверном формате.',
        showInSystem: true,
      );
      _safeNotify();
    }
  }

  void _handleAuthOk(Map<String, dynamic> payload) {
    final authorizedUserId = (payload['userId']?.toString() ?? '').trim();
    final authorizedUserName = (payload['userName']?.toString() ?? '').trim();

    if (authorizedUserId.isNotEmpty) {
      _userId = authorizedUserId;
    }
    if (authorizedUserName.isNotEmpty) {
      _userName = authorizedUserName;
    }

    _setConnectionStatus(ChatConnectionStatus.connected);
    _pushNotification(
      kind: NotificationKind.system,
      title: 'Авторизация успешна',
      description: 'Пользователь: $_userName',
      showInSystem: false,
    );

    _sendEnvelope(type: 'scheduled_config_get', payload: <String, dynamic>{});

    SharedPreferences.getInstance().then((prefs) async {
      await prefs.setString(_userIdKey, _userId);
      await prefs.setString(_userNameKey, _userName);
    });

    _safeNotify();
  }

  void _handleScheduledConfig(Map<String, dynamic> payload) {
    _scheduledEnabled = payload['enabled'] == true;
    _scheduledText = (payload['text']?.toString() ?? '').trim();

    final normalizedTime = _normalizeScheduleTime(
      payload['time']?.toString() ?? '09:00',
    );
    _scheduledTime = normalizedTime ?? '09:00';

    final timezone = _toInt(payload['timezoneOffsetMinutes']);
    _scheduledTimezoneOffsetMinutes = timezone ?? 0;

    final lastSent = (payload['lastSentDate']?.toString() ?? '').trim();
    _scheduledLastSentDate = lastSent.isEmpty ? null : lastSent;

    final updatedAtRaw = (payload['updatedAt']?.toString() ?? '').trim();
    _scheduledUpdatedAt = DateTime.tryParse(updatedAtRaw)?.toLocal();

    _scheduledConfigError = null;
    _isSavingScheduledConfig = false;
    _safeNotify();
  }

  void _onSocketError(Object error) {
    _lastError = error.toString();
    _setConnectionStatus(ChatConnectionStatus.disconnected);
    _isSavingScheduledConfig = false;
    _pushNotification(
      kind: NotificationKind.system,
      title: 'Соединение потеряно',
      description: 'Ошибка: $_lastError',
      showInSystem: true,
    );
    _safeNotify();
  }

  void _onSocketDone() {
    _typingUsers.clear();
    _onlineUsers.clear();
    _isSavingScheduledConfig = false;

    if (_connectionStatus != ChatConnectionStatus.disconnected) {
      _setConnectionStatus(ChatConnectionStatus.disconnected);
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Отключено',
        description: 'Соединение с сервером закрыто.',
        showInSystem: true,
      );
      _safeNotify();
    }
  }

  void _handleSnapshot(Map<String, dynamic> payload) {
    final onlineUsersRaw = payload['onlineUsers'];
    final messagesRaw = payload['messages'];

    _onlineUsers.clear();
    if (onlineUsersRaw is List) {
      for (final user in onlineUsersRaw) {
        final map = _asMap(user);
        final id = map['id']?.toString() ?? '';
        final name = map['name']?.toString() ?? '';
        if (id.isEmpty || id == _userId) {
          continue;
        }
        _onlineUsers[id] = name;
      }
    }

    _messages.clear();
    _messageIds.clear();

    if (messagesRaw is List) {
      for (final item in messagesRaw) {
        final map = _asMap(item);
        final message = ChatMessage.fromJson(map);
        if (message.id.isEmpty || _messageIds.contains(message.id)) {
          continue;
        }
        _messageIds.add(message.id);
        _messages.add(message);
      }
    }

    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    if (_messages.isEmpty) {
      _messages.add(
        ChatMessage.system(
          id: _nextId(),
          createdAt: DateTime.now(),
          text: 'Подключено к общей группе.',
        ),
      );
    }

    _safeNotify();
  }

  void _handlePresence(Map<String, dynamic> payload) {
    final userId = payload['userId']?.toString() ?? '';
    final userName = payload['userName']?.toString() ?? 'Unknown';
    final isOnline = payload['isOnline'] == true;

    if (userId.isEmpty || userId == _userId) {
      return;
    }

    if (isOnline) {
      _onlineUsers[userId] = userName;
    } else {
      _onlineUsers.remove(userId);
      _typingUsers.remove(userId);
    }

    _messages.add(
      ChatMessage.system(
        id: _nextId(),
        createdAt: DateTime.now(),
        text: isOnline ? '$userName в сети' : '$userName вышел из сети',
      ),
    );

    _pushNotification(
      kind: NotificationKind.presence,
      title: 'Статус пользователя',
      description: isOnline ? '$userName подключился' : '$userName отключился',
      showInSystem: true,
    );

    _safeNotify();
  }

  void _handleTyping(Map<String, dynamic> payload) {
    final userId = payload['userId']?.toString() ?? '';
    final userName = payload['userName']?.toString() ?? 'Unknown';
    final isTyping = payload['isTyping'] == true;

    if (userId.isEmpty || userId == _userId) {
      return;
    }

    if (isTyping) {
      _typingUsers[userId] = userName;
      _pushNotification(
        kind: NotificationKind.typing,
        title: 'Действие пользователя',
        description: '$userName печатает...',
        showInSystem: true,
      );
    } else {
      _typingUsers.remove(userId);
    }

    _safeNotify();
  }

  void _handleMessage(Map<String, dynamic> payload) {
    final message = ChatMessage.fromJson(payload);
    if (message.id.isEmpty || _messageIds.contains(message.id)) {
      return;
    }

    _messageIds.add(message.id);
    _messages.add(message);

    final isMineByName =
        message.senderName.trim().toLowerCase() == _userName.toLowerCase();

    if (!isMineByName && message.senderId != _userId) {
      _pushNotification(
        kind: message.type == MessageType.file
            ? NotificationKind.file
            : NotificationKind.message,
        title: message.type == MessageType.file
            ? 'Новый файл'
            : (message.isScheduled
                  ? 'Сообщение по времени'
                  : 'Новое сообщение'),
        description: message.type == MessageType.file
            ? '${message.senderName}: ${message.attachment?.name ?? 'Файл'}'
            : '${message.senderName}: ${message.text ?? ''}',
        showInSystem: true,
      );
    }

    _safeNotify();
  }

  void _handleServerError(Map<String, dynamic> payload) {
    final message = payload['message']?.toString() ?? 'Неизвестная ошибка.';
    _lastError = message;
    _scheduledConfigError = message;
    _isSavingScheduledConfig = false;

    final shouldDisconnect =
        _connectionStatus == ChatConnectionStatus.connecting ||
        message.toLowerCase().contains('авторизация');

    if (shouldDisconnect) {
      _typingUsers.clear();
      _onlineUsers.clear();
      _setConnectionStatus(ChatConnectionStatus.disconnected);

      _pushNotification(
        kind: NotificationKind.system,
        title: 'Ошибка сервера',
        description: message,
        showInSystem: true,
      );

      _channel?.sink.close();
      _channel = null;
      _safeNotify();
      return;
    }

    _pushNotification(
      kind: NotificationKind.system,
      title: 'Ошибка',
      description: message,
      showInSystem: false,
    );
    _safeNotify();
  }

  Future<String?> saveScheduledMessageConfig({
    required bool enabled,
    required String text,
    required String time,
  }) async {
    if (!isConnected) {
      return 'Подключитесь к серверу, чтобы сохранить расписание.';
    }

    final normalizedText = text.trim();
    final normalizedTime = _normalizeScheduleTime(time);

    if (enabled && normalizedText.isEmpty) {
      return 'Введите текст сообщения для отправки по времени.';
    }

    if (enabled && normalizedTime == null) {
      return 'Укажите корректное время в формате HH:mm.';
    }

    _scheduledEnabled = enabled;
    _scheduledText = normalizedText;
    _scheduledTime = normalizedTime ?? _scheduledTime;
    _scheduledTimezoneOffsetMinutes = DateTime.now().timeZoneOffset.inMinutes;
    _scheduledConfigError = null;
    _isSavingScheduledConfig = true;
    _safeNotify();

    _sendEnvelope(
      type: 'scheduled_config_set',
      payload: {
        'enabled': _scheduledEnabled,
        'text': _scheduledText,
        'time': _scheduledTime,
        'timezoneOffsetMinutes': _scheduledTimezoneOffsetMinutes,
      },
    );

    return null;
  }

  void sendText(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      return;
    }

    if (!isConnected) {
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Нет соединения',
        description: 'Подключитесь к серверу, чтобы отправить сообщение.',
        showInSystem: false,
      );
      _safeNotify();
      return;
    }

    _sendEnvelope(
      type: 'message',
      payload: {
        'id': _nextId(),
        'text': text,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      },
    );

    updateTypingStatus('');
  }

  Future<String?> pickAndSendFile() async {
    if (!isConnected) {
      return 'Нет подключения к серверу. Невозможно отправить файл.';
    }

    if (_isPickingFile) {
      return 'Выбор файла уже выполняется.';
    }

    _isPickingFile = true;
    _safeNotify();

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return null;
      }

      final picked = result.files.single;
      final bytes = _resolveBytes(picked);
      if (bytes == null || bytes.isEmpty) {
        return 'Не удалось прочитать файл.';
      }

      const maxFileSize = 20 * 1024 * 1024;
      if (bytes.length > maxFileSize) {
        return 'Файл слишком большой. Максимум 20 MB.';
      }

      final extension = p.extension(picked.name).replaceFirst('.', '');
      final safeExtension = extension.isEmpty
          ? 'FILE'
          : extension.toUpperCase();

      _sendEnvelope(
        type: 'file',
        payload: {
          'id': _nextId(),
          'name': picked.name,
          'extension': safeExtension,
          'sizeBytes': bytes.length,
          'contentBase64': base64Encode(bytes),
          'text': 'Отправлен файл',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
      );

      _pushNotification(
        kind: NotificationKind.file,
        title: 'Отправка файла',
        description: picked.name,
        showInSystem: false,
      );
      _safeNotify();

      return null;
    } catch (_) {
      return 'Не удалось выбрать файл. Проверьте доступ к файловой системе.';
    } finally {
      _isPickingFile = false;
      _safeNotify();
    }
  }

  List<int>? _resolveBytes(PlatformFile file) {
    final bytes = file.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return bytes;
    }
    return null;
  }

  void updateTypingStatus(String composerText) {
    if (!isConnected) {
      return;
    }

    final shouldBeTyping = composerText.trim().isNotEmpty;
    if (shouldBeTyping != _isMeTyping) {
      _sendTyping(isTyping: shouldBeTyping);
    }

    _typingStopTimer?.cancel();
    if (shouldBeTyping) {
      _typingStopTimer = Timer(const Duration(seconds: 2), () {
        _sendTyping(isTyping: false);
      });
    }
  }

  void _sendTyping({required bool isTyping}) {
    if (!isConnected) {
      return;
    }

    if (_isMeTyping == isTyping) {
      return;
    }

    _isMeTyping = isTyping;
    _sendEnvelope(type: 'typing', payload: {'isTyping': isTyping});
  }

  void _sendEnvelope({
    required String type,
    required Map<String, dynamic> payload,
  }) {
    final envelope = {'type': type, 'payload': payload};
    try {
      _channel?.sink.add(jsonEncode(envelope));
    } catch (_) {
      _lastError = 'Не удалось отправить событие: $type';
      _scheduledConfigError = _lastError;
      _isSavingScheduledConfig = false;
    }
  }

  void clearNotifications() {
    if (_notifications.isEmpty) {
      return;
    }
    _notifications.clear();
    _safeNotify();
  }

  void _setConnectionStatus(ChatConnectionStatus status) {
    _connectionStatus = status;
  }

  void _pushNotification({
    required NotificationKind kind,
    required String title,
    required String description,
    required bool showInSystem,
  }) {
    _notifications.add(
      AppNotification(
        id: _nextId(),
        kind: kind,
        title: title,
        description: description,
        createdAt: DateTime.now(),
      ),
    );

    if (_notifications.length > 80) {
      _notifications.removeRange(0, _notifications.length - 80);
    }

    if (showInSystem) {
      _showSystemNotification(
        kind: kind,
        title: title,
        description: description,
      );
    }
  }

  void _showSystemNotification({
    required NotificationKind kind,
    required String title,
    required String description,
  }) {
    if (kind == NotificationKind.typing) {
      final now = DateTime.now();
      if (now.difference(_lastTypingSystemNotificationAt) <
          const Duration(seconds: 25)) {
        return;
      }
      _lastTypingSystemNotificationAt = now;
    }

    unawaited(
      SystemNotificationService.instance.show(title: title, body: description),
    );
  }

  String _nextId() {
    return '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(9999)}';
  }

  String _normalizeServerUrl(String input) {
    var normalized = input.trim();
    if (normalized.isEmpty) {
      normalized = _defaultServerUrl;
    }

    if (!normalized.contains('://')) {
      normalized = 'ws://$normalized';
    }

    var uri = Uri.parse(normalized);

    if (uri.scheme == 'http') {
      uri = uri.replace(scheme: 'ws');
    } else if (uri.scheme == 'https') {
      uri = uri.replace(scheme: 'wss');
    }

    final path = uri.path.isEmpty || uri.path == '/' ? '/ws' : uri.path;
    uri = uri.replace(path: path, query: '', fragment: '');

    return uri.toString();
  }

  Future<void> checkForUpdates({bool notifyIfNoUpdate = false}) async {
    if (_isCheckingUpdates || _disposed) {
      return;
    }

    _isCheckingUpdates = true;
    _updateError = null;
    _safeNotify();

    try {
      final manifestUri = _updateManifestUriFromServerUrl(_serverUrl);
      final payload = await _loadJson(manifestUri);
      final latestVersion = (payload['version']?.toString() ?? '').trim();
      final latestBuild = _toInt(payload['build']);
      final notes = (payload['notes']?.toString() ?? '').trim();
      final downloads = _asMap(payload['downloads']);
      final platformKey = _platformKey();
      var downloadUrl = (downloads[platformKey]?.toString() ?? '').trim();

      if (downloadUrl.isEmpty) {
        downloadUrl = (downloads['all']?.toString() ?? '').trim();
      }
      final downloadUri = Uri.tryParse(downloadUrl);

      if (latestVersion.isEmpty || latestBuild == null) {
        throw const FormatException(
          'Version/build not found in update manifest.',
        );
      }
      if (downloadUri == null || downloadUri.toString().isEmpty) {
        throw FormatException(
          'Download URL for platform "$platformKey" is missing in update manifest.',
        );
      }

      final hasUpdate = _isRemoteVersionNewer(
        remoteVersion: latestVersion,
        remoteBuild: latestBuild,
      );
      final previousVersion = _latestVersion;
      final previousBuild = _latestBuild;

      if (hasUpdate) {
        _isUpdateAvailable = true;
        _latestVersion = latestVersion;
        _latestBuild = latestBuild;
        _updateDownloadUri = downloadUri;
        _updateNotes = notes.isEmpty ? null : notes;

        final isNewRelease =
            previousVersion != latestVersion || previousBuild != latestBuild;
        if (isNewRelease) {
          _pushNotification(
            kind: NotificationKind.system,
            title: 'Доступно обновление',
            description: 'Новая версия: $latestVersion+$latestBuild',
            showInSystem: true,
          );
        }
      } else {
        _isUpdateAvailable = false;
        _latestVersion = null;
        _latestBuild = null;
        _updateNotes = null;
        _updateDownloadUri = null;

        if (notifyIfNoUpdate) {
          _pushNotification(
            kind: NotificationKind.system,
            title: 'Обновлений нет',
            description: 'Установлена актуальная версия $currentVersionLabel',
            showInSystem: false,
          );
        }
      }
    } catch (error) {
      _updateError = _readableUpdateError(error);
      if (notifyIfNoUpdate) {
        _pushNotification(
          kind: NotificationKind.system,
          title: 'Ошибка проверки обновления',
          description: _updateError!,
          showInSystem: false,
        );
      }
    } finally {
      _lastUpdateCheckAt = DateTime.now();
      _isCheckingUpdates = false;
      _safeNotify();
    }
  }

  Future<String?> openUpdateDownload() async {
    if (!_isUpdateAvailable || _updateDownloadUri == null) {
      return 'Сейчас нет доступного обновления.';
    }

    final launched = await launchUrl(
      _updateDownloadUri!,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      return 'Не удалось открыть ссылку на обновление.';
    }
    return null;
  }

  Future<Map<String, dynamic>> _loadJson(Uri uri) async {
    final response = await http
        .get(uri, headers: const {'accept': 'application/json'})
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception(
        'HTTP ${response.statusCode} while loading update manifest.',
      );
    }

    final decoded = jsonDecode(response.body);
    return _asMap(decoded);
  }

  Uri _updateManifestUriFromServerUrl(String wsUrl) {
    final wsUri = Uri.parse(wsUrl);
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return wsUri.replace(
      scheme: scheme,
      path: '/update-manifest',
      query: '',
      fragment: '',
    );
  }

  String _platformKey() {
    if (kIsWeb) {
      return 'web';
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      _ => 'linux',
    };
  }

  bool _isRemoteVersionNewer({
    required String remoteVersion,
    required int remoteBuild,
  }) {
    final versionCmp = _compareVersionParts(remoteVersion, _appVersion);
    if (versionCmp > 0) {
      return true;
    }
    if (versionCmp < 0) {
      return false;
    }
    return remoteBuild > _appBuild;
  }

  int _compareVersionParts(String left, String right) {
    final leftParts = _extractVersionParts(left);
    final rightParts = _extractVersionParts(right);
    final length = max(leftParts.length, rightParts.length);

    for (var i = 0; i < length; i++) {
      final l = i < leftParts.length ? leftParts[i] : 0;
      final r = i < rightParts.length ? rightParts[i] : 0;
      if (l != r) {
        return l.compareTo(r);
      }
    }

    return 0;
  }

  List<int> _extractVersionParts(String version) {
    final rawParts = version.split(RegExp(r'[^0-9]+'));
    final parts = <int>[];
    for (final part in rawParts) {
      if (part.isEmpty) {
        continue;
      }
      parts.add(int.tryParse(part) ?? 0);
    }
    return parts.isEmpty ? <int>[0] : parts;
  }

  int? _toInt(Object? raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  String _readableUpdateError(Object error) {
    final text = error.toString().trim();
    if (text.isEmpty) {
      return 'Не удалось проверить обновления.';
    }
    return text;
  }

  String? _normalizeScheduleTime(String raw) {
    final text = raw.trim();
    final match = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$').firstMatch(text);
    if (match == null) {
      return null;
    }

    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  void _safeNotify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _typingStopTimer?.cancel();
    _updateCheckTimer?.cancel();
    _sendTyping(isTyping: false);
    _channelSubscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
