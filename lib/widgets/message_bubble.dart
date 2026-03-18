import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/chat_message.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.currentUserLower,
    this.onAttachmentTap,
    this.onReply,
    this.onEdit,
    this.onDelete,
    this.onReactionToggle,
  });

  final ChatMessage message;
  final bool isMine;
  final String currentUserLower;
  final VoidCallback? onAttachmentTap;
  final ValueChanged<ChatMessage>? onReply;
  final ValueChanged<ChatMessage>? onEdit;
  final ValueChanged<ChatMessage>? onDelete;
  final Future<void> Function(ChatMessage message, String reaction)?
  onReactionToggle;

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
            const SizedBox(height: 5),
            if (message.replyTo != null) ...[
              _ReplyPreview(
                reply: message.replyTo!,
                textColor: textColor,
                isMine: isMine,
              ),
              const SizedBox(height: 7),
            ],
            if (hasFile) ...[
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
                children: message.reactions.entries.map((entry) {
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
                }).toList(growable: false),
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
                  Icon(
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
