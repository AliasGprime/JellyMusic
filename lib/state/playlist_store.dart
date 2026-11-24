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

  /// Playlists que ce compte a le droit de voir (les playlists Spotify
  /// « __Compte__ … » des autres comptes sont exclues).
  Iterable<JItem>? get _mine =>
      playlists?.where((p) => p.visibleTo(session.username));

  /// Toutes les playlists que ce compte voit (y compris vides ou vidéos).
  List<JItem>? get mine => _mine?.toList();

  /// Playlists affichées : seulement celles qui contiennent au moins un
  /// morceau de musique.
  List<JItem>? get visible =>
      _mine?.where((p) => (p.musicCount ?? 0) > 0).toList();

  /// Playlists proposées dans « Ajouter à une playlist » : celles qui ont de
  /// la musique, plus les playlists entièrement vides (fraîchement créées).
  /// Une playlist qui ne contient que des vidéos n'est jamais proposée, ni
  /// une playlist Spotify (verrouillée).
  List<JItem>? get pickable => _mine
      ?.where((p) => !p.isLocked)
      .where((p) => (p.musicCount ?? 0) > 0 || (p.childCount ?? 0) == 0)
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
  /// [private] : visible seulement par ce compte (préfixe « _-Compte-_ »).
  Future<String> create(
    String name, {
    List<JItem> tracks = const [],
    bool private = false,
  }) async {
    final id = await session.client!.createPlaylist(
      PlaylistRules.serverName(
        name,
        privateFor: private ? session.username : null,
      ),
    );
    if (tracks.isNotEmpty) {
      await add(id, tracks); // par paquets : la liste peut être longue
    } else {
      _changed(id);
      await refresh();
    }
    return id;
  }

  /// Copie [source] (ex. une playlist Spotify verrouillée) dans une nouvelle
  /// playlist modifiable nommée [name]. Renvoie l'id de la copie.
  Future<String> clone(
    JItem source,
    String name, {
    bool private = false,
  }) async {
    final tracks = await session.client!.playlistTracks(source.id);
    return create(name, tracks: tracks, private: private);
  }

  /// Rend [p] privée (visible seulement par ce compte) ou publique.
  Future<void> setPrivate(JItem p, bool private) async {
    await session.client!.renamePlaylist(
      p.id,
      PlaylistRules.serverName(
        p.displayName,
        privateFor: private ? session.username : null,
      ),
    );
    await refresh();
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

  /// Renomme [p] en gardant son statut privé ou public.
  Future<void> rename(JItem p, String name) async {
    await session.client!.renamePlaylist(
      p.id,
      PlaylistRules.serverName(name, privateFor: p.privateOwner),
    );
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
