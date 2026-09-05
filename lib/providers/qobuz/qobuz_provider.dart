import '../../core/models.dart';
import '../../core/provider.dart';
import 'qobuz_api.dart';

/// Qobuz provider. Requires an active subscription.
/// The token is never exposed to chat — it's stored via the injected
/// [tokenStore] (flutter_secure_storage) and used only for API calls.
class QobuzProvider implements MusicProvider {
  final QobuzApi _api;
  final Future<String?> Function() _loadToken;
  final Future<void> Function(String token) _saveToken;
  final Future<void> Function() _clearToken;

  bool _loggedIn = false;

  /// Exposed for the import service (playlists/favorites).
  QobuzApi get api => _api;

  QobuzProvider({
    required Future<String?> Function() loadToken,
    required Future<void> Function(String token) saveToken,
    required Future<void> Function() clearToken,
  })  : _loadToken = loadToken,
        _saveToken = saveToken,
        _clearToken = clearToken,
        _api = QobuzApi(tokenProvider: () => '') {
    // tokenProvider is kept; we manage token via _api.setToken after loading.
  }

  @override
  String get id => 'qobuz';

  @override
  bool get hasQualityTiers => true;

  @override
  bool get isConfigured => _loggedIn;

  Future<void> restoreSession() async {
    final t = await _loadToken();
    if (t != null && t.isNotEmpty) {
      _api.setToken(t);
      _loggedIn = true;
    }
  }

  Future<void> login(String email, String password) async {
    final auth = await _api.login(email, password);
    _api.setToken(auth.token);
    _loggedIn = true;
    await _saveToken(auth.token);
  }

  Future<void> logout() async {
    _loggedIn = false;
    _api.setToken(null);
    await _clearToken();
  }

  /// Quality ladder: hi-res (27) then lossless (7). Falls back down the ladder.
  int _formatFor(QualityPref pref) => switch (pref) {
        QualityPref.highest => 27,
        QualityPref.balanced => 7,
        QualityPref.lowest => 6,
      };

  /// Fresh stream URL for the proxy's mid-stream re-resolve (Qobuz
  /// tokens die mid-track). Returns null when nothing resolves.
  Future<Uri?> resolveStreamById(String trackId, int formatId) async {
    for (final f in [formatId, 7, 6, 5].toSet()) {
      try {
        final s = await _api.getFileUrl(trackId, f);
        if (s.url.isNotEmpty) return Uri.parse(s.url);
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<SearchResults> search(String query) async {
    if (!_loggedIn) return const SearchResults();
    final tracks = await _api.searchTracks(query);
    return SearchResults(
      tracks: tracks
          .map((t) => Track(
                providerId: id,
                id: 'qobuz:${t.id}',
                title: t.title,
                artists: t.artists,
                album: t.album,
                duration: t.duration != null ? Duration(seconds: t.duration!) : null,
                artwork: t.artwork,
                sampleRate: (t.maxSampleRate ?? 0) * 1000,
                bitDepth: t.maxBitDepth,
              ))
          .toList(),
    );
  }

  @override
  Future<StreamSpec> resolveStream(Track track, QualityPref pref) async {
    final did = track.id.startsWith('qobuz:')
        ? track.id.substring('qobuz:'.length)
        : track.id;
    final formatId = _formatFor(pref);
    // try requested format, then fall back down the ladder
    for (final f in [formatId, 7, 6, 5].toSet()) {
      try {
        final s = await _api.getFileUrl(did, f);
        if (s.url.isNotEmpty) {
          // getFileUrl often omits the embedded track/album object —
          // favorites imports have no covers without this backfill.
          var art = s.artwork;
          var album = s.album;
          if (art == null || album == null) {
            try {
              final meta = await _api.getTrackMeta(did);
              art ??= meta.artwork;
              album ??= meta.album;
            } catch (_) {
              // cover backfill is best-effort, never block playback
            }
          }
          return StreamSpec(
            uri: Uri.parse(s.url),
            contentType: s.mimeType,
            // Qobuz reports kHz (44.1); the app speaks Hz everywhere.
            sampleRate: (s.sampleRate ?? 0) * 1000 == 0
                ? null
                : (s.sampleRate! * 1000).toInt(),
            bitDepth: s.bitDepth,
            artwork: art,
            album: album,
          );
        }
      } catch (_) {
        // try next quality
      }
    }
    throw StateError('Qobuz: no stream available for ${track.id}');
  }

  void dispose() {
    _api.dispose();
  }
}