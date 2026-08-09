import 'dart:io' show Directory;

import 'package:flutter/material.dart';

import 'core/models.dart';
import 'core/player_service.dart';
import 'core/provider.dart';
import 'core/library_service.dart';
import 'providers/local/local_provider.dart';
import 'providers/ytm/ytm_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UnisonApp());
}

class UnisonApp extends StatelessWidget {
  const UnisonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unison',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFEC8603),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final List<MusicProvider> _providers;
  late final LibraryService _library;
  final _player = PlayerService();
  final _controller = TextEditingController();
  final _localRoot = 'PATH_TO_LOCAL_MUSIC_ROOT'; // user-configurable later

  late final YtmProvider _ytm;
  late final LocalProvider? _local;

  List<MergedTrack> _results = [];
  bool _searching = false;
  String? _error;
  MergedTrack? _resolving;
  String? _playingSource;

  @override
  void initState() {
    super.initState();
    _ytm = YtmProvider();
    _local = _localRoot == 'PATH_TO_LOCAL_MUSIC_ROOT'
        ? null
        : LocalProvider([Directory(_localRoot)]);
    _providers = [
      if (_local != null) _local,
      _ytm,
    ];
    _library = LibraryService(_providers);
  }

  @override
  void dispose() {
    _ytm.dispose();
    _local?.dispose();
    _player.dispose();
    _controller.dispose();
    super.dispose();
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
    final src = sourceId ?? t.bestSourceId;
    setState(() {
      _resolving = t;
      _playingSource = src;
    });
    try {
      final rr = sourceId != null
          ? await _library.resolve(t, sourceId, QualityPref.highest)
          : await _library.resolveAuto(t, QualityPref.highest);
      await _player.play(
        Track(
          providerId: src,
          id: rr.stream.uri.toString(),
          title: rr.title,
          artists: rr.artists,
        ),
        rr.stream,
      );
    } catch (e) {
      setState(() => _error = 'Play failed: $e');
    } finally {
      setState(() => _resolving = null);
    }
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
            const Text('Unison'),
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
      ),
      body: Column(
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
                      final isCurrent = _player.current?.title == t.title;
                      final isResolving = _resolving?.universalKey == t.universalKey;
                      final badgeSources = t.sources.keys.toList()..sort((a, b) {
                        const order = ['local', 'qobuz', 'ytm'];
                        int rank(String s) {
                          final i = order.indexOf(s);
                          return i == -1 ? order.length : i;
                        }
                        return rank(a).compareTo(rank(b));
                      });
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
                        trailing: isResolving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : PopupMenuButton<String>(
                                icon: const Icon(Icons.source_rounded),
                                tooltip: 'Choose source',
                                onSelected: (src) => _play(t, sourceId: src),
                                itemBuilder: (context) => [
                                  for (final s in badgeSources)
                                    PopupMenuItem(
                                      value: s,
                                      child: Text('Play from $s'),
                                    ),
                                ],
                              ),
                        onTap: isCurrent
                            ? () => _player.toggle()
                            : () => _play(t),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _player.current == null
          ? null
          : NowPlayingBar(
              title: _player.current!.title,
              artists: _player.current!.artists,
              player: _player,
            ),
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

class NowPlayingBar extends StatelessWidget {
  final String title;
  final List<String> artists;
  final PlayerService player;

  const NowPlayingBar({
    super.key,
    required this.title,
    required this.artists,
    required this.player,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  artists.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.pause_circle_filled),
            onPressed: () => player.toggle(),
          ),
        ],
      ),
    );
  }
}