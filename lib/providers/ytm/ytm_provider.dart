import 'dart:io' show HttpClient, HttpHeaders;

import '../../core/models.dart';
import '../../core/provider.dart';
import '../../core/stream_proxy.dart';
import 'innertube.dart';
import 'search_client.dart';
import 'ytm_library_client.dart';

class YtmProvider implements MusicProvider {
  final YtmSearchClient _search = YtmSearchClient();
  final InnerTubeClient _streams = InnerTubeClient();
  final YtmLibraryClient _library = YtmLibraryClient();

  final Future<String?> Function() _loadCookie;
  final Future<void> Function(String cookie) _saveCookie;
  final Future<void> Function() _clearCookie;

  YtmProvider({
    Future<String?> Function()? loadCookie,
    Future<void> Function(String cookie)? saveCookie,
    Future<void> Function()? clearCookie,
  })  : _loadCookie = loadCookie ?? (() async => null),
        _saveCookie = saveCookie ?? ((_) async {}),
        _clearCookie = clearCookie ?? (() async {});

  @override
  String get id => 'ytm';

  @override
  bool get hasQualityTiers => false;

  @override
  bool get isConfigured => true;

  /// True once a logged-in YTM session (auth cookie) is available.
  bool get isLoggedIn => _library.isLoggedIn;

  YtmLibraryClient get libraryClient => _library;

  Future<void> restoreSession() async {
    final c = await _loadCookie();
    if (c != null && c.isNotEmpty) {
      _library.setCookie(c);
      _streams.cookie = c;
    }
  }

  Future<void> loginWithCookie(String cookieHeader) async {
    _library.setCookie(cookieHeader);
    _streams.cookie = cookieHeader;
    await _saveCookie(cookieHeader);
  }

  Future<void> logout() async {
    _library.clearCookie();
    _streams.cookie = null;
    await _clearCookie();
  }

  @override
  Future<SearchResults> search(String query) async {
    final songs = await _search.searchSongs(query);
    return SearchResults(
      tracks: songs
          .map((s) => Track(
                providerId: id,
                id: s.videoId,
                title: s.title,
                artists: s.artists,
                album: s.album,
                duration: s.durationSeconds != null
                    ? Duration(seconds: s.durationSeconds!)
                    : null,
                artwork: s.artwork,
              ))
          .toList(),
    );
  }

  /// Fresh stream URL for the proxy's mid-stream re-resolve.
  Future<Uri?> resolveUriById(String videoId) async {
    final r = await _streams.resolve(videoId, force: true);
    return r == null ? null : Uri.parse(r.url);
  }

  /// On-device diagnostics: walk the ladder on THIS network, byte-fetch
  /// each resolved URL directly and through the proxy, and report per
  /// client what worked. This is the ground truth that server-side
  /// probes cannot see (they run on a different IP entirely).
  Future<List<String>> diagnose() async {
    final out = <String>[];
    await _streams.diagnose(out, (url, ua) async {
      final proxy = StreamProxy();
      await proxy.start();
      final local = proxy.proxyUrl(
          sourceId: 'ytm', trackId: 'diag', originUrl: url, userAgent: ua);
      try {
        final c = HttpClient()..autoUncompress = false;
        final req = await c.openUrl('GET', local);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
        final resp = await req.close().timeout(const Duration(seconds: 15));
        final bytes = await resp.first.timeout(const Duration(seconds: 15));
        await resp.drain<void>().catchError((_) {});
        c.close();
        proxy.dispose();
        return 'proxy ${resp.statusCode} ${bytes.length}B';
      } catch (e) {
        proxy.dispose();
        final msg = e.toString();
        return 'proxy ERR ${msg.length > 70 ? msg.substring(0, 70) : msg}';
      }
    });
    return out;
  }

  @override
  Future<StreamSpec> resolveStream(Track track, QualityPref pref) async {
    final r = await _streams.resolve(track.id);
    if (r == null) {
      final trace = _streams.lastAttemptTrace.isEmpty
          ? 'no client attempted'
          : _streams.lastAttemptTrace.join(' | ');
      throw StateError('YTM: no stream resolved for ${track.id} ($trace)');
    }
    return specFromResolved(r);
  }

  void dispose() {
    _search.dispose();
    _streams.dispose();
    _library.dispose();
  }
}
