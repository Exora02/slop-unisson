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
    // No raw stream URLs exist in Spotify's Web API. This marker spec
    // tells the audio handler to route the track to the headless Web
    // Playback SDK device instead of just_audio. Never reaches the
    // player itself — _loadCurrent intercepts source == 'spotify'.
    return StreamSpec(
      uri: Uri.parse('spotify:track:${track.id}'),
      contentType: 'application/x-spotify-track',
      // Web Playback SDK cap: AAC ~128 kbps (160 for accounts with
      // 'Very high' quality set). No lossless tier exists in the SDK.
      bitrate: 128,
      userAgent: 'Unisson/1.0',
    );
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
