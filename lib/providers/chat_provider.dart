import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as encrypt;
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
import '../models/chat_thread.dart';
import '../models/chat_user.dart';
import '../services/mesh_transport_service.dart';
import '../services/mesh_transport_service_base.dart';
import '../services/proxy_transport_service.dart';
import '../services/proxy_transport_service_base.dart';
import '../services/system_notification_service.dart';

enum ChatConnectionStatus { disconnected, connecting, connected }

class PreparedFileUpload {
  const PreparedFileUpload({
    required this.name,
    required this.extension,
    required this.sizeBytes,
    required this.bytes,
  });

  final String name;
  final String extension;
  final int sizeBytes;
  final List<int> bytes;
}

class ChatProvider extends ChangeNotifier {
  ChatProvider() {
    _bootstrap();
  }

  static const String _themeModeKey = 'theme_mode';
  static const String _serverUrlKey = 'server_url';
  static const String _userNameKey = 'user_name';
  static const String _userIdKey = 'user_id';
  static const String _passwordsByUserKey = 'passwords_by_user';
  static const String _subscriptionSourcesKey = 'ws_subscription_sources';
  static const String _proxySubscriptionSourcesKey =
      'proxy_subscription_sources';
  static const String _dismissedUpdateSignatureKey =
      'dismissed_update_signature';
  static const String _e2eeSecretKey = 'e2ee_secret';

  static const String _defaultServerUrl = 'ws://localhost:8080/ws';
  static const String _defaultSubscriptionSourcesRaw = String.fromEnvironment(
    'NETMAX_WS_SUBSCRIPTION_SOURCES',
    defaultValue: '',
  );
  static const String _defaultProxySubscriptionSourcesRaw =
      String.fromEnvironment(
        'NETMAX_PROXY_SUBSCRIPTION_SOURCES',
        defaultValue: '',
      );
  static const Duration _updateCheckInterval = Duration(minutes: 15);
  static const Duration _reconnectBaseDelay = Duration(seconds: 3);
  static const Duration _reconnectMaxDelay = Duration(seconds: 30);
  static const Duration _meshFallbackActivationDelay = Duration(minutes: 1);
  static const Duration _subscriptionRefreshInterval = Duration(hours: 1);
  static const Duration _subscriptionProbeTimeout = Duration(seconds: 5);
  static const Duration _subscriptionConnectTimeout = Duration(seconds: 12);
  static const Duration _meshRetryInterval = Duration(seconds: 4);
  static const int _meshMaxRetryAttempts = 5;
  static const int _clientMaxMessages = 1500;
  static const String _defaultGroupChatId = 'group-general';
  static const String _defaultGroupChatTitle = 'Общий чат';
  static const Set<String> _scheduledRestrictedUsersLower = <String>{
    'юлия сергеевна',
    'татьяна владимировна',
  };

  final List<ChatMessage> _messages = <ChatMessage>[];
  final List<AppNotification> _notifications = <AppNotification>[];
  final Set<String> _messageIds = <String>{};
  final Map<String, String> _onlineUsers = <String, String>{};
  final Map<String, String> _typingUsers = <String, String>{};
  final Map<String, String> _groupChatTitlesById = <String, String>{
    _defaultGroupChatId: _defaultGroupChatTitle,
  };
  final Map<String, String> _allowedUsersByLower = <String, String>{};
  final Map<String, String> _directChatPeerById = <String, String>{};
  final Map<String, int> _unreadByChatId = <String, int>{};
  String _selectedChatId = _defaultGroupChatId;
  final Random _random = Random();

  WebSocketChannel? _channel;
  Future<void> Function()? _channelResourceDisposer;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _typingStopTimer;
  Timer? _updateCheckTimer;
  Timer? _subscriptionRefreshTimer;
  Timer? _reconnectTimer;
  Timer? _meshFallbackTimer;
  Timer? _meshRetryTimer;

  ThemeMode _themeMode = ThemeMode.light;
  ChatConnectionStatus _connectionStatus = ChatConnectionStatus.disconnected;

  String _serverUrl = _defaultServerUrl;
  String _userName = '';
  String _userId = '';
  String _e2eeSecret = '';
  String? _pendingPasswordForAuth;
  final Map<String, String> _passwordsByUserLower = <String, String>{};

  String? _lastError;
  bool _isPickingFile = false;
  bool _isMeTyping = false;
  bool _disposed = false;
  bool _isCheckingUpdates = false;
  bool _isUpdateAvailable = false;
  bool _isSavingScheduledConfig = false;
  bool _isSubscriptionFailoverRunning = false;
  bool _suppressReconnectScheduling = false;

  String _appVersion = '0.0.0';
  int _appBuild = 0;
  String? _latestVersion;
  int? _latestBuild;
  String? _updateNotes;
  Uri? _updateDownloadUri;
  String? _updateError;
  DateTime? _lastUpdateCheckAt;
  String? _dismissedUpdateSignature;

  bool _scheduledEnabled = false;
  String _scheduledText = '';
  String _scheduledTime = '09:00';
  int _scheduledTimezoneOffsetMinutes = 0;
  String? _scheduledLastSentDate;
  DateTime? _scheduledUpdatedAt;
  String? _scheduledConfigError;
  bool _isScheduledAllowedByServer = true;
  bool _isMeshFallbackActive = false;
  DateTime? _serverUnavailableSince;
  DateTime? _lastSubscriptionRefreshAt;
  final List<String> _subscriptionSources = <String>[];
  final List<String> _subscriptionCandidates = <String>[];
  final List<String> _proxySubscriptionSources = <String>[];
  final List<ProxyEndpoint> _proxyCandidates = <ProxyEndpoint>[];
  ProxyEndpoint? _activeProxyEndpoint;
  final Map<String, _MeshPendingMessage> _meshPendingByMessageId =
      <String, _MeshPendingMessage>{};

  final MeshTransportServiceBase _meshTransport = MeshTransportService.instance;
  final ProxyTransportServiceBase _proxyTransport =
      ProxyTransportService.instance;

  int _reconnectAttempt = 0;
  bool _manualDisconnectRequested = false;

  ThemeMode get themeMode => _themeMode;
  ChatConnectionStatus get connectionStatus => _connectionStatus;
  bool get isConnected => _connectionStatus == ChatConnectionStatus.connected;
  bool get isMeshFallbackActive => _isMeshFallbackActive;
  bool get isSubscriptionFailoverRunning => _isSubscriptionFailoverRunning;
  DateTime? get lastSubscriptionRefreshAt => _lastSubscriptionRefreshAt;
  String get subscriptionSourcesText => _subscriptionSources.join('\n');
  String get proxySubscriptionSourcesText =>
      _proxySubscriptionSources.join('\n');

  String get serverUrl => _serverUrl;
  String get userName => _userName;
  String get userId => _userId;
  String get encryptionKey => _e2eeSecret;
  bool get isEncryptionEnabled => _e2eeSecret.trim().isNotEmpty;
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
  bool get shouldShowUpdateBanner => _isUpdateAvailable && !_isUpdateDismissed;

  bool get scheduledEnabled => _scheduledEnabled;
  String get scheduledText => _scheduledText;
  String get scheduledTime => _scheduledTime;
  int get scheduledTimezoneOffsetMinutes => _scheduledTimezoneOffsetMinutes;
  String? get scheduledLastSentDate => _scheduledLastSentDate;
  DateTime? get scheduledUpdatedAt => _scheduledUpdatedAt;
  String? get scheduledConfigError => _scheduledConfigError;
  bool get canUseScheduledMessages =>
      isConnected &&
      _isScheduledAllowedByServer &&
      _isScheduledAllowedForUser(_userName);
  String get selectedChatId => _selectedChatId;
  String get selectedChatTitle => _chatTitleById(_selectedChatId);
  List<ChatThread> get chats => _buildChatThreads();
  List<ChatThread> searchDirectUsers(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const <ChatThread>[];
    }

    final lastMessageByChatId = _lastMessagesByChatId();
    final results = <ChatThread>[];
    final entries = _directChatPeerById.entries.where((entry) {
      final name = entry.value.toLowerCase();
      return name.contains(normalized);
    }).toList()..sort((a, b) => a.value.compareTo(b.value));

    for (final entry in entries) {
      final lastMessage = lastMessageByChatId[entry.key];
      results.add(
        ChatThread(
          id: entry.key,
          title: 'ЛС: ${entry.value}',
          type: ChatThreadType.direct,
          lastMessageAt: lastMessage?.createdAt,
          lastMessagePreview: lastMessage == null
              ? null
              : _threadPreview(lastMessage),
          unreadCount: _unreadByChatId[entry.key] ?? 0,
        ),
      );
    }

