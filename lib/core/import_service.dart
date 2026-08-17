import '../core/library_service.dart';
import '../core/library_store.dart';
import '../core/models.dart';
import '../providers/qobuz/qobuz_api.dart';
import '../providers/qobuz/qobuz_provider.dart';
import '../providers/ytm/ytm_provider.dart';

/// A remote playlist offered for import.
class ImportablePlaylist {
  final String providerId;
  final String remoteId; // qobuz playlist id or ytm playlist id
  final String title;
  final String? artwork;
  final int? count;

  const ImportablePlaylist({
    required this.providerId,
    required this.remoteId,
    required this.title,
    this.artwork,
    this.count,
  });
}

/// Imports playlists and favorites from Qobuz/YTM into the local library.
class ImportService {
  final QobuzProvider? qobuz;
  final YtmProvider ytm;
  final LibraryStore store;

  ImportService({this.qobuz, required this.ytm, required this.store});

  /// All playlists available for import across connected providers.
  Future<List<ImportablePlaylist>> listImportablePlaylists() async {
    final out = <ImportablePlaylist>[];

    if (qobuz != null && qobuz!.isConfigured) {
      try {
        final api = qobuz!.api;
        final playlists = await api.getUserPlaylists();
        for (final p in playlists) {
          out.add(ImportablePlaylist(
            providerId: 'qobuz',
            remoteId: p.id,
            title: p.name,
            artwork: p.artwork,
            count: p.tracksCount,
          ));
        }
      } catch (_) {}
    }

    if (ytm.isLoggedIn) {
      try {
        final playlists = await ytm.libraryClient.getLibraryPlaylists();
        for (final p in playlists) {
          out.add(ImportablePlaylist(
            providerId: 'ytm',
            remoteId: p.playlistId,
            title: p.title,
            artwork: p.artwork,
            count: p.count,
          ));
        }
        // Liked songs appear as the special "LM" playlist.
        out.add(ImportablePlaylist(
          providerId: 'ytm',
          remoteId: 'LM',
          title: 'Liked Music',
          count: null,
        ));
      } catch (_) {}
    }

    return out;
  }

  /// Import a remote playlist as a local Unisson playlist.
  /// Returns the number of tracks imported.
  Future<int> importPlaylist(ImportablePlaylist source) async {
    final tracks = await _fetchTracks(source);
    if (tracks.isEmpty) return 0;

    final local = await store.createPlaylist(source.title);
    var added = 0;
    for (final t in tracks) {
      final merged = MergedTrack(
        universalKey: _keyFor(t),
        title: t.title,
        artists: t.artists,
        album: t.album,
        duration: t.duration,
        artwork: t.artwork,
        sources: {t.providerId: t},
      );
      if (await store.addToPlaylist(local.id, merged)) added++;
    }
    return added;
  }

  /// Import all favorited tracks of a provider as favorites.
  Future<int> importFavorites(String providerId) async {
    final tracks = providerId == 'qobuz'
        ? await _fetchQobuzFavorites()
        : await _fetchYtmLiked();
    var added = 0;
    for (final t in tracks) {
      final merged = MergedTrack(
        universalKey: _keyFor(t),
        title: t.title,
        artists: t.artists,
        album: t.album,
        duration: t.duration,
        artwork: t.artwork,
        sources: {t.providerId: t},
      );
      if (!await store.isFavorite(merged.universalKey)) {
        await store.toggleFavorite(merged);
        added++;
      }
    }
    return added;
  }

  Future<List<Track>> _fetchTracks(ImportablePlaylist source) async {
    if (source.providerId == 'qobuz') {
      final api = qobuz!.api;
      final tracks = await api.getPlaylistTracks(source.remoteId);
      return tracks
          .map((t) => Track(
                providerId: 'qobuz',
                id: 'qobuz:${t.id}',
                title: t.title,
                artists: t.artists,
                album: t.album,
                duration:
                    t.duration != null ? Duration(seconds: t.duration!) : null,
                artwork: t.artwork,
                sampleRate: (t.maxSampleRate ?? 0) * 1000,
                bitDepth: t.maxBitDepth,
              ))
          .toList();
    }
    return ytm.libraryClient.getPlaylistTracks(source.remoteId);
  }

  Future<List<Track>> _fetchQobuzFavorites() async {
    final api = qobuz!.api;
    final tracks = await api.getFavoriteTracks();
    return tracks
        .map((t) => Track(
              providerId: 'qobuz',
              id: 'qobuz:${t.id}',
              title: t.title,
              artists: t.artists,
              album: t.album,
              duration:
                  t.duration != null ? Duration(seconds: t.duration!) : null,
              artwork: t.artwork,
              sampleRate: (t.maxSampleRate ?? 0) * 1000,
              bitDepth: t.maxBitDepth,
            ))
        .toList();
  }

  Future<List<Track>> _fetchYtmLiked() async {
    return ytm.libraryClient.getPlaylistTracks('LM');
  }

  String _keyFor(Track t) {
    final title = t.title.trim().toLowerCase();
    final artist =
        t.artists.isNotEmpty ? t.artists.first.trim().toLowerCase() : '';
    return '$title|$artist';
  }
}
