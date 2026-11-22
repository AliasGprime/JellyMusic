import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/session.dart';
import 'mini_player.dart';
import 'playlist_picker.dart';
import 'widgets.dart';

class AlbumScreen extends StatelessWidget {
  final String albumId;
  final String title;
  const AlbumScreen({super.key, required this.albumId, required this.title});

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client!;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Ajouter l\'album à une playlist',
            icon: const Icon(Icons.playlist_add),
            onPressed: () => showAddToPlaylist(
              context,
              loadTracks: () => client.albumTracks(albumId),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: TrackListLoader(
        load: () => client.albumTracks(albumId),
        builder: (context, tracks) {
          final first = tracks.isNotEmpty ? tracks.first : null;
          final total = tracks.fold<Duration>(
            Duration.zero,
            (sum, t) => sum + (t.duration ?? Duration.zero),
          );
          final multiDisc = tracks.map((t) => t.discNumber).toSet().length > 1;
          return ListView.builder(
            itemCount: tracks.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Column(
                  children: [
                    const SizedBox(height: 16),
                    CoverImage(
                      itemId: albumId,
                      size: 220,
                      radius: 12,
                      maxWidth: 600,
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (first != null)
                      Text(
                        [
                          first.albumArtist ?? first.artistLine,
                          if (first.productionYear != null)
                            '${first.productionYear}',
                          '${tracks.length} morceaux',
                          formatDuration(total),
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    PlayButtons(loadTracks: () async => tracks),
                  ],
                );
              }
              final idx = i - 1;
              final t = tracks[idx];
              final showDisc =
                  multiDisc &&
                  (idx == 0 || tracks[idx - 1].discNumber != t.discNumber);
              final tile = TrackTile(
                tracks: tracks,
                index: idx,
                showCover: false,
                showNumber: true,
              );
              if (!showDisc) return tile;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Disque ${t.discNumber ?? ''}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  tile,
                ],
              );
            },
          );
        },
      ),
    );
  }
}
