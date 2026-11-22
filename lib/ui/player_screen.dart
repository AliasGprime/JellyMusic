import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/player_controller.dart';
import 'album_screen.dart';
import 'playlist_picker.dart';
import 'widgets.dart';

/// Lecteur plein écran.
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
    final player = pc.player;
    final theme = Theme.of(context);

    if (t == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold();
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
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
            onPressed: () => _showQueue(context),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final coverSize = (c.maxWidth - 48).clamp(120.0, c.maxHeight * 0.5);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(),
                  GestureDetector(
                    onTap: t.albumId == null
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AlbumScreen(
                                albumId: t.albumId!,
                                title: t.album ?? '',
                              ),
                            ),
                          ),
                    child: Hero(
                      tag: 'cover',
                      child: CoverImage(
                        itemId: t.imageItemId,
                        size: coverSize,
                        radius: 16,
                        maxWidth: 900,
                      ),
                    ),
                  ),
                  const Spacer(),
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
                  if (pc.lastError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        pc.lastError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _SeekBar(player: player, fallback: t.duration),
                  const SizedBox(height: 8),
                  _Controls(pc: pc),
                  const SizedBox(height: 32),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const _QueueSheet(),
    );
  }
}

class _SeekBar extends StatefulWidget {
  final AudioPlayer player;
  final Duration? fallback;
  const _SeekBar({required this.player, this.fallback});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, snap) {
        final dur = player.duration ?? widget.fallback ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final pos = (snap.data ?? Duration.zero).inMilliseconds.toDouble();
        final value = (_dragValue ?? pos).clamp(0.0, max > 0 ? max : 1.0);
        return Column(
          children: [
            Slider(
              value: value,
              max: max > 0 ? max : 1.0,
              onChanged: max > 0 ? (v) => setState(() => _dragValue = v) : null,
              onChangeEnd: (v) {
                player.seek(Duration(milliseconds: v.round()));
                setState(() => _dragValue = null);
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDuration(Duration(milliseconds: value.round()))),
                  Text(formatDuration(dur)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  final PlayerController pc;
  const _Controls({required this.pc});

  @override
  Widget build(BuildContext context) {
    final player = pc.player;
    final primary = Theme.of(context).colorScheme.primary;
    final loop = player.loopMode;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: 'Aléatoire',
          icon: Icon(
            Icons.shuffle,
            color: player.shuffleModeEnabled ? primary : null,
          ),
          onPressed: pc.toggleShuffle,
        ),
        IconButton(
          iconSize: 40,
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
              width: 72,
              height: 72,
              child: loading && playing
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: CircularProgressIndicator(),
                    )
                  : IconButton.filled(
                      iconSize: 44,
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: playing ? player.pause : player.play,
                    ),
            );
          },
        ),
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_next),
          onPressed: player.hasNext ? player.seekToNext : null,
        ),
        IconButton(
          tooltip: 'Répéter',
          icon: Icon(
            loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
            color: loop == LoopMode.off ? null : primary,
          ),
          onPressed: pc.cycleRepeat,
        ),
      ],
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
