import 'package:flutter_test/flutter_test.dart';
import 'package:unison/core/library_service.dart';
import 'package:unison/core/models.dart';
import 'package:unison/core/provider.dart';

class _FailingProvider implements MusicProvider {
  _FailingProvider(this.id);
  @override
  final String id;
  @override
  bool get isConfigured => true;
  @override
  Future<SearchResults> search(String query) async {
    throw Exception('$id search exploded');
  }
  @override
  Future<StreamSpec> resolveStream(Track track, QualityPref pref) async {
    throw StateError('n/a');
  }
}

class _OkProvider implements MusicProvider {
  _OkProvider(this.id);
  @override
  final String id;
  @override
  bool get isConfigured => true;
  @override
  Future<SearchResults> search(String query) async {
    if (query.contains('nothing matches')) {
      return const SearchResults();
    }
    return SearchResults(tracks: [
      Track(
        providerId: id,
        id: '$id:1',
        title: 'Veridis Quo',
        artists: const ['Daft Punk'],
      ),
    ]);
  }
  @override
  Future<StreamSpec> resolveStream(Track track, QualityPref pref) async {
    throw StateError('n/a');
  }
}

void main() {
  test('one failing provider does not hide a working one', () async {
    final svc = LibraryService([
      _FailingProvider('qobuz'),
      _OkProvider('ytm'),
    ]);
    final results = await svc.searchAll('veridis quo');
    expect(results, isNotEmpty);
    expect(results.first.sources.keys, contains('ytm'));
    expect(results.first.sources.containsKey('qobuz'), isFalse);
    expect(results.first.title, 'Veridis Quo');
  });

  test('empty search returns empty', () async {
    final svc = LibraryService([_OkProvider('ytm')]);
    final results = await svc.searchAll('nothing matches');
    expect(results, isEmpty);
  });
}