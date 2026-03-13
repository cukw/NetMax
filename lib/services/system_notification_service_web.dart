// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

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
      return;
    }

    try {
      html.Notification(title, body: body);
    } catch (_) {
      // Ignore browser-side notification failures.
    }
  }
}
