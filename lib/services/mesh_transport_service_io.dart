import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mesh_transport_service_base.dart';

MeshTransportServiceBase createMeshTransportService() {
  return _IoMeshTransportService();
}

class _IoMeshTransportService implements MeshTransportServiceBase {
  static const String _appTag = 'netmax-mesh-v1';
  static const int _port = 42424;
  static final InternetAddress _multicastAddress = InternetAddress(
    '239.1.42.99',
  );

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  String _selfUserId = '';
  MeshMessageHandler? _onMessage;

  @override
  bool get isSupported => true;

  @override
  bool get isRunning => _socket != null;

  @override
  Future<void> start({
    required String userId,
    required String userName,
    required MeshMessageHandler onMessage,
  }) async {
    _selfUserId = userId.trim();
    _onMessage = onMessage;
    if (_selfUserId.isEmpty) {
      throw const FormatException('Mesh userId is empty.');
    }

    if (_socket != null) {
      return;
    }

    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _port,
      reuseAddress: true,
      reusePort: true,
    );
    socket.broadcastEnabled = true;
    socket.multicastHops = 1;
    socket.joinMulticast(_multicastAddress);
    socket.readEventsEnabled = true;
    socket.writeEventsEnabled = false;
    _socket = socket;

    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final current = datagram!;
        try {
          final decoded = jsonDecode(
            utf8.decode(current.data, allowMalformed: true),
          );
          if (decoded is! Map) {
            continue;
          }
          final map = decoded.cast<String, dynamic>();
          if ((map['app']?.toString() ?? '') != _appTag) {
            continue;
          }
          final type = (map['type']?.toString() ?? '').trim();
          if (type != 'mesh_message' && type != 'mesh_ack') {
            continue;
          }
          final senderId = (map['senderId']?.toString() ?? '').trim();
          if (senderId.isEmpty || senderId == _selfUserId) {
            continue;
          }

          _onMessage?.call(map);
        } catch (_) {
          // Ignore malformed packets.
        }
      }
    });
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        socket.leaveMulticast(_multicastAddress);
      } catch (_) {}
      socket.close();
    }
  }

  @override
  Future<bool> sendText({
    required String messageId,
    required String userId,
    required String userName,
    required String text,
    required String createdAtIso,
    required String chatId,
    Map<String, dynamic>? replyTo,
  }) async {
    final socket = _socket;
    if (socket == null) {
      return false;
    }

    final replyEntry = replyTo == null
        ? null
        : <String, dynamic>{'replyTo': replyTo};

    final payload = <String, dynamic>{
      'app': _appTag,
      'type': 'mesh_message',
      'id': messageId,
      'senderId': userId,
      'senderName': userName,
      'createdAt': createdAtIso,
      'chatId': chatId,
      'chatType': 'group',
      'messageType': 'text',
      'text': text,
      ...?replyEntry,
    };

    return _sendPacket(payload);
  }

  @override
  Future<bool> sendAck({
    required String messageId,
    required String userId,
    required String targetUserId,
    required String createdAtIso,
  }) async {
    final payload = <String, dynamic>{
      'app': _appTag,
      'type': 'mesh_ack',
      'id': messageId,
      'senderId': userId,
      'targetUserId': targetUserId,
      'createdAt': createdAtIso,
    };

    return _sendPacket(payload);
  }

  bool _sendPacket(Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) {
      return false;
    }

    try {
      final bytes = utf8.encode(jsonEncode(payload));
      final sent = socket.send(bytes, _multicastAddress, _port);
      return sent > 0;
    } catch (_) {
      return false;
    }
  }
}
