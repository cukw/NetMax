// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mongo_dart/mongo_dart.dart' as mongo;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:web_socket_channel/web_socket_channel.dart';

const String _authConfigRelativePath = 'config/authorized_users.json';
const String _usersDbRelativePath = 'config/users.sqlite3';
const String _updateManifestRelativePath = 'config/update_manifest.json';
const String _scheduledConfigRelativePath = 'config/scheduled_messages.json';
const String _groupChatsConfigRelativePath = 'config/group_chats.json';
const String _messagesDbRelativePath = 'config/messages_history.sqlite3';
const String _messagesConfigRelativePath = 'config/messages_history.json';
const String _e2eeKeyConfigRelativePath = 'config/e2ee_shared_key.txt';
const String _mongoUriEnv = 'NETMAX_MONGO_URI';
const String _defaultMongoUri = 'mongodb://127.0.0.1:27017/netmax';
const Duration _scheduleTickInterval = Duration(seconds: 20);
const Duration _storageCleanupInterval = Duration(minutes: 30);
const Duration _storageFileMaxAge = Duration(days: 14);
const int _storageMaxBytes = 1024 * 1024 * 1024;
final int _maxHistoryMessages = _readPositiveIntFromEnv(
  'NETMAX_HISTORY_LIMIT',
  fallback: 10000,
);
const String _defaultGroupChatId = 'group-general';
const String _defaultGroupChatTitle = 'Общий чат';
const Set<String> _scheduledRestrictedUsersLower = <String>{
  'юлия сергеевна',
  'татьяна владимировна',
};

final RoomState _group = RoomState();
final Random _random = Random();

late final List<String> _allowedUsers;
late final Map<String, String> _allowedUsersByLower;
late final Map<String, String> _passwordsByUserLower;
late final String _serverManagedE2eeKey;
late final String _serverManagedE2eeKeySource;
late final File _e2eeKeyFile;
late final File _usersDbFile;
late final sqlite.Database _usersDb;
late final File _scheduledConfigFile;
late final File _groupChatsConfigFile;
late final File _messagesLegacyConfigFile;
late final File _messagesDbFile;
late final sqlite.Database _messagesDb;
late final mongo.Db _mongoDb;
late final mongo.DbCollection _mongoMessagesCollection;
late final mongo.DbCollection _mongoFilesCollection;
late final mongo.DbCollection _mongoChatsCollection;
late final mongo.GridFS _mongoGridFs;
final Map<String, ScheduledMessageRule> _scheduledRulesByUserLower =
    <String, ScheduledMessageRule>{};
final Map<String, String> _groupChatTitlesById = <String, String>{};

// 0 = без ограничений
int _maxSessionsPerUser = 0;

Timer? _scheduledDispatchTimer;
Timer? _storageCleanupTimer;

Future<void> main() async {
  _usersDbFile = File(p.join(Directory.current.path, _usersDbRelativePath));
  _scheduledConfigFile = File(
    p.join(Directory.current.path, _scheduledConfigRelativePath),
  );
  _groupChatsConfigFile = File(
    p.join(Directory.current.path, _groupChatsConfigRelativePath),
  );
  _messagesLegacyConfigFile = File(
    p.join(Directory.current.path, _messagesConfigRelativePath),
  );
  _messagesDbFile = File(
    p.join(Directory.current.path, _messagesDbRelativePath),
  );
  _e2eeKeyFile = File(
    p.join(Directory.current.path, _e2eeKeyConfigRelativePath),
  );

  _loadServerManagedE2eeKey();
  await _initializeNoSqlStore();
  _loadAuthorizedUsers();
  await _loadGroupChats();
  await _initializeMessageStore();
  _loadScheduledRules();
  _startScheduledDispatcher();
  _cleanupStorage();
  _startStorageCleanup();

  final router = Router()
    ..get('/health', _healthHandler)
    ..get('/authorized-users', _authorizedUsersHandler)
    ..get('/chats', _chatsHandler)
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
  stdout.writeln('Group chats loaded: ${_groupChatTitlesById.length}');
  stdout.writeln('Messages loaded: ${_group.messages.length}');
  stdout.writeln('History limit: $_maxHistoryMessages');
  stdout.writeln('NoSQL backend: MongoDB (${_mongoDb.databaseName})');
  stdout.writeln('E2EE key source: $_serverManagedE2eeKeySource');
  stdout.writeln(
    'Storage cleanup: every ${_storageCleanupInterval.inMinutes}m, '
    'max age ${_storageFileMaxAge.inDays}d, max size '
    '${(_storageMaxBytes / (1024 * 1024)).round()} MB',
  );
}

