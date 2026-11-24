import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/player_controller.dart';
import 'album_screen.dart';
import 'layout.dart';
import 'playlist_picker.dart';
import 'widgets.dart';

/// Lecteur plein écran (une colonne sur téléphone, deux sur ordinateur).
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  static Route route() => PageRouteBuilder(
    pageBuilder: (_, __, ___) => const PlayerScreen(),
    transitionsBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(anim),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    final t = pc.current;
    final theme = Theme.of(context);

    if (t == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold();
    }

    void openAlbum() {
      if (t.albumId == null) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              AlbumScreen(albumId: t.albumId!, title: t.album ?? ''),
        ),
      );
    }

    Widget cover(double size) => GestureDetector(
      onTap: openAlbum,
      child: Hero(
        tag: 'cover',
        child: CoverImage(
          itemId: t.imageItemId,
          size: size,
          radius: 16,
          maxWidth: 900,
        ),
      ),
    );

    final info = <Widget>[
      Text(
        t.name,
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.headlineSmall,
      ),
      const SizedBox(height: 4),
      Text(
        t.artistLine,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 8),
      // Version écoutée (téléchargée, originale, MP3…) : touchez pour changer.
      Center(
        child: ActionChip(
          avatar: Icon(
            pc.currentIsLocal
                ? Icons.download_done
                : Icons.high_quality_outlined,
            size: 18,
          ),
          label: Text(pc.currentSourceLabel),
          tooltip: 'Changer la qualité de ce morceau',
          onPressed: () => showSourceSheet(context),
        ),
      ),
      if (pc.lastError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            pc.lastError!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      const SizedBox(height: 16),
      SeekBar(player: pc.player, fallback: t.duration),
      const SizedBox(height: 8),
      PlayerControls(pc: pc),
      const SizedBox(height: 4),
      _SeekAndLoopControls(pc: pc),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: VolumeControl(pc: pc),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Fermer',
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(t.album ?? '', style: theme.textTheme.titleSmall),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Ajouter à une playlist',
            icon: const Icon(Icons.playlist_add),
            onPressed: () => showAddToPlaylist(context, tracks: [t]),
          ),
          IconButton(
            tooltip: 'File d\'attente',
            icon: const Icon(Icons.queue_music),
            onPressed: () => showQueueSheet(context),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            if (c.maxWidth >= wideBreakpoint) {
              // Ordinateur : pochette à gauche, informations à droite.
              // Pochette limitée par la hauteur ET par la largeur restante
              // (colonne d'informations 460 + marges), sinon ça déborde.
              final size = [
                c.maxHeight - 64,
                c.maxWidth - 460 - 48 - 64,
                560.0,
              ].reduce((x, y) => x < y ? x : y).clamp(160.0, 560.0);
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      cover(size),
                      const SizedBox(width: 48),
                      SizedBox(
                        width: 460,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: info,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            final size = (c.maxWidth - 48).clamp(120.0, c.maxHeight * 0.45);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(),
                  cover(size),
                  const Spacer(),
                  ...info,
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Reculer / avancer de 10 s et boucle A-B (lecteur plein écran).
class _SeekAndLoopControls extends StatelessWidget {
  final PlayerController pc;
  const _SeekAndLoopControls({required this.pc});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = pc.abStart, b = pc.abEnd;

    final String label;
    final String tooltip;
    final Widget abButton;
    if (a == null) {
      label = 'A-B';
      tooltip = 'Boucle A-B : appuyez pour marquer le début (A)';
      abButton = OutlinedButton(onPressed: pc.pressAb, child: Text(label));
    } else if (b == null) {
      label = 'A-…';
      tooltip = 'Appuyez pour marquer la fin (B) et lancer la boucle';
      abButton = FilledButton.tonal(onPressed: pc.pressAb, child: Text(label));
    } else {
      label = 'A-B';
      tooltip = 'Boucle active : appuyez pour l\'arrêter';
      abButton = FilledButton(onPressed: pc.pressAb, child: Text(label));
    }

    final status = a == null
        ? null
        : b == null
        ? 'A : ${formatDuration(a)} — appuyez à nouveau pour B'
        : 'Boucle ${formatDuration(a)} → ${formatDuration(b)}';

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Reculer de 10 secondes',
              iconSize: 30,
              icon: const Icon(Icons.replay_10),
              onPressed: () => pc.seekBy(-10),
            ),
            const SizedBox(width: 16),
            Tooltip(
              message: tooltip,
              child: SizedBox(width: 84, child: abButton),
            ),
            const SizedBox(width: 16),
            IconButton(
              tooltip: 'Avancer de 10 secondes',
              iconSize: 30,
              icon: const Icon(Icons.forward_10),
              onPressed: () => pc.seekBy(10),
            ),
          ],
        ),
        SizedBox(
          height: 20,
          child: status == null
              ? null
              : Text(
                  status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: b == null ? scheme.onSurfaceVariant : scheme.primary,
                  ),
                ),
        ),
      ],
    );
  }
}

