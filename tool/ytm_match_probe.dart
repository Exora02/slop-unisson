import 'dart:convert';
import 'dart:io';

import '../lib/providers/ytm/search_client.dart';
import '../lib/providers/ytm/ytm_config.dart';

Future<void> main() async {
  final c = YtmSearchClient();
  final songs = await c.searchSongs('rough jordyn edmonds');
  stdout.writeln('got ${songs.length} songs');
  for (final s in songs.take(8)) {
    stdout.writeln('- ${s.title} | ${s.artists.join(', ')} | ${s.videoId}');
  }
}