void _loadAuthorizedUsers() {
  _usersDbFile.parent.createSync(recursive: true);
  _usersDb = sqlite.sqlite3.open(_usersDbFile.path);
  _usersDb.execute('PRAGMA journal_mode = WAL;');
  _usersDb.execute('PRAGMA synchronous = NORMAL;');
  _usersDb.execute('''
    CREATE TABLE IF NOT EXISTS users (
      name_lower TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      password TEXT NOT NULL
    )
  ''');

  final configFile = File(
    p.join(Directory.current.path, _authConfigRelativePath),
  );
  Map<String, dynamic> decoded = <String, dynamic>{};
  if (configFile.existsSync()) {
    final raw = configFile.readAsStringSync();
    final parsed = jsonDecode(raw);
    if (parsed is! Map<String, dynamic>) {
      throw StateError(
        'Invalid authorization config format. Expected JSON object.',
      );
    }
    decoded = parsed;
  }

  final maxSessions = _toInt(decoded['maxSessionsPerUser']);
  _maxSessionsPerUser = (maxSessions != null && maxSessions >= 0)
      ? maxSessions
      : 0;

  final usersRaw = decoded['allowedUsers'];
  final seedUsers = usersRaw is List ? usersRaw : const <Object>[];

  final users = <String>[];
  final usersByLower = <String, String>{};
  final passwordsByLower = <String, String>{};

  for (final rawUser in seedUsers) {
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

  final rows = _usersDb.select('SELECT COUNT(*) AS c FROM users');
  final existingUsersCount = rows.isEmpty
      ? 0
      : ((rows.first['c'] as num?)?.toInt() ?? 0);
  if (existingUsersCount == 0 && users.isNotEmpty) {
    final insert = _usersDb.prepare(
      'INSERT INTO users (name_lower, name, password) VALUES (?, ?, ?)',
    );
    try {
      for (final entry in usersByLower.entries) {
        insert.execute(<Object?>[
          entry.key,
          entry.value,
          passwordsByLower[entry.key] ?? '',
        ]);
      }
    } finally {
      insert.dispose();
    }
  }

  final persisted = _usersDb.select(
    'SELECT name_lower, name, password FROM users ORDER BY name COLLATE NOCASE ASC',
  );

  users
    ..clear()
    ..addAll(
      persisted
          .map((row) => (row['name']?.toString() ?? '').trim())
          .where((name) => name.isNotEmpty),
    );
  usersByLower
    ..clear()
    ..addEntries(
      persisted
          .map((row) {
            final lower = (row['name_lower']?.toString() ?? '')
                .trim()
                .toLowerCase();
            final name = (row['name']?.toString() ?? '').trim();
            return MapEntry(lower, name);
          })
          .where((entry) => entry.key.isNotEmpty && entry.value.isNotEmpty),
    );
  passwordsByLower
    ..clear()
    ..addEntries(
      persisted
          .map((row) {
            final lower = (row['name_lower']?.toString() ?? '')
                .trim()
                .toLowerCase();
            final password = (row['password']?.toString() ?? '').trim();
            return MapEntry(lower, password);
          })
          .where((entry) => entry.key.isNotEmpty && entry.value.isNotEmpty),
    );

  if (users.isEmpty) {
    throw StateError(
      'Users store is empty. Add users to SQLite ($_usersDbRelativePath) '
      'or define allowedUsers in $_authConfigRelativePath for bootstrap.',
    );
  }

  _allowedUsers = List<String>.unmodifiable(users);
  _allowedUsersByLower = Map<String, String>.unmodifiable(usersByLower);
  _passwordsByUserLower = Map<String, String>.unmodifiable(passwordsByLower);
}

Future<void> _initializeNoSqlStore() async {
  var uri = (Platform.environment[_mongoUriEnv] ?? _defaultMongoUri).trim();
  if (uri.isEmpty) {
    uri = _defaultMongoUri;
  }

  _mongoDb = await mongo.Db.create(uri);
  await _mongoDb.open();

  _mongoMessagesCollection = _mongoDb.collection('messages');
  _mongoFilesCollection = _mongoDb.collection('files');
  _mongoChatsCollection = _mongoDb.collection('chats');
  _mongoGridFs = mongo.GridFS(_mongoDb, 'netmax_files');

  await _mongoMessagesCollection.createIndex(
    keys: <String, dynamic>{'created_at': 1},
  );
  await _mongoMessagesCollection.createIndex(
    keys: <String, dynamic>{'chat_id': 1, 'created_at': 1},
  );
  await _mongoFilesCollection.createIndex(
    keys: <String, dynamic>{'created_at': 1},
  );
  await _mongoChatsCollection.createIndex(
    keys: <String, dynamic>{'id': 1},
    unique: true,
  );
}

void _loadServerManagedE2eeKey() {
  final fromEnv = (Platform.environment['NETMAX_E2EE_SHARED_KEY'] ?? '').trim();
  if (fromEnv.isNotEmpty) {
    _serverManagedE2eeKey = fromEnv;
    _serverManagedE2eeKeySource = 'env:NETMAX_E2EE_SHARED_KEY';
    return;
  }

  if (_e2eeKeyFile.existsSync()) {
    try {
      final fromFile = _e2eeKeyFile.readAsStringSync().trim();
      if (fromFile.isNotEmpty) {
        _serverManagedE2eeKey = fromFile;
        _serverManagedE2eeKeySource = _e2eeKeyConfigRelativePath;
        return;
      }
    } catch (_) {
      // Generate and rewrite key below if the file is unreadable.
    }
  }

  final seed = <int>[
    DateTime.now().microsecondsSinceEpoch & 0xFF,
    ...List<int>.generate(31, (_) => _random.nextInt(256)),
  ];
  _serverManagedE2eeKey = base64UrlEncode(seed);
  _serverManagedE2eeKeySource = _e2eeKeyConfigRelativePath;
  try {
    _e2eeKeyFile.parent.createSync(recursive: true);
    _e2eeKeyFile.writeAsStringSync(_serverManagedE2eeKey);
  } catch (_) {
    stdout.writeln(
      'Warning: failed to persist E2EE key at $_e2eeKeyConfigRelativePath.',
    );
  }
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

Future<void> _loadGroupChats() async {
  final loaded = <String, String>{};

  final chatsFromNoSql = await _mongoChatsCollection.find({
    'type': 'group',
  }).toList();
  for (final item in chatsFromNoSql) {
    final rawId = (item['id']?.toString() ?? '').trim();
    final rawTitle = (item['title']?.toString() ?? '').trim();
    final chatId = _normalizeGroupChatId(rawId, requireExisting: false);
    if (chatId == null || loaded.containsKey(chatId)) {
      continue;
    }
    loaded[chatId] = rawTitle.isEmpty ? 'Чат' : rawTitle;
  }

  if (loaded.isEmpty) {
    final legacyLoaded = _loadLegacyGroupChats();
    loaded.addAll(legacyLoaded);
    if (loaded.isNotEmpty) {
      final documents = loaded.entries
          .map(
            (entry) => <String, dynamic>{
              '_id': entry.key,
              'id': entry.key,
              'title': entry.value,
              'type': 'group',
              'created_at': DateTime.now().toUtc().toIso8601String(),
            },
          )
          .toList(growable: false);
      if (documents.isNotEmpty) {
        await _mongoChatsCollection.insertMany(documents);
      }
    }
  }

  if (loaded.isEmpty) {
    loaded[_defaultGroupChatId] = _defaultGroupChatTitle;
    await _mongoChatsCollection.replaceOne(
      {'_id': _defaultGroupChatId},
      <String, dynamic>{
        '_id': _defaultGroupChatId,
        'id': _defaultGroupChatId,
        'title': _defaultGroupChatTitle,
        'type': 'group',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      upsert: true,
    );
  }

  if (!loaded.containsKey(_defaultGroupChatId)) {
    loaded[_defaultGroupChatId] = _defaultGroupChatTitle;
    await _mongoChatsCollection.replaceOne(
      {'_id': _defaultGroupChatId},
      <String, dynamic>{
        '_id': _defaultGroupChatId,
        'id': _defaultGroupChatId,
        'title': _defaultGroupChatTitle,
        'type': 'group',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      upsert: true,
    );
  }

  _groupChatTitlesById
    ..clear()
    ..addAll(loaded);
}

Map<String, String> _loadLegacyGroupChats() {
  if (!_groupChatsConfigFile.existsSync()) {
    return <String, String>{};
  }

  final loaded = <String, String>{};
  try {
    final decoded = jsonDecode(_groupChatsConfigFile.readAsStringSync());
    final root = _asMap(decoded);
    final rawChats = root['chats'];
    if (rawChats is List) {
      for (final item in rawChats) {
        final map = _asMap(item);
        final rawId = (map['id']?.toString() ?? '').trim();
        final rawTitle = (map['title']?.toString() ?? '').trim();
        final chatId = _normalizeGroupChatId(rawId, requireExisting: false);
        if (chatId == null || loaded.containsKey(chatId)) {
          continue;
        }
        loaded[chatId] = rawTitle.isEmpty ? 'Чат' : rawTitle;
      }
    }
  } catch (_) {
    return <String, String>{};
  }
  return loaded;
}

Future<void> _initializeMessageStore() async {
  _messagesDbFile.parent.createSync(recursive: true);
  _messagesDb = sqlite.sqlite3.open(_messagesDbFile.path);
  _messagesDb.execute('PRAGMA journal_mode = WAL;');
  _messagesDb.execute('PRAGMA synchronous = NORMAL;');
  _messagesDb.execute('''
    CREATE TABLE IF NOT EXISTS message_store_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    ''');
  _messagesDb.execute('''
    INSERT OR REPLACE INTO message_store_meta (key, value)
    VALUES ('engine', 'mongo')
    ''');

  await _trimMessagesInNoSql();

  if (await _messagesCountInNoSql() == 0) {
    final migrated = _loadLegacyMessagesForMigration();
    if (migrated.isNotEmpty) {
      await _replaceAllMessagesInNoSql(migrated);
      stdout.writeln(
        'Migrated ${migrated.length} message(s) from $_messagesConfigRelativePath to MongoDB.',
      );
    }
  }

  await _loadMessagesFromNoSqlToMemory();
}

List<Map<String, dynamic>> _loadLegacyMessagesForMigration() {
  if (!_messagesLegacyConfigFile.existsSync()) {
    return <Map<String, dynamic>>[];
  }

  final result = <Map<String, dynamic>>[];
  try {
    final decoded = jsonDecode(_messagesLegacyConfigFile.readAsStringSync());
    final root = _asMap(decoded);
    final rawMessages = root['messages'];
    if (rawMessages is! List) {
      return result;
    }
    for (final item in rawMessages) {
      final normalized = _normalizeLoadedMessage(_asMap(item));
      if (normalized != null) {
        result.add(normalized);
      }
    }
  } catch (_) {
    return <Map<String, dynamic>>[];
  }

  if (result.length > _maxHistoryMessages) {
    return result.sublist(result.length - _maxHistoryMessages);
  }
  return result;
}

Future<void> _loadMessagesFromNoSqlToMemory() async {
  _group.messages.clear();

  final staleIds = <String>[];
  final rows = await _mongoMessagesCollection
      .find(mongo.where.sortBy('created_at'))
      .toList();
  for (final row in rows) {
    final id = (row['_id']?.toString() ?? '').trim();
    final parsed = _asMap(row['payload']);

    final normalized = _normalizeLoadedMessage(parsed);
    if (normalized == null) {
      if (id.isNotEmpty) {
        staleIds.add(id);
      }
      continue;
    }
    _group.messages.add(normalized);
  }

  if (staleIds.isNotEmpty) {
    await _deleteMessagesFromNoSqlByIds(staleIds);
  }

  if (_group.messages.length > _maxHistoryMessages) {
    _group.messages.removeRange(
      0,
      _group.messages.length - _maxHistoryMessages,
    );
    await _replaceAllMessagesInNoSql(_group.messages);
  }
}

Future<int> _messagesCountInNoSql() async {
  return _mongoMessagesCollection.count();
}

void _saveMessageHistory({
  Map<String, dynamic>? changedMessage,
  List<String> removedMessageIds = const <String>[],
}) {
  unawaited(
    _saveMessageHistoryInNoSql(
      changedMessage: changedMessage,
      removedMessageIds: removedMessageIds,
    ),
  );
}

Future<void> _saveMessageHistoryInNoSql({
  Map<String, dynamic>? changedMessage,
  List<String> removedMessageIds = const <String>[],
}) async {
  if (changedMessage == null) {
    await _replaceAllMessagesInNoSql(_group.messages);
    return;
  }

  await _upsertMessageInNoSql(changedMessage);
  if (removedMessageIds.isNotEmpty) {
    await _deleteMessagesFromNoSqlByIds(removedMessageIds);
  }
  await _trimMessagesInNoSql();
}

Future<void> _replaceAllMessagesInNoSql(
  List<Map<String, dynamic>> messages,
) async {
  await _mongoMessagesCollection.deleteMany(<String, dynamic>{});
  final start = messages.length > _maxHistoryMessages
      ? messages.length - _maxHistoryMessages
      : 0;
  final documents = <Map<String, dynamic>>[];
  for (var index = start; index < messages.length; index++) {
    documents.add(_messageRecordFromPayload(messages[index]));
  }
  if (documents.isNotEmpty) {
    await _mongoMessagesCollection.insertMany(documents);
  }
}

Future<void> _upsertMessageInNoSql(Map<String, dynamic> message) async {
  final id = _normalizeMessageId(message['id']);
  final record = _messageRecordFromPayload(message);
  await _mongoMessagesCollection.replaceOne({'_id': id}, record, upsert: true);
}

Map<String, dynamic> _messageRecordFromPayload(Map<String, dynamic> message) {
  final id = _normalizeMessageId(message['id']);
  return <String, dynamic>{
    '_id': id,
    'created_at': _normalizeIsoTimestamp(message['createdAt']),
    'chat_id': (message['chatId']?.toString() ?? _defaultGroupChatId).trim(),
    'chat_type': (message['chatType']?.toString() ?? 'group').trim(),
    'payload': message,
  };
}

Future<void> _deleteMessagesFromNoSqlByIds(List<String> ids) async {
  if (ids.isEmpty) {
    return;
  }
  final normalizedIds = ids
      .map((id) => id.trim())
      .where((id) => id.isNotEmpty)
      .toList(growable: false);
  if (normalizedIds.isEmpty) {
    return;
  }
  await _mongoMessagesCollection.deleteMany(<String, dynamic>{
    '_id': <String, dynamic>{'\$in': normalizedIds},
  });
}

Future<void> _trimMessagesInNoSql() async {
  final rows = await _mongoMessagesCollection
      .find(mongo.where.sortBy('created_at', descending: true))
      .toList();
  if (rows.length <= _maxHistoryMessages) {
    return;
  }
  final staleIds = rows
      .skip(_maxHistoryMessages)
      .map((row) => (row['_id']?.toString() ?? '').trim())
      .where((id) => id.isNotEmpty)
      .toList(growable: false);
  await _deleteMessagesFromNoSqlByIds(staleIds);
}

Future<void> _storeFileInNoSql({
  required String fileId,
  required String fileName,
  required String extension,
  required List<int> bytes,
}) async {
  final existing = await _mongoGridFs.findOne(mongo.where.id(fileId));
  if (existing != null) {
    await existing.delete();
  }

  final gridIn = _mongoGridFs
      .createFile(Stream<List<int>>.value(bytes), fileName, <String, dynamic>{
        'extension': extension,
        'sizeBytes': bytes.length,
        'createdAt': DateTime.now().toUtc(),
      });
  gridIn.id = fileId;
  await gridIn.save();

  final now = DateTime.now().toUtc().toIso8601String();
  await _mongoFilesCollection.replaceOne(
    {'_id': fileId},
    <String, dynamic>{
      '_id': fileId,
      'name': fileName,
      'extension': extension,
      'size_bytes': bytes.length,
      'created_at': now,
    },
    upsert: true,
  );
}

Future<Map<String, dynamic>?> _fileFromNoSql(String fileId) async {
  return _mongoFilesCollection.findOne({'_id': fileId});
}

Future<List<int>?> _readFileBytesFromNoSql(String fileId) async {
  final out = await _mongoGridFs.findOne(mongo.where.id(fileId));
  if (out == null) {
    return null;
  }
  final chunks = await _mongoGridFs.chunks
      .find(mongo.where.eq('files_id', out.id).sortBy('n'))
      .toList();
  if (chunks.isEmpty) {
    return <int>[];
  }
  final bytes = BytesBuilder(copy: false);
  for (final chunk in chunks) {
    final data = chunk['data'];
    if (data is mongo.BsonBinary) {
      bytes.add(data.byteList);
    } else if (data is List<int>) {
      bytes.add(data);
    }
  }
  return bytes.toBytes();
}

Future<void> _deleteFilesFromNoSqlByIds(List<String> ids) async {
  final normalizedIds = ids
      .map((id) => id.trim())
      .where((id) => id.isNotEmpty)
      .toList(growable: false);
  if (normalizedIds.isEmpty) {
    return;
  }

  for (final id in normalizedIds) {
    final out = await _mongoGridFs.findOne(mongo.where.id(id));
    if (out != null) {
      await out.delete();
    }
  }

  await _mongoFilesCollection.deleteMany(<String, dynamic>{
    '_id': <String, dynamic>{'\$in': normalizedIds},
  });
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
  unawaited(_cleanupStorageInNoSql());
}

Future<void> _cleanupStorageInNoSql() async {
  final now = DateTime.now();
  final rows = await _mongoFilesCollection.find().toList();
  if (rows.isEmpty) {
    return;
  }

  var activeTotalBytes = 0;
  var deletedFiles = 0;
  var freedBytes = 0;
  final staleIds = <String>[];
  final active = <Map<String, dynamic>>[];

  for (final row in rows) {
    final id = (row['_id']?.toString() ?? '').trim();
    final createdAt = DateTime.tryParse(
      row['created_at']?.toString() ?? '',
    )?.toLocal();
    final size = (row['size_bytes'] as num?)?.toInt() ?? 0;
    if (id.isEmpty || createdAt == null || size <= 0) {
      if (id.isNotEmpty) {
        staleIds.add(id);
      }
      continue;
    }
    final age = now.difference(createdAt);
    if (age > _storageFileMaxAge) {
      staleIds.add(id);
      deletedFiles++;
      freedBytes += size;
      continue;
    }

    active.add(<String, dynamic>{
      'id': id,
      'size': size,
      'createdAt': createdAt,
    });
    activeTotalBytes += size;
  }

  if (activeTotalBytes > _storageMaxBytes) {
    active.sort(
      (a, b) =>
          (a['createdAt'] as DateTime).compareTo(b['createdAt'] as DateTime),
    );
    for (final entry in active) {
      if (activeTotalBytes <= _storageMaxBytes) {
        break;
      }
      staleIds.add(entry['id'] as String);
      deletedFiles++;
      freedBytes += entry['size'] as int;
      activeTotalBytes -= entry['size'] as int;
    }
  }

  if (staleIds.isNotEmpty) {
    await _deleteFilesFromNoSqlByIds(staleIds);
  }

  if (deletedFiles > 0) {
    stdout.writeln(
      'Storage cleanup removed $deletedFiles file(s), '
      'freed ${(freedBytes / (1024 * 1024)).toStringAsFixed(2)} MB.',
    );
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
    final groupChatId = _primaryGroupChatId;

    final message = <String, dynamic>{
      'id': _normalizeMessageId(null),
      'senderId': senderId,
      'senderName': rule.userName,
      'createdAt': nowUtc.toIso8601String(),
      'type': 'text',
      'text': text,
      'scheduled': true,
      'chatId': groupChatId,
      'chatType': 'group',
      'edited': false,
      'deleted': false,
      'editHistory': const <Object>[],
      'reactions': const <String, Object>{},
      'mentions': _normalizeMentions(rawMentions: null, text: text).toList(),
      'deliveredTo': <String>[rule.userName.toLowerCase()],
      'readBy': <String>[rule.userName.toLowerCase()],
      'encrypted': false,
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

String get _primaryGroupChatId {
  if (_groupChatTitlesById.containsKey(_defaultGroupChatId)) {
    return _defaultGroupChatId;
  }
  if (_groupChatTitlesById.isNotEmpty) {
    return _groupChatTitlesById.keys.first;
  }
  return _defaultGroupChatId;
}

List<Map<String, dynamic>> _groupChatsPayload() {
  return _groupChatTitlesById.entries
      .map(
        (entry) => <String, dynamic>{
          'id': entry.key,
          'title': entry.value,
          'type': 'group',
        },
      )
      .toList(growable: false);
}

List<Map<String, dynamic>> _messagesForUser(String userName) {
  final userLower = userName.trim().toLowerCase();
  final result = <Map<String, dynamic>>[];
  for (final message in _group.messages) {
    if (_isMessageVisibleForUser(message: message, userNameLower: userLower)) {
      result.add(message);
    }
  }
  return result;
}

bool _isMessageVisibleForUser({
  required Map<String, dynamic> message,
  required String userNameLower,
}) {
  final chatType = (message['chatType']?.toString() ?? 'group').trim();
  if (chatType != 'direct') {
    return true;
  }
  final rawParticipants = message['participants'];
  if (rawParticipants is! List) {
    return false;
  }
  for (final participant in rawParticipants) {
    final lower = participant.toString().trim().toLowerCase();
    if (lower == userNameLower) {
      return true;
    }
  }
  return false;
}

bool _isDirectChatId(String chatId) {
  return chatId.startsWith('direct:');
}

String _buildDirectChatId(String firstLower, String secondLower) {
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
  if (!_allowedUsersByLower.containsKey(first) ||
      !_allowedUsersByLower.containsKey(second)) {
    return null;
  }
  return _buildDirectChatId(first, second);
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

_DirectChatContext? _resolveDirectChatContext({
  required String chatId,
  required String senderUserName,
}) {
  if (!_isDirectChatId(chatId)) {
    return null;
  }

  final raw = chatId.substring('direct:'.length);
  final parts = raw.split('|');
  if (parts.length != 2) {
    return null;
  }
  final first = parts[0].trim().toLowerCase();
  final second = parts[1].trim().toLowerCase();
  if (first.isEmpty || second.isEmpty || first == second) {
    return null;
  }

  final canonicalFirst = _allowedUsersByLower[first];
  final canonicalSecond = _allowedUsersByLower[second];
  if (canonicalFirst == null || canonicalSecond == null) {
    return null;
  }

  final senderLower = senderUserName.trim().toLowerCase();
  if (senderLower != first && senderLower != second) {
    return null;
  }

  final canonicalChatId = _buildDirectChatId(first, second);
  return _DirectChatContext(
    chatId: canonicalChatId,
    participantsLower: <String>{first, second},
  );
}

Map<String, dynamic>? _normalizeReplyPayload(Object? raw) {
  if (raw is! Map) {
    return null;
  }

  final map = _asMap(raw);
  final messageId = (map['messageId']?.toString() ?? '').trim();
  if (messageId.isEmpty) {
    return null;
  }

  final senderName = _sanitizePlainText(
    map['senderName']?.toString() ?? 'Unknown',
    maxLength: 80,
  );
  final text = _sanitizePlainText(
    map['text']?.toString() ?? '',
    maxLength: 600,
  );
  final typeRaw = (map['type']?.toString() ?? 'text').trim().toLowerCase();
  final type = switch (typeRaw) {
    'file' => 'file',
    'system' => 'system',
    _ => 'text',
  };

  final fallbackText = type == 'file' ? 'Файл' : 'Сообщение';
  return <String, dynamic>{
    'messageId': messageId,
    'senderName': senderName.isEmpty ? 'Unknown' : senderName,
    'text': text.isEmpty ? fallbackText : text,
    'type': type,
  };
}

Map<String, dynamic>? _normalizeForwardPayload(Object? raw) {
  if (raw is! Map) {
    return null;
  }

  final map = _asMap(raw);
  final messageId = (map['messageId']?.toString() ?? '').trim();
  if (messageId.isEmpty) {
    return null;
  }

  final senderName = _sanitizePlainText(
    map['senderName']?.toString() ?? 'Unknown',
    maxLength: 80,
  );
  final text = _sanitizePlainText(
    map['text']?.toString() ?? '',
    maxLength: 600,
  );
  final typeRaw = (map['type']?.toString() ?? 'text').trim().toLowerCase();
  final type = switch (typeRaw) {
    'file' => 'file',
    'system' => 'system',
    _ => 'text',
  };

  final fallbackText = type == 'file' ? 'Файл' : 'Сообщение';
  return <String, dynamic>{
    'messageId': messageId,
    'senderName': senderName.isEmpty ? 'Unknown' : senderName,
    'text': text.isEmpty ? fallbackText : text,
    'type': type,
  };
}

Map<String, dynamic>? _normalizeLoadedMessage(Map<String, dynamic> raw) {
  final id = _normalizeMessageId(raw['id']);
  final senderId = (raw['senderId']?.toString() ?? '').trim();
  final senderName = _sanitizePlainText(
    raw['senderName']?.toString() ?? '',
    maxLength: 80,
  );
  final createdAt = _normalizeIsoTimestamp(raw['createdAt']);
  final type = (raw['type']?.toString() ?? 'text').trim();
  final isEncrypted = raw['encrypted'] == true || raw['isEncrypted'] == true;
  final textRaw = (raw['text']?.toString() ?? '').trim();
  final text = isEncrypted
      ? textRaw
      : _sanitizePlainText(textRaw, maxLength: 4000);
  final isScheduled = raw['scheduled'] == true;
  final chatIdRaw = (raw['chatId']?.toString() ?? '').trim();
  final chatType = (raw['chatType']?.toString() ?? 'group').trim();
  final replyTo = _normalizeReplyPayload(raw['replyTo']);
  final forwardedFrom = _normalizeForwardPayload(raw['forwardedFrom']);
  final isEdited = raw['edited'] == true || raw['isEdited'] == true;
  final editedAt = _normalizeOptionalIsoTimestamp(raw['editedAt']);
  final isDeleted = raw['deleted'] == true || raw['isDeleted'] == true;
  final deletedAt = _normalizeOptionalIsoTimestamp(raw['deletedAt']);
  final editHistory = _normalizeEditHistory(raw['editHistory']);
  final reactions = _normalizeReactions(raw['reactions']);
  final mentions = _normalizeMentions(rawMentions: raw['mentions'], text: text);
  final deliveredTo = _normalizeUserLowerList(raw['deliveredTo']);
  final readBy = _normalizeUserLowerList(raw['readBy']);
  final encryption = raw['encryption'] is Map
      ? _asMap(raw['encryption'])
      : null;
  final senderLower = senderName.trim().toLowerCase();
  if (senderLower.isNotEmpty) {
    if (!deliveredTo.contains(senderLower)) {
      deliveredTo.add(senderLower);
    }
    if (!readBy.contains(senderLower)) {
      readBy.add(senderLower);
    }
  }
  deliveredTo.sort();
  readBy.sort();

  if (type != 'text' && type != 'file' && type != 'system') {
    return null;
  }

  if (chatType == 'direct') {
    final direct = _resolveDirectChatContext(
      chatId: chatIdRaw,
      senderUserName: senderName,
    );
    if (direct == null) {
      return null;
    }
    final normalized = <String, dynamic>{
      'id': id,
      'senderId': senderId,
      'senderName': senderName.isEmpty ? 'Unknown' : senderName,
      'createdAt': createdAt,
      'type': type,
      'text': text,
      'scheduled': isScheduled,
      'chatId': direct.chatId,
      'chatType': 'direct',
      'participants': direct.participantsLower.toList(),
      'edited': isEdited,
      'editedAt': editedAt,
      'deleted': isDeleted,
      'deletedAt': deletedAt,
      'editHistory': editHistory,
      'reactions': reactions,
      'mentions': mentions.toList(growable: false),
      'deliveredTo': deliveredTo,
      'readBy': readBy,
      'encrypted': isEncrypted,
      if (encryption != null) 'encryption': encryption,
      if (replyTo != null) 'replyTo': replyTo,
      if (forwardedFrom != null) 'forwardedFrom': forwardedFrom,
    };
    if (type == 'file') {
      final attachment = _asMap(raw['attachment']);
      attachment['name'] = _sanitizePlainText(
        attachment['name']?.toString() ?? 'file',
        maxLength: 255,
      );
      normalized['attachment'] = attachment;
    }
    return normalized;
  }

  final groupChatId = _normalizeGroupChatId(chatIdRaw) ?? _primaryGroupChatId;
  final normalized = <String, dynamic>{
    'id': id,
    'senderId': senderId,
    'senderName': senderName.isEmpty ? 'Unknown' : senderName,
    'createdAt': createdAt,
    'type': type,
    'text': text,
    'scheduled': isScheduled,
    'chatId': groupChatId,
    'chatType': 'group',
    'edited': isEdited,
    'editedAt': editedAt,
    'deleted': isDeleted,
    'deletedAt': deletedAt,
    'editHistory': editHistory,
    'reactions': reactions,
    'mentions': mentions.toList(growable: false),
    'deliveredTo': deliveredTo,
    'readBy': readBy,
    'encrypted': isEncrypted,
    if (encryption != null) 'encryption': encryption,
    if (replyTo != null) 'replyTo': replyTo,
    if (forwardedFrom != null) 'forwardedFrom': forwardedFrom,
  };
  if (type == 'file') {
    final attachment = _asMap(raw['attachment']);
    attachment['name'] = _sanitizePlainText(
      attachment['name']?.toString() ?? 'file',
      maxLength: 255,
    );
    normalized['attachment'] = attachment;
  }
  return normalized;
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
    'groupChats': _groupChatTitlesById.length,
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

Response _chatsHandler(Request request) {
  return _json({
    'groupChats': _groupChatsPayload(),
    'allowedUsers': _allowedUsers,
    'count': _groupChatTitlesById.length,
  });
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

Future<Response> _filesHandler(Request request, String file) async {
  final fileId = file.trim();
  final validId = RegExp(r'^[a-zA-Z0-9._-]{1,120}$').hasMatch(fileId);
  if (!validId) {
    return _json({'error': 'Invalid file path.'}, statusCode: 400);
  }

  final item = await _fileFromNoSql(fileId);
  if (item == null) {
    return _json({'error': 'File not found.'}, statusCode: 404);
  }

  final bytes = await _readFileBytesFromNoSql(fileId);
  if (bytes == null) {
    return _json({'error': 'File payload not found.'}, statusCode: 404);
  }
  final totalSize = bytes.length;
  if (totalSize <= 0) {
    return _json({'error': 'File payload is empty.'}, statusCode: 404);
  }

  final downloadFlag = request.url.queryParameters['download']?.trim();
  final forceDownload = downloadFlag == '1' || downloadFlag == 'true';
  final requestedName = request.url.queryParameters['name']?.trim() ?? '';
  final fallbackName = _sanitizePlainText(
    item['name']?.toString() ?? 'file.bin',
    maxLength: 255,
  );
  final downloadName = _safeDownloadName(
    requestedName.isEmpty ? fallbackName : requestedName,
  );
  final contentType = _contentTypeByFileName(downloadName);
  final inlineAllowed = _isInlineMediaContentType(contentType);

  final headers = <String, String>{
    HttpHeaders.contentTypeHeader: contentType,
    HttpHeaders.acceptRangesHeader: 'bytes',
    HttpHeaders.xContentTypeOptionsHeader: 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    'content-security-policy': "default-src 'none'; sandbox",
  };
  if (forceDownload || !inlineAllowed) {
    headers['content-disposition'] = 'attachment; filename="$downloadName"';
  }

  final rangeHeader = request.headers[HttpHeaders.rangeHeader];
  final byteRange = _parseByteRange(rangeHeader, totalSize);
  if (byteRange != null) {
    final start = byteRange.start;
    final end = byteRange.end;
    final length = end - start + 1;
    headers[HttpHeaders.contentLengthHeader] = length.toString();
    headers[HttpHeaders.contentRangeHeader] = 'bytes $start-$end/$totalSize';
    return Response(
      HttpStatus.partialContent,
      body: Stream<List<int>>.value(bytes.sublist(start, end + 1)),
      headers: headers,
    );
  }

  headers[HttpHeaders.contentLengthHeader] = totalSize.toString();
  return Response.ok(Stream<List<int>>.value(bytes), headers: headers);
}

_ByteRange? _parseByteRange(String? header, int totalSize) {
  if (header == null || header.trim().isEmpty || totalSize <= 0) {
    return null;
  }

  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null) {
    return null;
  }

  final startRaw = match.group(1) ?? '';
  final endRaw = match.group(2) ?? '';

  int? start;
  int? end;

  if (startRaw.isEmpty && endRaw.isEmpty) {
    return null;
  }

  if (startRaw.isNotEmpty) {
    start = int.tryParse(startRaw);
  }
  if (endRaw.isNotEmpty) {
    end = int.tryParse(endRaw);
  }

  if (start == null && end != null) {
    if (end <= 0) {
      return null;
    }
    start = totalSize - end;
    end = totalSize - 1;
  }

  start ??= 0;
  end ??= totalSize - 1;

  if (start < 0 || end < 0 || start >= totalSize) {
    return null;
  }
  if (end >= totalSize) {
    end = totalSize - 1;
  }
  if (end < start) {
    return null;
  }

  return _ByteRange(start: start, end: end);
}

String _contentTypeByFileName(String fileName) {
  final ext = p.extension(fileName).replaceFirst('.', '').trim().toLowerCase();
  return switch (ext) {
    'wav' => 'audio/wav',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' => 'audio/ogg',
    'opus' => 'audio/ogg',
    'flac' => 'audio/flac',
    'txt' => 'text/plain; charset=utf-8',
    'json' => 'application/json; charset=utf-8',
    'pdf' => 'application/pdf',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    _ => 'application/octet-stream',
  };
}

bool _isInlineMediaContentType(String contentType) {
  final normalized = contentType.toLowerCase();
  return normalized.startsWith('audio/') || normalized.startsWith('video/');
}

void _handleSocket(WebSocketChannel channel, String? protocol) {
  String? userId;
  String? userName;
  var joined = false;

  late final StreamSubscription<dynamic> subscription;
  subscription = channel.stream.listen(
    (dynamic rawData) async {
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
              payload: {
                'userId': userId,
                'userName': userName,
                'encryption': {
                  'method': 'aes-gcm-256-v1',
                  'sharedKey': _serverManagedE2eeKey,
                  'source': 'server',
                },
              },
            );

            // список уникальных пользаков
            _sendEnvelope(
              channel,
              type: 'snapshot',
              payload: {
                'onlineUsers': _deduplicatedOnlineUsers(),
                'messages': _messagesForUser(userName!),
                'groupChats': _groupChatsPayload(),
                'allowedUsers': _allowedUsers,
              },
            );

            _sendScheduledConfig(channel: channel, userName: userName!);

            // Broadcast presence only for the first active session of user.
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

            final isEncrypted = payload['encrypted'] == true;
            final rawText = (payload['text']?.toString() ?? '').trim();
            final text = isEncrypted
                ? rawText
                : _sanitizePlainText(rawText, maxLength: 4000);
            if (text.isEmpty) {
              return;
            }

            final chatId = (payload['chatId']?.toString() ?? '').trim();
            if (chatId.isEmpty) {
              _sendEnvelope(
                channel,
                type: 'error',
                payload: {'message': 'chatId is required.'},
              );
              return;
            }

            final directContext = _resolveDirectChatContext(
              chatId: chatId,
              senderUserName: userName!,
            );
            if (_isDirectChatId(chatId) && directContext == null) {
              _sendEnvelope(
                channel,
                type: 'error',
                payload: {'message': 'Неверный direct chatId.'},
              );
              return;
            }

            final groupChatId = directContext == null
                ? _normalizeGroupChatId(chatId)
                : null;
            if (directContext == null && groupChatId == null) {
              _sendEnvelope(
                channel,
                type: 'error',
                payload: {'message': 'Групповой чат не найден.'},
              );
              return;
            }
            final replyTo = _normalizeReplyPayload(payload['replyTo']);
            final forwardedFrom = _normalizeForwardPayload(
              payload['forwardedFrom'],
            );

            final message = <String, dynamic>{
              'id': _normalizeMessageId(payload['id']),
              'senderId': userId,
              'senderName': userName,
              'createdAt': _normalizeIsoTimestamp(payload['createdAt']),
              'type': 'text',
              'text': text,
              'scheduled': false,
              'chatId': directContext?.chatId ?? groupChatId!,
              'chatType': directContext == null ? 'group' : 'direct',
              'edited': false,
              'deleted': false,
              'editHistory': const <Object>[],
              'reactions': const <String, Object>{},
              'mentions': _normalizeMentions(
                rawMentions: payload['mentions'],
                text: text,
              ).toList(growable: false),
              'deliveredTo': <String>[userName!.toLowerCase()],
              'readBy': <String>[userName!.toLowerCase()],
              'encrypted': isEncrypted,
              if (payload['encryption'] is Map)
                'encryption': _asMap(payload['encryption']),
              if (replyTo != null) 'replyTo': replyTo,
              if (forwardedFrom != null) 'forwardedFrom': forwardedFrom,
              if (directContext != null)
                'participants': directContext.participantsLower.toList(),
            };

            _appendMessage(message);
            _broadcastMessageToAudience(type: 'message', payload: message);
            break;

          case 'typing':
            if (!joined || userId == null || userName == null) {
              return;
            }

            final isTyping = payload['isTyping'] == true;
            final chatId = (payload['chatId']?.toString() ?? '').trim();
            if (chatId.isEmpty) {
              return;
            }
            final directContext = _resolveDirectChatContext(
              chatId: chatId,
              senderUserName: userName!,
            );
            if (_isDirectChatId(chatId) && directContext == null) {
              return;
            }
            final groupChatId = directContext == null
                ? _normalizeGroupChatId(chatId)
                : null;
            if (directContext == null && groupChatId == null) {
              return;
            }

            final typingPayload = {
              'userId': userId,
              'userName': userName,
              'isTyping': isTyping,
              'chatId': directContext?.chatId ?? groupChatId!,
            };
            if (directContext == null) {
              _broadcast(
                type: 'typing',
                payload: typingPayload,
                exceptUserId: userId,
              );
            } else {
              _broadcastToParticipants(
                type: 'typing',
                payload: typingPayload,
                participantsLower: directContext.participantsLower,
                exceptUserId: userId,
              );
            }
            break;

          case 'file':
            if (!joined || userId == null || userName == null) {
              return;
            }
            await _handleFileMessage(
              channel: channel,
              userId: userId!,
              userName: userName!,
              payload: payload,
            );
            break;

          case 'message_edit':
            if (!joined || userId == null || userName == null) {
              return;
            }
            _handleMessageEdit(
              channel: channel,
              userId: userId!,
              userName: userName!,
              payload: payload,
            );
            break;

          case 'message_delete':
            if (!joined || userId == null || userName == null) {
              return;
            }
            _handleMessageDelete(
              channel: channel,
              userId: userId!,
              userName: userName!,
              payload: payload,
            );
            break;

          case 'message_reaction_toggle':
            if (!joined || userId == null || userName == null) {
              return;
            }
            _handleMessageReactionToggle(
              channel: channel,
              userName: userName!,
              payload: payload,
            );
            break;

          case 'message_delivered':
            if (!joined || userName == null) {
              return;
            }
            _handleMessageDeliveryState(
              userName: userName!,
              payload: payload,
              markAsRead: false,
            );
            break;

          case 'message_read':
            if (!joined || userName == null) {
              return;
            }
            _handleMessageDeliveryState(
              userName: userName!,
              payload: payload,
              markAsRead: true,
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

Future<void> _handleFileMessage({
  required WebSocketChannel channel,
  required String userId,
  required String userName,
  required Map<String, dynamic> payload,
}) async {
  final chatId = (payload['chatId']?.toString() ?? '').trim();
  if (chatId.isEmpty) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'chatId is required for file message.'},
    );
    return;
  }
  final directContext = _resolveDirectChatContext(
    chatId: chatId,
    senderUserName: userName,
  );
  if (_isDirectChatId(chatId) && directContext == null) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Неверный direct chatId.'},
    );
    return;
  }
  final groupChatId = directContext == null
      ? _normalizeGroupChatId(chatId)
      : null;
  if (directContext == null && groupChatId == null) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Групповой чат не найден.'},
    );
    return;
  }
  final replyTo = _normalizeReplyPayload(payload['replyTo']);
  final forwardedFrom = _normalizeForwardPayload(payload['forwardedFrom']);

  final fileName = _sanitizePlainText(
    payload['name']?.toString() ?? '',
    maxLength: 255,
  );
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
  final isEncrypted = payload['encrypted'] == true;
  final captionRaw = (payload['text']?.toString() ?? 'Отправлен файл').trim();
  final caption = isEncrypted
      ? captionRaw
      : _sanitizePlainText(captionRaw, maxLength: 4000);
  final safeName = _safeFileName(fileName);
  final storedName =
      '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(100000)}_$safeName';
  try {
    await _storeFileInNoSql(
      fileId: storedName,
      fileName: fileName,
      extension: extension,
      bytes: bytes,
    );
  } catch (_) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Не удалось сохранить файл в хранилище.'},
    );
    return;
  }
  _cleanupStorage();

  final message = <String, dynamic>{
    'id': _normalizeMessageId(payload['id']),
    'senderId': userId,
    'senderName': userName,
    'createdAt': _normalizeIsoTimestamp(payload['createdAt']),
    'type': 'file',
    'text': caption,
    'scheduled': false,
    'chatId': directContext?.chatId ?? groupChatId!,
    'chatType': directContext == null ? 'group' : 'direct',
    'edited': false,
    'deleted': false,
    'editHistory': const <Object>[],
    'reactions': const <String, Object>{},
    'mentions': _normalizeMentions(
      rawMentions: payload['mentions'],
      text: caption,
    ).toList(growable: false),
    'deliveredTo': <String>[userName.toLowerCase()],
    'readBy': <String>[userName.toLowerCase()],
    'encrypted': isEncrypted,
    if (payload['encryption'] is Map)
      'encryption': _asMap(payload['encryption']),
    if (replyTo != null) 'replyTo': replyTo,
    if (forwardedFrom != null) 'forwardedFrom': forwardedFrom,
    if (directContext != null)
      'participants': directContext.participantsLower.toList(),
    'attachment': {
      'name': fileName,
      'path': '/files/$storedName',
      'sizeBytes': bytes.length,
      'extension': extension,
    },
  };

  _appendMessage(message);
  _broadcastMessageToAudience(type: 'message', payload: message);
}

void _handleMessageEdit({
  required WebSocketChannel channel,
  required String userId,
  required String userName,
  required Map<String, dynamic> payload,
}) {
  final messageId = (payload['id']?.toString() ?? '').trim();
  final isEncrypted = payload['encrypted'] == true;
  final updatedTextRaw = (payload['text']?.toString() ?? '').trim();
  final updatedText = isEncrypted
      ? updatedTextRaw
      : _sanitizePlainText(updatedTextRaw, maxLength: 4000);
  if (messageId.isEmpty) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'message id is required for edit.'},
    );
    return;
  }
  if (updatedText.isEmpty) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Введите текст сообщения для редактирования.'},
    );
    return;
  }

  final message = _findMessageForUser(messageId: messageId, userName: userName);
  if (message == null) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Сообщение не найдено.'},
    );
    return;
  }

  final senderNameLower = (message['senderName']?.toString() ?? '')
      .trim()
      .toLowerCase();
  if (senderNameLower != userName.toLowerCase()) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Редактировать можно только свои сообщения.'},
    );
    return;
  }
  if ((message['deleted'] == true) || (message['isDeleted'] == true)) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Удаленное сообщение нельзя редактировать.'},
    );
    return;
  }

  final type = (message['type']?.toString() ?? 'text').trim().toLowerCase();
  if (type != 'text' && type != 'file') {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Этот тип сообщения нельзя редактировать.'},
    );
    return;
  }

  final previousText = (message['text']?.toString() ?? '').trim();
  if (previousText == updatedText) {
    return;
  }

  final nowIso = DateTime.now().toUtc().toIso8601String();
  final editHistory = _normalizeEditHistory(message['editHistory']);
  if (previousText.isNotEmpty) {
    final historyItem = <String, dynamic>{
      'text': previousText,
      'editedAt': nowIso,
    };
    if (message['encrypted'] == true && message['encryption'] is Map) {
      historyItem['encryption'] = _asMap(message['encryption']);
    }
    editHistory.add(historyItem);
  }

  message['text'] = updatedText;
  message['edited'] = true;
  message['editedAt'] = nowIso;
  message['editHistory'] = editHistory;
  message['mentions'] = _normalizeMentions(
    rawMentions: payload['mentions'],
    text: updatedText,
  ).toList(growable: false);

  if (payload['encrypted'] is bool) {
    message['encrypted'] = isEncrypted;
  }
  if (payload['encryption'] is Map) {
    message['encryption'] = _asMap(payload['encryption']);
  } else if (payload.containsKey('encryption') &&
      payload['encryption'] == null) {
    message.remove('encryption');
  }

  _saveMessageHistory(changedMessage: message);
  _broadcastMessageToAudience(type: 'message_updated', payload: message);
}

