import 'dart:io';

import '../lib/providers/ytm/innertube.dart';

Future<void> main(List<String> args) async {
  final c = InnerTubeClient();
  final id = args.isNotEmpty ? args[0] : 'jWs_EsTFUi8';
  stdout.writeln('resolving $id ...');
  final r = await c.resolve(id);
  if (r == null) {
    stdout.writeln('RESOLVE FAILED');
    for (final l in c.lastAttemptTrace) stdout.writeln(l);
    exit(1);
  }
  stdout.writeln('resolved itag=${r.itag} via ${r.clientUsed}');
  stdout.writeln('UA used: ${r.userAgent}');
  final probes = <String, String>{
    'resolve-UA': r.userAgent,
    'no-UA': '',
    'desktop-chrome': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  };
  for (final e in probes.entries) {
    final req = await HttpClient().getUrl(Uri.parse(r.url));
    if (e.value.isNotEmpty) req.headers.set(HttpHeaders.userAgentHeader, e.value);
    final resp = await req.close();
    await resp.drain<void>();
    stdout.writeln('${e.key}: HTTP ${resp.statusCode}');
  }
}
