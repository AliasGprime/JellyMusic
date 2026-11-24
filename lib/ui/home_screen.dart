import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/player_controller.dart';
import '../state/playlist_store.dart';
import '../state/session.dart';
import 'artist_screen.dart';
import 'downloads.dart';
import 'layout.dart';
import 'mini_player.dart';
import 'player_bar.dart';
import 'playlists_tab.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import '../update/update_dialog.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  static const _titles = ['Artistes', 'Albums', 'Morceaux', 'Playlists'];
  static const _icons = [
    Icons.person,
    Icons.album,
    Icons.music_note,
    Icons.queue_music,
  ];

  /// Mise en page « ordinateur » : un navigateur par onglet, pour que les
  /// pages (album, artiste…) s'ouvrent dans la zone centrale.
  final _navKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());

  late final List<Widget> _pages = _buildPages();

  void _selectTab(int i) {
    if (i == _tab) {
      // Re-cliquer l'onglet courant revient à sa page de départ.
      _navKeys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = i);
    }
  }

  void _openSearch(BuildContext context) {
    final route = MaterialPageRoute(builder: (_) => const SearchScreen());
    if (isWide(context)) {
      _navKeys[_tab].currentState?.push(route);
    } else {
      Navigator.of(context).push(route);
    }
  }

  void _openSettings(BuildContext context) {
    final route = MaterialPageRoute(
      builder: (_) => SettingsScreen(onLogout: _logout),
    );
    if (isWide(context)) {
      _navKeys[_tab].currentState?.push(route);
    } else {
      Navigator.of(context).push(route);
    }
  }

  Widget _menuButton() => PopupMenuButton<String>(
    tooltip: 'Plus d\'options',
    onSelected: (v) {
      if (v == 'settings') _openSettings(context);
      if (v == 'downloads') {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const DownloadsScreen()));
      }
      if (v == 'shuffle') _shuffleAll();
      if (v == 'update') checkForUpdates(context, manual: true);
      if (v == 'logout') _logout();
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'shuffle', child: Text('Tout en aléatoire')),
      if (!kIsWeb)
        const PopupMenuItem(value: 'downloads', child: Text('Téléchargements')),
      const PopupMenuItem(value: 'settings', child: Text('Paramètres')),
      if (!kIsWeb)
        const PopupMenuItem(
          value: 'update',
          child: Text('Rechercher une mise à jour'),
        ),
      const PopupMenuItem(value: 'logout', child: Text('Se déconnecter')),
    ],
  );

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

  /// Nombre maximum de morceaux mis dans la file par « Lire » / « Aléatoire »
  /// de la page Morceaux.
  static const _maxQueue = 1000;

  List<Widget> _buildPages() {
    final client = context.read<Session>().client!;
    return <Widget>[
      PagedItems(
        alphabet: true,
        fetch: (s, l, letter) =>
            client.artists(start: s, limit: l, letter: letter),
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
        alphabet: true,
        fetch: (s, l, letter) =>
            client.albums(start: s, limit: l, letter: letter),
        emptyText: 'Aucun album.',
        itemBuilder: (context, items, i) => AlbumCard(album: items[i]),
      ),
      PagedItems(
        alphabet: true,
        fetch: (s, l, letter) =>
            client.songs(start: s, limit: l, letter: letter),
        // Lire tous les morceaux (ou ceux de la lettre choisie), dans
        // l'ordre ou au hasard dans toute la bibliothèque.
        headerFor: (letter) => PlayButtons(
          key: ValueKey(letter),
          loadTracks: () async =>
              (await client.songs(limit: _maxQueue, letter: letter)).items,
          loadShuffled: () async => (await client.songs(
            limit: _maxQueue,
            letter: letter,
            random: true,
          )).items,
        ),
        emptyText: 'Aucun morceau.',
        itemBuilder: (context, items, i) => TrackTile(tracks: items, index: i),
      ),
      const PlaylistsTab(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (isWide(context)) return _buildDesktop(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        actions: [
          IconButton(
            tooltip: 'Rechercher',
            icon: const Icon(Icons.search),
            onPressed: () => _openSearch(context),
          ),
          _menuButton(),
        ],
      ),
      body: IndexedStack(index: _tab, children: _pages),
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

  /// Ordinateur : barre latérale | contenu | barre de lecture en bas.
  Widget _buildDesktop(BuildContext context) {
    final theme = Theme.of(context);
    final extended = MediaQuery.sizeOf(context).width >= 1200;
    return PlayerBarScope(
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  NavigationRail(
                    extended: extended,
                    minExtendedWidth: 220,
                    selectedIndex: _tab,
                    onDestinationSelected: _selectTab,
                    labelType: extended
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: extended
                            ? CrossAxisAlignment.start
                            : CrossAxisAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.library_music,
                                color: theme.colorScheme.primary,
                                size: 32,
                              ),
                              if (extended) ...[
                                const SizedBox(width: 12),
                                Text(
                                  'JellyMusic',
                                  style: theme.textTheme.titleLarge,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 20),
                          extended
                              ? SizedBox(
                                  width: 188,
                                  child: FilledButton.tonalIcon(
                                    onPressed: () => _openSearch(context),
                                    icon: const Icon(Icons.search),
                                    label: const Text('Rechercher'),
                                  ),
                                )
                              : IconButton.filledTonal(
                                  tooltip: 'Rechercher',
                                  onPressed: () => _openSearch(context),
                                  icon: const Icon(Icons.search),
                                ),
                        ],
                      ),
                    ),
                    trailing: Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _menuButton(),
                        ),
                      ),
                    ),
                    destinations: [
                      for (var i = 0; i < 4; i++)
                        NavigationRailDestination(
                          icon: Icon(_icons[i]),
                          label: Text(_titles[i]),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  // Toute la largeur : la molette fait défiler la liste
                  // où que soit la souris.
                  Expanded(
                    child: IndexedStack(
                      index: _tab,
                      children: [
                        for (var i = 0; i < 4; i++)
                          Navigator(
                            key: _navKeys[i],
                            onGenerateRoute: (_) => MaterialPageRoute(
                              builder: (_) => Scaffold(
                                appBar: AppBar(title: Text(_titles[i])),
                                body: _pages[i],
                                floatingActionButton: i == 3
                                    ? const NewPlaylistButton()
                                    : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const PlayerBar(),
          ],
        ),
      ),
    );
  }
}
