import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../core/models.dart';
import 'ytm_config.dart';

/// A playlist in the user's YTM library.
class YtmLibraryPlaylist {
  final String playlistId; // without the "VL" prefix
  final String title;
  final String? artwork;
  final int? count;

  const YtmLibraryPlaylist({
    required this.playlistId,
    required this.title,
    this.artwork,
    this.count,
  });
}

/// SAPISIDHASH <ts>_<sha1(ts + " " + sapisid + " " + origin)>.
/// Pure so it can be unit-tested against a reference implementation.
String sapisidHash(String ts, String sapisid, String origin) {
  final hash = sha1.convert(utf8.encode('$ts $sapisid $origin')).toString();
  return 'SAPISIDHASH ${ts}_$hash';
}

/// Authenticated access to the user's YTM library via InnerTube (WEB_REMIX).
/// Authentication is cookie-based: after a browser login we keep the raw
/// cookie string and derive the SAPISIDHASH Authorization header from the
/// `__Secure-3PAPISID` value on every request.
class YtmLibraryClient {
  final _http = http.Client();
  String? _cookie;

  bool get isLoggedIn => _cookie != null && _sapisid != null;

  void setCookie(String cookie) => _cookie = cookie;
  void clearCookie() => _cookie = null;
  String? get cookie => _cookie;

