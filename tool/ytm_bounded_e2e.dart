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
  proxy.registerResolver(
      'ytm', (String id, int? hint) async => Uri.parse(r.url));
  final url = proxy.proxyUrl(
    sourceId: 'ytm',
    trackId: 'jWs_EsTFUi8',
    originUrl: Uri.parse(r.url),
  );
  // Client sends a bounded Range (like just_audio on seek):
  // expect 206 + exactly the requested bytes.
  final req = await HttpClient().getUrl(url);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1048576');
  final resp = await req.close();
  var bytes = 0;
  await for (final b in resp) {
    bytes += b.length;
  }
  stdout.writeln('bounded Range via proxy: HTTP ${resp.statusCode}, '
      '$bytes bytes, content-range=${resp.headers.value(HttpHeaders.contentRangeHeader) ?? "-"}');
  exit(resp.statusCode == 206 && bytes == 1048577 ? 0 : 2);
}
