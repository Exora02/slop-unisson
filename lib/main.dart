import 'dart:io' show Directory;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'core/audio_handler.dart';
import 'core/models.dart';
import 'core/provider.dart';
import 'core/import_service.dart';
import 'core/library_service.dart';
import 'core/library_store.dart';
import 'core/queue.dart';
import 'providers/local/local_provider.dart';
import 'providers/qobuz/qobuz_provider.dart';
import 'providers/qobuz/qobuz_login_screen.dart';
import 'providers/ytm/ytm_provider.dart';
import 'providers/ytm/ytm_login_screen.dart';
import 'ui/import_sheet.dart';
import 'ui/library_screen.dart';
import 'ui/mini_player.dart';

const appBuildTag = 'v0.4.7-ladder';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UnissonApp());
}

class UnissonApp extends StatefulWidget {
  const UnissonApp({super.key});

  @override
  State<UnissonApp> createState() => _UnissonAppState();
}

class _UnissonAppState extends State<UnissonApp> {
  final List<String> _crashes = [];

  @override
  void initState() {
    super.initState();
    // Global net: ANY uncaught error (widget build, async, platform) gets
    // shown on screen with its stack trace so we can see file:line.
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _record('${details.exception}\n${details.stack.toString().split('\n').take(6).join('\n')}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _record('$error\n${stack.toString().split('\n').take(6).join('\n')}');
      return true;
    };
  }

