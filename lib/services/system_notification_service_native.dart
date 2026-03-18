// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'system_notification_service_base.dart';

SystemNotificationServiceBase createSystemNotificationService() {
  return _NativeSystemNotificationService();
}

class _NativeSystemNotificationService
    implements SystemNotificationServiceBase {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
      linux: LinuxInitializationSettings(
        defaultActionName: 'Open notification',
      ),
      windows: WindowsInitializationSettings(
        appName: 'NetMax Messenger',
        appUserModelId: 'NetMax.Messenger.App',
        guid: '6f2a8f68-cf7f-4de0-88dd-fbb52be6de40',
      ),
    );

    await _plugin.initialize(initializationSettings);

    await _requestPermissions();
    _initialized = true;
  }

  Future<void> _requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();

    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  @override
  Future<void> show({required String title, required String body}) async {
    if (!_initialized) {
      return;
    }

    final notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'netmax_general_channel',
        'NetMax Notifications',
        channelDescription: 'System notifications for NetMax messenger events',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: const DarwinNotificationDetails(),
      macOS: const DarwinNotificationDetails(),
      linux: const LinuxNotificationDetails(),
      windows: const WindowsNotificationDetails(),
    );

    final id = DateTime.now().microsecondsSinceEpoch.remainder(2147483647);
    await _plugin.show(id, title, body, notificationDetails);
  }
}
