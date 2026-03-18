// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

class ChatUser {
  const ChatUser({required this.id, required this.name, this.isMe = false});

  final String id;
  final String name;
  final bool isMe;
}
