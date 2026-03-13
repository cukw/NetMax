import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/chat_message.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message, required this.isMine});

  final ChatMessage message;
  final bool isMine;

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
        message.type == MessageType.file && message.attachment != null;
    final bubbleColor = isMine
        ? theme.colorScheme.primary
        : theme.colorScheme.surface;
    final textColor = isMine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

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
            if (hasFile) ...[
              _FileAttachmentView(
                attachment: message.attachment!,
                textColor: textColor,
                isMine: isMine,
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
                message.text ?? '',
                style: TextStyle(color: textColor, fontSize: 15),
              ),
            const SizedBox(height: 4),
            Text(
              DateFormat('HH:mm').format(message.createdAt),
              style: TextStyle(color: textColor.withAlpha(170), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileAttachmentView extends StatelessWidget {
  const _FileAttachmentView({
    required this.attachment,
    required this.textColor,
    required this.isMine,
  });

  final MessageAttachment attachment;
  final Color textColor;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final background = isMine
        ? Colors.white.withAlpha(42)
        : Theme.of(context).colorScheme.primary.withAlpha(22);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
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
        ],
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