void _handleMessageDelete({
  required WebSocketChannel channel,
  required String userId,
  required String userName,
  required Map<String, dynamic> payload,
}) {
  final messageId = (payload['id']?.toString() ?? '').trim();
  if (messageId.isEmpty) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'message id is required for delete.'},
    );
    return;
  }

  final message = _findMessageForUser(messageId: messageId, userName: userName);
  if (message == null) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Сообщение не найдено.'},
    );
    return;
  }

  final senderNameLower = (message['senderName']?.toString() ?? '')
      .trim()
      .toLowerCase();
  if (senderNameLower != userName.toLowerCase()) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Удалять можно только свои сообщения.'},
    );
    return;
  }
  if (message['deleted'] == true || message['isDeleted'] == true) {
    return;
  }

  final nowIso = DateTime.now().toUtc().toIso8601String();
  message['deleted'] = true;
  message['deletedAt'] = nowIso;
  message['edited'] = false;
  message['editedAt'] = null;
  message['text'] = '';
  message['mentions'] = const <String>[];
  message['reactions'] = const <String, Object>{};

  _saveMessageHistory(changedMessage: message);
  _broadcastMessageToAudience(type: 'message_updated', payload: message);
}

void _handleMessageReactionToggle({
  required WebSocketChannel channel,
  required String userName,
  required Map<String, dynamic> payload,
}) {
  final messageId = (payload['id']?.toString() ?? '').trim();
  final reaction = (payload['reaction']?.toString() ?? '').trim();
  if (messageId.isEmpty || reaction.isEmpty) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'id и reaction обязательны.'},
    );
    return;
  }

  final message = _findMessageForUser(messageId: messageId, userName: userName);
  if (message == null) {
    _sendEnvelope(
      channel,
      type: 'error',
      payload: {'message': 'Сообщение не найдено.'},
    );
    return;
  }

  if (message['deleted'] == true || message['isDeleted'] == true) {
    return;
  }

  final userLower = userName.toLowerCase();
  final reactions = _normalizeReactions(message['reactions']);
  final users = reactions[reaction] ?? <String>[];
  if (users.contains(userLower)) {
    users.remove(userLower);
  } else {
    users.add(userLower);
  }

  if (users.isEmpty) {
    reactions.remove(reaction);
  } else {
    users.sort();
    reactions[reaction] = users;
  }

  message['reactions'] = reactions;
  _saveMessageHistory(changedMessage: message);
  _broadcastMessageToAudience(type: 'message_updated', payload: message);
}

