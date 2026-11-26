import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/session.dart';
import 'mini_player.dart';
import 'widgets.dart';

/// Plusieurs listes dans un même onglet, choisies par des boutons en haut
/// (ex. : Artistes | Albums). Chaque liste garde sa position.
class SegmentedPages extends StatefulWidget {
  final List<String> labels;
  final List<IconData> icons;
  final List<Widget> children;
  const SegmentedPages({
    super.key,
    required this.labels,
    required this.icons,
    required this.children,
  });

  @override
  State<SegmentedPages> createState() => _SegmentedPagesState();
}

class _SegmentedPagesState extends State<SegmentedPages> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                for (var i = 0; i < widget.labels.length; i++)
                  ButtonSegment(
                    value: i,
                    icon: Icon(widget.icons[i]),
                    label: Text(widget.labels[i]),
                  ),
              ],
              selected: {_i},
              onSelectionChanged: (s) => setState(() => _i = s.first),
            ),
          ),
        ),
        Expanded(
          child: IndexedStack(index: _i, children: widget.children),
        ),
      ],
    );
  }
}

/// Ligne d'un genre (en ligne ou hors connexion).
class GenreTile extends StatelessWidget {
  final JItem genre;

  /// Nombre de chansons à afficher (null : rien).
  final int? count;
  final String countLabel;
  final VoidCallback onTap;
  const GenreTile({
    super.key,
    required this.genre,
    required this.count,
    this.countLabel = 'chanson',
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final n = count;
    return ListTile(
      leading: CoverImage(
        itemId: genre.imageItemId,
        radius: 24,
        fallback: Icons.category,
      ),
      title: Text(genre.name),
      subtitle: n == null
          ? null
          : Text(n == 1 ? '1 $countLabel' : '$n ${countLabel}s'),
      onTap: onTap,
    );
  }
}

/// Onglet Genres : genres de musique du serveur.
class GenresPage extends StatelessWidget {
  const GenresPage({super.key});

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client!;
    return PagedItems(
      alphabet: true,
      fetch: (s, l, letter) =>
          client.genres(start: s, limit: l, letter: letter),
      emptyText: 'Aucun genre.',
      itemBuilder: (context, items, i) {
        final g = items[i];
        return GenreTile(
          genre: g,
          count: g.childCount,
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => GenreScreen(genre: g))),
        );
      },
    );
  }
}

/// Page d'un genre : ses chansons et ses albums.
class GenreScreen extends StatelessWidget {
  final JItem genre;
  const GenreScreen({super.key, required this.genre});

  /// Nombre maximum de chansons mises dans la file par « Lire » /
  /// « Aléatoire ».
  static const _maxQueue = 1000;

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client!;
    return Scaffold(
      appBar: AppBar(title: Text(genre.name)),
      bottomNavigationBar: const MiniPlayer(),
      body: SegmentedPages(
        labels: const ['Chansons', 'Albums'],
        icons: const [Icons.music_note, Icons.album],
        children: [
          PagedItems(
            fetch: (s, l, _) => client.genreSongs(genre.id, start: s, limit: l),
            header: PlayButtons(
              loadTracks: () async =>
                  (await client.genreSongs(genre.id, limit: _maxQueue)).items,
              loadShuffled: () async => (await client.genreSongs(
                genre.id,
                limit: _maxQueue,
                random: true,
              )).items,
            ),
            emptyText: 'Aucune chanson.',
            itemBuilder: (context, items, i) =>
                TrackTile(tracks: items, index: i),
          ),
          PagedItems(
            grid: true,
            fetch: (s, l, _) =>
                client.genreAlbums(genre.id, start: s, limit: l),
            emptyText: 'Aucun album.',
            itemBuilder: (context, items, i) => AlbumCard(album: items[i]),
          ),
        ],
      ),
    );
  }
}
