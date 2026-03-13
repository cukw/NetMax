import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String _authConfigRelativePath = 'config/authorized_users.json';

final RoomState _group = RoomState();
final Random _random = Random();

late final Directory _storageDir;
late final List<String> _allowedUsers;
late final Map<String, String> _allowedUsersByLower;

Future<void> main() async {
  _storageDir = Directory(p.join(Directory.current.path, 'storage'));
  if (!_storageDir.existsSync()) {
    _storageDir.createSync(recursive: true);
  }

  _loadAuthorizedUsers();

  final router = Router()
    ..get('/health', _healthHandler)
    ..get('/authorized-users', _authorizedUsersHandler)
    ..get(
      '/ws',
      webSocketHandler(
        _handleSocket,
        pingInterval: const Duration(seconds: 20),
      ),
    );

  final filesHandler = createStaticHandler(
    _storageDir.path,
    listDirectories: false,
  );
  router.get('/files/<file|.*>', (Request request, String file) {
    final normalizedPath = file.trim().isEmpty ? '/' : file;
    return filesHandler(request.change(path: normalizedPath));
  });

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
}

void _loadAuthorizedUsers() {
  final configFile = File(
    p.join(Directory.current.path, _authConfigRelativePath),
  );
  if (!configFile.existsSync()) {
    throw StateError(
      'Authorization config not found: ${configFile.path}. '
      'Create $_authConfigRelativePath with allowedUsers list.',
    );
  }

  final raw = configFile.readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw StateError(
      'Invalid authorization config format. Expected JSON object.',
    );
  }

  final usersRaw = decoded['allowedUsers'];
  if (usersRaw is! List) {
    throw StateError(
      'Invalid authorization config: "allowedUsers" must be a list.',
    );
  }

  final users =
      usersRaw
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

  if (users.length < 30) {
    throw StateError(
      'At least 30 authorized users expected. Current count: ${users.length}.',
    );
  }

  _allowedUsers = List<String>.unmodifiable(users);
  _allowedUsersByLower = {
    for (final name in _allowedUsers) name.toLowerCase(): name,
  };
}

Response _healthHandler(Request request) {
  return _json({
    'status': 'ok',
    'onlineUsers': _group.clients.length,
    'authorizedUsers': _allowedUsers.length,
    'messagesInMemory': _group.messages.length,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
  });
}

Response _authorizedUsersHandler(Request request) {
  return _json({'count': _allowedUsers.length, 'users': _allowedUsers});
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

            final nameAlreadyOnline = _group.userNames.values.any(
              (currentName) =>
                  currentName.toLowerCase() == authorizedName.toLowerCase(),
            );
            if (nameAlreadyOnline) {
              _denyAndClose(
                channel,
                'Авторизация отклонена: "$authorizedName" уже в сети.',
              );
              return;
            }

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

            _sendEnvelope(
              channel,
              type: 'snapshot',
              payload: {
                'onlineUsers': _group.userNames.entries
                    .map((entry) => {'id': entry.key, 'name': entry.value})
                    .toList(growable: false),
                'messages': _group.messages,
              },
            );

            _broadcast(
              type: 'presence',
              payload: {
                'userId': userId,
                'userName': userName,
                'isOnline': true,
              },
              exceptUserId: userId,
            );
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

  final message = <String, dynamic>{
    'id': _normalizeMessageId(payload['id']),
    'senderId': userId,
    'senderName': userName,
    'createdAt': _normalizeIsoTimestamp(payload['createdAt']),
    'type': 'file',
    'text': (payload['text']?.toString() ?? 'Отправлен файл').trim(),
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

  _broadcast(
    type: 'presence',
    payload: {'userId': userId, 'userName': userName, 'isOnline': false},
  );

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
