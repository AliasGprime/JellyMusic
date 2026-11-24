import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'session.dart';

/// Un morceau téléchargé sur le téléphone.
class DownloadEntry {
  final JItem track;
  final String file; // chemin du fichier audio
  final int bytes;

  /// Débit choisi (kb/s), ou null pour le fichier original.
  final int? kbps;

  const DownloadEntry({
    required this.track,
    required this.file,
    required this.bytes,
    this.kbps,
  });

  Map<String, dynamic> toJson() => {
    'track': track.toJson(),
    'file': file,
    'bytes': bytes,
    'kbps': kbps,
  };

  static DownloadEntry fromJson(Map<String, dynamic> j) => DownloadEntry(
    track: JItem.fromJson(j['track'] as Map<String, dynamic>),
    file: j['file'] as String,
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    kbps: (j['kbps'] as num?)?.toInt(),
  );
}

/// Une playlist téléchargée : son nom et l'ordre de ses morceaux.
class DownloadedPlaylist {
  final String id;
  final String name;
  final List<String> trackIds;
  const DownloadedPlaylist(this.id, this.name, this.trackIds);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'tracks': trackIds};

  static DownloadedPlaylist fromJson(Map<String, dynamic> j) =>
      DownloadedPlaylist(
        j['id'] as String,
        j['name'] as String,
        ((j['tracks'] as List?) ?? const []).cast<String>(),
      );
}

class _Job {
  final JItem track;
  final int? kbps;
  const _Job(this.track, this.kbps);
}

/// Morceaux téléchargés pour l'écoute sans connexion (téléphone seulement :
/// un navigateur ne garde pas de fichiers durablement).
///
/// Les fichiers sont dans le dossier privé de l'application (supprimés avec
/// elle) ; un index JSON garde les informations des morceaux pour pouvoir
/// les afficher et les lire hors connexion.
class DownloadStore extends ChangeNotifier {
  final Session session;
  DownloadStore(this.session);

  bool get supported => !kIsWeb;

  Directory? _dir;
  final Map<String, DownloadEntry> entries = {};
  final Map<String, DownloadedPlaylist> playlists = {};

  /// Pochettes enregistrées : id de l'image → chemin du fichier.
  final Map<String, String> covers = {};

  // File d'attente des téléchargements.
  final List<_Job> _queue = [];
  JItem? current;
  double currentProgress = 0; // 0 à 1, ou -1 si inconnu
  int done = 0;
  int failed = 0;
  int total = 0;
  bool _running = false;
  bool _cancelled = false;
  final http.Client _http = http.Client();

  bool get busy => _running;

  /// Incrémenté à chaque changement des fichiers (pour recalculer la place).
  int revision = 0;

