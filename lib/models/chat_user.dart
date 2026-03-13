class ChatUser {
  const ChatUser({required this.id, required this.name, this.isMe = false});

  final String id;
  final String name;
  final bool isMe;
}
