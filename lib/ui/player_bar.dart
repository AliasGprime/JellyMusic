import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/player_controller.dart';
import 'player_screen.dart';
import 'playlist_picker.dart';
import 'widgets.dart';

/// Barre de lecture « ordinateur », en bas de la fenêtre :
/// morceau à gauche, commandes et progression au centre, volume à droite.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    final t = pc.current;
    if (t == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Container(
        height: 96,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            // Morceau en cours (clic : lecteur plein écran).
            SizedBox(
              width: 300,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.of(context).push(PlayerScreen.route()),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Hero(
                        tag: 'cover',
                        child: CoverImage(itemId: t.imageItemId, size: 60),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                            Text(
                              t.artistLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Commandes et progression.
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      PlayerControls(pc: pc, compact: true),
                      SizedBox(
                        height: 28,
                        child: SeekBar(
                          player: pc.player,
                          fallback: t.duration,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Actions et volume.
            SizedBox(
              width: 340,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Qualité : ${pc.currentSourceLabel}',
                    icon: const Icon(Icons.high_quality_outlined),
                    onPressed: () => showSourceSheet(context),
                  ),
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
                  Expanded(child: VolumeControl(pc: pc)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
