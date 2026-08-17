import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const _baseUrl = 'https://www.qobuz.com/api.json/0.2';

// Public Qobuz web-player app credentials (embedded in all official clients).
const _appId = '942852567';
const _appSecret = '761730d3f95e4af09ac63b9a37ccc96a';

class QobuzAuthInfo {
  final String token;
  final String? userId;
  final String? login;

  QobuzAuthInfo({required this.token, this.userId, this.login});

  factory QobuzAuthInfo.fromJson(Map<String, dynamic> j) {
    final user = j['user'] as Map<String, dynamic>?;
    return QobuzAuthInfo(
      token: j['user_auth_token'] as String,
      userId: user?['id']?.toString(),
      login: user?['login'] as String?,
    );
  }
}

class QobuzTrack {
  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final int? duration;
  final String? artwork;
  final int? maxSampleRate;
  final int? maxBitDepth;
  final bool streamable;

  QobuzTrack({
    required this.id,
    required this.title,
    this.artists = const [],
    this.album,
    this.duration,
    this.artwork,
    this.maxSampleRate,
    this.maxBitDepth,
    this.streamable = false,
  });

  factory QobuzTrack.fromJson(Map<String, dynamic> j) {
    try {
      final performer = j['performer'] as Map<String, dynamic>?;
      final albumObj = j['album'] as Map<String, dynamic>?;
      final albumArtist = albumObj?['artist'] as Map<String, dynamic>?;
      final artistName = performer?['name'] ?? albumArtist?['name'];
      final image = j['image'] as Map<String, dynamic>?;
      Object? artUrl;
      if (image != null) {
        for (final k in ['large', 'medium', 'small']) {
          if (image[k] != null) {
            artUrl = image[k];
            break;
          }
        }
      }
      final id = j['id'];
      final title = j['title'];
      return QobuzTrack(
        id: id?.toString() ?? '',
        title: title?.toString() ?? 'Unknown',
        artists: artistName != null ? [artistName.toString()] : const [],
        album: albumObj?['title']?.toString(),
        duration: (j['duration'] as num?)?.toInt(),
        artwork: artUrl?.toString(),
        maxSampleRate: (j['maximum_sampling_rate'] as num?)?.toInt(),
        maxBitDepth: (j['maximum_bit_depth'] as num?)?.toInt(),
        streamable: (j['streamable'] as bool?) ?? false,
      );
    } on TypeError catch (e) {
      // A field-type mismatch must never break the whole search. Report the
      // field so we can fix the exact key.
      throw Exception('Qobuz track field-type mismatch: $e '
          '(title=${j['title']}, keys=${j.keys.toList().take(6)})');
    }
  }
}

class QobuzPlaylist {
  final String id;
  final String name;
  final int tracksCount;
  final String? artwork;

  QobuzPlaylist({
    required this.id,
    required this.name,
    this.tracksCount = 0,
    this.artwork,
  });

  factory QobuzPlaylist.fromJson(Map<String, dynamic> j) {
    final img = j['images300'] as List<dynamic>?;
    return QobuzPlaylist(
      id: j['id']?.toString() ?? '',
      name: j['name']?.toString() ?? 'Playlist',
      tracksCount: (j['tracks_count'] as num?)?.toInt() ?? 0,
      artwork: (img != null && img.isNotEmpty) ? img.first?.toString() : null,
    );
  }
}

class QobuzApi {
  final _http = http.Client();
  final String Function() _tokenProvider;
  String? _cachedToken;

  QobuzApi({required String Function() tokenProvider})
      : _tokenProvider = tokenProvider {
    _cachedToken = _tokenProvider();
  }

  String? get token => _cachedToken;

  void setToken(String? t) => _cachedToken = t;

