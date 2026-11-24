import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../state/download_store.dart';
import '../state/player_controller.dart';
import '../state/session.dart';
import 'mini_player.dart';
import 'widgets.dart';

const _kLastQuality = 'download.kbps';

/// Choix proposés : null = fichier original (sans conversion).
const _choices = <int?>[null, 320, 256, 192, 128];

String _qualityLabel(int? kbps) =>
    kbps == null ? 'Originale (sans conversion)' : 'MP3 $kbps kb/s';

/// Demande la qualité puis lance le téléchargement de [tracks] (et garde
/// [playlist] pour l'écoute hors connexion, si fournie).
Future<void> showDownloadDialog(
  BuildContext context, {
  required List<JItem> tracks,
  JItem? playlist,
}) async {
  final store = context.read<DownloadStore>();
  final messenger = ScaffoldMessenger.of(context);
  if (!store.supported || tracks.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final last = prefs.getInt(_kLastQuality) ?? 320;
  if (!context.mounted) return;

  final kbps = await showDialog<int>(
    context: context,
    builder: (_) => _QualityDialog(
      tracks: tracks,
      title: playlist != null
          ? 'Télécharger « ${playlist.displayName} »'
          : tracks.length == 1
          ? 'Télécharger « ${tracks.first.name} »'
          : 'Télécharger ${tracks.length} morceaux',
      initial: last == 0 ? null : last,
    ),
  );
  if (kbps == null) return; // annulé
  await prefs.setInt(_kLastQuality, kbps);
  await store.enqueue(
    tracks,
    kbps: kbps == 0 ? null : kbps,
    playlist: playlist,
  );
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        tracks.length == 1
            ? 'Téléchargement de « ${tracks.first.name} »…'
            : 'Téléchargement de ${tracks.length} morceaux…',
      ),
    ),
  );
}

class _QualityDialog extends StatefulWidget {
  final List<JItem> tracks;
  final String title;
  final int? initial;
  const _QualityDialog({
    required this.tracks,
    required this.title,
    required this.initial,
  });

  @override
  State<_QualityDialog> createState() => _QualityDialogState();
}

class _QualityDialogState extends State<_QualityDialog> {
  late int? _kbps = widget.initial;
  Map<String, int>? _bitrates; // débit des fichiers originaux

  @override
  void initState() {
    super.initState();
    final c = context.read<Session>().client;
    c
        ?.sourceBitrates([for (final t in widget.tracks) t.id])
        .then((b) {
          if (mounted) setState(() => _bitrates = b);
        })
        .catchError((_) {});
  }

  Duration get _totalDuration => widget.tracks.fold(
    Duration.zero,
    (s, t) => s + (t.duration ?? Duration.zero),
  );

  /// Taille estimée pour un débit (kb/s), ou pour l'original.
  String _estimate(int? kbps) {
    if (kbps != null) {
      return '≈ ${formatBytes(_totalDuration.inSeconds * kbps * 1000 / 8)}';
    }
    final b = _bitrates;
    if (b == null) return 'calcul…';
    var bits = 0.0;
    for (final t in widget.tracks) {
      bits += (b[t.id] ?? 1600000) * (t.duration?.inSeconds ?? 0);
    }
    return '≈ ${formatBytes(bits / 8)}';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<DownloadStore>();
    final already = widget.tracks.where((t) => store.isDownloaded(t.id)).length;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Qualité : plus elle est basse, moins les morceaux prennent de '
              'place sur le téléphone.',
            ),
            const SizedBox(height: 8),
            RadioGroup<int>(
              groupValue: _kbps ?? 0,
              onChanged: (v) => setState(() => _kbps = v == 0 ? null : v),
              child: Column(
                children: [
                  for (final k in _choices)
                    RadioListTile<int>(
                      contentPadding: EdgeInsets.zero,
                      value: k ?? 0,
                      title: Text(_qualityLabel(k)),
                      subtitle: Text(_estimate(k)),
                    ),
                ],
              ),
            ),
            if (already > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '$already déjà téléchargé(s) : ils ne seront retéléchargés '
                  'que si la qualité choisie est différente.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(_kbps ?? 0),
          icon: const Icon(Icons.download),
          label: const Text('Télécharger'),
        ),
      ],
    );
  }
}

/// Bandeau de progression des téléchargements en cours.
class DownloadProgress extends StatelessWidget {
  const DownloadProgress({super.key});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DownloadStore>();
    if (!d.busy) return const SizedBox.shrink();
    final cur = d.current;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Téléchargement ${d.done + d.failed + 1} sur ${d.total}'
                    '${d.failed > 0 ? ' (${d.failed} échec(s))' : ''}',
                  ),
                  if (cur != null)
                    Text(
                      cur.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: d.currentProgress < 0 ? null : d.currentProgress,
                  ),
                ],
              ),
            ),
            TextButton(onPressed: d.cancel, child: const Text('Arrêter')),
          ],
        ),
      ),
    );
  }
}

