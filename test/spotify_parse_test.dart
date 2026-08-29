import 'package:flutter_test/flutter_test.dart';
import 'package:unisson/providers/spotify/spotify_api.dart';

void main() {
  test('spotify track parse tolerates double duration_ms and reads isrc', () {
    final t = spotifyTrackFromJson({
      'id': 'abc',
      'name': 'Veridis Quo',
      'artists': [
        {'name': 'Daft Punk'}
      ],
      'album': {
        'name': 'Discovery',
        'images': [
          {'url': 'https://i.scdn.co/image/x'},
          {'url': 'https://i.scdn.co/image/y'}
        ],
      },
      'duration_ms': 221000.0,
      'external_ids': {'isrc': 'GBDUW0000053'},
    });
    expect(t.id, 'abc');
    expect(t.durationMs, 221000);
    expect(t.isrc, 'GBDUW0000053');
    expect(t.artwork, 'https://i.scdn.co/image/x');
    expect(t.artists, ['Daft Punk']);
  });

  test('spotify track parse survives missing fields', () {
    final t = spotifyTrackFromJson({'id': 'x', 'name': 'Bare'});
    expect(t.durationMs, isNull);
    expect(t.isrc, isNull);
    expect(t.artwork, isNull);
    expect(t.artists, isEmpty);
  });
}
