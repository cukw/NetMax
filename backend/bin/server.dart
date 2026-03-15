import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String _authConfigRelativePath = 'config/authorized_users.json';
const String _updateManifestRelativePath = 'config/update_manifest.json';
const String _scheduledConfigRelativePath = 'config/scheduled_messages.json';
const Duration _scheduleTickInterval = Duration(seconds: 20);
const Duration _storageCleanupInterval = Duration(minutes: 30);
const Duration _storageFileMaxAge = Duration(days: 14);
const int _storageMaxBytes = 1024 * 1024 * 1024;
const Set<String> _scheduledRestrictedUsersLower = <String>{
  'юлия сергеевна',
  'татьяна владимировна',
};

final RoomState _group = RoomState();
final Random _random = Random();

late final Directory _storageDir;
late final List<String> _allowedUsers;
late final Map<String, String> _allowedUsersByLower;
late final Map<String, String> _passwordsByUserLower;
late final File _scheduledConfigFile;
final Map<String, ScheduledMessageRule> _scheduledRulesByUserLower =
    <String, ScheduledMessageRule>{};

// 0 = без ограничений
int _maxSessionsPerUser = 0;

Timer? _scheduledDispatchTimer;
Timer? _storageCleanupTimer;

Future<void> main() async {
  _storageDir = Directory(p.join(Directory.current.path, 'storage'));
  if (!_storageDir.existsSync()) {
    _storageDir.createSync(recursive: true);
  }

  _scheduledConfigFile = File(
    p.join(Directory.current.path, _scheduledConfigRelativePath),
  );

  _loadAuthorizedUsers();
  _loadScheduledRules();
  _startScheduledDispatcher();
  _cleanupStorage();
  _startStorageCleanup();

  final router = Router()
    ..get('/health', _healthHandler)
    ..get('/authorized-users', _authorizedUsersHandler)
    ..get('/scheduled-messages', _scheduledMessagesHandler)
    ..get('/update-manifest', _updateManifestHandler)
    ..get(
      '/ws',
      webSocketHandler(
        _handleSocket,
        pingInterval: const Duration(seconds: 20),
      ),
    );

  router.get('/files/<file|.*>', _filesHandler);

  final handler = Pipeline()
      .addMiddleware(_cors())
      .addMiddleware(logRequests())
      .addHandler(router.call);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);

  stdout.writeln(
    'NetMax backend is running on http://${server.address.host}:${server.port}',
  );
  stdout.writeln('WebSocket endpoint: ws://<host>:${server.port}/ws');
  stdout.writeln('Files endpoint: http://<host>:${server.port}/files/<file>');
  stdout.writeln('Authorized users loaded: ${_allowedUsers.length}');
  stdout.writeln(
    'Session limit per user: '
    '${_maxSessionsPerUser == 0 ? "unlimited" : _maxSessionsPerUser.toString()}',
  );
  stdout.writeln(
    'Scheduled rules loaded: ${_scheduledRulesByUserLower.length}',
  );
  stdout.writeln(
    'Storage cleanup: every ${_storageCleanupInterval.inMinutes}m, '
    'max age ${_storageFileMaxAge.inDays}d, max size '
    '${(_storageMaxBytes / (1024 * 1024)).round()} MB',
  );
}

