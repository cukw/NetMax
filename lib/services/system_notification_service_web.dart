// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;

import 'system_notification_service_base.dart';

SystemNotificationServiceBase createSystemNotificationService() {
  return _WebSystemNotificationService();
}

class _WebSystemNotificationService implements SystemNotificationServiceBase {
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    if (!html.Notification.supported) {
      _initialized = true;
      return;
    }

    if (html.Notification.permission != 'granted') {
      try {
        await html.Notification.requestPermission();
      } catch (_) {
        // Browser may block permission request until user gesture.
      }
    }

    _initialized = true;
  }

  @override
  Future<void> show({required String title, required String body}) async {
    if (!_initialized || !html.Notification.supported) {
      return;
    }

    if (html.Notification.permission != 'granted') {
      try {
        final permission = await html.Notification.requestPermission();
        if (permission != 'granted') {
          return;
        }
      } catch (_) {
        return;
      }
    }

    final safeTitle = _sanitizeNotificationText(title, maxLength: 120);
    final safeBody = _sanitizeNotificationText(body, maxLength: 280);
    if (safeTitle.isEmpty || safeBody.isEmpty) {
      return;
    }

    try {
      html.Notification(safeTitle, body: safeBody);
    } catch (_) {
      // Ignore browser-side notification failures.
    }
  }

  String _sanitizeNotificationText(String raw, {required int maxLength}) {
    final withoutControls = raw
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .trim();
    final collapsed = withoutControls.replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isEmpty) {
      return '';
    }
    final safe = const HtmlEscape(HtmlEscapeMode.element).convert(collapsed);
    if (safe.length <= maxLength) {
      return safe;
    }
    return '${safe.substring(0, maxLength - 1)}…';
  }
}
