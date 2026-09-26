import 'dart:io';

import '../lib/providers/ytm/innertube.dart';

Future<void> probe(String url, String ua, String range) async {
  final req = await HttpClient().getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, ua);
  req.headers.set(HttpHeaders.rangeHeader, range);
  final resp = await req.close();
  await resp.drain<void>();
  stdout.writeln('  $range -> ${resp.statusCode}');
}

Future<void> main() async {
  final c = InnerTubeClient();
  final r = (await c.resolve('jWs_EsTFUi8', force: true))!;
  stdout.writeln('fresh url, ascending sizes:');
  await probe(r.url, r.userAgent, 'bytes=0-1023');
  await probe(r.url, r.userAgent, 'bytes=0-1048576');
  await probe(r.url, r.userAgent, 'bytes=0-1048577');
  await probe(r.url, r.userAgent, 'bytes=0-1048578');
}
