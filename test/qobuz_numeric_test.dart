import 'package:flutter_test/flutter_test.dart';
import 'package:unisson/providers/qobuz/qobuz_api.dart';

void main() {
  test('QobuzTrack.fromJson accepts double-typed numeric fields', () {
    // Qobuz commonly returns duration/sample_rate/bit_depth as doubles in JSON.
    final t = QobuzTrack.fromJson({
      'id': 12345,
      'title': 'Veridis Quo',
      'duration': 346.0,
      'maximum_sampling_rate': 96.0,
      'maximum_bit_depth': 24.0,
      'streamable': true,
      'performer': {'name': 'Daft Punk'},
      'album': {'title': 'Discovery'},
    });
    expect(t.duration, 346);
    expect(t.maxSampleRate, 96);
    expect(t.maxBitDepth, 24);
  });

  test('QobuzTrack.fromJson accepts int-typed numeric fields too', () {
    final t = QobuzTrack.fromJson({
      'id': 9,
      'title': 'x',
      'duration': 200,
      'maximum_sampling_rate': 192,
      'maximum_bit_depth': 24,
      'streamable': true,
    });
    expect(t.duration, 200);
    expect(t.maxSampleRate, 192);
    expect(t.maxBitDepth, 24);
  });

  test('QobuzTrack.fromJson tolerates missing numeric fields', () {
    final t = QobuzTrack.fromJson({'id': 1, 'title': 'x', 'streamable': false});
    expect(t.duration, isNull);
    expect(t.maxSampleRate, isNull);
    expect(t.maxBitDepth, isNull);
    expect(t.streamable, false);
  });
}