  String? get _sapisid {
    final c = _cookie;
    if (c == null) return null;
    for (final part in c.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length == 2 &&
          (kv[0] == '__Secure-3PAPISID' || kv[0] == 'SAPISID')) {
        return kv[1];
      }
    }
    return null;
  }

  /// SAPISIDHASH Authorization header for the current second.
  String _authorization() {
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    return sapisidHash(ts, _sapisid!, ytmDomain);
  }

  Future<Map<String, dynamic>> _browse(Map<String, dynamic> extra) async {
    if (!isLoggedIn) throw StateError('YTM not logged in');
    final body = {
      ...extra,
      'context': {
        'client': {
          'clientName': 'WEB_REMIX',
          'clientVersion': ytmWebClientVersion(),
          'hl': 'en',
          'gl': 'US',
        },
        'user': <String, dynamic>{},
      },
    };
    final resp = await _http
        .post(
          Uri.parse('$ytmApiBase/browse?key=$ytmWebKey&alt=json'),
          headers: {
            'User-Agent': ytmUserAgent,
            'Content-Type': 'application/json',
            'Origin': ytmDomain,
            'Referer': '$ytmDomain/',
            'Cookie': _cookie!,
            'Authorization': _authorization(),
            'x-goog-authuser': '0',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 25));
    if (resp.statusCode >= 400) {
      throw Exception('YTM browse HTTP ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Recursively find the first map value whose key equals [key].
  dynamic _find(dynamic node, String key) {
    if (node is Map) {
      if (node.containsKey(key)) return node[key];
      for (final v in node.values) {
        final r = _find(v, key);
        if (r != null) return r;
      }
    } else if (node is List) {
      for (final v in node) {
        final r = _find(v, key);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// All playlists in the user's library (liked playlists).
  Future<List<YtmLibraryPlaylist>> getLibraryPlaylists() async {
    final j = await _browse({'browseId': 'FEmusic_liked_playlists'});
    final grid = _find(j, 'gridRenderer') ?? _find(j, 'musicShelfRenderer');
    if (grid == null) return [];
    final items = (grid is Map ? grid['items'] as List? : null) ?? const [];
    final out = <YtmLibraryPlaylist>[];
    for (final item in items) {
      final renderer = item is Map ? item['musicTwoRowItemRenderer'] : null;
      if (renderer == null) continue;
      final p = _parsePlaylistTile(renderer as Map<String, dynamic>);
      if (p != null) out.add(p);
    }
    return out;
  }

  YtmLibraryPlaylist? _parsePlaylistTile(Map<String, dynamic> m) {
    final titleRuns = m['title']?['runs'] as List?;
    if (titleRuns == null || titleRuns.isEmpty) return null;
    final title = titleRuns[0]['text'] as String? ?? '';
    var browseId = titleRuns[0]['navigationEndpoint']?['browseEndpoint']
        ?['browseId'] as String?;
    if (browseId == null) return null;
    // Library playlist browse ids are "VL<playlistId>".
    if (browseId.startsWith('VL')) browseId = browseId.substring(2);

    final thumbs = m['thumbnailRenderer']?['musicThumbnailRenderer']
        ?['thumbnail']?['thumbnails'] as List?;
    final art = thumbs != null && thumbs.isNotEmpty
        ? thumbs.last['url'] as String?
        : null;

    int? count;
    final subtitleRuns = m['subtitle']?['runs'] as List?;
    if (subtitleRuns != null && subtitleRuns.isNotEmpty) {
      final txt = subtitleRuns[0]['text'] as String? ?? '';
      final match = RegExp(r'(\d+)').firstMatch(txt);
      if (match != null) count = int.tryParse(match.group(1)!);
    }

    return YtmLibraryPlaylist(
      playlistId: browseId,
      title: title,
      artwork: art,
      count: count,
    );
  }

  /// Tracks of one playlist ("LM" = liked songs).
  Future<List<Track>> getPlaylistTracks(String playlistId) async {
    final browseId = playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';
    final j = await _browse({'browseId': browseId});
    final out = <Track>[];
    final seen = <String>{};
    final shelf = _find(j, 'musicPlaylistShelfRenderer') ??
        _find(j, 'musicShelfRenderer');
    final contents = shelf is Map ? shelf['contents'] as List? : null;
    for (final item in contents ?? const []) {
      final mrlir = item is Map ? item['musicResponsiveListItemRenderer'] : null;
      if (mrlir == null) continue;
      final t = _parseTrack(mrlir as Map<String, dynamic>);
      if (t != null && seen.add(t.id)) out.add(t);
    }
    return out;
  }

  Track? _parseTrack(Map<String, dynamic> m) {
    List<dynamic> runs(int i) {
      final flex = m['flexColumns'] as List?;
      if (flex == null || i >= flex.length) return const [];
      return flex[i]['musicResponsiveListItemFlexColumnRenderer']?['text']
              ?['runs'] as List? ??
          const [];
    }

    final titleRuns = runs(0);
    if (titleRuns.isEmpty) return null;

    String? videoId = m['playlistItemData']?['videoId'] as String?;
    videoId ??= titleRuns[0]['navigationEndpoint']?['watchEndpoint']
        ?['videoId'] as String?;
    if (videoId == null) return null;

    final title = titleRuns[0]['text'] as String? ?? 'Unknown';

    final metaRuns = runs(1)
        .where((r) {
          final t = ((r is Map ? r['text'] : null) as String? ?? '').trim();
          return t.isNotEmpty && !RegExp(r'^[•·\-–]+$').hasMatch(t);
        })
        .toList();
    final artists = metaRuns.isNotEmpty
        ? [(metaRuns[0] is Map ? metaRuns[0]['text'] : null) as String? ?? '']
        : const <String>[];

    String? album;
    String? durText;
    if (metaRuns.length >= 3 &&
        RegExp(r'^\d+:\d+$')
            .hasMatch(((metaRuns[2] is Map ? metaRuns[2]['text'] : null) as String? ?? '').trim())) {
      album = (metaRuns[1] is Map ? metaRuns[1]['text'] : null) as String?;
      durText = (metaRuns[2] is Map ? metaRuns[2]['text'] : null) as String?;
    } else if (metaRuns.length >= 2) {
      final last = ((metaRuns.last is Map ? metaRuns.last['text'] : null) as String? ?? '').trim();
      if (RegExp(r'^\d+:\d+$').hasMatch(last)) {
        durText = last;
      } else {
        album = last;
      }
    }
    if (durText == null) {
      final fixed = m['fixedColumns'] as List?;
      if (fixed != null && fixed.isNotEmpty) {
        durText = fixed[0]['musicResponsiveListItemFixedColumnRenderer']
            ?['text']?['runs']?[0]?['text'] as String?;
      }
    }

    final thumbs = m['thumbnail']?['musicThumbnailRenderer']?['thumbnail']
        ?['thumbnails'] as List?;
    final art = thumbs != null && thumbs.isNotEmpty
        ? thumbs.last['url'] as String?
        : null;

    return Track(
      providerId: 'ytm',
      id: videoId,
      title: title,
      artists: artists.where((a) => a.isNotEmpty).toList(),
      album: album,
      duration: _parseDuration(durText) != null
          ? Duration(seconds: _parseDuration(durText)!)
          : null,
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

  void dispose() {
    _http.close();
  }
}
