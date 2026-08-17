import '../library_service.dart';
import '../models.dart';

/// Serialize a MergedTrack (with all its sources) for storage.
/// Keeping every source means library items stay playable from any
/// configured provider, exactly like search results.
Map<String, dynamic> mergedTrackToJson(MergedTrack t) => {
      'universalKey': t.universalKey,
      'title': t.title,
      'artists': t.artists,
      'album': t.album,
      'durationMs': t.duration?.inMilliseconds,
      'artwork': t.artwork,
      'sources': {
        for (final e in t.sources.entries) e.key: trackToJson(e.value),
      },
    };

MergedTrack mergedTrackFromJson(Map<String, dynamic> j) => MergedTrack(
      universalKey: j['universalKey'] as String? ?? '',
      title: j['title'] as String? ?? 'Unknown',
      artists: (j['artists'] as List<dynamic>? ?? const [])
          .map((a) => '$a')
          .toList(),
      album: j['album'] as String?,
      duration: j['durationMs'] is int
          ? Duration(milliseconds: j['durationMs'] as int)
          : null,
      artwork: j['artwork'] as String?,
      sources: {
        for (final e
            in (j['sources'] as Map<String, dynamic>? ?? const {}).entries)
          e.key: trackFromJson(e.value as Map<String, dynamic>),
      },
    );

Map<String, dynamic> trackToJson(Track t) => {
      'providerId': t.providerId,
      'id': t.id,
      'title': t.title,
      'artists': t.artists,
      'album': t.album,
      'durationMs': t.duration?.inMilliseconds,
      'artwork': t.artwork,
      'bitrate': t.bitrate,
      'sampleRate': t.sampleRate,
      'bitDepth': t.bitDepth,
    };

Track trackFromJson(Map<String, dynamic> j) => Track(
      providerId: j['providerId'] as String? ?? '',
      id: j['id'] as String? ?? '',
      title: j['title'] as String? ?? 'Unknown',
      artists: (j['artists'] as List<dynamic>? ?? const [])
          .map((a) => '$a')
          .toList(),
      album: j['album'] as String?,
      duration: j['durationMs'] is int
          ? Duration(milliseconds: j['durationMs'] as int)
          : null,
      artwork: j['artwork'] as String?,
      bitrate: (j['bitrate'] as num?)?.toInt(),
      sampleRate: (j['sampleRate'] as num?)?.toInt(),
      bitDepth: (j['bitDepth'] as num?)?.toInt(),
    );