void _loadAuthorizedUsers() {
  final configFile = File(
    p.join(Directory.current.path, _authConfigRelativePath),
  );
  if (!configFile.existsSync()) {
    throw StateError(
      'Authorization config not found: ${configFile.path}. '
      'Create $_authConfigRelativePath with allowedUsers list containing '
      '{"name","password"} entries.',
    );
  }

  final raw = configFile.readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw StateError(
      'Invalid authorization config format. Expected JSON object.',
    );
  }

  // подгрузка лимита сессий
  final maxSessions = _toInt(decoded['maxSessionsPerUser']);
  _maxSessionsPerUser = (maxSessions != null && maxSessions >= 0)
      ? maxSessions
      : 0;

  final usersRaw = decoded['allowedUsers'];
  if (usersRaw is! List) {
    throw StateError(
      'Invalid authorization config: "allowedUsers" must be a list.',
    );
  }

  final users = <String>[];
  final usersByLower = <String, String>{};
  final passwordsByLower = <String, String>{};

  for (final rawUser in usersRaw) {
    final map = _asMap(rawUser);
    final name = (map['name']?.toString() ?? '').trim();
    final password = (map['password']?.toString() ?? '').trim();

    if (name.isEmpty) {
      throw StateError(
        'Invalid authorization config: each user must contain non-empty "name".',
      );
    }
    if (password.isEmpty) {
      throw StateError('Password is empty for user "$name".');
    }

    final lower = name.toLowerCase();
    if (usersByLower.containsKey(lower)) {
      throw StateError('Duplicate user in authorization config: "$name".');
    }

    usersByLower[lower] = name;
    passwordsByLower[lower] = password;
    users.add(name);
  }

  users.sort();

  if (users.isEmpty) {
    throw StateError('Authorization config must contain at least one user.');
  }

  _allowedUsers = List<String>.unmodifiable(users);
  _allowedUsersByLower = Map<String, String>.unmodifiable(usersByLower);
  _passwordsByUserLower = Map<String, String>.unmodifiable(passwordsByLower);
}

void _loadScheduledRules() {
  if (!_scheduledConfigFile.existsSync()) {
    _scheduledConfigFile.createSync(recursive: true);
    _scheduledConfigFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({'schedules': <Object>[]}),
    );
  }

  try {
    final decoded = jsonDecode(_scheduledConfigFile.readAsStringSync());
    final root = _asMap(decoded);
    final rawSchedules = root['schedules'];
    var droppedInvalidRule = false;

    _scheduledRulesByUserLower.clear();
    if (rawSchedules is List) {
      for (final item in rawSchedules) {
        final map = _asMap(item);
        final rule = ScheduledMessageRule.fromJson(map);
        if (rule == null) {
          continue;
        }

        final authorizedName =
            _allowedUsersByLower[rule.userName.toLowerCase()];
        if (authorizedName == null) {
          droppedInvalidRule = true;
          continue;
        }

        if (!_isScheduledAllowedForUser(authorizedName)) {
          droppedInvalidRule = true;
          continue;
        }

        final normalized = rule.copyWith(userName: authorizedName);
        _scheduledRulesByUserLower[authorizedName.toLowerCase()] = normalized;
      }
    }
    if (droppedInvalidRule) {
      _saveScheduledRules();
    }
  } catch (_) {
    _scheduledRulesByUserLower.clear();
    _saveScheduledRules();
  }
}

void _saveScheduledRules() {
  final schedules = _scheduledRulesByUserLower.values.toList()
    ..sort((a, b) => a.userName.compareTo(b.userName));

  final payload = {
    'schedules': schedules.map((rule) => rule.toJson()).toList(),
  };
  _scheduledConfigFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
}

void _startScheduledDispatcher() {
  _scheduledDispatchTimer?.cancel();
  _scheduledDispatchTimer = Timer.periodic(_scheduleTickInterval, (_) {
    _dispatchScheduledMessages();
  });
}

void _startStorageCleanup() {
  _storageCleanupTimer?.cancel();
  _storageCleanupTimer = Timer.periodic(_storageCleanupInterval, (_) {
    _cleanupStorage();
  });
}

void _cleanupStorage() {
  final now = DateTime.now();
  final entries = _listStorageFiles();

  var activeTotalBytes = 0;
  var deletedFiles = 0;
  var freedBytes = 0;

  final active = <_StorageFileRecord>[];

  for (final entry in entries) {
    final age = now.difference(entry.modifiedAt);
    if (age > _storageFileMaxAge) {
      if (_deleteStorageFile(entry.file)) {
        deletedFiles++;
        freedBytes += entry.sizeBytes;
      }
      continue;
    }

    active.add(entry);
    activeTotalBytes += entry.sizeBytes;
  }

  if (activeTotalBytes > _storageMaxBytes) {
    active.sort((a, b) => a.modifiedAt.compareTo(b.modifiedAt));
    for (final entry in active) {
      if (activeTotalBytes <= _storageMaxBytes) {
        break;
      }
      if (_deleteStorageFile(entry.file)) {
        deletedFiles++;
        freedBytes += entry.sizeBytes;
        activeTotalBytes -= entry.sizeBytes;
      }
    }
  }

  if (deletedFiles > 0) {
    stdout.writeln(
      'Storage cleanup removed $deletedFiles file(s), '
      'freed ${(freedBytes / (1024 * 1024)).toStringAsFixed(2)} MB.',
    );
  }
}

