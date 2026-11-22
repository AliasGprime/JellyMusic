import 'package:flutter/foundation.dart';

import '../models.dart';
import 'session.dart';

/// Liste des playlists partagée par tous les écrans, gardée à jour après
/// chaque création, ajout, retrait, renommage ou suppression.
class PlaylistStore extends ChangeNotifier {
  final Session session;
  PlaylistStore(this.session);

  /// Toutes les playlists connues (y compris celles sans musique).
  List<JItem>? playlists;
  Object? error;

  /// Playlists affichées : seulement celles qui contiennent au moins un
  /// morceau de musique.
  List<JItem>? get visible =>
      playlists?.where((p) => (p.musicCount ?? 0) > 0).toList();

  /// Playlists proposées dans « Ajouter à une playlist » : celles qui ont de
  /// la musique, plus les playlists entièrement vides (fraîchement créées).
  /// Une playlist qui ne contient que des vidéos n'est jamais proposée.
  List<JItem>? get pickable => playlists
      ?.where((p) => (p.musicCount ?? 0) > 0 || (p.childCount ?? 0) == 0)
      .toList();
  bool loading = false;

  /// Incrémenté à chaque changement du contenu d'une playlist, avec son id :
  /// l'écran d'une playlist ouverte s'en sert pour se recharger.
  int revision = 0;
  String? lastChangedId;

  Future<void> refresh() async {
    final c = session.client;
    if (c == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      playlists = await c.playlists();
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> ensureLoaded() async {
    if (playlists == null && !loading) await refresh();
  }

  void _changed(String playlistId) {
    revision++;
    lastChangedId = playlistId;
  }

  /// Crée une playlist (éventuellement déjà remplie) et renvoie son id.
  Future<String> create(String name, {List<JItem> tracks = const []}) async {
    final id = await session.client!.createPlaylist(
      name.trim(),
      itemIds: tracks.map((t) => t.id).toList(),
    );
    _changed(id);
    await refresh();
    return id;
  }

  Future<void> add(String playlistId, List<JItem> tracks) async {
    if (tracks.isEmpty) return;
    // Le serveur limite la longueur des adresses : on envoie par paquets.
    for (var i = 0; i < tracks.length; i += 100) {
      final chunk = tracks.skip(i).take(100).map((t) => t.id).toList();
      await session.client!.addToPlaylist(playlistId, chunk);
    }
    _changed(playlistId);
    await refresh();
  }

  Future<void> remove(String playlistId, List<JItem> entries) async {
    final ids = entries
        .map((t) => t.playlistItemId)
        .whereType<String>()
        .toList();
    if (ids.isEmpty) return;
    await session.client!.removeFromPlaylist(playlistId, ids);
    _changed(playlistId);
    await refresh();
  }

  Future<void> move(String playlistId, JItem entry, int newIndex) async {
    final id = entry.playlistItemId;
    if (id == null) return;
    await session.client!.movePlaylistItem(playlistId, id, newIndex);
    _changed(playlistId);
    notifyListeners();
  }

  Future<void> rename(String playlistId, String name) async {
    await session.client!.renamePlaylist(playlistId, name.trim());
    await refresh();
  }

  Future<void> delete(String playlistId) async {
    await session.client!.deletePlaylist(playlistId);
    playlists?.removeWhere((p) => p.id == playlistId);
    notifyListeners();
    await refresh();
  }

  void clear() {
    playlists = null;
    error = null;
    notifyListeners();
  }
}
