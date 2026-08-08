import 'package:just_audio/just_audio.dart';

import '../core/models.dart';

enum PlayerState { idle, loading, playing, paused, error }

class PlayerService {
  final _player = AudioPlayer();

  Track? current;
  StreamSpec? currentSpec;

  Stream<Duration> get position => _player.positionStream;
  Stream<Duration?> get duration => _player.durationStream;

  Future<void> play(Track track, StreamSpec spec) async {
    current = track;
    currentSpec = spec;
    await _player.setUrl(spec.uri.toString());
    await _player.play();
  }

  Future<void> toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> seek(Duration d) => _player.seek(d);

  bool get playing => _player.playing;

  void dispose() {
    _player.dispose();
  }
}
