import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/playlist_store.dart';
import 'playlist_picker.dart';
import 'playlist_screen.dart';
import 'widgets.dart';

/// Onglet « Playlists » : liste partagée, toujours à jour.
class PlaylistsTab extends StatefulWidget {
  const PlaylistsTab({super.key});

  @override
  State<PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<PlaylistsTab> {
  @override
  void initState() {
    super.initState();
    context.read<PlaylistStore>().ensureLoaded();
  }

  void _open(JItem p) =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: p)));

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    final list = store.visible;
    if (list == null) {
      if (store.error != null) {
        return ErrorRetry(error: store.error!, onRetry: store.refresh);
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.queue_music, size: 56),
              const SizedBox(height: 12),
              const Text(
                'Aucune playlist avec de la musique pour l\'instant.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  final id = await createPlaylistFlow(context);
                  final p = store.playlists
                      ?.where((p) => p.id == id)
                      .firstOrNull;
                  if (p != null) _open(p);
                },
                icon: const Icon(Icons.add),
                label: const Text('Créer une playlist'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: store.refresh,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 88), // place pour le bouton +
        itemCount: list.length,
        itemBuilder: (context, i) {
          final p = list[i];
          final n = p.musicCount;
          return ListTile(
            leading: CoverImage(
              itemId: p.imageItemId,
              fallback: Icons.queue_music,
            ),
            title: Text(p.displayName),
            subtitle: n == null
                ? null
                : Text(n == 1 ? '1 morceau' : '$n morceaux'),
            trailing: PlaylistBadge(playlist: p),
            onTap: () => _open(p),
          );
        },
      ),
    );
  }
}

/// Bouton flottant « Nouvelle playlist ».
class NewPlaylistButton extends StatelessWidget {
  const NewPlaylistButton({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: () async {
        final store = context.read<PlaylistStore>();
        final nav = Navigator.of(context);
        final id = await createPlaylistFlow(context);
        final p = store.playlists?.where((p) => p.id == id).firstOrNull;
        if (p != null) {
          nav.push(
            MaterialPageRoute(builder: (_) => PlaylistScreen(playlist: p)),
          );
        }
      },
      icon: const Icon(Icons.add),
      label: const Text('Nouvelle playlist'),
    );
  }
}
