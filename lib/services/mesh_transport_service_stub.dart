import 'mesh_transport_service_base.dart';

MeshTransportServiceBase createMeshTransportService() {
  return _StubMeshTransportService();
}

class _StubMeshTransportService implements MeshTransportServiceBase {
  @override
  bool get isRunning => false;

  @override
  bool get isSupported => false;

  @override
  Future<void> start({
    required String userId,
    required String userName,
    required MeshMessageHandler onMessage,
  }) async {}

  @override
  Future<void> stop() async {}

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
    return false;
  }

  @override
  Future<bool> sendAck({
    required String messageId,
    required String userId,
    required String targetUserId,
    required String createdAtIso,
  }) async {
    return false;
  }
}
