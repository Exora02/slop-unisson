import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Headless Spotify Connect device: a 1x1 WebView running Spotify's
/// Web Playback SDK against the loopback-proxied host page (secure
/// context for EME). Premium unlocks full tracks; playback is then
/// driven through the Web API remote-control endpoints against this
/// device id.
class SpotifyEngine {
  final Future<String?> Function() loadAccessToken;
  final Future<int> Function() loadPort;
  final String? Function() reportedScopes;
  final void Function(String line) onLog;

  WebViewController? controller;
  String? deviceId;
  bool deviceReady = false;
  bool accountError = false;

  /// Scopes decoded from the access token inside the WebView (what the
  /// SDK actually received) — end of the scope chain of custody.
  String? grantedBySdk;
  Future<bool>? _booting;

  SpotifyEngine({
    required this.loadAccessToken,
    required this.loadPort,
    required this.reportedScopes,
    required this.onLog,
  });

  bool get isReady => deviceReady && deviceId != null;

  Future<bool> ensureBooted() => _booting ??= _boot().catchError((e) {
        onLog('spotify engine boot failed: $e');
        _booting = null;
        return false;
      });

  Future<bool> _boot() async {
    var c = controller;
    if (c == null) {
      final port = await loadPort();
      // The Web Playback SDK refuses mobile user agents ("unsupported
      // browser"). Pretend to be Chrome desktop.
      const ua = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
      final c0 = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent(ua)
        ..addJavaScriptChannel('spbridge', onMessageReceived: (m) {
          try {
            final j = jsonDecode(m.message) as Map<String, dynamic>;
            final type = '${j['type']}';
            if (type == 'token_req') {
              _deliverToken();
            } else if (type == 'device_ready') {
              deviceId = '${j['deviceId']}';
              deviceReady = true;
              accountError = false;
              onLog('spotify device up');
            } else if (type == 'token_scopes') {
              grantedBySdk = '${j['scopes']}';
              onLog('spotify token scopes: ${j['scopes']}');
            } else if (type == 'auth_error') {
              onLog('spotify SDK auth error: ${j['message']}');
            } else if (type == 'player_error') {
              accountError = '${j['kind']}' == 'account';
              onLog('spotify SDK player error (${j['kind']}): ${j['message']}');
            }
          } catch (_) {}
        })
        ..loadRequest(Uri.parse('http://127.0.0.1:$port/spotify-host'));
      // Widevine/EME: the SDK requests protected media identifiers.
      // Denying (the default) kills player init ("failed to initialize
      // player"). The facade hides this API in webview_flutter 4.13,
      // so call the platform interface directly. The host page only
      // ever runs our own Spotify page — grant everything it asks.
      try {
        await (c0.platform as dynamic).setOnPlatformPermissionRequest(
            (request) => request.grant());
      } catch (_) {}
      c = c0;
      controller = c;
    } else {
      // existing controller: reload the host page so the SDK restarts
      // and asks for the CURRENT token (stale-boot fix after relogin)
      deviceReady = false;
      deviceId = null;
      try {
        await c.reload();
      } catch (_) {}
    }
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      if (isReady) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // A failed boot must be retryable — drop the memo so the next
    // ensureBooted() actually re-boots instead of replaying false.
    _booting = null;
    return isReady;
  }

  /// Full restart after a re-login: reloads the host page (fresh JS,
  /// fresh getOAuthToken round-trip) and waits for device_ready.
  Future<bool> reboot() {
    _booting = null;
    return ensureBooted();
  }

  Future<void> _deliverToken() async {
    final t = await loadAccessToken();
    if (t == null || controller == null) return;
    try {
      await controller!.runJavaScript(
          'window.__deliverToken && window.__deliverToken(${jsonEncode(t)});');
    } catch (_) {}
  }

  Future<void> reloadWithFreshToken() async {
    _booting = null;
    deviceReady = false;
    await ensureBooted();
  }

  void dispose() {
    controller = null;
    deviceReady = false;
  }
}

/// Invisible host that keeps the engine's WebView in the tree.
class SpotifyEngineHost extends StatefulWidget {
  final SpotifyEngine engine;
  final Widget child;
  const SpotifyEngineHost(
      {super.key, required this.engine, required this.child});

  @override
  State<SpotifyEngineHost> createState() => _SpotifyEngineHostState();
}

class _SpotifyEngineHostState extends State<SpotifyEngineHost> {
  @override
  Widget build(BuildContext context) {
    final c = widget.engine.controller;
    return Stack(children: [
      widget.child,
      // The WebView must stay in the tree or Android suspends its JS.
      // 1x1 transparent, behind everything.
      if (c != null)
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: WebViewWidget(controller: c),
        ),
    ]);
  }
}
