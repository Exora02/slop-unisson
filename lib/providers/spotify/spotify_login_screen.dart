import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'spotify_api.dart';

/// WebView-based Spotify login using the authorization-code flow with
/// PKCE. The user signs in on accounts.spotify.com; the redirect to
/// the custom scheme (registered in their own Spotify app settings)
/// is intercepted and the `code` parameter is exchanged with the
/// stored verifier.
class SpotifyLoginScreen extends StatefulWidget {
  final String clientId;
  final Future<void> Function(String code, String verifier) onCode;

  const SpotifyLoginScreen(
      {super.key, required this.clientId, required this.onCode});

  @override
  State<SpotifyLoginScreen> createState() => _SpotifyLoginScreenState();
}

class _SpotifyLoginScreenState extends State<SpotifyLoginScreen> {
  late final WebViewController _controller;
  late final String _verifier;
  late final String _challenge;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _verifier = _randomVerifier();
    _challenge = base64UrlEncode(sha256.convert(utf8.encode(_verifier)).bytes)
        .replaceAll('=', '');
    final url = 'https://accounts.spotify.com/authorize'
        '?client_id=${Uri.encodeComponent(widget.clientId)}'
        '&response_type=code'
        '&redirect_uri=${Uri.encodeComponent(spotifyRedirectUri)}'
        '&scope=${Uri.encodeComponent('playlist-read-private user-library-read')}'
        '&code_challenge_method=S256'
        '&code_challenge=$_challenge'
        '&show_dialog=true';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          if (req.url.startsWith(spotifyRedirectUri)) {
            final uri = Uri.parse(req.url);
            final code = uri.queryParameters['code'];
            final err = uri.queryParameters['error'];
            if (err != null) {
              if (mounted) {
                setState(() => _error = 'Spotify said: $err');
              }
              return NavigationDecision.prevent;
            }
            if (code != null && !_done) {
              _done = true;
              widget.onCode(code, _verifier).then((_) {
                if (mounted) Navigator.of(context).pop(true);
              }).catchError((e) {
                if (mounted) {
                  setState(() => _error = 'Code exchange failed: $e');
                }
              });
              return NavigationDecision.prevent;
            }
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(url));
  }

  String _randomVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rnd = Random.secure();
    return List.generate(64, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to Spotify'),
      ),
      body: Column(
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: const Color(0xFF3B0A0A),
              child: Text(_error!, style: const TextStyle(fontSize: 12)),
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Sign in with your Spotify account. This grants read access to '
            'your playlists and liked songs for import. Playback still needs '
            'a separate phase.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }
}
