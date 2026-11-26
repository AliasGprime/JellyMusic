import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/download_store.dart';
import '../state/player_controller.dart';
import '../state/playlist_store.dart';
import '../state/session.dart';
import 'artist_screen.dart';
import 'downloads.dart';
import 'layout.dart';
import 'library_tabs.dart';
import 'mini_player.dart';
import 'offline_library.dart';
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
  static const _titles = ['Bibliothèque', 'Genres', 'Chansons', 'Playlists'];
  static const _icons = [
    Icons.library_music,
    Icons.category,
    Icons.music_note,
    Icons.queue_music,
  ];

  late final Session _session = context.read<Session>();

  @override
  void initState() {
    super.initState();
    _session.addListener(_fillGenres);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fillGenres());
  }

  @override
  void dispose() {
    _session.removeListener(_fillGenres);
    super.dispose();
  }

  /// Serveur disponible : genres des morceaux téléchargés par une ancienne
  /// version (pour l'onglet Genres hors connexion).
  void _fillGenres() {
    final c = _session.client;
    if (!mounted || c == null || _session.offline) return;
    context.read<DownloadStore>().fillGenres(c);
  }

  /// Mise en page « ordinateur » : un navigateur par onglet, pour que les
  /// pages (album, artiste…) s'ouvrent dans la zone centrale.
  final _navKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());

  late final List<Widget> _pages = _buildPages();

  /// Navigateurs des onglets en cours (en ligne ou hors connexion).
  List<GlobalKey<NavigatorState>> get _keys =>
      context.read<Session>().offline ? _offlineNavKeys : _navKeys;

  void _selectTab(int i) {
    if (i == _tab) {
      // Re-cliquer l'onglet courant revient à sa page de départ.
      _keys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = i);
    }
  }

  void _openSearch(BuildContext context) {
    final offline = context.read<Session>().offline;
    final route = MaterialPageRoute(
      builder: (_) =>
          offline ? const OfflineSearchScreen() : const SearchScreen(),
    );
    if (isWide(context)) {
      _keys[_tab].currentState?.push(route);
    } else {
      Navigator.of(context).push(route);
    }
  }

  void _openSettings(BuildContext context) {
    final route = MaterialPageRoute(
      builder: (_) => SettingsScreen(onLogout: _logout),
    );
    if (isWide(context)) {
      _keys[_tab].currentState?.push(route);
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
      if (v == 'downloadAll') _downloadAll();
      if (v == 'update') checkForUpdates(context, manual: true);
      if (v == 'logout') _logout();
    },
    itemBuilder: (_) {
      final session = context.read<Session>();
      final online = session.serverAvailable;
      return [
        const PopupMenuItem(value: 'shuffle', child: Text('Tout en aléatoire')),
        // Onglet Chansons : télécharger toute la bibliothèque.
        if (!kIsWeb && _tab == 2 && online && !session.offline)
          const PopupMenuItem(
            value: 'downloadAll',
            child: Text('Télécharger toutes les chansons'),
          ),
        if (!kIsWeb)
          const PopupMenuItem(
            value: 'downloads',
            child: Text('Téléchargements'),
          ),
        const PopupMenuItem(value: 'settings', child: Text('Paramètres')),
        if (!kIsWeb && online)
          const PopupMenuItem(
            value: 'update',
            child: Text('Rechercher une mise à jour'),
          ),
        if (online)
          const PopupMenuItem(value: 'logout', child: Text('Se déconnecter')),
      ];
    },
  );

  Future<void> _shuffleAll() async {
    final player = context.read<PlayerController>();
    if (context.read<Session>().offline) {
      final tracks = context.read<DownloadStore>().allTracks;
      if (tracks.isNotEmpty) await player.playItems(tracks, shuffle: true);
      return;
    }
    final client = context.read<Session>().client!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await player.playItems(await client.randomSongs());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Télécharge toutes les chansons du serveur (qualité demandée).
  Future<void> _downloadAll() async {
    final client = context.read<Session>().client!;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Liste des chansons du serveur…')),
    );
    try {
      final all = await client.allSongs();
      messenger.hideCurrentSnackBar();
      if (!mounted || all.isEmpty) return;
      await showDownloadDialog(
        context,
        tracks: all,
        title: 'Télécharger toutes les chansons (${all.length})',
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _logout() async {
    final store = context.read<PlaylistStore>();
    await context.read<PlayerController>().stop();
    store.clear();
    if (mounted) await context.read<Session>().logout();
  }

  /// Nombre maximum de chansons mises dans la file par « Lire » /
  /// « Aléatoire » de l'onglet Chansons.
  static const _maxQueue = 1000;

  List<Widget> _buildPages() {
    final client = context.read<Session>().client!;
    return <Widget>[
      SegmentedPages(
        labels: const ['Artistes', 'Albums'],
        icons: const [Icons.person, Icons.album],
        children: [
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
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ArtistScreen(artist: a)),
                ),
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
        ],
      ),
      const GenresPage(),
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
        emptyText: 'Aucune chanson.',
        itemBuilder: (context, items, i) => TrackTile(tracks: items, index: i),
      ),
      const PlaylistsTab(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final offline = context.select<Session, bool>((s) => s.offline);
    final checking = context.select<Session, bool>(
      (s) => s.server == ServerState.checking,
    );
    if (!offline && checking) return _buildChecking(context);
    final pages = offline ? _offlinePagesFor(context) : _pages;
    if (isWide(context)) return _buildDesktop(context, pages, offline);
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        bottom: offline ? _offlineBar(context) : null,
        actions: [
          IconButton(
            tooltip: 'Rechercher',
            icon: const Icon(Icons.search),
            onPressed: () => _openSearch(context),
          ),
          _menuButton(),
        ],
      ),
      body: IndexedStack(
        key: ValueKey(offline ? 'off$_offlineRev' : 'on'),
        index: _tab,
        children: pages,
      ),
      floatingActionButton: _tab == 3 && !offline
          ? const NewPlaylistButton()
          : null,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(bottomSafe: false),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              for (var i = 0; i < 4; i++)
                NavigationDestination(icon: Icon(_icons[i]), label: _titles[i]),
            ],
          ),
        ],
      ),
    );
  }

  /// Démarrage : on vérifie que le serveur répond.
  Widget _buildChecking(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Connexion au serveur…'),
          ],
        ),
      ),
      bottomNavigationBar: MiniPlayer(),
    );
  }

  /// Pages hors connexion, refaites quand les téléchargements changent.
  int _offlineRev = -1;
  List<Widget> _offlinePages = const [];
  List<GlobalKey<NavigatorState>> _offlineNavKeys = const [];

  List<Widget> _offlinePagesFor(BuildContext context) {
    final d = context.watch<DownloadStore>();
    if (d.revision != _offlineRev || _offlinePages.isEmpty) {
      _offlineRev = d.revision;
      _offlinePages = offlinePages(d);
      _offlineNavKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());
    }
    return _offlinePages;
  }

  /// Une seule ligne « Hors connexion » sous le titre ; le détail est dans
  /// les Paramètres.
  PreferredSizeWidget _offlineBar(BuildContext context) {
    final theme = Theme.of(context);
    return PreferredSize(
      preferredSize: const Size.fromHeight(28),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: () => _openSettings(context),
          child: SizedBox(
            height: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  context.select<Session, bool>((s) => s.libraryEmpty)
                      ? 'Bibliothèque du serveur vide'
                      : 'Hors connexion',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Ordinateur : barre latérale | contenu | barre de lecture en bas.
  Widget _buildDesktop(BuildContext context, List<Widget> pages, bool offline) {
    final navKeys = offline ? _offlineNavKeys : _navKeys;
    final theme = Theme.of(context);
    final extended = MediaQuery.sizeOf(context).width >= 1200;
    return PlayerBarScope(
      child: Scaffold(
        body: Column(
          children: [
            if (offline) SafeArea(bottom: false, child: _offlineBar(context)),
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
                      key: ValueKey(offline ? 'off$_offlineRev' : 'on'),
                      index: _tab,
                      children: [
                        for (var i = 0; i < 4; i++)
                          Navigator(
                            key: navKeys[i],
                            onGenerateRoute: (_) => MaterialPageRoute(
                              builder: (_) => Scaffold(
                                appBar: AppBar(title: Text(_titles[i])),
                                body: pages[i],
                                floatingActionButton: i == 3 && !offline
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
