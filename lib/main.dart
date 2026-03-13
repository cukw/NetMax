import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/chat_provider.dart';
import 'screens/chat_screen.dart';
import 'services/system_notification_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemNotificationService.instance.initialize();
  runApp(const NetMaxMessengerApp());
}

class NetMaxMessengerApp extends StatelessWidget {
  const NetMaxMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(),
      child: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'NetMax Messenger',
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: chatProvider.themeMode,
            home: const ChatScreen(),
          );
        },
      ),
    );
  }
}