  void _record(String msg) {
    if (!mounted) return;
    setState(() {
      _crashes.insert(0, msg);
      if (_crashes.length > 3) _crashes.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unisson',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFEC8603),
        useMaterial3: true,
      ),
      home: HomeScreen(crashes: _crashes),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final List<String> crashes;
  const HomeScreen({super.key, required this.crashes});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final List<MusicProvider> _providers;
  late final LibraryService _library;
  final _controller = TextEditingController();
  final _localRoot = 'PATH_TO_LOCAL_MUSIC_ROOT'; // user-configurable later
  final _secure = const FlutterSecureStorage();

  late final YtmProvider _ytm;
  late final LocalProvider? _local;
  late final QobuzProvider _qobuz;
  late final Future<UnissonAudioHandler> _handlerFuture;
  late final Future<LibraryStore> _storeFuture;

  List<MergedTrack> _results = [];
  bool _searching = false;
  String? _error;
  String? _playingSource;
  QualityPref _quality = QualityPref.highest;

  @override
  void initState() {
    super.initState();
    _ytm = YtmProvider(
      loadCookie: () => _secure.read(key: 'ytm_cookie'),
      saveCookie: (c) => _secure.write(key: 'ytm_cookie', value: c),
      clearCookie: () => _secure.delete(key: 'ytm_cookie'),
    );
    _ytm.restoreSession();
    _local = _localRoot == 'PATH_TO_LOCAL_MUSIC_ROOT'
        ? null
        : LocalProvider([Directory(_localRoot)]);
    _qobuz = QobuzProvider(
      loadToken: () => _secure.read(key: 'qobuz_token'),
      saveToken: (t) => _secure.write(key: 'qobuz_token', value: t),
      clearToken: () => _secure.delete(key: 'qobuz_token'),
    );
    _qobuz.restoreSession();
    _providers = [
      if (_local != null) _local,
      _qobuz,
      _ytm,
    ];
    _library = LibraryService(_providers);
    _storeFuture = LibraryStore.open();
    _handlerFuture = _startAudioService();
  }

  Future<UnissonAudioHandler> _startAudioService() async {
    UnissonAudioHandlerFactory.prepare(_library, _storeFuture);
    final handler = await AudioService.init(
      builder: UnissonAudioHandlerFactory.build,
      // DefaultCacheManager opens a sqflite DB, which races with the
      // background audio isolate at startup -> SQLITE_BUSY crash.
      // JsonCacheInfoRepository is sqflite-free.
      cacheManager: CacheManager(
        Config(
          'unissonArtCache',
          repo: JsonCacheInfoRepository(databaseName: 'unissonArtCache'),
        ),
      ),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.example.unisson.channel.audio',
        androidNotificationChannelName: 'Unisson playback',
      ),
    );
    handler.errorStream.listen((msg) {
      if (mounted) setState(() => _error = msg);
    });
    return handler;
  }

  @override
  void dispose() {
    _ytm.dispose();
    _local?.dispose();
    _qobuz.dispose();
    _controller.dispose();
    _storeFuture.then((s) => s.close());
    super.dispose();
  }

  Future<void> _connectQobuz() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => QobuzLoginScreen(provider: _qobuz)),
    );
    if (ok == true && mounted) setState(() {});
  }

  Future<void> _disconnectQobuz() async {
    await _qobuz.logout();
    if (mounted) setState(() {});
  }

  Future<void> _connectYtm() async {
    final cookie = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const YtmLoginScreen()),
    );
    if (cookie != null && cookie.isNotEmpty) {
      await _ytm.loginWithCookie(cookie);
      if (mounted) setState(() {});
    }
  }

  Future<void> _disconnectYtm() async {
    await _ytm.logout();
    if (mounted) setState(() {});
  }

  Future<void> _openImport() async {
    final store = await _storeFuture;
    final importer = ImportService(
      qobuz: _qobuz.isConfigured ? _qobuz : null,
      ytm: _ytm,
      store: store,
    );
    if (!mounted) return;
    await ImportSheet.show(context, importer);
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final r = await _library.searchAll(q);
      setState(() => _results = r);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _searching = false);
    }
  }

  Future<void> _play(MergedTrack t, {String? sourceId}) async {
    final handler = await _handlerFuture;
    handler.quality = _quality;
    // Record what the user plays, for the Recently played tab.
    final store = await _storeFuture;
    store.addRecent(t);
    // Tapping a search result builds a queue from the current results
    // starting at that track.
    final startIdx = _results.indexWhere((r) => r.universalKey == t.universalKey);
    final entries = <QueueEntry>[
      for (var i = (startIdx == -1 ? 0 : startIdx); i < _results.length; i++)
        QueueEntry(
          track: _results[i],
          sourceId: i == (startIdx == -1 ? 0 : startIdx) ? sourceId : null,
        ),
      if (_results.isEmpty) QueueEntry(track: t, sourceId: sourceId),
    ];
    if (entries.isEmpty) entries.add(QueueEntry(track: t, sourceId: sourceId));
    setState(() => _playingSource = sourceId ?? t.bestSourceId);
    await handler.playQueue(entries, startIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.album_rounded),
            const SizedBox(width: 10),
            const Text('Unisson'),
            const SizedBox(width: 6),
            Text(appBuildTag,
                style: const TextStyle(
                    fontSize: 10, color: Colors.white38)),
            const SizedBox(width: 12),
            ..._providers.map((p) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Chip(
                    label: Text(p.id),
                    visualDensity: VisualDensity.compact,
                  ),
                )),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Sources & settings',
            onSelected: (value) {
              if (value == 'qobuz_login') _connectQobuz();
              if (value == 'qobuz_logout') _disconnectQobuz();
              if (value == 'ytm_login') _connectYtm();
              if (value == 'ytm_logout') _disconnectYtm();
              if (value == 'import') _openImport();
              if (value == 'quality_highest') setState(() => _quality = QualityPref.highest);
              if (value == 'quality_balanced') setState(() => _quality = QualityPref.balanced);
              if (value == 'quality_lowest') setState(() => _quality = QualityPref.lowest);
            },
            itemBuilder: (context) => [
              if (!_qobuz.isConfigured)
                const PopupMenuItem(
                  value: 'qobuz_login',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.login, color: Color(0xFF0FA88E)),
                    title: Text('Connect Qobuz'),
                    subtitle: Text('hi-res stream'),
                  ),
                )
              else
                const PopupMenuItem(
                  value: 'qobuz_logout',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.logout, color: Colors.red),
                    title: Text('Disconnect Qobuz'),
                  ),
                ),
              if (!_ytm.isLoggedIn)
                const PopupMenuItem(
                  value: 'ytm_login',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.login, color: Colors.redAccent),
                    title: Text('Connect YouTube Music'),
                    subtitle: Text('for library import'),
                  ),
                )
              else
                const PopupMenuItem(
                  value: 'ytm_logout',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.logout, color: Colors.red),
                    title: Text('Disconnect YouTube Music'),
                  ),
                ),
              const PopupMenuItem(
                value: 'import',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.download),
                  title: Text('Import playlists & favorites'),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                enabled: false,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Playback quality',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              CheckedPopupMenuItem(
                value: 'quality_highest',
                checked: _quality == QualityPref.highest,
                child: const Text('Hi-res / lossless (highest)'),
              ),
              CheckedPopupMenuItem(
                value: 'quality_balanced',
                checked: _quality == QualityPref.balanced,
                child: const Text('Balanced'),
              ),
              CheckedPopupMenuItem(
                value: 'quality_lowest',
                checked: _quality == QualityPref.lowest,
                child: const Text('Lowest data (save data)'),
              ),
            ],
          ),
        ],
      ),
      body: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            if (widget.crashes.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B0A0A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.bug_report,
                            size: 16, color: Colors.redAccent),
                        const SizedBox(width: 6),
                        const Text('Captured crash (last ${appBuildTag})',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        GestureDetector(
                          onTap: () {
                            // rebuild clears nothing automatically; just note it
                          },
                          child: const Icon(Icons.close,
                              size: 14, color: Colors.white38),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.crashes.first,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          color: Colors.redAccent),
                    ),
                  ],
                ),
              ),
            const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.search), text: 'Search'),
                Tab(icon: Icon(Icons.library_music), text: 'Library'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _searchTab(context, primary),
                  FutureBuilder<List<Object>>(
                    future: Future.wait<Object>([_handlerFuture, _storeFuture]),
                    builder: (context, snap) {
                      if (snap.data == null) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }
                      final handler = snap.data![0] as UnissonAudioHandler;
                      final store = snap.data![1] as LibraryStore;
                      return LibraryScreen(store: store, handler: handler);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: FutureBuilder<UnissonAudioHandler>(
        future: _handlerFuture,
        builder: (context, snap) {
          final handler = snap.data;
          if (handler == null) return const SizedBox.shrink();
          return MiniPlayer(handler: handler);
        },
      ),
    );
  }

  Widget _searchTab(BuildContext context, Color primary) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    hintText: 'Search all sources...',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searching ? null : _search,
                child: const Text('Search'),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.shade900,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!),
            ),
          ),
        Expanded(
          child: _searching
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (context, i) {
                    final t = _results[i];
                    final badgeSources = t.sources.keys.toList()..sort((a, b) {
                      const order = ['local', 'qobuz', 'ytm'];
                      int rank(String s) {
                        final i = order.indexOf(s);
                        return i == -1 ? order.length : i;
                      }
                      return rank(a).compareTo(rank(b));
                    });
                    return FutureBuilder<UnissonAudioHandler>(
                      future: _handlerFuture,
                      builder: (context, hSnap) {
                        final handler = hSnap.data;
                        return StreamBuilder<MediaItem?>(
                          stream: handler?.mediaItem,
                          builder: (context, itemSnap) {
                            final nowId = itemSnap.data?.id;
                            final isCurrent = nowId != null &&
                                nowId.endsWith(':${t.sources[t.bestSourceId]?.id}');
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: t.artwork != null
                                    ? Image.network(
                                        t.artwork!,
                                        width: 48,
                                        height: 48,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(Icons.music_note),
                                      )
                                    : const Icon(Icons.music_note),
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      t.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: isCurrent
                                          ? TextStyle(color: primary)
                                          : null,
                                    ),
                                  ),
                                  ...badgeSources.map((s) => Padding(
                                        padding: const EdgeInsets.only(left: 4),
                                        child: _SourceBadge(
                                          source: s,
                                          isActive: s == _playingSource,
                                        ),
                                      )),
                                ],
                              ),
                              subtitle: Text(
                                '${t.artists.join(', ')}${t.album != null ? ' — ${t.album}' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _HeartButton(track: t, storeFuture: _storeFuture),
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert),
                                    tooltip: 'More',
                                    onSelected: (action) {
                                      if (action.startsWith('from:')) {
                                        _play(t, sourceId: action.substring(5));
                                      } else if (action == 'next' && handler != null) {
                                        handler.playNext(QueueEntry(track: t));
                                      } else if (action == 'queue' && handler != null) {
                                        handler.addToQueue(QueueEntry(track: t));
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      for (final s in badgeSources)
                                        PopupMenuItem(
                                          value: 'from:$s',
                                          child: Text('Play from $s'),
                                        ),
                                      const PopupMenuDivider(),
                                      const PopupMenuItem(
                                        value: 'next',
                                        child: Text('Play next'),
                                      ),
                                      const PopupMenuItem(
                                        value: 'queue',
                                        child: Text('Add to queue'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: isCurrent
                                  ? null
                                  : () => _play(t),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Heart toggle for search rows: favorites a track in the library store.
class _HeartButton extends StatelessWidget {
  final MergedTrack track;
  final Future<LibraryStore> storeFuture;

  const _HeartButton({required this.track, required this.storeFuture});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<LibraryStore>(
      future: storeFuture,
      builder: (context, snap) {
        final store = snap.data;
        if (store == null) {
          return const SizedBox(width: 40, height: 40);
        }
        return StreamBuilder<List<MergedTrack>>(
          stream: store.favoritesStream,
          builder: (context, favSnap) {
            final favKeys =
                (favSnap.data ?? const []).map((t) => t.universalKey).toSet();
            final isFav = favKeys.contains(track.universalKey);
            return IconButton(
              icon: Icon(
                isFav ? Icons.favorite : Icons.favorite_border,
                color: isFav ? theme.colorScheme.primary : null,
              ),
              onPressed: () => store.toggleFavorite(track),
            );
          },
        );
      },
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final String source;
  final bool isActive;

  const _SourceBadge({required this.source, required this.isActive});

  @override
  Widget build(BuildContext context) {
    final color = switch (source) {
      'local' => Colors.green.shade600,
      'qobuz' => const Color(0xFF0FA88E),
      'ytm' => Colors.red.shade700,
      _ => Colors.blueGrey,
    };
    return Tooltip(
      message: subbed('$source'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isActive ? color.withValues(alpha: 0.3) : color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color, width: isActive ? 1.5 : 0.8),
        ),
        child: Text(
          source,
          style: TextStyle(
            fontSize: 10,
            color: isActive ? Colors.white : color.withValues(alpha: 0.9),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  String subbed(String s) => switch (s) {
        'local' => 'Local files',
        'qobuz' => 'Qobuz hi-res',
        'ytm' => 'YouTube Music',
        _ => s,
      };
}