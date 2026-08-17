import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _cookieChannel = MethodChannel('unisson/cookies');

/// WebView-based YouTube Music login.
///
/// The user signs into their Google account in a real browser context.
/// webview_flutter can't read cookies on Android itself, so a tiny
/// MethodChannel in MainActivity asks Android's CookieManager for the
/// exact cookie header a WebView would send for music.youtube.com.
/// Once `__Secure-3PAPISID` appears (the key the InnerTube SAPISIDHASH
/// auth needs), the header string is returned to the caller.
class YtmLoginScreen extends StatefulWidget {
  const YtmLoginScreen({super.key});

  @override
  State<YtmLoginScreen> createState() => _YtmLoginScreenState();
}

class _YtmLoginScreenState extends State<YtmLoginScreen> {
  late final WebViewController _controller;
  Timer? _pollTimer;
  bool _checking = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) => _captureCookies(),
      ))
      ..loadRequest(Uri.parse('https://music.youtube.com'));
    // Poll so login completes automatically even when Google's consent
    // flow doesn't fire a page-finished event.
    _pollTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _captureCookies());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _captureCookies() async {
    if (_checking || _done) return;
    _checking = true;
    try {
      final header = await _cookieChannel.invokeMethod<String>(
        'getCookies',
        {'url': 'https://music.youtube.com'},
      );
      if (header == null || !header.contains('__Secure-3PAPISID=')) {
        return; // not logged in yet
      }
      if (!mounted || _done) return;
      setState(() => _done = true);
      Navigator.of(context).pop(header);
    } catch (_) {
      // channel/cookie read failed — keep polling
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in to YouTube Music'),
        actions: [
          TextButton(
            onPressed: _captureCookies,
            child: const Text('Done'),
          ),
        ],
      ),
      body: WebViewWidget(controller: _controller),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _done
              ? const Text('Logged in ✓')
              : const Text(
                  'Sign in with the Google account that has your YouTube Music library. '
                  'This window closes automatically once you are signed in.',
                  style: TextStyle(fontSize: 12),
                ),
        ),
      ),
    );
  }
}
