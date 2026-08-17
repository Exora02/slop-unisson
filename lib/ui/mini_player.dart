import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';

import '../core/audio_handler.dart';
import 'player_screen.dart';

/// Compact now-playing bar. Tap to open the full player tab.
class MiniPlayer extends StatelessWidget {
  final UnissonAudioHandler handler;

  const MiniPlayer({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, itemSnap) {
        final item = itemSnap.data;
        if (item == null) return const SizedBox.shrink();
        return StreamBuilder<PlaybackState>(
          stream: handler.playbackState,
          builder: (context, stateSnap) {
            final playing = stateSnap.data?.playing ?? false;
            return GestureDetector(
              onTap: () => Navigator.of(context).push(
                PageRouteBuilder(
                  pageBuilder: (_, __, ___) =>
                      PlayerScreen(handler: handler),
                  transitionsBuilder: (_, anim, __, child) => SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 1),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
                    child: child,
                  ),
                ),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: Border(
                    top: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Row(
                  children: [
                    if (item.artUri != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.network(
                          item.artUri.toString(),
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.music_note),
                        ),
                      )
                    else
                      const Icon(Icons.music_note),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(
                            item.artist ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        playing
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 36,
                      ),
                      onPressed: () =>
                          playing ? handler.pause() : handler.play(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: () => handler.skipToNext(),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