List<_StorageFileRecord> _listStorageFiles() {
  final files = <_StorageFileRecord>[];
  final entries = _storageDir.listSync(followLinks: false);

  for (final entity in entries) {
    if (entity is! File) {
      continue;
    }

    try {
      final stat = entity.statSync();
      if (stat.type != FileSystemEntityType.file) {
        continue;
      }
      files.add(
        _StorageFileRecord(
          file: entity,
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    } catch (_) {
      // Best effort: inaccessible file will be skipped.
    }
  }

  return files;
}

bool _deleteStorageFile(File file) {
  try {
    if (!file.existsSync()) {
      return false;
    }
    file.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

void _dispatchScheduledMessages() {
  if (_scheduledRulesByUserLower.isEmpty) {
    return;
  }

  var changed = false;
  final nowUtc = DateTime.now().toUtc();

  for (final key in _scheduledRulesByUserLower.keys.toList(growable: false)) {
    final rule = _scheduledRulesByUserLower[key];
    if (rule == null || !rule.enabled) {
      continue;
    }

    if (!_isScheduledAllowedForUser(rule.userName)) {
      _scheduledRulesByUserLower.remove(key);
      changed = true;
      continue;
    }

    final text = rule.text.trim();
    if (text.isEmpty) {
      continue;
    }

    final localNow = nowUtc.add(Duration(minutes: rule.timezoneOffsetMinutes));
    final localDate = _formatDate(localNow);
    final localTime = _formatHm(localNow);

    if (localTime != rule.time || localDate == rule.lastSentDate) {
      continue;
    }

    final senderId =
        _findOnlineUserIdByName(rule.userName) ??
        'scheduled-${_safeIdentity(rule.userName)}';

    final message = <String, dynamic>{
      'id': _normalizeMessageId(null),
      'senderId': senderId,
      'senderName': rule.userName,
      'createdAt': nowUtc.toIso8601String(),
      'type': 'text',
      'text': text,
      'scheduled': true,
    };

    _appendMessage(message);
    _broadcast(type: 'message', payload: message);

    _scheduledRulesByUserLower[key] = rule.copyWith(
      lastSentDate: localDate,
      updatedAt: nowUtc.toIso8601String(),
    );
    changed = true;
  }

  if (changed) {
    _saveScheduledRules();
  }
}

// кол-во сессий пользака
int _sessionCountForUser(String userNameLower) {
  return _group.userNames.values
      .where((n) => n.toLowerCase() == userNameLower)
      .length;
}

// уник список пользаков
List<Map<String, dynamic>> _deduplicatedOnlineUsers() {
  final seen = <String>{};
  final result = <Map<String, dynamic>>[];
  for (final entry in _group.userNames.entries) {
    final nameLower = entry.value.toLowerCase();
    if (seen.add(nameLower)) {
      result.add({'id': entry.key, 'name': entry.value});
    }
  }
  return result;
}

String? _findOnlineUserIdByName(String userName) {
  final expected = userName.toLowerCase();
  for (final entry in _group.userNames.entries) {
    if (entry.value.toLowerCase() == expected) {
      return entry.key;
    }
  }
  return null;
}

Response _healthHandler(Request request) {
  final updateManifestFile = File(
    p.join(Directory.current.path, _updateManifestRelativePath),
  );

  final enabledRules = _scheduledRulesByUserLower.values
      .where((rule) => rule.enabled)
      .length;

  return _json({
    'status': 'ok',
    'onlineUsers': _group.clients.length,
    'uniqueOnlineUsers': _deduplicatedOnlineUsers().length,
    'authorizedUsers': _allowedUsers.length,
    'maxSessionsPerUser': _maxSessionsPerUser,
    'updateManifestAvailable': updateManifestFile.existsSync(),
    'scheduledRules': _scheduledRulesByUserLower.length,
    'scheduledEnabled': enabledRules,
    'messagesInMemory': _group.messages.length,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
  });
}

Response _authorizedUsersHandler(Request request) {
  return _json({'count': _allowedUsers.length, 'users': _allowedUsers});
}

Response _scheduledMessagesHandler(Request request) {
  final schedules = _scheduledRulesByUserLower.values.toList()
    ..sort((a, b) => a.userName.compareTo(b.userName));

  return _json({
    'count': schedules.length,
    'schedules': schedules.map((rule) => rule.toJson()).toList(),
  });
}

Response _updateManifestHandler(Request request) {
  final manifestFile = File(
    p.join(Directory.current.path, _updateManifestRelativePath),
  );

  if (!manifestFile.existsSync()) {
    return _json({
      'error': 'Update manifest not found.',
      'path': _updateManifestRelativePath,
    }, statusCode: 404);
  }

  try {
    final decoded = jsonDecode(manifestFile.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      return _json({
        'error': 'Invalid update manifest format.',
      }, statusCode: 500);
    }
    return _json(decoded);
  } catch (_) {
    return _json({'error': 'Unable to read update manifest.'}, statusCode: 500);
  }
}

Response _filesHandler(Request request, String file) {
  final normalized = p.normalize(file).replaceAll('\\', '/').trim();
  final isUnsafePath =
      normalized.isEmpty ||
      normalized == '.' ||
      normalized.startsWith('..') ||
      normalized.contains('/..');
  if (isUnsafePath) {
    return _json({'error': 'Invalid file path.'}, statusCode: 400);
  }

  final target = File(p.join(_storageDir.path, normalized));
  if (!target.existsSync()) {
    return _json({'error': 'File not found.'}, statusCode: 404);
  }

  FileStat stat;
  try {
    stat = target.statSync();
  } catch (_) {
    return _json({'error': 'Unable to read file metadata.'}, statusCode: 500);
  }

  if (stat.type != FileSystemEntityType.file) {
    return _json({'error': 'File not found.'}, statusCode: 404);
  }

  final downloadFlag = request.url.queryParameters['download']?.trim();
  final forceDownload = downloadFlag == '1' || downloadFlag == 'true';
  final requestedName = request.url.queryParameters['name']?.trim() ?? '';
  final fallbackName = p.basename(normalized);
  final downloadName = _safeDownloadName(
    requestedName.isEmpty ? fallbackName : requestedName,
  );

  final headers = <String, String>{
    HttpHeaders.contentTypeHeader: 'application/octet-stream',
    HttpHeaders.contentLengthHeader: stat.size.toString(),
  };
  if (forceDownload) {
    headers['content-disposition'] = 'attachment; filename="$downloadName"';
  }

  return Response.ok(target.openRead(), headers: headers);
}

void _handleSocket(WebSocketChannel channel, String? protocol) {
  String? userId;
  String? userName;
  var joined = false;

  late final StreamSubscription<dynamic> subscription;
  subscription = channel.stream.listen(
    (dynamic rawData) {
      try {
        if (rawData is! String) {
          _sendEnvelope(
            channel,
            type: 'error',
            payload: {'message': 'Unsupported payload type.'},
          );
          return;
        }

        final decoded = jsonDecode(rawData);
        if (decoded is! Map<String, dynamic>) {
          _sendEnvelope(
            channel,
            type: 'error',
            payload: {'message': 'Invalid envelope.'},
          );
          return;
        }

        final type = decoded['type']?.toString() ?? '';
        final payload = _asMap(decoded['payload']);

        switch (type) {
          case 'join':
            final requestedName = _normalizeUserName(payload['userName']);
            if (requestedName.isEmpty) {
              _denyAndClose(
                channel,
                'Авторизация отклонена: укажите имя пользователя.',
              );
              return;
            }

            final authorizedName =
                _allowedUsersByLower[requestedName.toLowerCase()];
            if (authorizedName == null) {
              _denyAndClose(
                channel,
                'Авторизация отклонена: пользователь "$requestedName" не в списке.',
              );
              return;
            }

            final providedPassword = (payload['password']?.toString() ?? '')
                .trim();
            if (providedPassword.isEmpty) {
              _denyAndClose(
                channel,
                'Авторизация отклонена: пароль обязателен.',
              );
              return;
            }
            final expectedPassword =
                _passwordsByUserLower[authorizedName.toLowerCase()];
            if (expectedPassword == null ||
                expectedPassword != providedPassword) {
              _denyAndClose(channel, 'Авторизация отклонена: неверный пароль.');
              return;
            }

            // проверка лимита кол-ва сессий | _maxSessionsPerUser = 0 = без ограничений
            final currentSessions = _sessionCountForUser(
              authorizedName.toLowerCase(),
            );
            if (_maxSessionsPerUser > 0 &&
                currentSessions >= _maxSessionsPerUser) {
              _denyAndClose(
                channel,
                'Лимит сессий для "$authorizedName" '
                '(макс: $_maxSessionsPerUser).',
              );
              return;
            }

            final isFirstSession = currentSessions == 0;
            userId = _createConnectionUserId();
            userName = authorizedName;

            _group.clients[userId!] = channel;
            _group.userNames[userId!] = userName!;
            joined = true;

            _sendEnvelope(
              channel,
              type: 'auth_ok',
              payload: {'userId': userId, 'userName': userName},
            );

            // список уникальных пользаков
            _sendEnvelope(
              channel,
              type: 'snapshot',
              payload: {
                'onlineUsers': _deduplicatedOnlineUsers(),
                'messages': _group.messages,
              },
            );

            _sendScheduledConfig(channel: channel, userName: userName!);

            // уведа при первом конекте, я бы вообще нахуй дропнул уведы о коннекте если честнро но думай сам
            if (isFirstSession) {
              _broadcast(
                type: 'presence',
                payload: {
                  'userId': userId,
                  'userName': userName,
                  'isOnline': true,
                },
                exceptUserId: userId,
              );
            }
            break;

          case 'message':
            if (!joined || userId == null || userName == null) {
              return;
            }

            final text = (payload['text']?.toString() ?? '').trim();
            if (text.isEmpty) {
              return;
            }

            final message = <String, dynamic>{
              'id': _normalizeMessageId(payload['id']),
              'senderId': userId,
              'senderName': userName,
              'createdAt': _normalizeIsoTimestamp(payload['createdAt']),
              'type': 'text',
              'text': text,
              'scheduled': false,
            };

            _appendMessage(message);
            _broadcast(type: 'message', payload: message);
            break;

          case 'typing':
            if (!joined || userId == null || userName == null) {
              return;
            }

            final isTyping = payload['isTyping'] == true;
            _broadcast(
              type: 'typing',
              payload: {
                'userId': userId,
                'userName': userName,
                'isTyping': isTyping,
              },
              exceptUserId: userId,
            );
            break;

          case 'file':
            if (!joined || userId == null || userName == null) {
              return;
            }
            _handleFileMessage(
              channel: channel,
              userId: userId!,
              userName: userName!,
              payload: payload,
            );
            break;

          case 'scheduled_config_get':
            if (!joined || userName == null) {
              return;
            }
            _sendScheduledConfig(channel: channel, userName: userName!);
            break;

          case 'scheduled_config_set':
            if (!joined || userName == null) {
              return;
            }
            _handleScheduledConfigSet(
              channel: channel,
              userName: userName!,
              payload: payload,
            );
            break;

          default:
            _sendEnvelope(
              channel,
              type: 'error',
              payload: {'message': 'Unknown event type: $type'},
            );
        }
      } catch (_) {
        _sendEnvelope(
          channel,
          type: 'error',
          payload: {'message': 'Invalid JSON format.'},
        );
      }
    },
    onError: (_) =>
        _cleanupConnection(userId: userId, userName: userName, joined: joined),
    onDone: () =>
        _cleanupConnection(userId: userId, userName: userName, joined: joined),
    cancelOnError: true,
  );

  channel.sink.done.whenComplete(() => subscription.cancel());
}

void _handleFileMessage({
  required WebSocketChannel channel,
  required String userId,
  required String userName,
  required Map<String, dynamic> payload,
}) {
  final fileName = (payload['name']?.toString() ?? '').trim();
  final base64Content = payload['contentBase64']?.toString() ?? '';

  if (fileName.isEmpty || base64Content.isEmpty) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'File name or file data is empty.'},
    );
    return;
  }

  List<int> bytes;
  try {
    bytes = base64Decode(base64Content);
  } catch (_) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Invalid file data.'},
    );
    return;
  }

  const maxFileSize = 20 * 1024 * 1024;
  if (bytes.length > maxFileSize) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'File too large. Max size is 20 MB.'},
    );
    return;
  }

  final extension = _normalizeExtension(payload['extension'], fileName);
  final safeName = _safeFileName(fileName);
  final storedName =
      '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(100000)}_$safeName';
  final targetPath = p.join(_storageDir.path, storedName);

  File(targetPath).writeAsBytesSync(bytes);
  _cleanupStorage();

  final message = <String, dynamic>{
    'id': _normalizeMessageId(payload['id']),
    'senderId': userId,
    'senderName': userName,
    'createdAt': _normalizeIsoTimestamp(payload['createdAt']),
    'type': 'file',
    'text': (payload['text']?.toString() ?? 'Отправлен файл').trim(),
    'scheduled': false,
    'attachment': {
      'name': fileName,
      'path': '/files/$storedName',
      'sizeBytes': bytes.length,
      'extension': extension,
    },
  };

  _appendMessage(message);
  _broadcast(type: 'message', payload: message);
}

