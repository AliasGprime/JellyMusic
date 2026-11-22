import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/playlist_store.dart';
import '../state/session.dart';
import 'mini_player.dart';
import 'playlist_picker.dart';
import 'search_screen.dart';
import 'widgets.dart';

class PlaylistScreen extends StatefulWidget {
  final JItem playlist;
  const PlaylistScreen({super.key, required this.playlist});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  List<JItem>? _tracks;
  Object? _error;
  late String _name = widget.playlist.name;
  late final PlaylistStore _store = context.read<PlaylistStore>();
  int _seenRevision = 0;

  String get _id => widget.playlist.id;

  @override
  void initState() {
    super.initState();
    _seenRevision = _store.revision;
    _store.addListener(_onStoreChanged);
    _load();
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// Recharge si la playlist a été modifiée ailleurs (ex. depuis la recherche).
  void _onStoreChanged() {
    if (_store.revision != _seenRevision) {
      _seenRevision = _store.revision;
      if (_store.lastChangedId == _id) _load();
    }
    final p = _store.playlists?.where((p) => p.id == _id).firstOrNull;
    if (p != null && p.name != _name && mounted) setState(() => _name = p.name);
  }

  Future<void> _load() async {
    try {
      final t = await context.read<Session>().client!.playlistTracks(_id);
      if (mounted)
        setState(() {
          _tracks = t;
          _error = null;
        });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _snack(String msg, {SnackBarAction? action}) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg), action: action));
  }

  Future<void> _remove(int index) async {
    final tracks = _tracks!;
    final t = tracks[index];
    setState(() => tracks.removeAt(index));
    try {
      await _store.remove(_id, [t]);
      _seenRevision = _store.revision;
      _snack(
        '« ${t.name} » retiré',
        action: SnackBarAction(
          label: 'Annuler',
          onPressed: () => _undo(t, index),
        ),
      );
    } catch (e) {
      _snack('Retrait impossible : $e');
      _load();
    }
  }

  /// Remet le morceau retiré à sa place d'origine.
  Future<void> _undo(JItem t, int index) async {
    final client = context.read<Session>().client!;
    try {
      await _store.add(_id, [t]);
      _seenRevision = _store.revision;
      final fresh = await client.playlistTracks(_id);
      final added = fresh.lastIndexWhere((x) => x.id == t.id);
      if (added >= 0 && added != index) {
        await _store.move(_id, fresh[added], index);
        _seenRevision = _store.revision;
      }
    } catch (e) {
      _snack('Annulation impossible : $e');
    }
    _load();
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final tracks = _tracks!;
    if (newIndex == oldIndex) return;
    final t = tracks.removeAt(oldIndex);
    setState(() => tracks.insert(newIndex, t));
    try {
      await _store.move(_id, t, newIndex);
      _seenRevision = _store.revision;
    } catch (e) {
      _snack('Déplacement impossible : $e');
      _load();
    }
  }

  Future<void> _rename() async {
    var initial = _name;
    String name;
    while (true) {
      final asked = await askPlaylistName(
        context,
        title: 'Renommer la playlist',
        action: 'Renommer',
        initial: initial,
      );
      if (asked == null || asked == _name || !mounted) return;
      name = asked;
      final JItem? existing;
      try {
        existing = await findPlaylistByName(_store, name, excludeId: _id);
      } catch (e) {
        _snack('$e');
        return;
      }
      if (existing == null || !mounted) break;
      final again = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('« ${existing!.name} » existe déjà'),
          content: Text(
            '${describeExisting(existing)}\n\n'
            'Renommer donnerait deux playlists portant le même nom sur votre '
            'serveur.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Renommer quand même'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Changer le nom'),
            ),
          ],
        ),
      );
      if (again == null || !mounted) return;
      if (!again) break;
      initial = name;
    }
    try {
      await _store.rename(_id, name);
      setState(() => _name = name);
    } catch (e) {
      _snack('Renommage impossible : $e');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer la playlist ?'),
        content: Text(
          '« $_name » sera supprimée du serveur. Les morceaux eux-mêmes '
          'restent dans votre bibliothèque. Cette action est définitive.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _store.delete(_id);
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text('« $_name » supprimée')));
    } catch (e) {
      _snack('Suppression impossible : $e');
    }
  }

  void _addSongs() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SearchScreen(target: widget.playlist, targetName: _name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _tracks;
    final total = (tracks ?? const <JItem>[]).fold<Duration>(
      Duration.zero,
      (s, t) => s + (t.duration ?? Duration.zero),
    );

    Widget body;
    if (tracks == null) {
      body = _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    } else {
      final header = Column(
        children: [
          const SizedBox(height: 16),
          CoverImage(
            itemId: widget.playlist.imageItemId,
            size: 180,
            radius: 12,
            fallback: Icons.queue_music,
            maxWidth: 500,
          ),
          const SizedBox(height: 8),
          Text(
            [
              tracks.length == 1 ? '1 morceau' : '${tracks.length} morceaux',
              if (tracks.isNotEmpty) formatDuration(total),
            ].join(' · '),
          ),
          if (tracks.isNotEmpty) PlayButtons(loadTracks: () async => tracks),
          if (tracks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text(
                    'Cette playlist est vide.\nAjoutez des morceaux avec le '
                    'bouton ci-dessous, ou depuis le menu ⋮ de n\'importe quel '
                    'morceau.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _addSongs,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Ajouter des morceaux'),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'Glissez un morceau vers la gauche pour le retirer, '
                'ou utilisez la poignée ≡ pour le déplacer.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      );

      body = RefreshIndicator(
        onRefresh: _load,
        child: ReorderableListView.builder(
          header: header,
          buildDefaultDragHandles: false,
          itemCount: tracks.length,
          onReorderItem: _reorder,
          itemBuilder: (context, i) {
            final t = tracks[i];
            return Dismissible(
              key: ValueKey(t.playlistItemId ?? '${t.id}-$i'),
              direction: DismissDirection.endToStart,
              background: Container(
                color: Theme.of(context).colorScheme.errorContainer,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Icon(
                  Icons.playlist_remove,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              onDismissed: (_) => _remove(i),
              child: TrackTile(
                tracks: tracks,
                index: i,
                onRemove: () => _remove(i),
                dragHandle: ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          IconButton(
            tooltip: 'Ajouter des morceaux',
            icon: const Icon(Icons.playlist_add),
            onPressed: _addSongs,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'rename') _rename();
              if (v == 'delete') _delete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Renommer')),
              PopupMenuItem(
                value: 'delete',
                child: Text('Supprimer la playlist'),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: body,
    );
  }
}
