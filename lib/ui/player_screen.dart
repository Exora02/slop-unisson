import 'package:flutter/material.dart' hide RepeatMode;
import 'package:audio_service/audio_service.dart';

import '../core/artwork.dart';
import '../core/audio_handler.dart';
import '../core/models.dart';
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
                  const SizedBox(height: 8),
                  _SourceChip(handler: handler, item: item),
                  const SizedBox(height: 12),
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
    final url = item?.artUri?.toString();
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: url != null
            ? Image.network(
                hqArtwork(url),
                fit: BoxFit.cover,
                // Some covers have no large cut — fall back to the
                // original (smaller) URL instead of an error icon.
                errorBuilder: (_, __, ___) => Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _fallback(theme),
                ),
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

/// Compact chip under the track info: current source + resolved quality.
/// Tap opens a sheet to switch source or pick a quality for this track.
class _SourceChip extends StatelessWidget {
  final UnissonAudioHandler handler;
  final MediaItem? item;

  const _SourceChip({required this.handler, this.item});

  static const _labels = {
    'local': 'Local',
    'qobuz': 'Qobuz',
    'ytm': 'YouTube',
    'tidal': 'Tidal',
    'spotify': 'Spotify',
  };

  String _qualityText(Map<String, dynamic>? extras) {
    if (extras == null) return '';
    final sr = (extras['sampleRate'] as num?)?.toInt();
    final bd = (extras['bitDepth'] as num?)?.toInt();
    if (sr != null && bd != null && bd >= 16) {
      return '${bd}bit/${(sr / 1000).toStringAsFixed(sr % 1000 == 0 ? 0 : 1)}kHz';
    }
    final br = (extras['bitrate'] as num?)?.toInt();
    if (br != null) return '${(br / 1000).round()}kbps';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final extras = item?.extras;
    final sourceId = extras?['sourceId'] as String?;
    if (sourceId == null) return const SizedBox.shrink();

    final label = _labels[sourceId] ?? sourceId;
    final q = _qualityText(extras);

    return GestureDetector(
      onTap: () => _openSourceSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.swap_horiz,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              q.isEmpty ? label : '$label · $q',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  void _openSourceSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (_) => _SourceSheet(handler: handler, item: item),
    );
  }
}

class _SourceSheet extends StatelessWidget {
  final UnissonAudioHandler handler;
  final MediaItem? item;

  const _SourceSheet({required this.handler, this.item});

  static const _labels = {
    'local': 'Local file',
    'qobuz': 'Qobuz',
    'ytm': 'YouTube Music',
    'tidal': 'Tidal',
    'spotify': 'Spotify',
  };

  static const _qualityLabels = {
    QualityPref.highest: 'Highest (hi-res / lossless)',
    QualityPref.balanced: 'Balanced',
    QualityPref.lowest: 'Lowest data',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<QueueEntry?>(
      stream: handler.currentEntryStream,
      builder: (context, entrySnap) {
        final entry = entrySnap.data;
        if (entry == null) {
          return const SizedBox(
              height: 120, child: Center(child: Text('Nothing playing')));
        }
        final sources = entry.track.sources;
        final currentSourceId = item?.extras?['sourceId'] as String?;
        // Quality choice only makes sense where tiers actually differ
        // (Qobuz: hi-res vs CD vs MP320). YTM/local are single-format.
        final tiersAvailable = sources.keys
            .any((id) => handler.hasQualityTiers(id));
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Play from',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (final sourceId in sources.keys)
                  RadioListTile<String>(
                    dense: true,
                    title: Text(_labels[sourceId] ?? sourceId),
                    subtitle: sourceId == 'qobuz'
                        ? const Text('hi-res up to 24bit/192kHz')
                        : null,
                    value: sourceId,
                    groupValue: currentSourceId,
                    onChanged: (v) {
                      if (v != null) handler.switchSource(v);
                      Navigator.of(context).pop();
                    },
                  ),
                const SizedBox(height: 4),
                if (tiersAvailable) ...[
                  Text('Quality for this track',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (final pref in QualityPref.values)
                    RadioListTile<QualityPref>(
                      dense: true,
                      title: Text(_qualityLabels[pref]!),
                      value: pref,
                      groupValue: entry.qualityOverride ?? handler.quality,
                      onChanged: (v) {
                        if (v == null) return;
                        // Re-resolve the current source with the new quality;
                        // if none was pinned, pin the best available one.
                        handler.switchSource(
                          currentSourceId ?? entry.track.bestSourceId,
                          qualityPref: v,
                        );
                        Navigator.of(context).pop();
                      },
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
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
