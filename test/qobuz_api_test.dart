import 'package:flutter_test/flutter_test.dart';
import 'package:unisson/providers/qobuz/qobuz_api.dart';

void main() {
  test('QobuzTrack.fromJson maps fields', () {
    final t = QobuzTrack.fromJson({
      'id': 12345,
      'title': 'Veridis Quo',
      'duration': 346,
      'streamable': true,
      'maximum_sampling_rate': 96,
      'maximum_bit_depth': 24,
      'performer': {'name': 'Daft Punk'},
      'album': {'title': 'Discovery'},
      'image': {'large': 'https://img/large.jpg', 'medium': 'https://img/med.jpg'},
    });
    expect(t.id, '12345');
    expect(t.title, 'Veridis Quo');
    expect(t.artists, ['Daft Punk']);
    expect(t.album, 'Discovery');
    expect(t.maxSampleRate, 96);
    expect(t.maxBitDepth, 24);
    expect(t.artwork, 'https://img/large.jpg');
    expect(t.streamable, true);
  });

  test('QobuzTrack.fromJson graceful when no artist/album', () {
    final t = QobuzTrack.fromJson({
      'id': 1,
      'title': 'x',
      'streamable': false,
    });
    expect(t.artists, isEmpty);
    expect(t.album, isNull);
    expect(t.artwork, isNull);
    expect(t.streamable, false);
  });
}