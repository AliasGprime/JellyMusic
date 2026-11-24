import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/download_store.dart';
import '../state/player_controller.dart';
import 'downloads.dart';
import 'layout.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// Barre de lecture compacte affichée au bas des écrans.
class MiniPlayer extends StatelessWidget {
  /// `true` quand la barre est tout en bas de l'écran : on laisse alors de la
  /// place pour les boutons système d'Android.
  final bool bottomSafe;
  const MiniPlayer({super.key, this.bottomSafe = true});

  @override
  Widget build(BuildContext context) {
    // Sur ordinateur, la barre de lecture du bas remplace le mini-lecteur.
    if (PlayerBarScope.active(context)) return const SizedBox.shrink();
    final pc = context.watch<PlayerController>();
    final t = pc.current;
    // Téléchargements en cours : barre avec « Arrêter », sur tous les écrans.
    final downloading = context.select<DownloadStore, bool>((d) => d.busy);
    if (t == null) {
      // Rien ne joue : on réserve quand même la place des boutons système,
      // sinon les messages (« Annuler », etc.) passent dessous.
      final spacer = SizedBox(
        height: bottomSafe ? MediaQuery.paddingOf(context).bottom : 0,
      );
      if (!downloading) return spacer;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [const DownloadBar(), spacer],
      );
    }
    final player = pc.player;
    final scheme = Theme.of(context).colorScheme;

    final playerBar = Material(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        bottom: bottomSafe,
        child: InkWell(
          onTap: () => Navigator.of(context).push(PlayerScreen.route()),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (context, snap) {
                  final pos = snap.data ?? Duration.zero;
                  final dur = player.duration ?? t.duration ?? Duration.zero;
                  final v = dur.inMilliseconds > 0
                      ? (pos.inMilliseconds / dur.inMilliseconds).clamp(
                          0.0,
                          1.0,
                        )
                      : 0.0;
                  return LinearProgressIndicator(value: v, minHeight: 2);
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                child: Row(
                  children: [
                    Hero(
                      tag: 'cover',
                      child: CoverImage(itemId: t.imageItemId, size: 44),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            t.artistLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    StreamBuilder<bool>(
                      stream: player.playingStream,
                      builder: (context, snap) {
                        final playing = snap.data ?? false;
                        return IconButton(
                          iconSize: 32,
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                          onPressed: playing ? player.pause : player.play,
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: player.hasNext ? player.seekToNext : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!downloading) return playerBar;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [const DownloadBar(), playerBar],
    );
  }
}
