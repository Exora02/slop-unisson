import 'dart:io';

import '../lib/providers/ytm/innertube.dart';

Future<void> probe(String url, String ua, int end) async {
  final req = await HttpClient().getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, ua);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-$end');
  final resp = await req.close();
  await resp.drain<void>();
  stdout.writeln('  0-$end (${(end / 1024).toStringAsFixed(0)}KiB) -> ${resp.statusCode}');
}

Future<void> main() async {
  final c = InnerTubeClient();
  final r = (await c.resolve('jWs_EsTFUi8', force: true))!;
  stdout.writeln('total per content-range will show; probing sizes');
  await probe(r.url, r.userAgent, 999999);
  await probe(r.url, r.userAgent, 1048575);
  await probe(r.url, r.userAgent, 1048576);
  await probe(r.url, r.userAgent, 2097151);
  await probe(r.url, r.userAgent, 3145727);
  await probe(r.url, r.userAgent, 3155772);
}