  Future<void> init() async {
    if (!supported) return;
    try {
      final base = await getApplicationDocumentsDirectory();
      _dir = Directory('${base.path}/downloads');
      await Directory('${_dir!.path}/covers').create(recursive: true);
      final index = File('${_dir!.path}/index.json');
      if (await index.exists()) {
        final j =
            jsonDecode(await index.readAsString()) as Map<String, dynamic>;
        for (final e in (j['tracks'] as List? ?? const [])) {
          final d = DownloadEntry.fromJson(e as Map<String, dynamic>);
          if (File(d.file).existsSync()) entries[d.track.id] = d;
        }
        for (final p in (j['playlists'] as List? ?? const [])) {
          final d = DownloadedPlaylist.fromJson(p as Map<String, dynamic>);
          playlists[d.id] = d;
        }
        (j['covers'] as Map? ?? const {}).forEach((k, v) {
          if (File(v as String).existsSync()) covers[k as String] = v;
        });
      }
    } catch (e) {
      debugPrint('Téléchargements : index illisible ($e)');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final dir = _dir;
    if (dir == null) return;
    final j = {
      'tracks': [for (final e in entries.values) e.toJson()],
      'playlists': [for (final p in playlists.values) p.toJson()],
      'covers': covers,
    };
    final tmp = File('${dir.path}/index.json.tmp');
    await tmp.writeAsString(jsonEncode(j));
    await tmp.rename('${dir.path}/index.json');
  }

  bool isDownloaded(String trackId) => entries.containsKey(trackId);

  /// En attente dans la file de téléchargement.
  bool isQueued(String trackId) => _queue.any((j) => j.track.id == trackId);

  /// Progression (0 à 1, -1 si inconnue) si ce morceau est en cours de
  /// téléchargement, sinon null.
  double? progressOf(String trackId) =>
      current?.id == trackId ? currentProgress : null;

  /// Fichier local du morceau, s'il est téléchargé.
  String? fileFor(String trackId) => entries[trackId]?.file;

  /// Pochette locale, si elle a été enregistrée avec un téléchargement.
  String? coverFor(String? imageItemId) =>
      imageItemId == null ? null : covers[imageItemId];

  /// Morceaux d'une playlist téléchargée, dans son ordre (seulement ceux
  /// présents sur le téléphone).
  List<JItem> tracksOf(DownloadedPlaylist p) => [
    for (final id in p.trackIds)
      if (entries[id] != null) entries[id]!.track,
  ];

  /// Tous les morceaux téléchargés, triés par titre.
  List<JItem> get allTracks =>
      entries.values.map((e) => e.track).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Place occupée par tous les téléchargements (fichiers et pochettes).
  Future<int> diskUsage() async {
    final dir = _dir;
    if (dir == null || !await dir.exists()) return 0;
    var sum = 0;
    await for (final f in dir.list(recursive: true)) {
      if (f is File) sum += await f.length();
    }
    return sum;
  }

  /// Ajoute des morceaux à télécharger. [kbps] : débit MP3, ou null pour le
  /// fichier original. Avec [playlist], la playlist est aussi gardée pour
  /// l'écoute hors connexion (dans son ordre).
  Future<void> enqueue(List<JItem> tracks, {int? kbps, JItem? playlist}) async {
    if (!supported || _dir == null) return;
    if (playlist != null) {
      playlists[playlist.id] = DownloadedPlaylist(
        playlist.id,
        playlist.displayName,
        [for (final t in tracks) t.id],
      );
      await _save();
    }
    for (final t in tracks) {
      final have = entries[t.id];
      // Déjà là dans la même qualité, ou déjà prévu : rien à faire.
      if (have != null && have.kbps == kbps) continue;
      if (_queue.any((j) => j.track.id == t.id)) continue;
      _queue.add(_Job(t, kbps));
      total++;
    }
    notifyListeners();
    _run();
  }

  /// Arrête les téléchargements en attente (le morceau en cours est
  /// abandonné).
  void cancel() {
    _cancelled = true;
    _queue.clear();
    notifyListeners();
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    while (_queue.isNotEmpty && !_cancelled) {
      final job = _queue.removeAt(0);
      current = job.track;
      currentProgress = 0;
      notifyListeners();
      try {
        await _download(job);
        done++;
      } catch (e) {
        if (!_cancelled) failed++;
        debugPrint('Téléchargement échoué (${job.track.name}) : $e');
      }
    }
    current = null;
    _running = false;
    // Compteurs remis à zéro pour la prochaine série.
    total = done = failed = 0;
    revision++;
    notifyListeners();
  }

  Future<void> _download(_Job job) async {
    final c = session.client;
    final dir = _dir;
    if (c == null || dir == null) throw StateError('Non connecté');
    final t = job.track;
    final req = http.Request(
      'GET',
      Uri.parse(c.streamUrl(t.id, maxKbps: job.kbps)),
    )..headers.addAll(c.streamHeaders);
    final res = await _http.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode >= 400) throw HttpException('Erreur ${res.statusCode}');
    final ext = _extension(res.headers['content-type'], job.kbps);
    final part = File('${dir.path}/${t.id}.part');
    final sink = part.openWrite();
    // Taille attendue : annoncée par le serveur, sinon estimée (conversion
    // MP3 en direct : la taille n'est pas connue d'avance).
    final expected =
        res.contentLength ??
        (job.kbps != null && t.duration != null
            ? t.duration!.inSeconds * job.kbps! * 1000 ~/ 8
            : null);
    var received = 0;
    try {
      await for (final chunk in res.stream) {
        if (_cancelled) throw StateError('Annulé');
        sink.add(chunk);
        received += chunk.length;
        currentProgress = expected == null || expected == 0
            ? -1
            : (received / expected).clamp(0.0, 1.0);
        notifyListeners();
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await part.exists()) await part.delete();
      rethrow;
    }
    // Remplace une éventuelle version précédente (autre qualité).
    final old = entries[t.id];
    if (old != null && old.file != '${dir.path}/${t.id}.$ext') {
      final f = File(old.file);
      if (await f.exists()) await f.delete();
    }
    final file = await part.rename('${dir.path}/${t.id}.$ext');
    entries[t.id] = DownloadEntry(
      track: t,
      file: file.path,
      bytes: received,
      kbps: job.kbps,
    );
    await _saveCover(t);
    revision++;
    await _save();
    notifyListeners();
  }

