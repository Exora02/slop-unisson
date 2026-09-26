import 'dart:async';
import 'dart:io';

/// Local HTTP stream proxy (NewPipe/InnerTune pattern).
///
/// The player is pointed at 127.0.0.1:<port> instead of the CDN. The
/// proxy forwards Range requests upstream with the right headers and,
/// when the CDN rejects an expired token (403/410), transparently
/// re-resolves a fresh URL via the provider and retries with the same
/// Range — the player never sees the failure.
///
/// Kills two bug classes at once:
///  - googlevideo rejecting ExoPlayer's media fetch ("playback error 0")
///    even though the URL resolves and serves bytes in probes
///  - Qobuz CDN cutting the connection when the stream token expires
///    mid-track (music dies before the song ends)
class StreamProxy {
  // autoUncompress=false: bytes must flow through VERBATIM. With the
  // default (true) Dart decompresses gzip bodies while the upstream
  // content-encoding/-length headers are copied along — the client
  // then reads fewer bytes than promised and dies mid-stream.
  final _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 15);

  HttpServer? _server;
  int _port = 0;

  /// Bound loopback port (0 until started).
  int get port => _port;
  Future<int>? _starting;

  /// Fresh-URL resolvers by source id, registered at startup. Given the
  /// track id (and format hint) they return a new playable upstream URL.
  final _resolvers =
      <String, Future<Uri?> Function(String trackId, int? hint)>{};

  void registerResolver(
      String sourceId, Future<Uri?> Function(String trackId, int? hint) fn) {
    _resolvers[sourceId] = fn;
  }

  /// Memoized so callers can safely await on every playback — the first
  /// call binds, later calls return immediately. Without this, a track
  /// loading before the bind completed got a port-0 URL and died.
  Future<int> start() => _starting ??= _bind();

  Future<int> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    server.listen((req) {
      _onRequest(req);
    }, onError: (Object e) {
      // server-level failures must never take the app down
    });
    return _port;
  }

  Uri proxyUrl({
    required String sourceId,
    required String trackId,
    required Uri originUrl,
    int? formatHint,
    String? userAgent,
  }) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: _port, pathSegments: [
        's', sourceId, trackId
      ], queryParameters: {
        'u': originUrl.toString(),
        if (formatHint != null) 'f': '$formatHint',
        if (userAgent != null && userAgent.isNotEmpty) 'ua': userAgent,
      });

  Future<void> _onRequest(HttpRequest req) async {
    final res = req.response;
    try {
      final segs = req.uri.pathSegments;
      // Spotify Web Playback SDK host page: served locally so the
      // WebView gets a secure context (127.0.0.1 is trusted) for EME.
      if (segs.length == 1 && segs[0] == 'spotify-host') {
        res.statusCode = HttpStatus.ok;
        res.headers.contentType = ContentType.html;
        res.write(SpotifyHostPage.html);
        await res.close();
        return;
      }
      if (segs.length < 3 || segs[0] != 's') {
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }
      final sourceId = segs[1];
      final trackId = segs[2];
      var url = Uri.tryParse(req.uri.queryParameters['u'] ?? '');
      final hint = int.tryParse(req.uri.queryParameters['f'] ?? '');
      final range = req.headers.value(HttpHeaders.rangeHeader);
      final ua = req.uri.queryParameters['ua'];

      for (var attempt = 0; attempt < 3; attempt++) {
        if (url == null) break;
        // googlevideo caps ranged GETs at ~1MiB (PO-token era): larger
        // or open-ended ranges 403. Serve YTM by chaining bounded
        // chunks into the client's response.
        if (sourceId == 'ytm') {
          final served = await _serveYtmChunked(url, range, ua, res);
          if (served) return;
          // fall through to the classic path (resolver retry below)
        }
        final upstream = await _fetchUpstream(url, range, sourceId, ua);
        if (upstream != null) {
          res.statusCode = upstream.statusCode;
          upstream.headers.forEach((name, values) {
            if (_isHopByHop(name)) return;
            for (final v in values) {
              try {
                res.headers.add(name, v);
              } catch (_) {}
            }
          });
          try {
            await upstream.pipe(res);
          } catch (_) {
            // client went away (skip/stop) — close quietly
            try { await upstream.drain().timeout(const Duration(seconds: 2)); } catch (_) {}
          }
          return;
        }
        // upstream rejected the URL — get a fresh one, same Range
        final resolver = _resolvers[sourceId];
        if (resolver == null) break;
        try {
          url = await resolver(trackId, hint)
              .timeout(const Duration(seconds: 20));
        } catch (_) {
          url = null;
        }
        if (url == null) break;
      }
      res.statusCode = HttpStatus.notFound;
      res.write('proxy: upstream exhausted (source=$sourceId id=$trackId)');
      await res.close();
    } catch (_) {
      try { await res.close(); } catch (_) {}
    }
  }

  Future<HttpClientResponse?> _fetchUpstream(
      Uri url, String? range, String sourceId, String? uaOverride) async {
    try {
      var effRange = range;
      if (sourceId == 'ytm') {
        // googlevideo (PO-token era) 403s every open-ended or absent
        // Range — only explicitly bounded ranges serve bytes. Learn
        // the total via a 1-byte probe, then re-issue bounded.
        final parsed = _parseRange(range);
        if (parsed == null || parsed.$2 == null) {
          final start = parsed?.$1 ?? 0;
          final total = await _probeTotal(url, uaOverride);
          if (total != null && total > start) {
            effRange = 'bytes=$start-${total - 1}';
          } else if (total != null && total == start) {
            // seeking to exact EOF — clamp to last byte
            effRange = 'bytes=${start > 0 ? start - 1 : 0}-${total - 1}';
          } else {
            return null;
          }
        }
      }
      final req = await _client.openUrl('GET', url);
      req.followRedirects = true;
      if (effRange != null && effRange.isNotEmpty) {
        req.headers.set(HttpHeaders.rangeHeader, effRange);
      }
      final ua = uaOverride ?? _userAgentFor(sourceId);
      if (ua != null) req.headers.set(HttpHeaders.userAgentHeader, ua);
      final resp = await req.close();
      if (resp.statusCode == HttpStatus.ok ||
          resp.statusCode == HttpStatus.partialContent) {
        return resp;
      }
      await resp.drain<void>().catchError((_) {});
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Serve a YTM request as a chain of <=1MiB bounded ranges. Returns
  /// true when at least the first chunk reached the client; false when
  /// the path is unusable (caller falls back to the classic proxy).
  Future<bool> _serveYtmChunked(
      Uri url, String? range, String? ua, HttpResponse res) async {
    final parsed = _parseRange(range);
    final start = parsed?.$1 ?? 0;
    final total = await _probeTotal(url, ua);
    if (total == null || total <= 0) return false;
    var end = parsed?.$2 ?? total - 1;
    if (end >= total) end = total - 1;
    const chunk = 1024 * 1024 - 1; // <=1MiB inclusive
    res.statusCode = HttpStatus.partialContent;
    res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    res.contentLength = end - start + 1;
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.contentType = ContentType.binary;
    var pos = start;
    try {
      while (pos <= end) {
        final chunkEnd = pos + chunk < end ? pos + chunk : end;
        final req = await _client.openUrl('GET', url);
        req.followRedirects = true;
        req.headers.set(
            HttpHeaders.rangeHeader, 'bytes=$pos-$chunkEnd');
        final u = ua ?? _userAgentFor('ytm');
        if (u != null) req.headers.set(HttpHeaders.userAgentHeader, u);
        final resp = await req.close();
        if (resp.statusCode != HttpStatus.partialContent) {
          await resp.drain<void>().catchError((_) {});
          try { await res.close(); } catch (_) {}
          return true; // partial bytes already sent — just stop
        }
        try {
          await for (final b in resp) {
            res.add(b);
          }
          await res.flush();
        } catch (_) {
          try { await resp.drain().timeout(const Duration(seconds: 2)); } catch (_) {}
          return true; // client went away
        }
        pos = chunkEnd + 1;
      }
      await res.close();
    } catch (_) {}
    return true;
  }

  /// (start, end) from a Range header, null if absent/unparseable.
  (int, int?)? _parseRange(String? range) {
    if (range == null) return null;
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    if (m == null) return null;
    final start = int.parse(m.group(1)!);
    final endStr = m.group(2)!;
    return (start, endStr.isEmpty ? null : int.parse(endStr));
  }

  /// Total content length via a 1-byte ranged probe
  /// (Content-Range: bytes 0-0/TOTAL). Null when unavailable.
  Future<int?> _probeTotal(Uri url, String? uaOverride) async {
    try {
      final req = await _client.openUrl('GET', url);
      req.followRedirects = true;
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final ua = uaOverride ?? _userAgentFor('ytm');
      if (ua != null) req.headers.set(HttpHeaders.userAgentHeader, ua);
      final resp = await req.close();
      await resp.drain<void>().catchError((_) {});
      if (resp.statusCode != HttpStatus.partialContent) return null;
      final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
      final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
      if (m == null) {
        return resp.contentLength >= 0 && resp.contentLength > 0
            ? null
            : null;
      }
      return int.parse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// The UA the CDN saw when the URL was minted. Some CDNs bind the
  /// media fetch to the client identity; a mismatch reads as bot
  /// traffic (this is the suspected "playback error 0" trigger).
  String? _userAgentFor(String sourceId) {
    switch (sourceId) {
      case 'ytm':
        return 'com.google.ios.youtube/20.32.4 (iPhone16,2; U; CPU iOS 18_6 like Mac OS X;)';
      case 'qobuz':
        return 'Unisson/1.0';
      default:
        return null;
    }
  }

  bool _isHopByHop(String name) {
    switch (name.toLowerCase()) {
      case 'connection':
      case 'keep-alive':
      case 'proxy-authenticate':
      case 'proxy-authorization':
      case 'te':
      case 'trailer':
      case 'transfer-encoding':
        return true;
      default:
        return false;
    }
  }

  void dispose() {
    _server?.close(force: true);
    _client.close(force: true);
  }
}

/// Spotify Web Playback SDK host page served from the loopback proxy.
/// Loopback HTTP counts as a secure context in WebViews, so EME (the
/// DRM handshake the SDK needs) works without HTTPS.
class SpotifyHostPage {
  static const html = '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Unisson Spotify Host</title>
<script>
window.__tok = null; window.__tokWaiters = [];
window.__deliverToken = function (t) {
  window.__tok = t;
  var w = window.__tokWaiters.splice(0);
  for (var i = 0; i < w.length; i++) w[i](t);
  try {
    var part = t.split('.')[1] || '';
    part = part.replace(/-/g, '+').replace(/_/g, '/');
    while (part.length % 4) part += '=';
    var payload = JSON.parse(atob(part));
    window.spbridge && window.spbridge.postMessage(JSON.stringify(
        {type: 'token_scopes', scopes: payload.scope || 'NO-SCOPE-FIELD'}));
  } catch (e) {
    window.spbridge && window.spbridge.postMessage(JSON.stringify(
        {type: 'token_scopes', scopes: 'UNDECODABLE'}));
  }
};
window.onSpotifyWebPlaybackSDKReady = function () {
  var bridge = function (obj) {
    window.spbridge && window.spbridge.postMessage(JSON.stringify(obj));
  };
  bridge({type: 'js_ready'});
  var player = new Spotify.Player({
    name: 'Unisson',
    volume: 1.0,
    getOAuthToken: function (cb) {
      if (window.__tok) cb(window.__tok);
      else { window.__tokWaiters.push(cb); bridge({type: 'token_req'}); }
    }
  });
  player.addListener('ready', function (d) {
    bridge({type: 'device_ready', deviceId: d.device_id});
  });
  player.addListener('authentication_error', function (e) {
    bridge({type: 'auth_error', message: e.message});
  });
  player.addListener('initialization_error', function (e) {
    bridge({type: 'player_error', kind: 'init', message: e.message});
  });
  player.addListener('account_error', function (e) {
    bridge({type: 'player_error', kind: 'account', message: e.message});
  });
  player.connect();
};
</script>
<script src="https://sdk.scdn.co/spotify-player.js"></script>
</head>
<body></body>
</html>
''';
}
