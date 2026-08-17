import 'package:flutter/material.dart';

import '../core/audio_handler.dart';
import '../core/queue.dart';

/// Bottom-sheet queue view: current track highlighted, swipe to remove,
/// drag handle to reorder, tap to jump.
class QueueSheet extends StatelessWidget {
  final UnissonAudioHandler handler;
  final ScrollController scrollController;

  const QueueSheet({
    super.key,
    required this.handler,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              const Icon(Icons.queue_music),
              const SizedBox(width: 8),
              Text('Up next', style: theme.textTheme.titleMedium),
              const Spacer(),
              StreamBuilder<int>(
                stream: handler.indexStream,
                builder: (context, idxSnap) {
                  final i = idxSnap.data ?? -1;
                  return Text(
                    i >= 0 ? '${i + 1} playing' : '',
                    style: theme.textTheme.bodySmall,
                  );
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<List<QueueEntry>>(
            stream: handler.queueStream,
            builder: (context, snap) {
              final entries = snap.data ?? const <QueueEntry>[];
              if (entries.isEmpty) {
                return const Center(child: Text('Queue is empty'));
              }
              return StreamBuilder<int>(
                stream: handler.indexStream,
                builder: (context, idxSnap) {
                  final currentIdx = idxSnap.data ?? -1;
                  return ReorderableListView.builder(
                    scrollController: scrollController,
                    buildDefaultDragHandles: false,
                    itemCount: entries.length,
                    onReorder: (from, to) =>
                        handler.moveInQueue(from, to > from ? to - 1 : to),
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final isCurrent = i == currentIdx;
                      return ListTile(
                        key: ValueKey('${e.key}_$i'),
                        leading: Icon(
                          isCurrent ? Icons.play_arrow : Icons.music_note,
                          color: isCurrent
                              ? theme.colorScheme.primary
                              : null,
                        ),
                        title: Text(
                          e.track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isCurrent
                              ? TextStyle(color: theme.colorScheme.primary)
                              : null,
                        ),
                        subtitle: Text(
                          e.track.artists.join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              e.sourceId ?? e.track.bestSourceId,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 4),
                            ReorderableDragStartListener(
                              index: i,
                              child: const Icon(Icons.drag_handle),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => handler.removeFromQueue(i),
                            ),
                          ],
                        ),
                        onTap: () => handler.playAt(i),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
