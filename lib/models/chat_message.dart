enum MessageType { text, file, system }

class MessageAttachment {
  const MessageAttachment({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.extension,
  });

  final String name;
  final String path;
  final int sizeBytes;
  final String extension;
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
}
