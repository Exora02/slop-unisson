import 'dart:io';

import '../lib/providers/ytm/innertube.dart';

Future<int> probe(String url, String ua, String range) async {
  final req = await HttpClient().getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader, ua);
  req.headers.set(HttpHeaders.rangeHeader, range);
  final resp = await req.close();
  await resp.drain<void>();
  return resp.statusCode;
}

Future<void> main() async {
  final c = InnerTubeClient();
  final r = (await c.resolve('jWs_EsTFUi8', force: true))!;
  stdout.writeln('repeat 1KiB x5 on one fresh url:');
  for (var i = 0; i < 5; i++) {
    stdout.writeln('  tiny $i -> ${await probe(r.url, r.userAgent, "bytes=0-1023")}');
  }
  stdout.writeln('then 1MiB:');
  stdout.writeln('  1MiB -> ${await probe(r.url, r.userAgent, "bytes=0-1048576")}');
  stdout.writeln('then tiny again:');
  stdout.writeln('  tiny -> ${await probe(r.url, r.userAgent, "bytes=0-1023")}');
  stdout.writeln('then tiny at offset 2MiB:');
  stdout.writeln('  2MiB-tiny -> ${await probe(r.url, r.userAgent, "bytes=2097152-2098175")}');
}