/// Choix de la version du morceau en cours : téléchargée, originale ou MP3.
void showSourceSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (context) {
      final pc = context.watch<PlayerController>();
      final t = pc.current;
      final dl = t == null ? null : pc.downloads?.entries[t.id];
      final override = pc.currentHasOverride;
      Widget option({
        required String title,
        String? subtitle,
        required IconData icon,
        required bool selected,
        required VoidCallback onTap,
      }) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: selected ? const Icon(Icons.check) : null,
        selected: selected,
        onTap: () {
          Navigator.of(context).pop();
          onTap();
        },
      );
      return ListView(
        shrinkWrap: true,
        // Au-dessus des boutons d'Android.
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewPadding.bottom,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Qualité de ce morceau',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (dl != null)
            option(
              title: 'Version téléchargée',
              subtitle:
                  '${PlayerController.qualityName(dl.kbps)} · sur le téléphone, '
                  'sans données',
              icon: Icons.download_done,
              selected: !override,
              onTap: () => pc.setCurrentSource(useDownload: true),
            ),
          for (final k in PlayerController.qualityChoices)
            option(
              title: k == null ? 'Originale (sans conversion)' : 'MP3 $k kb/s',
              subtitle: k == null ? 'Meilleure qualité, plus de données' : null,
              icon: k == null ? Icons.high_quality : Icons.music_note_outlined,
              selected: override
                  ? pc.currentOverrideKbps == k
                  : dl == null && pc.streamKbps == k,
              onTap: () => pc.setCurrentSource(kbps: k),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              'Ne change que ce morceau. Les suivants gardent la version '
              'téléchargée en priorité, sinon la qualité des Paramètres.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );
    },
  );
}

void showQueueSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => const _QueueSheet(),
  );
}

/// Barre de progression du morceau. [compact] : version pour la barre de
/// lecture « ordinateur », avec les temps de part et d'autre.
/// Molette de la souris au-dessus de [child] : [onStep] reçoit +1 (vers le
/// haut) ou -1 (vers le bas). La page derrière ne défile pas.
class MouseWheel extends StatefulWidget {
  final Widget child;
  final void Function(int direction) onStep;
  const MouseWheel({super.key, required this.child, required this.onStep});

  @override
  State<MouseWheel> createState() => _MouseWheelState();
}

class _MouseWheelState extends State<MouseWheel> {
  // Un cran de molette ≈ 100 px ; un pavé tactile envoie plein de petits
  // déplacements, qu'on cumule pour ne pas sauter trop vite.
  static const _threshold = 50.0;
  double _acc = 0;

  void _onScroll(double dy) {
    if (_acc != 0 && dy.sign != _acc.sign) _acc = 0;
    _acc += dy;
    if (_acc.abs() < _threshold) return;
    widget.onStep(_acc < 0 ? 1 : -1);
    _acc = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        final dy = event.scrollDelta.dy;
        if (dy == 0) return;
        GestureBinding.instance.pointerSignalResolver.register(
          event,
          (_) => _onScroll(dy),
        );
      },
      child: widget.child,
    );
  }
}

class SeekBar extends StatefulWidget {
  final AudioPlayer player;
  final Duration? fallback;
  final bool compact;
  const SeekBar({
    super.key,
    required this.player,
    this.fallback,
    this.compact = false,
  });

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragValue;

  /// Molette : avance ou recule de 10 secondes.
  void _wheel(int direction) {
    final player = widget.player;
    final dur = player.duration ?? widget.fallback;
    if (dur == null || dur == Duration.zero) return;
    var to = player.position + Duration(seconds: 10 * direction);
    if (to < Duration.zero) to = Duration.zero;
    if (to > dur) to = dur;
    player.seek(to);
  }

  @override
  Widget build(BuildContext context) {
    return MouseWheel(onStep: _wheel, child: _buildBar(context));
  }

