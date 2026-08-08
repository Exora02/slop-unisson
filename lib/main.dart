import 'package:flutter/material.dart';

import 'core/models.dart';
import 'core/player_service.dart';
import 'providers/ytm/ytm_provider.dart';

void main() {
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
  final _ytm = YtmProvider();
  final _player = PlayerService();
  final _controller = TextEditingController();

  List<Track> _results = [];
  bool _searching = false;
  String? _error;
  Track? _resolving;

  @override
  void dispose() {
    _ytm.dispose();
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
      final r = await _ytm.search(q);
      setState(() => _results = r.tracks);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _searching = false);
    }
  }

  Future<void> _play(Track t) async {
    setState(() => _resolving = t);
    try {
      final spec = await _ytm.resolveStream(t, QualityPref.highest);
      await _player.play(t, spec);
    } catch (e) {
      setState(() => _error = 'Play failed: $e');
    } finally {
      setState(() => _resolving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player.current;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.album_rounded),
            const SizedBox(width: 10),
            const Text('Unison'),
            const SizedBox(width: 8),
            Chip(label: Text(_ytm.id.toUpperCase())),
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
                      hintText: 'Search YouTube Music...',
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
                      final isCurrent = _player.current?.id == t.id;
                      final isResolving = _resolving?.id == t.id;
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
                        title: Text(
                          t.title,
                          maxLines: 1,
                          style: isCurrent
                              ? TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary)
                              : null,
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
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : isCurrent
                                ? Icon(
                                    _player.playing
                                        ? Icons.pause_circle
                                        : Icons.play_circle,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  )
                                : const Icon(Icons.play_arrow_rounded),
                        onTap: isCurrent ? () => _player.toggle() : () => _play(t),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: playing == null
          ? null
          : NowPlayingBar(
              track: playing,
              player: _player,
            ),
    );
  }
}

class NowPlayingBar extends StatelessWidget {
  final Track track;
  final PlayerService player;

  const NowPlayingBar({super.key, required this.track, required this.player});

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
                Text(track.title, maxLines: 1),
                Text(
                  track.artists.join(', '),
                  maxLines: 1,
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
