import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/download_store.dart';
import '../state/player_controller.dart';
import '../state/session.dart';
import 'album_screen.dart';
import 'downloads.dart';
import 'layout.dart';
import 'offline_library.dart';
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
    // Pochette enregistrée avec un téléchargement : affichée même hors
    // connexion.
    final local = context.select<DownloadStore, String?>(
      (d) => d.coverFor(itemId),
    );
    if (local != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.file(
          File(local),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => placeholder,
        ),
      );
    }
    // Hors connexion : rien n'est demandé au serveur.
    final offline = context.select<Session, bool>((s) => s.offline);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null || offline
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
      subtitle: _DownloadStatus(
        trackId: t.id,
        child: Row(
          children: [
            // Morceau déjà téléchargé sur le téléphone.
            if (context.select<DownloadStore, bool>(
              (d) => d.isDownloaded(t.id),
            ))
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Tooltip(
                  message: 'Téléchargé',
                  child: Icon(
                    Icons.download_done,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            Flexible(
              child: Text(
                [
                  t.artistLine,
                  // Sur ordinateur, il y a la place d'afficher l'album.
                  if (isWide(context) && showCover) t.album ?? '',
                  formatDuration(t.duration),
                ].where((s) => s.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
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

/// Sous-titre d'un morceau, avec l'état de son téléchargement : sablier s'il
/// attend son tour, barre de progression pendant le téléchargement.
class _DownloadStatus extends StatelessWidget {
  final String trackId;
  final Widget child;
  const _DownloadStatus({required this.trackId, required this.child});

  @override
  Widget build(BuildContext context) {
    final (queued, progress) = context.select<DownloadStore, (bool, double?)>(
      (d) => (d.isQueued(trackId), d.progressOf(trackId)),
    );
    if (!queued && progress == null) return child;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        const SizedBox(height: 4),
        if (progress != null)
          Row(
            children: [
              Icon(Icons.downloading, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: LinearProgressIndicator(
                  value: progress < 0 ? null : progress,
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (progress >= 0)
                SizedBox(
                  width: 40,
                  child: Text(
                    '${(progress * 100).round()} %',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          )
        else
          Row(
            children: [
              Icon(
                Icons.hourglass_empty,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                'En attente de téléchargement',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
      ],
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
    final offline = context.read<Session>().offline;
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
          case 'download':
            showDownloadDialog(context, tracks: [track]);
          case 'canceldl':
            final cancelled = context.read<DownloadStore>().cancelTrack(
              track.id,
            );
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  cancelled
                      ? 'Téléchargement annulé'
                      : 'Trop tard : ce morceau venait d\'être téléchargé',
                ),
              ),
            );
          case 'undownload':
            context.read<DownloadStore>().remove(track.id);
            messenger.showSnackBar(
              const SnackBar(content: Text('Téléchargement supprimé')),
            );
          case 'album':
            if (offline) {
              openOfflineAlbum(context, track);
            } else if (track.albumId != null) {
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
        if (!offline)
          const PopupMenuItem(
            value: 'playlist',
            child: Text('Ajouter à une playlist…'),
          ),
        if (onRemove != null && !offline)
          const PopupMenuItem(
            value: 'remove',
            child: Text('Retirer de la playlist'),
          ),
        if (context.read<DownloadStore>().supported)
          ?(context.read<DownloadStore>().isQueued(track.id) ||
                  context.read<DownloadStore>().progressOf(track.id) != null)
              ? const PopupMenuItem(
                  value: 'canceldl',
                  child: Text('Annuler ce téléchargement'),
                )
              : context.read<DownloadStore>().isDownloaded(track.id)
              ? const PopupMenuItem(
                  value: 'undownload',
                  child: Text('Supprimer le téléchargement'),
                )
              : offline
              ? null
              : const PopupMenuItem(
                  value: 'download',
                  child: Text('Télécharger…'),
                ),
        if (track.albumId != null || offline)
          const PopupMenuItem(value: 'album', child: Text('Voir l\'album')),
      ],
    );
  }
}

/// Boutons « Lire » et « Aléatoire » en haut d'une liste de morceaux.
class PlayButtons extends StatelessWidget {
  final Future<List<JItem>> Function() loadTracks;

  /// Morceaux déjà mélangés pour « Aléatoire » (sinon : [loadTracks]
  /// mélangés ici).
  final Future<List<JItem>> Function()? loadShuffled;
  const PlayButtons({super.key, required this.loadTracks, this.loadShuffled});

  Future<void> _play(BuildContext context, bool shuffle) async {
    final player = context.read<PlayerController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final premixed = shuffle && loadShuffled != null;
      final tracks = await (premixed ? loadShuffled!() : loadTracks());
      if (tracks.isEmpty) return;
      await player.playItems(tracks, shuffle: shuffle && !premixed);
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
              // Petit écran : le texte rapetisse au lieu de passer à la ligne.
              label: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Lire', maxLines: 1),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () => _play(context, true),
              icon: const Icon(Icons.shuffle),
              // Petit écran : le texte rapetisse au lieu de passer à la ligne.
              label: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Aléatoire', maxLines: 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Liste qui charge la bibliothèque par pages au fil du défilement.
class PagedItems extends StatefulWidget {
  /// Charge une page ; [letter] est la lettre choisie dans la barre A-Z
  /// (null : tout).
  final Future<ItemsPage> Function(int start, int limit, String? letter) fetch;
  final Widget Function(BuildContext context, List<JItem> items, int index)
  itemBuilder;
  final bool grid;
  final Widget? header;

  /// En-tête qui dépend de la lettre choisie (prioritaire sur [header]).
  final Widget Function(String? letter)? headerFor;
  final String emptyText;

  /// Affiche la barre de lettres # A … Z à droite pour filtrer la liste.
  final bool alphabet;

  const PagedItems({
    super.key,
    required this.fetch,
    required this.itemBuilder,
    this.grid = false,
    this.header,
    this.headerFor,
    this.emptyText = 'Rien ici pour l\'instant.',
    this.alphabet = false,
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

  /// Lettre choisie dans la barre A-Z (null : tout).
  String? _letter;

  /// Augmente à chaque nouveau filtre : une réponse arrivée trop tard (pour
  /// l'ancienne lettre) est ignorée.
  int _generation = 0;

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final gen = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.fetch(_items.length, _pageSize, _letter);
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.items.isEmpty ? _items.length : page.total;
      });
    } catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _generation++;
      _loading = false;
      _items.clear();
      _total = -1;
    });
    await _loadMore();
  }

  /// Choisit une lettre ; la même lettre une 2e fois : retour à tout.
  void _pickLetter(String letter) {
    _letter = _letter == letter ? null : letter;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final list = _buildList(context);
    if (!widget.alphabet) return list;
    return Row(
      children: [
        Expanded(child: list),
        LetterBar(selected: _letter, onPick: _pickLetter),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    if (_items.isEmpty) {
      if (_error != null) return ErrorRetry(error: _error!, onRetry: _refresh);
      if (_loading) return const Center(child: CircularProgressIndicator());
      final header = widget.headerFor?.call(_letter);
      return Column(
        children: [
          ?header,
          Expanded(
            child: Center(
              child: Text(
                _letter == null
                    ? widget.emptyText
                    : _letter == '#'
                    ? 'Rien qui commence par un chiffre ou un symbole.'
                    : 'Rien qui commence par « $_letter ».',
              ),
            ),
          ),
        ],
      );
    }
    final header = widget.headerFor?.call(_letter) ?? widget.header;
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
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (header != null) SliverToBoxAdapter(child: header),
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

const _letters = [
  '#',
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', //
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

/// Barre verticale # A … Z : un clic filtre la liste sur cette lettre, un
/// 2e clic sur la même lettre réaffiche tout.
class LetterBar extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onPick;
  const LetterBar({super.key, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 30,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            for (final l in _letters)
              Expanded(
                child: Tooltip(
                  message: l == selected
                      ? 'Tout afficher'
                      : l == '#'
                      ? 'Chiffres et symboles'
                      : 'Commence par $l',
                  waitDuration: const Duration(milliseconds: 600),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => onPick(l),
                    child: Center(
                      child: Container(
                        width: 24,
                        constraints: const BoxConstraints(maxHeight: 24),
                        decoration: l == selected
                            ? BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                              )
                            : null,
                        alignment: Alignment.center,
                        child: FittedBox(
                          child: Text(
                            l,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: l == selected
                                  ? scheme.onPrimary
                                  : selected == null
                                  ? scheme.onSurfaceVariant
                                  : scheme.onSurfaceVariant.withValues(
                                      alpha: 0.6,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Carte d'album pour les grilles.
class AlbumCard extends StatelessWidget {
  final JItem album;

  /// Hors connexion : pochette à afficher et action au toucher.
  final String? coverId;
  final VoidCallback? onTap;
  const AlbumCard({super.key, required this.album, this.coverId, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap:
          onTap ??
          () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AlbumScreen(albumId: album.id, title: album.name),
            ),
          ),
      child: LayoutBuilder(
        builder: (context, c) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CoverImage(
              itemId: coverId ?? album.imageItemId,
              size: c.maxWidth,
              radius: 8,
            ),
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
            // Hors connexion : les morceaux téléchargés restent écoutables.
            if (context.select<DownloadStore, bool>(
              (d) => d.supported && d.entries.isNotEmpty,
            )) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                ),
                icon: const Icon(Icons.download_done),
                label: const Text('Écouter les téléchargements'),
              ),
            ],
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
