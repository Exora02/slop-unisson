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
    final performer = j['performer'] as Map<String, dynamic>?;
    final albumObj = j['album'] as Map<String, dynamic>?;
    final albumArtist = albumObj?['artist'] as Map<String, dynamic>?;
    final artistName = performer?['name'] ?? albumArtist?['name'];
    final image = j['image'] as Map<String, dynamic>?;
    var artUrl;
    if (image != null) {
      for (final k in ['large', 'medium', 'small']) {
        if (image[k] != null) {
          artUrl = image[k];
          break;
        }
      }
    }
    return QobuzTrack(
      id: j['id'].toString(),
      title: j['title'] as String,
      artists: artistName != null ? [artistName as String] : const [],
      album: albumObj?['title'] as String?,
      duration: j['duration'] as int?,
      artwork: artUrl as String?,
      maxSampleRate: j['maximum_sampling_rate'] as int?,
      maxBitDepth: j['maximum_bit_depth'] as int?,
      streamable: (j['streamable'] as bool?) ?? false,
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

  /// Login with email/password. Returns auth info on success, throws on failure.
  Future<QobuzAuthInfo> login(String email, String password) async {
    final resp = await _http.get(
      Uri.parse('$_baseUrl/user/login').replace(queryParameters: {
        'email': email,
        'password': password,
        'app_id': _appId,
      }),
      headers: {'X-App-Id': _appId},
    );
    if (resp.statusCode != 200) {
      throw Exception('Qobuz login failed (${resp.statusCode})');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    if (j['user_auth_token'] == null) {
      throw Exception('Invalid Qobuz credentials');
    }
    final auth = QobuzAuthInfo.fromJson(j);
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
      // build signing_data: endpoint (no slashes) + sorted params
      final parts = endpoint.split('/');
      final signingData = StringBuffer(parts.join());
      final keys = query.keys.toList()..sort();
      for (final k in keys) {
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
    return items
        .map((e) => QobuzTrack.fromJson(e as Map<String, dynamic>))
        .where((t) => t.streamable)
        .toList();
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
    final url = j['url'] as String?;
    if (url == null) throw Exception('Qobuz returned no stream URL');
    return QobuzStream(
      url: url,
      formatId: (j['format_id'] as int?) ?? formatId,
      mimeType: j['mime_type'] as String? ?? 'audio/flac',
      sampleRate: (j['sampling_rate'] as num?)?.toDouble(),
      bitDepth: j['bit_depth'] as int?,
      duration: j['duration'] as int?,
    );
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