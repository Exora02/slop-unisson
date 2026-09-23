import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import 'library_service.dart';
import 'library_store.dart';
import 'models.dart';
import '../providers/qobuz/qobuz_provider.dart' show QobuzProvider;
import '../providers/spotify/spotify_provider.dart' show SpotifyProvider;
import '../providers/ytm/ytm_provider.dart' show YtmProvider;
import 'queue.dart';
import 'spotify_engine.dart';
import 'stream_proxy.dart';

/// Central playback service: owns the queue, resolves streams with
/// source-fallback, drives just_audio, and feeds audio_service so
/// lock-screen / notification controls work.
class UnissonAudioHandler extends BaseAudioHandler {
  final LibraryService library;

  /// Local loopback proxy the player streams through. Intercepts CDN
  /// token deaths (403 on Qobuz mid-track) and client-identity rejections
  /// ("playback error 0" on googlevideo) — re-resolves and retries with
  /// the same Range so the player never notices.
  late final StreamProxy proxy = () {
    final p = StreamProxy();
    for (final pr in library.providers) {
      if (!pr.isConfigured) continue;
      if (pr is QobuzProvider) {
        p.registerResolver('qobuz', (trackId, hint) async {
          return await pr.resolveStreamById(trackId, hint ?? 27);
        });
      } else if (pr is YtmProvider) {
        p.registerResolver('ytm', (trackId, hint) async {
          return await pr.resolveUriById(trackId);
        });
      }
    }
    return p;
  }();

  /// Library persistence, used to write back source enrichment results.
  /// Nullable only so tests/factories without a store still work.
  final Future<LibraryStore>? storeFuture;

  /// Headless Spotify Connect device (Web Playback SDK in a 1x1
  /// WebView). Created lazily on first Spotify track. The notifier
  /// lets the widget tree mount its WebView when it appears.
  SpotifyEngine? _spotifyEngine;
  final engineNotifier = ValueNotifier<SpotifyEngine?>(null);

  /// Active Spotify playback session: track id being played + the
  /// position/ended poller that keeps the UI in sync.
  String? _spotifyTrackId;
  Timer? _spotifyPoll;
  bool _spotifyPlaying = false;
  int _spotifyPosMs = 0;
  int _spotifyDurMs = 0;

  /// Whether a Spotify Web Playback SDK session is currently active.
  bool get _spotifyActive => _spotifyTrackId != null;

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
    // proxy must be listening before the first track can load
    unawaited(proxy.start());
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
    // while "playing". Watch for that too, and for a hung load.
    _stallWatch = Timer.periodic(const Duration(seconds: 5), (_) {
      _forceUnlockIfNeeded();
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
    // Never auto-recover onto a source the user explicitly chose — if
    // that source is failing, the reload loop would just re-fail it
    // forever (and re-wedge the single-flight slot). The user decides.
    if (entry.sourceId != null) {
      _errorSubject.add(
          'Source ${entry.sourceId} failed — switch source or skip');
      return;
    }
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
  Future<void> play() async {
    if (_spotifyActive) {
      final sp = _spotify;
      if (sp != null) {
        try {
          await sp.api.resume();
          _spotifyPlaying = true;
          _broadcastSpotifyState(_spotifyPosMs, _spotifyDurMs);
        } catch (_) {}
      }
      return;
    }
    await _player.play();
  }

  @override
  Future<void> pause() async {
    if (_spotifyActive) {
      final sp = _spotify;
      if (sp != null) {
        try {
          await sp.api.pause();
          _spotifyPlaying = false;
          _broadcastSpotifyState(_spotifyPosMs, _spotifyDurMs);
          return;
        } catch (_) {}
      }
      return;
    }
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    _spotifyPoll?.cancel();
    _spotifyTrackId = null;
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_spotifyActive) {
      final sp = _spotify;
      if (sp != null) {
        try {
          await sp.api.seek(position.inMilliseconds);
          _spotifyPosMs = position.inMilliseconds;
        } catch (_) {}
      }
      return;
    }
    await _player.seek(position);
  }

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

    // ---- Spotify native path: Web Playback SDK device ----
    if (source == 'spotify') {
      final ok = await _startSpotifyPlayback(track.id, gen);
      if (ok) return;
      // fall through to error path — _startSpotifyPlayback logged it
      _lastLoadFailed = true;
      return;
    }

    // Stream through the local proxy: it re-resolves expired tokens
    // (Qobuz mid-track death) and sends the client identity the CDN
    // minted the URL for (googlevideo "playback error 0" fix).
    // Awaiting start() is cheap after the first call (memoized) and
    // guarantees a bound port before the URL is built.
    var playUri = spec.uri;
    if (source == 'ytm' || source == 'qobuz') {
      await proxy.start();
      playUri = proxy.proxyUrl(
        sourceId: source,
        trackId: track.id,
        originUrl: spec.uri,
        formatHint: source == 'qobuz' ? 27 : null,
        userAgent: spec.userAgent,
      );
    }
    mediaItem.add(_toMediaItem(entry.track, track, spec));

    _enrichInBackground(entry);

    await _applySource(playUri, autoplay: autoplay, resumeAt: resumeAt, gen: gen);
  }

