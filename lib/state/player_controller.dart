import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/jellyfin_client.dart';
import '../audio/eq_bridge.dart';
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

    // Volume mémorisé entre les sessions.
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble(_kVolume);
    if (saved != null) {
      volume.value = saved.clamp(0.0, 1.0);
      if (saved > 0) _beforeMute = volume.value;
      _applyVolume();
    }
    crossfadeSeconds = (prefs.getInt(_kCrossfade) ?? 0).clamp(0, 12);
    final q = prefs.getInt(_kQuality);
    if (q != null) streamKbps = q == 0 ? null : q;
    normalize = prefs.getBool(_kNormalize) ?? false;
    normalizeGain = (prefs.getDouble(_kNormalizeGain) ?? 6).clamp(0.0, 12.0);
    _applyNormalization();
    if (normalize) _loadFallbackGain();
    // Aléatoire et répétition choisis la dernière fois.
    if (prefs.getBool(_kShuffle) ?? false) {
      await player.setShuffleModeEnabled(true);
    }
    final repeat = prefs.getInt(_kRepeat);
    if (repeat != null && repeat >= 0 && repeat < LoopMode.values.length) {
      await player.setLoopMode(LoopMode.values[repeat]);
    }
    notifyListeners();

    _subs.add(
      player.currentIndexStream.listen((_) {
        _onTrackChanged();
        notifyListeners();
      }),
    );
    _subs.add(player.sequenceStateStream.listen((_) => notifyListeners()));
    _subs.add(
      player.positionStream.listen((p) {
        _lastPosition = p;
        _checkAbLoop(p);
        _checkCrossfade(p);
      }),
    );
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
      Uri.parse(c.streamUrl(t.id, maxKbps: streamKbps)),
      headers: kIsWeb ? null : c.streamHeaders,
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
    _endCrossfade();
    // Version web : le lecteur du navigateur garde l'ancienne file en cache
    // (même identifiant de playlist) et rejouait l'ancien morceau alors que
    // l'écran affichait le nouveau. On l'arrête pour repartir à neuf.
    if (kIsWeb && player.audioSource != null) await player.stop();
    try {
      await player.setAudioSources(
        list.map(_sourceFor).toList(),
        initialIndex: index,
        shuffleOrder: _order = QueueShuffleOrder(),
      );
      // Mode aléatoire mémorisé : nouveau mélange, en commençant par le
      // morceau choisi.
      if (player.shuffleModeEnabled) await player.shuffle();
    } on PlayerInterruptedException {
      return;
    } on PlayerException catch (e) {
      lastError = 'Lecture impossible : ${e.message ?? e.code}';
      notifyListeners();
      return;
    }
    player.play();
  }

  QueueShuffleOrder? _order;

  Future<void> playNext(JItem t) async {
    if (player.sequence.isEmpty) return playItems([t]);
    final cur = player.currentIndex ?? -1;
    // En aléatoire aussi, il sera joué juste après le morceau en cours.
    _order?.insertAfter = cur;
    await player.insertAudioSource(cur + 1, _sourceFor(t));
  }

  Future<void> addToQueue(JItem t) async {
    if (player.sequence.isEmpty) return playItems([t]);
    _order?.insertAfter = null; // à la fin de la file
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

  static const _kShuffle = 'player.shuffle';
  static const _kRepeat = 'player.repeat';

  /// Aléatoire et répétition sont mémorisés entre les sessions.
  Future<void> toggleShuffle() async {
    final enable = !player.shuffleModeEnabled;
    if (enable) await player.shuffle();
    await player.setShuffleModeEnabled(enable);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_kShuffle, enable);
  }

  static const _kVolume = 'player.volume';
  double _beforeMute = 1;

  /// Volume choisi par l'utilisateur (0 à 1). Le volume réel du lecteur
  /// peut être plus bas pendant un fondu enchaîné.
  final ValueNotifier<double> volume = ValueNotifier(1);

  /// Facteur du fondu enchaîné appliqué au lecteur principal (0 à 1).
  double _fadeGain = 1;

  void _applyVolume() =>
      player.setVolume(volume.value * _fadeGain * _trackFactor);

  // ---- Qualité de lecture ----

  static const _kQuality = 'player.quality';

  /// Débits proposés (kb/s) ; null : fichier original, sans conversion.
  static const qualityChoices = <int?>[null, 320, 256, 192, 128];

  /// Débit maximal du flux en kb/s (au-delà, conversion en MP3), ou null
  /// pour le fichier original. Par défaut : original sur le web (réseau
  /// local), MP3 320 kb/s sur téléphone (données mobiles).
  int? streamKbps = kIsWeb ? null : 320;

  /// S'applique aux morceaux lancés ensuite (la file en cours garde son
  /// débit).
  Future<void> setStreamKbps(int? kbps) async {
    streamKbps = kbps;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(_kQuality, kbps ?? 0);
  }

  // ---- Normalisation du volume ----
  //
  // Jellyfin mesure chaque morceau et donne la correction (dB) qui l'amène
  // au niveau commun. On l'applique au volume du lecteur, qui ne sait que
  // baisser : pour pouvoir aussi monter les morceaux faibles, tout est
  // d'abord baissé de [_headroomDb], puis remonté d'autant (plus le gain de
  // compensation) en sortie, derrière un limiteur (version web).

  static const _kNormalize = 'player.normalize';
  static const _kNormalizeGain = 'player.normalizeGain';
  static const _headroomDb = 6.0;

  /// Normalisation activée.
  bool normalize = false;

  /// Gain de compensation (dB) : la normalisation baisse surtout les
  /// morceaux forts, ce gain remonte l'ensemble.
  double normalizeGain = 6;

  /// Correction utilisée pour un morceau pas encore mesuré par Jellyfin :
  /// la médiane des morceaux mesurés (sinon il sonnerait trop fort).
  double fallbackGain = -8;

  /// Vrai si la sortie peut être amplifiée (moteur audio de la page web).
  bool get _canBoost => kIsWeb && equalizerSupported;

  double _trackFactor = 1;
  double _tailFactor = 1;

  /// Facteur de volume (0 à 1) pour le morceau [t].
  double _factorFor(JItem? t) {
    if (!normalize || t == null) return 1;
    final g = t.normalizationGain ?? fallbackGain;
    final db = g - (_canBoost ? _headroomDb : 0);
    return math.min(1.0, math.pow(10, db / 20).toDouble());
  }

  void _applyNormalization() {
    _trackFactor = _factorFor(current);
    _applyVolume();
    applyOutputGain(normalize && _canBoost ? _headroomDb + normalizeGain : 0);
  }

  Future<void> setNormalize(bool on) async {
    normalize = on;
    _applyNormalization();
    notifyListeners();
    if (on) _loadFallbackGain();
    await (await SharedPreferences.getInstance()).setBool(_kNormalize, on);
  }

  Future<void> setNormalizeGain(double db) async {
    normalizeGain = db.clamp(0.0, 12.0);
    _applyNormalization();
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      _kNormalizeGain,
      normalizeGain,
    );
  }

  bool _fallbackLoaded = false;

  /// Calcule la médiane des corrections de la bibliothèque (une fois).
  Future<void> _loadFallbackGain() async {
    final c = _client;
    if (_fallbackLoaded || c == null) return;
    _fallbackLoaded = true;
    try {
      final gains =
          (await c.songs(limit: 5000)).items
              .map((s) => s.normalizationGain)
              .whereType<double>()
              .toList()
            ..sort();
      if (gains.isEmpty) return;
      fallbackGain = gains[gains.length ~/ 2];
      _applyNormalization();
      notifyListeners();
    } catch (_) {
      _fallbackLoaded = false; // nouvel essai plus tard
    }
  }

  /// Change le volume pendant qu'on glisse le curseur (sans l'enregistrer).
  void previewVolume(double v) {
    volume.value = v.clamp(0.0, 1.0);
    _applyVolume();
  }

  /// Change le volume (0 à 1) et le mémorise.
  Future<void> setVolume(double v) async {
    previewVolume(v);
    if (volume.value > 0) _beforeMute = volume.value;
    await (await SharedPreferences.getInstance()).setDouble(
      _kVolume,
      volume.value,
    );
  }

  /// Coupe le son, ou le remet au niveau d'avant.
  Future<void> toggleMute() =>
      setVolume(volume.value > 0 ? 0 : (_beforeMute > 0 ? _beforeMute : 1));

  Future<void> cycleRepeat() async {
    const order = [LoopMode.off, LoopMode.all, LoopMode.one];
    final next = order[(order.indexOf(player.loopMode) + 1) % order.length];
    await player.setLoopMode(next);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(_kRepeat, next.index);
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
    _endCrossfade();
    _reportStop();
    await player.stop();
    await player.clearAudioSources();
    notifyListeners();
  }

  /// Avance (secondes > 0) ou recule dans le morceau, sans sortir des bornes.
  Future<void> seekBy(int seconds) async {
    final dur = _trackDuration;
    var to = player.position + Duration(seconds: seconds);
    if (to < Duration.zero) to = Duration.zero;
    if (dur != null && to > dur) to = dur;
    await player.seek(to);
  }

  // ---- Boucle A-B ----

  /// Point A (début de la boucle), ou null.
  Duration? abStart;

  /// Point B (fin de la boucle), ou null. Boucle active quand les deux sont
  /// définis.
  Duration? abEnd;
  bool _abJumping = false;

  bool get abActive => abStart != null && abEnd != null;

  /// 1er appui : point A ; 2e : point B, la boucle démarre ; 3e : arrêt.
  void pressAb() {
    final pos = player.position;
    if (abStart == null) {
      abStart = pos;
    } else if (abEnd == null) {
      var a = abStart!, b = pos;
      if (b < a) (a, b) = (b, a); // on a reculé entre les deux appuis
      if (b - a < const Duration(seconds: 1)) return; // trop court
      abStart = a;
      abEnd = b;
      if (pos > b || pos < a) player.seek(a);
    } else {
      clearAb();
      return;
    }
    notifyListeners();
  }

  void clearAb() {
    if (abStart == null && abEnd == null) return;
    abStart = abEnd = null;
    notifyListeners();
  }

  void _checkAbLoop(Duration p) {
    final a = abStart, b = abEnd;
    if (a == null || b == null || _abJumping || p < b) return;
    _abJumping = true;
    player.seek(a).whenComplete(() => _abJumping = false);
  }

  // ---- Fondu enchaîné (version web) ----
  //
  // Un peu avant la fin du morceau, un second lecteur (« la traîne ») charge
  // ce même morceau à l'endroit du relais. Au relais, la traîne continue le
  // morceau qui finit en baissant, pendant que le lecteur principal passe au
  // suivant en montant : aucun silence entre les deux. Le lecteur principal
  // reste la seule référence pour la file, l'affichage et Jellyfin.

  static const _kCrossfade = 'player.crossfade';

  /// Durée du morceau : celle du lecteur, sinon celle connue par Jellyfin
  /// (le navigateur ne la donne pas toujours pour un flux).
  Duration? get _trackDuration => player.duration ?? current?.duration;

  /// Durée du fondu enchaîné en secondes (0 : désactivé).
  int crossfadeSeconds = 0;

  /// Nécessite deux lecteurs simultanés : version web seulement.
  bool get crossfadeSupported => kIsWeb;

  AudioPlayer? _tail;
  bool _tailReady = false;
  int? _tailIndex; // morceau (index de la file) chargé dans la traîne
  Duration? _handoffAt; // position du relais dans ce morceau
  Timer? _handoffTimer;
  Timer? _rampTimer;
  int? _rampFrom; // morceau qui s'éteint
  int? _rampTo; // morceau qui monte (connu après le relais)
  Duration _rampLength = Duration.zero;

  Future<void> setCrossfade(int seconds) async {
    crossfadeSeconds = seconds.clamp(0, 12);
    if (crossfadeSeconds == 0) _endCrossfade();
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      _kCrossfade,
      crossfadeSeconds,
    );
  }

  void _checkCrossfade(Duration pos) {
    if (!crossfadeSupported || crossfadeSeconds == 0) return;
    if (_rampTimer != null) return; // fondu en cours
    final dur = _trackDuration;
    final idx = player.currentIndex;
    if (dur == null || idx == null || !player.playing) return;
    if (!player.hasNext || player.loopMode == LoopMode.one || abActive) {
      _cancelTail();
      return;
    }
    // Morceau court : le fondu ne dépasse pas le tiers du morceau.
    var fade = Duration(seconds: crossfadeSeconds);
    if (fade > dur ~/ 3) fade = dur ~/ 3;
    if (fade < const Duration(seconds: 1)) return;
    // La traîne joue un peu plus longtemps que le fondu, le temps que le
    // morceau suivant démarre.
    final handoff = dur - fade - const Duration(seconds: 1);

    if (_tailIndex == idx && _handoffAt != null) {
      // Préparé : annuler si l'utilisateur s'est déplacé dans le morceau.
      if (pos > _handoffAt! + const Duration(seconds: 1) ||
          _handoffAt! - pos > const Duration(seconds: 10)) {
        _cancelTail();
      } else if (_tailReady &&
          _handoffTimer == null &&
          _handoffAt! - pos < const Duration(seconds: 1)) {
        // Relais à la milliseconde près (la position n'arrive que toutes
        // les ~200 ms).
        var wait = _handoffAt! - player.position;
        if (wait < Duration.zero) wait = Duration.zero;
        _handoffTimer = Timer(wait, _handoff);
      }
      return;
    }
    _cancelTail();
    final ahead = handoff - pos;
    if (ahead > const Duration(seconds: 6) ||
        ahead < const Duration(seconds: 1)) {
      return; // trop tôt, ou trop tard pour préparer ce morceau
    }
    _prepareTail(idx, handoff);
  }

  void _prepareTail(int idx, Duration at) {
    final c = _client;
    final seq = player.sequence;
    if (c == null || idx >= seq.length) return;
    final tag = seq[idx].tag;
    if (tag is! MediaItem) return;
    final tail = AudioPlayer();
    _tail = tail;
    _tailIndex = idx;
    _handoffAt = at;
    _tailReady = false;
    tail
        .setAudioSource(
          AudioSource.uri(Uri.parse(c.streamUrl(tag.id, maxKbps: streamKbps))),
          initialPosition: at,
        )
        .then((_) {
          if (_tail == tail) _tailReady = true;
        })
        .catchError((e) {
          if (_tail == tail) _cancelTail();
          return null;
        });
  }

  Future<void> _handoff() async {
    _handoffTimer = null;
    final tail = _tail;
    final from = player.currentIndex;
    if (tail == null || !_tailReady || !player.playing || from != _tailIndex) {
      _cancelTail();
      return;
    }
    var fade = Duration(seconds: crossfadeSeconds);
    final dur = _trackDuration;
    if (dur != null && fade > dur ~/ 3) fade = dur ~/ 3;
    _rampLength = fade;
    _rampFrom = from;
    _rampTo = null;
    // Le morceau suivant démarre en silence, la traîne prend le relais.
    // La traîne garde la correction de volume du morceau qui finit.
    _tailFactor = _trackFactor;
    _fadeGain = 0;
    _applyVolume();
    tail.setVolume(volume.value * _tailFactor);
    tail.play();
    _rampTimer = Timer.periodic(const Duration(milliseconds: 50), _rampTick);
    await player.seekToNext();
    _rampTo = player.currentIndex;
  }

  void _rampTick(Timer _) {
    final idx = player.currentIndex;
    // Arrêt du fondu : pause, ou l'utilisateur a changé de morceau.
    if (!player.playing || (_rampTo != null && idx != _rampTo)) {
      _endCrossfade();
      return;
    }
    // Progression = position du morceau qui monte : tant qu'il charge, il
    // reste muet et l'ancien continue à plein volume.
    final x = idx == _rampFrom
        ? 0.0
        : (player.position.inMilliseconds / _rampLength.inMilliseconds).clamp(
            0.0,
            1.0,
          );
    // Courbes « puissance constante » : le volume global ne creuse pas.
    _fadeGain = math.sin(x * math.pi / 2);
    _applyVolume();
    _tail?.setVolume(volume.value * _tailFactor * math.cos(x * math.pi / 2));
    if (x >= 1) _endCrossfade();
  }

  void _cancelTail() {
    _handoffTimer?.cancel();
    _handoffTimer = null;
    final tail = _tail;
    _tail = null;
    _tailReady = false;
    _tailIndex = null;
    _handoffAt = null;
    tail?.dispose();
  }

  /// Termine (ou interrompt) le fondu : volume normal, traîne arrêtée.
  void _endCrossfade() {
    _rampTimer?.cancel();
    _rampTimer = null;
    _rampFrom = _rampTo = null;
    _cancelTail();
    if (_fadeGain != 1) {
      _fadeGain = 1;
      _applyVolume();
    }
  }

  void _onTrackChanged() {
    // Changement de morceau hors fondu (suivant, précédent, choix dans la
    // file) : la traîne préparée ne sert plus.
    if (_rampTimer == null) _cancelTail();
    // Correction de volume du nouveau morceau.
    _trackFactor = _factorFor(current);
    _applyVolume();
    if (normalize) _loadFallbackGain();
    final now = current?.id;
    if (now == _reportedId) return;
    clearAb(); // la boucle A-B ne vaut que pour le morceau où on l'a posée
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
    _endCrossfade();
    volume.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    super.dispose();
  }
}

/// Ordre aléatoire de la file. Contrairement à l'ordre par défaut (qui place
/// les ajouts au hasard), un morceau « Lire ensuite » passe juste après le
/// morceau en cours, et « Ajouter à la file » le met à la fin.
class QueueShuffleOrder extends DefaultShuffleOrder {
  /// Index (dans la file d'origine) du morceau après lequel insérer ;
  /// null : à la fin.
  int? insertAfter;

  @override
  void insert(int index, int count) {
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) indices[i] += count;
    }
    final anchor = insertAfter;
    insertAfter = null;
    var at = anchor == null ? -1 : indices.indexOf(anchor);
    at = at < 0 ? indices.length : at + 1;
    indices.insertAll(at, List.generate(count, (i) => index + i));
  }
}
