import 'dart:io';

import '../lib/providers/ytm/innertube.dart';

Future<void> main() async {
  final c = InnerTubeClient();
  final id = Platform.environment['VID'] ?? 'jWs_EsTFUi8';
  stdout.writeln('resolving $id ...');
  final r = await c.resolve(id);
  if (r == null) {
    stdout.writeln('RESOLVE FAILED');
    stdout.writeln('--- trace ---');
    for (final l in c.lastAttemptTrace) stdout.writeln(l);
    exit(1);
  }
  stdout.writeln('resolved itag=${r.itag} via ${r.clientUsed}');
  stdout.writeln('bitrate=${r.bitrate} codec=${r.codec}');
  stdout.writeln('url host=${Uri.parse(r.url).host}');
  // Probe the CDN: does the URL actually serve bytes?
  final req = await HttpClient().getUrl(Uri.parse(r.url));
  req.headers.set('User-Agent', r.userAgent);
  final resp = await req.close();
  stdout.writeln('CDN probe: HTTP ${resp.statusCode}');
  await resp.drain<void>();
  exit(resp.statusCode == 200 ? 0 : 2);
}
