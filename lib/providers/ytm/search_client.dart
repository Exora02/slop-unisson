import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ytm_config.dart';

const _songsParam = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';

class YtmSong {
  final String videoId;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationSeconds;
  final String? artwork;

  const YtmSong({
    required this.videoId,
    required this.title,
    this.artists = const [],
    this.album,
    this.durationSeconds,
    this.artwork,
  });
}

class YtmSearchClient {
  final _http = http.Client();
  String? _visitorId;

  Future<List<YtmSong>> searchSongs(String query) async {
    await _ensureVisitorId();
    final body = {
      'query': query,
      'params': _songsParam,
      'context': {
        'client': {
          'clientName': 'WEB_REMIX',
          'clientVersion': ytmWebClientVersion(),
        },
        'user': <String, dynamic>{},
      },
    };

    final resp = await _http
        .post(
          Uri.parse('$ytmApiBase/search?key=$ytmWebKey&alt=json'),
          headers: {
            'User-Agent': ytmUserAgent,
            'Accept': '*/*',
            'Content-Type': 'application/json',
            'Origin': ytmDomain,
            if (_visitorId != null) 'X-Goog-Visitor-Id': _visitorId!,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode >= 400) {
      throw Exception('YTM search HTTP ${resp.statusCode}');
    }

    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final contents = j['contents'] as Map<String, dynamic>?;
    if (contents == null) return [];

    List<dynamic> sections;
    final tabbed =
        contents['tabbedSearchResultsRenderer'] as Map<String, dynamic>?;
    if (tabbed != null) {
      sections = ((tabbed['tabs'] as List)[0]['tabRenderer']['content']
          ['sectionListRenderer']['contents']) as List;
    } else {
      sections = contents['sectionListRenderer']?['contents'] as List? ?? [];
    }

    final songs = <YtmSong>[];
    for (final sec in sections) {
      final items =
          sec['musicShelfRenderer']?['contents'] as List<dynamic>? ?? [];
      for (final item in items) {
        final mrlir = item['musicResponsiveListItemRenderer'];
        if (mrlir == null) continue;
        final s = _parseSong(mrlir as Map<String, dynamic>);
        if (s != null) songs.add(s);
      }
    }
    return songs;
  }

  YtmSong? _parseSong(Map<String, dynamic> m) {
    List<dynamic> runs(int i) {
      final flex = m['flexColumns'] as List<dynamic>?;
      if (flex == null || i >= flex.length) return [];
      return flex[i]['musicResponsiveListItemFlexColumnRenderer']?['text']
              ?['runs'] as List<dynamic>? ??
          [];
    }

    final titleRuns = runs(0);
    if (titleRuns.isEmpty) return null;

    String? videoId = m['playlistItemData']?['videoId'] as String?;
    videoId ??= titleRuns[0]['navigationEndpoint']?['watchEndpoint']
        ?['videoId'] as String?;
    if (videoId == null) return null;

    final title = titleRuns[0]['text'] as String;

    final metaRuns = runs(1)
        .where((r) {
          final t = (r['text'] as String? ?? '').trim();
          return t.isNotEmpty && !RegExp(r'^[•·\-–]+$').hasMatch(t);
        })
        .toList();

    final artists =
        metaRuns.isNotEmpty ? [metaRuns[0]['text'] as String] : <String>[];

    // layout: artist [• album] [• duration]
    String? album;
    String? durText;
    if (metaRuns.length >= 3 &&
        RegExp(r'^\d+:\d+$').hasMatch((metaRuns[2]['text'] as String).trim())) {
      album = metaRuns[1]['text'] as String;
      durText = metaRuns[2]['text'] as String;
    } else if (metaRuns.length >= 2) {
      final last = (metaRuns.last['text'] as String).trim();
      if (RegExp(r'^\d+:\d+$').hasMatch(last)) {
        durText = last;
      } else {
        album = last;
      }
    }

    // fixed column duration if present (some layouts)
    if (durText == null) {
      final fixed = m['fixedColumns'] as List<dynamic>?;
      if (fixed != null && fixed.isNotEmpty) {
        durText = fixed[0]['musicResponsiveListItemFixedColumnRenderer']
            ?['text']?['runs']?[0]?['text'] as String?;
      }
    }

    final thumbs = m['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
        ?['thumbnails'] as List<dynamic>?;
    final art = thumbs != null && thumbs.isNotEmpty
        ? thumbs.last['url'] as String
        : null;

    return YtmSong(
      videoId: videoId,
      title: title,
      artists: artists,
      album: album,
      durationSeconds: _parseDuration(durText),
      artwork: art,
    );
  }

  int? _parseDuration(String? s) {
    if (s == null) return null;
    try {
      var total = 0;
      for (final p in s.split(':')) {
        total = total * 60 + int.parse(p);
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureVisitorId() async {
    if (_visitorId != null) return;
    try {
      final resp = await _http
          .get(Uri.parse(ytmDomain),
              headers: {'User-Agent': ytmUserAgent})
          .timeout(const Duration(seconds: 15));
      final m = RegExp(r'ytcfg\.set\(\s*({.+?})\s*\)\s*;').firstMatch(resp.body);
      if (m != null) {
        final cfg = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        _visitorId = cfg['VISITOR_DATA'] as String?;
      }
    } catch (_) {}
  }

  void dispose() {
    _http.close();
  }
}