void _handleScheduledConfigSet({
  required WebSocketChannel channel,
  required String userName,
  required Map<String, dynamic> payload,
}) {
  if (!_isScheduledAllowedForUser(userName)) {
    final removed = _scheduledRulesByUserLower.remove(userName.toLowerCase());
    if (removed != null) {
      _saveScheduledRules();
    }
    _sendScheduledConfig(channel: channel, userName: userName);
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {
        'message':
            'Для пользователя "$userName" отправка по времени отключена.',
      },
    );
    return;
  }

  final enabled = payload['enabled'] == true;
  final text = (payload['text']?.toString() ?? '').trim();
  final time = _normalizeScheduleTime(payload['time']) ?? '09:00';
  final timezoneOffsetMinutes = _clampTimezoneOffset(
    _toInt(payload['timezoneOffsetMinutes']) ?? 0,
  );

  if (enabled && text.isEmpty) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Введите текст для отправки по времени.'},
    );
    return;
  }

  if (enabled && _normalizeScheduleTime(payload['time']) == null) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Укажите время в формате HH:mm.'},
    );
    return;
  }

  final key = userName.toLowerCase();
  final current = _scheduledRulesByUserLower[key];
  final normalizedText = text;
  final normalizedTime = time;

  final resetLastDate =
      current == null ||
      current.time != normalizedTime ||
      current.text != normalizedText ||
      current.timezoneOffsetMinutes != timezoneOffsetMinutes ||
      current.enabled != enabled;

  _scheduledRulesByUserLower[key] = ScheduledMessageRule(
    userName: userName,
    enabled: enabled,
    text: normalizedText,
    time: normalizedTime,
    timezoneOffsetMinutes: timezoneOffsetMinutes,
    lastSentDate: resetLastDate ? null : current.lastSentDate,
    updatedAt: DateTime.now().toUtc().toIso8601String(),
  );

  _saveScheduledRules();

  _sendScheduledConfig(channel: channel, userName: userName);
}

