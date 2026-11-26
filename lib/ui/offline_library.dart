import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/download_store.dart';
import '../state/playlist_store.dart';
import 'library_tabs.dart';
import 'mini_player.dart';
import 'widgets.dart';

/// Bibliothèque hors connexion : artistes, albums, morceaux et playlists
/// calculés à partir des seuls morceaux téléchargés.
class OfflineLibrary {
  final DownloadStore downloads;

  /// Morceaux téléchargés, par ordre alphabétique.
  final List<JItem> tracks;

  OfflineLibrary(this.downloads) : tracks = downloads.allTracks;

  static String albumKey(JItem t) => t.albumId ?? 'album:${t.album ?? ''}';

  static List<String> _artistsOf(JItem t) => t.artists.isNotEmpty
      ? t.artists
      : [if ((t.albumArtist ?? '').isNotEmpty) t.albumArtist!];

  static int _byName(JItem a, JItem b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  /// Ordre d'un album : disque, puis numéro de piste, puis titre.
  static int _albumOrder(JItem a, JItem b) {
    final d = (a.discNumber ?? 0).compareTo(b.discNumber ?? 0);
    if (d != 0) return d;
    final i = (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
    return i != 0 ? i : _byName(a, b);
  }

  /// Un artiste par nom (pas d'identifiant d'artiste dans les morceaux).
  List<JItem> get artists {
    final names = <String, String>{}; // minuscules → nom affiché
    for (final t in tracks) {
      for (final a in _artistsOf(t)) {
        names.putIfAbsent(a.toLowerCase(), () => a);
      }
    }
    return [
      for (final n in names.values)
        JItem(id: 'artist:$n', name: n, type: 'MusicArtist'),
    ]..sort(_byName);
  }

  List<JItem> tracksOfArtist(String name) {
    final key = name.toLowerCase();
    return tracks
        .where((t) => _artistsOf(t).any((a) => a.toLowerCase() == key))
        .toList()
      ..sort((a, b) {
        final c = (a.album ?? '').toLowerCase().compareTo(
          (b.album ?? '').toLowerCase(),
        );
        return c != 0 ? c : _albumOrder(a, b);
      });
  }

  /// Un genre par nom, d'après les genres des morceaux téléchargés.
  List<JItem> get genres {
    final names = <String, String>{}; // minuscules → nom affiché
    for (final t in tracks) {
      for (final g in t.genres ?? const <String>[]) {
        names.putIfAbsent(g.toLowerCase(), () => g);
      }
    }
    return [
      for (final n in names.values)
        JItem(id: 'genre:$n', name: n, type: 'MusicGenre'),
    ]..sort(_byName);
  }

  /// Chansons téléchargées d'un genre, par titre.
  List<JItem> tracksOfGenre(String name) {
    final key = name.toLowerCase();
    return tracks
        .where(
          (t) =>
              (t.genres ?? const <String>[]).any((g) => g.toLowerCase() == key),
        )
        .toList();
  }

  /// Un album par album des morceaux téléchargés. Son [JItem.id] est la
  /// clé de [albumKey].
  List<JItem> get albums {
    final byKey = <String, JItem>{};
    for (final t in tracks) {
      byKey.putIfAbsent(
        albumKey(t),
        () => JItem(
          id: albumKey(t),
          name: (t.album ?? '').isEmpty ? 'Album inconnu' : t.album!,
          type: 'MusicAlbum',
          albumArtist: t.albumArtist ?? t.artistLine,
          productionYear: t.productionYear,
        ),
      );
    }
    return byKey.values.toList()..sort(_byName);
  }

  List<JItem> tracksOfAlbum(String key) =>
      tracks.where((t) => albumKey(t) == key).toList()..sort(_albumOrder);

  /// Pochette d'un album : celle d'un de ses morceaux téléchargés.
  String? coverOfAlbum(String key) {
    for (final t in tracks) {
      if (albumKey(t) == key && downloads.coverFor(t.imageItemId) != null) {
        return t.imageItemId;
      }
    }
    return null;
  }

  /// Playlists qui contiennent au moins un morceau téléchargé, avec la liste
  /// de ces morceaux dans l'ordre de la playlist.
  List<(String name, List<JItem> tracks)> playlists(PlaylistStore store) {
    final out = <(String, List<JItem>)>[];
    final seen = <String>{};
    for (final p in store.mine ?? const <JItem>[]) {
      final t = [
        for (final id in p.musicIds ?? const <String>[])
          if (downloads.entries[id] != null) downloads.entries[id]!.track,
      ];
      if (t.isEmpty) continue;
      seen.add(p.id);
      out.add((p.displayName, t));
    }
    // Playlists téléchargées absentes de la copie de la liste du serveur.
    for (final p in downloads.playlists.values) {
      if (seen.contains(p.id)) continue;
      final t = downloads.tracksOf(p);
      if (t.isNotEmpty) out.add((p.name, t));
    }
    out.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    return out;
  }

  /// Vrai si [name] commence par [letter] (barre A-Z ; « # » : chiffre ou
  /// symbole). Les accents sont ignorés (« É » va avec « E »).
  static bool startsWith(String name, String? letter) {
    if (letter == null) return true;
    final n = name.trim();
    if (n.isEmpty) return letter == '#';
    final c = _plain(n[0].toUpperCase());
    final isLetter = c.compareTo('A') >= 0 && c.compareTo('Z') <= 0;
    return letter == '#' ? !isLetter : c == letter;
  }

  static String _plain(String c) {
    const from = 'ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝ';
    const to = 'AAAAAACEEEEIIIINOOOOOUUUUY';
    final i = from.indexOf(c);
    return i < 0 ? c : to[i];
  }

  /// Une page de [items] pour [PagedItems], filtrée par lettre.
  static ItemsPage page(List<JItem> items, int start, int limit, String? l) {
    final f = items.where((i) => startsWith(i.name, l)).toList();
    return ItemsPage(f.skip(start).take(limit).toList(), f.length);
  }
}

/// Liste de morceaux téléchargés (artiste, album ou playlist hors
/// connexion).
class OfflineTracksScreen extends StatelessWidget {
  final String title;
  final List<JItem> tracks;
  final bool album;
  const OfflineTracksScreen({
    super.key,
    required this.title,
    required this.tracks,
    this.album = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      bottomNavigationBar: const MiniPlayer(),
      body: ListView(
        children: [
          PlayButtons(loadTracks: () async => tracks),
          for (var i = 0; i < tracks.length; i++)
            TrackTile(
              tracks: tracks,
              index: i,
              showCover: !album,
              showNumber: album,
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// « Voir l'album » hors connexion : ses morceaux téléchargés.
void openOfflineAlbum(BuildContext context, JItem track) {
  final lib = OfflineLibrary(context.read<DownloadStore>());
  final key = OfflineLibrary.albumKey(track);
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => OfflineTracksScreen(
        title: (track.album ?? '').isEmpty ? 'Album inconnu' : track.album!,
        tracks: lib.tracksOfAlbum(key),
        album: true,
      ),
    ),
  );
}

/// Les quatre onglets de l'accueil, hors connexion.
List<Widget> offlinePages(DownloadStore d) {
  final lib = OfflineLibrary(d);
  return [
    SegmentedPages(
      labels: const ['Artistes', 'Albums'],
      icons: const [Icons.person, Icons.album],
      children: [
        PagedItems(
          alphabet: true,
          fetch: (s, l, letter) async =>
              OfflineLibrary.page(lib.artists, s, l, letter),
          emptyText: 'Aucun artiste téléchargé.',
          itemBuilder: (context, items, i) {
            final a = items[i];
            return ListTile(
              leading: const CoverImage(
                itemId: null,
                radius: 24,
                fallback: Icons.person,
              ),
              title: Text(a.name),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => OfflineTracksScreen(
                    title: a.name,
                    tracks: lib.tracksOfArtist(a.name),
                  ),
                ),
              ),
            );
          },
        ),
        PagedItems(
          grid: true,
          alphabet: true,
          fetch: (s, l, letter) async =>
              OfflineLibrary.page(lib.albums, s, l, letter),
          emptyText: 'Aucun album téléchargé.',
          itemBuilder: (context, items, i) {
            final a = items[i];
            return AlbumCard(
              album: a,
              coverId: lib.coverOfAlbum(a.id),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => OfflineTracksScreen(
                    title: a.name,
                    tracks: lib.tracksOfAlbum(a.id),
                    album: true,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    ),
    PagedItems(
      alphabet: true,
      fetch: (s, l, letter) async =>
          OfflineLibrary.page(lib.genres, s, l, letter),
      emptyText: lib.tracks.isEmpty
          ? 'Aucun genre téléchargé.'
          : 'Aucun genre téléchargé. Les genres des chansons déjà '
                'téléchargées sont récupérés à la prochaine connexion au '
                'serveur.',
      itemBuilder: (context, items, i) {
        final g = items[i];
        final tracks = lib.tracksOfGenre(g.name);
        return GenreTile(
          genre: g,
          count: tracks.length,
          countLabel: 'chanson téléchargée',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  OfflineTracksScreen(title: g.name, tracks: tracks),
            ),
          ),
        );
      },
    ),
    PagedItems(
      alphabet: true,
      fetch: (s, l, letter) async =>
          OfflineLibrary.page(lib.tracks, s, l, letter),
      headerFor: (letter) => PlayButtons(
        key: ValueKey(letter),
        loadTracks: () async => lib.tracks
            .where((t) => OfflineLibrary.startsWith(t.name, letter))
            .toList(),
      ),
      emptyText: 'Aucune chanson téléchargée.',
      itemBuilder: (context, items, i) => TrackTile(tracks: items, index: i),
    ),
    const _OfflinePlaylists(),
  ];
}

class _OfflinePlaylists extends StatefulWidget {
  const _OfflinePlaylists();

  @override
  State<_OfflinePlaylists> createState() => _OfflinePlaylistsState();
}

class _OfflinePlaylistsState extends State<_OfflinePlaylists> {
  @override
  void initState() {
    super.initState();
    context.read<PlaylistStore>().refresh(); // copie gardée sur le téléphone
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    final lib = OfflineLibrary(context.watch<DownloadStore>());
    final list = lib.playlists(store);
    if (list.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Aucune playlist avec des morceaux téléchargés.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) {
        final (name, tracks) = list[i];
        final n = tracks.length;
        return ListTile(
          // Pochette d'un des morceaux téléchargés.
          leading: CoverImage(
            itemId: tracks
                .map((t) => t.imageItemId)
                .where((id) => lib.downloads.coverFor(id) != null)
                .firstOrNull,
            fallback: Icons.queue_music,
          ),
          title: Text(name),
          subtitle: Text(
            n == 1 ? '1 morceau téléchargé' : '$n morceaux téléchargés',
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => OfflineTracksScreen(title: name, tracks: tracks),
            ),
          ),
        );
      },
    );
  }
}

/// Recherche hors connexion, parmi les morceaux téléchargés (titre,
/// artiste ou album).
class OfflineSearchScreen extends StatefulWidget {
  const OfflineSearchScreen({super.key});

  @override
  State<OfflineSearchScreen> createState() => _OfflineSearchScreenState();
}

class _OfflineSearchScreenState extends State<OfflineSearchScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final lib = OfflineLibrary(context.watch<DownloadStore>());
    final q = _q.trim().toLowerCase();
    final found = q.isEmpty
        ? const <JItem>[]
        : lib.tracks
              .where(
                (t) =>
                    t.name.toLowerCase().contains(q) ||
                    t.artistLine.toLowerCase().contains(q) ||
                    (t.album ?? '').toLowerCase().contains(q),
              )
              .toList();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Rechercher dans les téléchargements',
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: q.isEmpty
          ? const SizedBox.shrink()
          : found.isEmpty
          ? const Center(child: Text('Aucun morceau téléchargé trouvé.'))
          : ListView.builder(
              itemCount: found.length,
              itemBuilder: (context, i) => TrackTile(tracks: found, index: i),
            ),
    );
  }
}
