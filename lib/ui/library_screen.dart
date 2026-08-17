import 'package:flutter/material.dart';

import '../core/audio_handler.dart';
import '../core/library_service.dart';
import '../core/library_store.dart';
import '../core/queue.dart';

/// Library tab: favorites, playlists, recently played.
class LibraryScreen extends StatelessWidget {
  final LibraryStore store;
  final UnissonAudioHandler handler;

  const LibraryScreen({super.key, required this.store, required this.handler});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.favorite), text: 'Favorites'),
              Tab(icon: Icon(Icons.playlist_play), text: 'Playlists'),
              Tab(icon: Icon(Icons.history), text: 'Recent'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _FavoritesTab(store: store, handler: handler),
                _PlaylistsTab(store: store, handler: handler),
                _RecentTab(store: store, handler: handler),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared row for a saved track: play, heart-toggle, add to playlist.
class _TrackRow extends StatelessWidget {
  final MergedTrack track;
  final LibraryStore store;
  final UnissonAudioHandler handler;
  final List<MergedTrack> queueSource;
  final VoidCallback? onRemove;

  const _TrackRow({
    required this.track,
    required this.store,
    required this.handler,
    required this.queueSource,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<List<MergedTrack>>(
      stream: store.favoritesStream,
      builder: (context, favSnap) {
        final favKeys =
            (favSnap.data ?? const []).map((t) => t.universalKey).toSet();
        final isFav = favKeys.contains(track.universalKey);
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: track.artwork != null
                ? Image.network(
                    track.artwork!,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.music_note),
                  )
                : const Icon(Icons.music_note),
          ),
          title: Text(track.title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${track.artists.join(', ')}${track.album != null ? ' — ${track.album}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  isFav ? Icons.favorite : Icons.favorite_border,
                  color: isFav ? theme.colorScheme.primary : null,
                ),
                onPressed: () => store.toggleFavorite(track),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (action) async {
                  if (action == 'playlist') {
                    await _pickPlaylist(context);
                  } else if (action == 'remove' && onRemove != null) {
                    onRemove!();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'playlist',
                    child: Text('Add to playlist'),
                  ),
                  if (onRemove != null)
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove'),
                    ),
                ],
              ),
            ],
          ),
          onTap: () {
            final idx =
                queueSource.indexWhere((t) => t.universalKey == track.universalKey);
            handler.playQueue(
              [for (final t in queueSource) QueueEntry(track: t)],
              startIndex: idx == -1 ? 0 : idx,
            );
          },
        );
      },
    );
  }

  Future<void> _pickPlaylist(BuildContext context) async {
    final playlists = store.playlistsStream.value;
    if (!context.mounted) return;
    final choice = await showDialog<Playlist>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to playlist'),
        children: [
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No playlists yet. Create one first.'),
            ),
          for (final pl in playlists)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(pl),
              child: Text(pl.name),
            ),
        ],
      ),
    );
    if (choice != null) {
      await store.addToPlaylist(choice.id, track);
    }
  }
}

class _FavoritesTab extends StatelessWidget {
  final LibraryStore store;
  final UnissonAudioHandler handler;

  const _FavoritesTab({required this.store, required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MergedTrack>>(
      stream: store.favoritesStream,
      builder: (context, snap) {
        final tracks = snap.data ?? const <MergedTrack>[];
        if (tracks.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No favorites yet.\nTap the heart on any track to keep it here.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.builder(
          itemCount: tracks.length,
          itemBuilder: (context, i) => _TrackRow(
            track: tracks[i],
            store: store,
            handler: handler,
            queueSource: tracks,
          ),
        );
      },
    );
  }
}

class _PlaylistsTab extends StatelessWidget {
  final LibraryStore store;
  final UnissonAudioHandler handler;

  const _PlaylistsTab({required this.store, required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Playlist>>(
      stream: store.playlistsStream,
      builder: (context, snap) {
        final playlists = snap.data ?? const <Playlist>[];
        return Column(
          children: [
            if (playlists.isEmpty)
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('No playlists yet.'),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (context, i) {
                    final pl = playlists[i];
                    return FutureBuilder<int>(
                      future: store.playlistCount(pl.id),
                      builder: (context, countSnap) {
                        return ListTile(
                          leading: const Icon(Icons.playlist_play),
                          title: Text(pl.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${countSnap.data ?? 0} tracks'),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) async {
                              if (action == 'rename') {
                                await _renameDialog(context, pl);
                              } else if (action == 'delete') {
                                await store.deletePlaylist(pl.id);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(value: 'rename', child: Text('Rename')),
                              PopupMenuItem(value: 'delete', child: Text('Delete')),
                            ],
                          ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _PlaylistDetailScreen(
                                playlist: pl,
                                store: store,
                                handler: handler,
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: () => _createDialog(context),
                  icon: const Icon(Icons.add),
                  label: const Text('New playlist'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _createDialog(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await store.createPlaylist(name);
    }
  }

  Future<void> _renameDialog(BuildContext context, Playlist pl) async {
    final controller = TextEditingController(text: pl.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await store.renamePlaylist(pl.id, name);
    }
  }
}

class _RecentTab extends StatelessWidget {
  final LibraryStore store;
  final UnissonAudioHandler handler;

  const _RecentTab({required this.store, required this.handler});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MergedTrack>>(
      stream: store.recentStream,
      builder: (context, snap) {
        final tracks = snap.data ?? const <MergedTrack>[];
        if (tracks.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('Nothing played yet.'),
            ),
          );
        }
        return ListView.builder(
          itemCount: tracks.length,
          itemBuilder: (context, i) => _TrackRow(
            track: tracks[i],
            store: store,
            handler: handler,
            queueSource: tracks,
          ),
        );
      },
    );
  }
}

class _PlaylistDetailScreen extends StatelessWidget {
  final Playlist playlist;
  final LibraryStore store;
  final UnissonAudioHandler handler;

  const _PlaylistDetailScreen({
    required this.playlist,
    required this.store,
    required this.handler,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Play all',
              onPressed: () async {
                final tracks = await store.playlistTracks(playlist.id);
                if (tracks.isNotEmpty) {
                  await handler
                      .playQueue([for (final t in tracks) QueueEntry(track: t)]);
                }
              },
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<MergedTrack>>(
        future: store.playlistTracks(playlist.id),
        builder: (context, snap) {
          final tracks = snap.data ?? const <MergedTrack>[];
          if (tracks.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Empty playlist.\nAdd tracks via ⋮ → Add to playlist.'),
              ),
            );
          }
          return ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) => _TrackRow(
              track: tracks[i],
              store: store,
              handler: handler,
              queueSource: tracks,
              onRemove: () =>
                  store.removeFromPlaylist(playlist.id, tracks[i].universalKey),
            ),
          );
        },
      ),
    );
  }
}
