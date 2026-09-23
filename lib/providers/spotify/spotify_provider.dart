import '../../core/models.dart';
import '../../core/provider.dart';
import 'spotify_api.dart';

class SpotifyProvider implements MusicProvider {
  final SpotifyApi api;

  SpotifyProvider({required this.api});

  @override
  String get id => 'spotify';

  @override
  bool get hasQualityTiers => false;

  @override
  bool get isConfigured => api.isAuthorized;

  Future<void> restoreSession() => api.restore();

  Future<void> logout() => api.logout();

  @override
  Future<SearchResults> search(String query) async {
    final tracks = await api.search(query);
    return SearchResults(tracks: tracks.map(_toTrack).toList());
  }

  @override
  Future<StreamSpec> resolveStream(Track track, QualityPref pref) async {
    // Spotify ships no stream URLs (Web API). Playback of imported
    // content happens by enriching the track with other sources at
    // play time (see audio handler); native playback is a separate
    // phase (Web Playback SDK, Premium).
    throw UnsupportedError(
        'Spotify has no direct streams — enrich from other sources');
  }

  /// Devices currently registered for playback (Web Playback SDK
  /// instances show up here once connected). Premium-gated.
  Future<List<Map<String, dynamic>>> devices() => api.getDevices();

  Track _toTrack(SpotifyTrack t) => Track(
        providerId: id,
        id: 'spotify:${t.id}',
        title: t.title,
        artists: t.artists,
        album: t.album,
        duration:
            t.durationMs != null ? Duration(milliseconds: t.durationMs!) : null,
        artwork: t.artwork,
        isrc: t.isrc,
      );

  void dispose() => api.dispose();
}
