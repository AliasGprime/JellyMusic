import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/download_store.dart';
import '../state/playlist_store.dart';
import '../state/session.dart';
import 'downloads.dart';
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

  /// La playlist telle que connue maintenant (son nom peut changer).
  late JItem _pl = widget.playlist;
  String get _name => _pl.displayName;
  late final PlaylistStore _store = context.read<PlaylistStore>();
  int _seenRevision = 0;

  String get _id => widget.playlist.id;

  /// Playlist Spotify : lecture seule (rien ne peut être ajouté, retiré,
  /// déplacé, renommé ni supprimé).
  bool get _locked => _pl.isLocked;

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
    if (p != null && p.name != _pl.name && mounted) setState(() => _pl = p);
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
    if (_locked) return;
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
    if (_locked) return;
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
    if (_locked) return;
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
      await _store.rename(_pl, name);
    } catch (e) {
      _snack('Renommage impossible : $e');
    }
  }

  Future<void> _delete() async {
    if (_locked) return;
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
    if (_locked) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchScreen(target: _pl, targetName: _name),
      ),
    );
  }

  /// Télécharge toute la playlist pour l'écoute sans connexion.
  void _download() {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    showDownloadDialog(context, tracks: tracks, playlist: _pl);
  }

  /// Rend la playlist privée (seulement ce compte) ou publique (tous).
  Future<void> _setPrivate(bool private) async {
    if (_locked) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(private ? 'Rendre privée ?' : 'Rendre publique ?'),
        content: Text(
          private
              ? '« $_name » ne sera plus visible que par votre compte. Elle '
                    'disparaîtra pour les autres comptes.'
              : '« $_name » sera visible par tous les comptes du serveur.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(private ? 'Rendre privée' : 'Rendre publique'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _store.setPrivate(_pl, private);
      _snack(
        private
            ? '« $_name » est maintenant privée'
            : '« $_name » est maintenant publique',
      );
    } catch (e) {
      _snack('Changement impossible : $e');
    }
  }

  /// Copie la playlist (ex. une playlist Spotify) dans une nouvelle playlist
  /// modifiable, puis l'ouvre.
  Future<void> _clone() async {
    var initial = _pl.isSpotify ? _pl.baseName : '${_pl.baseName} (copie)';
    var private = true;
    NewPlaylist? asked;
    while (true) {
      asked = await askNewPlaylist(
        context,
        title: 'Cloner « $_name »',
        action: 'Cloner',
        initial: initial,
        private: private,
      );
      if (asked == null || !mounted) return;
      initial = asked.name;
      private = asked.private;
      final JItem? existing;
      try {
        existing = await findPlaylistByName(_store, asked.name);
      } catch (e) {
        _snack('$e');
        return;
      }
      if (existing == null || !mounted) break;
      final again = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('« ${existing!.displayName} » existe déjà'),
          content: Text(
            '${describeExisting(existing)}\n\n'
            'Cloner sous ce nom donnerait deux playlists portant le même nom.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cloner quand même'),
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
    }
    final nav = Navigator.of(context);
    _snack('Clonage en cours…');
    try {
      final id = await _store.clone(_pl, asked.name, private: asked.private);
      final copy = _store.playlists?.where((p) => p.id == id).firstOrNull;
      _snack('Playlist « ${asked.name} » créée');
      if (copy != null && mounted) {
        nav.push(
          MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: copy)),
        );
      }
    } catch (e) {
      _snack('Clonage impossible : $e');
    }
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
          if (_locked)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Playlist importée de Spotify : verrouillée, en lecture '
                      'seule.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            )
          else if (tracks.isEmpty)
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
        child: _locked
            ? ListView.builder(
                itemCount: tracks.length + 1,
                itemBuilder: (context, i) =>
                    i == 0 ? header : TrackTile(tracks: tracks, index: i - 1),
              )
            : ReorderableListView.builder(
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
          if (_locked)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Tooltip(
                message: 'Playlist Spotify verrouillée',
                child: Icon(Icons.lock_outline),
              ),
            )
          else ...[
            if (_pl.isPrivate)
              const Tooltip(
                message: 'Privée : visible seulement par vous',
                child: Icon(Icons.person_outline),
              ),
            IconButton(
              tooltip: 'Ajouter des morceaux',
              icon: const Icon(Icons.playlist_add),
              onPressed: _addSongs,
            ),
          ],
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'rename') _rename();
              if (v == 'private') _setPrivate(true);
              if (v == 'public') _setPrivate(false);
              if (v == 'clone') _clone();
              if (v == 'download') _download();
              if (v == 'stopdl') stopAllDownloads(context);
              if (v == 'delete') _delete();
            },
            itemBuilder: (_) => [
              if (!_locked) ...[
                const PopupMenuItem(value: 'rename', child: Text('Renommer')),
                _pl.isPrivate
                    ? const PopupMenuItem(
                        value: 'public',
                        child: ListTile(
                          leading: Icon(Icons.group_outlined),
                          title: Text('Rendre publique'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      )
                    : const PopupMenuItem(
                        value: 'private',
                        child: ListTile(
                          leading: Icon(Icons.person_outline),
                          title: Text('Rendre privée'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
              ],
              const PopupMenuItem(
                value: 'clone',
                child: ListTile(
                  leading: Icon(Icons.copy_all_outlined),
                  title: Text('Cloner'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (context.read<DownloadStore>().busy)
                const PopupMenuItem(
                  value: 'stopdl',
                  child: ListTile(
                    leading: Icon(Icons.stop_circle_outlined),
                    title: Text('Arrêter les téléchargements'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (context.read<DownloadStore>().supported)
                const PopupMenuItem(
                  value: 'download',
                  child: ListTile(
                    leading: Icon(Icons.download_outlined),
                    title: Text('Télécharger la playlist'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (!_locked)
                const PopupMenuItem(
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
