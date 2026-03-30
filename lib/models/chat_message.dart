// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

enum MessageType { text, file, system }

extension MessageTypeX on MessageType {
  String get value {
    return switch (this) {
      MessageType.text => 'text',
      MessageType.file => 'file',
      MessageType.system => 'system',
    };
  }

  static MessageType fromValue(String raw) {
    return switch (raw.toLowerCase()) {
      'text' => MessageType.text,
      'file' => MessageType.file,
      'system' => MessageType.system,
      _ => MessageType.text,
    };
  }
}

enum MessageLocalState { none, sending, queued, failed }

extension MessageLocalStateX on MessageLocalState {
  String get value {
    return switch (this) {
      MessageLocalState.none => 'none',
      MessageLocalState.sending => 'sending',
      MessageLocalState.queued => 'queued',
      MessageLocalState.failed => 'failed',
    };
  }

  static MessageLocalState fromValue(String raw) {
    return switch (raw.toLowerCase()) {
      'sending' => MessageLocalState.sending,
      'queued' => MessageLocalState.queued,
      'failed' => MessageLocalState.failed,
      _ => MessageLocalState.none,
    };
  }
}

class MessageAttachment {
  const MessageAttachment({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.extension,
  });

  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    return MessageAttachment(
      name: json['name']?.toString() ?? 'file',
      path: json['path']?.toString() ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      extension: json['extension']?.toString() ?? 'FILE',
    );
  }

  final String name;
  final String path;
  final int sizeBytes;
  final String extension;

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'path': path,
      'sizeBytes': sizeBytes,
      'extension': extension,
    };
  }
}

class MessageReplyInfo {
  const MessageReplyInfo({
    required this.messageId,
    required this.senderName,
    required this.text,
    required this.type,
  });

  factory MessageReplyInfo.fromJson(Map<String, dynamic> json) {
    return MessageReplyInfo(
      messageId: (json['messageId']?.toString() ?? '').trim(),
      senderName: (json['senderName']?.toString() ?? 'Unknown').trim(),
      text: (json['text']?.toString() ?? '').trim(),
      type: MessageTypeX.fromValue(json['type']?.toString() ?? 'text'),
    );
  }

  final String messageId;
  final String senderName;
  final String text;
  final MessageType type;

  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'senderName': senderName,
      'text': text,
      'type': type.value,
    };
  }
}

class MessageForwardInfo {
  const MessageForwardInfo({
    required this.messageId,
    required this.senderName,
    required this.text,
    required this.type,
  });

  factory MessageForwardInfo.fromJson(Map<String, dynamic> json) {
    return MessageForwardInfo(
      messageId: (json['messageId']?.toString() ?? '').trim(),
      senderName: (json['senderName']?.toString() ?? 'Unknown').trim(),
      text: (json['text']?.toString() ?? '').trim(),
      type: MessageTypeX.fromValue(json['type']?.toString() ?? 'text'),
    );
  }

  final String messageId;
  final String senderName;
  final String text;
  final MessageType type;

  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'senderName': senderName,
      'text': text,
      'type': type.value,
    };
  }
}

class MessageEditHistoryItem {
  const MessageEditHistoryItem({required this.text, required this.editedAt});

