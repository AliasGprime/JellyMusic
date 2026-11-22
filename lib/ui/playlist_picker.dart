import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/playlist_store.dart';
import 'widgets.dart';

String _countLabel(int n) => n == 1 ? '1 morceau' : '$n morceaux';

/// Demande un nom de playlist (création ou renommage).
Future<String?> askPlaylistName(
  BuildContext context, {
  String title = 'Nouvelle playlist',
  String action = 'Créer',
  String initial = '',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final v = ctrl.text.trim();
        if (v.isNotEmpty) Navigator.of(context).pop(v);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Nom de la playlist'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(onPressed: submit, child: Text(action)),
        ],
      );
    },
  );
}

String _normalize(String s) => s.trim().toLowerCase();

/// Cherche une playlist portant déjà ce nom (casse ignorée), y compris les
/// playlists cachées dans l'application (vides ou ne contenant que des vidéos).
Future<JItem?> findPlaylistByName(
  PlaylistStore store,
  String name, {
  String? excludeId,
}) async {
  await store.refresh(); // liste fraîche : quelqu'un a pu en créer ailleurs
  final n = _normalize(name);
  return store.playlists
      ?.where((p) => p.id != excludeId && _normalize(p.name) == n)
      .firstOrNull;
}

/// Décrit une playlist existante pour la boîte d'avertissement.
String describeExisting(JItem p) {
  final music = p.musicCount ?? 0;
  final other = (p.childCount ?? 0) - music;
  if (music > 0) {
    return 'Elle contient ${_countLabel(music)}'
        '${other > 0 ? ' et $other autre(s) élément(s) (vidéos)' : ''}.';
  }
  if (other > 0) {
    return 'Elle ne contient que des vidéos ($other élément(s)) : c\'est pour '
        'ça qu\'elle n\'apparaît pas dans l\'application.';
  }
  return 'Elle est vide : c\'est pour ça qu\'elle n\'apparaît pas encore dans '
      'l\'onglet Playlists.';
}

enum _DuplicateChoice { useExisting, createAnyway, rename }

/// Crée une playlist vide (ou remplie de [tracks]) après avoir demandé son nom.
/// Si le nom existe déjà, propose d'utiliser l'existante, de créer quand même
/// ou de changer le nom. Renvoie l'id de la playlist utilisée.
Future<String?> createPlaylistFlow(
  BuildContext context, {
  List<JItem> tracks = const [],
}) async {
  final store = context.read<PlaylistStore>();
  final messenger = ScaffoldMessenger.of(context);
  var initial = '';
  String name;
  while (true) {
    final asked = await askPlaylistName(context, initial: initial);
    if (asked == null || !context.mounted) return null;
    name = asked;

    final JItem? existing;
    try {
      existing = await findPlaylistByName(store, name);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
      return null;
    }
    if (existing == null || !context.mounted) break;

    final choice = await showDialog<_DuplicateChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('« ${existing!.name} » existe déjà'),
        content: Text(
          '${describeExisting(existing)}\n\n'
          'Créer une nouvelle playlist donnerait deux playlists portant le '
          'même nom sur votre serveur.',
        ),
        actionsOverflowDirection: VerticalDirection.down,
        actionsOverflowButtonSpacing: 4,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_DuplicateChoice.rename),
            child: const Text('Changer le nom'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_DuplicateChoice.createAnyway),
            child: const Text('Créer quand même'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_DuplicateChoice.useExisting),
            child: Text(
              tracks.isEmpty ? 'Ouvrir l\'existante' : 'Ajouter à l\'existante',
            ),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return null;
    if (choice == _DuplicateChoice.rename) {
      initial = name;
      continue;
    }
    if (choice == _DuplicateChoice.createAnyway) break;

    // Utiliser la playlist existante.
    if (tracks.isNotEmpty) {
      try {
        await store.add(existing.id, tracks);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              '${_countLabel(tracks.length)} ajouté(s) à « ${existing.name} »',
            ),
          ),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Ajout impossible : $e')),
        );
        return null;
      }
    }
    return existing.id;
  }

  try {
    final id = await store.create(name, tracks: tracks);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          tracks.isEmpty
              ? 'Playlist « $name » créée'
              : '${_countLabel(tracks.length)} dans la nouvelle playlist « $name »',
        ),
      ),
    );
    return id;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Création impossible : $e')));
    return null;
  }
}

/// Feuille « Ajouter à une playlist » : choisir une playlist ou en créer une.
/// [loadTracks] permet de charger les morceaux (ex. un album) au moment du choix.
Future<void> showAddToPlaylist(
  BuildContext context, {
  List<JItem>? tracks,
  Future<List<JItem>> Function()? loadTracks,
}) async {
  assert(tracks != null || loadTracks != null);
  final store = context.read<PlaylistStore>();
  final messenger = ScaffoldMessenger.of(context);
  store.ensureLoaded();

  final choice = await showModalBottomSheet<_Choice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _PickerSheet(),
  );
  if (choice == null || !context.mounted) return;

  List<JItem> list;
  try {
    list = tracks ?? await loadTracks!();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return;
  }
  if (list.isEmpty || !context.mounted) return;

  if (choice.playlist == null) {
    await createPlaylistFlow(context, tracks: list);
    return;
  }
  final p = choice.playlist!;
  try {
    await store.add(p.id, list);
    messenger.showSnackBar(
      SnackBar(
        content: Text('${_countLabel(list.length)} ajouté(s) à « ${p.name} »'),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Ajout impossible : $e')));
  }
}

class _Choice {
  final JItem? playlist; // null = nouvelle playlist
  const _Choice(this.playlist);
}

class _PickerSheet extends StatelessWidget {
  const _PickerSheet();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    final playlists = store.pickable ?? const <JItem>[];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Ajouter à une playlist',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: const Icon(Icons.add),
            ),
            title: const Text('Nouvelle playlist…'),
            onTap: () => Navigator.of(context).pop(const _Choice(null)),
          ),
          const Divider(),
          if (store.loading && store.playlists == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (store.error != null && store.playlists == null)
            ErrorRetry(error: store.error!, onRetry: store.refresh)
          else if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('Aucune playlist pour l\'instant.')),
            ),
          for (final p in playlists)
            ListTile(
              leading: CoverImage(
                itemId: p.imageItemId,
                fallback: Icons.queue_music,
              ),
              title: Text(p.name),
              subtitle: p.musicCount != null
                  ? Text(_countLabel(p.musicCount!))
                  : null,
              onTap: () => Navigator.of(context).pop(_Choice(p)),
            ),
        ],
      ),
    );
  }
}
