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

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.createdAt,
    required this.type,
    this.text,
    this.attachment,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final attachmentJson = json['attachment'];

    return ChatMessage(
      id: json['id']?.toString() ?? '',
      senderId: json['senderId']?.toString() ?? '',
      senderName: json['senderName']?.toString() ?? 'Unknown',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      type: MessageTypeX.fromValue(json['type']?.toString() ?? 'text'),
      text: json['text']?.toString(),
      attachment: attachmentJson is Map<String, dynamic>
          ? MessageAttachment.fromJson(attachmentJson)
          : attachmentJson is Map
          ? MessageAttachment.fromJson(attachmentJson.cast<String, dynamic>())
          : null,
    );
  }

  factory ChatMessage.text({
    required String id,
    required String senderId,
    required String senderName,
    required DateTime createdAt,
    required String text,
  }) {
    return ChatMessage(
      id: id,
      senderId: senderId,
      senderName: senderName,
      createdAt: createdAt,
      type: MessageType.text,
      text: text,
    );
  }

  factory ChatMessage.file({
    required String id,
    required String senderId,
    required String senderName,
    required DateTime createdAt,
    required MessageAttachment attachment,
    String? text,
  }) {
    return ChatMessage(
      id: id,
      senderId: senderId,
      senderName: senderName,
      createdAt: createdAt,
      type: MessageType.file,
      text: text,
      attachment: attachment,
    );
  }

  factory ChatMessage.system({
    required String id,
    required DateTime createdAt,
    required String text,
  }) {
    return ChatMessage(
      id: id,
      senderId: 'system',
      senderName: 'System',
      createdAt: createdAt,
      type: MessageType.system,
      text: text,
    );
  }

  final String id;
  final String senderId;
  final String senderName;
  final DateTime createdAt;
  final MessageType type;
  final String? text;
  final MessageAttachment? attachment;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'type': type.value,
      'text': text,
      'attachment': attachment?.toJson(),
    };
  }
}
