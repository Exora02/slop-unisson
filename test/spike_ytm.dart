import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:unisson/providers/ytm/ytm_provider.dart';
import 'package:unisson/core/models.dart';

Future<void> main(List<String> args) async {
  final query = args.isNotEmpty ? args.join(' ') : 'daft punk veridis quo';
  final ytm = YtmProvider();

  print('== SEARCH: "$query" ==');
  final res = await ytm.search(query);
  print('got ${res.tracks.length} tracks');
  for (final t in res.tracks.take(3)) {
    print('  ${t.id} | ${t.title} | ${t.artists.join(', ')} | ${t.duration}');
  }
  if (res.tracks.isEmpty) {
    print('NO RESULTS');
    exit(1);
  }

  final t = res.tracks.first;
  print('\n== RESOLVE STREAM: ${t.title} (${t.id}) ==');
  final spec = await ytm.resolveStream(t, QualityPref.highest);
  print('url host: ${spec.uri.host}');
  print('content-type: ${spec.contentType}');
  print('bitrate: ${(spec.bitrate ?? 0) ~/ 1000} kbps');
  print('expires: ${spec.expiresAt}');

  print('\n== FETCH FIRST BYTES ==');
  final req = http.Request('GET', spec.uri);
  req.headers['Range'] = 'bytes=0-4096';
  req.headers['User-Agent'] =
      'com.google.android.apps.youtube.music/5.26.1 (Linux; U; Android 13; en_US) gzip';
  final resp = await http.Client().send(req).timeout(const Duration(seconds: 20));
  final bytes = await resp.stream.toBytes();
  print('status: ${resp.statusCode}');
  print('got ${bytes.length} bytes');
  print('magic: ${base64.encode(bytes.take(16).toList())}');
  // opus/webm starts with 0x1A45DFA3 (EBML), m4a with 0x00...66747970 (ftyp)
  final magic = String.fromCharCodes(bytes.take(12).toList()
      .map((b) => b >= 32 && b < 127 ? b : 46));
  print('ascii: $magic');

  ytm.dispose();
  print('\nVERDICT: ${resp.statusCode == 206 && bytes.isNotEmpty ? 'PASS' : 'FAIL'}');
}
