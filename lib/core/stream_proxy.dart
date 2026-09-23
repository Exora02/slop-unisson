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
      final req = await _client.openUrl('GET', url);
      req.followRedirects = true;
      if (range != null && range.isNotEmpty) {
        req.headers.set(HttpHeaders.rangeHeader, range);
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
    bridge({type: 'player_error', message: e.message});
  });
  player.addListener('account_error', function (e) {
    bridge({type: 'player_error', message: 'account: ' + e.message});
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
