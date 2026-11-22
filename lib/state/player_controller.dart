import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../api/jellyfin_client.dart';
import '../models.dart';
import 'session.dart';

/// Lecteur audio : file d'attente, contrôles et rapports d'écoute à Jellyfin.
class PlayerController extends ChangeNotifier {
  final Session session;
  final AudioPlayer player = AudioPlayer();
  final Map<String, JItem> _items = {};
  final List<StreamSubscription> _subs = [];
  Timer? _progressTimer;

  String? _reportedId;
  Duration _lastPosition = Duration.zero;
  String? lastError;

  PlayerController(this.session) {
    _init();
  }

  JellyfinClient? get _client => session.client;

  Future<void> _init() async {
    final audioSession = await AudioSession.instance;
    await audioSession.configure(const AudioSessionConfiguration.music());

    _subs.add(
      player.currentIndexStream.listen((_) {
        _onTrackChanged();
        notifyListeners();
      }),
    );
    _subs.add(player.sequenceStateStream.listen((_) => notifyListeners()));
    _subs.add(player.positionStream.listen((p) => _lastPosition = p));
    _subs.add(
      player.playingStream.listen((playing) {
        final id = _reportedId;
        if (id != null) _client?.reportProgress(id, _lastPosition, !playing);
      }),
    );
    _subs.add(
      player.errorStream.listen((e) {
        lastError = 'Lecture impossible : ${e.message ?? e.code}';
        notifyListeners();
      }),
    );
    _progressTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final id = _reportedId;
      if (id != null && player.playing) {
        _client?.reportProgress(id, _lastPosition, false);
      }
    });
  }

  /// Morceaux de la file, dans l'ordre de lecture (tient compte de l'aléatoire).
  List<JItem> get queue {
    final seq = player.sequence;
    return [
      for (final i in player.effectiveIndices)
        if (i < seq.length) _itemForSource(seq[i]),
    ].whereType<JItem>().toList();
  }

  /// Position du morceau courant dans [queue].
  int get queuePosition {
    final idx = player.currentIndex;
    if (idx == null) return -1;
    return player.effectiveIndices.indexOf(idx);
  }

  JItem? get current {
    final idx = player.currentIndex;
    final seq = player.sequence;
    if (idx == null || idx >= seq.length) return null;
    return _itemForSource(seq[idx]);
  }

  JItem? _itemForSource(IndexedAudioSource s) {
    final tag = s.tag;
    return tag is MediaItem ? _items[tag.id] : null;
  }

  AudioSource _sourceFor(JItem t) {
    final c = _client!;
    _items[t.id] = t;
    final art = c.imageUrl(t.imageItemId, maxWidth: 600);
    return AudioSource.uri(
      Uri.parse(c.streamUrl(t.id)),
      headers: c.streamHeaders,
      tag: MediaItem(
        id: t.id,
        title: t.name,
        artist: t.artistLine,
        album: t.album,
        duration: t.duration,
        artUri: art == null ? null : Uri.parse(art),
      ),
    );
  }

  /// Remplace la file et lance la lecture.
  Future<void> playItems(
    List<JItem> items, {
    int start = 0,
    bool shuffle = false,
  }) async {
    if (items.isEmpty || _client == null) return;
    var list = items;
    var index = start;
    if (shuffle) {
      list = List.of(items)..shuffle();
      index = 0;
    }
    lastError = null;
    await player.setShuffleModeEnabled(false);
    try {
      await player.setAudioSources(
        list.map(_sourceFor).toList(),
        initialIndex: index,
        preload: false,
      );
    } on PlayerInterruptedException {
      return;
    } on PlayerException catch (e) {
      lastError = 'Lecture impossible : ${e.message ?? e.code}';
      notifyListeners();
      return;
    }
    player.play();
  }

  Future<void> playNext(JItem t) async {
    if (player.sequence.isEmpty) return playItems([t]);
    final idx = (player.currentIndex ?? -1) + 1;
    await player.insertAudioSource(idx, _sourceFor(t));
  }

  Future<void> addToQueue(JItem t) async {
    if (player.sequence.isEmpty) return playItems([t]);
    await player.addAudioSource(_sourceFor(t));
  }

  /// Saute au morceau à la position [queueIndex] de [queue].
  Future<void> skipToQueueIndex(int queueIndex) async {
    final indices = player.effectiveIndices;
    if (queueIndex < 0 || queueIndex >= indices.length) return;
    await player.seek(Duration.zero, index: indices[queueIndex]);
    player.play();
  }

  Future<void> removeFromQueue(int queueIndex) async {
    final indices = player.effectiveIndices;
    if (queueIndex < 0 || queueIndex >= indices.length) return;
    await player.removeAudioSourceAt(indices[queueIndex]);
  }

  Future<void> toggleShuffle() async {
    final enable = !player.shuffleModeEnabled;
    if (enable) await player.shuffle();
    await player.setShuffleModeEnabled(enable);
    notifyListeners();
  }

  Future<void> cycleRepeat() async {
    const order = [LoopMode.off, LoopMode.all, LoopMode.one];
    final next = order[(order.indexOf(player.loopMode) + 1) % order.length];
    await player.setLoopMode(next);
    notifyListeners();
  }

  /// « Précédent » : revient au début si on est à plus de 3 secondes.
  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  Future<void> stop() async {
    _reportStop();
    await player.stop();
    await player.clearAudioSources();
    notifyListeners();
  }

  void _onTrackChanged() {
    final now = current?.id;
    if (now == _reportedId) return;
    _reportStop();
    if (now != null) {
      _reportedId = now;
      _client?.reportPlaying(now);
    }
  }

  void _reportStop() {
    final prev = _reportedId;
    if (prev != null) _client?.reportStopped(prev, _lastPosition);
    _reportedId = null;
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    super.dispose();
  }
}
