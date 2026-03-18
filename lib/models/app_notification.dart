// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

enum NotificationKind { presence, typing, message, file, system }

class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.createdAt,
  });

  final String id;
  final NotificationKind kind;
  final String title;
  final String description;
  final DateTime createdAt;
}
