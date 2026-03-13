import 'system_notification_service_base.dart';

SystemNotificationServiceBase createSystemNotificationService() {
  return _StubSystemNotificationService();
}

class _StubSystemNotificationService implements SystemNotificationServiceBase {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> show({required String title, required String body}) async {}
}
