import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import 'library_service.dart';
import 'library_store.dart';
import 'models.dart';
import 'queue.dart';

/// Central playback service: owns the queue, resolves streams with
/// source-fallback, drives just_audio, and feeds audio_service so
/// lock-screen / notification controls work.
class UnissonAudioHandler extends BaseAudioHandler {
  final LibraryService library;

  /// Library persistence, used to write back source enrichment results.
  /// Nullable only so tests/factories without a store still work.
  final Future<LibraryStore>? storeFuture;

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

  /// The entry currently loaded/playing (for the player UI).
  Stream<QueueEntry?> get currentEntryStream => Rx.combineLatest2(
      queueStream,
      indexStream,
      (List<QueueEntry> q, int i) =>
          i >= 0 && i < q.length ? q[i] : null);

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

  /// Does the given source offer meaningfully different quality tiers
  /// (hi-res vs CD vs lossy)? Single-format sources don't.
  bool hasQualityTiers(String sourceId) {
    final matches = library.providers.where((p) => p.id == sourceId);
    return matches.isNotEmpty && matches.first.hasQualityTiers;
  }

  /// Monotonic guard: every load bumps it; a load whose generation is no
  /// longer current after an await was superseded (fast skip taps) and must
  /// abandon its result instead of clobbering the newer track.
  int _loadGen = 0;

  /// just_audio cannot run two setAudioSource calls concurrently — they
  /// deadlock on the platform channel and every control looks dead until a
  /// later tap happens to get through. Serialize loads: at most one runs;
  /// a request that arrives mid-load is coalesced (the restart picks up the
  /// latest queue state) and the running load is interrupted via stop().
  bool _loading = false;
  bool _pendingLoad = false;
  bool _pendingAutoplay = true;
  Uri? _pendingUri;
  Duration? _pendingResume;

  /// Last playback error from just_audio's load step, cleared on
  /// success. switchSource consults it to revert a failed switch.
  String? _lastApplyError;

  /// True when the most recent _loadCurrent could not resolve a stream.
  bool _lastLoadFailed = false;

  /// Last position where playback was actually advancing — the resume
  /// point when a stream dies mid-track (Qobuz URLs expire after a
  /// while and the player just stalls).
  Duration _lastGoodPosition = Duration.zero;
  DateTime _lastPositionAdvance = DateTime.now();
  DateTime _lastRecovery = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _stallWatch;

  /// Position ticks fire ~4x/s; only broadcast playback state to the
  /// platform channel once per second (event-driven broadcasts stay
  /// immediate). Constant churn here made the UI feel laggy.
  DateTime _lastPosBroadcast = DateTime.fromMillisecondsSinceEpoch(0);

  UnissonAudioHandler({required this.library, this.storeFuture}) {
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
    _player.positionStream.listen((p) {
      if (p > _lastGoodPosition + const Duration(milliseconds: 200)) {
        _lastGoodPosition = p;
        _lastPositionAdvance = DateTime.now();
      }
      final now = DateTime.now();
      if (now.difference(_lastPosBroadcast).inMilliseconds >= 1000) {
        _lastPosBroadcast = now;
        _broadcastState();
      }
    });
    _player.durationStream.listen((_) => _broadcastState());

    // A stream that dies mid-track (expired URL, network drop) surfaces
    // here. Reload the current entry at the last good position with a
    // freshly resolved URL instead of leaving the player dead.
    _player.errorStream.listen((e) {
      _errorSubject.add('Player error: $e');
      _recoverPlayback();
    });
    // Some failures never raise an error — the position just freezes
    // while "playing". Watch for that too.
    _stallWatch = Timer.periodic(const Duration(seconds: 5), (_) {
      final stalled = _player.playing &&
          DateTime.now().difference(_lastPositionAdvance) >
              const Duration(seconds: 20);
      if (stalled) _recoverPlayback();
    });
  }