void _sendScheduledConfig({
  required WebSocketChannel channel,
  required String userName,
}) {
  final isAllowed = _isScheduledAllowedForUser(userName);
  final rule = isAllowed
      ? _scheduledRulesByUserLower[userName.toLowerCase()]
      : null;

  _sendEnvelope(
    channel,
    type: 'scheduled_config',
    payload: {
      'userName': userName,
      'allowed': isAllowed,
      'enabled': rule?.enabled ?? false,
      'text': rule?.text ?? '',
      'time': rule?.time ?? '09:00',
      'timezoneOffsetMinutes': rule?.timezoneOffsetMinutes ?? 0,
      'lastSentDate': rule?.lastSentDate,
      'updatedAt': rule?.updatedAt,
    },
  );
}

void _cleanupConnection({
  required String? userId,
  required String? userName,
  required bool joined,
}) {
  if (!joined || userId == null || userName == null) {
    return;
  }

  _group.clients.remove(userId);
  _group.userNames.remove(userId);

  // проверка на наличия другихз сессии
  final hasOtherSessions = _group.userNames.values.any(
    (n) => n.toLowerCase() == userName.toLowerCase(),
  );
  // уведа если все сессии отключились
  if (!hasOtherSessions) {
    _broadcast(
      type: 'presence',
      payload: {'userId': userId, 'userName': userName, 'isOnline': false},
    );
  }

  _broadcast(
    type: 'typing',
    payload: {'userId': userId, 'userName': userName, 'isTyping': false},
  );
}