void _handleMessageDeliveryState({
  required String userName,
  required Map<String, dynamic> payload,
  required bool markAsRead,
}) {
  final messageId = (payload['id']?.toString() ?? '').trim();
  if (messageId.isEmpty) {
    return;
  }

  final message = _findMessageForUser(messageId: messageId, userName: userName);
  if (message == null) {
    return;
  }

  final userLower = userName.toLowerCase();
  final delivered = _normalizeUserLowerList(message['deliveredTo']);
  final readBy = _normalizeUserLowerList(message['readBy']);
  var changed = false;

  if (!delivered.contains(userLower)) {
    delivered.add(userLower);
    changed = true;
  }

  if (markAsRead && !readBy.contains(userLower)) {
    readBy.add(userLower);
    changed = true;
  }

  if (!changed) {
    return;
  }

  delivered.sort();
  readBy.sort();
  message['deliveredTo'] = delivered;
  message['readBy'] = readBy;

  _saveMessageHistory(changedMessage: message);
  _broadcastMessageToAudience(type: 'message_updated', payload: message);
}

Map<String, dynamic>? _findMessageForUser({
  required String messageId,
  required String userName,
}) {
  final userLower = userName.trim().toLowerCase();
  if (userLower.isEmpty) {
    return null;
  }

  for (final message in _group.messages.reversed) {
    final id = (message['id']?.toString() ?? '').trim();
    if (id != messageId) {
      continue;
    }
    if (_isMessageVisibleForUser(message: message, userNameLower: userLower)) {
      return message;
    }
    return null;
  }
  return null;
}

