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

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.senderName,
    required this.createdAt,
    required this.type,
    required this.isScheduled,
    this.text,
    this.attachment,
    this.replyTo,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final attachmentJson = json['attachment'];
    final replyJson = json['replyTo'];

    return ChatMessage(
      id: json['id']?.toString() ?? '',
      chatId: (json['chatId']?.toString() ?? 'group-general').trim(),
      senderId: json['senderId']?.toString() ?? '',
      senderName: json['senderName']?.toString() ?? 'Unknown',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      type: MessageTypeX.fromValue(json['type']?.toString() ?? 'text'),
      isScheduled: json['scheduled'] == true,
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
    );
  }

  final String id;
  final String chatId;
  final String senderId;
  final String senderName;
  final DateTime createdAt;
  final MessageType type;
  final bool isScheduled;
  final String? text;
  final MessageAttachment? attachment;
  final MessageReplyInfo? replyTo;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chatId': chatId,
      'senderId': senderId,
      'senderName': senderName,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'type': type.value,
      'scheduled': isScheduled,
      'text': text,
      'attachment': attachment?.toJson(),
      'replyTo': replyTo?.toJson(),
    };
  }
}