  Widget _buildBar(BuildContext context) {
    final player = widget.player;
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snap) {
        final dur = player.duration ?? widget.fallback ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final pos = (snap.data ?? Duration.zero).inMilliseconds.toDouble();
        final value = (_dragValue ?? pos).clamp(0.0, max > 0 ? max : 1.0);
        // Partie déjà téléchargée (mise en mémoire tampon), affichée en
        // plus clair devant la position de lecture.
        final buffered = player.bufferedPosition.inMilliseconds
            .toDouble()
            .clamp(0.0, max > 0 ? max : 1.0);
        final scheme = Theme.of(context).colorScheme;
        final slider = Slider(
          value: value,
          max: max > 0 ? max : 1.0,
          secondaryTrackValue: buffered,
          secondaryActiveColor: scheme.primary.withValues(alpha: 0.45),
          onChanged: max > 0 ? (v) => setState(() => _dragValue = v) : null,
          onChangeEnd: (v) {
            player.seek(Duration(milliseconds: v.round()));
            setState(() => _dragValue = null);
          },
        );
        final posText = Text(
          formatDuration(Duration(milliseconds: value.round())),
          style: Theme.of(context).textTheme.bodySmall,
        );
        final durText = Text(
          formatDuration(dur),
          style: Theme.of(context).textTheme.bodySmall,
        );
        if (widget.compact) {
          return Row(
            children: [
              SizedBox(
                width: 44,
                child: Align(alignment: Alignment.centerRight, child: posText),
              ),
              Expanded(child: slider),
              SizedBox(width: 44, child: durText),
            ],
          );
        }
        return Column(
          children: [
            slider,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [posText, durText],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Boutons aléatoire / précédent / lecture / suivant / répéter.
class PlayerControls extends StatelessWidget {
  final PlayerController pc;
  final bool compact;
  const PlayerControls({super.key, required this.pc, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final player = pc.player;
    final loop = player.loopMode;
    final skipSize = compact ? 28.0 : 40.0;
    final playBox = compact ? 48.0 : 72.0;
    return Row(
      mainAxisAlignment: compact
          ? MainAxisAlignment.center
          : MainAxisAlignment.spaceEvenly,
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        _ModeButton(
          active: player.shuffleModeEnabled,
          tooltip: player.shuffleModeEnabled
              ? 'Aléatoire : activé'
              : 'Aléatoire : désactivé',
          icon: Icons.shuffle,
          onPressed: pc.toggleShuffle,
        ),
        IconButton(
          tooltip: 'Précédent',
          iconSize: skipSize,
          icon: const Icon(Icons.skip_previous),
          onPressed: pc.previous,
        ),
        StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, snap) {
            final state = snap.data;
            final loading =
                state?.processingState == ProcessingState.loading ||
                state?.processingState == ProcessingState.buffering;
            final playing = state?.playing ?? false;
            return SizedBox(
              width: playBox,
              height: playBox,
              child: loading && playing
                  ? Padding(
                      padding: EdgeInsets.all(playBox / 4),
                      child: const CircularProgressIndicator(),
                    )
                  : IconButton.filled(
                      tooltip: playing ? 'Pause' : 'Lecture',
                      iconSize: playBox * 0.6,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: playing ? player.pause : player.play,
                    ),
            );
          },
        ),
        IconButton(
          tooltip: 'Suivant',
          iconSize: skipSize,
          icon: const Icon(Icons.skip_next),
          onPressed: player.hasNext ? player.seekToNext : null,
        ),
        _ModeButton(
          active: loop != LoopMode.off,
          tooltip: switch (loop) {
            LoopMode.off => 'Répéter : désactivé',
            LoopMode.all => 'Répéter : toute la file',
            LoopMode.one => 'Répéter : ce morceau',
          },
          icon: loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
          onPressed: pc.cycleRepeat,
        ),
      ],
    );
  }
}

/// Bouton de mode (aléatoire, répétition) : bien visible quand il est actif,
/// avec un fond coloré et un petit point dessous.
class _ModeButton extends StatelessWidget {
  final bool active;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  const _ModeButton({
    required this.active,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = active
        ? IconButton.filled(
            tooltip: tooltip,
            isSelected: true,
            icon: Icon(icon),
            onPressed: onPressed,
          )
        : IconButton(
            tooltip: tooltip,
            icon: Icon(
              icon,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            onPressed: onPressed,
          );
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        button,
        if (active)
          Positioned(
            bottom: -2,
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

/// Bouton muet + barre de volume (mémorisé entre les sessions).
class VolumeControl extends StatelessWidget {
  final PlayerController pc;
  const VolumeControl({super.key, required this.pc});

  @override
  Widget build(BuildContext context) {
    // Volume choisi par l'utilisateur (pas celui, plus bas, d'un fondu).
    return ValueListenableBuilder<double>(
      valueListenable: pc.volume,
      builder: (context, v, _) {
        final icon = v == 0
            ? Icons.volume_off
            : v < 0.5
            ? Icons.volume_down
            : Icons.volume_up;
        // Molette : ±5 % par cran.
        return MouseWheel(
          onStep: (d) => pc.setVolume(((v + d * 0.05) * 20).round() / 20),
          child: Row(
            children: [
              IconButton(
                tooltip: v == 0 ? 'Rétablir le son' : 'Couper le son',
                icon: Icon(icon),
                onPressed: pc.toggleMute,
              ),
              Expanded(
                child: Slider(
                  value: v,
                  // Glisser change le volume en direct ; il est mémorisé
                  // quand on relâche.
                  onChanged: pc.previewVolume,
                  onChangeEnd: pc.setVolume,
                  semanticFormatterCallback: (x) =>
                      'Volume ${(x * 100).round()} %',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    final queue = pc.queue;
    final pos = pc.queuePosition;
    final primary = Theme.of(context).colorScheme.primary;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Text(
            'File d\'attente (${queue.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: queue.length,
              itemBuilder: (context, i) {
                final t = queue[i];
                final isCurrent = i == pos;
                return ListTile(
                  leading: CoverImage(itemId: t.imageItemId, size: 40),
                  title: Text(
                    t.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: isCurrent ? primary : null),
                  ),
                  subtitle: Text(
                    t.artistLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: isCurrent
                      ? Icon(Icons.graphic_eq, color: primary)
                      : IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Retirer',
                          onPressed: () => pc.removeFromQueue(i),
                        ),
                  onTap: () => pc.skipToQueueIndex(i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
