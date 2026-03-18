// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

abstract class SystemNotificationServiceBase {
  Future<void> initialize();
  Future<void> show({required String title, required String body});
}
