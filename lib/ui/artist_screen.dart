import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/session.dart';
import 'mini_player.dart';
import 'widgets.dart';

class ArtistScreen extends StatelessWidget {
  final JItem artist;
  const ArtistScreen({super.key, required this.artist});

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client!;
    return Scaffold(
      appBar: AppBar(title: Text(artist.name)),
      bottomNavigationBar: const MiniPlayer(),
      body: PagedItems(
        grid: true,
        emptyText: 'Aucun album pour cet artiste.',
        header: Column(
          children: [
            const SizedBox(height: 16),
            CoverImage(
              itemId: artist.imageItemId,
              size: 160,
              radius: 80,
              fallback: Icons.person,
              maxWidth: 400,
            ),
            const SizedBox(height: 8),
            PlayButtons(loadTracks: () => client.artistTracks(artist.id)),
          ],
        ),
        fetch: (start, limit) =>
            client.albums(artistId: artist.id, start: start, limit: limit),
        itemBuilder: (context, items, i) => AlbumCard(album: items[i]),
      ),
    );
  }
}
