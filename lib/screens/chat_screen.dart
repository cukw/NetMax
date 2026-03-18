import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/app_notification.dart';
import '../models/chat_message.dart';
import '../models/chat_thread.dart';
import '../providers/chat_provider.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _chatSearchController = TextEditingController();
  final TextEditingController _scheduledTextController =
      TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode(
    debugLabel: 'message_input_focus',
  );
  final FocusNode _chatSearchFocusNode = FocusNode(
    debugLabel: 'chat_search_focus',
  );

  int _lastMessageCount = 0;
  int _selectedTab = 0;
  ChatMessage? _replyToMessage;
  String? _lastWebPopupNotificationId;
  AppNotification? _webPopupNotification;
  Timer? _webPopupTimer;

  bool _scheduledEnabledDraft = false;
  String _scheduledTimeDraft = '09:00';
  String _scheduleSignature = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureMessageInputFocus(force: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _chatSearchController.dispose();
    _scheduledTextController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    _chatSearchFocusNode.dispose();
    _webPopupTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) {
      return;
    }

    _ensureMessageInputFocus(force: true);

    final chatProvider = context.read<ChatProvider>();
    if (chatProvider.userName.trim().isEmpty || chatProvider.isConnected) {
      return;
    }
    chatProvider.connect(force: true);
  }

  void _sendMessage(ChatProvider chatProvider) {
    final text = _messageController.text;
    chatProvider.sendText(text, replyTo: _replyToMessage);
    _messageController.clear();
    _replyToMessage = null;
    chatProvider.updateTypingStatus('');
    setState(() {});
    _scrollToBottom();
    _ensureMessageInputFocus(force: true);
  }

  Future<void> _sendFile(ChatProvider chatProvider) async {
    PreparedFileUpload? prepared;
    try {
      prepared = await chatProvider.pickFileForSending();
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = _readableErrorMessage(error);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    if (!mounted) {
      return;
    }

    if (prepared == null) {
      return;
    }

    final caption = await _showFileCaptionDialog(prepared.name);
    if (!mounted || caption == null) {
      return;
    }

    final error = await chatProvider.sendPickedFile(
      prepared,
      caption: caption,
      replyTo: _replyToMessage,
    );
    if (!mounted) {
      return;
    }

    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    _replyToMessage = null;
    setState(() {});
    _scrollToBottom();
    _ensureMessageInputFocus(force: true);
  }

  Future<String?> _showFileCaptionDialog(String fileName) async {
    final controller = TextEditingController();
    String? result;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Подпись к файлу'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  dialogContext,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Сообщение к файлу',
                  hintText: 'Например: Документ на согласование',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                result = controller.text.trim();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Отправить'),
            ),
          ],
        );
      },
    );

    controller.dispose();
    return result;
  }

  Future<void> _checkForUpdates(ChatProvider chatProvider) async {
    await chatProvider.checkForUpdates(notifyIfNoUpdate: true);
    if (!mounted) {
      return;
    }

    final error = chatProvider.updateError;
    if (error != null && error.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _installUpdate(ChatProvider chatProvider) async {
    final error = await chatProvider.openUpdateDownload();
    if (!mounted) {
      return;
    }

    final message =
        error ??
        'Ссылка на обновление открыта. Завершите установку на устройстве.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openAttachment(
    ChatProvider chatProvider,
    MessageAttachment attachment,
  ) async {
    final error = await chatProvider.openAttachment(attachment);
    if (!mounted || error == null) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _pickScheduleTime() async {
    final parts = _scheduledTimeDraft.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 9,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
    );

    final result = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: 'Время отправки',
    );
    if (result == null) {
      return;
    }

    setState(() {
      _scheduledTimeDraft =
          '${result.hour.toString().padLeft(2, '0')}:${result.minute.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _saveSchedule(ChatProvider chatProvider) async {
    final error = await chatProvider.saveScheduledMessageConfig(
      enabled: _scheduledEnabledDraft,
      text: _scheduledTextController.text,
      time: _scheduledTimeDraft,
    );

    if (!mounted) {
      return;
    }

    final message =
        error ??
        'Расписание сохранено. Сервер отправит сообщение в заданное время.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _syncScheduleDraft(ChatProvider chatProvider) {
    final signature =
        '${chatProvider.canUseScheduledMessages}|${chatProvider.scheduledEnabled}|${chatProvider.scheduledText}|${chatProvider.scheduledTime}|${chatProvider.scheduledLastSentDate}|${chatProvider.scheduledUpdatedAt?.millisecondsSinceEpoch ?? 0}';

    if (signature == _scheduleSignature) {
      return;
    }

    _scheduleSignature = signature;
    _scheduledEnabledDraft =
        chatProvider.canUseScheduledMessages && chatProvider.scheduledEnabled;
    _scheduledTimeDraft = chatProvider.scheduledTime;

    if (_scheduledTextController.text != chatProvider.scheduledText) {
      _scheduledTextController.text = chatProvider.scheduledText;
    }
  }

  void _syncWebMessagePopup(AppNotification? latestNotification) {
    if (!kIsWeb) {
      return;
    }
    if (latestNotification == null ||
        latestNotification.kind != NotificationKind.message) {
      return;
    }
    if (latestNotification.id == _lastWebPopupNotificationId) {
      return;
    }

    _lastWebPopupNotificationId = latestNotification.id;
    _webPopupTimer?.cancel();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _webPopupNotification = latestNotification;
      });
    });

    _webPopupTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _webPopupNotification = null;
      });
    });
  }

  void _startReply(ChatMessage message) {
    if (message.type == MessageType.system) {
      return;
    }
    setState(() {
      _replyToMessage = message;
    });
    _ensureMessageInputFocus(force: true);
  }

  void _cancelReply() {
    if (_replyToMessage == null) {
      return;
    }
    setState(() {
      _replyToMessage = null;
    });
    _ensureMessageInputFocus(force: true);
  }

  Future<void> _editMessage(
    ChatProvider chatProvider,
    ChatMessage message,
  ) async {
    final controller = TextEditingController(text: message.text ?? '');
    String? editedText;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Редактировать сообщение'),
          content: TextField(
            controller: controller,
            minLines: 2,
            maxLines: 6,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Новый текст'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                editedText = controller.text.trim();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (!mounted || editedText == null) {
      return;
    }

    final error = await chatProvider.editMessage(
      message: message,
      text: editedText!,
    );
    if (!mounted || error == null) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _deleteMessage(
    ChatProvider chatProvider,
    ChatMessage message,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Удалить сообщение'),
          content: const Text('Сообщение будет скрыто для всех участников чата.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Удалить'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    final error = await chatProvider.deleteMessage(message);
    if (!mounted || error == null) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _toggleReaction(
    ChatProvider chatProvider,
    ChatMessage message,
    String reaction,
  ) async {
    await chatProvider.toggleReaction(message, reaction);
  }

  void _ensureMessageInputFocus({bool force = false}) {
    if (!mounted || _selectedTab != 0) {
      return;
    }
    if (_chatSearchFocusNode.hasFocus) {
      return;
    }
    if (!force && _messageFocusNode.hasFocus) {
      return;
    }
    final scope = FocusScope.of(context);
    if (!scope.hasFocus || force || !_messageFocusNode.hasFocus) {
      scope.requestFocus(_messageFocusNode);
    }
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
    _syncScheduleDraft(chatProvider);

    final chats = chatProvider.chats;
    final messages = chatProvider.messages;
    final latestNotification = chatProvider.latestNotification;
    final canSend = _messageController.text.trim().isNotEmpty;

    _maybeScrollOnNewMessage(messages.length);
    _syncWebMessagePopup(latestNotification);

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
            tooltip: 'Проверить обновления',
            onPressed: chatProvider.isCheckingUpdates
                ? null
                : () => _checkForUpdates(chatProvider),
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  chatProvider.isCheckingUpdates
                      ? Icons.sync_rounded
                      : Icons.system_update_alt_rounded,
                ),
                if (chatProvider.isUpdateAvailable)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
              ],
            ),
          ),
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
        child: Stack(
          children: [
            _selectedTab == 0
                ? _buildChatTab(chatProvider, chats, messages, canSend)
                : _buildSettingsTab(chatProvider),
            if (kIsWeb && _webPopupNotification != null)
              _buildWebMessagePopup(_webPopupNotification!),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) {
          setState(() {
            _selectedTab = index;
          });
          if (index == 0) {
            _ensureMessageInputFocus(force: true);
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Чат',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Настройки',
          ),
        ],
      ),
    );
  }

  Widget _buildChatTab(
    ChatProvider chatProvider,
    List<ChatThread> chats,
    List<ChatMessage> messages,
    bool canSend,
  ) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1240),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showLeftSidebar = constraints.maxWidth >= 860;
            final sidebarThreads = _resolveSidebarThreads(
              chatProvider: chatProvider,
              source: chats,
              query: _chatSearchController.text,
            );

            return Column(
              children: [
                if (!kIsWeb && chatProvider.shouldShowUpdateBanner)
                  _buildUpdateBanner(chatProvider),
                if (chatProvider.isCheckingUpdates)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                Expanded(
                  child: showLeftSidebar
                      ? Row(
                          children: [
                            SizedBox(
                              width: 320,
                              child: _buildLeftSidebar(
                                chatProvider: chatProvider,
                                threads: sidebarThreads,
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: _buildConversationPane(
                                chatProvider: chatProvider,
                                messages: messages,
                                canSend: canSend,
                              ),
                            ),
                          ],
                        )
                      : _buildConversationPane(
                          chatProvider: chatProvider,
                          messages: messages,
                          canSend: canSend,
                          onOpenChats: () =>
                              _openChatsSheet(chatProvider, chats),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildLeftSidebar({
    required ChatProvider chatProvider,
    required List<ChatThread> threads,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
      child: Column(
        children: [
          TextField(
            controller: _chatSearchController,
            focusNode: _chatSearchFocusNode,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Поиск пользователя',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _chatSearchController.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Очистить',
                      onPressed: () {
                        _chatSearchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: threads.isEmpty
                ? Center(
                    child: Text(
                      _chatSearchController.text.trim().isEmpty
                          ? 'Нет активных диалогов'
                          : 'Пользователь не найден',
                    ),
                  )
                : ListView.separated(
                    itemCount: threads.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final thread = threads[index];
                      final selected = thread.id == chatProvider.selectedChatId;
                      final preview = thread.lastMessagePreview?.trim() ?? '';
                      final showPreview = preview.isNotEmpty;
                      final threadTitle = _displayThreadTitle(thread);
                      final timeLabel = thread.lastMessageAt == null
                          ? null
                          : DateFormat('HH:mm').format(thread.lastMessageAt!);

                      return Material(
                        color: selected
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _selectThread(chatProvider, thread),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  child: Icon(
                                    thread.type == ChatThreadType.group
                                        ? Icons.groups_rounded
                                        : Icons.person_rounded,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        threadTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (showPreview) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          preview,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (timeLabel != null)
                                      Text(
                                        timeLabel,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    if (thread.unreadCount > 0) ...[
                                      if (timeLabel != null)
                                        const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: Text(
                                          thread.unreadCount > 99
                                              ? '99+'
                                              : thread.unreadCount.toString(),
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onPrimary,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationPane({
    required ChatProvider chatProvider,
    required List<ChatMessage> messages,
    required bool canSend,
    VoidCallback? onOpenChats,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              if (onOpenChats != null)
                IconButton.filledTonal(
                  onPressed: onOpenChats,
                  tooltip: 'Диалоги',
                  icon: const Icon(Icons.menu_rounded),
                ),
              if (onOpenChats != null) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  chatProvider.selectedChatTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemCount: messages.length,
            itemBuilder: (context, index) {
              final message = messages[index];
              final isMine = chatProvider.isMyMessage(message);
              return MessageBubble(
                message: message,
                isMine: isMine,
                currentUserLower: chatProvider.userName.trim().toLowerCase(),
                onAttachmentTap: message.attachment == null
                    ? null
                    : () => _openAttachment(chatProvider, message.attachment!),
                onReply: message.type == MessageType.system
                    ? null
                    : _startReply,
                onEdit: (message.type == MessageType.system || !isMine)
                    ? null
                    : (msg) => _editMessage(chatProvider, msg),
                onDelete: (message.type == MessageType.system || !isMine)
                    ? null
                    : (msg) => _deleteMessage(chatProvider, msg),
                onReactionToggle: message.type == MessageType.system
                    ? null
                    : (msg, reaction) =>
                          _toggleReaction(chatProvider, msg, reaction),
              );
            },
          ),
        ),
        _buildComposer(chatProvider, canSend),
      ],
    );
  }

  Future<void> _openChatsSheet(
    ChatProvider chatProvider,
    List<ChatThread> source,
  ) async {
    var query = '';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final threads = _resolveSidebarThreads(
              chatProvider: chatProvider,
              source: source,
              query: query,
            );

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 12,
                  right: 12,
                  top: 8,
                  bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 12,
                ),
                child: SizedBox(
                  height: MediaQuery.of(sheetContext).size.height * 0.75,
                  child: Column(
                    children: [
                      TextField(
                        onChanged: (value) {
                          setSheetState(() {
                            query = value;
                          });
                        },
                        decoration: const InputDecoration(
                          hintText: 'Поиск пользователя',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: threads.isEmpty
                            ? const Center(
                                child: Text('Пользователь не найден'),
                              )
                            : ListView.builder(
                                itemCount: threads.length,
                                itemBuilder: (context, index) {
                                  final thread = threads[index];
                                  final preview =
                                      thread.lastMessagePreview?.trim() ?? '';
                                  final title = _displayThreadTitle(thread);
                                  return ListTile(
                                    leading: Icon(
                                      thread.type == ChatThreadType.group
                                          ? Icons.groups_rounded
                                          : Icons.person_rounded,
                                    ),
                                    title: Text(title),
                                    subtitle: preview.isEmpty
                                        ? null
                                        : Text(
                                            preview,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                    onTap: () {
                                      Navigator.of(sheetContext).pop();
                                      _selectThread(chatProvider, thread);
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<ChatThread> _resolveSidebarThreads({
    required ChatProvider chatProvider,
    required List<ChatThread> source,
    required String query,
  }) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return source;
    }

    final byId = <String, ChatThread>{};
    for (final thread in source) {
      final title = _displayThreadTitle(thread).toLowerCase();
      if (title.contains(normalized)) {
        byId[thread.id] = thread;
      }
    }

    for (final thread in chatProvider.searchDirectUsers(normalized)) {
      byId.putIfAbsent(thread.id, () => thread);
    }

    return byId.values.toList(growable: false);
  }

  String _displayThreadTitle(ChatThread thread) {
    if (thread.type == ChatThreadType.group) {
      return thread.title;
    }
    return thread.title.replaceFirst(RegExp(r'^ЛС:\s*'), '');
  }

  void _selectThread(ChatProvider chatProvider, ChatThread thread) {
    chatProvider.updateTypingStatus('');
    chatProvider.selectChat(thread.id);
    _messageController.clear();
    _chatSearchController.clear();
    _replyToMessage = null;
    setState(() {});
    _scrollToBottom();
    _ensureMessageInputFocus(force: true);
  }

  Widget _buildSettingsTab(ChatProvider chatProvider) {
    final theme = Theme.of(context);
    final lastSent = chatProvider.scheduledLastSentDate;
    final updatedAt = chatProvider.scheduledUpdatedAt;
    final canUseScheduledMessages = chatProvider.canUseScheduledMessages;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Подключение',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Сервер: ${chatProvider.serverUrl}'),
                    const SizedBox(height: 4),
                    Text('Пользователь: ${chatProvider.userName}'),
                    const SizedBox(height: 4),
                    Text(
                      'Шифрование: ${chatProvider.isEncryptionEnabled ? "включено" : "выключено"}',
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      onPressed: () => _openConnectionSheet(chatProvider),
                      icon: const Icon(Icons.cloud_outlined),
                      label: const Text('Изменить подключение'),
                    ),
                  ],
                ),
              ),
            ),
            if (canUseScheduledMessages) ...[
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Отправка по времени',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: _scheduledEnabledDraft,
                        title: const Text('Отправлять сообщение по времени'),
                        subtitle: const Text(
                          'Сервер сам отправит сообщение в указанное время.',
                        ),
                        onChanged: (value) {
                          setState(() {
                            _scheduledEnabledDraft = value;
                          });
                        },
                      ),
                      if (_scheduledEnabledDraft) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _scheduledTextController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Текст сообщения',
                            hintText: 'Введите сообщение для автo-отправки',
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: InputDecorator(
                                decoration: const InputDecoration(
                                  labelText: 'Время отправки',
                                ),
                                child: Text(
                                  _scheduledTimeDraft,
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _pickScheduleTime,
                              icon: const Icon(Icons.access_time_rounded),
                              label: const Text('Выбрать'),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: chatProvider.isSavingScheduledConfig
                                ? null
                                : () => _saveSchedule(chatProvider),
                            icon: chatProvider.isSavingScheduledConfig
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save_rounded),
                            label: const Text('Сохранить в JSON'),
                          ),
                          const SizedBox(width: 10),
                          if (chatProvider.isSavingScheduledConfig)
                            const Text('Сохраняем...'),
                        ],
                      ),
                      if (chatProvider.scheduledConfigError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          chatProvider.scheduledConfigError!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                      if (lastSent != null || updatedAt != null) ...[
                        const SizedBox(height: 10),
                        if (lastSent != null)
                          Text('Последняя автоотправка: $lastSent'),
                        if (updatedAt != null)
                          Text(
                            'Обновлено: ${DateFormat('dd.MM.yyyy HH:mm').format(updatedAt)}',
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWebMessagePopup(AppNotification notification) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withAlpha(70),
          alignment: Alignment.center,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(70),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notification.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  notification.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUpdateBanner(ChatProvider chatProvider) {
    final theme = Theme.of(context);
    final latestBuild = chatProvider.latestBuild ?? 0;
    final latestVersion = '${chatProvider.latestVersion}+$latestBuild';
    final notes = chatProvider.updateNotes;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer.withAlpha(200),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.system_update_alt_rounded,
                  size: 18,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Доступна новая версия: $latestVersion',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть',
                  onPressed: () => chatProvider.dismissUpdateBanner(),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Текущая версия: ${chatProvider.currentVersionLabel}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer.withAlpha(210),
              ),
            ),
            if (notes != null && notes.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                notes,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer.withAlpha(210),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: chatProvider.isCheckingUpdates
                      ? null
                      : () => _checkForUpdates(chatProvider),
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('Проверить'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _installUpdate(chatProvider),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Установить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer(ChatProvider chatProvider, bool canSend) {
    final reply = _replyToMessage;
    final replyPreviewText = reply == null
        ? null
        : ((reply.text ?? '').trim().isEmpty
              ? (reply.attachment?.name ?? 'Файл')
              : (reply.text ?? '').trim());

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          if (reply != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.reply_rounded, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ответ ${reply.senderName}: $replyPreviewText',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Отменить ответ',
                    onPressed: _cancelReply,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
          Row(
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
                  focusNode: _messageFocusNode,
                  autofocus: true,
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
                        ? 'Сообщение в ${chatProvider.selectedChatTitle}'
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
        ],
      ),
    );
  }

  Future<void> _openConnectionSheet(ChatProvider chatProvider) {
    final serverController = TextEditingController(
      text: chatProvider.serverUrl,
    );
    final subscriptionController = TextEditingController(
      text: chatProvider.subscriptionSourcesText,
    );
    final proxySubscriptionController = TextEditingController(
      text: chatProvider.proxySubscriptionSourcesText,
    );
    final userController = TextEditingController(text: chatProvider.userName);
    final passwordController = TextEditingController();
    final encryptionController = TextEditingController(
      text: chatProvider.encryptionKey,
    );
    var hasSavedPassword = chatProvider.hasSavedPasswordForUser(
      userController.text,
    );
    var obscurePassword = true;
    var obscureEncryption = true;

    final future = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
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
                    'Укажите WebSocket URL сервера, имя пользователя и пароль.',
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
                    controller: subscriptionController,
                    minLines: 2,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      labelText: 'Источники подписок (опционально)',
                      hintText:
                          'https://example.com/netmax-subscription.txt\nОдна ссылка на строку',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: proxySubscriptionController,
                    minLines: 2,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    decoration: const InputDecoration(
                      labelText: 'Proxy-подписки (native)',
                      hintText:
                          'http://proxy-list.local/proxies.txt\nПоддержка: http/https/socks5',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: userController,
                    onChanged: (value) {
                      setSheetState(() {
                        hasSavedPassword = chatProvider.hasSavedPasswordForUser(
                          value,
                        );
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Имя пользователя',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Пароль',
                      hintText: hasSavedPassword
                          ? 'Оставьте пустым, чтобы использовать сохраненный'
                          : 'Введите пароль',
                      suffixIcon: IconButton(
                        onPressed: () {
                          setSheetState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                        icon: Icon(
                          obscurePassword
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: encryptionController,
                    obscureText: obscureEncryption,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Ключ шифрования (опционально)',
                      hintText:
                          'Оставьте пустым, чтобы отправлять без шифрования',
                      suffixIcon: IconButton(
                        onPressed: () {
                          setSheetState(() {
                            obscureEncryption = !obscureEncryption;
                          });
                        },
                        icon: Icon(
                          obscureEncryption
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                        ),
                      ),
                    ),
                  ),
                  if (hasSavedPassword) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Пароль для этого пользователя уже сохранен на устройстве.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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
                                password: passwordController.text,
                                subscriptionSources:
                                    subscriptionController.text,
                                proxySubscriptionSources:
                                    proxySubscriptionController.text,
                                encryptionKey: encryptionController.text,
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
      },
    );
    return future.whenComplete(() {
      serverController.dispose();
      subscriptionController.dispose();
      proxySubscriptionController.dispose();
      userController.dispose();
      passwordController.dispose();
      encryptionController.dispose();
    });
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
