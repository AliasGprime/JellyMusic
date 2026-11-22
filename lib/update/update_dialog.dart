import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';

import 'updater.dart';

/// Vérifie les mises à jour. Au démarrage ([manual] = false), ne dit rien
/// s'il n'y en a pas ou si le réseau échoue ; en vérification manuelle,
/// affiche toujours un résultat.
Future<void> checkForUpdates(
  BuildContext context, {
  bool manual = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  AppRelease? release;
  try {
    release = await Updater.check(manual: manual);
  } catch (e) {
    if (manual) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Vérification impossible : $e')),
      );
    }
    return;
  }
  if (!context.mounted) return;
  if (release == null) {
    if (manual) {
      final v = await Updater.currentVersion();
      messenger?.showSnackBar(
        SnackBar(content: Text('JellyMusic est à jour (version $v).')),
      );
    }
    return;
  }
  await showUpdateDialog(context, release);
}

/// Les notes de version sont écrites en Markdown pour GitHub ; on retire
/// les symboles de mise en forme pour les afficher proprement.
String plainNotes(String md) => md
    .split('\n')
    .map(
      (l) => l
          .replaceFirst(RegExp(r'^\s*#+\s*'), '')
          .replaceFirst(RegExp(r'^\s*[-*]\s+'), '• ')
          .replaceAll('**', '')
          .replaceAll('__', '')
          .replaceAll('`', ''),
    )
    .join('\n')
    .trim();

Future<void> showUpdateDialog(BuildContext context, AppRelease r) async {
  final installed = await Updater.currentVersion();
  if (!context.mounted) return;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.system_update),
      title: const Text('Nouvelle version disponible'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Version ${r.version} (vous avez la $installed)'
              '${r.apkSize > 0 ? ' · ${(r.apkSize / 1048576).toStringAsFixed(1)} Mo' : ''}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (r.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(plainNotes(r.notes)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('skip'),
          child: const Text('Ignorer'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop('later'),
          child: const Text('Plus tard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop('update'),
          child: const Text('Mettre à jour'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (choice == 'skip') {
    await Updater.skip(r.version);
  } else if (choice == 'update') {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(release: r),
    );
  }
}

class _DownloadDialog extends StatefulWidget {
  final AppRelease release;
  const _DownloadDialog({required this.release});

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  StreamSubscription<OtaEvent>? _sub;
  double? _progress;
  String _status = 'Téléchargement…';
  String? _error;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    setState(() {
      _error = null;
      _progress = null;
      _status = 'Téléchargement…';
    });
    try {
      _sub = OtaUpdate()
          .execute(
            widget.release.apkUrl,
            destinationFilename: 'jellymusic-${widget.release.version}.apk',
            sha256checksum: widget.release.sha256,
          )
          .listen(_onEvent, onError: (e) => _fail('$e'));
    } catch (e) {
      _fail('$e');
    }
  }

  void _onEvent(OtaEvent e) {
    if (!mounted) return;
    switch (e.status) {
      case OtaStatus.DOWNLOADING:
        final p = double.tryParse(e.value ?? '');
        setState(() {
          _progress = p == null ? null : p / 100;
          _status = p == null
              ? 'Téléchargement…'
              : 'Téléchargement… ${p.round()} %';
        });
      case OtaStatus.INSTALLING:
      case OtaStatus.INSTALLATION_DONE:
        setState(() {
          _installing = true;
          _progress = 1;
          _status =
              'Téléchargement terminé. Confirmez l\'installation dans la '
              'fenêtre d\'Android.\n\nSi Android vous a d\'abord demandé une '
              'autorisation, touchez « Installer » une fois celle-ci donnée.';
        });
      case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
        _fail(
          'Android doit autoriser JellyMusic à installer des applications. '
          'Acceptez la demande, puis réessayez.',
        );
      case OtaStatus.CHECKSUM_ERROR:
        _fail('Le fichier téléchargé est corrompu. Réessayez.');
      case OtaStatus.CANCELED:
        _fail('Téléchargement annulé.');
      default:
        _fail('Échec de la mise à jour (${e.status.name}) ${e.value ?? ''}');
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() => _error = msg);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Mise à jour ${widget.release.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error == null) ...[
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 12),
            Text(_status),
          ] else
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      actions: [
        if (_error != null)
          TextButton(onPressed: _start, child: const Text('Réessayer')),
        // La toute première fois, Android demande d'autoriser JellyMusic à
        // installer des applications ; une fois l'autorisation donnée,
        // l'installateur ne revient pas seul. Ce bouton le relance.
        if (_installing && _error == null)
          FilledButton(
            onPressed: () {
              _sub?.cancel();
              _installing = false;
              _start();
            },
            child: const Text('Installer'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_error != null || _installing ? 'Fermer' : 'Annuler'),
        ),
      ],
    );
  }
}