  static String _extension(String? contentType, int? kbps) {
    final ct = (contentType ?? '').toLowerCase();
    if (ct.contains('flac')) return 'flac';
    if (ct.contains('mpeg') || ct.contains('mp3')) return 'mp3';
    if (ct.contains('ogg') || ct.contains('opus')) return 'ogg';
    if (ct.contains('mp4') || ct.contains('m4a') || ct.contains('aac')) {
      return 'm4a';
    }
    if (ct.contains('wav')) return 'wav';
    return kbps == null ? 'audio' : 'mp3';
  }

  /// Garde la pochette pour l'affichage hors connexion (une par album).
  Future<void> _saveCover(JItem t) async {
    final img = t.imageItemId;
    final c = session.client;
    final dir = _dir;
    if (img == null || c == null || dir == null || covers.containsKey(img)) {
      return;
    }
    try {
      final url = c.imageUrl(img, maxWidth: 400);
      if (url == null) return;
      final res = await _http
          .get(Uri.parse(url), headers: c.streamHeaders)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return;
      final f = File('${dir.path}/covers/$img.jpg');
      await f.writeAsBytes(res.bodyBytes);
      covers[img] = f.path;
    } catch (_) {
      // Pas de pochette : l'icône de secours sera affichée.
    }
  }

  /// Supprime le téléchargement d'un morceau.
  Future<void> remove(String trackId) async {
    final e = entries.remove(trackId);
    if (e != null) {
      final f = File(e.file);
      if (await f.exists()) await f.delete();
    }
    await _cleanup();
  }

  /// Supprime une playlist téléchargée et ses morceaux (sauf ceux qui font
  /// aussi partie d'une autre playlist téléchargée).
  Future<void> removePlaylist(String playlistId) async {
    final p = playlists.remove(playlistId);
    if (p != null) {
      final keep = {for (final o in playlists.values) ...o.trackIds};
      for (final id in p.trackIds) {
        if (keep.contains(id)) continue;
        final e = entries.remove(id);
        if (e != null) {
          final f = File(e.file);
          if (await f.exists()) await f.delete();
        }
      }
    }
    await _cleanup();
  }

  /// Supprime tous les téléchargements.
  Future<void> clearAll() async {
    cancel();
    entries.clear();
    playlists.clear();
    covers.clear();
    final dir = _dir;
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
      await Directory('${dir.path}/covers').create(recursive: true);
    }
    revision++;
    await _save();
    notifyListeners();
  }

  /// Retire les pochettes qui ne servent plus et enregistre l'index.
  Future<void> _cleanup() async {
    final used = {for (final e in entries.values) e.track.imageItemId};
    for (final img in covers.keys.toList()) {
      if (used.contains(img)) continue;
      final f = File(covers.remove(img)!);
      if (await f.exists()) await f.delete();
    }
    revision++;
    await _save();
    notifyListeners();
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}

/// Taille lisible : « 12,3 Mo », « 1,2 Go ».
String formatBytes(num bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} Mo';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2).replaceAll('.', ',')} Go';
}