  /// Reload the current track from a fresh URL at the last advancing
  /// position. Rate-limited so a hard-failing source cannot loop this.
  Future<void> _recoverPlayback() async {
    final entry = _queue.current;
    if (entry == null) return;
    if (DateTime.now().difference(_lastRecovery) <
        const Duration(seconds: 30)) {
      return;
    }
    _lastRecovery = DateTime.now();
    final resume = _lastGoodPosition;
    _lastPositionAdvance = DateTime.now();
    await _loadCurrent(
      autoplay: true,
      resumeAt: resume > const Duration(seconds: 1) ? resume : null,
    );
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

  /// Change the current track's source (and optionally quality) and reload.
  /// Keeps the playback position so switching doesn't restart the song.
  /// An explicit switch is a statement of intent: it must NOT silently
  /// fall back to another source. If the chosen source fails, the
  /// previous source is restored and the reason is surfaced.
  Future<void> switchSource(String sourceId, {QualityPref? qualityPref}) async {
    final entry = _queue.current;
    if (entry == null) return;
    final wasPlaying = _player.playing;
    final pos = _player.position;
    final prevSource = entry.sourceId;
    final prevQuality = entry.qualityOverride;
    entry.sourceId = sourceId;
    if (qualityPref != null) entry.qualityOverride = qualityPref;
    _broadcastQueue();
    await _loadCurrent(
      autoplay: wasPlaying,
      resumeAt: pos > Duration.zero ? pos : null,
      explicitSource: true,
    );
    // The switch did not actually take — restore what was playing.
    if (_lastLoadFailed || _lastApplyError != null) {
      entry.sourceId = prevSource;
      entry.qualityOverride = prevQuality;
      _broadcastQueue();
      _lastLoadFailed = false;
      _lastApplyError = null;
      await _loadCurrent(
        autoplay: wasPlaying,
        resumeAt: pos > Duration.zero ? pos : null,
      );
    }
  }

  Future<void> _loadCurrent(
      {required bool autoplay, Duration? resumeAt, bool explicitSource = false}) async {
    final entry = _queue.current;
    if (entry == null) return;

    final gen = ++_loadGen;
    _lastApplyError = null;
    _lastLoadFailed = false;

    final spec =
        await _resolveWithFallback(entry, gen, explicit: explicitSource);
    if (gen != _loadGen) return; // superseded by a newer skip/load

    if (spec == null) {
      _lastLoadFailed = true;
      return; // _resolveWithFallback emitted the reason
    }

    final source = entry.sourceId ?? entry.track.bestSourceId;
    final track = entry.track.sources[source] ?? entry.track.sources.values.first;
    // Sources that only ship artwork with the stream (Qobuz getFileUrl)
    // fill it in here so saved copies gain covers over time.
    if (entry.track.artwork == null && spec.artwork != null) {
      entry.track.artwork = spec.artwork;
    }
    if (entry.track.album == null && spec.album != null) {
      entry.track.album = spec.album;
      _broadcastQueue();
    }
    if (spec.artwork != null || spec.album != null) {
      storeFuture?.then((s) => s.updateTrackMeta(entry.track.universalKey,
          artwork: spec.artwork, album: spec.album));
    }
    mediaItem.add(_toMediaItem(entry.track, track, spec));

    _enrichInBackground(entry);

    await _applySource(spec.uri, autoplay: autoplay, resumeAt: resumeAt, gen: gen);
  }

  /// Single-flight around just_audio's setAudioSource. Overlapping calls here
  /// deadlock the platform channel and make every control look dead. At
  /// most one apply runs; a request that lands mid-apply REPLACES the
  /// pending slot — the newest track wins, so the audio can never be
  /// left on a superseded track while the UI shows the new one.
  Future<void> _applySource(
    Uri uri, {
    required bool autoplay,
    Duration? resumeAt,
    required int gen,
  }) async {
    _pendingAutoplay = autoplay;
    if (_loading) {
      _pendingLoad = true;
      _pendingUri = uri;
      _pendingResume = resumeAt;
      return;
    }
    await _runApply(uri, autoplay: autoplay, resumeAt: resumeAt, gen: gen);
  }

  Future<void> _runApply(
    Uri uri, {
    required bool autoplay,
    Duration? resumeAt,
    required int gen,
  }) async {
    _loading = true;
    try {
      if (gen != _loadGen) return;
      await _player.setAudioSource(
        AudioSource.uri(uri),
        preload: true,
        initialPosition: resumeAt,
      );
      if (gen != _loadGen) return;
      _lastApplyError = null;
      _lastGoodPosition = resumeAt ?? Duration.zero;
      _lastPositionAdvance = DateTime.now();
      if (autoplay) await _player.play();
    } catch (e) {
      if (gen == _loadGen) {
        _lastApplyError = 'Playback error: $e';
        _errorSubject.add(_lastApplyError!);
      }
    } finally {
      _loading = false;
      if (_pendingLoad) {
        _pendingLoad = false;
        final u = _pendingUri;
        final r = _pendingResume;
        _pendingUri = null;
        _pendingResume = null;
        if (u != null) {
          await _runApply(u, autoplay: _pendingAutoplay, resumeAt: r, gen: _loadGen);
        }
      }
    }
  }

  /// Try the preferred source first, then every other available source in
  /// priority order. Returns the first stream that resolves. Aborts early if
  /// a newer load has superseded this one, so a stuck source can't hang the
  /// whole chain. On total failure, emits a diagnostic saying WHY.
  /// [explicit]: the user asked for THIS source (source switcher) —
  /// no fallback walk, the failure must be reported, not papered over.
  Future<StreamSpec?> _resolveWithFallback(QueueEntry entry, int gen,
      {bool explicit = false}) async {
    final preferred = entry.sourceId ?? entry.track.bestSourceId;
    final order = <String>[
      preferred,
      if (!explicit)
        for (final id in const ['local', 'qobuz', 'ytm', 'tidal', 'spotify'])
          if (id != preferred && entry.track.sources.containsKey(id)) id,
    ];
    final pref = entry.qualityOverride ?? quality;
    final attempts = <String>[];

    for (final sourceId in order) {
      if (gen != _loadGen) return null; // superseded — stop trying
      final track = entry.track.sources[sourceId];
      if (track == null) continue;
      final matches = library.providers
          .where((p) => p.id == sourceId && p.isConfigured);
      final provider = matches.isEmpty ? null : matches.first;
      if (provider == null) {
        attempts.add('$sourceId: not configured');
        continue;
      }
      try {
        // Keep this above the slowest provider's internal budget (YTM's
        // ladder allows up to 20s per client call); snappiness comes from
        // the generation interrupt, not from starving slow resolves.
        return await provider
            .resolveStream(track, pref)
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        attempts.add('$sourceId: timed out');
      } catch (e) {
        attempts.add('$sourceId: $e');
      }
    }
    if (gen == _loadGen) {
      _errorSubject.add(attempts.isEmpty
          ? 'Could not play "${entry.track.title}" — track has no sources'
          : 'Could not play "${entry.track.title}" — ${attempts.join(' | ')}');
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

  // ---------- source enrichment ----------

  /// Keys currently being enriched (one search pass per track, ever).
  final _enriching = <String>{};

  /// Imported/saved tracks are often stored single-source (a YTM import has
  /// no Qobuz entry even when the song exists there). When such a track
  /// plays, search the other configured providers in the background and
  /// merge any exact-key match into the queue entry AND the store, so the
  /// source chip/switcher grows over time without a re-import.
  /// Fire-and-forget: never delays playback.
  void _enrichInBackground(QueueEntry entry) {
    final storeF = storeFuture;
    if (storeF == null) return;
    if (entry.track.sources.length >= 2) return;
    final key = entry.track.universalKey;
    if (_enriching.contains(key)) return;
    _enriching.add(key);
    () async {
      try {
        final found = <String, Track>{};
        final query =
            '${entry.track.title} ${entry.track.artists.join(' ')}'.trim();
        for (final p in library.providers) {
          if (!p.isConfigured) continue;
          if (entry.track.sources.containsKey(p.id)) continue;
          try {
            final results =
                await p.search(query).timeout(const Duration(seconds: 10));
            for (final t in results.tracks.take(5)) {
              if (_keyOf(t) == key) {
                found[p.id] = t;
                break;
              }
            }
          } catch (_) {
            // one provider's failure must not block the others
          }
        }
        if (found.isNotEmpty) {
          entry.track.sources.addAll(found);
          _broadcastQueue();
          final store = await storeF;
          await store.enrichTrack(key, found);
        }
      } catch (_) {}
    }();
  }

  String _keyOf(Track t) {
    final title = t.title.trim().toLowerCase();
    final artist =
        t.artists.isNotEmpty ? t.artists.first.trim().toLowerCase() : '';
    return '$title|$artist';
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
      extras: {
        'sourceId': source.providerId,
        if (spec.bitrate != null) 'bitrate': spec.bitrate,
        if (spec.sampleRate != null) 'sampleRate': spec.sampleRate,
        if (spec.bitDepth != null) 'bitDepth': spec.bitDepth,
      },
    );
  }

  Future<void> dispose() async {
    _stallWatch?.cancel();
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
  static Future<LibraryStore>? _store;

  static void prepare(LibraryService library, Future<LibraryStore> store) {
    _library = library;
    _store = store;
  }

  static UnissonAudioHandler build() {
    final lib = _library;
    if (lib == null) {
      throw StateError(
          'UnissonAudioHandlerFactory.prepare() must be called before start');
    }
    return UnissonAudioHandler(library: lib, storeFuture: _store);
  }
}
