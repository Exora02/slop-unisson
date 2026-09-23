import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Redirect the WebView intercepts before it ever loads. A custom
/// scheme needs no server, and the user registers it verbatim in
/// their Spotify app settings, so it always matches.
const spotifyRedirectUri = 'unisson://callback';

const _tokenEndpoint = 'https://accounts.spotify.com/api/token';
const _apiBase = 'https://api.spotify.com/v1';

class SpotifyPlaylist {
  final String id;
  final String name;
  final String? artwork;
  final int? tracksCount;

  const SpotifyPlaylist(
      {required this.id, required this.name, this.artwork, this.tracksCount});
}

class SpotifyTrack {
  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;
  final String? artwork;
  final String? isrc;

  const SpotifyTrack({
    required this.id,
    required this.title,
    this.artists = const [],
    this.album,
    this.durationMs,
    this.artwork,
    this.isrc,
  });
}

/// Minimal Spotify Web API client: PKCE token exchange/refresh plus the
/// read scopes needed for library import (playlist-read-private,
/// user-library-read) and search.
/// Parse a Web API track object. Numeric fields go through num? on
/// purpose — the API has been known to return doubles for ms values.
SpotifyTrack spotifyTrackFromJson(Map<String, dynamic> m) {
  final imgs = (m['album']?['images'] as List<dynamic>? ?? const []);
  return SpotifyTrack(
    id: '${m['id']}',
    title: '${m['name'] ?? 'Unknown'}',
    artists: (m['artists'] as List<dynamic>? ?? const [])
        .map((a) => '${(a as Map)['name']}')
        .toList(),
    album: m['album']?['name'] as String?,
    durationMs: (m['duration_ms'] as num?)?.toInt(),
    artwork: imgs.isNotEmpty ? (imgs[0] as Map)['url'] as String? : null,
    isrc: m['external_ids']?['isrc'] as String?,
  );
}

/// Client id of the Unisson app registered on the Spotify developer
/// dashboard (redirect unisson://callback). Public client material —
/// baked in like the InnerTube keys; PKCE keeps the flow secret-free,
/// so end users only ever see a login screen.
const spotifyClientId = '2354f17b09244bfb82e1dff610039b8f';

class SpotifyApi {
  final Future<String?> Function() loadToken;
  final Future<void> Function(String) saveToken;
  final Future<void> Function() clearToken;
  final _http = http.Client();

  String? _access;
  String? _refresh;
  int _expiresAtMs = 0;
  bool _restored = false;

  SpotifyApi(
      {required this.loadToken, required this.saveToken, required this.clearToken});

