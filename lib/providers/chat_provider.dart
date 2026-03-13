import 'dart:async';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_notification.dart';
import '../models/chat_message.dart';
import '../models/chat_user.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider() {
    _bootstrap();
  }

  static const String _themeModeKey = 'theme_mode';

  final ChatUser _me = const ChatUser(id: 'me', name: 'Вы', isMe: true);
  final ChatUser _peer = const ChatUser(id: 'peer', name: 'Alex');

  final List<ChatMessage> _messages = <ChatMessage>[];
  final List<AppNotification> _notifications = <AppNotification>[];
  final List<Timer> _timers = <Timer>[];
  final Random _random = Random();

  Timer? _presenceTimer;
  Timer? _incomingMessageTimer;

  ThemeMode _themeMode = ThemeMode.light;
  bool _isPeerOnline = true;
  bool _isPeerTyping = false;
  bool _isPickingFile = false;
  bool _disposed = false;

  ThemeMode get themeMode => _themeMode;
  ChatUser get me => _me;
  ChatUser get peer => _peer;
  bool get isPeerOnline => _isPeerOnline;
  bool get isPeerTyping => _isPeerTyping;
  bool get isPickingFile => _isPickingFile;
  int get notificationCount => _notifications.length;
  AppNotification? get latestNotification =>
      _notifications.isEmpty ? null : _notifications.last;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  List<AppNotification> get notifications =>
      List<AppNotification>.unmodifiable(_notifications.reversed);

  Future<void> _bootstrap() async {
    await _loadThemeMode();
    if (_disposed) {
      return;
    }

    _seedInitialConversation();
    _startPresenceSimulation();
    _startIncomingMessages();
    notifyListeners();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final rawTheme = prefs.getString(_themeModeKey);
    _themeMode = switch (rawTheme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
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

  void sendText(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      return;
    }

    _messages.add(
      ChatMessage.text(
        id: _nextId(),
        senderId: _me.id,
        senderName: _me.name,
        createdAt: DateTime.now(),
        text: text,
      ),
    );
    notifyListeners();
    _simulatePeerReaction(sourceText: text);
  }

  Future<String?> pickAndSendFile() async {
    if (_isPickingFile) {
      return 'Выбор файла уже выполняется.';
    }

    _isPickingFile = true;
    notifyListeners();

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: false,
      );

      if (result == null || result.files.isEmpty) {
        return null;
      }

      final picked = result.files.single;
      final extension = p.extension(picked.name).replaceFirst('.', '');
      final safeExtension = extension.isEmpty
          ? 'FILE'
          : extension.toUpperCase();

      final attachment = MessageAttachment(
        name: picked.name,
        path: picked.path ?? '',
        sizeBytes: picked.size,
        extension: safeExtension,
      );

      _messages.add(
        ChatMessage.file(
          id: _nextId(),
          senderId: _me.id,
          senderName: _me.name,
          createdAt: DateTime.now(),
          attachment: attachment,
          text: 'Отправлен файл',
        ),
      );
      _pushNotification(
        kind: NotificationKind.file,
        title: 'Файл отправлен',
        description: picked.name,
      );
      notifyListeners();

      _simulatePeerReaction(fileName: picked.name);
      return null;
    } catch (_) {
      return 'Не удалось выбрать файл. Проверьте доступ к файловой системе.';
    } finally {
      _isPickingFile = false;
      notifyListeners();
    }
  }

  void clearNotifications() {
    if (_notifications.isEmpty) {
      return;
    }
    _notifications.clear();
    notifyListeners();
  }

  void _seedInitialConversation() {
    if (_messages.isNotEmpty) {
      return;
    }

    final now = DateTime.now();
    _messages.add(
      ChatMessage.system(
        id: _nextId(),
        createdAt: now.subtract(const Duration(minutes: 5)),
        text: 'Чат NetMax готов к работе.',
      ),
    );
    _messages.add(
      ChatMessage.text(
        id: _nextId(),
        senderId: _peer.id,
        senderName: _peer.name,
        createdAt: now.subtract(const Duration(minutes: 4)),
        text: 'Привет! Можно отправлять сообщения, файлы и переключать тему.',
      ),
    );
    _pushNotification(
      kind: NotificationKind.system,
      title: 'Система',
      description: 'Мессенджер готов к работе.',
    );
  }

  void _startPresenceSimulation() {
    _presenceTimer = Timer.periodic(const Duration(seconds: 26), (_) {
      if (_disposed) {
        return;
      }

      if (_random.nextDouble() < 0.55) {
        return;
      }

      _isPeerOnline = !_isPeerOnline;
      if (!_isPeerOnline) {
        _setPeerTyping(false, shouldNotify: false);
      }

      final statusText = _isPeerOnline
          ? '${_peer.name} в сети'
          : '${_peer.name} вышел из сети';

      _messages.add(
        ChatMessage.system(
          id: _nextId(),
          createdAt: DateTime.now(),
          text: statusText,
        ),
      );
      _pushNotification(
        kind: NotificationKind.presence,
        title: 'Статус пользователя',
        description: statusText,
      );
      notifyListeners();
    });
  }

  void _startIncomingMessages() {
    _incomingMessageTimer = Timer.periodic(const Duration(seconds: 18), (_) {
      if (_disposed || !_isPeerOnline || _isPeerTyping) {
        return;
      }

      if (_random.nextDouble() > 0.45) {
        return;
      }

      _simulatePeerReaction();
    });
  }

  void _simulatePeerReaction({String? sourceText, String? fileName}) {
    if (!_isPeerOnline) {
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Пользователь офлайн',
        description: '${_peer.name} получит сообщение, когда появится в сети.',
      );
      notifyListeners();
      return;
    }

    _setPeerTyping(true);
    _schedule(const Duration(seconds: 2), () {
      _setPeerTyping(false, shouldNotify: false);

      final reply = _buildReply(sourceText: sourceText, fileName: fileName);
      _messages.add(
        ChatMessage.text(
          id: _nextId(),
          senderId: _peer.id,
          senderName: _peer.name,
          createdAt: DateTime.now(),
          text: reply,
        ),
      );
      _pushNotification(
        kind: NotificationKind.message,
        title: 'Новое сообщение',
        description: '${_peer.name}: $reply',
      );
      notifyListeners();
    });
  }

  String _buildReply({String? sourceText, String? fileName}) {
    if (fileName != null) {
      return 'Файл "$fileName" получил, спасибо.';
    }

    if (sourceText != null && sourceText.length <= 25) {
      return 'Принял: "$sourceText"';
    }

    const replies = <String>[
      'Отлично, я на связи.',
      'Принято. Если нужно, отправь файл.',
      'Смотрится хорошо, продолжаем.',
      'Увидел сообщение. Давай дальше.',
      'Супер, синхронизация работает.',
    ];
    return replies[_random.nextInt(replies.length)];
  }

  void _setPeerTyping(bool value, {bool shouldNotify = true}) {
    if (_isPeerTyping == value) {
      return;
    }

    _isPeerTyping = value;
    if (value && shouldNotify) {
      _pushNotification(
        kind: NotificationKind.typing,
        title: 'Действие пользователя',
        description: '${_peer.name} печатает...',
      );
    }
    notifyListeners();
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

  void _schedule(Duration delay, VoidCallback action) {
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      if (_disposed) {
        return;
      }
      action();
    });
    _timers.add(timer);
  }

  String _nextId() {
    return '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(9999)}';
  }

  @override
  void dispose() {
    _disposed = true;
    _presenceTimer?.cancel();
    _incomingMessageTimer?.cancel();
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }
}
