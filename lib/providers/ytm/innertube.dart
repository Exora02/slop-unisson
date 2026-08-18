import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/models.dart';
import 'ytm_config.dart';
import 'ytm_library_client.dart' show sapisidHash;

const _playerEndpoint = 'https://music.youtube.com/youtubei/v1/player';
const _androidMusicKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
const _androidKey = 'AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w';

class _Client {
  final String name;
  final String code;
  final String version;
  final String key;
  final int sdk;
  final String userAgent;

  /// iOS/WEB-style clients use a lean context (no android fields).
  final bool lean;

  /// Attach the logged-in user's SAPISIDHASH auth when available.
  final bool auth;

  /// Optional android device fields; some clients (ANDROID_VR) only
  /// resolve when the context carries the exact device identity.
  final String? deviceMake;
  final String? deviceModel;
  final String? osVersionOverride;

  const _Client(this.name, this.code, this.version, this.key, this.sdk,
      this.userAgent,
      {this.lean = false,
      this.auth = false,
      this.deviceMake,
      this.deviceModel,
      this.osVersionOverride});
}

// Ladder verified live on 2026-08-18 against a failing videoId:
// - ANDROID_MUSIC 7.16.51 passes the precondition check but answers
//   LOGIN_REQUIRED anonymously -> with the user's cookie it yields the
//   full-quality opus streams.
// - IOS is the only client that resolves anonymously (direct AAC urls).
// Everything else (old ANDROID_MUSIC, ANDROID, ANDROID_VR,
// ANDROID_TESTSUITE, WEB, MWEB, TVHTML5*) is dead: 400 Precondition
// check failed / LOGIN_REQUIRED / UNPLAYABLE / "no longer supported".
const _clients = [
  _Client(
      'ANDROID_MUSIC',
      '21',
      '7.16.51',
      _androidMusicKey,
      34,
      'com.google.android.apps.youtube.music/7.16.51 (Linux; U; Android 14; en_US) gzip',
      auth: true),
  _Client('IOS', '5', '20.32.4', _androidKey, 0,
      'com.google.ios.youtube/20.32.4 (iPhone16,2; U; CPU iOS 18_6 like Mac OS X;)',
      lean: true),
    // CANARY-MANAGED anonymous fallback: the ytm_ladder_canary cron rewrites
  // this entry from yt-dlp's current working spec when it rots.
  _Client('ANDROID_VR', '28', '1.65.10', _androidKey, 32,
      'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
      deviceMake: 'Oculus', deviceModel: 'Quest 3', osVersionOverride: '12L'),
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

  /// Logged-in YTM cookie, injected by the provider. When present, the
  /// auth-flagged clients attach a SAPISIDHASH Authorization header —
  /// authenticated requests bypass the anonymous bot wall entirely.
  String? cookie;

  /// Diagnostic trace of the most recent resolve attempt, one line per
  /// client. Surfaced when resolution fails so we know WHY.
  final List<String> lastAttemptTrace = [];

  Future<ResolvedStream?> resolve(String videoId, {bool force = false}) async {
    if (force) _cache.remove(videoId);
    final hit = _cache[videoId];
    if (hit != null && !hit.isExpired) return hit;

    lastAttemptTrace.clear();
    var r = await _tryLadder(videoId);
    if (r != null) {
      _cache[videoId] = r;
      return r;
    }
    // Second attempt without the auth header's second having rolled over
    // is pointless; instead retry once in case of transient throttling.
    r = await _tryLadder(videoId);
    if (r != null) {
      _cache[videoId] = r;
      return r;
    }
    return null;
  }

  Future<ResolvedStream?> _tryLadder(String videoId) async {
    for (final c in _clients) {
      if (c.auth && cookie == null) {
        lastAttemptTrace.add('${c.name}: skipped (not logged in)');
        continue;
      }
      try {
        final r = await _playerCall(videoId, c);
        if (r != null) return r;
      } catch (_) {}
    }
    return null;
  }

  /// SAPISIDHASH Authorization header for the current second, derived
  /// from the __Secure-3PAPISID cookie value.
  String? _authorization() {
    final c = cookie;
    if (c == null) return null;
    String? sapisid;
    for (final part in c.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length == 2 &&
          (kv[0] == '__Secure-3PAPISID' || kv[0] == 'SAPISID')) {
        sapisid = kv[1];
      }
    }
    if (sapisid == null) return null;
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    return sapisidHash(ts, sapisid, ytmDomain);
  }

  Future<ResolvedStream?> _playerCall(String videoId, _Client c) async {
    final ctx = c.lean
        ? <String, dynamic>{
            'clientName': c.name,
            'clientVersion': c.version,
            'hl': 'en',
            'gl': 'US',
          }
        : <String, dynamic>{
            'clientName': c.name,
            'clientVersion': c.version,
            'androidSdkVersion': c.sdk,
            'osName': 'Android',
            'osVersion': c.osVersionOverride ?? (c.sdk >= 34 ? '14' : '13'),
            if (c.deviceMake != null) 'deviceMake': c.deviceMake,
            if (c.deviceModel != null) 'deviceModel': c.deviceModel,
            'platform': 'MOBILE',
            'hl': 'en',
            'gl': 'US',
            'utcOffsetMinutes': 0,
          };
    final body = <String, dynamic>{
      'videoId': videoId,
      'context': {'client': ctx},
      if (!c.lean)
        'playbackContext': {
          'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'}
        },
      'contentCheckOk': true,
      'racyCheckOk': true,
    };

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': c.userAgent,
      'X-YouTube-Client-Name': c.code,
      'X-YouTube-Client-Version': c.version,
    };
    if (c.auth && cookie != null) {
      final auth = _authorization();
      if (auth != null) {
        headers['Authorization'] = auth;
        headers['Origin'] = ytmDomain;
        headers['Cookie'] = cookie!;
      }
    }

    final resp = await _http
        .post(
          Uri.parse('$_playerEndpoint?key=${c.key}&prettyPrint=false'),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      final snippet = resp.body.length > 160
          ? resp.body.substring(0, 160)
          : resp.body;
      lastAttemptTrace.add(
          '${c.name}: HTTP ${resp.statusCode} ${snippet.replaceAll('\n', ' ')}');
      return null;
    }

    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final status = j['playabilityStatus']?['status'] as String? ?? '';
    if (status != 'OK') {
      final reason = j['playabilityStatus']?['reason'] as String? ?? '';
      lastAttemptTrace.add('${c.name}: status=$status${reason.isEmpty ? '' : ' ($reason)'}');
      return null;
    }

    final formats = (j['streamingData']?['adaptiveFormats'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final audio = formats.where((f) {
      final mime = f['mimeType'] as String? ?? '';
      final url = f['url'] as String?;
      final hasCipher =
          f.containsKey('signatureCipher') || f.containsKey('cipher');
      return mime.startsWith('audio/') && url != null && url.isNotEmpty && !hasCipher;
    }).toList();
    if (audio.isEmpty) {
      lastAttemptTrace.add('${c.name}: OK but no direct-url audio formats');
      return null;
    }

    Map<String, dynamic>? best;
    for (final itag in _preferredItags) {
      best = audio.firstWhereOrNull((f) => f['itag'] == itag);
      if (best != null) break;
    }
    best ??= audio.reduce(
        (a, b) => (a['bitrate'] as num? ?? 0) >= (b['bitrate'] as num? ?? 0) ? a : b);

    final url = best['url'] as String;
    final u = Uri.tryParse(url);
    final ok = u != null &&
        (u.host.contains('googlevideo.com')) &&
        url.contains('expire=');
    if (!ok) {
      lastAttemptTrace.add('${c.name}: stream URL failed validation');
      return null;
    }

    final mime = best['mimeType'] as String? ?? '';
    final codecMatch = RegExp('codecs="([^"]+)"').firstMatch(mime);
    return ResolvedStream(
      url: url,
      itag: (best['itag'] as num?)?.toInt() ?? 0,
      contentType: mime,
      codec: codecMatch?.group(1) ?? 'unknown',
      bitrate: (best['bitrate'] as num?)?.toInt() ?? 0,
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