  /// Login with username/password. Returns auth info on success, throws on failure.
  /// Matches Music Assistant's spec: username + password + device_manufacturer_id
  /// as query params, X-App-Id header only.
  Future<QobuzAuthInfo> login(String username, String password) async {
    final resp = await _http.get(
      Uri.parse('$_baseUrl/user/login').replace(queryParameters: {
        'username': username,
        'password': password,
        'device_manufacturer_id': 'music_assistant',
      }),
      headers: {
        'X-App-Id': _appId,
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13; app) AppleWebKit/537.36',
      },
    );
    if (resp.statusCode != 200) {
      final body = resp.body.replaceAll('\n', ' ');
      throw Exception('Qobuz login failed (${resp.statusCode}): $body');
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Qobuz login: bad response body ($e)');
    }
    if (j['user_auth_token'] == null) {
      throw Exception('Invalid Qobuz credentials');
    }
    final QobuzAuthInfo auth;
    try {
      auth = QobuzAuthInfo.fromJson(j);
    } on TypeError catch (e) {
      throw Exception('Qobuz login field-type mismatch: $e '
          '(keys=${j.keys.toList().take(8)})');
    }
    _cachedToken = auth.token;
    return auth;
  }

  Future<Map<String, dynamic>> _get(
    String endpoint, {
    Map<String, String>? params,
    bool signRequest = false,
  }) async {
    final headers = {
      'X-App-Id': _appId,
      'Accept': 'application/json',
    };
    var query = {...?params};

    if (endpoint != 'user/login') {
      final t = _cachedToken;
      if (t == null) throw Exception('Qobuz not logged in');
      headers['X-User-Auth-Token'] = t;
      query['user_auth_token'] = t;
    }

    if (signRequest) {
      // Match MA: signature covers endpoint + the ORIGINAL sorted params
      // (format_id, track_id, intent) — NOT app_id/user_auth_token/request_ts,
      // which are appended to the query AFTER signing.
      final signingData = StringBuffer(endpoint.split('/').join());
      final keys = query.keys.toList()..sort();
      for (final k in keys) {
        if (k == 'app_id' || k == 'user_auth_token' ||
            k == 'request_ts' || k == 'request_sig') {
          continue; // these are appended post-signature, not signed
        }
        signingData.write('$k${query[k]}');
      }
      final ts = (DateTime.now().millisecondsSinceEpoch / 1000).toStringAsFixed(0);
      final sig = md5.convert(utf8.encode('$signingData$ts$_appSecret')).toString();
      query['request_ts'] = ts;
      query['request_sig'] = sig;
      query['app_id'] = _appId;
      query['user_auth_token'] = _cachedToken!;
    }

    final uri = Uri.parse('$_baseUrl/$endpoint').replace(queryParameters: query);
    final resp = await _http.get(uri, headers: headers).timeout(const Duration(seconds: 25));
    if (resp.statusCode == 401) {
      throw Exception('Qobuz session expired — please re-login');
    }
    if (resp.statusCode >= 400) {
      throw Exception('Qobuz API error ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<List<QobuzTrack>> searchTracks(String query, {int limit = 25}) async {
    final j = await _get('catalog/search', params: {
      'query': query,
      'limit': '$limit',
      'type': 'tracks',
    });
    final items = (j['tracks']?['items'] as List<dynamic>?) ?? [];
    final out = <QobuzTrack>[];
    for (final e in items) {
      try {
        final t = QobuzTrack.fromJson(e as Map<String, dynamic>);
        if (t.id.isEmpty) continue;
        out.add(t);
      } catch (_) {
        // skip malformed track(s) instead of failing the whole search
      }
    }
    return out.where((t) => t.streamable).toList();
  }

  /// Resolve the direct stream URL for a track.
  /// [formatId]: 27=hi-res lossless, 7=CD lossless FLAC, 6=320kbps, 5=160kbps.
  Future<QobuzStream> getFileUrl(String trackId, int formatId) async {
    final j = await _get(
      'track/getFileUrl',
      params: {
        'format_id': '$formatId',
        'track_id': trackId,
        'intent': 'stream',
      },
      signRequest: true,
    );
    try {
      final url = j['url'] as String?;
      if (url == null) throw Exception('Qobuz returned no stream URL');
      return QobuzStream(
        url: url,
        formatId: (j['format_id'] as num?)?.toInt() ?? formatId,
        mimeType: j['mime_type'] as String? ?? 'audio/flac',
        sampleRate: (j['sampling_rate'] as num?)?.toDouble(),
        bitDepth: (j['bit_depth'] as num?)?.toInt(),
        duration: (j['duration'] as num?)?.toInt(),
      );
    } on TypeError catch (e) {
      throw Exception('Qobuz getFileUrl field-type mismatch: $e '
          '(keys=${j.keys.toList().take(8)})');
    }
  }

  /// All playlists in the user's library (paginated, MA-style).
  Future<List<QobuzPlaylist>> getUserPlaylists() async {
    final out = <QobuzPlaylist>[];
    var offset = 0;
    const limit = 100;
    while (true) {
      final j = await _get('playlist/getUserPlaylists', params: {
        'limit': '$limit',
        'offset': '$offset',
      });
      final items = (j['playlists']?['items'] as List<dynamic>?) ?? [];
      for (final e in items) {
        try {
          final p = QobuzPlaylist.fromJson(e as Map<String, dynamic>);
          if (p.id.isNotEmpty) out.add(p);
        } catch (_) {}
      }
      offset += limit;
      if (items.length < limit) break;
    }
    return out;
  }

  /// Tracks of one playlist (paginated).
  Future<List<QobuzTrack>> getPlaylistTracks(String playlistId) async {
    final out = <QobuzTrack>[];
    var offset = 0;
    const limit = 100;
    while (true) {
      final j = await _get('playlist/get', params: {
        'playlist_id': playlistId,
        'limit': '$limit',
        'offset': '$offset',
      });
      final items = (j['tracks']?['items'] as List<dynamic>?) ?? [];
      for (final e in items) {
        try {
          final t = QobuzTrack.fromJson(e as Map<String, dynamic>);
          if (t.id.isNotEmpty && t.streamable) out.add(t);
        } catch (_) {}
      }
      offset += limit;
      if (items.length < limit) break;
    }
    return out;
  }

  /// Favorited tracks in the user's library (paginated).
  Future<List<QobuzTrack>> getFavoriteTracks() async {
    final out = <QobuzTrack>[];
    var offset = 0;
    const limit = 100;
    while (true) {
      final j = await _get('favorite/getUserFavorites', params: {
        'type': 'tracks',
        'limit': '$limit',
        'offset': '$offset',
      });
      final items = (j['tracks']?['items'] as List<dynamic>?) ?? [];
      for (final e in items) {
        try {
          final t = QobuzTrack.fromJson(e as Map<String, dynamic>);
          if (t.id.isNotEmpty && t.streamable) out.add(t);
        } catch (_) {}
      }
      offset += limit;
      if (items.length < limit) break;
    }
    return out;
  }

  void dispose() {
    _http.close();
  }
}

class QobuzStream {
  final String url;
  final int formatId;
  final String mimeType;
  final double? sampleRate;
  final int? bitDepth;
  final int? duration;

  QobuzStream({
    required this.url,
    required this.formatId,
    required this.mimeType,
    this.sampleRate,
    this.bitDepth,
    this.duration,
  });
}