/// Page « Téléchargements » : playlists et morceaux enregistrés sur le
/// téléphone, utilisable sans connexion.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DownloadStore>();
    final tracks = d.allTracks;
    final playlists = d.playlists.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final theme = Theme.of(context);

    Widget section(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        t,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Téléchargements')),
      bottomNavigationBar: const MiniPlayer(),
      body: ListView(
        children: [
          const DownloadProgress(),
          if (tracks.isEmpty && !d.busy)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Aucun morceau téléchargé.\n\nPour écouter sans connexion, '
                'utilisez « Télécharger… » dans le menu ⋮ d\'un morceau ou '
                'd\'une playlist.',
                textAlign: TextAlign.center,
              ),
            ),
          if (playlists.isNotEmpty) section('Playlists'),
          for (final p in playlists)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.queue_music)),
              title: Text(p.name),
              subtitle: Text(
                '${d.tracksOf(p).length} morceau(x) sur ${p.trackIds.length}',
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _DownloadedPlaylistScreen(id: p.id),
                ),
              ),
              trailing: IconButton(
                tooltip: 'Supprimer ce téléchargement',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmRemovePlaylist(context, p),
              ),
            ),
          if (tracks.isNotEmpty) ...[
            section('Tous les morceaux (${tracks.length})'),
            PlayButtons(loadTracks: () async => tracks),
            for (var i = 0; i < tracks.length; i++)
              TrackTile(tracks: tracks, index: i),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

Future<void> _confirmRemovePlaylist(
  BuildContext context,
  DownloadedPlaylist p,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Supprimer « ${p.name} » du téléphone ?'),
      content: const Text(
        'Les morceaux téléchargés de cette playlist seront supprimés du '
        'téléphone (sauf ceux d\'une autre playlist téléchargée). La playlist '
        'reste sur le serveur.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  if (ok == true && context.mounted) {
    await context.read<DownloadStore>().removePlaylist(p.id);
  }
}

class _DownloadedPlaylistScreen extends StatelessWidget {
  final String id;
  const _DownloadedPlaylistScreen({required this.id});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DownloadStore>();
    final p = d.playlists[id];
    if (p == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Téléchargement supprimé.')),
      );
    }
    final tracks = d.tracksOf(p);
    return Scaffold(
      appBar: AppBar(title: Text(p.name)),
      bottomNavigationBar: const MiniPlayer(),
      body: ListView(
        children: [
          const DownloadProgress(),
          if (tracks.isNotEmpty) PlayButtons(loadTracks: () async => tracks),
          for (var i = 0; i < tracks.length; i++)
            TrackTile(tracks: tracks, index: i),
        ],
      ),
    );
  }
}

/// Section « Téléchargements » de la page Paramètres.
class DownloadsSettings extends StatelessWidget {
  const DownloadsSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DownloadStore>();
    if (!d.supported) {
      return const ListTile(
        leading: Icon(Icons.download_outlined),
        title: Text(
          'Téléchargements : disponibles dans l\'application Android',
        ),
      );
    }
    return Column(
      children: [
        const DownloadProgress(),
        FutureBuilder<int>(
          // Recalculé à chaque changement des fichiers.
          key: ValueKey(d.revision),
          future: d.diskUsage(),
          builder: (context, snap) => ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: Text(
              snap.hasData
                  ? 'Espace utilisé : ${formatBytes(snap.data!)}'
                  : 'Espace utilisé : calcul…',
            ),
            subtitle: Text(
              '${d.entries.length} morceau(x), '
              '${d.playlists.length} playlist(s) téléchargé(s)',
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.download_done),
          title: const Text('Voir les téléchargements'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const DownloadsScreen())),
        ),
        ListTile(
          leading: Icon(
            Icons.delete_sweep_outlined,
            color: Theme.of(context).colorScheme.error,
          ),
          title: const Text('Tout supprimer'),
          enabled: d.entries.isNotEmpty || d.busy,
          onTap: () => _confirmClearAll(context),
        ),
      ],
    );
  }
}

Future<void> _confirmClearAll(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer tous les téléchargements ?'),
      content: const Text(
        'Tous les morceaux et playlists téléchargés seront effacés du '
        'téléphone. Ils restent sur le serveur et pourront être retéléchargés.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Tout supprimer'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  // La lecture en cours peut utiliser un fichier supprimé : on l'arrête.
  final pc = context.read<PlayerController>();
  final d = context.read<DownloadStore>();
  if (pc.current != null && d.isDownloaded(pc.current!.id)) await pc.stop();
  await d.clearAll();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Tous les téléchargements sont supprimés')),
    );
  }
}
