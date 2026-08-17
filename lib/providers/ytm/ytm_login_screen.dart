import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// WebView-based YouTube Music login.
///
/// The user signs into their Google account in a real browser context.
/// Once the `__Secure-3PAPISID` cookie appears (the key the InnerTube
/// SAPISIDHASH auth needs), we capture all cookies for music.youtube.com
/// and return them as a single cookie-header string.
class YtmLoginScreen extends StatefulWidget {
  const YtmLoginScreen({super.key});

  @override
  State<YtmLoginScreen> createState() => _YtmLoginScreenState();
}

class _YtmLoginScreenState extends State<YtmLoginScreen> {
  Timer? _pollTimer;
  bool _checking = false;
  bool _done = false;

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _captureCookies() async {
    if (_checking || _done) return;
    _checking = true;
    try {
      final manager = CookieManager.instance();
      final cookies = await manager.getCookies(
        url: WebUri('https://music.youtube.com'),
      );
      final byName = {for (final c in cookies) c.name: c.value};
      final sapisid = byName['__Secure-3PAPISID'];
      if (sapisid == null || sapisid.isEmpty) return; // not logged in yet

      // Build the raw cookie header for API requests.
      final header = cookies
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      if (!mounted) return;
      setState(() => _done = true);
      Navigator.of(context).pop(header);
    } catch (_) {
      // cookie read failed — keep polling
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
      body: InAppWebView(
        initialUrlRequest:
            URLRequest(url: WebUri('https://music.youtube.com')),
        initialSettings: InAppWebViewSettings(
          userAgent:
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        ),
        onWebViewCreated: (controller) {
          // Poll for the auth cookie so login completes automatically.
          _pollTimer =
              Timer.periodic(const Duration(seconds: 3), (_) => _captureCookies());
        },
        onLoadStop: (controller, url) => _captureCookies(),
      ),
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
