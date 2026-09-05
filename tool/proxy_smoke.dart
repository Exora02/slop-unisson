import 'dart:async';
import 'dart:io';

import 'package:unisson/core/stream_proxy.dart';

int failed = 0;

void check(String label, bool ok) {
  print('  ${ok ? 'ok  ' : 'FAIL'}  $label');
  if (!ok) failed++;
}

Future<void> main() async {
  // --- T1: 403 -> re-resolve -> retry with same Range -------------
  print('T1: expired token re-resolve');
  final hits = <String>[];
  final up = await HttpServer.bind('127.0.0.1', 0);
  up.listen((req) async {
    hits.add(req.uri.queryParameters['gen'] ?? 'stale');
    if (req.uri.queryParameters['gen'] == null) {
      req.response.statusCode = 403;
      await req.response.close();
    } else {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      req.response.statusCode = 206;
      req.response.headers.set(HttpHeaders.contentLengthHeader, '4');
      req.response.add(range == 'bytes=2-5' ? [1, 2, 3, 4] : [9, 9, 9, 9]);
      await req.response.close();
    }
  });

  final proxy = StreamProxy();
  final port = await proxy.start();
  check('port bound', port > 0);

  var gen = 0;
  proxy.registerResolver('qobuz', (trackId, hint) async {
    gen++;
    return Uri.parse('http://127.0.0.1:${up.port}/audio?gen=$gen');
  });

  var url = proxy.proxyUrl(
    sourceId: 'qobuz',
    trackId: 't1',
    originUrl: Uri.parse('http://127.0.0.1:${up.port}/audio'),
  );
  var client = HttpClient();
  var req = await client.openUrl('GET', url);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=2-5');
  var resp = await req.close();
  var body = await resp.fold<List<int>>(<int>[], (a, d) => a..addAll(d));
  check('status 206 after retry', resp.statusCode == 206);
  check('range preserved on retry', bodyEquals(body, [1, 2, 3, 4]));
  check('exactly 2 upstream hits', hits.length == 2);
  client.close();
  proxy.dispose();
  await up.close(force: true);

  // --- T2: UA forwarding ------------------------------------------
  print('T2: UA forwarding');
  String? seenUa;
  String? seenRange;
  final up2 = await HttpServer.bind('127.0.0.1', 0);
  up2.listen((req) async {
    seenUa = req.headers.value(HttpHeaders.userAgentHeader);
    seenRange = req.headers.value(HttpHeaders.rangeHeader);
    req.response.statusCode = 206;
    req.response.headers.set(HttpHeaders.contentLengthHeader, '1');
    req.response.add([7]);
    await req.response.close();
  });

  final proxy2 = StreamProxy();
  await proxy2.start();
  final url2 = proxy2.proxyUrl(
    sourceId: 'ytm',
    trackId: 'v1',
    originUrl: Uri.parse('http://127.0.0.1:${up2.port}/a'),
  );
  client = HttpClient();
  req = await client.openUrl('GET', url2);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
  resp = await req.close();
  await resp.drain<void>();
  check('ytm UA forwarded', (seenUa ?? '').contains('com.google.ios.youtube'));
  check('range forwarded', seenRange == 'bytes=0-0');
  client.close();
  proxy2.dispose();
  await up2.close(force: forceClose);

  // --- T2b: explicit ua= param OVERRIDES the source default -------
  print('T2b: UA override param');
  String? seenUa2;
  final up2b = await HttpServer.bind('127.0.0.1', 0);
  up2b.listen((req) async {
    seenUa2 = req.headers.value(HttpHeaders.userAgentHeader);
    req.response.statusCode = 206;
    req.response.headers.set(HttpHeaders.contentLengthHeader, '1');
    req.response.add([1]);
    await req.response.close();
  });
  final proxy2b = StreamProxy();
  await proxy2b.start();
  final url2b = proxy2b.proxyUrl(
    sourceId: 'ytm',
    trackId: 'v2',
    originUrl: Uri.parse('http://127.0.0.1:${up2b.port}/a'),
    userAgent: 'com.google.android.apps.youtube.music/7.16.51 (Linux; U; Android 14; en_US) gzip',
  );
  client = HttpClient();
  req = await client.openUrl('GET', url2b);
  resp = await req.close();
  await resp.drain<void>();
  check('ua param overrides default',
      (seenUa2 ?? '').contains('youtube.music'));
  client.close();
  proxy2b.dispose();
  await up2b.close(force: true);

  // --- T3: live upstream through proxy -----------------------------
  print('T3: live upstream fetch');
  final proxy3 = StreamProxy();
  await proxy3.start();
  final url3 = proxy3.proxyUrl(
    sourceId: 'qobuz',
    trackId: 't1',
    originUrl:
        Uri.parse('https://raw.githubusercontent.com/git/git/master/README.md'),
  );
  client = HttpClient();
  client.autoUncompress = false;
  req = await client.openUrl('GET', url3);
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-99');
  resp = await req.close();
  final n = await resp.fold<int>(0, (a, d) => a + d.length);
  print('    [debug] status=${resp.statusCode} bytes=$n '
      'enc=${resp.headers.value(HttpHeaders.contentEncodingHeader)} '
      'len=${resp.headers.value(HttpHeaders.contentLengthHeader)}');
  check('live fetch 2xx/206',
      resp.statusCode == 200 || resp.statusCode == 206);
  check('bytes flowed through pipe', n >= 100);
  client.close();
  proxy3.dispose();

  print(failed == 0 ? 'ALL PASS' : '$failed FAILURES');
  exit(failed == 0 ? 0 : 1);
}

bool bodyEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const forceClose = true;
