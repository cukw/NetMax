import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/app_notification.dart';
import '../providers/chat_provider.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = 0;

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage(ChatProvider chatProvider) {
    final text = _messageController.text;
    chatProvider.sendText(text);
    _messageController.clear();
    chatProvider.updateTypingStatus('');
    setState(() {});
    _scrollToBottom();
  }

  Future<void> _sendFile(ChatProvider chatProvider) async {
    final error = await chatProvider.pickAndSendFile();
    if (!mounted) {
      return;
    }

    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }

      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  void _maybeScrollOnNewMessage(int currentMessageCount) {
    if (currentMessageCount == _lastMessageCount) {
      return;
    }
    _lastMessageCount = currentMessageCount;
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final chatProvider = context.watch<ChatProvider>();
    final messages = chatProvider.messages;
    final latestNotification = chatProvider.latestNotification;
    final canSend = _messageController.text.trim().isNotEmpty;

    _maybeScrollOnNewMessage(messages.length);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NetMax Messenger',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20),
            ),
            Text(
              chatProvider.connectionStatusLine,
              style: TextStyle(fontSize: 12, color: _statusColor(chatProvider)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Настройки подключения',
            onPressed: () => _openConnectionSheet(chatProvider),
            icon: const Icon(Icons.cloud_outlined),
          ),
          IconButton(
            tooltip: chatProvider.isConnected ? 'Отключиться' : 'Подключиться',
            onPressed: chatProvider.isConnected
                ? chatProvider.disconnect
                : () => chatProvider.connect(force: true),
            icon: Icon(
              chatProvider.isConnected
                  ? Icons.link_off_rounded
                  : Icons.link_rounded,
            ),
          ),
          IconButton(
            tooltip: 'Уведомления',
            onPressed: () => _openNotificationsSheet(chatProvider),
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_outlined),
                if (chatProvider.notificationCount > 0)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        chatProvider.notificationCount > 99
                            ? '99+'
                            : chatProvider.notificationCount.toString(),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          PopupMenuButton<ThemeMode>(
            tooltip: 'Тема',
            initialValue: chatProvider.themeMode,
            onSelected: chatProvider.setThemeMode,
            icon: Icon(_themeIcon(chatProvider.themeMode)),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: ThemeMode.light,
                child: Text('Светлая тема'),
              ),
              PopupMenuItem(value: ThemeMode.dark, child: Text('Тёмная тема')),
              PopupMenuItem(
                value: ThemeMode.system,
                child: Text('Как в системе'),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              children: [
                if (latestNotification != null)
                  _buildActivityBanner(latestNotification),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final isMine = message.senderId == chatProvider.me.id;
                      return MessageBubble(message: message, isMine: isMine);
                    },
                  ),
                ),
                _buildComposer(chatProvider, canSend),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActivityBanner(AppNotification notification) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withAlpha(170),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              _iconForNotification(notification.kind),
              size: 18,
              color: theme.colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${notification.title}: ${notification.description}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              DateFormat('HH:mm').format(notification.createdAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer.withAlpha(190),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer(ChatProvider chatProvider, bool canSend) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        children: [
          IconButton.filledTonal(
            onPressed: chatProvider.isPickingFile
                ? null
                : () => _sendFile(chatProvider),
            tooltip: 'Отправить файл',
            icon: chatProvider.isPickingFile
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.attach_file_rounded),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _messageController,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onChanged: (value) {
                chatProvider.updateTypingStatus(value);
                setState(() {});
              },
              onSubmitted: (_) => _sendMessage(chatProvider),
              decoration: InputDecoration(
                hintText: chatProvider.isConnected
                    ? 'Введите сообщение'
                    : 'Сначала подключитесь к серверу',
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: canSend ? () => _sendMessage(chatProvider) : null,
            tooltip: 'Отправить',
            icon: const Icon(Icons.send_rounded),
          ),
        ],
      ),
    );
  }

  Future<void> _openConnectionSheet(ChatProvider chatProvider) {
    final serverController = TextEditingController(
      text: chatProvider.serverUrl,
    );
    final userController = TextEditingController(text: chatProvider.userName);

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Подключение к серверу',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Укажите WebSocket URL сервера и имя пользователя из списка авторизованных.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: serverController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'ws://localhost:8080/ws',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: userController,
                decoration: const InputDecoration(
                  labelText: 'Имя пользователя',
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                      child: const Text('Отмена'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        try {
                          await chatProvider.applyConnectionSettings(
                            serverUrl: serverController.text,
                            userName: userController.text,
                          );
                          if (!context.mounted) {
                            return;
                          }
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Настройки сохранены. Выполнено подключение.',
                              ),
                            ),
                          );
                        } catch (error) {
                          if (!context.mounted) {
                            return;
                          }
                          final message = _readableErrorMessage(error);
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text(message)));
                        }
                      },
                      child: const Text('Сохранить и подключить'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openNotificationsSheet(ChatProvider chatProvider) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final notifications = chatProvider.notifications;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Уведомления',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: notifications.isEmpty
                          ? null
                          : () {
                              chatProvider.clearNotifications();
                              Navigator.of(context).pop();
                            },
                      child: const Text('Очистить'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: notifications.isEmpty
                      ? const Center(child: Text('Пока нет уведомлений'))
                      : ListView.separated(
                          itemCount: notifications.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final notification = notifications[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                radius: 16,
                                child: Icon(
                                  _iconForNotification(notification.kind),
                                  size: 18,
                                ),
                              ),
                              title: Text(notification.title),
                              subtitle: Text(notification.description),
                              trailing: Text(
                                DateFormat(
                                  'HH:mm',
                                ).format(notification.createdAt),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _statusColor(ChatProvider chatProvider) {
    if (chatProvider.connectionStatus == ChatConnectionStatus.disconnected) {
      return Colors.redAccent;
    }
    if (chatProvider.connectionStatus == ChatConnectionStatus.connecting) {
      return Colors.orange;
    }
    if (chatProvider.typingUsers.isNotEmpty) {
      return Colors.lightBlueAccent;
    }
    return Colors.green;
  }

  IconData _themeIcon(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.light => Icons.light_mode_rounded,
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };
  }

  IconData _iconForNotification(NotificationKind kind) {
    return switch (kind) {
      NotificationKind.presence => Icons.wifi_tethering_rounded,
      NotificationKind.typing => Icons.keyboard_alt_rounded,
      NotificationKind.message => Icons.chat_bubble_rounded,
      NotificationKind.file => Icons.attach_file_rounded,
      NotificationKind.system => Icons.info_outline_rounded,
    };
  }

  String _readableErrorMessage(Object error) {
    final raw = error.toString().trim();
    const prefix = 'FormatException:';
    if (raw.startsWith(prefix)) {
      return raw.substring(prefix.length).trim();
    }
    if (raw.isEmpty) {
      return 'Некорректные параметры подключения.';
    }
    return raw;
  }
}
