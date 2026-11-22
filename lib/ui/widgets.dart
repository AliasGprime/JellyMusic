import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/player_controller.dart';
import '../state/session.dart';
import 'album_screen.dart';
import 'playlist_picker.dart';

/// Pochette d'album (ou photo d'artiste) avec une icône de secours.
class CoverImage extends StatelessWidget {
  final String? itemId;
  final double size;
  final double radius;
  final IconData fallback;
  final int maxWidth;

  const CoverImage({
    super.key,
    required this.itemId,
    this.size = 48,
    this.radius = 6,
    this.fallback = Icons.album,
    this.maxWidth = 300,
  });

  @override
  Widget build(BuildContext context) {
    final client = context.read<Session>().client;
    final url = client?.imageUrl(itemId, maxWidth: maxWidth);
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      child: Icon(fallback, size: size * 0.5, color: scheme.onSurfaceVariant),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? placeholder
          : CachedNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, __) => placeholder,
              errorWidget: (_, __, ___) => placeholder,
            ),
    );
  }
}

/// Ligne d'un morceau, avec un menu « Lire ensuite / Ajouter à la file ».
class TrackTile extends StatelessWidget {
  final List<JItem> tracks;
  final int index;
  final bool showCover;
  final bool showNumber;

  const TrackTile({
    super.key,
    required this.tracks,
    required this.index,
    this.showCover = true,
    this.showNumber = false,
    this.onRemove,
    this.dragHandle,
  });

  /// Dans une playlist : action « Retirer de la playlist ».
  final VoidCallback? onRemove;

  /// Dans une playlist : poignée pour déplacer le morceau.
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    final t = tracks[index];
    final player = context.read<PlayerController>();
    final isCurrent = context.select<PlayerController, bool>(
      (p) => p.current?.id == t.id,
    );
    final color = isCurrent ? Theme.of(context).colorScheme.primary : null;
    return ListTile(
      leading: showCover
          ? CoverImage(itemId: t.imageItemId, size: 48)
          : SizedBox(
              width: 32,
              child: Center(
                child: isCurrent
                    ? Icon(Icons.graphic_eq, color: color)
                    : Text(
                        showNumber ? '${t.indexNumber ?? ''}' : '',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
              ),
            ),
      title: Text(
        t.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color),
      ),
      subtitle: Text(
        [
          t.artistLine,
          formatDuration(t.duration),
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => player.playItems(tracks, start: index),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TrackMenu(track: t, onRemove: onRemove),
          ?dragHandle,
        ],
      ),
    );
  }
}

class TrackMenu extends StatelessWidget {
  final JItem track;
  final VoidCallback? onRemove;
  const TrackMenu({super.key, required this.track, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        final messenger = ScaffoldMessenger.of(context);
        switch (v) {
          case 'next':
            player.playNext(track);
            messenger.showSnackBar(
              const SnackBar(content: Text('Sera joué ensuite')),
            );
          case 'queue':
            player.addToQueue(track);
            messenger.showSnackBar(
              const SnackBar(content: Text('Ajouté à la file')),
            );
          case 'playlist':
            showAddToPlaylist(context, tracks: [track]);
          case 'remove':
            onRemove?.call();
          case 'album':
            if (track.albumId != null) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AlbumScreen(
                    albumId: track.albumId!,
                    title: track.album ?? '',
                  ),
                ),
              );
            }
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'next', child: Text('Lire ensuite')),
        const PopupMenuItem(value: 'queue', child: Text('Ajouter à la file')),
        const PopupMenuItem(
          value: 'playlist',
          child: Text('Ajouter à une playlist…'),
        ),
        if (onRemove != null)
          const PopupMenuItem(
            value: 'remove',
            child: Text('Retirer de la playlist'),
          ),
        if (track.albumId != null)
          const PopupMenuItem(value: 'album', child: Text('Voir l\'album')),
      ],
    );
  }
}

/// Boutons « Lire » et « Aléatoire » en haut d'une liste de morceaux.
class PlayButtons extends StatelessWidget {
  final Future<List<JItem>> Function() loadTracks;
  const PlayButtons({super.key, required this.loadTracks});

  Future<void> _play(BuildContext context, bool shuffle) async {
    final player = context.read<PlayerController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final tracks = await loadTracks();
      if (tracks.isEmpty) return;
      await player.playItems(tracks, shuffle: shuffle);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _play(context, false),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Lire'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () => _play(context, true),
              icon: const Icon(Icons.shuffle),
              label: const Text('Aléatoire'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Liste qui charge la bibliothèque par pages au fil du défilement.
class PagedItems extends StatefulWidget {
  final Future<ItemsPage> Function(int start, int limit) fetch;
  final Widget Function(BuildContext context, List<JItem> items, int index)
  itemBuilder;
  final bool grid;
  final Widget? header;
  final String emptyText;

  const PagedItems({
    super.key,
    required this.fetch,
    required this.itemBuilder,
    this.grid = false,
    this.header,
    this.emptyText = 'Rien ici pour l\'instant.',
  });

  @override
  State<PagedItems> createState() => _PagedItemsState();
}

class _PagedItemsState extends State<PagedItems>
    with AutomaticKeepAliveClientMixin {
  static const _pageSize = 100;
  final List<JItem> _items = [];
  int _total = -1;
  bool _loading = false;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  bool get _hasMore => _total < 0 || _items.length < _total;

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.fetch(_items.length, _pageSize);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.items.isEmpty ? _items.length : page.total;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _total = -1;
    });
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_items.isEmpty) {
      if (_error != null) return ErrorRetry(error: _error!, onRetry: _refresh);
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(child: Text(widget.emptyText));
    }
    final footer = _hasMore
        ? const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        : const SizedBox(height: 16);

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 800) _loadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (widget.header != null) SliverToBoxAdapter(child: widget.header),
            if (widget.grid)
              SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.75,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (c, i) => widget.itemBuilder(c, _items, i),
                    childCount: _items.length,
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (c, i) => widget.itemBuilder(c, _items, i),
                  childCount: _items.length,
                ),
              ),
            SliverToBoxAdapter(child: footer),
          ],
        ),
      ),
    );
  }
}

/// Carte d'album pour les grilles.
class AlbumCard extends StatelessWidget {
  final JItem album;
  const AlbumCard({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AlbumScreen(albumId: album.id, title: album.name),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(itemId: album.imageItemId, size: c.maxWidth, radius: 8),
            const SizedBox(height: 6),
            Text(
              album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              album.albumArtist ?? album.artistLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class ErrorRetry extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const ErrorRetry({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}

/// Charge une liste de morceaux une seule fois et l'affiche.
class TrackListLoader extends StatefulWidget {
  final Future<List<JItem>> Function() load;
  final Widget Function(BuildContext context, List<JItem> tracks) builder;
  const TrackListLoader({super.key, required this.load, required this.builder});

  @override
  State<TrackListLoader> createState() => _TrackListLoaderState();
}

class _TrackListLoaderState extends State<TrackListLoader> {
  late Future<List<JItem>> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<JItem>>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return ErrorRetry(
            error: snap.error!,
            onRetry: () => setState(() => _future = widget.load()),
          );
        }
        if (!snap.hasData)
          return const Center(child: CircularProgressIndicator());
        return widget.builder(context, snap.data!);
      },
    );
  }
}
