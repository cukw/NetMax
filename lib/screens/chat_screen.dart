// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

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
  static const Duration _maxVoiceRecordingDuration = Duration(minutes: 3);
  static const int _messagesPageSize = 80;

  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _chatSearchController = TextEditingController();
  final TextEditingController _messageSearchController =
      TextEditingController();
  final TextEditingController _scheduledTextController =
      TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode(
    debugLabel: 'message_input_focus',
  );
  final FocusNode _chatSearchFocusNode = FocusNode(
    debugLabel: 'chat_search_focus',
  );
  final FocusNode _messageSearchFocusNode = FocusNode(
    debugLabel: 'message_search_focus',
  );

  int _lastMessageCount = 0;
  int _selectedTab = 0;
  ChatMessage? _replyToMessage;
  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _voiceStreamSubscription;
  final BytesBuilder _voicePcmBuffer = BytesBuilder(copy: false);
  bool _isRecordingVoice = false;
  DateTime? _voiceRecordingStartedAt;
  Duration _voiceRecordingDuration = Duration.zero;
  Timer? _voiceRecordingTimer;
  List<String> _mentionSuggestions = const <String>[];
  _MentionQueryContext? _mentionContext;

  bool _scheduledEnabledDraft = false;
  String _scheduledTimeDraft = '09:00';
  String _scheduleSignature = '';
  int _visibleMessageLimit = _messagesPageSize;
  String _messageWindowSignature = '';

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
    _voiceRecordingTimer?.cancel();
    _voiceStreamSubscription?.cancel();
    unawaited(_audioRecorder.dispose());
    _messageController.dispose();
    _chatSearchController.dispose();
    _messageSearchController.dispose();
    _scheduledTextController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    _chatSearchFocusNode.dispose();
    _messageSearchFocusNode.dispose();
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
    _clearMentionSuggestions();
    _replyToMessage = null;
    chatProvider.updateTypingStatus('');
    setState(() {});
    _scrollToBottom();
    _ensureMessageInputFocus(force: true);
  }

  Future<void> _reconnect(ChatProvider chatProvider) async {
    if (chatProvider.isConnected) {
      await chatProvider.disconnect();
    }
    await chatProvider.connect(force: true);
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

  void _onMessageChanged(ChatProvider chatProvider, String value) {
    chatProvider.updateTypingStatus(value);
    _updateMentionSuggestions(chatProvider);
    setState(() {});
  }

  void _syncMessageWindow(ChatProvider chatProvider) {
    final signature =
        '${chatProvider.selectedChatId}|${_messageSearchController.text.trim()}';
    if (signature == _messageWindowSignature) {
      return;
    }
    _messageWindowSignature = signature;
    _visibleMessageLimit = _messagesPageSize;
  }

  void _showMoreMessages() {
    setState(() {
      _visibleMessageLimit += _messagesPageSize;
    });
  }

  void _updateMentionSuggestions(ChatProvider chatProvider) {
    final text = _messageController.text;
    final selection = _messageController.selection;
    var cursor = selection.baseOffset;
    if (cursor < 0 || cursor > text.length) {
      cursor = text.length;
    }

    final context = _extractMentionContext(text: text, cursorOffset: cursor);
    if (context == null) {
      _clearMentionSuggestions();
      return;
    }

    final query = context.query.trim().toLowerCase();
    final candidates = chatProvider.mentionCandidates;
    final suggestions = candidates
        .where((name) {
          final normalized = name.trim().toLowerCase();
          if (normalized.isEmpty) {
            return false;
          }
          return query.isEmpty || normalized.contains(query);
        })
        .toList(growable: false);

    _mentionContext = context;
    _mentionSuggestions = suggestions.take(8).toList(growable: false);
  }

  _MentionQueryContext? _extractMentionContext({
    required String text,
    required int cursorOffset,
  }) {
    if (text.isEmpty || cursorOffset <= 0) {
      return null;
    }

    final left = text.substring(0, cursorOffset);
    final atIndex = left.lastIndexOf('@');
    if (atIndex < 0) {
      return null;
    }

    if (atIndex > 0) {
      final beforeAt = left[atIndex - 1];
      if (!RegExp(r'[\s(>\[\{]').hasMatch(beforeAt)) {
        return null;
      }
    }

    final query = left.substring(atIndex + 1);
    if (query.contains(RegExp(r'[\s\n\r]'))) {
      return null;
    }

    return _MentionQueryContext(
      start: atIndex,
      end: cursorOffset,
      query: query,
    );
  }

  void _clearMentionSuggestions() {
    _mentionContext = null;
    _mentionSuggestions = const <String>[];
  }

  void _insertMention(String userName) {
    final context = _mentionContext;
    if (context == null) {
      return;
    }

    final text = _messageController.text;
    if (context.start < 0 ||
        context.end < context.start ||
        context.end > text.length) {
      _clearMentionSuggestions();
      return;
    }

    final mentionText = '@$userName ';
    final newText =
        '${text.substring(0, context.start)}$mentionText${text.substring(context.end)}';
    final cursor = context.start + mentionText.length;
    _messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _clearMentionSuggestions();
    _ensureMessageInputFocus(force: true);
    setState(() {});
  }

  Future<void> _toggleVoiceRecording(ChatProvider chatProvider) async {
    if (_isRecordingVoice) {
      await _stopVoiceRecording(chatProvider);
      return;
    }
    await _startVoiceRecording(chatProvider);
  }

  Future<void> _startVoiceRecording(ChatProvider chatProvider) async {
    if (!chatProvider.isConnected) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала подключитесь к серверу.')),
      );
      return;
    }

    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нет доступа к микрофону.')),
        );
        return;
      }

      _voicePcmBuffer.clear();
      await _voiceStreamSubscription?.cancel();
      _voiceStreamSubscription = null;

      final stream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );

      _voiceStreamSubscription = stream.listen((chunk) {
        _voicePcmBuffer.add(chunk);
      });

      _voiceRecordingTimer?.cancel();
      _voiceRecordingStartedAt = DateTime.now();
      _voiceRecordingDuration = Duration.zero;
      _voiceRecordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final startedAt = _voiceRecordingStartedAt;
        if (!mounted || startedAt == null) {
          return;
        }
        final elapsed = DateTime.now().difference(startedAt);
        setState(() {
          _voiceRecordingDuration = elapsed;
        });
        if (elapsed >= _maxVoiceRecordingDuration) {
          unawaited(_stopVoiceRecording(chatProvider));
        }
      });

      setState(() {
        _isRecordingVoice = true;
      });
    } on MissingPluginException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Плагин записи не инициализирован. Нужна полная пересборка приложения.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось начать запись: $error')),
      );
    }
  }

  Future<void> _stopVoiceRecording(ChatProvider chatProvider) async {
    try {
      await _audioRecorder.stop();
      await _voiceStreamSubscription?.cancel();
      _voiceStreamSubscription = null;
    } catch (_) {}

    _voiceRecordingTimer?.cancel();
    _voiceRecordingTimer = null;

    final pcmBytes = _voicePcmBuffer.takeBytes();
    final duration = _voiceRecordingDuration;
    _voiceRecordingStartedAt = null;
    _voiceRecordingDuration = Duration.zero;

    if (mounted) {
      setState(() {
        _isRecordingVoice = false;
      });
    } else {
      _isRecordingVoice = false;
    }

    if (pcmBytes.isEmpty || duration.inMilliseconds < 500) {
      return;
    }

    final wavBytes = _wrapPcm16AsWav(
      pcmBytes: Uint8List.fromList(pcmBytes),
      sampleRate: 16000,
      channels: 1,
    );
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final prepared = PreparedFileUpload(
      name: 'voice_$stamp.wav',
      extension: 'WAV',
      sizeBytes: wavBytes.length,
      bytes: wavBytes,
    );

    final error = await chatProvider.sendPickedFile(
      prepared,
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

  Uint8List _wrapPcm16AsWav({
    required Uint8List pcmBytes,
    required int sampleRate,
    required int channels,
  }) {
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final dataLength = pcmBytes.length;
    final fileLength = 36 + dataLength;

    final header = ByteData(44);
    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    header.setUint32(4, fileLength, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, dataLength, Endian.little);

    final bytes = BytesBuilder(copy: false);
    bytes.add(header.buffer.asUint8List());
    bytes.add(pcmBytes);
    return bytes.toBytes();
  }

  String _formatRecordingDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
          content: const Text(
            'Сообщение будет скрыто для всех участников чата.',
          ),
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

  Future<void> _toggleFavorite(
    ChatProvider chatProvider,
    ChatMessage message,
  ) async {
    await chatProvider.toggleFavorite(message);
  }

  Future<void> _togglePin(
    ChatProvider chatProvider,
    ChatMessage message,
  ) async {
    await chatProvider.togglePinForChat(message);
  }

  Future<void> _forwardMessage(
    ChatProvider chatProvider,
    ChatMessage message,
  ) async {
    final targetChatId = await _pickForwardTargetChat(chatProvider);
    if (!mounted || targetChatId == null) {
      return;
    }

    final error = await chatProvider.forwardMessage(
      message: message,
      targetChatId: targetChatId,
    );
    if (!mounted) {
      return;
    }

    final feedback = error ?? 'Сообщение переслано.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(feedback)));
  }

  Future<String?> _pickForwardTargetChat(ChatProvider chatProvider) async {
    final source = chatProvider.chats;
    var query = '';
    String? selectedChatId;

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
                          hintText: 'Куда переслать',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: threads.isEmpty
                            ? const Center(child: Text('Чат не найден'))
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
                                    trailing:
                                        thread.id == chatProvider.selectedChatId
                                        ? const Icon(Icons.check_circle_outline)
                                        : null,
                                    onTap: () {
                                      selectedChatId = thread.id;
                                      Navigator.of(sheetContext).pop();
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

    return selectedChatId;
  }

  List<ChatMessage> _filteredMessagesForView(
    ChatProvider chatProvider,
    List<ChatMessage> source,
  ) {
    final query = _messageSearchController.text.trim();
    if (query.isEmpty) {
      return source;
    }
    return chatProvider.searchMessages(
      query: query,
      chatId: chatProvider.selectedChatId,
    );
  }

  void _ensureMessageInputFocus({bool force = false}) {
    if (!mounted || _selectedTab != 0) {
      return;
    }
    if (_chatSearchFocusNode.hasFocus) {
      return;
    }
    if (_messageSearchFocusNode.hasFocus) {
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
    final canSend = _messageController.text.trim().isNotEmpty;

    _syncMessageWindow(chatProvider);
    _maybeScrollOnNewMessage(messages.length);

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            _SendShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.enter, meta: true):
            _SendShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.escape):
            _CancelReplyShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _FocusChatsShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _FocusChatsShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.keyM, control: true):
            _FocusMessageSearchShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.keyM, meta: true):
            _FocusMessageSearchShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true):
            _AttachFileShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.keyA, meta: true, shift: true):
            _AttachFileShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true):
            _ReconnectShortcutIntent(),
        SingleActivator(LogicalKeyboardKey.keyR, meta: true, shift: true):
            _ReconnectShortcutIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SendShortcutIntent: CallbackAction<_SendShortcutIntent>(
            onInvoke: (_) {
              if (_selectedTab == 0 && canSend) {
                _sendMessage(chatProvider);
              }
              return null;
            },
          ),
          _CancelReplyShortcutIntent:
              CallbackAction<_CancelReplyShortcutIntent>(
                onInvoke: (_) {
                  if (_selectedTab == 0) {
                    _cancelReply();
                  }
                  return null;
                },
              ),
          _FocusChatsShortcutIntent: CallbackAction<_FocusChatsShortcutIntent>(
            onInvoke: (_) {
              if (_selectedTab == 0) {
                _chatSearchFocusNode.requestFocus();
              }
              return null;
            },
          ),
          _FocusMessageSearchShortcutIntent:
              CallbackAction<_FocusMessageSearchShortcutIntent>(
                onInvoke: (_) {
                  if (_selectedTab == 0) {
                    _messageSearchFocusNode.requestFocus();
                    _messageSearchController.selection = TextSelection(
                      baseOffset: 0,
                      extentOffset: _messageSearchController.text.length,
                    );
                  }
                  return null;
                },
              ),
          _AttachFileShortcutIntent: CallbackAction<_AttachFileShortcutIntent>(
            onInvoke: (_) {
              if (_selectedTab == 0) {
                unawaited(_sendFile(chatProvider));
              }
              return null;
            },
          ),
          _ReconnectShortcutIntent: CallbackAction<_ReconnectShortcutIntent>(
            onInvoke: (_) {
              unawaited(_reconnect(chatProvider));
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
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
                    style: TextStyle(
                      fontSize: 12,
                      color: _statusColor(chatProvider),
                    ),
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
                  tooltip: 'Параметры входа',
                  onPressed: () => _openConnectionSheet(chatProvider),
                  icon: const Icon(Icons.cloud_outlined),
                ),
                IconButton(
                  tooltip: chatProvider.isConnected
                      ? 'Отключиться'
                      : 'Подключиться',
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
                    PopupMenuItem(
                      value: ThemeMode.dark,
                      child: Text('Тёмная тема'),
                    ),
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
              child: _selectedTab == 0
                  ? _buildChatTab(chatProvider, chats, messages, canSend)
                  : _buildSettingsTab(chatProvider),
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
          ),
        ),
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
    final allVisibleMessages = _filteredMessagesForView(chatProvider, messages);
    final totalVisible = allVisibleMessages.length;
    final startIndex = totalVisible > _visibleMessageLimit
        ? totalVisible - _visibleMessageLimit
        : 0;
    final visibleMessages = startIndex == 0
        ? allVisibleMessages
        : allVisibleMessages.sublist(startIndex);
    final hiddenCount = startIndex;
    final pinned = chatProvider.pinnedMessageForSelectedChat;
    final searchActive = _messageSearchController.text.trim().isNotEmpty;

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
              IconButton(
                tooltip: 'Очистить поиск',
                onPressed: searchActive
                    ? () {
                        _messageSearchController.clear();
                        setState(() {});
                      }
                    : null,
                icon: const Icon(Icons.search_off_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            controller: _messageSearchController,
            focusNode: _messageSearchFocusNode,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Поиск по сообщениям в текущем чате',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: searchActive
                  ? IconButton(
                      tooltip: 'Очистить',
                      onPressed: () {
                        _messageSearchController.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded),
                    )
                  : null,
            ),
          ),
        ),
        if (pinned != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.push_pin_rounded, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ((pinned.text ?? '').trim().isEmpty
                              ? (pinned.attachment?.name ??
                                    'Закрепленное сообщение')
                              : pinned.text!)
                          .trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Снять закреп',
                    onPressed: () => _togglePin(chatProvider, pinned),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
          ),
        if (hiddenCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _showMoreMessages,
                icon: const Icon(Icons.expand_less_rounded),
                label: Text('Показать ещё ($hiddenCount)'),
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            itemCount: visibleMessages.length,
            itemBuilder: (context, index) {
              final message = visibleMessages[index];
              final isMine = chatProvider.isMyMessage(message);
              final voicePlaybackUrl =
                  message.isVoiceMessage && message.attachment != null
                  ? chatProvider.attachmentPlaybackUrl(message.attachment!)
                  : null;
              return MessageBubble(
                message: message,
                isMine: isMine,
                currentUserLower: chatProvider.userName.trim().toLowerCase(),
                voicePlaybackUrl: voicePlaybackUrl,
                isFavorite: chatProvider.isFavoriteMessage(message.id),
                isPinned: chatProvider.isPinnedMessage(
                  message.chatId,
                  message.id,
                ),
                onAttachmentTap: message.attachment == null
                    ? null
                    : () => _openAttachment(chatProvider, message.attachment!),
                onReply: message.type == MessageType.system
                    ? null
                    : _startReply,
                onForward: message.type == MessageType.system
                    ? null
                    : (msg) => _forwardMessage(chatProvider, msg),
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
                onToggleFavorite: message.type == MessageType.system
                    ? null
                    : (msg) => _toggleFavorite(chatProvider, msg),
                onTogglePin: message.type == MessageType.system
                    ? null
                    : (msg) => _togglePin(chatProvider, msg),
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
    _clearMentionSuggestions();
    _messageSearchController.clear();
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
                    Text('Пользователь: ${chatProvider.userName}'),
                    const SizedBox(height: 4),
                    Text(
                      'Шифрование: ${chatProvider.isEncryptionEnabled ? "включено (серверный ключ)" : "выключено"}',
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      onPressed: () => _openConnectionSheet(chatProvider),
                      icon: const Icon(Icons.cloud_outlined),
                      label: const Text('Параметры входа'),
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
    final queuedCount = chatProvider.queuedOutgoingTextCount;
    final hasMessageSearch = _messageSearchController.text.trim().isNotEmpty;
    final showQuickActions =
        queuedCount > 0 ||
        reply != null ||
        hasMessageSearch ||
        !chatProvider.isConnected;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          if (_mentionSuggestions.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Theme.of(context).dividerColor.withAlpha(120),
                ),
              ),
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _mentionSuggestions.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: Theme.of(context).dividerColor),
                itemBuilder: (context, index) {
                  final name = _mentionSuggestions[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.alternate_email_rounded),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _insertMention(name),
                  );
                },
              ),
            ),
          if (_isRecordingVoice)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.mic_rounded,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Идет запись голосового: ${_formatRecordingDuration(_voiceRecordingDuration)}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _toggleVoiceRecording(chatProvider),
                    child: const Text('Стоп'),
                  ),
                ],
              ),
            ),
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
          if (showQuickActions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (reply != null)
                    ActionChip(
                      avatar: const Icon(Icons.reply_rounded, size: 16),
                      label: const Text('Отменить ответ'),
                      onPressed: _cancelReply,
                    ),
                  if (hasMessageSearch)
                    ActionChip(
                      avatar: const Icon(Icons.search_off_rounded, size: 16),
                      label: const Text('Сбросить поиск'),
                      onPressed: () {
                        _messageSearchController.clear();
                        setState(() {});
                      },
                    ),
                  ActionChip(
                    avatar: Icon(
                      chatProvider.isConnected
                          ? Icons.restart_alt_rounded
                          : Icons.link_rounded,
                      size: 16,
                    ),
                    label: Text(
                      chatProvider.isConnected
                          ? 'Переподключить'
                          : 'Подключиться',
                    ),
                    onPressed: () => unawaited(_reconnect(chatProvider)),
                  ),
                  ActionChip(
                    avatar: const Icon(
                      Icons.vertical_align_bottom_rounded,
                      size: 16,
                    ),
                    label: const Text('Вниз'),
                    onPressed: _scrollToBottom,
                  ),
                  if (queuedCount > 0)
                    Chip(
                      avatar: const Icon(Icons.cloud_upload_rounded, size: 16),
                      label: Text('В очереди: $queuedCount'),
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
              GestureDetector(
                onLongPressStart: (_) {
                  if (_isRecordingVoice) {
                    return;
                  }
                  unawaited(_startVoiceRecording(chatProvider));
                },
                onLongPressEnd: (_) {
                  if (!_isRecordingVoice) {
                    return;
                  }
                  unawaited(_stopVoiceRecording(chatProvider));
                },
                child: IconButton.filledTonal(
                  onPressed: () => _toggleVoiceRecording(chatProvider),
                  tooltip: _isRecordingVoice
                      ? 'Остановить запись'
                      : 'Записать ГС (или удерживайте)',
                  icon: Icon(
                    _isRecordingVoice
                        ? Icons.stop_circle_rounded
                        : Icons.mic_rounded,
                  ),
                ),
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
                  onChanged: (value) => _onMessageChanged(chatProvider, value),
                  onSubmitted: (_) => _sendMessage(chatProvider),
                  decoration: InputDecoration(
                    hintText: chatProvider.isConnected
                        ? 'Сообщение в ${chatProvider.selectedChatTitle}'
                        : 'Сообщение в ${chatProvider.selectedChatTitle} (уйдет в очередь)',
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
    final subscriptionController = TextEditingController(
      text: chatProvider.subscriptionSourcesText,
    );
    final proxySubscriptionController = TextEditingController(
      text: chatProvider.proxySubscriptionSourcesText,
    );
    final userController = TextEditingController(text: chatProvider.userName);
    final passwordController = TextEditingController();
    final phoneController = TextEditingController(text: chatProvider.authPhone);
    final emailController = TextEditingController(text: chatProvider.authEmail);
    final codeController = TextEditingController();
    final profileController = TextEditingController(
      text: chatProvider.authProfileName.isEmpty
          ? chatProvider.userName
          : chatProvider.authProfileName,
    );
    var selectedAuthMode = chatProvider.authMode;
    var requestingPhoneCode = false;
    var hasSavedPassword = chatProvider.hasSavedPasswordForUser(
      userController.text,
    );
    var obscurePassword = true;

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
                    'Параметры входа',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Выберите способ авторизации и параметры аккаунта.',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ChatAuthMode>(
                    key: ValueKey<ChatAuthMode>(selectedAuthMode),
                    initialValue: selectedAuthMode,
                    decoration: const InputDecoration(
                      labelText: 'Метод авторизации',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: ChatAuthMode.password,
                        child: Text('Логин + пароль'),
                      ),
                      DropdownMenuItem(
                        value: ChatAuthMode.phone,
                        child: Text('Регистрация: телефон + email'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setSheetState(() {
                        selectedAuthMode = value;
                      });
                    },
                  ),
                  if (selectedAuthMode == ChatAuthMode.phone) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Телефон, email и код используются только для создания нового аккаунта.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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
                  if (selectedAuthMode == ChatAuthMode.password) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: userController,
                      onChanged: (value) {
                        setSheetState(() {
                          hasSavedPassword = chatProvider
                              .hasSavedPasswordForUser(value);
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
                    if (hasSavedPassword) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Пароль для этого пользователя уже сохранен на устройстве.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ] else ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Номер телефона',
                        hintText: '+79991234567',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Email для кода',
                        hintText: 'user@example.com',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: codeController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Код подтверждения',
                              hintText: '6 цифр',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.tonal(
                          onPressed: requestingPhoneCode
                              ? null
                              : () async {
                                  setSheetState(() {
                                    requestingPhoneCode = true;
                                  });
                                  try {
                                    final info = await chatProvider
                                        .requestEmailAuthCode(
                                          phone: phoneController.text,
                                          email: emailController.text,
                                        );
                                    if (!context.mounted) {
                                      return;
                                    }
                                    final devMatch = RegExp(
                                      r'DEV-код:\s*(\d{6})',
                                    ).firstMatch(info);
                                    if (devMatch != null) {
                                      codeController.text = devMatch.group(1)!;
                                    }
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(info)),
                                    );
                                  } catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    final message = _readableErrorMessage(
                                      error,
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(message)),
                                    );
                                  } finally {
                                    if (context.mounted) {
                                      setSheetState(() {
                                        requestingPhoneCode = false;
                                      });
                                    }
                                  }
                                },
                          child: Text(
                            requestingPhoneCode ? '...' : 'Запросить код',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: profileController,
                      decoration: const InputDecoration(
                        labelText: 'Имя профиля',
                        hintText: 'Например, Иван Петров',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: passwordController,
                      obscureText: obscurePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Пароль нового аккаунта',
                        hintText: 'Минимум 4 символа',
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
                                userName: userController.text,
                                password: passwordController.text,
                                subscriptionSources:
                                    subscriptionController.text,
                                proxySubscriptionSources:
                                    proxySubscriptionController.text,
                                authMode: selectedAuthMode,
                                phone: phoneController.text,
                                email: emailController.text,
                                phoneCode: codeController.text,
                                profileName: profileController.text,
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
      subscriptionController.dispose();
      proxySubscriptionController.dispose();
      userController.dispose();
      passwordController.dispose();
      phoneController.dispose();
      emailController.dispose();
      codeController.dispose();
      profileController.dispose();
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

class _MentionQueryContext {
  const _MentionQueryContext({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}

class _SendShortcutIntent extends Intent {
  const _SendShortcutIntent();
}

class _CancelReplyShortcutIntent extends Intent {
  const _CancelReplyShortcutIntent();
}

class _FocusChatsShortcutIntent extends Intent {
  const _FocusChatsShortcutIntent();
}

class _FocusMessageSearchShortcutIntent extends Intent {
  const _FocusMessageSearchShortcutIntent();
}

class _AttachFileShortcutIntent extends Intent {
  const _AttachFileShortcutIntent();
}

class _ReconnectShortcutIntent extends Intent {
  const _ReconnectShortcutIntent();
}
