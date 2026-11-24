import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/playlist_store.dart';
import '../state/session.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'mini_player.dart';
import 'playlist_picker.dart';
import 'playlist_screen.dart';
import 'widgets.dart';

class SearchScreen extends StatefulWidget {
  /// Si fourni, la recherche sert à ajouter des morceaux à cette playlist.
  final JItem? target;
  final String? targetName;
  const SearchScreen({super.key, this.target, this.targetName});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  Timer? _debounce;
  String _term = '';
  List<JItem> _results = [];
  bool _loading = false;
  Object? _error;

  /// Éléments déjà ajoutés à la playlist cible pendant cette recherche.
  final Set<String> _added = {};
  final Set<String> _adding = {};

  bool get _pickMode => widget.target != null;

  @override
  void initState() {
    super.initState();
    context.read<PlaylistStore>().ensureLoaded();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => _search(v.trim()),
    );
  }

  Future<void> _search(String term) async {
    _term = term;
    if (term.isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<Session>().client!.search(term);
      if (!mounted || term != _term) return;
      setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addToTarget(JItem item) async {
    if (_added.contains(item.id) || _adding.contains(item.id)) return;
    final store = context.read<PlaylistStore>();
    final client = context.read<Session>().client!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding.add(item.id));
    try {
      final tracks = item.type == 'MusicAlbum'
          ? await client.albumTracks(item.id)
          : [item];
      await store.add(widget.target!.id, tracks);
      if (mounted) setState(() => _added.add(item.id));
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            item.type == 'MusicAlbum'
                ? 'Album « ${item.name} » ajouté (${tracks.length} morceaux)'
                : '« ${item.name} » ajouté',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ajout impossible : $e')));
    } finally {
      if (mounted) setState(() => _adding.remove(item.id));
    }
  }

  Widget _addButton(JItem item) {
    if (_adding.contains(item.id)) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: Padding(
          padding: EdgeInsets.all(14),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final done = _added.contains(item.id);
    return IconButton(
      tooltip: done ? 'Ajouté' : 'Ajouter à la playlist',
      icon: Icon(
        done ? Icons.check_circle : Icons.add_circle_outline,
        color: done ? Theme.of(context).colorScheme.primary : null,
      ),
      onPressed: done ? null : () => _addToTarget(item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final artists = _pickMode
        ? <JItem>[]
        : _results.where((i) => i.type == 'MusicArtist').toList();
    final albums = _results.where((i) => i.type == 'MusicAlbum').toList();
    // Les playlists sans musique (ex. seulement des vidéos) sont masquées.
    final visibleIds = context
        .watch<PlaylistStore>()
        .visible
        ?.map((p) => p.id)
        .toSet();
    final playlists = _pickMode
        ? <JItem>[]
        : _results
              .where((i) => i.type == 'Playlist')
              .where((p) => visibleIds == null || visibleIds.contains(p.id))
              .toList();
    final tracks = _results.where((i) => i.type == 'Audio').toList();

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );

    final targetLabel = _pickMode
        ? 'Ajout à « ${widget.targetName ?? widget.target!.name} »'
              '${_added.isEmpty ? '' : ' · ${_added.length} ajout(s)'}'
        : '';

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(
            hintText: _pickMode
                ? 'Chercher un morceau ou un album…'
                : 'Artistes, albums, morceaux…',
            border: InputBorder.none,
          ),
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (v) => _search(v.trim()),
        ),
        bottom: _pickMode
            ? PreferredSize(
                preferredSize: const Size.fromHeight(32),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    targetLabel,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              )
            : null,
      ),
      bottomNavigationBar: const MiniPlayer(),
      body: _error != null
          ? ErrorRetry(error: _error!, onRetry: () => _search(_term))
          : _loading && _results.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
          ? Center(
              child: Text(
                _term.isEmpty ? 'Tapez pour chercher' : 'Aucun résultat',
              ),
            )
          : ListView(
              children: [
                if (artists.isNotEmpty) section('Artistes'),
                for (final a in artists)
                  ListTile(
                    leading: CoverImage(
                      itemId: a.imageItemId,
                      radius: 24,
                      fallback: Icons.person,
                    ),
                    title: Text(a.name),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ArtistScreen(artist: a),
                      ),
                    ),
                  ),
                if (albums.isNotEmpty) section('Albums'),
                for (final a in albums)
                  ListTile(
                    leading: CoverImage(itemId: a.imageItemId),
                    title: Text(a.name),
                    subtitle: Text(a.albumArtist ?? a.artistLine),
                    trailing: _pickMode ? _addButton(a) : null,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            AlbumScreen(albumId: a.id, title: a.name),
                      ),
                    ),
                  ),
                if (playlists.isNotEmpty) section('Playlists'),
                for (final p in playlists)
                  ListTile(
                    leading: CoverImage(
                      itemId: p.imageItemId,
                      fallback: Icons.queue_music,
                    ),
                    title: Text(p.displayName),
                    trailing: PlaylistBadge(playlist: p),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistScreen(playlist: p),
                      ),
                    ),
                  ),
                if (tracks.isNotEmpty) section('Morceaux'),
                for (var i = 0; i < tracks.length; i++)
                  if (_pickMode)
                    ListTile(
                      leading: CoverImage(itemId: tracks[i].imageItemId),
                      title: Text(
                        tracks[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        tracks[i].artistLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _addButton(tracks[i]),
                      onTap: () => _addToTarget(tracks[i]),
                    )
                  else
                    TrackTile(tracks: tracks, index: i),
              ],
            ),
    );
  }
}
