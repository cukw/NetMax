// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

typedef MeshMessageHandler = void Function(Map<String, dynamic> payload);

abstract class MeshTransportServiceBase {
  bool get isSupported;
  bool get isRunning;

  Future<void> start({
    required String userId,
    required String userName,
    required MeshMessageHandler onMessage,
  });

  Future<void> stop();

  Future<bool> sendText({
    required String messageId,
    required String userId,
    required String userName,
    required String text,
    required String createdAtIso,
    required String chatId,
    Map<String, dynamic>? replyTo,
  });

  Future<bool> sendAck({
    required String messageId,
    required String userId,
    required String targetUserId,
    required String createdAtIso,
  });
}
