abstract class SystemNotificationServiceBase {
  Future<void> initialize();
  Future<void> show({required String title, required String body});
}