void _appendMessage(Map<String, dynamic> message) {
  _group.messages.add(message);

  const maxHistory = 200;
  if (_group.messages.length > maxHistory) {
    _group.messages.removeRange(0, _group.messages.length - maxHistory);
  }
}

void _broadcast({
  required String type,
  required Map<String, dynamic> payload,
  String? exceptUserId,
}) {
  final envelope = jsonEncode({'type': type, 'payload': payload});
  final staleUsers = <String>[];

  _group.clients.forEach((userKey, socket) {
    if (exceptUserId != null && userKey == exceptUserId) {
      return;
    }
    try {
      socket.sink.add(envelope);
    } catch (_) {
      staleUsers.add(userKey);
    }
  });

  for (final staleUser in staleUsers) {
    _group.clients.remove(staleUser);
    _group.userNames.remove(staleUser);
  }
}

void _sendEnvelope(
  WebSocketChannel channel, {
  required String type,
  required Map<String, dynamic> payload,
}) {
  channel.sink.add(jsonEncode({'type': type, 'payload': payload}));
}

void _denyAndClose(WebSocketChannel channel, String reason) {
  _sendEnvelope(channel, type: 'error', payload: {'message': reason});
  channel.sink.close(WebSocketStatus.policyViolation, reason);
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

String _createConnectionUserId() {
  return '${DateTime.now().millisecondsSinceEpoch}-${_random.nextInt(99999)}';
}

String _normalizeUserName(Object? value) {
  return (value?.toString() ?? '').trim();
}

String _normalizeMessageId(Object? value) {
  final id = (value?.toString() ?? '').trim();
  if (id.isNotEmpty) {
    return id;
  }
  return '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(9999)}';
}

String _normalizeIsoTimestamp(Object? value) {
  final text = (value?.toString() ?? '').trim();
  final parsed = DateTime.tryParse(text);
  return (parsed ?? DateTime.now()).toUtc().toIso8601String();
}

String _normalizeExtension(Object? value, String fileName) {
  final fromPayload = (value?.toString() ?? '').replaceFirst('.', '').trim();
  if (fromPayload.isNotEmpty) {
    return fromPayload.toUpperCase();
  }

  final ext = p.extension(fileName).replaceFirst('.', '').trim();
  if (ext.isEmpty) {
    return 'FILE';
  }
  return ext.toUpperCase();
}

String _safeFileName(String original) {
  final baseName = p.basename(original);
  final safe = baseName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  if (safe.isEmpty) {
    return 'file.bin';
  }
  return safe;
}

String _safeDownloadName(String original) {
  final baseName = p.basename(original);
  final sanitized = baseName
      .replaceAll(RegExp(r'[\r\n"]'), '')
      .replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_')
      .trim();
  if (sanitized.isEmpty) {
    return 'file.bin';
  }
  return sanitized;
}

String _safeIdentity(String raw) {
  final safe = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  if (safe.isEmpty) {
    return 'user';
  }
  return safe;
}

String? _normalizeScheduleTime(Object? value) {
  final text = (value?.toString() ?? '').trim();
  final match = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$').firstMatch(text);
  if (match == null) {
    return null;
  }

  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

int _clampTimezoneOffset(int value) {
  if (value < -840) {
    return -840;
  }
  if (value > 840) {
    return 840;
  }
  return value;
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

String _formatDate(DateTime dateTime) {
  final year = dateTime.year.toString().padLeft(4, '0');
  final month = dateTime.month.toString().padLeft(2, '0');
  final day = dateTime.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

String _formatHm(DateTime dateTime) {
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

bool _isScheduledAllowedForUser(String userName) {
  return !_scheduledRestrictedUsersLower.contains(
    userName.trim().toLowerCase(),
  );
}

Middleware _cors() {
  const corsHeaders = <String, String>{
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers':
        'Origin, Content-Type, Accept, Authorization',
  };

  return (Handler inner) {
    return (Request request) async {
      if (request.method.toUpperCase() == 'OPTIONS') {
        return Response.ok('', headers: corsHeaders);
      }

      final response = await inner(request);
      return response.change(
        headers: <String, String>{...response.headers, ...corsHeaders},
      );
    };
  };
}

Response _json(Map<String, dynamic> data, {int statusCode = 200}) {
  return Response(
    statusCode,
    body: jsonEncode(data),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

class RoomState {
  final Map<String, WebSocketChannel> clients = <String, WebSocketChannel>{};
  final Map<String, String> userNames = <String, String>{};
  final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[];
}

class _StorageFileRecord {
  const _StorageFileRecord({
    required this.file,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final File file;
  final int sizeBytes;
  final DateTime modifiedAt;
}

class ScheduledMessageRule {
  const ScheduledMessageRule({
    required this.userName,
    required this.enabled,
    required this.text,
    required this.time,
    required this.timezoneOffsetMinutes,
    this.lastSentDate,
    this.updatedAt,
  });

  final String userName;
  final bool enabled;
  final String text;
  final String time;
  final int timezoneOffsetMinutes;
  final String? lastSentDate;
  final String? updatedAt;

  ScheduledMessageRule copyWith({
    String? userName,
    bool? enabled,
    String? text,
    String? time,
    int? timezoneOffsetMinutes,
    String? lastSentDate,
    String? updatedAt,
  }) {
    return ScheduledMessageRule(
      userName: userName ?? this.userName,
      enabled: enabled ?? this.enabled,
      text: text ?? this.text,
      time: time ?? this.time,
      timezoneOffsetMinutes:
          timezoneOffsetMinutes ?? this.timezoneOffsetMinutes,
      lastSentDate: lastSentDate,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userName': userName,
      'enabled': enabled,
      'text': text,
      'time': time,
      'timezoneOffsetMinutes': timezoneOffsetMinutes,
      'lastSentDate': lastSentDate,
      'updatedAt': updatedAt,
    };
  }

  static ScheduledMessageRule? fromJson(Map<String, dynamic> json) {
    final userName = (json['userName']?.toString() ?? '').trim();
    final time = _normalizeScheduleTime(json['time']);
    if (userName.isEmpty || time == null) {
      return null;
    }

    final text = (json['text']?.toString() ?? '').trim();
    final enabled = json['enabled'] == true;
    final timezoneOffsetMinutes = _clampTimezoneOffset(
      _toInt(json['timezoneOffsetMinutes']) ?? 0,
    );
    final lastSentDate = (json['lastSentDate']?.toString() ?? '').trim();
    final updatedAt = (json['updatedAt']?.toString() ?? '').trim();

    return ScheduledMessageRule(
      userName: userName,
      enabled: enabled,
      text: text,
      time: time,
      timezoneOffsetMinutes: timezoneOffsetMinutes,
      lastSentDate: lastSentDate.isEmpty ? null : lastSentDate,
      updatedAt: updatedAt.isEmpty ? null : updatedAt,
    );
  }
}
