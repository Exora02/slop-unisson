import 'dart:io';

import '../lib/providers/ytm/innertube.dart';

Future<void> probe(String url, String ua, int end) async {
  final req = await HttpClient().getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, ua);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-$end');
  final resp = await req.close();
  await resp.drain<void>();
  stdout.writeln('  0-$end -> ${resp.statusCode}');
}

Future<void> main() async {
  final c = InnerTubeClient();
  final r = (await c.resolve('jWs_EsTFUi8', force: true))!;
  await probe(r.url, r.userAgent, 1572863);
  await probe(r.url, r.userAgent, 1572864);
  await probe(r.url, r.userAgent, 1572865);
  await probe(r.url, r.userAgent, 1310720);
}
