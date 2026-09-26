import 'dart:io';

import '../lib/providers/ytm/innertube.dart';

Future<int> probe(String url, String ua, String range) async {
  final req = await HttpClient().getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, ua);
  if (range.isNotEmpty) req.headers.set(HttpHeaders.rangeHeader, range);
  final resp = await req.close();
  await resp.drain<void>();
  return resp.statusCode;
}

Future<void> main() async {
  final c = InnerTubeClient();
  final r1 = (await c.resolve('jWs_EsTFUi8', force: true))!;
  stdout.writeln('url1 via ${r1.clientUsed}');
  stdout.writeln('  bytes=0-     : ${await probe(r1.url, r1.userAgent, "bytes=0-")}');
  stdout.writeln('  bytes=0-1023 : ${await probe(r1.url, r1.userAgent, "bytes=0-1023")}');
  stdout.writeln('  bytes=0-999999: ${await probe(r1.url, r1.userAgent, "bytes=0-999999")}');
  final r2 = (await c.resolve('jWs_EsTFUi8', force: true))!;
  stdout.writeln('url2 fresh');
  stdout.writeln('  bytes=0-     : ${await probe(r2.url, r2.userAgent, "bytes=0-")}');
  stdout.writeln('  bytes=0-1023 : ${await probe(r2.url, r2.userAgent, "bytes=0-1023")}');
}