void _broadcastMessageToAudience({
  required String type,
  required Map<String, dynamic> payload,
  String? exceptUserId,
}) {
  final chatType = (payload['chatType']?.toString() ?? 'group')
      .trim()
      .toLowerCase();
  if (chatType != 'direct') {
    _broadcast(type: type, payload: payload, exceptUserId: exceptUserId);
    return;
  }

  final participants = _participantsLowerFromMessage(payload);
  if (participants.isEmpty) {
    _broadcast(type: type, payload: payload, exceptUserId: exceptUserId);
    return;
  }

  _broadcastToParticipants(
    type: type,
    payload: payload,
    participantsLower: participants,
    exceptUserId: exceptUserId,
  );
}

Set<String> _participantsLowerFromMessage(Map<String, dynamic> message) {
  final raw = message['participants'];
  if (raw is List) {
    final values = raw
        .map((item) => item.toString().trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet();
    if (values.isNotEmpty) {
      return values;
    }
  }

  final chatId = _normalizeDirectChatId(
    (message['chatId']?.toString() ?? '').trim(),
  );
  if (chatId == null) {
    return <String>{};
  }
  final tail = chatId.substring('direct:'.length);
  final parts = tail.split('|');
  if (parts.length != 2) {
    return <String>{};
  }
  return <String>{parts[0], parts[1]};
}

List<Map<String, dynamic>> _normalizeEditHistory(Object? raw) {
  if (raw is! List) {
    return <Map<String, dynamic>>[];
  }

  final result = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is! Map) {
      continue;
    }
    final map = _asMap(item);
    final text = (map['text']?.toString() ?? '').trim();
    if (text.isEmpty) {
      continue;
    }
    final normalized = <String, dynamic>{
      'text': text,
      'editedAt': _normalizeIsoTimestamp(map['editedAt']),
    };
    if (map['encryption'] is Map) {
      normalized['encryption'] = _asMap(map['encryption']);
    }
    result.add(normalized);
  }
  return result;
}

