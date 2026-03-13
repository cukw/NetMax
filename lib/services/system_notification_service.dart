import 'system_notification_service_base.dart';
import 'system_notification_service_stub.dart'
    if (dart.library.io) 'system_notification_service_native.dart'
    if (dart.library.html) 'system_notification_service_web.dart'
    as impl;

class SystemNotificationService {
  SystemNotificationService._();

  static final SystemNotificationServiceBase instance = impl
      .createSystemNotificationService();
}
