import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models.dart';
import '../../core/provider.dart';
import 'tag_reader.dart';

const _audioExts = {'mp3', 'flac', 'm4a', 'aac', 'ogg', 'wav', 'opus'};

class LocalProvider implements MusicProvider {
  final List<Directory> _roots;
  bool _scanned = false;
  final _tracks = <Track>[];

  LocalProvider(this._roots);

  @override
  String get id => 'local';

  @override
  bool get isConfigured => _roots.isNotEmpty;

  void dispose() {
    _tracks.clear();
    _scanned = false;
  }

  Future<void> scan() async {
    if (_scanned) return;
    _tracks.clear();
    for (final root in _roots) {
      await _scanDir(root);
    }
    _scanned = true;
  }

  Future<void> _scanDir(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          await _scanDir(entity);
        } else if (entity is File) {
          final ext = p.extension(entity.path).replaceFirst('.', '').toLowerCase();
          if (_audioExts.contains(ext)) {
            final t = await _readTrack(entity);
            if (t != null) _tracks.add(t);
          }
        }
      }
    } catch (_) {
      // skip unreadable subdirs
    }
  }

  Future<Track?> _readTrack(File file) async {
    try {
      final tags = await TagReader.read(file.path);
      final title = tags.title?.trim().isNotEmpty == true
          ? tags.title!.trim()
          : p.basenameWithoutExtension(file.path);
      final artists = tags.artist == null
          ? <String>[]
          : tags.artist!
              .split('/')
              .expand((a) => a.split(','))
              .map((a) => a.trim())
              .where((a) => a.isNotEmpty)
              .toList();
      return Track(
        providerId: id,
        id: 'file:${file.path}',
        title: title,
        artists: artists,
        album: tags.album?.trim().isNotEmpty == true ? tags.album : null,
        duration: tags.duration,
        artwork: null,
      );
    } catch (_) {
      return Track(
        providerId: id,
        id: 'file:${file.path}',
        title: p.basenameWithoutExtension(file.path),
        artists: const [],
        duration: null,
      );
    }
  }

  @override
  Future<SearchResults> search(String query) async {
    await scan();
    final q = query.toLowerCase();
    final matches = _tracks.where((t) {
      final haystack = '${t.title} ${t.artists.join(' ')} ${t.album ?? ''}'
          .toLowerCase();
      return haystack.contains(q);
    }).toList();
    return SearchResults(tracks: matches);
  }

  @override
  Future<StreamSpec> resolveStream(Track track, QualityPref pref) async {
    if (!track.id.startsWith('file:')) {
      throw StateError('local resolveStream called on non-file track');
    }
    final path = track.id.substring('file:'.length);
    return StreamSpec(
      uri: File(path).uri,
      contentType: _contentTypeFor(p.extension(path)),
      sampleRate: null,
      bitDepth: null,
    );
  }

  String _contentTypeFor(String ext) {
    switch (ext.toLowerCase()) {
      case '.flac':
        return 'audio/flac';
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
        return 'audio/mp4';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.wav':
        return 'audio/wav';
      case '.aac':
        return 'audio/aac';
      default:
        return 'application/octet-stream';
    }
  }
}