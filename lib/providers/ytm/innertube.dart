import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/models.dart';

const _playerEndpoint = 'https://music.youtube.com/youtubei/v1/player';
const _configEndpoint = 'https://music.youtube.com/youtubei/v1/config';
const _androidMusicKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
const _androidKey = 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w';

class _Client {
  final String name;
  final String code;
  final String version;
  final String key;
  final int sdk;
  final String userAgent;
  final String? playerParams;
  final bool skipVisitorData;

  const _Client(this.name, this.code, this.version, this.key, this.sdk,
      this.userAgent,
      {this.playerParams, this.skipVisitorData = false});
}

const _clients = [
  _Client(
      'ANDROID_MUSIC',
      '21',
      '5.26.1',
      _androidMusicKey,
      33,
      'com.google.android.apps.youtube.music/5.26.1 (Linux; U; Android 13; en_US) gzip',
      skipVisitorData: true),
  _Client(
      'ANDROID_VR',
      '28',
      '1.60.19',
      _androidKey,
      33,
      'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip'),
  _Client(
      'ANDROID',
      '3',
      '17.36.4',
      _androidKey,
      30,
      'com.google.android.youtube/17.36.4 (Linux; U; Android 11) gzip',
      playerParams: 'CgIQBg'),
  _Client('ANDROID_TESTSUITE', '30', '1.9', _androidKey, 33,
      'com.google.android.youtube/1.9 (Linux; U; Android 13; en_US) gzip'),
];

const _preferredItags = [251, 250, 140];

class ResolvedStream {
  final String url;
  final int itag;
  final String contentType;
  final String codec;
  final int bitrate;
  final int? contentLength;
  final String clientUsed;
  final DateTime expiresAt;

  ResolvedStream({
    required this.url,
    required this.itag,
    required this.contentType,
    required this.codec,
    required this.bitrate,
    required this.contentLength,
    required this.clientUsed,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class InnerTubeClient {
  final _http = http.Client();
  final _cache = <String, ResolvedStream>{};
  String? _visitorData;

  Future<ResolvedStream?> resolve(String videoId, {bool force = false}) async {
    if (force) _cache.remove(videoId);
    final hit = _cache[videoId];
    if (hit != null && !hit.isExpired) return hit;

    await _ensureVisitorData();
    for (final c in _clients) {
      try {
        final r = await _playerCall(videoId, c);
        if (r != null) {
          _cache[videoId] = r;
          return r;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> _ensureVisitorData() async {
    if (_visitorData != null) return;
    try {
      final body = {
        'context': {
          'client': {
            'clientName': 'ANDROID_MUSIC',
            'clientVersion': '5.26.1',
            'androidSdkVersion': 33,
            'osName': 'Android',
            'osVersion': '13',
            'hl': 'en',
            'gl': 'US',
          }
        }
      };
      final resp = await _http
          .post(
            Uri.parse('$_configEndpoint?key=$_androidMusicKey&prettyPrint=false'),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent':
                  'com.google.android.apps.youtube.music/5.26.1 (Linux; U; Android 13; en_US) gzip',
              'X-YouTube-Client-Name': '21',
              'X-YouTube-Client-Version': '5.26.1',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      final vd = (j['responseContext']?['visitorData'] as String?) ??
          (j['visitorData'] as String?);
      if (vd != null) _visitorData = vd;
    } catch (_) {}
  }

  Future<ResolvedStream?> _playerCall(String videoId, _Client c) async {
    final ctx = <String, dynamic>{
      'clientName': c.name,
      'clientVersion': c.version,
      'androidSdkVersion': c.sdk,
      'osName': 'Android',
      'osVersion': c.sdk >= 33 ? '13' : '11',
      'platform': 'MOBILE',
      'hl': 'en',
      'gl': 'US',
      'utcOffsetMinutes': 0,
    };
    if (!c.skipVisitorData && _visitorData != null) {
      ctx['visitorData'] = _visitorData;
    }
    final body = <String, dynamic>{
      'videoId': videoId,
      if (c.playerParams != null) 'params': c.playerParams,
      'context': {'client': ctx},
      'playbackContext': {
        'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'}
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    };

    final resp = await _http
        .post(
          Uri.parse('$_playerEndpoint?key=${c.key}&prettyPrint=false'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'User-Agent': c.userAgent,
            'X-YouTube-Client-Name': c.code,
            'X-YouTube-Client-Version': c.version,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) return null;

    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final status = j['playabilityStatus']?['status'] as String? ?? '';
    if (status != 'OK') {
      if (status == 'LOGIN_REQUIRED') _visitorData = null;
      return null;
    }

    final formats =
        (j['streamingData']?['adaptiveFormats'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
    final audio = formats.where((f) {
      final mime = f['mimeType'] as String? ?? '';
      final url = f['url'] as String?;
      final hasCipher =
          f.containsKey('signatureCipher') || f.containsKey('cipher');
      return mime.startsWith('audio/') && url != null && url.isNotEmpty && !hasCipher;
    }).toList();
    if (audio.isEmpty) return null;

    Map<String, dynamic>? best;
    for (final itag in _preferredItags) {
      best = audio.firstWhereOrNull((f) => f['itag'] == itag);
      if (best != null) break;
    }
    best ??= audio.reduce(
        (a, b) => (a['bitrate'] as int? ?? 0) >= (b['bitrate'] as int? ?? 0) ? a : b);

    final url = best['url'] as String;
    final u = Uri.tryParse(url);
    final ok = u != null &&
        (u.host.contains('googlevideo.com')) &&
        url.contains('expire=');
    if (!ok) return null;

    final mime = best['mimeType'] as String? ?? '';
    final codecMatch = RegExp('codecs="([^"]+)"').firstMatch(mime);
    return ResolvedStream(
      url: url,
      itag: best['itag'] as int? ?? 0,
      contentType: mime,
      codec: codecMatch?.group(1) ?? 'unknown',
      bitrate: best['bitrate'] as int? ?? 0,
      contentLength: int.tryParse('${best['contentLength'] ?? ''}'),
      clientUsed: c.name,
      expiresAt: _parseExpiry(url),
    );
  }

  DateTime _parseExpiry(String url) {
    final m = RegExp(r'[?&]expire=(\d+)').firstMatch(url);
    if (m != null) {
      return DateTime.fromMillisecondsSinceEpoch(int.parse(m.group(1)!) * 1000);
    }
    return DateTime.now().add(const Duration(hours: 6));
  }

  void dispose() {
    _cache.clear();
    _http.close();
  }
}

extension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}

StreamSpec specFromResolved(ResolvedStream r) => StreamSpec(
      uri: Uri.parse(r.url),
      contentType: r.contentType,
      bitrate: r.bitrate,
      expiresAt: r.expiresAt,
    );
