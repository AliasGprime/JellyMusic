import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/jellyfin_client.dart';
import '../audio/eq_bridge.dart';
import '../models.dart';
import 'download_store.dart';
import 'session.dart';

/// Lecteur audio : file d'attente, contrôles et rapports d'écoute à Jellyfin.
class PlayerController extends ChangeNotifier {
  final Session session;
  final AudioPlayer player = AudioPlayer(
    // Android : garder en mémoire la partie déjà écoutée (par défaut, rien
    // n'est gardé : reculer obligeait à tout retélécharger, et Jellyfin à
    // reconvertir), charger plus loin devant, et repartir plus vite après
    // un déplacement.
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 60),
        maxBufferDuration: Duration(minutes: 2),
        bufferForPlaybackDuration: Duration(seconds: 1),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 2),
        backBufferDuration: Duration(minutes: 10),
      ),
    ),
  );
  final Map<String, JItem> _items = {};
  final List<StreamSubscription> _subs = [];
  Timer? _progressTimer;

  String? _reportedId;
  Duration _lastPosition = Duration.zero;
  String? lastError;

  /// Morceaux téléchargés : lus depuis le téléphone, même hors connexion.
  final DownloadStore? downloads;

  PlayerController(this.session, [this.downloads]) {
    _init();
  }

  JellyfinClient? get _client => session.client;

  /// Rapports d'écoute au serveur : aucun hors connexion.
  JellyfinClient? get _reporter => session.offline ? null : session.client;

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
    final qm = prefs.getInt(_kQualityMobile);
    if (qm != null) mobileKbps = qm == 0 ? null : qm;
    wifiOverDownloads = prefs.getBool(_kWifiOverDownloads) ?? false;
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
        if (id != null) _reporter?.reportProgress(id, _lastPosition, !playing);
      }),
    );
    _subs.add(
      player.errorStream.listen((e) {
        lastError = 'Lecture impossible : ${e.message ?? e.code}';
        notifyListeners();
      }),
    );
    // Hors connexion : on passe les morceaux non téléchargés.
    _subs.add(player.currentIndexStream.listen((_) => _skipUnavailable()));
    session.addListener(_onSessionChanged);
    // Wi-Fi perdu en pleine écoute en qualité originale : pause et question.
    if (!kIsWeb) {
      final net = await _network();
      _lastNet = net == _Net.none ? null : net;
      _subs.add(
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged),
      );
    }
    _progressTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      final id = _reportedId;
      if (id != null && player.playing) {
        _reporter?.reportProgress(id, _lastPosition, false);
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

  /// Choix de qualité fait dans le lecteur pour un morceau précis : il est
  /// alors lu en flux à ce débit (null : original), même s'il est
  /// téléchargé. Sans choix : version téléchargée d'abord, sinon la
  /// qualité de lecture des Paramètres.
  final Map<String, int?> _streamOverride = {};

  /// Morceaux pour lesquels « Version téléchargée » a été choisie dans le
  /// lecteur (même en Wi-Fi avec « Appliquer même si téléchargé »).
  final Set<String> _forceLocal = {};

  AudioSource _sourceFor(JItem t) {
    final c = _client!;
    _items[t.id] = t;
    // Morceau téléchargé : lu depuis le téléphone (marche hors connexion et
    // n'utilise pas de données), avec sa pochette enregistrée.
    final forced = _streamOverride.containsKey(t.id);
    final local = _playsDownload(t) ? downloads?.fileFor(t.id) : null;
    final localCover = downloads?.coverFor(t.imageItemId);
    final art = localCover != null
        ? Uri.file(localCover)
        : switch (c.imageUrl(t.imageItemId, maxWidth: 600)) {
            final String u => Uri.parse(u),
            null => null,
          };
    final tag = MediaItem(
      id: t.id,
      title: t.name,
      artist: t.artistLine,
      album: t.album,
      duration: t.duration,
      artUri: art,
    );
    if (local != null) {
      return ProgressiveAudioSource(
        Uri.file(local),
        tag: tag,
        duration: t.duration,
        options: _seekableLocal,
      );
    }
    final kbps = forced ? _streamOverride[t.id] : _queueKbps;
    // Android, qualité MP3 : flux en segments (HLS), pour des déplacements
    // rapides dans le morceau. Originale : le fichier tel quel (déjà
    // déplaçable). Web : les navigateurs ne lisent pas le HLS.
    if (!kIsWeb && kbps != null) {
      return HlsAudioSource(
        Uri.parse(c.hlsUrl(t.id, kbps)),
        tag: tag,
        duration: t.duration,
      );
    }
    return ProgressiveAudioSource(
      Uri.parse(c.streamUrl(t.id, maxKbps: kbps)),
      headers: kIsWeb ? null : c.streamHeaders,
      tag: tag,
      duration: t.duration,
      options: _seekableMp3,
    );
  }

  /// Android : un MP3 converti à la volée par Jellyfin n'a ni durée ni table
  /// de positions ; sans ces options, le lecteur le considère « non
  /// déplaçable » et un déplacement dans le morceau le fait repartir au
  /// début. Débit constant (MP3 converti) : position calculée à partir du
  /// débit, même si la taille du flux est inconnue ; fichier téléchargé :
  /// index construit en lisant le fichier.
  static const _seekableMp3 = ProgressiveAudioSourceOptions(
    androidExtractorOptions: AndroidExtractorOptions(
      constantBitrateSeekingEnabled: true,
      constantBitrateSeekingAlwaysEnabled: true,
    ),
  );
  static const _seekableLocal = ProgressiveAudioSourceOptions(
    androidExtractorOptions: AndroidExtractorOptions(
      constantBitrateSeekingEnabled: true,
      mp3Flags: AndroidExtractorOptions.flagMp3EnableIndexSeeking,
    ),
  );

  /// Messages courts à afficher (ex. morceau non téléchargé hors connexion).
  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  bool _wasOffline = false;

  void _onSessionChanged() {
    final off = session.offline;
    if (off && !_wasOffline) _skipUnavailable();
    _wasOffline = off;
  }

  static bool _isLocal(IndexedAudioSource s) =>
      s is UriAudioSource && s.uri.scheme == 'file';

  bool _skipping = false;

  /// Hors connexion, si le morceau en cours n'est pas sur le téléphone :
  /// passe au prochain morceau téléchargé de la file, ou s'arrête.
  Future<void> _skipUnavailable() async {
    if (!session.offline || _skipping) return;
    _skipping = true;
    try {
      await _useDownloads();
    } finally {
      _skipping = false;
    }
    final seq = player.sequence;
    final idx = player.currentIndex;
    if (seq.isEmpty || idx == null || idx >= seq.length) return;
    if (_isLocal(seq[idx])) return;
    final order = player.effectiveIndices;
    final pos = order.indexOf(idx);
    int? next;
    for (var k = pos + 1; k < order.length && next == null; k++) {
      if (_isLocal(seq[order[k]])) next = order[k];
    }
    if (next == null && player.loopMode == LoopMode.all) {
      for (var k = 0; k < pos && next == null; k++) {
        if (_isLocal(seq[order[k]])) next = order[k];
      }
    }
    _skipping = true;
    try {
      if (next == null) {
        // Fin des morceaux téléchargés : on revient au dernier morceau
        // téléchargé (au début, en pause) plutôt que d'afficher un morceau
        // qui ne peut pas être lu. Aucun dans la file : lecteur arrêté.
        int? back;
        for (var k = pos - 1; k >= 0 && back == null; k--) {
          if (_isLocal(seq[order[k]])) back = order[k];
        }
        await player.pause();
        if (back != null) {
          await player.seek(Duration.zero, index: back);
        } else {
          await stop();
        }
        _messages.add(
          'Hors connexion : plus aucun morceau téléchargé dans la file.',
        );
      } else {
        await player.seek(Duration.zero, index: next);
      }
    } finally {
      _skipping = false;
    }
  }

  /// Morceaux téléchargés après leur mise dans la file (encore lus par
  /// Internet) : remplacés sur place par le fichier du téléphone, au même
  /// endroit de la file et, pour le morceau en cours, à la même position.
  Future<void> _useDownloads() async {
    final d = downloads;
    if (d == null) return;
    final seq = player.sequence;
    final swap = <int, JItem>{
      for (var i = 0; i < seq.length; i++)
        if (!_isLocal(seq[i]))
          if (_itemForSource(seq[i]) case final t? when d.isDownloaded(t.id))
            i: t,
    };
    if (swap.isEmpty) return;
    final cur = player.currentIndex;
    final pos = player.position;
    final wasPlaying = player.playing;
    if (swap.containsKey(cur)) {
      _endCrossfade();
      if (wasPlaying) await player.pause();
    }
    for (final MapEntry(key: i, value: t) in swap.entries) {
      final orderPos = player.effectiveIndices.indexOf(i);
      await player.removeAudioSourceAt(i);
      _order?.insertAtPosition = orderPos < 0 ? null : orderPos;
      await player.insertAudioSource(i, _sourceFor(t));
    }
    if (cur != null && swap.containsKey(cur)) {
      await player.seek(pos, index: cur);
      if (wasPlaying) player.play();
    }
    notifyListeners();
  }

  /// Remplace la file et lance la lecture.
  Future<void> playItems(
    List<JItem> items, {
    int start = 0,
    bool shuffle = false,
  }) async {
    if (items.isEmpty || _client == null) return;
    final net = await _network();
    // Hors connexion : seulement les morceaux téléchargés.
    final d = downloads;
    if (!kIsWeb && d != null && (session.offline || net == _Net.none)) {
      final chosen = shuffle ? null : items[start.clamp(0, items.length - 1)];
      final avail = items.where((t) => d.isDownloaded(t.id)).toList();
      if (avail.isEmpty || (chosen != null && !avail.contains(chosen))) {
        _messages.add(
          avail.isEmpty && items.length > 1
              ? 'Hors connexion : aucun de ces morceaux n\'est téléchargé.'
              : 'Hors connexion : ce morceau n\'est pas téléchargé.',
        );
        return;
      }
      if (chosen != null) start = avail.indexOf(chosen);
      items = avail;
    }
    // Qualité selon le réseau (Wi-Fi ou données mobiles) ; originale en
    // données mobiles : on demande d'abord.
    final kbps = await _checkMobileData(
      net == _Net.mobile ? mobileKbps : streamKbps,
      items,
    );
    if (kbps == _cancelled) return;
    _queueKbps = kbps;
    _queueOnWifi = net == _Net.wifi;
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

  /// Hors connexion : faux (avec un message) si [t] n'est pas téléchargé.
  bool _canQueue(JItem t) {
    if (!session.offline || (downloads?.isDownloaded(t.id) ?? false)) {
      return true;
    }
    _messages.add("Hors connexion : ce morceau n'est pas téléchargé.");
    return false;
  }

  Future<void> playNext(JItem t) async {
    if (!_canQueue(t)) return;
    if (player.sequence.isEmpty) return playItems([t]);
    final cur = player.currentIndex ?? -1;
    // En aléatoire aussi, il sera joué juste après le morceau en cours.
    _order?.insertAfter = cur;
    await player.insertAudioSource(cur + 1, _sourceFor(t));
  }

  Future<void> addToQueue(JItem t) async {
    if (!_canQueue(t)) return;
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

  // ---- Qualité du morceau en cours (bouton du lecteur) ----

  /// Version du morceau en cours : « Téléchargé (MP3 192 kb/s) »,
  /// « Originale », « MP3 320 kb/s »…
  String get currentSourceLabel {
    final t = current;
    if (t == null) return '';
    if (_streamOverride.containsKey(t.id)) {
      return qualityName(_streamOverride[t.id]);
    }
    final d = downloads?.entries[t.id];
    if (d != null && _playsDownload(t)) {
      return 'Téléchargé (${qualityName(d.kbps)})';
    }
    return qualityName(_queueKbps);
  }

  /// Vrai si le morceau en cours est lu depuis son téléchargement.
  bool get currentIsLocal {
    final t = current;
    return t != null && _playsDownload(t);
  }

  /// Vrai si [t] est lu depuis son téléchargement : toujours, sauf choix de
  /// qualité fait dans le lecteur pour ce morceau, ou en Wi-Fi avec
  /// « Appliquer même si téléchargé » quand le fichier est de moins bonne
  /// qualité que celle du Wi-Fi.
  bool _playsDownload(JItem t) {
    final d = downloads?.entries[t.id];
    if (d == null) return false;
    if (session.offline) return true; // pas d'autre choix
    if (_streamOverride.containsKey(t.id)) return false;
    if (_forceLocal.contains(t.id)) return true;
    if (_queueOnWifi && wifiOverDownloads && _better(_queueKbps, d.kbps)) {
      return false;
    }
    return true;
  }

  /// Vrai si le débit [a] est meilleur que [b] (null : original, le
  /// meilleur).
  static bool _better(int? a, int? b) => b != null && (a == null || a > b);

  /// Vrai si une qualité précise a été choisie pour le morceau en cours.
  bool get currentHasOverride =>
      current != null && _streamOverride.containsKey(current!.id);

  /// Débit choisi pour le morceau en cours (si [currentHasOverride]).
  int? get currentOverrideKbps =>
      current == null ? null : _streamOverride[current!.id];

  static String qualityName(int? kbps) =>
      kbps == null ? 'Originale' : 'MP3 $kbps kb/s';

  /// Change la version du morceau en cours sans perdre l'endroit écouté :
  /// [useDownload] pour revenir au fichier du téléphone, sinon flux au
  /// débit [kbps] (null : original).
  Future<void> setCurrentSource({bool useDownload = false, int? kbps}) async {
    final t = current;
    final idx = player.currentIndex;
    if (t == null || idx == null || _client == null) return;
    if (useDownload) {
      _streamOverride.remove(t.id);
      _forceLocal.add(t.id);
    } else {
      // En données mobiles, la réponse à la question peut remplacer le
      // choix (ex. « MP3 320 kb/s » au lieu de l'originale).
      final chosen = await _checkMobileData(kbps, [t], ignoreDownloads: true);
      if (chosen == _cancelled) return;
      // Déjà dans cette qualité : rien à recharger.
      if (!currentIsLocal &&
          (_streamOverride.containsKey(t.id)
              ? _streamOverride[t.id] == chosen
              : _queueKbps == chosen)) {
        notifyListeners();
        return;
      }
      _streamOverride[t.id] = chosen;
      _forceLocal.remove(t.id);
    }
    final pos = player.position;
    final wasPlaying = player.playing;
    _endCrossfade();
    // En pause le temps du remplacement : le morceau suivant ne doit pas
    // démarrer une fraction de seconde.
    if (wasPlaying) await player.pause();
    // Remplace le morceau sur place, à la même position dans la file (y
    // compris en aléatoire).
    final orderPos = player.effectiveIndices.indexOf(idx);
    await player.removeAudioSourceAt(idx);
    _order?.insertAtPosition = orderPos < 0 ? null : orderPos;
    await player.insertAudioSource(idx, _sourceFor(t));
    await player.seek(pos, index: idx);
    if (wasPlaying) player.play();
    notifyListeners();
  }

  // ---- Données mobiles ----

  /// Débit utilisé pour la file en cours (choisi au lancement de la
  /// lecture : celui des Paramètres, ou MP3 si on l'a préféré en données
  /// mobiles).
  int? _queueKbps = kIsWeb ? null : 320;
  int? get queueKbps => _queueKbps;

  /// Valeur spéciale : l'utilisateur a annulé.
  static const _cancelled = -1;

  /// Demande à l'utilisateur s'il veut écouter en qualité originale en
  /// données mobiles. Réponse : true = originale, false = MP3 320 kb/s,
  /// null = annuler. Fourni par l'interface (boîte de dialogue).
  Future<bool?> Function(int trackCount)? confirmOriginalOnMobile;

  /// Wi-Fi perdu pendant une écoute en qualité originale : continuer en
  /// originale (true), passer en MP3 320 kb/s (false) ou rester en pause
  /// (null). Fourni par l'interface.
  Future<bool?> Function()? confirmWifiLost;

  /// File lancée en Wi-Fi (pour « Appliquer même si téléchargé »).
  bool _queueOnWifi = false;

  /// Dernier réseau connu (Wi-Fi ou données mobiles), null au départ.
  _Net? _lastNet;
  bool _askingWifiLost = false;

  /// Vrai si le morceau en cours passe par Internet en qualité originale.
  bool get _currentStreamsOriginal {
    final t = current;
    if (t == null || currentIsLocal) return false;
    return _streamOverride.containsKey(t.id)
        ? _streamOverride[t.id] == null
        : _queueKbps == null;
  }

  static _Net _netOf(List<ConnectivityResult> r) {
    if (r.contains(ConnectivityResult.wifi) ||
        r.contains(ConnectivityResult.ethernet)) {
      return _Net.wifi;
    }
    if (r.contains(ConnectivityResult.mobile)) return _Net.mobile;
    return _Net.none;
  }

  static Future<_Net> _network() async {
    if (kIsWeb) return _Net.wifi;
    try {
      return _netOf(await Connectivity().checkConnectivity());
    } catch (_) {
      return _Net.wifi;
    }
  }

  /// Passage du Wi-Fi aux données mobiles (ou l'inverse) : la file en cours
  /// passe à la qualité de ce réseau, sans perdre l'endroit écouté.
  Future<void> _onConnectivityChanged(List<ConnectivityResult> r) async {
    final net = _netOf(r);
    if (net == _Net.none) return; // coupure passagère entre deux réseaux
    final prev = _lastNet;
    _lastNet = net;
    if (prev == null || prev == net || _askingWifiLost) return;
    if (player.sequence.isEmpty) return;
    final wifi = net == _Net.wifi;
    int? target = wifi ? streamKbps : mobileKbps;
    final ask = confirmWifiLost;
    if (!wifi &&
        target == null &&
        ask != null &&
        player.playing &&
        _currentStreamsOriginal) {
      // Originale aussi en données mobiles : on demande avant de continuer.
      _askingWifiLost = true;
      try {
        await player.pause();
        final choice = await ask();
        if (choice == null) return; // on reste en pause
        if (choice == false) {
          await setMobileKbps(320);
          target = 320;
        }
        await _requeueAt(target, wifi: false);
        player.play();
      } finally {
        _askingWifiLost = false;
      }
      return;
    }
    await _requeueAt(target, wifi: wifi);
  }

  /// Comment [t] est lu : depuis le téléphone, ou en flux à tel débit.
  String _plan(JItem t) {
    if (_playsDownload(t)) return 'local';
    final k = _streamOverride.containsKey(t.id)
        ? _streamOverride[t.id]
        : _queueKbps;
    return 'k$k';
  }

  /// Reconstruit la file au débit [kbps] pour le réseau indiqué, en gardant
  /// le morceau en cours et l'endroit écouté. Rien n'est rechargé si cela ne
  /// change rien (ex. que des morceaux téléchargés).
  Future<void> _requeueAt(int? kbps, {required bool wifi}) async {
    final seq = player.sequence;
    final idx = player.currentIndex;
    if (seq.isEmpty || idx == null) return;
    final items = [for (final s in seq) _itemForSource(s)]
        .whereType<JItem>()
        .toList();
    if (items.length != seq.length) return;
    final before = items.map(_plan).toList();
    final oldOverride = Map.of(_streamOverride);
    final oldLocal = Set.of(_forceLocal);
    _streamOverride.clear();
    _forceLocal.clear();
    _queueKbps = kbps;
    _queueOnWifi = wifi;
    final after = items.map(_plan).toList();
    if (listEquals(before, after)) {
      // Rien à recharger : on garde aussi les choix faits dans le lecteur.
      _streamOverride.addAll(oldOverride);
      _forceLocal.addAll(oldLocal);
      notifyListeners();
      return;
    }
    final pos = player.position;
    final wasPlaying = player.playing;
    _endCrossfade();
    await player.setAudioSources(
      items.map(_sourceFor).toList(),
      initialIndex: idx,
      initialPosition: pos,
      shuffleOrder: _order = QueueShuffleOrder(),
    );
    if (player.shuffleModeEnabled) await player.shuffle();
    if (wasPlaying && !player.playing) player.play();
    notifyListeners();
  }

  /// Vrai si le téléphone utilise les données mobiles (ni Wi-Fi, ni
  /// câble).
  static Future<bool> onMobileData() async {
    if (kIsWeb) return false;
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.mobile) &&
          !r.contains(ConnectivityResult.wifi) &&
          !r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }

  /// Débit à utiliser pour lire [tracks] en flux, après confirmation si
  /// [kbps] est l'original (null) et qu'on est en données mobiles. Renvoie
  /// [_cancelled] si l'utilisateur annule. Les morceaux téléchargés ne
  /// comptent pas (ils ne passent pas par Internet).
  Future<int?> _checkMobileData(
    int? kbps,
    List<JItem> tracks, {
    bool ignoreDownloads = false,
  }) async {
    if (kbps != null || kIsWeb) return kbps;
    final streamed = ignoreDownloads
        ? tracks.length
        : tracks.where((t) => !(downloads?.isDownloaded(t.id) ?? false)).length;
    if (streamed == 0 || !await onMobileData()) return kbps;
    final ask = confirmOriginalOnMobile;
    if (ask == null) return kbps;
    final choice = await ask(streamed);
    if (choice == null) return _cancelled;
    if (choice) return null;
    // MP3 choisi : il devient la qualité « Données mobiles » des
    // Paramètres, pour ne plus reposer la question à chaque morceau.
    await setMobileKbps(320);
    return 320;
  }

  // ---- Qualité de lecture ----

  static const _kQuality = 'player.quality';

  /// Débits proposés (kb/s) ; null : fichier original, sans conversion.
  static const qualityChoices = <int?>[null, 320, 256, 192, 128];

  static const _kQualityMobile = 'player.qualityMobile';
  static const _kWifiOverDownloads = 'player.wifiOverDownloads';

  /// Débit maximal du flux en kb/s (au-delà, conversion en MP3), ou null
  /// pour le fichier original. Sur téléphone : qualité en Wi-Fi. Par
  /// défaut : original sur le web (réseau local), MP3 320 kb/s sur
  /// téléphone.
  int? streamKbps = kIsWeb ? null : 320;

  /// Téléphone : qualité en données mobiles.
  int? mobileKbps = 320;

  /// Téléphone, en Wi-Fi : lire en flux, à la qualité du Wi-Fi, les
  /// morceaux téléchargés en moins bonne qualité.
  bool wifiOverDownloads = false;

  Future<void> setMobileKbps(int? kbps) async {
    mobileKbps = kbps;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      _kQualityMobile,
      kbps ?? 0,
    );
  }

  Future<void> setWifiOverDownloads(bool on) async {
    wifiOverDownloads = on;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      _kWifiOverDownloads,
      on,
    );
  }

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
      _reporter?.reportPlaying(now);
    }
  }

  void _reportStop() {
    final prev = _reportedId;
    if (prev != null) _reporter?.reportStopped(prev, _lastPosition);
    _reportedId = null;
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    _messages.close();
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

  /// Position exacte (dans l'ordre de lecture) où insérer, prioritaire sur
  /// [insertAfter] : sert à remplacer un morceau sur place.
  int? insertAtPosition;

  @override
  void insert(int index, int count) {
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] >= index) indices[i] += count;
    }
    final anchor = insertAfter;
    final pos = insertAtPosition;
    insertAfter = null;
    insertAtPosition = null;
    var at = anchor == null ? -1 : indices.indexOf(anchor);
    at = at < 0 ? indices.length : at + 1;
    if (pos != null) at = pos.clamp(0, indices.length);
    indices.insertAll(at, List.generate(count, (i) => index + i));
  }
}

/// Réseau utilisé par le téléphone.
enum _Net { wifi, mobile, none }
