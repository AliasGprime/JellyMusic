import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/player_controller.dart';
import '../state/playlist_store.dart';
import '../state/session.dart';
import 'artist_screen.dart';
import 'mini_player.dart';
import 'playlists_tab.dart';
import 'search_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  static const _titles = ['Artistes', 'Albums', 'Morceaux', 'Playlists'];

  Future<void> _shuffleAll() async {
    final client = context.read<Session>().client!;
    final player = context.read<PlayerController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await player.playItems(await client.randomSongs());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _logout() async {
    final store = context.read<PlaylistStore>();
    await context.read<PlayerController>().stop();
    store.clear();
    if (mounted) await context.read<Session>().logout();
  }

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client!;
    final pages = <Widget>[
      PagedItems(
        fetch: (s, l) => client.artists(start: s, limit: l),
        emptyText: 'Aucun artiste.',
        itemBuilder: (context, items, i) {
          final a = items[i];
          return ListTile(
            leading: CoverImage(
              itemId: a.imageItemId,
              radius: 24,
              fallback: Icons.person,
            ),
            title: Text(a.name),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => ArtistScreen(artist: a))),
          );
        },
      ),
      PagedItems(
        grid: true,
        fetch: (s, l) => client.albums(start: s, limit: l),
        emptyText: 'Aucun album.',
        itemBuilder: (context, items, i) => AlbumCard(album: items[i]),
      ),
      PagedItems(
        fetch: (s, l) => client.songs(start: s, limit: l),
        emptyText: 'Aucun morceau.',
        itemBuilder: (context, items, i) => TrackTile(tracks: items, index: i),
      ),
      const PlaylistsTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        actions: [
          IconButton(
            tooltip: 'Rechercher',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SearchScreen())),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'shuffle') _shuffleAll();
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'shuffle', child: Text('Tout en aléatoire')),
              PopupMenuItem(value: 'logout', child: Text('Se déconnecter')),
            ],
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: _tab == 3 ? const NewPlaylistButton() : null,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(bottomSafe: false),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.person),
                label: 'Artistes',
              ),
              NavigationDestination(icon: Icon(Icons.album), label: 'Albums'),
              NavigationDestination(
                icon: Icon(Icons.music_note),
                label: 'Morceaux',
              ),
              NavigationDestination(
                icon: Icon(Icons.queue_music),
                label: 'Playlists',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
