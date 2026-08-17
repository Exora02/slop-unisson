import 'package:flutter/material.dart' hide RepeatMode;
import 'package:audio_service/audio_service.dart';

import '../core/audio_handler.dart';
import '../core/queue.dart';
import 'queue_sheet.dart';

class PlayerScreen extends StatelessWidget {
  final UnissonAudioHandler handler;

  const PlayerScreen({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down, size: 32),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.queue_music),
            onPressed: () => _openQueue(context),
          ),
        ],
      ),
      body: StreamBuilder<MediaItem?>(
        stream: handler.mediaItem,
        builder: (context, itemSnap) {
          final item = itemSnap.data;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  Expanded(
                    flex: 3,
                    child: Center(
                      child: _Artwork(item: item),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _TrackInfo(item: item),
                  const SizedBox(height: 20),
                  _SeekBar(handler: handler),
                  const SizedBox(height: 8),
                  _Controls(handler: handler),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openQueue(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (_, scrollController) =>
            QueueSheet(handler: handler, scrollController: scrollController),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  final MediaItem? item;
  const _Artwork({this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: item?.artUri != null
            ? Image.network(
                item!.artUri.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallback(theme),
              )
            : _fallback(theme),
      ),
    );
  }

  Widget _fallback(ThemeData theme) => Container(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(Icons.music_note,
              size: 96, color: theme.colorScheme.primary),
        ),
      );
}

class _TrackInfo extends StatelessWidget {
  final MediaItem? item;
  const _TrackInfo({this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          item?.title ?? 'Nothing playing',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          item?.artist ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (item?.album != null) ...[
          const SizedBox(height: 2),
          Text(
            item!.album!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _SeekBar extends StatelessWidget {
  final UnissonAudioHandler handler;
  const _SeekBar({required this.handler});

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: handler.positionStream,
      builder: (context, posSnap) {
        return StreamBuilder<Duration?>(
          stream: handler.durationStream,
          builder: (context, durSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final dur = durSnap.data ?? Duration.zero;
            final maxMs = dur.inMilliseconds.clamp(1, 1 << 62).toDouble();
            return Column(
              children: [
                Slider(
                  value: pos.inMilliseconds.toDouble().clamp(0, maxMs),
                  max: maxMs,
                  onChanged: (v) =>
                      handler.seek(Duration(milliseconds: v.toInt())),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(pos),
                          style: Theme.of(context).textTheme.bodySmall),
                      Text(_fmt(dur),
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  final UnissonAudioHandler handler;
  const _Controls({required this.handler});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, stateSnap) {
        final playing = stateSnap.data?.playing ?? false;
        return StreamBuilder<RepeatMode>(
          stream: handler.repeatStream,
          builder: (context, repeatSnap) {
            return StreamBuilder<bool>(
              stream: handler.shuffleStream,
              builder: (context, shuffleSnap) {
                final repeat = repeatSnap.data ?? RepeatMode.none;
                final shuffled = shuffleSnap.data ?? false;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.shuffle,
                        color: shuffled
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () => handler.toggleShuffle(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_previous, size: 44),
                      onPressed: () => handler.skipToPrevious(),
                    ),
                    IconButton(
                      iconSize: 72,
                      icon: Icon(
                        playing
                            ? Icons.pause_circle
                            : Icons.play_circle,
                      ),
                      onPressed: () =>
                          playing ? handler.pause() : handler.play(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next, size: 44),
                      onPressed: () => handler.skipToNext(),
                    ),
                    IconButton(
                      icon: Icon(
                        repeat == RepeatMode.one
                            ? Icons.repeat_one
                            : Icons.repeat,
                        color: repeat != RepeatMode.none
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () => handler.cycleRepeatMode(),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}