    return List<ChatThread>.unmodifiable(results);
  }

  bool get hasSavedPasswordForCurrentUser => hasSavedPasswordForUser(_userName);

  ChatUser get me => ChatUser(id: _userId, name: _userName, isMe: true);

  bool hasSavedPasswordForUser(String userName) {
    if (!_canPersistPasswordLocally) {
      return false;
    }
    final key = _passwordCacheKey(userName);
    if (key.isEmpty) {
      return false;
    }
    final stored = _passwordsByUserLower[key];
    return stored != null && stored.isNotEmpty;
  }

  int get notificationCount => _notifications.length;
  AppNotification? get latestNotification =>
      _notifications.isEmpty ? null : _notifications.last;

  List<ChatMessage> get messages {
    final selected = _selectedChatId;
    final visible = _messages
        .where((message) => message.chatId == selected)
        .toList(growable: false);
    return List<ChatMessage>.unmodifiable(visible);
  }

  List<AppNotification> get notifications =>
      List<AppNotification>.unmodifiable(_notifications.reversed);

  List<String> get mentionCandidates {
    final meLower = _userName.trim().toLowerCase();
    final result = _allowedUsersByLower.entries
        .where((entry) => entry.key != meLower)
        .map((entry) => entry.value)
        .toList(growable: false)
      ..sort((a, b) => a.compareTo(b));
    return result;
  }

  bool isMyMessage(ChatMessage message) {
    final senderId = message.senderId.trim();
    if (senderId.isNotEmpty && senderId == _userId) {
      return true;
    }

    final myName = _userName.trim().toLowerCase();
    if (myName.isEmpty) {
      return false;
    }

    final senderName = message.senderName.trim().toLowerCase();
    return senderName.isNotEmpty && senderName == myName;
  }

  String get connectionStatusLine {
    if (_connectionStatus == ChatConnectionStatus.connecting) {
      return 'Авторизация на сервере...';
    }

    if (_isMeshFallbackActive &&
        _connectionStatus != ChatConnectionStatus.connected) {
      final mode = _meshTransport.isSupported
          ? 'Mesh режим LAN: узел недоступен'
          : 'Mesh режим: не поддерживается на этой платформе';
      return '$mode • Сообщения: общий чат';
    }

    if (_isSubscriptionFailoverRunning &&
        _connectionStatus != ChatConnectionStatus.connected) {
      return 'Подбор подписки: поиск самого быстрого сервера...';
    }

    if (_connectionStatus == ChatConnectionStatus.disconnected) {
      return 'Не подключено';
    }

    if (typingUsers.isNotEmpty) {
      return '${typingUsers.join(', ')} печатает...';
    }

    final proxy = _activeProxyEndpoint;
    final proxyLabel = proxy == null
        ? ''
        : ' • Proxy: ${proxy.scheme.toUpperCase()} ${proxy.host}:${proxy.port}';
    return 'Авторизован: $_userName • В сети: $onlineUsersCount$proxyLabel';
  }

  void selectChat(String chatId) {
    final normalized = chatId.trim();
    if (normalized.isEmpty || !_chatExists(normalized)) {
      return;
    }
    if (_selectedChatId == normalized) {
      return;
    }
    _selectedChatId = normalized;
    _typingUsers.clear();
    _unreadByChatId[_selectedChatId] = 0;
    _markSelectedChatMessagesAsRead();
    _safeNotify();
  }

  String get _primaryGroupChatId {
    if (_groupChatTitlesById.containsKey(_defaultGroupChatId)) {
      return _defaultGroupChatId;
    }
    if (_groupChatTitlesById.isNotEmpty) {
      return _groupChatTitlesById.keys.first;
    }
    return _defaultGroupChatId;
  }

  bool _chatExists(String chatId) {
    return _groupChatTitlesById.containsKey(chatId) ||
        _directChatPeerById.containsKey(chatId);
  }

  String _chatTitleById(String chatId) {
    final groupTitle = _groupChatTitlesById[chatId];
    if (groupTitle != null && groupTitle.trim().isNotEmpty) {
      return groupTitle;
    }

    final directName = _directChatPeerById[chatId];
    if (directName != null && directName.trim().isNotEmpty) {
      return 'ЛС: $directName';
    }

    if (_isDirectChatId(chatId)) {
      final peerName = _resolvePeerNameForDirectChat(chatId);
      if (peerName != null && peerName.isNotEmpty) {
        return 'ЛС: $peerName';
      }
    }

    return 'Чат';
  }

  Map<String, ChatMessage> _lastMessagesByChatId() {
    final result = <String, ChatMessage>{};
    for (final message in _messages) {
      final chatId = message.chatId.trim();
      if (chatId.isEmpty) {
        continue;
      }
      final previous = result[chatId];
      if (previous == null || previous.createdAt.isBefore(message.createdAt)) {
        result[chatId] = message;
      }
    }
    return result;
  }

  List<ChatThread> _buildChatThreads() {
    final lastMessageByChatId = _lastMessagesByChatId();

    final threads = <ChatThread>[];
    final added = <String>{};

    void addThread({
      required String id,
      required String title,
      required ChatThreadType type,
    }) {
      if (!added.add(id)) {
        return;
      }
      final lastMessage = lastMessageByChatId[id];
      threads.add(
        ChatThread(
          id: id,
          title: title,
          type: type,
          lastMessageAt: lastMessage?.createdAt,
          lastMessagePreview: lastMessage == null
              ? null
              : _threadPreview(lastMessage),
          unreadCount: _unreadByChatId[id] ?? 0,
        ),
      );
    }

    final groupEntries = _groupChatTitlesById.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final entry in groupEntries) {
      addThread(id: entry.key, title: entry.value, type: ChatThreadType.group);
    }

    final directEntries = _directChatPeerById.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final entry in directEntries) {
      final hasMessages = lastMessageByChatId.containsKey(entry.key);
      if (!hasMessages && entry.key != _selectedChatId) {
        continue;
      }
      addThread(
        id: entry.key,
        title: 'ЛС: ${entry.value}',
        type: ChatThreadType.direct,
      );
    }

    threads.sort((left, right) {
      if (left.type != right.type) {
        return left.type == ChatThreadType.group ? -1 : 1;
      }

      final leftLast = left.lastMessageAt;
      final rightLast = right.lastMessageAt;
      if (leftLast != null && rightLast != null) {
        final byDate = rightLast.compareTo(leftLast);
        if (byDate != 0) {
          return byDate;
        }
      } else if (leftLast != null) {
        return -1;
      } else if (rightLast != null) {
        return 1;
      }

      return left.title.compareTo(right.title);
    });

    return List<ChatThread>.unmodifiable(threads);
  }

  String _threadPreview(ChatMessage message) {
    final senderPrefix = isMyMessage(message)
        ? 'Вы: '
        : '${message.senderName}: ';
    if (message.isDeleted) {
      return '$senderPrefixСообщение удалено';
    }
    if (message.type == MessageType.file) {
      final attachmentName = message.attachment?.name ?? 'Файл';
      final caption = (message.text ?? '').trim();
      if (caption.isEmpty) {
        return '$senderPrefix$attachmentName';
      }
      return '$senderPrefix$caption';
    }

    final text = (message.text ?? '').trim();
    if (text.isEmpty) {
      return senderPrefix.trim();
    }
    return '$senderPrefix$text';
  }

  String? _normalizeGroupChatId(String raw, {bool requireExisting = true}) {
    final id = raw.trim().toLowerCase();
    if (id.isEmpty) {
      return null;
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{1,63}$').hasMatch(id)) {
      return null;
    }
    if (requireExisting && !_groupChatTitlesById.containsKey(id)) {
      return null;
    }
    return id;
  }

  void _syncGroupChats(Object? raw) {
    final merged = <String, String>{
      _defaultGroupChatId: _defaultGroupChatTitle,
    };

    if (raw is List) {
      for (final item in raw) {
        final map = _asMap(item);
        final normalizedId = _normalizeGroupChatId(
          map['id']?.toString() ?? '',
          requireExisting: false,
        );
        if (normalizedId == null || merged.containsKey(normalizedId)) {
          continue;
        }

        final title = (map['title']?.toString() ?? '').trim();
        merged[normalizedId] = title.isEmpty ? 'Групповой чат' : title;
      }
    }

    _groupChatTitlesById
      ..clear()
      ..addAll(merged);
  }

  void _syncAllowedUsers(Object? raw) {
    _allowedUsersByLower.clear();
    if (raw is! List) {
      return;
    }

    for (final item in raw) {
      final map = _asMap(item);
      final fromMap = (map['name']?.toString() ?? '').trim();
      final name = fromMap.isNotEmpty ? fromMap : item.toString().trim();
      if (name.isEmpty) {
        continue;
      }
      _allowedUsersByLower[name.toLowerCase()] = name;
    }
  }

  void _syncDirectChats() {
    final meLower = _userName.trim().toLowerCase();
    _directChatPeerById.clear();
    if (meLower.isEmpty) {
      return;
    }

    for (final entry in _allowedUsersByLower.entries) {
      if (entry.key == meLower) {
        continue;
      }
      final chatId = _buildDirectChatIdForUsers(meLower, entry.key);
      _directChatPeerById[chatId] = entry.value;
    }

    for (final message in _messages) {
      _rememberDirectChat(message.chatId, peerNameHint: message.senderName);
    }
  }

  void _ensureSelectedChatExists() {
    if (_chatExists(_selectedChatId)) {
      return;
    }
    _selectedChatId = _primaryGroupChatId;
    _typingUsers.clear();
    _unreadByChatId[_selectedChatId] = 0;
  }

  void _registerMessageChat(ChatMessage message) {
    final chatId = message.chatId.trim();
    if (chatId.isEmpty) {
      return;
    }

    if (_isDirectChatId(chatId)) {
      _rememberDirectChat(chatId, peerNameHint: message.senderName);
      return;
    }

    final normalizedGroup = _normalizeGroupChatId(
      chatId,
      requireExisting: false,
    );
    if (normalizedGroup == null) {
      return;
    }
    _groupChatTitlesById.putIfAbsent(normalizedGroup, () => 'Групповой чат');
  }

  bool _isDirectChatId(String chatId) {
    return chatId.startsWith('direct:');
  }

  String _buildDirectChatIdForUsers(String firstLower, String secondLower) {
    final parts = <String>[firstLower, secondLower]..sort();
    return 'direct:${parts[0]}|${parts[1]}';
  }

  String? _normalizeDirectChatId(String raw) {
    if (!_isDirectChatId(raw)) {
      return null;
    }
    final tail = raw.substring('direct:'.length);
    final parts = tail.split('|');
    if (parts.length != 2) {
      return null;
    }

    final first = parts[0].trim().toLowerCase();
    final second = parts[1].trim().toLowerCase();
    if (first.isEmpty || second.isEmpty || first == second) {
      return null;
    }

    return _buildDirectChatIdForUsers(first, second);
  }

  bool _directChatIncludesUser(String chatId, String userLower) {
    final normalized = _normalizeDirectChatId(chatId);
    if (normalized == null) {
      return false;
    }
    final tail = normalized.substring('direct:'.length);
    final parts = tail.split('|');
    if (parts.length != 2) {
      return false;
    }
    return parts[0] == userLower || parts[1] == userLower;
  }

  String? _resolvePeerNameForDirectChat(String chatId, {String? fallbackName}) {
    final normalized = _normalizeDirectChatId(chatId);
    if (normalized == null) {
      return null;
    }

    final tail = normalized.substring('direct:'.length);
    final parts = tail.split('|');
    if (parts.length != 2) {
      return null;
    }

    final meLower = _userName.trim().toLowerCase();
    String peerLower;
    if (parts[0] == meLower) {
      peerLower = parts[1];
    } else if (parts[1] == meLower) {
      peerLower = parts[0];
    } else {
      peerLower = parts[0];
    }

    final fromAllowed = _allowedUsersByLower[peerLower];
    if (fromAllowed != null && fromAllowed.isNotEmpty) {
      return fromAllowed;
    }

    final fallback = fallbackName?.trim();
    if (fallback != null &&
        fallback.isNotEmpty &&
        fallback.toLowerCase() != meLower) {
      return fallback;
    }

    final partsForDisplay = peerLower
        .split(RegExp(r'[_\-. ]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .toList(growable: false);
    if (partsForDisplay.isEmpty) {
      return peerLower;
    }
    return partsForDisplay.join(' ');
  }

  void _rememberDirectChat(String chatId, {String? peerNameHint}) {
    final normalized = _normalizeDirectChatId(chatId);
    if (normalized == null) {
      return;
    }

    final meLower = _userName.trim().toLowerCase();
    if (meLower.isNotEmpty && !_directChatIncludesUser(normalized, meLower)) {
      return;
    }

    final peerName = _resolvePeerNameForDirectChat(
      normalized,
      fallbackName: peerNameHint,
    );
    if (peerName == null || peerName.trim().isEmpty) {
      return;
    }
    _directChatPeerById[normalized] = peerName.trim();
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
        chatId: _selectedChatId,
        text: _userName.isEmpty
            ? 'Выберите имя из списка авторизованных пользователей и подключитесь к серверу.'
            : 'NetMax Messenger готов. Выполняется подключение к серверу...',
      ),
    );
    _safeNotify();

    _startUpdateChecks();
    _startSubscriptionRefresh();
    await checkForUpdates();
    await _refreshAllCandidates(force: true);

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

  void _startSubscriptionRefresh() {
    _subscriptionRefreshTimer?.cancel();
    _subscriptionRefreshTimer = Timer.periodic(_subscriptionRefreshInterval, (
      _,
    ) {
      unawaited(_refreshAllCandidates());
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

    _dismissedUpdateSignature = prefs.getString(_dismissedUpdateSignatureKey);
    _passwordsByUserLower.clear();
    if (_canPersistPasswordLocally) {
      _passwordsByUserLower.addAll(
        _decodePasswordMap(prefs.getString(_passwordsByUserKey)),
      );
    }

    final storedServerUrl = prefs.getString(_serverUrlKey) ?? _defaultServerUrl;
    try {
      _serverUrl = _normalizeServerUrl(storedServerUrl);
    } catch (_) {
      _serverUrl = _defaultServerUrl;
    }

    final storedSourcesRaw =
        prefs.getString(_subscriptionSourcesKey) ??
        _defaultSubscriptionSourcesRaw;
    _subscriptionSources
      ..clear()
      ..addAll(_parseSourceUrls(storedSourcesRaw));

    final storedProxySourcesRaw =
        prefs.getString(_proxySubscriptionSourcesKey) ??
        _defaultProxySubscriptionSourcesRaw;
    _proxySubscriptionSources
      ..clear()
      ..addAll(_parseSourceUrls(storedProxySourcesRaw));

    _userName = (prefs.getString(_userNameKey) ?? '').trim();
    _e2eeSecret = (prefs.getString(_e2eeSecretKey) ?? '').trim();

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
    required String password,
    String? subscriptionSources,
    String? proxySubscriptionSources,
    String? encryptionKey,
  }) async {
    final normalizedServerUrl = _normalizeServerUrl(serverUrl);
    final normalizedUserName = userName.trim();

    if (normalizedUserName.isEmpty) {
      throw const FormatException(
        'Введите имя пользователя из списка 30 авторизованных.',
      );
    }

    final cacheKey = _passwordCacheKey(normalizedUserName);
    final typedPassword = password.trim();
    final cachedPassword = !_canPersistPasswordLocally || cacheKey.isEmpty
        ? ''
        : (_passwordsByUserLower[cacheKey] ?? '');
    final effectivePassword = typedPassword.isNotEmpty
        ? typedPassword
        : cachedPassword;
    if (effectivePassword.isEmpty) {
      throw const FormatException('Введите пароль пользователя.');
    }

    _serverUrl = normalizedServerUrl;
    _userName = normalizedUserName;
    if (encryptionKey != null) {
      _e2eeSecret = encryptionKey.trim();
    }
    _isScheduledAllowedByServer = _isScheduledAllowedForUser(_userName);
    _pendingPasswordForAuth = effectivePassword;

    if (_canPersistPasswordLocally && cacheKey.isNotEmpty) {
      _passwordsByUserLower[cacheKey] = effectivePassword;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, _serverUrl);
    await prefs.setString(_userNameKey, _userName);
    if (encryptionKey != null) {
      await prefs.setString(_e2eeSecretKey, _e2eeSecret);
    }
    if (subscriptionSources != null) {
      _subscriptionSources
        ..clear()
        ..addAll(_parseSourceUrls(subscriptionSources));
      await prefs.setString(
        _subscriptionSourcesKey,
        _subscriptionSources.join('\n'),
      );
    }
    if (proxySubscriptionSources != null) {
      _proxySubscriptionSources
        ..clear()
        ..addAll(_parseSourceUrls(proxySubscriptionSources));
      await prefs.setString(
        _proxySubscriptionSourcesKey,
        _proxySubscriptionSources.join('\n'),
      );
    }
    await _refreshAllCandidates(force: true);
    if (_canPersistPasswordLocally && cacheKey.isNotEmpty) {
      await prefs.setString(
        _passwordsByUserKey,
        jsonEncode(_passwordsByUserLower),
      );
    }
    await connect(force: true);
    await checkForUpdates();
  }

  Future<void> connect({bool force = false, ProxyEndpoint? proxy}) async {
    if (_disposed) {
      return;
    }

    if (_connectionStatus == ChatConnectionStatus.connecting) {
      return;
    }

    if (_connectionStatus == ChatConnectionStatus.connected && !force) {
      return;
    }

    _manualDisconnectRequested = false;
    _cancelReconnect(resetAttempt: false);

    if (_userName.trim().isEmpty) {
      _clearServerUnavailableMarker();
      _deactivateMeshFallback();
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Авторизация',
        description: 'Введите имя пользователя из whitelist.',
        showInSystem: false,
      );
      _safeNotify();
      return;
    }

    final passwordForAuth = _resolvedPasswordForCurrentUser;
    if (passwordForAuth.isEmpty) {
      _clearServerUnavailableMarker();
      _deactivateMeshFallback();
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Требуется пароль',
        description: 'Введите пароль пользователя в настройках подключения.',
        showInSystem: false,
      );
      _setConnectionStatus(ChatConnectionStatus.disconnected);
      _manualDisconnectRequested = true;
      _safeNotify();
      return;
    }

    await _closeSocket(sendTypingOff: false, notify: false);
    _activeProxyEndpoint = proxy;

    _setConnectionStatus(ChatConnectionStatus.connecting);
    _lastError = null;
    _safeNotify();

    try {
      final uri = Uri.parse(_serverUrl);
      final session = await _proxyTransport.openWebSocket(
        uri: uri,
        proxy: proxy,
      );
      _channelResourceDisposer = session.dispose;
      _channel = session.channel;

      _channelSubscription = _channel!.stream.listen(
        _onSocketData,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: true,
      );

      _sendEnvelope(
        type: 'join',
        payload: {
          'userId': _userId,
          'userName': _userName,
          'password': passwordForAuth,
        },
      );
    } catch (error) {
      _activeProxyEndpoint = null;
      _setConnectionStatus(ChatConnectionStatus.disconnected);
      _lastError = error.toString();
      _markServerUnavailable();
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Ошибка подключения',
        description: 'Не удалось подключиться к серверу.',
        showInSystem: true,
      );
      _scheduleReconnectIfNeeded();
      _safeNotify();
    }
  }

  Future<void> disconnect() async {
    _manualDisconnectRequested = true;
    _isSubscriptionFailoverRunning = false;
    _suppressReconnectScheduling = false;
    _clearServerUnavailableMarker();
    _deactivateMeshFallback();
    _cancelReconnect();
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

    await _disposeChannelResources();

    _setConnectionStatus(ChatConnectionStatus.disconnected);
    if (!_isSubscriptionFailoverRunning) {
      _activeProxyEndpoint = null;
    }

    if (notify) {
      _safeNotify();
    }
  }

  Future<void> _disposeChannelResources() async {
    await _channelSubscription?.cancel();
    _channelSubscription = null;

    await _channel?.sink.close();
    _channel = null;

    final resourceDisposer = _channelResourceDisposer;
    _channelResourceDisposer = null;
    if (resourceDisposer != null) {
      await resourceDisposer();
    }
  }

  void _disposeChannelResourcesWithoutAwait() {
    final subscription = _channelSubscription;
    _channelSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }

    final channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close());
    }

    final resourceDisposer = _channelResourceDisposer;
    _channelResourceDisposer = null;
    if (resourceDisposer != null) {
      unawaited(resourceDisposer());
    }

    if (!_isSubscriptionFailoverRunning) {
      _activeProxyEndpoint = null;
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
        case 'message_updated':
          _handleMessageUpdated(payload);
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
    _isScheduledAllowedByServer = _isScheduledAllowedForUser(_userName);
    _syncDirectChats();
    _ensureSelectedChatExists();
    _clearServerUnavailableMarker();
    _deactivateMeshFallback();

    _setConnectionStatus(ChatConnectionStatus.connected);
    _manualDisconnectRequested = false;
    _cancelReconnect();
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
      if (_canPersistPasswordLocally) {
        final password = _pendingPasswordForAuth?.trim();
        if (password != null && password.isNotEmpty) {
          final key = _passwordCacheKey(_userName);
          if (key.isNotEmpty) {
            _passwordsByUserLower[key] = password;
            await prefs.setString(
              _passwordsByUserKey,
              jsonEncode(_passwordsByUserLower),
            );
          }
        }
      }
    });
    _pendingPasswordForAuth = null;

    _safeNotify();
  }

  void _handleScheduledConfig(Map<String, dynamic> payload) {
    final payloadUserName = (payload['userName']?.toString() ?? '').trim();
    final userNameForPolicy = payloadUserName.isEmpty
        ? _userName
        : payloadUserName;
    final allowedByServer = payload['allowed'] != false;
    _isScheduledAllowedByServer =
        allowedByServer && _isScheduledAllowedForUser(userNameForPolicy);

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

    if (!_isScheduledAllowedByServer) {
      _scheduledEnabled = false;
    }

    _scheduledConfigError = null;
    _isSavingScheduledConfig = false;
    _safeNotify();
  }

  void _onSocketError(Object error) {
    _disposeChannelResourcesWithoutAwait();
    _lastError = error.toString();
    _setConnectionStatus(ChatConnectionStatus.disconnected);
    _isSavingScheduledConfig = false;
    _markServerUnavailable();
    _pushNotification(
      kind: NotificationKind.system,
      title: 'Соединение потеряно',
      description: 'Ошибка: $_lastError',
      showInSystem: true,
    );
    _scheduleReconnectIfNeeded();
    _safeNotify();
  }

  void _onSocketDone() {
    _disposeChannelResourcesWithoutAwait();
    _typingUsers.clear();
    _onlineUsers.clear();
    _isSavingScheduledConfig = false;

    if (_connectionStatus != ChatConnectionStatus.disconnected) {
      _setConnectionStatus(ChatConnectionStatus.disconnected);
      _markServerUnavailable();
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Отключено',
        description: 'Соединение с сервером закрыто.',
        showInSystem: true,
      );
      _scheduleReconnectIfNeeded();
      _safeNotify();
    }
  }

  void _handleSnapshot(Map<String, dynamic> payload) {
    final onlineUsersRaw = payload['onlineUsers'];
    final messagesRaw = payload['messages'];
    final groupChatsRaw = payload['groupChats'];
    final allowedUsersRaw = payload['allowedUsers'];

    _syncGroupChats(groupChatsRaw);
    _syncAllowedUsers(allowedUsersRaw);
    _syncDirectChats();
    _ensureSelectedChatExists();

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
    _unreadByChatId.clear();

    if (messagesRaw is List) {
      for (final item in messagesRaw) {
        final map = _asMap(item);
        final message = _messageFromServerPayload(map);
        if (message.id.isEmpty || _messageIds.contains(message.id)) {
          continue;
        }
        _registerMessageChat(message);
        _messageIds.add(message.id);
        _messages.add(message);
      }
    }

    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _syncDirectChats();
    _ensureSelectedChatExists();
    _markSelectedChatMessagesAsRead();

    if (_messages.isEmpty) {
      _messages.add(
        ChatMessage.system(
          id: _nextId(),
          createdAt: DateTime.now(),
          chatId: _selectedChatId,
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
        chatId: _primaryGroupChatId,
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
    final chatId = (payload['chatId']?.toString() ?? _primaryGroupChatId)
        .trim();

    if (userId.isEmpty || userId == _userId) {
      return;
    }

    if (_isDirectChatId(chatId)) {
      _rememberDirectChat(chatId, peerNameHint: userName);
    }

    if (chatId != _selectedChatId) {
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
    final message = _messageFromServerPayload(payload);
    if (message.id.isEmpty) {
      return;
    }

    final added = _appendLocalMessage(message);
    if (!added) {
      return;
    }

    final isMine = isMyMessage(message);
    _sendDeliveryReceiptIfNeeded(message);
    if (!isMine && message.chatId == _selectedChatId) {
      _sendReadReceiptIfNeeded(message);
    }

    if (!isMine && message.chatId != _selectedChatId) {
      _unreadByChatId[message.chatId] =
          (_unreadByChatId[message.chatId] ?? 0) + 1;
    }

    if (!isMine) {
      final isFile = message.type == MessageType.file;
      final fileName = message.attachment?.name ?? 'Файл';
      final messageText = (message.text ?? '').trim();
      final bodyText = isFile
          ? (messageText.isEmpty ? fileName : '$fileName — $messageText')
          : (messageText.isEmpty ? 'Сообщение' : messageText);
      final isMentioned = _isMentionedInMessage(message);
      final title = isMentioned
          ? 'Упоминание в чате'
          : (isFile ? 'Новый файл' : 'Новое сообщение');
      _pushNotification(
        kind: NotificationKind.message,
        title: title,
        description: '${message.senderName}: $bodyText',
        showInSystem: true,
      );
    }

    _safeNotify();
  }

  void _handleMessageUpdated(Map<String, dynamic> payload) {
    final message = _messageFromServerPayload(payload);
    if (message.id.isEmpty) {
      return;
    }

    final changed = _upsertLocalMessage(message);
    if (!changed) {
      return;
    }

    if (!isMyMessage(message) && message.chatId == _selectedChatId) {
      _sendReadReceiptIfNeeded(message);
    }
    _safeNotify();
  }

  bool _appendLocalMessage(ChatMessage message) {
    if (message.id.isEmpty || _messageIds.contains(message.id)) {
      return false;
    }
    _registerMessageChat(message);
    _messageIds.add(message.id);
    _messages.add(message);
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _trimMessageCache();
    return true;
  }

  bool _upsertLocalMessage(ChatMessage message) {
    final index = _messages.indexWhere((item) => item.id == message.id);
    if (index < 0) {
      return _appendLocalMessage(message);
    }

    final current = _messages[index];
    if (current.toJson().toString() == message.toJson().toString()) {
      return false;
    }

    _messages[index] = message;
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _trimMessageCache();
    return true;
  }

  void _trimMessageCache() {
    if (_messages.length <= _clientMaxMessages) {
      return;
    }
    final overflow = _messages.length - _clientMaxMessages;
    if (overflow <= 0) {
      return;
    }
    final removed = _messages.take(overflow).toList(growable: false);
    _messages.removeRange(0, overflow);
    for (final message in removed) {
      _messageIds.remove(message.id);
    }
  }

  ChatMessage _messageFromServerPayload(Map<String, dynamic> payload) {
    final normalized = Map<String, dynamic>.from(payload);
    if (normalized['encrypted'] == true) {
      final decryptedText = _decryptTextPayload(
        (normalized['text']?.toString() ?? ''),
        _asMap(normalized['encryption']),
      );
      if (decryptedText != null) {
        normalized['text'] = decryptedText;
      } else {
        normalized['text'] = '[Не удалось расшифровать]';
      }

      final editHistoryRaw = normalized['editHistory'];
      if (editHistoryRaw is List) {
        final normalizedHistory = <Map<String, dynamic>>[];
        for (final item in editHistoryRaw) {
          final map = _asMap(item);
          final decrypted = _decryptTextPayload(
            (map['text']?.toString() ?? ''),
            map['encryption'] is Map
                ? _asMap(map['encryption'])
                : _asMap(normalized['encryption']),
          );
          normalizedHistory.add(<String, dynamic>{
            'text': decrypted ?? '[Не удалось расшифровать]',
            'editedAt': map['editedAt'],
            if (map['encryption'] is Map) 'encryption': _asMap(map['encryption']),
          });
        }
        normalized['editHistory'] = normalizedHistory;
      }
    }

    return ChatMessage.fromJson(normalized);
  }

  bool _isMentionedInMessage(ChatMessage message) {
    final meLower = _userName.trim().toLowerCase();
    if (meLower.isEmpty) {
      return false;
    }
    return message.mentions.contains(meLower);
  }

  void _sendDeliveryReceiptIfNeeded(ChatMessage message) {
    if (!isConnected || isMyMessage(message)) {
      return;
    }

    final meLower = _userName.trim().toLowerCase();
    if (meLower.isEmpty) {
      return;
    }
    if (message.deliveredTo.contains(meLower)) {
      return;
    }

    _sendEnvelope(
      type: 'message_delivered',
      payload: <String, dynamic>{'id': message.id},
    );
  }

  void _sendReadReceiptIfNeeded(ChatMessage message) {
    if (!isConnected || isMyMessage(message)) {
      return;
    }

    final meLower = _userName.trim().toLowerCase();
    if (meLower.isEmpty) {
      return;
    }
    if (message.readBy.contains(meLower)) {
      return;
    }

    _sendEnvelope(
      type: 'message_read',
      payload: <String, dynamic>{'id': message.id},
    );
  }

  void _markSelectedChatMessagesAsRead() {
    if (!isConnected) {
      return;
    }

    final selectedChat = _selectedChatId;
    for (final message in _messages) {
      if (message.chatId != selectedChat) {
        continue;
      }
      _sendReadReceiptIfNeeded(message);
    }
  }

  void _handleServerError(Map<String, dynamic> payload) {
    final message = payload['message']?.toString() ?? 'Неизвестная ошибка.';
    _lastError = message;
    _scheduledConfigError = message;
    _isSavingScheduledConfig = false;

    final msgLower = message.toLowerCase();
    final isHardAuthError =
        msgLower.contains('авторизация') &&
        !msgLower.contains('лимит сессий') &&
        !msgLower.contains('уже в сети');

    final shouldDisconnect =
        _connectionStatus == ChatConnectionStatus.connecting || isHardAuthError;

    if (shouldDisconnect) {
      _typingUsers.clear();
      _onlineUsers.clear();
      _setConnectionStatus(ChatConnectionStatus.disconnected);
      if (isHardAuthError) {
        _manualDisconnectRequested = true;
        _clearServerUnavailableMarker();
        _deactivateMeshFallback();
        _cancelReconnect();
        _pendingPasswordForAuth = null;
        final cacheKey = _passwordCacheKey(_userName);
        if (_canPersistPasswordLocally &&
            cacheKey.isNotEmpty &&
            _passwordsByUserLower.remove(cacheKey) != null) {
          unawaited(_savePasswordCache());
        }
      } else {
        _markServerUnavailable();
        _scheduleReconnectIfNeeded();
      }

      _pushNotification(
        kind: NotificationKind.system,
        title: 'Ошибка сервера',
        description: message,
        showInSystem: true,
      );

      unawaited(_closeSocket(sendTypingOff: false, notify: true));
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
    if (!canUseScheduledMessages) {
      return 'Для пользователя $_userName отправка по времени отключена.';
    }

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

  void sendText(String rawText, {ChatMessage? replyTo}) {
    final text = rawText.trim();
    if (text.isEmpty) {
      return;
    }

    if (!isConnected && !_isMeshFallbackActive) {
      return;
    }

    if (!isConnected && _isMeshFallbackActive) {
      if (_selectedChatId != _primaryGroupChatId) {
        return;
      }

      final messageId = _nextId();
      final createdAt = DateTime.now();
      final replyPayload = replyTo == null
          ? null
          : _replyPayloadFromMessage(replyTo);
      final createdAtIso = createdAt.toUtc().toIso8601String();
      final mentions = _extractMentionsFromText(text);
      final added = _appendLocalMessage(
        ChatMessage.text(
          id: messageId,
          chatId: _primaryGroupChatId,
          senderId: _userId,
          senderName: _userName,
          createdAt: createdAt,
          text: text,
          replyTo: replyPayload == null
              ? null
              : MessageReplyInfo.fromJson(replyPayload),
        ).copyWith(
          mentions: mentions,
          deliveredTo: <String>[_userName.trim().toLowerCase()],
          readBy: <String>[_userName.trim().toLowerCase()],
        ),
      );
      if (added) {
        _safeNotify();
      }

      _meshPendingByMessageId[messageId] = _MeshPendingMessage(
        messageId: messageId,
        text: text,
        createdAtIso: createdAtIso,
        replyTo: replyPayload,
      );
      _startMeshRetryLoopIfNeeded();
      unawaited(_sendMeshPendingMessage(messageId));

      updateTypingStatus('');
      return;
    }

    final encryptedPayload = _encryptTextPayload(text);
    final outgoingText = encryptedPayload?.cipherText ?? text;
    final mentions = _extractMentionsFromText(text);

    _sendEnvelope(
      type: 'message',
      payload: {
        'id': _nextId(),
        'text': outgoingText,
        'chatId': _selectedChatId,
        'mentions': mentions,
        if (encryptedPayload != null) 'encrypted': true,
        if (encryptedPayload != null)
          'encryption': <String, dynamic>{
            'method': encryptedPayload.method,
            'nonce': encryptedPayload.nonceBase64,
          },
        if (replyTo != null) 'replyTo': _replyPayloadFromMessage(replyTo),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      },
    );

    updateTypingStatus('');
  }

  Future<String?> editMessage({
    required ChatMessage message,
    required String text,
  }) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      return 'Текст сообщения не может быть пустым.';
    }
    if (!isConnected) {
      return 'Нет подключения к серверу.';
    }
    if (!isMyMessage(message)) {
      return 'Редактировать можно только свои сообщения.';
    }
    if (message.isDeleted) {
      return 'Удаленное сообщение нельзя редактировать.';
    }
    if (message.type != MessageType.text && message.type != MessageType.file) {
      return 'Этот тип сообщения нельзя редактировать.';
    }

    final encrypted = message.isEncrypted
        ? _encryptTextPayload(normalizedText)
        : null;
    if (message.isEncrypted && encrypted == null) {
      return 'Для редактирования зашифрованного сообщения нужен ключ шифрования.';
    }
    _sendEnvelope(
      type: 'message_edit',
      payload: <String, dynamic>{
        'id': message.id,
        'text': encrypted?.cipherText ?? normalizedText,
        'mentions': _extractMentionsFromText(normalizedText),
        if (encrypted != null) 'encrypted': true,
        if (encrypted != null)
          'encryption': <String, dynamic>{
            'method': encrypted.method,
            'nonce': encrypted.nonceBase64,
          },
      },
    );
    return null;
  }

  Future<String?> deleteMessage(ChatMessage message) async {
    if (!isConnected) {
      return 'Нет подключения к серверу.';
    }
    if (!isMyMessage(message)) {
      return 'Удалять можно только свои сообщения.';
    }
    if (message.isDeleted) {
      return null;
    }
    _sendEnvelope(
      type: 'message_delete',
      payload: <String, dynamic>{'id': message.id},
    );
    return null;
  }

  Future<void> toggleReaction(ChatMessage message, String reaction) async {
    final normalized = reaction.trim();
    if (normalized.isEmpty || !isConnected || message.isDeleted) {
      return;
    }
    _sendEnvelope(
      type: 'message_reaction_toggle',
      payload: <String, dynamic>{'id': message.id, 'reaction': normalized},
    );
  }

  Future<PreparedFileUpload?> pickFileForSending() async {
    if (!isConnected) {
      throw const FormatException(
        'Нет подключения к серверу. Невозможно отправить файл.',
      );
    }

    if (_isPickingFile) {
      throw const FormatException('Выбор файла уже выполняется.');
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
        throw const FormatException('Не удалось прочитать файл.');
      }

      const maxFileSize = 20 * 1024 * 1024;
      if (bytes.length > maxFileSize) {
        throw const FormatException('Файл слишком большой. Максимум 20 MB.');
      }

      final extension = p.extension(picked.name).replaceFirst('.', '');
      final safeExtension = extension.isEmpty
          ? 'FILE'
          : extension.toUpperCase();

      return PreparedFileUpload(
        name: picked.name,
        extension: safeExtension,
        sizeBytes: bytes.length,
        bytes: bytes,
      );
    } catch (error) {
      if (error is FormatException) {
        rethrow;
      }
      throw const FormatException(
        'Не удалось выбрать файл. Проверьте доступ к файловой системе.',
      );
    } finally {
      _isPickingFile = false;
      _safeNotify();
    }
  }

  Future<String?> sendPickedFile(
    PreparedFileUpload file, {
    String caption = '',
    ChatMessage? replyTo,
  }) async {
    if (_isMeshFallbackActive && !isConnected) {
      return 'В Mesh режиме сейчас доступна только отправка текстовых сообщений.';
    }

    if (!isConnected) {
      return 'Нет подключения к серверу. Невозможно отправить файл.';
    }

    final normalizedCaption = caption.trim();
    final encryptedCaption = normalizedCaption.isEmpty
        ? null
        : _encryptTextPayload(normalizedCaption);
    final outgoingCaption = encryptedCaption?.cipherText ?? normalizedCaption;
    final mentions = normalizedCaption.isEmpty
        ? const <String>[]
        : _extractMentionsFromText(normalizedCaption);

    _sendEnvelope(
      type: 'file',
      payload: {
        'id': _nextId(),
        'chatId': _selectedChatId,
        'name': file.name,
        'extension': file.extension,
        'sizeBytes': file.sizeBytes,
        'contentBase64': base64Encode(file.bytes),
        'text': outgoingCaption,
        'mentions': mentions,
        if (encryptedCaption != null) 'encrypted': true,
        if (encryptedCaption != null)
          'encryption': <String, dynamic>{
            'method': encryptedCaption.method,
            'nonce': encryptedCaption.nonceBase64,
          },
        if (replyTo != null) 'replyTo': _replyPayloadFromMessage(replyTo),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      },
    );

    return null;
  }

  Map<String, dynamic> _replyPayloadFromMessage(ChatMessage message) {
    final previewText = (message.text ?? '').trim();
    final fallbackFileName = message.attachment?.name ?? 'Файл';
    final textForPayload = previewText.isEmpty ? fallbackFileName : previewText;
    return <String, dynamic>{
      'messageId': message.id,
      'senderName': message.senderName.trim().isEmpty
          ? 'Unknown'
          : message.senderName.trim(),
      'text': textForPayload,
      'type': message.type.value,
    };
  }

  Future<String?> openAttachment(
    MessageAttachment attachment, {
    bool forceDownload = true,
  }) async {
    final uri = _attachmentUri(attachment, forceDownload: forceDownload);
    final launched = await launchUrl(
      uri,
      mode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
    );
    if (!launched) {
      return 'Не удалось открыть файл для скачивания.';
    }
    return null;
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
    _sendEnvelope(
      type: 'typing',
      payload: {'isTyping': isTyping, 'chatId': _selectedChatId},
    );
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

  String get _resolvedPasswordForCurrentUser {
    final pending = _pendingPasswordForAuth?.trim();
    if (pending != null && pending.isNotEmpty) {
      return pending;
    }
    if (!_canPersistPasswordLocally) {
      return '';
    }
    final key = _passwordCacheKey(_userName);
    if (key.isEmpty) {
      return '';
    }
    final cached = _passwordsByUserLower[key];
    if (cached == null) {
      return '';
    }
    return cached.trim();
  }

  String _passwordCacheKey(String userName) {
    return userName.trim().toLowerCase();
  }

  bool _isScheduledAllowedForUser(String userName) {
    final key = userName.trim().toLowerCase();
    if (key.isEmpty) {
      return true;
    }
    return !_scheduledRestrictedUsersLower.contains(key);
  }

  bool get _canPersistPasswordLocally => true;

  Map<String, String> _decodePasswordMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return <String, String>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return <String, String>{};
      }
      final map = <String, String>{};
      decoded.forEach((key, value) {
        final normalizedKey = key.toString().trim().toLowerCase();
        final normalizedValue = value.toString().trim();
        if (normalizedKey.isEmpty || normalizedValue.isEmpty) {
          return;
        }
        map[normalizedKey] = normalizedValue;
      });
      return map;
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> _savePasswordCache() async {
    if (!_canPersistPasswordLocally) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _passwordsByUserKey,
      jsonEncode(_passwordsByUserLower),
    );
  }

  List<String> _extractMentionsFromText(String text) {
    final normalized = text.trim().toLowerCase();
    if (normalized.isEmpty || _allowedUsersByLower.isEmpty) {
      return const <String>[];
    }

    final mentions = <String>{};
    for (final key in _allowedUsersByLower.keys) {
      if (normalized.contains('@$key')) {
        mentions.add(key);
      }
    }
    return mentions.toList(growable: false);
  }

  _EncryptedTextPayload? _encryptTextPayload(String plainText) {
    final secret = _e2eeSecret.trim();
    if (secret.isEmpty) {
      return null;
    }
    final normalized = plainText.trim();
    if (normalized.isEmpty) {
      return null;
    }

    final key = _deriveEncryptionKey(secret);
    final iv = encrypt.IV.fromSecureRandom(12);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.gcm, padding: null),
    );
    final encrypted = encrypter.encrypt(normalized, iv: iv);

    return _EncryptedTextPayload(
      cipherText: encrypted.base64,
      nonceBase64: iv.base64,
      method: 'aes-gcm-256-v1',
    );
  }

  String? _decryptTextPayload(
    String cipherText,
    Map<String, dynamic>? encryption,
  ) {
    final secret = _e2eeSecret.trim();
    if (secret.isEmpty) {
      return null;
    }

    final method = (encryption?['method']?.toString() ?? '')
        .trim()
        .toLowerCase();
    final nonceRaw = (encryption?['nonce']?.toString() ?? '').trim();
    if (nonceRaw.isEmpty) {
      return null;
    }

    if (method.isEmpty || method == 'xor-v1') {
      return _decryptLegacyXor(
        cipherText: cipherText,
        nonceBase64: nonceRaw,
        secret: secret,
      );
    }

    if (method != 'aes-gcm-256-v1' && method != 'aes-gcm-256') {
      return null;
    }

    try {
      final key = _deriveEncryptionKey(secret);
      final iv = encrypt.IV.fromBase64(nonceRaw);
      final encrypted = encrypt.Encrypted.fromBase64(cipherText);
      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.gcm, padding: null),
      );
      return encrypter.decrypt(encrypted, iv: iv);
    } catch (_) {
      return null;
    }
  }

  encrypt.Key _deriveEncryptionKey(String secret) {
    final digest = crypto.sha256.convert(utf8.encode(secret)).bytes;
    return encrypt.Key(Uint8List.fromList(digest));
  }

  String? _decryptLegacyXor({
    required String cipherText,
    required String nonceBase64,
    required String secret,
  }) {
    try {
      final cipher = base64Decode(cipherText);
      final nonce = base64Decode(nonceBase64);
      if (cipher.isEmpty || nonce.isEmpty) {
        return null;
      }
      final keyBytes = utf8.encode(secret);
      final plain = List<int>.generate(cipher.length, (index) {
        final k = keyBytes[index % keyBytes.length];
        final n = nonce[index % nonce.length];
        return cipher[index] ^ k ^ n;
      });
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  List<String> _parseSourceUrls(String raw) {
    final chunks = raw
        .split(RegExp(r'[\n\r,;]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty && !item.startsWith('#'));

    final unique = <String>{};
    for (final chunk in chunks) {
      final parsed = Uri.tryParse(chunk);
      if (parsed == null) {
        continue;
      }
      if (!parsed.hasScheme) {
        continue;
      }
      final scheme = parsed.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        continue;
      }
      unique.add(parsed.toString());
    }
    return unique.toList(growable: false);
  }

  Future<void> _refreshAllCandidates({bool force = false}) async {
    await _refreshSubscriptionCandidates(force: force);
    await _refreshProxyCandidates(force: force);
  }

  Future<void> _refreshSubscriptionCandidates({bool force = false}) async {
    if (_subscriptionSources.isEmpty) {
      _subscriptionCandidates.clear();
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastSubscriptionRefreshAt != null &&
        now.difference(_lastSubscriptionRefreshAt!) <
            _subscriptionRefreshInterval) {
      return;
    }

    final collected = <String>{};
    for (final source in _subscriptionSources) {
      final endpoints = await _fetchSubscriptionEndpoints(source);
      collected.addAll(endpoints);
    }

    _subscriptionCandidates
      ..clear()
      ..addAll(collected);
    _lastSubscriptionRefreshAt = now;
  }

  Future<void> _refreshProxyCandidates({bool force = false}) async {
    if (_proxySubscriptionSources.isEmpty) {
      _proxyCandidates.clear();
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastSubscriptionRefreshAt != null &&
        now.difference(_lastSubscriptionRefreshAt!) <
            _subscriptionRefreshInterval) {
      return;
    }

    final unique = <String, ProxyEndpoint>{};
    for (final source in _proxySubscriptionSources) {
      final proxies = await _fetchProxyEndpoints(source);
      for (final proxy in proxies) {
        unique[proxy.id] = proxy;
      }
    }

    _proxyCandidates
      ..clear()
      ..addAll(unique.values);
  }

  Future<List<String>> _fetchSubscriptionEndpoints(String sourceUrl) async {
    final text = await _downloadSubscriptionText(sourceUrl);
    if (text == null) {
      return const <String>[];
    }
    return _extractServerUrls(text);
  }

  Future<List<ProxyEndpoint>> _fetchProxyEndpoints(String sourceUrl) async {
    final text = await _downloadSubscriptionText(sourceUrl);
    if (text == null) {
      return const <ProxyEndpoint>[];
    }
    return _extractProxyEndpoints(text);
  }

  Future<String?> _downloadSubscriptionText(String sourceUrl) async {
    try {
      final source = Uri.parse(sourceUrl);
      final response = await http
          .get(source, headers: const {'accept': 'application/json,text/plain'})
          .timeout(_subscriptionProbeTimeout);
      if (response.statusCode != 200) {
        return null;
      }
      return response.body;
    } catch (_) {
      return null;
    }
  }

  List<String> _extractServerUrls(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return const <String>[];
    }

    final unique = <String>{};

    void addCandidate(Object? value) {
      final candidate = value?.toString().trim() ?? '';
      if (candidate.isEmpty) {
        return;
      }
      try {
        final normalized = _normalizeServerUrl(candidate);
        unique.add(normalized);
      } catch (_) {}
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        for (final item in decoded) {
          addCandidate(item);
        }
      } else if (decoded is Map) {
        for (final key in const ['servers', 'endpoints', 'ws', 'urls']) {
          final rawList = decoded[key];
          if (rawList is List) {
            for (final item in rawList) {
              addCandidate(item);
            }
          }
        }
      }
    } catch (_) {
      final lines = text.split(RegExp(r'[\n\r]+'));
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          continue;
        }
        addCandidate(trimmed);
      }
    }

    return unique.toList(growable: false);
  }

  List<ProxyEndpoint> _extractProxyEndpoints(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return const <ProxyEndpoint>[];
    }

    final unique = <String, ProxyEndpoint>{};

    void addProxy(Object? value) {
      final proxy = _parseProxyEndpoint(value);
      if (proxy == null) {
        return;
      }
      unique[proxy.id] = proxy;
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is List) {
        for (final item in decoded) {
          addProxy(item);
        }
      } else if (decoded is Map) {
        for (final key in const ['proxies', 'proxy', 'endpoints', 'urls']) {
          final rawList = decoded[key];
          if (rawList is List) {
            for (final item in rawList) {
              addProxy(item);
            }
          }
        }
      }
    } catch (_) {
      final lines = text.split(RegExp(r'[\n\r]+'));
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          continue;
        }
        addProxy(trimmed);
      }
    }

    return unique.values.toList(growable: false);
  }

  ProxyEndpoint? _parseProxyEndpoint(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      return null;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' &&
        scheme != 'https' &&
        scheme != 'socks5' &&
        scheme != 'socks') {
      return null;
    }

    final port = uri.hasPort
        ? uri.port
        : (scheme == 'http' || scheme == 'https' ? 8080 : 1080);
    if (port <= 0) {
      return null;
    }

    final userInfo = uri.userInfo.trim();
    String? username;
    String? password;
    if (userInfo.isNotEmpty) {
      final parts = userInfo.split(':');
      final parsedUser = Uri.decodeComponent(parts.first).trim();
      if (parsedUser.isNotEmpty) {
        username = parsedUser;
      }
      if (parts.length > 1) {
        final parsedPass = Uri.decodeComponent(
          parts.sublist(1).join(':'),
        ).trim();
        if (parsedPass.isNotEmpty) {
          password = parsedPass;
        }
      }
    }

    return ProxyEndpoint(
      scheme: scheme,
      host: uri.host.trim(),
      port: port,
      username: username,
      password: password,
    );
  }

  List<String> _resolveFailoverServerCandidates() {
    final unique = <String>{_serverUrl};
    unique.addAll(_subscriptionCandidates);
    return unique.toList(growable: false);
  }

  List<ProxyEndpoint> _resolveFailoverProxyCandidates() {
    final unique = <String, ProxyEndpoint>{};
    for (final proxy in _proxyCandidates) {
      unique[proxy.id] = proxy;
    }
    return unique.values.toList(growable: false);
  }

  Future<List<String>> _rankCandidatesByLatency(List<String> candidates) async {
    if (candidates.isEmpty) {
      return const <String>[];
    }

    final probes = await Future.wait(
      candidates.map(_probeCandidate),
      eagerError: false,
    );

    probes.sort((a, b) {
      final aLatency = a.latency ?? const Duration(days: 1);
      final bLatency = b.latency ?? const Duration(days: 1);
      final cmp = aLatency.compareTo(bLatency);
      if (cmp != 0) {
        return cmp;
      }
      return a.serverUrl.compareTo(b.serverUrl);
    });

    return probes.map((item) => item.serverUrl).toList(growable: false);
  }

  Future<List<ProxyEndpoint>> _rankProxyCandidatesByLatency({
    required String serverUrl,
    required List<ProxyEndpoint> proxies,
  }) async {
    if (proxies.isEmpty || !_proxyTransport.supportsCustomProxy) {
      return const <ProxyEndpoint>[];
    }

    final probes = await Future.wait(
      proxies.map((proxy) => _probeCandidate(serverUrl, proxy: proxy)),
      eagerError: false,
    );

    probes.sort((a, b) {
      final aLatency = a.latency ?? const Duration(days: 1);
      final bLatency = b.latency ?? const Duration(days: 1);
      final cmp = aLatency.compareTo(bLatency);
      if (cmp != 0) {
        return cmp;
      }
      final aId = a.proxy?.id ?? '';
      final bId = b.proxy?.id ?? '';
      return aId.compareTo(bId);
    });

    final ranked = <ProxyEndpoint>[];
    for (final probe in probes) {
      if (probe.latency == null || probe.proxy == null) {
        continue;
      }
      ranked.add(probe.proxy!);
    }
    return ranked;
  }

  Future<_ServerProbeResult> _probeCandidate(
    String serverUrl, {
    ProxyEndpoint? proxy,
  }) async {
    try {
      final healthUri = _healthUriFromServerUrl(serverUrl);
      final latency = await _proxyTransport.probeHealth(
        healthUri: healthUri,
        timeout: _subscriptionProbeTimeout,
        proxy: proxy,
      );
      return _ServerProbeResult(
        serverUrl: serverUrl,
        latency: latency,
        proxy: proxy,
      );
    } catch (_) {
      return _ServerProbeResult(
        serverUrl: serverUrl,
        latency: null,
        proxy: proxy,
      );
    }
  }

  Uri _healthUriFromServerUrl(String serverUrl) {
    final wsUri = Uri.parse(serverUrl);
    return Uri(
      scheme: wsUri.scheme == 'wss' ? 'https' : 'http',
      host: wsUri.host,
      port: wsUri.hasPort ? wsUri.port : null,
      path: '/health',
    );
  }

  Future<bool> _attemptConnectPlan(_FailoverPlan plan) async {
    if (_disposed || _manualDisconnectRequested) {
      return false;
    }

    try {
      _serverUrl = _normalizeServerUrl(plan.serverUrl);
    } catch (_) {
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, _serverUrl);

    if (_connectionStatus == ChatConnectionStatus.connecting) {
      await _closeSocket(sendTypingOff: false, notify: false);
    }

    await connect(force: true, proxy: plan.proxy);
    return _waitForConnected(timeout: _subscriptionConnectTimeout);
  }

  Future<bool> _waitForConnected({required Duration timeout}) async {
    final endAt = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(endAt)) {
      if (isConnected) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return isConnected;
  }

  void _markServerUnavailable() {
    if (_manualDisconnectRequested || _userName.trim().isEmpty) {
      return;
    }
    _serverUnavailableSince ??= DateTime.now();
    _scheduleMeshFallbackActivation();
  }

  void _clearServerUnavailableMarker() {
    _serverUnavailableSince = null;
    _meshFallbackTimer?.cancel();
    _meshFallbackTimer = null;
  }

  void _scheduleMeshFallbackActivation() {
    if (_isMeshFallbackActive) {
      return;
    }

    final since = _serverUnavailableSince;
    if (since == null) {
      return;
    }

    final elapsed = DateTime.now().difference(since);
    final remaining = _meshFallbackActivationDelay - elapsed;
    if (remaining <= Duration.zero) {
      unawaited(_runSubscriptionFailover());
      return;
    }

    _meshFallbackTimer?.cancel();
    _meshFallbackTimer = Timer(remaining, () {
      _meshFallbackTimer = null;
      unawaited(_runSubscriptionFailover());
    });
  }

  Future<void> _runSubscriptionFailover() async {
    if (_disposed || _manualDisconnectRequested || isConnected) {
      return;
    }
    if (_isSubscriptionFailoverRunning) {
      return;
    }

    _isSubscriptionFailoverRunning = true;
    _suppressReconnectScheduling = true;
    _cancelReconnect(resetAttempt: false);
    _safeNotify();

    try {
      await _refreshAllCandidates(force: true);
      final rankedServers = await _rankCandidatesByLatency(
        _resolveFailoverServerCandidates(),
      );
      final plans = <_FailoverPlan>[
        for (final server in rankedServers) _FailoverPlan(serverUrl: server),
      ];

      if (_proxyTransport.supportsCustomProxy) {
        final proxyBaseServer = rankedServers.isNotEmpty
            ? rankedServers.first
            : _serverUrl;
        final rankedProxies = await _rankProxyCandidatesByLatency(
          serverUrl: proxyBaseServer,
          proxies: _resolveFailoverProxyCandidates(),
        );
        plans.addAll(
          rankedProxies.map(
            (proxy) => _FailoverPlan(serverUrl: proxyBaseServer, proxy: proxy),
          ),
        );
      }

      for (final plan in plans) {
        if (_disposed || _manualDisconnectRequested || isConnected) {
          return;
        }
        final connected = await _attemptConnectPlan(plan);
        if (connected) {
          return;
        }
      }
    } finally {
      _suppressReconnectScheduling = false;
      _isSubscriptionFailoverRunning = false;
      _safeNotify();
    }

    if (!isConnected) {
      if (_meshTransport.isSupported) {
        await _activateMeshFallback();
      }
      _scheduleReconnectIfNeeded();
    }
  }

  Future<void> _activateMeshFallback() async {
    if (_disposed || _isMeshFallbackActive) {
      return;
    }
    if (_connectionStatus == ChatConnectionStatus.connected) {
      return;
    }
    if (!_meshTransport.isSupported) {
      return;
    }

    try {
      await _meshTransport.start(
        userId: _userId,
        userName: _userName,
        onMessage: _onMeshPacket,
      );
      _isMeshFallbackActive = true;
      _safeNotify();
    } catch (_) {
      _isMeshFallbackActive = false;
    }
  }

  void _deactivateMeshFallback() {
    _meshFallbackTimer?.cancel();
    _meshFallbackTimer = null;
    _meshRetryTimer?.cancel();
    _meshRetryTimer = null;
    _meshPendingByMessageId.clear();
    final wasActive = _isMeshFallbackActive || _meshTransport.isRunning;
    _isMeshFallbackActive = false;
    unawaited(_meshTransport.stop());
    if (wasActive) {
      _safeNotify();
    }
  }

  void _onMeshPacket(Map<String, dynamic> payload) {
    final type = (payload['type']?.toString() ?? '').trim();
    if (type == 'mesh_ack') {
      _onMeshAck(payload);
      return;
    }
    if (type == 'mesh_message') {
      _onMeshMessage(payload);
    }
  }

  void _onMeshMessage(Map<String, dynamic> payload) {
    final chatType = (payload['chatType']?.toString() ?? 'group').trim();
    final messageType = (payload['messageType']?.toString() ?? 'text').trim();
    if (chatType != 'group' || messageType != 'text') {
      return;
    }

    final messageId = (payload['id']?.toString() ?? '').trim();
    final senderId = (payload['senderId']?.toString() ?? '').trim();
    if (messageId.isEmpty || senderId.isEmpty) {
      return;
    }

    unawaited(
      _meshTransport.sendAck(
        messageId: messageId,
        userId: _userId,
        targetUserId: senderId,
        createdAtIso: DateTime.now().toUtc().toIso8601String(),
      ),
    );

    if (_messageIds.contains(messageId)) {
      return;
    }

    final normalizedPayload = <String, dynamic>{
      'id': messageId,
      'senderId': senderId,
      'senderName': (payload['senderName']?.toString() ?? 'Unknown').trim(),
      'createdAt': (payload['createdAt']?.toString() ?? '').trim(),
      'type': 'text',
      'text': (payload['text']?.toString() ?? '').trim(),
      'scheduled': false,
      'chatId': _primaryGroupChatId,
      'chatType': 'group',
      if (payload['replyTo'] is Map) 'replyTo': _asMap(payload['replyTo']),
    };
    _handleMessage(normalizedPayload);
  }

  void _onMeshAck(Map<String, dynamic> payload) {
    final targetUserId = (payload['targetUserId']?.toString() ?? '').trim();
    final messageId = (payload['id']?.toString() ?? '').trim();
    if (targetUserId != _userId || messageId.isEmpty) {
      return;
    }
    _meshPendingByMessageId.remove(messageId);
    if (_meshPendingByMessageId.isEmpty) {
      _meshRetryTimer?.cancel();
      _meshRetryTimer = null;
    }
  }

  void _startMeshRetryLoopIfNeeded() {
    if (_meshRetryTimer != null) {
      return;
    }
    _meshRetryTimer = Timer.periodic(_meshRetryInterval, (_) {
      _processMeshRetries();
    });
  }

  Future<void> _sendMeshPendingMessage(String messageId) async {
    if (!_isMeshFallbackActive || isConnected) {
      _meshPendingByMessageId.clear();
      _meshRetryTimer?.cancel();
      _meshRetryTimer = null;
      return;
    }

    final pending = _meshPendingByMessageId[messageId];
    if (pending == null) {
      return;
    }

    if (pending.attempts >= _meshMaxRetryAttempts) {
      _meshPendingByMessageId.remove(messageId);
      _pushNotification(
        kind: NotificationKind.system,
        title: 'Mesh доставка',
        description:
            'Не удалось подтвердить доставку сообщения в локальной сети.',
        showInSystem: false,
      );
      if (_meshPendingByMessageId.isEmpty) {
        _meshRetryTimer?.cancel();
        _meshRetryTimer = null;
      }
      _safeNotify();
      return;
    }

    final sent = await _meshTransport.sendText(
      messageId: pending.messageId,
      userId: _userId,
      userName: _userName,
      text: pending.text,
      createdAtIso: pending.createdAtIso,
      chatId: _primaryGroupChatId,
      replyTo: pending.replyTo,
    );
    if (!sent) {
      return;
    }

    pending.attempts = pending.attempts + 1;
    pending.lastAttemptAt = DateTime.now();
  }

  void _processMeshRetries() {
    if (isConnected) {
      _meshPendingByMessageId.clear();
    }
    if (_meshPendingByMessageId.isEmpty ||
        !_isMeshFallbackActive ||
        isConnected) {
      _meshRetryTimer?.cancel();
      _meshRetryTimer = null;
      return;
    }

    final now = DateTime.now();
    final pendingIds = _meshPendingByMessageId.keys.toList(growable: false);
    for (final messageId in pendingIds) {
      final pending = _meshPendingByMessageId[messageId];
      if (pending == null) {
        continue;
      }
      final lastAttemptAt = pending.lastAttemptAt;
      final shouldRetry =
          lastAttemptAt == null ||
          now.difference(lastAttemptAt) >= _meshRetryInterval;
      if (!shouldRetry) {
        continue;
      }
      unawaited(_sendMeshPendingMessage(messageId));
    }
  }

  void _scheduleReconnectIfNeeded() {
    if (_disposed || _manualDisconnectRequested || _userName.trim().isEmpty) {
      return;
    }
    if (_suppressReconnectScheduling) {
      return;
    }
    if (_reconnectTimer?.isActive ?? false) {
      return;
    }

    final maxPower = 4;
    final attempt = _reconnectAttempt > maxPower ? maxPower : _reconnectAttempt;
    final factor = 1 << attempt;
    final rawSeconds = _reconnectBaseDelay.inSeconds * factor;
    final delaySeconds = rawSeconds > _reconnectMaxDelay.inSeconds
        ? _reconnectMaxDelay.inSeconds
        : rawSeconds;
    final delay = Duration(seconds: delaySeconds);
    _reconnectAttempt = _reconnectAttempt + 1;
    if (_reconnectAttempt > maxPower + 1) {
      _reconnectAttempt = maxPower + 1;
    }

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || _manualDisconnectRequested || _userName.trim().isEmpty) {
        return;
      }
      unawaited(connect(force: true));
    });
  }

  void _cancelReconnect({bool resetAttempt = true}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (resetAttempt) {
      _reconnectAttempt = 0;
    }
  }

  Uri _attachmentUri(
    MessageAttachment attachment, {
    required bool forceDownload,
  }) {
    final path = attachment.path.trim();
    final parsed = Uri.tryParse(path);
    final resolved = parsed != null && parsed.hasScheme
        ? parsed
        : _httpBaseUriFromServer().replace(
            path: path.startsWith('/') ? path : '/$path',
          );

    if (!forceDownload) {
      return resolved;
    }
    final query = <String, String>{
      ...resolved.queryParameters,
      'download': '1',
      'name': attachment.name,
    };
    return resolved.replace(queryParameters: query);
  }

  Uri _httpBaseUriFromServer() {
    final wsUri = Uri.parse(_serverUrl);
    final scheme = wsUri.scheme == 'wss' ? 'https' : 'http';
    return Uri(
      scheme: scheme,
      host: wsUri.host,
      port: wsUri.hasPort ? wsUri.port : null,
    );
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
    if (kind != NotificationKind.message) {
      return;
    }

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
      _showSystemNotification(title: title, description: description);
    }
  }

  void _showSystemNotification({
    required String title,
    required String description,
  }) {
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
    final cleaned = Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
    return cleaned.toString();
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
        final updateSignature = '$latestVersion+$latestBuild';
        final isDismissed = _dismissedUpdateSignature == updateSignature;

        final isNewRelease =
            previousVersion != latestVersion || previousBuild != latestBuild;
        if (isNewRelease && !isDismissed) {
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

  Future<void> dismissUpdateBanner() async {
    final signature = _currentUpdateSignature;
    if (signature == null) {
      return;
    }
    _dismissedUpdateSignature = signature;
    _safeNotify();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedUpdateSignatureKey, signature);
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
    final uri = wsUri.replace(scheme: scheme, path: '/update-manifest');
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
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

  String? get _currentUpdateSignature {
    if (!_isUpdateAvailable || _latestVersion == null || _latestBuild == null) {
      return null;
    }
    return '${_latestVersion!}+${_latestBuild!}';
  }

  bool get _isUpdateDismissed {
    final current = _currentUpdateSignature;
    if (current == null) {
      return false;
    }
    return current == _dismissedUpdateSignature;
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
    _manualDisconnectRequested = true;
    _isSubscriptionFailoverRunning = false;
    _suppressReconnectScheduling = false;
    _meshFallbackTimer?.cancel();
    _meshFallbackTimer = null;
    _meshRetryTimer?.cancel();
    _meshRetryTimer = null;
    _subscriptionRefreshTimer?.cancel();
    _subscriptionRefreshTimer = null;
    _meshPendingByMessageId.clear();
    _cancelReconnect();
    _typingStopTimer?.cancel();
    _updateCheckTimer?.cancel();
    _sendTyping(isTyping: false);
    _disposeChannelResourcesWithoutAwait();
    unawaited(_meshTransport.stop());
    super.dispose();
  }
}

class _MeshPendingMessage {
  _MeshPendingMessage({
    required this.messageId,
    required this.text,
    required this.createdAtIso,
    this.replyTo,
  });

  final String messageId;
  final String text;
  final String createdAtIso;
  final Map<String, dynamic>? replyTo;
  int attempts = 0;
  DateTime? lastAttemptAt;
}

class _EncryptedTextPayload {
  const _EncryptedTextPayload({
    required this.cipherText,
    required this.nonceBase64,
    required this.method,
  });

  final String cipherText;
  final String nonceBase64;
  final String method;
}

class _ServerProbeResult {
  const _ServerProbeResult({
    required this.serverUrl,
    required this.latency,
    this.proxy,
  });

  final String serverUrl;
  final Duration? latency;
  final ProxyEndpoint? proxy;
}

class _FailoverPlan {
  const _FailoverPlan({required this.serverUrl, this.proxy});

  final String serverUrl;
  final ProxyEndpoint? proxy;
}
