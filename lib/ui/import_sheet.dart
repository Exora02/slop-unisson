import 'package:flutter/material.dart';

import '../core/import_service.dart';

/// Bottom sheet: pick a remote playlist (or favorites) to import.
class ImportSheet extends StatefulWidget {
  final ImportService importer;

  const ImportSheet({super.key, required this.importer});

  static Future<void> show(BuildContext context, ImportService importer) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: ImportSheet(importer: importer),
      ),
    );
  }

  @override
  State<ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<ImportSheet> {
  late final Future<List<ImportablePlaylist>> _future;
  final _importing = <String>{};
  final _done = <String, ImportResult>{};
  bool _importingFavs = false;
  final _favDone = <String, ImportResult>{};

  @override
  void initState() {
    super.initState();
    _future = widget.importer.listImportablePlaylists();
  }

  String _key(ImportablePlaylist p) => '${p.providerId}:${p.remoteId}';

  Future<void> _import(ImportablePlaylist p) async {
    final key = _key(p);
    if (_importing.contains(key)) return;
    setState(() => _importing.add(key));
    try {
      final r = await widget.importer.importPlaylist(p);
      if (mounted) {
        setState(() {
          _importing.remove(key);
          _done[key] = r;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _importing.remove(key));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  Future<void> _importFavorites(String providerId) async {
    if (_importingFavs) return;
    setState(() => _importingFavs = true);
    try {
      final r = await widget.importer.importFavorites(providerId);
      if (mounted) {
        setState(() {
          _importingFavs = false;
          _favDone[providerId] = r;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _importingFavs = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Icon(Icons.download),
              SizedBox(width: 8),
              Text('Import from Qobuz / YTM',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        if (widget.importer.qobuz != null && widget.importer.qobuz!.isConfigured)
          _favTile('qobuz', 'Qobuz favorites'),
        if (widget.importer.ytm.isLoggedIn)
          _favTile('ytm', 'YTM liked songs'),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<List<ImportablePlaylist>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final playlists = snap.data ?? const [];
              if (playlists.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      widget.importer.ytm.isLoggedIn ||
                              (widget.importer.qobuz != null &&
                                  widget.importer.qobuz!.isConfigured)
                          ? 'No remote playlists found.'
                          : 'Connect Qobuz or YTM first.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: playlists.length,
                itemBuilder: (context, i) {
                  final p = playlists[i];
                  final key = _key(p);
                  final busy = _importing.contains(key);
                  final imported = _done[key];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: p.artwork != null
                          ? Image.network(
                              p.artwork!,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.playlist_play),
                            )
                          : const Icon(Icons.playlist_play),
                    ),
                    title: Text(
                      p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${p.providerId}${p.count != null ? ' · ${p.count} tracks' : ''}'
                      '${imported != null ? ' · fetched ${imported.fetched}, added ${imported.added}' : ''}',
                    ),
                    trailing: busy
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : imported != null
                            ? const Icon(Icons.check_circle,
                                color: Colors.green)
                            : IconButton(
                                icon: const Icon(Icons.download),
                                onPressed: () => _import(p),
                              ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _favTile(String providerId, String label) {
    final busy = _importingFavs;
    final imported = _favDone[providerId];
    return ListTile(
      leading: const Icon(Icons.favorite),
      title: Text(label),
      subtitle: imported != null
          ? Text('fetched ${imported.fetched}, added ${imported.added}')
          : null,
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : imported != null
              ? const Icon(Icons.check_circle, color: Colors.green)
              : IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () => _importFavorites(providerId),
                ),
    );
  }
}