  bool get isAuthorized => _access != null;

  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final raw = await loadToken();
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _access = j['access'] as String?;
      _refresh = j['refresh'] as String?;
      _expiresAtMs = (j['expiresAt'] as num?)?.toInt() ?? 0;
    } catch (_) {}
  }

  Future<void> exchangeCode(String code, String verifier) async {
    final resp = await _http.post(Uri.parse(_tokenEndpoint), body: {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': spotifyRedirectUri,
      'client_id': spotifyClientId,
      'code_verifier': verifier,
    });
    if (resp.statusCode != 200) {
      throw StateError('Spotify code exchange failed: HTTP ${resp.statusCode}');
    }
    _applyToken(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> logout() async {
    _access = null;
    _refresh = null;
    _expiresAtMs = 0;
    await clearToken();
  }

  void _applyToken(Map<String, dynamic> j) {
    _access = j['access_token'] as String?;
    final r = j['refresh_token'] as String?;
    if (r != null) _refresh = r;
    final inS = (j['expires_in'] as num?)?.toInt() ?? 3600;
    _expiresAtMs =
        DateTime.now().millisecondsSinceEpoch + inS * 1000 - 60000;
    saveToken(jsonEncode(
        {'access': _access, 'refresh': _refresh, 'expiresAt': _expiresAtMs}));
  }

  Future<void> _ensureToken() async {
    await restore();
    if (_access == null) throw StateError('Spotify not connected');
    if (DateTime.now().millisecondsSinceEpoch < _expiresAtMs) return;
    if (_refresh == null) throw StateError('Spotify token expired');
    final resp = await _http.post(Uri.parse(_tokenEndpoint), body: {
      'grant_type': 'refresh_token',
      'refresh_token': _refresh,
      'client_id': spotifyClientId,
    });
    if (resp.statusCode != 200) {
      throw StateError('Spotify token refresh failed: HTTP ${resp.statusCode}');
    }
    _applyToken(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> _get(String url) async {
    await _ensureToken();
    var resp =
        await _http.get(Uri.parse(url), headers: {'Authorization': 'Bearer $_access'});
    if (resp.statusCode == 401 && _refresh != null) {
      // token raced with expiry — force one refresh and retry
      _expiresAtMs = 0;
      await _ensureToken();
      resp = await _http
          .get(Uri.parse(url), headers: {'Authorization': 'Bearer $_access'});
    }
    if (resp.statusCode != 200) {
      // Keep Spotify's body: it carries the real reason (missing
      // developer verification, invalid scopes, restricted endpoint…)
      // which a bare status code cannot convey.
      throw StateError('Spotify API HTTP ${resp.statusCode}: '
          '${resp.body.length > 300 ? resp.body.substring(0, 300) : resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Devices currently registered for playback (Web Playback SDK
  /// instances show up here once connected). Premium-gated.
  Future<List<Map<String, dynamic>>> getDevices() async {
    final j = await _get('$_apiBase/me/player/devices');
    return (j['devices'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((d) => Map<String, dynamic>.from(d))
        .toList();
  }

  /// Move active playback to [deviceId]. Premium-gated.
  Future<void> transfer(String deviceId, {bool play = true}) async {
    await _ensureToken();
    final resp = await _http.put(
      Uri.parse('$_apiBase/me/player'),
      headers: {
        'Authorization': 'Bearer $_access',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'device_ids': [deviceId], 'play': play}),
    );
    // 204 = transferred, 202 = deferred. Anything else is a real error.
    if (resp.statusCode != 204 && resp.statusCode != 202) {
      throw StateError('Spotify transfer failed: HTTP ${resp.statusCode} '
          '${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}');
    }
  }

  /// Start [uri] (spotify:track:…) on [deviceId]. Premium-gated.
  Future<void> playUri(String deviceId, String uri,
      {int positionMs = 0}) async {
    await _ensureToken();
    final resp = await _http.put(
      Uri.parse('$_apiBase/me/player/play?device_id=$deviceId'),
      headers: {
        'Authorization': 'Bearer $_access',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'uris': [uri], 'position_ms': positionMs}),
    );
    if (resp.statusCode != 204) {
      throw StateError('Spotify play failed: HTTP ${resp.statusCode} '
          '${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}');
    }
  }

  /// Pause on the active device. Premium-gated.
  Future<void> pause() async {
    await _ensureToken();
    final resp = await _http.put(
      Uri.parse('$_apiBase/me/player/pause'),
      headers: {'Authorization': 'Bearer $_access'},
    );
    if (resp.statusCode != 204 && resp.statusCode != 403) {
      throw StateError('Spotify pause failed: HTTP ${resp.statusCode}');
    }
  }

  /// Seek on the active device. Premium-gated.
  Future<void> seek(int positionMs) async {
    await _ensureToken();
    final resp = await _http.put(
      Uri.parse('$_apiBase/me/player/seek?position_ms=$positionMs'),
      headers: {'Authorization': 'Bearer $_access'},
    );
    if (resp.statusCode != 204 && resp.statusCode != 403) {
      throw StateError('Spotify seek failed: HTTP ${resp.statusCode}');
    }
  }

  /// Current playback state (position, is_playing, device). Null when
  /// nothing is active. Premium-gated.
  Future<Map<String, dynamic>?> getPlaybackState() async {
    await _ensureToken();
    final resp = await _http.get(
      Uri.parse('$_apiBase/me/player'),
      headers: {'Authorization': 'Bearer $_access'},
    );
    if (resp.statusCode == 204 || resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw StateError('Spotify state failed: HTTP ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<List<SpotifyPlaylist>> getMyPlaylists() async {
    final out = <SpotifyPlaylist>[];
    String? url = '$_apiBase/me/playlists?limit=50';
    while (url != null) {
      final j = await _get(url);
      for (final it in (j['items'] as List<dynamic>? ?? const [])) {
        final m = it as Map<String, dynamic>;
        final imgs = (m['images'] as List<dynamic>? ?? const []);
        out.add(SpotifyPlaylist(
          id: '${m['id']}',
          name: '${m['name'] ?? 'Untitled'}',
          artwork: imgs.isNotEmpty ? (imgs[0] as Map)['url'] as String? : null,
          tracksCount: (m['tracks']?['total'] as num?)?.toInt(),
        ));
      }
      url = j['next'] as String?;
    }
    return out;
  }

  SpotifyTrack _trackFrom(Map<String, dynamic> m) => spotifyTrackFromJson(m);

  Future<List<SpotifyTrack>> getPlaylistTracks(String id) async {
    final out = <SpotifyTrack>[];
    String? url = '$_apiBase/playlists/$id/tracks?limit=100';
    while (url != null) {
      final j = await _get(url);
      for (final it in (j['items'] as List<dynamic>? ?? const [])) {
        final m = (it as Map<String, dynamic>)['track'];
        if (m is! Map<String, dynamic> || m['type'] != 'track') continue;
        out.add(_trackFrom(m));
      }
      url = j['next'] as String?;
    }
    return out;
  }

  Future<List<SpotifyTrack>> getLikedTracks() async {
    final out = <SpotifyTrack>[];
    String? url = '$_apiBase/me/tracks?limit=50';
    while (url != null) {
      final j = await _get(url);
      for (final it in (j['items'] as List<dynamic>? ?? const [])) {
        final m = (it as Map<String, dynamic>)['track'];
        if (m is! Map<String, dynamic>) continue;
        out.add(_trackFrom(m));
      }
      url = j['next'] as String?;
    }
    return out;
  }

  Future<List<SpotifyTrack>> search(String q) async {
    final j = await _get(
        '$_apiBase/search?type=track&limit=20&q=${Uri.encodeComponent(q)}');
    final items = (j['tracks']?['items'] as List<dynamic>? ?? const []);
    return items
        .whereType<Map<String, dynamic>>()
        .map(_trackFrom)
        .toList();
  }

  void dispose() => _http.close();
}
