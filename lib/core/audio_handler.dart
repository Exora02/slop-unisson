import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import 'library_service.dart';
import 'models.dart';
import 'provider.dart';
import 'queue.dart';

/// Central playback service: owns the queue, resolves streams with
/// source-fallback, drives just_audio, and feeds audio_service so
/// lock-screen / notification controls work.
class UnissonAudioHandler extends BaseAudioHandler {
  final LibraryService library;
  final _player = AudioPlayer();
  final _queue = UnissonQueue();

  QualityPref quality = QualityPref.highest;

  final _queueSubject = BehaviorSubject<List<QueueEntry>>.seeded(const []);
  final _indexSubject = BehaviorSubject<int>.seeded(-1);
  final _repeatSubject = BehaviorSubject<RepeatMode>.seeded(RepeatMode.none);
  final _shuffleSubject = BehaviorSubject<bool>.seeded(false);
  final _errorSubject = PublishSubject<String>();

  Stream<List<QueueEntry>> get queueStream => _queueSubject.stream;
  Stream<int> get indexStream => _indexSubject.stream;
  Stream<RepeatMode> get repeatStream => _repeatSubject.stream;
  Stream<bool> get shuffleStream => _shuffleSubject.stream;
  Stream<String> get errorStream => _errorSubject.stream;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  Stream<PlayerStatus> get statusStream => _player.playerStateStream
      .map((s) => switch (s.processingState) {
            ProcessingState.loading ||
            ProcessingState.buffering =>
              PlayerStatus.loading,
            ProcessingState.ready =>
              s.playing ? PlayerStatus.playing : PlayerStatus.paused,
            ProcessingState.completed => PlayerStatus.completed,
            _ => PlayerStatus.idle,
          });

  UnissonQueue get unissonQueue => _queue;

