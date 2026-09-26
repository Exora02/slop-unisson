import 'dart:io';

import '../lib/providers/ytm/innertube.dart';

Future<void> main() async {
  final c = InnerTubeClient();
  final r = await c.resolve('jWs_EsTFUi8', force: true);
  if (r == null) {
    stdout.writeln('RESOLVE FAILED (expected with probe)');
    for (final l in c.lastAttemptTrace) stdout.writeln(l);
    return;
  }
  stdout.writeln('resolved via ${r.clientUsed} itag=${r.itag}');
  for (final l in c.lastAttemptTrace) stdout.writeln('trace: $l');
  // ranged vs full GET comparison
  for (final ranged in [true, false]) {
    final req = await HttpClient().getUrl(Uri.parse(r.url));
    req.headers.set(HttpHeaders.userAgentHeader, r.userAgent);
    if (ranged) req.headers.set('Range', 'bytes=0-1023');
    final resp = await req.close();
    await resp.drain<void>();
    stdout.writeln('ranged=$ranged -> HTTP ${resp.statusCode}');
  }
}
