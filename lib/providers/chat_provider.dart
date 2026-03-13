import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/app_notification.dart';
import '../models/chat_message.dart';
import '../models/chat_user.dart';

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

  final List<ChatMessage> _messages = <ChatMessage>[];
  final List<AppNotification> _notifications = <AppNotification>[];
  final Set<String> _messageIds = <String>{};
  final Map<String, String> _onlineUsers = <String, String>{};
  final Map<String, String> _typingUsers = <String, String>{};
  final Random _random = Random();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _typingStopTimer;

  ThemeMode _themeMode = ThemeMode.light;
  ChatConnectionStatus _connectionStatus = ChatConnectionStatus.disconnected;

  String _serverUrl = _defaultServerUrl;
  String _userName = 'User';
  String _userId = '';

  String? _lastError;
  bool _isPickingFile = false;
  bool _isMeTyping = false;
  bool _disposed = false;

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

  ChatUser get me => ChatUser(id: _userId, name: _userName, isMe: true);

  int get notificationCount => _notifications.length;
  AppNotification? get latestNotification =>
      _notifications.isEmpty ? null : _notifications.last;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  List<AppNotification> get notifications =>
      List<AppNotification>.unmodifiable(_notifications.reversed);

  String get connectionStatusLine {
    if (_connectionStatus == ChatConnectionStatus.connecting) {
      return 'Подключение к серверу...';
    }

    if (_connectionStatus == ChatConnectionStatus.disconnected) {
      return 'Не подключено';
    }

    if (typingUsers.isNotEmpty) {
      return '${typingUsers.join(', ')} печатает...';
    }

    return 'Общая группа • В сети: $onlineUsersCount';
  }

  Future<void> _bootstrap() async {
    await _loadPreferences();
    if (_disposed) {
      return;
    }

    _messages.add(
      ChatMessage.system(
        id: _nextId(),
        createdAt: DateTime.now(),
        text: 'NetMax Messenger готов. Подключение к серверу...',
      ),
    );
    notifyListeners();

    await connect();
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

    final storedUserName = prefs.getString(_userNameKey);
    _userName = (storedUserName == null || storedUserName.trim().isEmpty)
        ? 'User-${1000 + _random.nextInt(9000)}'
        : storedUserName;

    final storedUserId = prefs.getString(_userIdKey);
    _userId = (storedUserId == null || storedUserId.trim().isEmpty)
        ? _nextId()
        : storedUserId;

    await prefs.setString(_userNameKey, _userName);
    await prefs.setString(_userIdKey, _userId);
    await prefs.setString(_serverUrlKey, _serverUrl);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) {
      return;
    }

    _themeMode = mode;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.name);
  }

  Future<void> applyConnectionSettings({
    required String serverUrl,
    required String userName,
  }) async {
    final normalizedServerUrl = _normalizeServerUrl(serverUrl);
    final normalizedUserName = userName.trim().isEmpty
        ? 'User-${1000 + _random.nextInt(9000)}'
        : userName.trim();

    _serverUrl = normalizedServerUrl;
    _userName = normalizedUserName;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, _serverUrl);
    await prefs.setString(_userNameKey, _userName);

    await connect(force: true);
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

    await _closeSocket(sendTypingOff: false, notify: false);

    _setConnectionStatus(ChatConnectionStatus.connecting);

    try {
      final uri = Uri.parse(_serverUrl);
      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 20),
      );

      _channelSubscription = _channel!.stream.listen(
        _onSocketData,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: true,
      );

      _setConnectionStatus(ChatConnectionStatus.connected);
      _sendEnvelope(
        type: 'join',
        payload: {'userId': _userId, 'userName': _userName},
      );

      _pushNotification(
        kind: NotificationKind.system,
        title: 'Подключено',
        description: 'Сервер: $_serverUrl',
      );
      notifyListeners();
    } catch (error) {
      _setConnectionStatus(ChatConnectionStatus.disconnected);
      _lastError = error.toString();
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Ошибка подключения',
        description: 'Не удалось подключиться к серверу.',
      );
      notifyListeners();
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

    await _channelSubscription?.cancel();
    _channelSubscription = null;

    await _channel?.sink.close();
    _channel = null;

    _setConnectionStatus(ChatConnectionStatus.disconnected);

    if (notify) {
      notifyListeners();
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
      );
      notifyListeners();
    }
  }

  void _onSocketError(Object error) {
    _lastError = error.toString();
    _setConnectionStatus(ChatConnectionStatus.disconnected);
    _pushNotification(
      kind: NotificationKind.system,
      title: 'Соединение потеряно',
      description: 'Ошибка: $_lastError',
    );
    notifyListeners();
  }

  void _onSocketDone() {
    _typingUsers.clear();
    _onlineUsers.clear();

    if (_connectionStatus != ChatConnectionStatus.disconnected) {
      _setConnectionStatus(ChatConnectionStatus.disconnected);
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Отключено',
        description: 'Соединение с сервером закрыто.',
      );
      notifyListeners();
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

    notifyListeners();
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
    );

    notifyListeners();
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
      );
    } else {
      _typingUsers.remove(userId);
    }

    notifyListeners();
  }

  void _handleMessage(Map<String, dynamic> payload) {
    final message = ChatMessage.fromJson(payload);
    if (message.id.isEmpty || _messageIds.contains(message.id)) {
      return;
    }

    _messageIds.add(message.id);
    _messages.add(message);

    if (message.senderId != _userId) {
      _pushNotification(
        kind: message.type == MessageType.file
            ? NotificationKind.file
            : NotificationKind.message,
        title: message.type == MessageType.file
            ? 'Новый файл'
            : 'Новое сообщение',
        description: message.type == MessageType.file
            ? '${message.senderName}: ${message.attachment?.name ?? 'Файл'}'
            : '${message.senderName}: ${message.text ?? ''}',
      );
    }

    notifyListeners();
  }

  void _handleServerError(Map<String, dynamic> payload) {
    final message = payload['message']?.toString() ?? 'Неизвестная ошибка.';
    _lastError = message;
    _pushNotification(
      kind: NotificationKind.system,
      title: 'Ошибка сервера',
      description: message,
    );
    notifyListeners();
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
      );
      notifyListeners();
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
    notifyListeners();

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return null;
      }

      final picked = result.files.single;
      final bytes = await _resolveBytes(picked);
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
      );
      notifyListeners();

      return null;
    } catch (_) {
      return 'Не удалось выбрать файл. Проверьте доступ к файловой системе.';
    } finally {
      _isPickingFile = false;
      notifyListeners();
    }
  }

  Future<List<int>?> _resolveBytes(PlatformFile file) async {
    if (file.bytes != null && file.bytes!.isNotEmpty) {
      return file.bytes;
    }

    if (file.path != null && file.path!.isNotEmpty) {
      return File(file.path!).readAsBytes();
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
    }
  }

  void clearNotifications() {
    if (_notifications.isEmpty) {
      return;
    }
    _notifications.clear();
    notifyListeners();
  }

  void _setConnectionStatus(ChatConnectionStatus status) {
    _connectionStatus = status;
  }

  void _pushNotification({
    required NotificationKind kind,
    required String title,
    required String description,
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

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  @override
  void dispose() {
    _disposed = true;
    _typingStopTimer?.cancel();
    _sendTyping(isTyping: false);
    _channelSubscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
