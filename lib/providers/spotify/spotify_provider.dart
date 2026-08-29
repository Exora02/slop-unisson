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
    // The official Web API exposes no stream URLs; librespot-style
    // playback needs a premium account and a separate phase.
    throw UnsupportedError(
        'Spotify playback is not supported yet (import & search only)');
  }

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