Map<String, List<String>> _normalizeReactions(Object? raw) {
  if (raw is! Map) {
    return <String, List<String>>{};
  }

  final result = <String, List<String>>{};
  raw.forEach((key, value) {
    final reaction = key.toString().trim();
    if (reaction.isEmpty || value is! List) {
      return;
    }
    final users =
        value
            .map((entry) => entry.toString().trim().toLowerCase())
            .where((entry) => entry.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (users.isNotEmpty) {
      result[reaction] = users;
    }
  });
  return result;
}

List<String> _normalizeUserLowerList(Object? raw) {
  if (raw is! List) {
    return <String>[];
  }
  return raw
      .map((entry) => entry.toString().trim().toLowerCase())
      .where((entry) => entry.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
}

Set<String> _normalizeMentions({
  required Object? rawMentions,
  required String text,
}) {
  final result = <String>{};
  if (rawMentions is List) {
    for (final item in rawMentions) {
      final key = item.toString().trim().toLowerCase();
      if (key.isEmpty) {
        continue;
      }
      if (_allowedUsersByLower.containsKey(key)) {
        result.add(key);
      }
    }
  }

  final textLower = text.toLowerCase();
  if (textLower.isNotEmpty) {
    for (final entry in _allowedUsersByLower.entries) {
      final token = '@${entry.key}';
      if (textLower.contains(token)) {
        result.add(entry.key);
      }
    }
  }

  return result;
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
  final text = _sanitizePlainText(
    payload['text']?.toString() ?? '',
    maxLength: 4000,
  );
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
    payload: {
      'userId': userId,
      'userName': userName,
      'isTyping': false,
      'chatId': _primaryGroupChatId,
    },
  );
}

void _appendMessage(Map<String, dynamic> message) {
  _group.messages.add(message);
  final removedIds = <String>[];
  if (_group.messages.length > _maxHistoryMessages) {
    final removed = _group.messages.sublist(
      0,
      _group.messages.length - _maxHistoryMessages,
    );
    _group.messages.removeRange(0, removed.length);
    for (final item in removed) {
      final id = (item['id']?.toString() ?? '').trim();
      if (id.isNotEmpty) {
        removedIds.add(id);
      }
    }
  }
  _saveMessageHistory(changedMessage: message, removedMessageIds: removedIds);
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

void _broadcastToParticipants({
  required String type,
  required Map<String, dynamic> payload,
  required Set<String> participantsLower,
  String? exceptUserId,
}) {
  final envelope = jsonEncode({'type': type, 'payload': payload});
  final staleUsers = <String>[];

  _group.clients.forEach((userKey, socket) {
    if (exceptUserId != null && userKey == exceptUserId) {
      return;
    }
    final onlineNameLower = _group.userNames[userKey]?.toLowerCase();
    if (onlineNameLower == null ||
        !participantsLower.contains(onlineNameLower)) {
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

String? _normalizeOptionalIsoTimestamp(Object? value) {
  final text = (value?.toString() ?? '').trim();
  if (text.isEmpty) {
    return null;
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) {
    return null;
  }
  return parsed.toUtc().toIso8601String();
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

String _sanitizePlainText(String raw, {required int maxLength}) {
  final withoutControls = raw
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .trim();
  if (withoutControls.isEmpty) {
    return '';
  }
  final collapsed = withoutControls.replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.length <= maxLength) {
    return collapsed;
  }
  return '${collapsed.substring(0, maxLength - 1)}…';
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

int _readPositiveIntFromEnv(String key, {required int fallback}) {
  final raw = (Platform.environment[key] ?? '').trim();
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 1) {
    return fallback;
  }
  return parsed;
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
    headers: const {
      'content-type': 'application/json; charset=utf-8',
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
      'referrer-policy': 'no-referrer',
      'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
    },
  );
}

class RoomState {
  final Map<String, WebSocketChannel> clients = <String, WebSocketChannel>{};
  final Map<String, String> userNames = <String, String>{};
  final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[];
}

class _ByteRange {
  const _ByteRange({required this.start, required this.end});

  final int start;
  final int end;
}

class _DirectChatContext {
  const _DirectChatContext({
    required this.chatId,
    required this.participantsLower,
  });

  final String chatId;
  final Set<String> participantsLower;
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
