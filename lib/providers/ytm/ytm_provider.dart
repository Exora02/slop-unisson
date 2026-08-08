import '../../core/models.dart';
import '../../core/provider.dart';
import 'innertube.dart';
import 'search_client.dart';

class YtmProvider implements MusicProvider {
  final YtmSearchClient _search = YtmSearchClient();
  final InnerTubeClient _streams = InnerTubeClient();

  @override
  String get id => 'ytm';

  @override
  bool get isConfigured => true;

  @override
  Future<SearchResults> search(String query) async {
    final songs = await _search.searchSongs(query);
    return SearchResults(
      tracks: songs
          .map((s) => Track(
                providerId: id,
                id: s.videoId,
                title: s.title,
                artists: s.artists,
                album: s.album,
                duration: s.durationSeconds != null
                    ? Duration(seconds: s.durationSeconds!)
                    : null,
                artwork: s.artwork,
              ))
          .toList(),
    );
  }

  @override
  Future<StreamSpec> resolveStream(Track track, QualityPref pref) async {
    final r = await _streams.resolve(track.id);
    if (r == null) {
      throw StateError('YTM: no stream resolved for ${track.id}');
    }
    return specFromResolved(r);
  }

  void dispose() {
    _search.dispose();
    _streams.dispose();
  }
}
