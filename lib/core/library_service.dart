import 'dart:async';

import 'models.dart';
import 'provider.dart';

/// A track that may be available from multiple sources.
/// backend-specific tracks are merged by a fuzzy key here.
class MergedTrack {
  final String universalKey; // lowercased title + '|' + first artist
  String title;
  List<String> artists;
  String? album;
  Duration? duration;
  String? artwork;

  /// providerId → best Track for that source (sorted by preference)
  final Map<String, Track> sources;

  MergedTrack({
    required this.universalKey,
    required this.title,
    required this.artists,
    required this.sources,
    this.album,
    this.duration,
    this.artwork,
  });

  String get bestSourceId {
    final sourceIds = sources.keys;
    if (sourceIds.isEmpty) return '?';
    // preference order
    const order = ['local', 'qobuz', 'ytm', 'tidal', 'spotify'];
    for (final o in order) {
      if (sources.containsKey(o)) return o;
    }
    return sourceIds.first;
  }
}

class LibraryService {
  final List<MusicProvider> providers;

  LibraryService(this.providers);

  /// Merged, source-annotated search across all providers.
  /// Each provider is isolated: one failing provider never hides others'
  /// results.
  Future<List<MergedTrack>> searchAll(String query) async {
    final tasks = <({String id, Future<SearchResults> future})>[];

    for (final p in providers) {
      if (!p.isConfigured) continue;
      tasks.add((id: p.id, future: p.search(query)));
    }

    // await all, but tolerate per-provider failures
    final results = <({String id, List<Track> tracks})>[];
    for (final task in tasks) {
      try {
        final r = await task.future;
        results.add((id: task.id, tracks: r.tracks));
      } catch (_) {
        // a provider's search error must not hide other sources
        results.add((id: task.id, tracks: const []));
      }
    }

    final all = <MergedTrack>[];
    final byKey = <String, MergedTrack>{};

    for (final result in results) {
      for (final t in result.tracks) {
        final key = _keyFor(t);
        final existing = byKey[key];
        if (existing == null) {
          final mt = MergedTrack(
            universalKey: key,
            title: t.title,
            artists: t.artists,
            album: t.album,
            duration: t.duration,
            artwork: t.artwork,
            sources: {t.providerId: t},
          );
          byKey[key] = mt;
          all.add(mt);
        } else {
          existing.sources[t.providerId] = t;
        }
      }
    }

    // pick representative artwork/album from best source
    for (final mt in all) {
      final best = mt.sources[mt.bestSourceId];
      if (best != null) {
        mt.title = best.title;
        mt.artists = best.artists.isNotEmpty ? best.artists : mt.artists;
        mt.album = best.album ?? mt.album;
        mt.artwork = best.artwork ?? mt.artwork;
      }
    }

    return all;
  }

  String _keyFor(Track t) {
    final title = t.title.trim().toLowerCase();
    final artist = t.artists.isNotEmpty ? t.artists.first.trim().toLowerCase() : '';
    return '$title|$artist';
  }

  /// Resolve a stream from a specific merged track/source.
  Future<ResolvedResult> resolve(
    MergedTrack merged,
    String sourceId,
    QualityPref quality,
  ) async {
    final track = merged.sources[sourceId];
    if (track == null) throw StateError('merged track has no $sourceId source');
    final provider = providers.firstWhere(
      (p) => p.id == sourceId,
      orElse: () => throw StateError('provider $sourceId not configured'),
    );
    final spec = await provider.resolveStream(track, quality);
    return ResolvedResult(
      title: merged.title,
      artists: merged.artists,
      stream: spec,
      sourceId: sourceId,
    );
  }

  /// Auto-pick best available source for a merged track.
  Future<ResolvedResult> resolveAuto(MergedTrack m, QualityPref quality) {
    final source = m.bestSourceId;
    return resolve(m, source, quality);
  }
}

class ResolvedResult {
  final String title;
  final List<String> artists;
  final StreamSpec stream;
  final String sourceId;

  const ResolvedResult({
    required this.title,
    required this.artists,
    required this.stream,
    required this.sourceId,
  });
}