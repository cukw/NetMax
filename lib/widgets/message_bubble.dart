// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 cukw

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../models/chat_message.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.currentUserLower,
    this.voicePlaybackUrl,
    this.isFavorite = false,
    this.isPinned = false,
    this.onAttachmentTap,
    this.onReply,
    this.onForward,
    this.onEdit,
    this.onDelete,
    this.onReactionToggle,
    this.onToggleFavorite,
    this.onTogglePin,
  });

  final ChatMessage message;
  final bool isMine;
  final String currentUserLower;
  final String? voicePlaybackUrl;
  final bool isFavorite;
  final bool isPinned;
  final VoidCallback? onAttachmentTap;
  final ValueChanged<ChatMessage>? onReply;
  final ValueChanged<ChatMessage>? onForward;
  final ValueChanged<ChatMessage>? onEdit;
  final ValueChanged<ChatMessage>? onDelete;
  final Future<void> Function(ChatMessage message, String reaction)?
  onReactionToggle;
  final ValueChanged<ChatMessage>? onToggleFavorite;
  final ValueChanged<ChatMessage>? onTogglePin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (message.type == MessageType.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withAlpha(190),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              message.text ?? '',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final hasFile =
        message.type == MessageType.file &&
        message.attachment != null &&
        !message.isDeleted;
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surface;
    final textColor = isMine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final senderLabel = isMine ? 'Вы' : message.senderName;
    final messageText = message.isDeleted
        ? 'Сообщение удалено'
        : (message.text ?? '');
    final quickReactions = const <String>['👍', '❤️', '🔥', '😂', '👏', '😮'];

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: isMine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              senderLabel,
              style: TextStyle(
                color: textColor.withAlpha(200),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (isPinned) ...[
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.push_pin_rounded,
                    size: 12,
                    color: textColor.withAlpha(190),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Закреплено',
                    style: TextStyle(
                      color: textColor.withAlpha(180),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 5),
            if (message.forwardedFrom != null) ...[
              _ForwardPreview(
                forward: message.forwardedFrom!,
                textColor: textColor,
                isMine: isMine,
              ),
              const SizedBox(height: 7),
            ],
            if (message.replyTo != null) ...[
              _ReplyPreview(
                reply: message.replyTo!,
                textColor: textColor,
                isMine: isMine,
              ),
              const SizedBox(height: 7),
            ],
            if (hasFile) ...[
              if (message.isVoiceMessage && voicePlaybackUrl != null)
                _VoiceAttachmentView(
                  attachment: message.attachment!,
                  playbackUrl: voicePlaybackUrl!,
                  textColor: textColor,
                  isMine: isMine,
                  onDownload: onAttachmentTap,
                )
              else
                _FileAttachmentView(
                  attachment: message.attachment!,
                  textColor: textColor,
                  isMine: isMine,
                  onTap: onAttachmentTap,
                ),
              if (message.text != null && message.text!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  message.text!,
                  style: TextStyle(color: textColor, fontSize: 14),
                ),
              ],
            ] else
              Text(
                messageText,
                style: TextStyle(
                  color: textColor,
                  fontSize: 15,
                  fontStyle: message.isDeleted
                      ? FontStyle.italic
                      : FontStyle.normal,
                ),
              ),
            if (message.reactions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: message.reactions.entries
                    .map((entry) {
                      final users = entry.value;
                      final reactedByMe = users.any(
                        (user) => user.trim().toLowerCase() == currentUserLower,
                      );
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: onReactionToggle == null
                            ? null
                            : () => onReactionToggle!(message, entry.key),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: reactedByMe
                                ? textColor.withAlpha(34)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: textColor.withAlpha(90)),
                          ),
                          child: Text(
                            '${entry.key} ${users.length}',
                            style: TextStyle(
                              color: textColor.withAlpha(220),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    })
                    .toList(growable: false),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onReactionToggle != null && !message.isDeleted)
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    icon: Icon(
                      Icons.add_reaction_outlined,
                      color: textColor.withAlpha(170),
                    ),
                    onSelected: (reaction) {
                      onReactionToggle!(message, reaction);
                    },
                    itemBuilder: (context) => quickReactions
                        .map(
                          (reaction) => PopupMenuItem<String>(
                            value: reaction,
                            child: Text(reaction),
                          ),
                        )
                        .toList(growable: false),
                  ),
                if (onToggleFavorite != null && !message.isDeleted)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onToggleFavorite!(message),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        isFavorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        size: 16,
                        color: isFavorite
                            ? Colors.amber
                            : textColor.withAlpha(170),
                      ),
                    ),
                  ),
                if (onTogglePin != null && !message.isDeleted)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onTogglePin!(message),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        isPinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 16,
                        color: textColor.withAlpha(170),
                      ),
                    ),
                  ),
                if (onReply != null && !message.isDeleted)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onReply!(message),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.reply_rounded,
                        size: 15,
                        color: textColor.withAlpha(170),
                      ),
                    ),
                  ),
                if (onForward != null && !message.isDeleted)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onForward!(message),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        Icons.forward_rounded,
                        size: 15,
                        color: textColor.withAlpha(170),
                      ),
                    ),
                  ),
                if ((onEdit != null || onDelete != null) &&
                    isMine &&
                    !message.isDeleted)
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      color: textColor.withAlpha(170),
                    ),
                    onSelected: (value) {
                      if (value == 'edit') {
                        onEdit?.call(message);
                      } else if (value == 'delete') {
                        onDelete?.call(message);
                      }
                    },
                    itemBuilder: (context) => <PopupMenuEntry<String>>[
                      if (onEdit != null)
                        const PopupMenuItem<String>(
                          value: 'edit',
                          child: Text('Редактировать'),
                        ),
                      if (onDelete != null)
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('Удалить'),
                        ),
                    ],
                  ),
                if (onReply != null || onReactionToggle != null)
                  const SizedBox(width: 4),
                Text(
                  DateFormat('HH:mm').format(message.createdAt),
                  style: TextStyle(
                    color: textColor.withAlpha(170),
                    fontSize: 11,
                  ),
                ),
                if (message.isEdited && !message.isDeleted) ...[
                  const SizedBox(width: 6),
                  Text(
                    'изм.',
                    style: TextStyle(
                      color: textColor.withAlpha(170),
                      fontSize: 10,
                    ),
                  ),
                ],
                if (isMine && !message.isDeleted) ...[
                  const SizedBox(width: 6),
                  switch (message.localState) {
                    MessageLocalState.sending => Icon(
                      Icons.schedule_rounded,
                      size: 15,
                      color: textColor.withAlpha(170),
                    ),
                    MessageLocalState.queued => Icon(
                      Icons.cloud_upload_rounded,
                      size: 15,
                      color: Colors.orangeAccent,
                    ),
                    MessageLocalState.failed => Icon(
                      Icons.error_outline_rounded,
                      size: 15,
                      color: Colors.redAccent,
                    ),
                    _ => Icon(
                      message.readBy.length > 1
                          ? Icons.done_all_rounded
                          : (message.deliveredTo.length > 1
                                ? Icons.done_all_rounded
                                : Icons.done_rounded),
                      size: 15,
                      color: message.readBy.length > 1
                          ? Colors.lightBlueAccent
                          : textColor.withAlpha(170),
                    ),
                  },
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({
    required this.reply,
    required this.textColor,
    required this.isMine,
  });

  final MessageReplyInfo reply;
  final Color textColor;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final background = isMine
        ? Colors.white.withAlpha(38)
        : Theme.of(context).colorScheme.primary.withAlpha(18);

    final kindText = switch (reply.type) {
      MessageType.file => '[Файл] ',
      MessageType.system => '[Система] ',
      _ => '',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: textColor.withAlpha(160), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reply.senderName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor.withAlpha(190),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$kindText${reply.text}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor.withAlpha(200), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ForwardPreview extends StatelessWidget {
  const _ForwardPreview({
    required this.forward,
    required this.textColor,
    required this.isMine,
  });

  final MessageForwardInfo forward;
  final Color textColor;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final background = isMine
        ? Colors.white.withAlpha(34)
        : Theme.of(context).colorScheme.primary.withAlpha(16);

    final kindText = switch (forward.type) {
      MessageType.file => '[Файл] ',
      MessageType.system => '[Система] ',
      _ => '',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: textColor.withAlpha(145), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Переслано от ${forward.senderName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor.withAlpha(190),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$kindText${forward.text}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor.withAlpha(200), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _VoiceAttachmentView extends StatefulWidget {
  const _VoiceAttachmentView({
    required this.attachment,
    required this.playbackUrl,
    required this.textColor,
    required this.isMine,
    this.onDownload,
  });

  final MessageAttachment attachment;
  final String playbackUrl;
  final Color textColor;
  final bool isMine;
  final VoidCallback? onDownload;

  @override
  State<_VoiceAttachmentView> createState() => _VoiceAttachmentViewState();
}

class _VoiceAttachmentViewState extends State<_VoiceAttachmentView> {
  AudioPlayer? _player;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlayerState _playerState = PlayerState(false, ProcessingState.idle);
  double _playbackSpeed = 1.0;
  bool _isLoading = false;
  bool _sourceLoaded = false;

  @override
  void initState() {
    super.initState();
  }

  void _bindPlayerStreams(AudioPlayer player) {
    _durationSubscription = player.durationStream.listen((duration) {
      if (!mounted || duration == null) {
        return;
      }
      setState(() {
        _duration = duration;
      });
    });
    _positionSubscription = player.positionStream.listen((position) {
      if (!mounted) {
        return;
      }
      setState(() {
        _position = position;
      });
    });
    _playerStateSubscription = player.playerStateStream.listen((state) {
      if (!mounted) {
        return;
      }
      if (state.processingState == ProcessingState.completed) {
        unawaited(player.seek(Duration.zero));
      }
      setState(() {
        _playerState = state;
      });
    });
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) {
      return existing;
    }
    final created = AudioPlayer();
    _player = created;
    _bindPlayerStreams(created);
    return created;
  }

  @override
  void didUpdateWidget(covariant _VoiceAttachmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackUrl == widget.playbackUrl) {
      return;
    }
    _sourceLoaded = false;
    _duration = Duration.zero;
    _position = Duration.zero;
    final player = _player;
    if (player != null) {
      unawaited(player.stop());
    }
  }

  @override
  void dispose() {
    _durationSubscription?.cancel();
    _positionSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_isLoading) {
      return;
    }

    try {
      final player = _ensurePlayer();
      if (player.playing) {
        await player.pause();
        return;
      }

      if (!_sourceLoaded) {
        setState(() {
          _isLoading = true;
        });
        await player.setUrl(widget.playbackUrl);
        _sourceLoaded = true;
      }

      await player.play();
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось воспроизвести голосовое.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _seekTo(double valueMs) async {
    final position = Duration(milliseconds: valueMs.round());
    final player = _player;
    if (player == null) {
      return;
    }
    await player.seek(position);
  }

  Future<void> _toggleSpeed() async {
    final player = _player;
    final next = _playbackSpeed >= 1.9
        ? 1.0
        : (_playbackSpeed >= 1.4 ? 2.0 : 1.5);
    if (player != null) {
      await player.setSpeed(next);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _playbackSpeed = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.isMine
        ? Colors.white.withAlpha(42)
        : Theme.of(context).colorScheme.primary.withAlpha(22);
    final maxDuration = _duration > Duration.zero
        ? _duration
        : const Duration(milliseconds: 1);
    final sliderMax = maxDuration.inMilliseconds.toDouble();
    final sliderValue = _position.inMilliseconds
        .clamp(0, maxDuration.inMilliseconds)
        .toDouble();
    final isPlaying = _playerState.playing;
    final isBusy =
        _isLoading ||
        _playerState.processingState == ProcessingState.loading ||
        _playerState.processingState == ProcessingState.buffering;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                onPressed: isBusy ? null : _togglePlay,
                icon: isBusy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: widget.textColor,
                        ),
                      )
                    : Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: widget.textColor,
                        size: 20,
                      ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.textColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              if (widget.onDownload != null)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  tooltip: 'Скачать файл',
                  onPressed: widget.onDownload,
                  icon: Icon(
                    Icons.download_rounded,
                    color: widget.textColor.withAlpha(220),
                    size: 18,
                  ),
                ),
              TextButton(
                onPressed: _toggleSpeed,
                style: TextButton.styleFrom(
                  minimumSize: const Size(36, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '${_playbackSpeed.toStringAsFixed(_playbackSpeed == 1.0 ? 0 : 1)}x',
                  style: TextStyle(
                    color: widget.textColor.withAlpha(210),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
            ),
            child: Slider(
              value: sliderValue,
              min: 0,
              max: sliderMax <= 0 ? 1 : sliderMax,
              onChanged: (value) {
                _seekTo(value);
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatAudioDuration(_position),
                style: TextStyle(
                  color: widget.textColor.withAlpha(170),
                  fontSize: 11,
                ),
              ),
              Text(
                _formatAudioDuration(_duration),
                style: TextStyle(
                  color: widget.textColor.withAlpha(170),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatAudioDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _FileAttachmentView extends StatelessWidget {
  const _FileAttachmentView({
    required this.attachment,
    required this.textColor,
    required this.isMine,
    required this.onTap,
  });

  final MessageAttachment attachment;
  final Color textColor;
  final bool isMine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final background = isMine
        ? Colors.white.withAlpha(42)
        : Theme.of(context).colorScheme.primary.withAlpha(22);

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_rounded, color: textColor, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${attachment.extension} • ${_formatFileSize(attachment.sizeBytes)}',
                      style: TextStyle(
                        color: textColor.withAlpha(180),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.download_rounded,
                color: textColor.withAlpha(220),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }

    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }

    final mb = kb / 1024;
    if (mb < 1024) {
      return '${mb.toStringAsFixed(1)} MB';
    }

    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }
}