  // ---------- Spotify Web Playback SDK path ----------

  SpotifyProvider? get _spotify {
    for (final p in library.providers) {
      if (p is SpotifyProvider && p.isConfigured) return p;
    }
    return null;
  }

  /// Play [trackId] on the headless Spotify Connect device. Boots the
  /// WebView engine on first use; subsequent plays are instant.
  Future<bool> _startSpotifyPlayback(String trackId, int gen) async {
    final sp = _spotify;
    if (sp == null) {
      _errorSubject.add('Spotify not connected (Premium required for '
          'native playback)');
      return false;
    }
    // stop just_audio so the two engines never play over each other
    await _player.pause();
    SpotifyEngine engine = _spotifyEngine ??= SpotifyEngine(
      loadAccessToken: () => sp.api.accessToken(),
      loadPort: () async {
        await proxy.start();
        return proxy.port;
      },
      onLog: (l) => _errorSubject.add('spotify: $l'),
    );
    engineNotifier.value = engine;
    if (!engine.isReady && !await engine.ensureBooted()) {
      _errorSubject.add('Spotify device failed to start — Premium '
          'required (or WebView blocked)');
      return false;
    }
    if (gen != _loadGen) return false; // superseded while booting
    try {
      await sp.api.playUri(engine.deviceId!, 'spotify:track:$trackId');
      _spotifyTrackId = trackId;
      _startSpotifyPoller();
      return true;
    } catch (e) {
      _errorSubject.add('Spotify play failed: $e');
      return false;
    }
  }

  /// Poll the Web API for position/ended while a Spotify track plays —
  /// just_audio knows nothing about this session, so the UI syncs
  /// through here.
  void _startSpotifyPoller() {
    _spotifyPoll?.cancel();
    _spotifyTrackId = _queue.current?.track.sources['spotify']?.id ??
        _spotifyTrackId;
    _spotifyPoll = Timer.periodic(const Duration(seconds: 2), (t) async {
      final sp = _spotify;
      final tid = _spotifyTrackId;
      if (sp == null || tid == null) {
        t.cancel();
        return;
      }
      try {
        final st = await sp.api.getPlaybackState();
        if (st == null) return;
        final pos = ((st['progress_ms'] as num?) ?? 0).toInt();
        final item = st['item'] as Map<String, dynamic>?;
        final dur = item != null
            ? ((item['duration_ms'] as num?) ?? 0).toInt()
            : 0;
        final playing = st['is_playing'] == true;
        _spotifyPosMs = pos;
        _spotifyPlaying = playing;
        _broadcastSpotifyState(pos, dur);
        if (dur > 0 && pos >= dur - 1500) {
          t.cancel();
          _onSpotifyEnded();
        }
      } catch (_) {}
    });
  }

  void _onSpotifyEnded() {
    _spotifyTrackId = null;
    if (_queue.advance()) {
      _broadcastQueue();
      _loadCurrent(autoplay: true);
    }
  }

