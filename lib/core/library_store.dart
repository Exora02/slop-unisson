import 'dart:async';
import 'dart:convert';

import 'package:rxdart/rxdart.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'library_service.dart';
import 'db/track_codec.dart';

class Playlist {
  final int id;
  final String name;
  final DateTime createdAt;
  const Playlist({required this.id, required this.name, required this.createdAt});
}

/// SQLite-backed library persistence: favorites, playlists, recently played.
/// Tracks are stored as full multi-source JSON so saved items remain
/// playable from any configured provider.
class LibraryStore {
  final Database _db;

  final _favoritesSubject = BehaviorSubject<List<MergedTrack>>.seeded(const []);
  final _playlistsSubject = BehaviorSubject<List<Playlist>>.seeded(const []);
  final _recentSubject = BehaviorSubject<List<MergedTrack>>.seeded(const []);

  ValueStream<List<MergedTrack>> get favoritesStream => _favoritesSubject;
  ValueStream<List<Playlist>> get playlistsStream => _playlistsSubject;
  ValueStream<List<MergedTrack>> get recentStream => _recentSubject;

  LibraryStore(this._db);

  /// Open the app database at the default mobile/desktop path.
  static Future<LibraryStore> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'unisson_library.db'),
      version: 1,
      onCreate: _createSchema,
    );
    final store = LibraryStore(db);
    await store._loadAll();
    return store;
  }

  /// Test/desktop factory: caller supplies an already-open database.
  static Future<LibraryStore> fromDatabase(Database db) async {
    await _createSchema(db, 1);
    final store = LibraryStore(db);
    await store._loadAll();
    return store;
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS favorites (
        key TEXT PRIMARY KEY,
        track_json TEXT NOT NULL,
        added_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_items (
        playlist_id INTEGER NOT NULL,
        key TEXT NOT NULL,
        track_json TEXT NOT NULL,
        position INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, key)
      )''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recent (
        key TEXT PRIMARY KEY,
        track_json TEXT NOT NULL,
        played_at INTEGER NOT NULL
      )''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_recent_time ON recent (played_at DESC)');
  }

  Future<void> _loadAll() async {
    _favoritesSubject.add(await _queryTracks(
        'SELECT track_json FROM favorites ORDER BY added_at DESC'));
    _playlistsSubject.add(await _queryPlaylists());
    _recentSubject.add(await _queryTracks(
        'SELECT track_json FROM recent ORDER BY played_at DESC LIMIT 100'));
  }

  Future<List<MergedTrack>> _queryTracks(String sql) async {
    final rows = await _db.rawQuery(sql);
    final out = <MergedTrack>[];
    for (final r in rows) {
      try {
        out.add(mergedTrackFromJson(
            jsonDecode(r['track_json'] as String) as Map<String, dynamic>));
      } catch (_) {
        // tolerate a corrupted row rather than failing the whole list
      }
    }
    return out;
  }

  Future<List<Playlist>> _queryPlaylists() async {
    final rows = await _db.query('playlists', orderBy: 'created_at DESC');
    return rows
        .map((r) => Playlist(
              id: r['id'] as int,
              name: r['name'] as String,
              createdAt:
                  DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
            ))
        .toList();
  }

  // ---------- favorites ----------

  Future<bool> isFavorite(String key) async {
    final rows = await _db.query('favorites',
        columns: ['key'], where: 'key = ?', whereArgs: [key]);
    return rows.isNotEmpty;
  }

  /// Toggle favorite; returns the new state (true = now favorited).
  Future<bool> toggleFavorite(MergedTrack track) async {
    final key = track.universalKey;
    final exists = await isFavorite(key);
    if (exists) {
      await _db.delete('favorites', where: 'key = ?', whereArgs: [key]);
    } else {
      await _db.insert('favorites', {
        'key': key,
        'track_json': jsonEncode(mergedTrackToJson(track)),
        'added_at': DateTime.now().millisecondsSinceEpoch,
      });
    }
    _favoritesSubject.add(await _queryTracks(
        'SELECT track_json FROM favorites ORDER BY added_at DESC'));
    return !exists;
  }

  // ---------- playlists ----------

  Future<Playlist> createPlaylist(String name) async {
    final id = await _db.insert('playlists', {
      'name': name,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    _playlistsSubject.add(await _queryPlaylists());
    return Playlist(id: id, name: name, createdAt: DateTime.now());
  }

  Future<void> renamePlaylist(int id, String name) async {
    await _db.update('playlists', {'name': name},
        where: 'id = ?', whereArgs: [id]);
    _playlistsSubject.add(await _queryPlaylists());
  }

  Future<void> deletePlaylist(int id) async {
    await _db.delete('playlist_items',
        where: 'playlist_id = ?', whereArgs: [id]);
    await _db.delete('playlists', where: 'id = ?', whereArgs: [id]);
    _playlistsSubject.add(await _queryPlaylists());
  }

  /// Add a track to a playlist. Returns false if already present.
  Future<bool> addToPlaylist(int playlistId, MergedTrack track) async {
    final key = track.universalKey;
    final existing = await _db.query('playlist_items',
        columns: ['key'],
        where: 'playlist_id = ? AND key = ?',
        whereArgs: [playlistId, key]);
    if (existing.isNotEmpty) return false;
    final posRow = await _db.rawQuery(
        'SELECT MAX(position) AS m FROM playlist_items WHERE playlist_id = ?',
        [playlistId]);
    final pos = ((posRow.first['m'] as int?) ?? -1) + 1;
    await _db.insert('playlist_items', {
      'playlist_id': playlistId,
      'key': key,
      'track_json': jsonEncode(mergedTrackToJson(track)),
      'position': pos,
    });
    return true;
  }

  Future<void> removeFromPlaylist(int playlistId, String key) async {
    await _db.delete('playlist_items',
        where: 'playlist_id = ? AND key = ?', whereArgs: [playlistId, key]);
    await _resequence(playlistId);
  }

  Future<void> moveInPlaylist(int playlistId, String key, int newPosition) async {
    final items = await playlistTracks(playlistId);
    final from = items.indexWhere((t) => t.universalKey == key);
    if (from == -1) return;
    final entry = items.removeAt(from);
    items.insert(newPosition.clamp(0, items.length), entry);
    await _db.transaction((txn) async {
      for (var i = 0; i < items.length; i++) {
        await txn.update(
            'playlist_items', {'position': i},
            where: 'playlist_id = ? AND key = ?',
            whereArgs: [playlistId, items[i].universalKey]);
      }
    });
  }

  Future<void> _resequence(int playlistId) async {
    final rows = await _db.query('playlist_items',
        where: 'playlist_id = ?', whereArgs: [playlistId], orderBy: 'position');
    for (var i = 0; i < rows.length; i++) {
      await _db.update(
          'playlist_items', {'position': i},
          where: 'playlist_id = ? AND key = ?',
          whereArgs: [playlistId, rows[i]['key']]);
    }
  }

  Future<List<MergedTrack>> playlistTracks(int playlistId) async {
    final rows = await _db.query('playlist_items',
        where: 'playlist_id = ?',
        whereArgs: [playlistId],
        orderBy: 'position');
    final out = <MergedTrack>[];
    for (final r in rows) {
      try {
        out.add(mergedTrackFromJson(
            jsonDecode(r['track_json'] as String) as Map<String, dynamic>));
      } catch (_) {}
    }
    return out;
  }

  Future<int> playlistCount(int playlistId) async {
    final rows = await _db.rawQuery(
        'SELECT COUNT(*) AS c FROM playlist_items WHERE playlist_id = ?',
        [playlistId]);
    return rows.first['c'] as int;
  }

  // ---------- recently played ----------

  Future<void> addRecent(MergedTrack track) async {
    final key = track.universalKey;
    await _db.delete('recent', where: 'key = ?', whereArgs: [key]);
    await _db.insert('recent', {
      'key': key,
      'track_json': jsonEncode(mergedTrackToJson(track)),
      'played_at': DateTime.now().millisecondsSinceEpoch,
    });
    // cap at 100
    await _db.execute(
        'DELETE FROM recent WHERE key NOT IN (SELECT key FROM recent ORDER BY played_at DESC LIMIT 100)');
    _recentSubject.add(await _queryTracks(
        'SELECT track_json FROM recent ORDER BY played_at DESC LIMIT 100'));
  }

  Future<void> close() async {
    await _favoritesSubject.close();
    await _playlistsSubject.close();
    await _recentSubject.close();
    await _db.close();
  }
}
