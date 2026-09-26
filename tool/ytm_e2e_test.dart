import 'dart:io';

import '../lib/core/stream_proxy.dart';
import '../lib/providers/ytm/innertube.dart';

Future<void> main() async {
  final ladder = InnerTubeClient();
  final r = await ladder.resolve('jWs_EsTFUi8');
  if (r == null) {
    stdout.writeln('ladder failed');
    exit(1);
  }
  stdout.writeln('ladder: ${r.clientUsed} itag=${r.itag}');
  final proxy = StreamProxy();
  await proxy.start();
  // Register a resolver that replays the minted URL (fresh fetch would
  // re-mint; we want the proxy fetch path exercised).
  proxy.registerResolver(
      'ytm', (String id, int? hint) async => Uri.parse(r.url));
  final url = proxy.proxyUrl(
    sourceId: 'ytm',
    trackId: 'jWs_EsTFUi8',
    originUrl: Uri.parse(r.url),
  );
  // sanity: direct ranged fetch of the same URL right now
  {
    final req2 = await HttpClient()
        .getUrl(Uri.parse(r.url));
    req2.headers.set(HttpHeaders.userAgentHeader, r.userAgent);
    req2.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
    final resp2 = await req2.close();
    await resp2.drain<void>();
    stdout.writeln('direct ranged: HTTP ${resp2.statusCode}');
  }
  final client = HttpClient();
  // NO Range header — exactly what just_audio's initial GET looks like.
  final req = await client.getUrl(url);
  final resp = await req.close();
  final bytes = await resp.fold<int>(0, (a, c) => a + c.length);
  stdout.writeln('plain GET through proxy: HTTP ${resp.statusCode}, '
      '$bytes bytes, content-range=${resp.headers.value(HttpHeaders.contentRangeHeader) ?? "none"}');
  exit(resp.statusCode == 206 || resp.statusCode == 200 ? 0 : 2);
}