  UnissonAudioHandler({required this.library}) {
    _init();
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        pause();
      } else if (event.type == AudioInterruptionType.pause) {
        play();
      }
    });

    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _onTrackCompleted();
      }
      _broadcastState();
    });
    _player.playingStream.listen((_) => _broadcastState());
    _player.positionStream.listen((_) => _broadcastState());
    _player.durationStream.listen((_) => _broadcastState());
  }

  // ---------- queue operations ----------

  /// Replace the queue and start playing [startIndex].
  Future<void> playQueue(List<QueueEntry> entries, {int startIndex = 0}) async {
    _queue.replaceAll(entries, startIndex: startIndex);
    _broadcastQueue();
    await _loadCurrent(autoplay: true);
  }

  Future<void> playNext(QueueEntry e) async {
    _queue.insertNext(e);
    _broadcastQueue();
  }

  Future<void> addToQueue(QueueEntry e) async {
    _queue.add(e);
    _broadcastQueue();
  }

  Future<void> removeFromQueue(int index) async {
    final wasCurrent = index == _queue.currentIndex;
    _queue.removeAt(index);
    _broadcastQueue();
    if (wasCurrent && _queue.hasCurrent) {
      await _loadCurrent(autoplay: _player.playing);
    }
  }

  Future<void> moveInQueue(int from, int to) async {
    _queue.move(from, to);
    _broadcastQueue();
  }

  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue.replaceAll(_queue.entries, startIndex: index);
    _broadcastQueue();
    await _loadCurrent(autoplay: true);
  }

  Future<void> toggleShuffle() async {
    _queue.toggleShuffle();
    _shuffleSubject.add(_queue.shuffled);
    setShuffleMode(_queue.shuffled
        ? AudioServiceShuffleMode.all
        : AudioServiceShuffleMode.none);
  }

  Future<void> cycleRepeatMode() async {
    _queue.repeatMode = switch (_queue.repeatMode) {
      RepeatMode.none => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.none,
    };
    _repeatSubject.add(_queue.repeatMode);
    setRepeatMode(switch (_queue.repeatMode) {
      RepeatMode.none => AudioServiceRepeatMode.none,
      RepeatMode.all => AudioServiceRepeatMode.all,
      RepeatMode.one => AudioServiceRepeatMode.one,
    });
    _player.setLoopMode(_queue.repeatMode == RepeatMode.one
        ? LoopMode.one
        : LoopMode.off);
  }

  // ---------- BaseAudioHandler media controls ----------

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_queue.advance()) {
      _broadcastQueue();
      await _loadCurrent(autoplay: true);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    // restart the track if more than 3s in, like most players
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_queue.goBack()) {
      _broadcastQueue();
      await _loadCurrent(autoplay: true);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await super.setShuffleMode(shuffleMode);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await super.setRepeatMode(repeatMode);
  }

  // ---------- resolution + loading ----------

  Future<void> _loadCurrent({required bool autoplay}) async {
    final entry = _queue.current;
    if (entry == null) return;

    final spec = await _resolveWithFallback(entry);
    if (spec == null) {
      _errorSubject.add(
          'Could not play "${entry.track.title}" from any source');
      return;
    }

    final source = entry.sourceId ?? entry.track.bestSourceId;
    final track = entry.track.sources[source] ?? entry.track.sources.values.first;
    mediaItem.add(_toMediaItem(entry.track, track, spec));

    try {
      await _player.setAudioSource(
        AudioSource.uri(spec.uri),
        preload: true,
      );
      if (autoplay) await _player.play();
    } catch (e) {
      _errorSubject.add('Playback error: $e');
    }
  }

  /// Try the preferred source first, then every other available source in
  /// priority order. Returns the first stream that resolves.
  Future<StreamSpec?> _resolveWithFallback(QueueEntry entry) async {
    final preferred = entry.sourceId ?? entry.track.bestSourceId;
    final order = <String>[
      preferred,
      for (final id in const ['local', 'qobuz', 'ytm', 'tidal', 'spotify'])
        if (id != preferred && entry.track.sources.containsKey(id)) id,
    ];

    String? lastError;
    for (final sourceId in order) {
      final track = entry.track.sources[sourceId];
      if (track == null) continue;
      final matches = library.providers
          .where((p) => p.id == sourceId && p.isConfigured);
      final provider = matches.isEmpty ? null : matches.first;
      if (provider == null) continue;
      try {
        return await provider
            .resolveStream(track, quality)
            .timeout(const Duration(seconds: 20));
      } catch (e) {
        lastError = '$sourceId: $e';
      }
    }
    if (lastError != null) {
      _errorSubject.add('Resolve failed — $lastError');
    }
    return null;
  }

  void _onTrackCompleted() {
    if (_queue.repeatMode == RepeatMode.one) return; // just_audio loops it
    if (_queue.advance()) {
      _broadcastQueue();
      _loadCurrent(autoplay: true);
    }
  }

  // ---------- state broadcast ----------

  void _broadcastQueue() {
    _queueSubject.add(List.unmodifiable(_queue.entries));
    _indexSubject.add(_queue.currentIndex);
  }

  void _broadcastState() {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.setRepeatMode},
      androidCompactActionIndices: const [0, 1, 3],
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _queue.currentIndex,
    ));
  }

  MediaItem _toMediaItem(MergedTrack merged, Track source, StreamSpec spec) {
    return MediaItem(
      id: '${source.providerId}:${source.id}',
      title: merged.title,
      artist: merged.artists.join(', '),
      album: merged.album,
      artUri: merged.artwork != null ? Uri.parse(merged.artwork!) : null,
      duration: spec.expiresAt != null ? null : (source.duration ?? merged.duration),
      extras: {'sourceId': source.providerId},
    );
  }

  Future<void> dispose() async {
    await _player.dispose();
    await _queueSubject.close();
    await _indexSubject.close();
    await _repeatSubject.close();
    await _shuffleSubject.close();
    await _errorSubject.close();
  }
}

enum PlayerStatus { idle, loading, playing, paused, completed }

/// Factory for AudioService.start — builds the handler with the given
/// library. Called once per app lifetime.
class UnissonAudioHandlerFactory {
  static LibraryService? _library;

  static void prepare(LibraryService library) => _library = library;

  static UnissonAudioHandler build() {
    final lib = _library;
    if (lib == null) {
      throw StateError(
          'UnissonAudioHandlerFactory.prepare() must be called before start');
    }
    return UnissonAudioHandler(library: lib);
  }
}
