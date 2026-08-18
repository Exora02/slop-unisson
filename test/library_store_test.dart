import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:unisson/core/library_service.dart';
import 'package:unisson/core/library_store.dart';
import 'package:unisson/core/models.dart';

MergedTrack track(String title, {String artist = 'Artist'}) {
  final t = Track(
    providerId: 'ytm',
    id: 'id_$title',
    title: title,
    artists: [artist],
    duration: const Duration(minutes: 3),
  );
  return MergedTrack(
    universalKey: '$title|$artist'.toLowerCase(),
    title: title,
    artists: [artist],
    sources: {'ytm': t},
    duration: const Duration(minutes: 3),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late LibraryStore store;

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath);
    store = await LibraryStore.fromDatabase(db);
  });

  tearDown(() async {
    await store.close();
  });

  test('favorites: toggle on/off, stream updates, isFavorite', () async {
    final t = track('Alpha');
    expect(await store.isFavorite(t.universalKey), isFalse);

    expect(await store.toggleFavorite(t), isTrue);
    expect(await store.isFavorite(t.universalKey), isTrue);
    expect(store.favoritesStream.value.length, 1);
    expect(store.favoritesStream.value.first.title, 'Alpha');

    // re-toggle removes it
    expect(await store.toggleFavorite(t), isFalse);
    expect(store.favoritesStream.value, isEmpty);
  });

  test('favorites: newest first', () async {
    await store.toggleFavorite(track('One'));
    await store.toggleFavorite(track('Two'));
    final titles = store.favoritesStream.value.map((t) => t.title).toList();
    expect(titles, ['Two', 'One']);
  });

  test('favorites: stored track keeps all sources', () async {
    final t = track('Multi');
    t.sources['qobuz'] = Track(
        providerId: 'qobuz', id: 'qz_1', title: 'Multi', artists: const ['Artist']);
    await store.toggleFavorite(t);
    final loaded = store.favoritesStream.value.first;
    expect(loaded.sources.keys, containsAll(['ytm', 'qobuz']));
    expect(loaded.sources['qobuz']!.id, 'qz_1');
  });

  test('playlists: create, add, dedupe, list tracks in order', () async {
    final pl = await store.createPlaylist('Road trip');
    expect(store.playlistsStream.value.length, 1);
    expect(store.playlistsStream.value.first.name, 'Road trip');

    expect(await store.addToPlaylist(pl.id, track('A')), isTrue);
    expect(await store.addToPlaylist(pl.id, track('B')), isTrue);
    // duplicate add rejected
    expect(await store.addToPlaylist(pl.id, track('A')), isFalse);

    final tracks = await store.playlistTracks(pl.id);
    expect(tracks.map((t) => t.title).toList(), ['A', 'B']);
    expect(await store.playlistCount(pl.id), 2);
  });

  test('playlists: rename + delete cascades items', () async {
    final pl = await store.createPlaylist('Old name');
    await store.addToPlaylist(pl.id, track('A'));
    await store.renamePlaylist(pl.id, 'New name');
    expect(store.playlistsStream.value.first.name, 'New name');

    await store.deletePlaylist(pl.id);
    expect(store.playlistsStream.value, isEmpty);
    expect(await store.playlistTracks(pl.id), isEmpty);
  });

  test('playlists: remove item resequences positions', () async {
    final pl = await store.createPlaylist('Seq');
    await store.addToPlaylist(pl.id, track('A'));
    await store.addToPlaylist(pl.id, track('B'));
    await store.addToPlaylist(pl.id, track('C'));

    await store.removeFromPlaylist(pl.id, 'b|artist');
    final tracks = await store.playlistTracks(pl.id);
    expect(tracks.map((t) => t.title).toList(), ['A', 'C']);

    // positions must be contiguous now: add again, order preserved
    await store.addToPlaylist(pl.id, track('D'));
    final after = await store.playlistTracks(pl.id);
    expect(after.map((t) => t.title).toList(), ['A', 'C', 'D']);
  });

  test('recently played: dedupe by key, newest first, capped', () async {
    await store.addRecent(track('First'));
    await store.addRecent(track('Second'));
    // replaying "First" moves it to the top, no duplicate row
    await store.addRecent(track('First'));

    final titles = store.recentStream.value.map((t) => t.title).toList();
    expect(titles, ['First', 'Second']);
  });

  test('recently played: 100-entry cap', () async {
    for (var i = 0; i < 105; i++) {
      await store.addRecent(track('t$i'));
    }
    expect(store.recentStream.value.length, 100);
    // newest still first
    expect(store.recentStream.value.first.title, 't104');
  });

  test('persistence across store instances on the same db', () async {
    await store.toggleFavorite(track('Keep me'));
    final pl = await store.createPlaylist('Persist');
    await store.addToPlaylist(pl.id, track('In list'));
    await store.addRecent(track('Heard'));

    final store2 = await LibraryStore.fromDatabase(db);
    expect(await store2.isFavorite(track('Keep me').universalKey), isTrue);
    expect((await store2.playlistTracks(pl.id)).length, 1);
    expect(store2.recentStream.value.length, 1);
  });

  test('enrichTrack merges new sources into every saved copy', () async {
    final t = track('Dual source');
    await store.toggleFavorite(t);
    final pl = await store.createPlaylist('Enrich');
    await store.addToPlaylist(pl.id, t);
    await store.addRecent(t);

    final qobuzTrack = Track(
      providerId: 'qobuz',
      id: 'qobuz:99',
      title: 'Dual source',
      artists: const ['Artist'],
    );
    await store.enrichTrack(t.universalKey, {'qobuz': qobuzTrack});

    final favs = store.favoritesStream.value;
    expect(favs.single.sources.keys, containsAll(['ytm', 'qobuz']));

    final plTracks = await store.playlistTracks(pl.id);
    expect(plTracks.single.sources.containsKey('qobuz'), isTrue);

    expect(store.recentStream.value.single.sources.containsKey('qobuz'),
        isTrue);
  });
}
