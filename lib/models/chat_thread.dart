enum ChatThreadType { group, direct }

class ChatThread {
  const ChatThread({
    required this.id,
    required this.title,
    required this.type,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.unreadCount = 0,
  });

  final String id;
  final String title;
  final ChatThreadType type;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final int unreadCount;
}