  factory MessageEditHistoryItem.fromJson(Map<String, dynamic> json) {
    return MessageEditHistoryItem(
      text: (json['text']?.toString() ?? '').trim(),
      editedAt:
          DateTime.tryParse(json['editedAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  final String text;
  final DateTime editedAt;

  Map<String, dynamic> toJson() {
    return {'text': text, 'editedAt': editedAt.toUtc().toIso8601String()};
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.senderName,
    required this.createdAt,
    required this.type,
    required this.isScheduled,
    this.isEdited = false,
    this.editedAt,
    this.isDeleted = false,
    this.deletedAt,
    this.editHistory = const <MessageEditHistoryItem>[],
    this.reactions = const <String, List<String>>{},
    this.mentions = const <String>[],
    this.deliveredTo = const <String>[],
    this.readBy = const <String>[],
    this.isEncrypted = false,
    this.encryption,
    this.localState = MessageLocalState.none,
    this.text,
    this.attachment,
    this.replyTo,
    this.forwardedFrom,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final attachmentJson = json['attachment'];
    final replyJson = json['replyTo'];
    final forwardedJson = json['forwardedFrom'];
    final reactionsJson = json['reactions'];
    final editHistoryRaw = json['editHistory'];
    final createdAtRaw =
        json['createdAt'] ??
        json['created_at'] ??
        json['createdAtIso'] ??
        json['timestamp'];

    return ChatMessage(
      id: json['id']?.toString() ?? '',
      chatId: (json['chatId']?.toString() ?? 'group-general').trim(),
      senderId: json['senderId']?.toString() ?? '',
      senderName: json['senderName']?.toString() ?? 'Unknown',
      createdAt:
          DateTime.tryParse(createdAtRaw?.toString() ?? '') ?? DateTime.now(),
      type: MessageTypeX.fromValue(json['type']?.toString() ?? 'text'),
      isScheduled: json['scheduled'] == true,
      isEdited: json['edited'] == true || json['isEdited'] == true,
      editedAt: DateTime.tryParse(json['editedAt']?.toString() ?? ''),
      isDeleted: json['deleted'] == true || json['isDeleted'] == true,
      deletedAt: DateTime.tryParse(json['deletedAt']?.toString() ?? ''),
      editHistory: editHistoryRaw is List
          ? editHistoryRaw
                .map(
                  (item) => item is Map
                      ? MessageEditHistoryItem.fromJson(
                          item.cast<String, dynamic>(),
                        )
                      : null,
                )
                .whereType<MessageEditHistoryItem>()
                .toList(growable: false)
          : const <MessageEditHistoryItem>[],
      reactions: reactionsJson is Map
          ? reactionsJson.map<String, List<String>>((key, value) {
              final users = value is List
                  ? value
                        .map((entry) => entry.toString().trim())
                        .where((entry) => entry.isNotEmpty)
                        .toList(growable: false)
                  : const <String>[];
              return MapEntry(key.toString(), users);
            })
          : const <String, List<String>>{},
      mentions: json['mentions'] is List
          ? (json['mentions'] as List)
                .map((entry) => entry.toString().trim().toLowerCase())
                .where((entry) => entry.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      deliveredTo: json['deliveredTo'] is List
          ? (json['deliveredTo'] as List)
                .map((entry) => entry.toString().trim().toLowerCase())
                .where((entry) => entry.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      readBy: json['readBy'] is List
          ? (json['readBy'] as List)
                .map((entry) => entry.toString().trim().toLowerCase())
                .where((entry) => entry.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      isEncrypted: json['encrypted'] == true || json['isEncrypted'] == true,
      encryption: json['encryption'] is Map<String, dynamic>
          ? json['encryption'] as Map<String, dynamic>
          : json['encryption'] is Map
          ? (json['encryption'] as Map).cast<String, dynamic>()
          : null,
      localState: MessageLocalStateX.fromValue(
        json['localState']?.toString() ?? 'none',
      ),
      text: json['text']?.toString(),
      attachment: attachmentJson is Map<String, dynamic>
          ? MessageAttachment.fromJson(attachmentJson)
          : attachmentJson is Map
          ? MessageAttachment.fromJson(attachmentJson.cast<String, dynamic>())
          : null,
      replyTo: replyJson is Map<String, dynamic>
          ? MessageReplyInfo.fromJson(replyJson)
          : replyJson is Map
          ? MessageReplyInfo.fromJson(replyJson.cast<String, dynamic>())
          : null,
      forwardedFrom: forwardedJson is Map<String, dynamic>
          ? MessageForwardInfo.fromJson(forwardedJson)
          : forwardedJson is Map
          ? MessageForwardInfo.fromJson(forwardedJson.cast<String, dynamic>())
          : null,
    );
  }

  factory ChatMessage.text({
    required String id,
    required String chatId,
    required String senderId,
    required String senderName,
    required DateTime createdAt,
    required String text,
    MessageReplyInfo? replyTo,
    MessageForwardInfo? forwardedFrom,
  }) {
    return ChatMessage(
      id: id,
      chatId: chatId,
      senderId: senderId,
      senderName: senderName,
      createdAt: createdAt,
      type: MessageType.text,
      isScheduled: false,
      text: text,
      replyTo: replyTo,
      forwardedFrom: forwardedFrom,
      mentions: const <String>[],
      reactions: const <String, List<String>>{},
      deliveredTo: const <String>[],
      readBy: const <String>[],
    );
  }

  factory ChatMessage.file({
    required String id,
    required String chatId,
    required String senderId,
    required String senderName,
    required DateTime createdAt,
    required MessageAttachment attachment,
    String? text,
    MessageReplyInfo? replyTo,
    MessageForwardInfo? forwardedFrom,
  }) {
    return ChatMessage(
      id: id,
      chatId: chatId,
      senderId: senderId,
      senderName: senderName,
      createdAt: createdAt,
      type: MessageType.file,
      isScheduled: false,
      text: text,
      attachment: attachment,
      replyTo: replyTo,
      forwardedFrom: forwardedFrom,
      mentions: const <String>[],
      reactions: const <String, List<String>>{},
      deliveredTo: const <String>[],
      readBy: const <String>[],
    );
  }

  factory ChatMessage.system({
    required String id,
    required DateTime createdAt,
    required String text,
    String chatId = 'group-general',
  }) {
    return ChatMessage(
      id: id,
      chatId: chatId,
      senderId: 'system',
      senderName: 'System',
      createdAt: createdAt,
      type: MessageType.system,
      isScheduled: false,
      text: text,
      mentions: const <String>[],
      reactions: const <String, List<String>>{},
      deliveredTo: const <String>[],
      readBy: const <String>[],
    );
  }

  final String id;
  final String chatId;
  final String senderId;
  final String senderName;
  final DateTime createdAt;
  final MessageType type;
  final bool isScheduled;
  final bool isEdited;
  final DateTime? editedAt;
  final bool isDeleted;
  final DateTime? deletedAt;
  final List<MessageEditHistoryItem> editHistory;
  final Map<String, List<String>> reactions;
  final List<String> mentions;
  final List<String> deliveredTo;
  final List<String> readBy;
  final bool isEncrypted;
  final Map<String, dynamic>? encryption;
  final MessageLocalState localState;
  final String? text;
  final MessageAttachment? attachment;
  final MessageReplyInfo? replyTo;
  final MessageForwardInfo? forwardedFrom;

  bool get isVoiceMessage {
    if (type != MessageType.file || attachment == null) {
      return false;
    }
    final extension = attachment!.extension.trim().toLowerCase();
    return extension == 'm4a' ||
        extension == 'aac' ||
        extension == 'wav' ||
        extension == 'ogg' ||
        extension == 'mp3' ||
        extension == 'opus';
  }

  ChatMessage copyWith({
    String? id,
    String? chatId,
    String? senderId,
    String? senderName,
    DateTime? createdAt,
    MessageType? type,
    bool? isScheduled,
    bool? isEdited,
    DateTime? editedAt,
    bool? isDeleted,
    DateTime? deletedAt,
    List<MessageEditHistoryItem>? editHistory,
    Map<String, List<String>>? reactions,
    List<String>? mentions,
    List<String>? deliveredTo,
    List<String>? readBy,
    bool? isEncrypted,
    Map<String, dynamic>? encryption,
    MessageLocalState? localState,
    String? text,
    MessageAttachment? attachment,
    MessageReplyInfo? replyTo,
    MessageForwardInfo? forwardedFrom,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      createdAt: createdAt ?? this.createdAt,
      type: type ?? this.type,
      isScheduled: isScheduled ?? this.isScheduled,
      isEdited: isEdited ?? this.isEdited,
      editedAt: editedAt ?? this.editedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
      editHistory: editHistory ?? this.editHistory,
      reactions: reactions ?? this.reactions,
      mentions: mentions ?? this.mentions,
      deliveredTo: deliveredTo ?? this.deliveredTo,
      readBy: readBy ?? this.readBy,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      encryption: encryption ?? this.encryption,
      localState: localState ?? this.localState,
      text: text ?? this.text,
      attachment: attachment ?? this.attachment,
      replyTo: replyTo ?? this.replyTo,
      forwardedFrom: forwardedFrom ?? this.forwardedFrom,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chatId': chatId,
      'senderId': senderId,
      'senderName': senderName,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'type': type.value,
      'scheduled': isScheduled,
      'edited': isEdited,
      'editedAt': editedAt?.toUtc().toIso8601String(),
      'deleted': isDeleted,
      'deletedAt': deletedAt?.toUtc().toIso8601String(),
      'editHistory': editHistory.map((item) => item.toJson()).toList(),
      'reactions': reactions,
      'mentions': mentions,
      'deliveredTo': deliveredTo,
      'readBy': readBy,
      'encrypted': isEncrypted,
      'encryption': encryption,
      'localState': localState.value,
      'text': text,
      'attachment': attachment?.toJson(),
      'replyTo': replyTo?.toJson(),
      'forwardedFrom': forwardedFrom?.toJson(),
    };
  }
}