  void _broadcastSpotifyState(int posMs, int durMs) {
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (_spotifyPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      updatePosition: Duration(milliseconds: posMs),
      bufferedPosition: Duration(milliseconds: posMs),
      playing: _spotifyPlaying,
    ));
    if (durMs > 0 && _spotifyDurMs != durMs) {
      _spotifyDurMs = durMs;
      final cur = mediaItem.value;
      if (cur != null) {
        mediaItem.add(cur.copyWith(
            duration: Duration(milliseconds: durMs)));
      }
    }
  }

  /// Single-flight around just_audio's setAudioSource. Overlapping calls here
  /// deadlock the platform channel and make every control look dead. At
  /// most one apply runs; a request that lands mid-apply REPLACES the
  /// pending slot — the newest track always wins. If setAudioSource
  /// itself hangs (dead/expired URL that never times out internally),
  /// the watchdog force-unlocks the slot so the queue keeps moving.
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

  DateTime? _applyDeadline;
  int _applyGen = -1;

  Future<void> _runApply(
    Uri uri, {
    required bool autoplay,
    Duration? resumeAt,
    required int gen,
  }) async {
    _loading = true;
    _applyGen = gen;
    _applyDeadline = DateTime.now().add(const Duration(seconds: 45));
    try {
      // Spotify marker specs never reach just_audio — the Web Playback
      // SDK path handles those before we get here. Belt and suspenders.
      if (uri.scheme == 'spotify') {
        _lastApplyError = 'spotify marker reached just_audio';
        _errorSubject.add(_lastApplyError!);
        return;
      }
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
      // Only release the slot if THIS apply is still the current one —
      // a force-unlock by the watchdog must not be overwritten.
      if (_applyGen == gen) {
        _loading = false;
        _applyDeadline = null;
      }
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

  /// Watchdog: a hung setAudioSource (dead URL, no internal timeout)
  /// wedges the single-flight slot forever AND the player — every skip
  /// then queues behind it (only a manual pause/stop freed it). Force:
  /// stop() the player (aborts the hung load so its finally runs) and
  /// release the slot so the next load proceeds immediately.
  void _forceUnlockIfNeeded() {
    if (!_loading) return;
    final dl = _applyDeadline;
    if (dl != null && DateTime.now().isAfter(dl)) {
      _loading = false;
      _applyDeadline = null;
      _pendingLoad = true;
      _pendingUri = null;
      unawaited(_player.stop());
      _errorSubject.add('Playback stalled — recovering');
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
      // YTM-specific auto-diagnosis: the phone diag showed IOS direct
      // fetch works while proxy leg was never measured. When ytm fails
      // to resolve AND the user is logged in, run a direct byte-fetch
      // verdict so the banner carries real data instead of a guess.
      if (order.contains('ytm') && entry.track.sources.containsKey('ytm')) {
        unawaited(_diagnoseYtmInline(entry));
      }
      // Last-chance synchronous enrichment: freshly imported single-
      // source tracks (e.g. Spotify import) have no playable source
      // yet. Search the other providers NOW (not just background) and
      // retry the ladder with whatever lands.
      final spec2 = await _enrichAndRetry(entry, gen);
      if (spec2 != null) return spec2;
      _errorSubject.add(attempts.isEmpty
          ? 'Could not play "${entry.track.title}" — track has no sources'
          : 'Could not play "${entry.track.title}" — ${attempts.join(' | ')}');
    }
    return null;
  }

  /// Synchronous enrichment for a track that just failed to resolve:
  /// search every configured provider the track lacks, merge exact
  /// matches, persist, and re-run the resolve ladder once.
  Future<StreamSpec?> _enrichAndRetry(QueueEntry entry, int gen) async {
    if (entry.track.sources.isEmpty) return null;
    final key = entry.track.universalKey;
    final found = <String, Track>{};
    final query =
        '${entry.track.title} ${entry.track.artists.join(' ')}'.trim();
    for (final p in library.providers) {
      if (gen != _loadGen) return null;
      if (!p.isConfigured) continue;
      if (entry.track.sources.containsKey(p.id)) continue;
      try {
        final results =
            await p.search(query).timeout(const Duration(seconds: 12));
        for (final t in results.tracks) {
          if (_keyOf(t) == key) {
            found[p.id] = t;
            break;
          }
        }
      } catch (_) {}
    }
    if (found.isEmpty) return null;
    entry.track.sources.addAll(found);
    _broadcastQueue();
    storeFuture?.then(
        (s) => s.enrichTrack(entry.track.universalKey, found));
    return await _resolveWithFallback(entry, gen);
  }

  /// Inline YTM verdict on load failure: runs the provider's on-device
  /// diagnostics and surfaces the first useful line in the error
  /// banner, so failures carry data instead of "error 0".
  Future<void> _diagnoseYtmInline(QueueEntry entry) async {
    try {
      final ytm = library.providers
          .whereType<YtmProvider>()
          .firstWhere((p) => p.isConfigured);
      final lines = await ytm.diagnose()
          .timeout(const Duration(seconds: 90));
      final verdict = lines
          .where((l) =>
              l.contains('resolved itag') || l.contains('failed'))
          .join(' || ');
      if (verdict.isNotEmpty) {
        _errorSubject.add('YTM diag: $verdict');
      }
    } catch (_) {}
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
