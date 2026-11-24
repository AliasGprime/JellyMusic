import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../state/equalizer_store.dart';
import '../state/player_controller.dart';
import '../state/session.dart';
import 'mini_player.dart';

class SettingsScreen extends StatelessWidget {
  final VoidCallback? onLogout;
  const SettingsScreen({super.key, this.onLogout});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final theme = Theme.of(context);

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      bottomNavigationBar: const MiniPlayer(),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          section('Compte'),
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(session.username.isEmpty ? '—' : session.username),
            subtitle: Text(session.serverUrl),
          ),
          if (onLogout != null)
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Se déconnecter'),
              onTap: () {
                Navigator.of(context).pop();
                onLogout!();
              },
            ),
          section('Lecture'),
          const QualityPanel(),
          const Divider(indent: 16, endIndent: 16),
          const NormalizePanel(),
          const Divider(indent: 16, endIndent: 16),
          const CrossfadePanel(),
          section('Égaliseur'),
          const EqualizerPanel(),
          section('À propos'),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('JellyMusic'),
              subtitle: Text(
                snap.hasData ? 'Version ${snap.data!.version}' : '',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Qualité de lecture : fichier original (sans conversion) ou MP3 compressé
/// au débit choisi.
class QualityPanel extends StatelessWidget {
  const QualityPanel({super.key});

  static String label(int? kbps) => kbps == null
      ? 'Originale (sans conversion)'
      : 'MP3 $kbps kb/s${kbps == 320 ? ' (meilleur MP3)' : ''}';

  static String help(int? kbps) => switch (kbps) {
    null =>
      'Vos fichiers tels quels (ex. FLAC sans perte, environ 1,6 Mb/s) : '
          'meilleure qualité, chargement en avance et déplacement instantané '
          'dans le morceau. Idéal à la maison.',
    320 || 256 =>
      'Converti en MP3 par Jellyfin pendant l\'écoute : très bonne qualité, '
          'environ 5 fois moins de données que l\'original.',
    _ =>
      'Converti en MP3 par Jellyfin pendant l\'écoute : qualité correcte, '
          'pour une connexion lente ou les données mobiles.',
  };

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<int>(
            // Le menu ne prend pas null comme valeur : 0 = original.
            initialValue: pc.streamKbps ?? 0,
            decoration: const InputDecoration(
              labelText: 'Qualité de lecture',
              prefixIcon: Icon(Icons.high_quality_outlined),
              border: OutlineInputBorder(),
            ),
            items: [
              for (final k in PlayerController.qualityChoices)
                DropdownMenuItem(value: k ?? 0, child: Text(label(k))),
            ],
            onChanged: (v) => pc.setStreamKbps(v == null || v == 0 ? null : v),
          ),
          const SizedBox(height: 6),
          Text(
            '${help(pc.streamKbps)}\nS\'applique aux morceaux lancés ensuite. '
            '${kIsWeb ? 'Réglage gardé dans ce navigateur.' : 'Réglage gardé sur ce téléphone.'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Normalisation du volume : tous les morceaux au même niveau, avec un gain
/// de compensation.
class NormalizePanel extends StatelessWidget {
  const NormalizePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    final theme = Theme.of(context);
    final on = pc.normalize;
    final g = pc.normalizeGain;
    final label = '+${g.toStringAsFixed(g == g.roundToDouble() ? 0 : 1)} dB';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.graphic_eq),
          title: const Text('Normalisation du volume'),
          subtitle: const Text(
            'Les morceaux jouent tous à peu près au même volume, d\'après '
            'les mesures faites par Jellyfin.',
          ),
          value: on,
          onChanged: pc.setNormalize,
        ),
        // Sur téléphone, le son ne peut pas être amplifié : pas de gain de
        // compensation (seuls les morceaux trop forts sont baissés).
        if (kIsWeb)
          Opacity(
            opacity: on ? 1 : 0.5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const SizedBox(
                    width: 120,
                    child: Text('Gain de compensation'),
                  ),
                  Expanded(
                    child: Slider(
                      value: g,
                      max: 12,
                      divisions: 24,
                      label: label,
                      onChanged: on ? pc.setNormalizeGain : null,
                    ),
                  ),
                  SizedBox(width: 72, child: Text(label)),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '${kIsWeb ? 'La normalisation baisse surtout les morceaux trop forts : le gain de compensation remonte l\'ensemble (un limiteur évite la saturation).' : 'Sur téléphone, les morceaux trop forts sont baissés au niveau des autres.'} '
            'Morceaux pas encore mesurés par Jellyfin : '
            'correction moyenne de votre bibliothèque '
            '(${pc.fallbackGain.toStringAsFixed(1)} dB). '
            '${kIsWeb ? 'Réglage gardé dans ce navigateur.' : 'Réglage gardé sur ce téléphone.'}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Fondu enchaîné entre les morceaux (0 à 12 secondes).
class CrossfadePanel extends StatelessWidget {
  const CrossfadePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    final theme = Theme.of(context);
    if (!pc.crossfadeSupported) {
      return const ListTile(
        leading: Icon(Icons.swap_horiz),
        title: Text('Fondu enchaîné : disponible dans la version web'),
      );
    }
    final s = pc.crossfadeSeconds;
    final on = s > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.swap_horiz),
          title: const Text('Fondu enchaîné'),
          subtitle: const Text(
            'Le morceau qui se termine baisse pendant que le suivant monte : '
            'aucun silence entre les chansons.',
          ),
          value: on,
          onChanged: (v) => pc.setCrossfade(v ? 6 : 0),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(
            children: [
              const SizedBox(width: 120, child: Text('Durée')),
              Expanded(
                child: Slider(
                  value: s.toDouble(),
                  max: 12,
                  divisions: 12,
                  label: on ? '$s s' : 'Désactivé',
                  onChanged: (v) => pc.setCrossfade(v.round()),
                ),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  on ? '$s s' : 'Désactivé',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Text(
            'Pas de fondu quand vous changez de morceau vous-même, en '
            'répétition d\'un seul morceau ou pendant une boucle A-B. '
            'Réglage gardé dans ce navigateur.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Réglages de l'égaliseur : activation, préréglage, 10 bandes, pré-ampli.
class EqualizerPanel extends StatelessWidget {
  const EqualizerPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final eq = context.watch<EqualizerStore>();
    final theme = Theme.of(context);

    if (!eq.supported) {
      return const ListTile(
        leading: Icon(Icons.equalizer),
        title: Text('Disponible dans la version web'),
        subtitle: Text(
          'L\'égaliseur fonctionne dans le navigateur. Sur Android, utilisez '
          'l\'égaliseur du téléphone.',
        ),
      );
    }
    if (eq.loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final s = eq.settings;
    final presetNames = [...eqPresets.keys, eqCustom];
    final storageText = eq.saving
        ? 'Enregistrement…'
        : eq.storage == EqStorage.account
        ? 'Réglages enregistrés sur votre compte Jellyfin : vous les '
              'retrouvez sur tous vos navigateurs.'
        : 'Le serveur n\'a pas accepté l\'enregistrement : réglages gardés '
              'dans ce navigateur seulement (toujours séparés par compte).';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.equalizer),
          title: const Text('Activer l\'égaliseur'),
          value: s.enabled,
          onChanged: (v) => eq.update(s.copyWith(enabled: v)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: presetNames.contains(s.preset)
                      ? s.preset
                      : eqCustom,
                  decoration: const InputDecoration(
                    labelText: 'Préréglage',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final n in presetNames)
                      DropdownMenuItem(
                        value: n,
                        enabled: n != eqCustom,
                        child: Text(n),
                      ),
                  ],
                  onChanged: (n) {
                    if (n != null && n != eqCustom) eq.applyPreset(n);
                  },
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: eq.reset,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Remettre à zéro'),
              ),
            ],
          ),
        ),
        // Les 10 bandes : curseurs verticaux.
        Opacity(
          opacity: s.enabled ? 1 : 0.5,
          child: SizedBox(
            height: 260,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  for (var i = 0; i < eqBandLabels.length; i++)
                    Expanded(
                      child: _Band(
                        label: eqBandLabels[i],
                        value: s.gains[i],
                        onChanged: (v) => eq.setBand(i, v),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              const SizedBox(width: 120, child: Text('Pré-amplification')),
              Expanded(
                child: Slider(
                  value: s.preamp,
                  min: eqMinDb,
                  max: 6,
                  divisions: 36,
                  label: _db(s.preamp),
                  onChanged: (v) => eq.update(s.copyWith(preamp: v)),
                ),
              ),
              SizedBox(width: 56, child: Text(_db(s.preamp))),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'Astuce : si le son sature quand vous montez des bandes, baissez '
            'la pré-amplification.\n$storageText',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

String _db(double v) =>
    '${v > 0 ? '+' : ''}${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)} dB';

class _Band extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  const _Band({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.labelSmall;
    return Column(
      children: [
        Text('${value > 0 ? '+' : ''}${value.round()}', style: small),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: value,
                min: eqMinDb,
                max: eqMaxDb,
                divisions: 48,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        Text(label, style: small),
        Text('Hz', style: small?.copyWith(fontSize: 9)),
      ],
    );
  }
}
