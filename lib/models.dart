/// Un élément de la bibliothèque Jellyfin (morceau, album, artiste, playlist).
class JItem {
  final String id;
  final String name;
  final String type; // Audio, MusicAlbum, MusicArtist, Playlist
  final String? albumId;
  final String? album;
  final String? albumArtist;
  final List<String> artists;
  final int? indexNumber;
  final int? discNumber;
  final int? productionYear;
  final Duration? duration;
  final bool hasPrimaryImage;
  final String? albumPrimaryImageTag;
  final int? childCount;
  final String? playlistItemId;
  final String? mediaType;

  /// Pour une playlist : nombre de morceaux de musique (vidéos exclues).
  final int? musicCount;

  /// Correction de volume calculée par Jellyfin (dB) pour que tous les
  /// morceaux sonnent au même niveau ; null si pas encore mesuré.
  final double? normalizationGain;

  const JItem({
    required this.id,
    required this.name,
    required this.type,
    this.albumId,
    this.album,
    this.albumArtist,
    this.artists = const [],
    this.indexNumber,
    this.discNumber,
    this.productionYear,
    this.duration,
    this.hasPrimaryImage = false,
    this.albumPrimaryImageTag,
    this.childCount,
    this.playlistItemId,
    this.mediaType,
    this.musicCount,
    this.normalizationGain,
  });

  factory JItem.fromJson(Map<String, dynamic> j) {
    final ticks = j['RunTimeTicks'];
    final imageTags = j['ImageTags'];
    return JItem(
      id: j['Id'] as String,
      name: (j['Name'] as String?) ?? 'Sans titre',
      type: (j['Type'] as String?) ?? '',
      albumId: j['AlbumId'] as String?,
      album: j['Album'] as String?,
      albumArtist: j['AlbumArtist'] as String?,
      artists: ((j['Artists'] as List?) ?? const []).cast<String>(),
      indexNumber: j['IndexNumber'] as int?,
      discNumber: j['ParentIndexNumber'] as int?,
      productionYear: j['ProductionYear'] as int?,
      // 1 tick = 100 ns = 0,1 µs
      duration: ticks is int ? Duration(microseconds: ticks ~/ 10) : null,
      hasPrimaryImage: imageTags is Map && imageTags.containsKey('Primary'),
      albumPrimaryImageTag: j['AlbumPrimaryImageTag'] as String?,
      childCount: (j['ChildCount'] ?? j['SongCount']) as int?,
      playlistItemId: j['PlaylistItemId'] as String?,
      normalizationGain: (j['NormalizationGain'] as num?)?.toDouble(),
      mediaType: switch (j['MediaType']) {
        final String m when m != 'Unknown' => m,
        _ => null,
      },
    );
  }

  JItem withMusicCount(int n) => JItem(
    id: id,
    name: name,
    type: type,
    albumId: albumId,
    album: album,
    albumArtist: albumArtist,
    artists: artists,
    indexNumber: indexNumber,
    discNumber: discNumber,
    productionYear: productionYear,
    duration: duration,
    hasPrimaryImage: hasPrimaryImage,
    albumPrimaryImageTag: albumPrimaryImageTag,
    childCount: childCount,
    playlistItemId: playlistItemId,
    mediaType: mediaType,
    musicCount: n,
    normalizationGain: normalizationGain,
  );

  /// Artiste(s) à afficher sous le titre.
  String get artistLine =>
      artists.isNotEmpty ? artists.join(', ') : (albumArtist ?? '');

  /// Identifiant de l'élément qui porte la pochette (le morceau ou son album).
  String? get imageItemId {
    if (hasPrimaryImage) return id;
    if (albumPrimaryImageTag != null && albumId != null) return albumId;
    return null;
  }
}

/// Règles de nommage des playlists sur le serveur :
/// - « __Compte__ Nom » (ex. « __Alice__ Divers ») : importée de Spotify,
///   visible seulement par ce compte, affichée « Divers (Spotify) »,
///   verrouillée (aucune modification) ;
/// - « _-Compte-_ Nom » (ex. « _-Alice-_ Rock ») : playlist privée créée dans
///   JellyMusic, visible seulement par ce compte, affichée « Rock » ;
/// - tout autre nom : playlist publique, visible par tous les comptes.
extension PlaylistRules on JItem {
  static final _prefix = RegExp(r'^__(.+?)__\s*(.*)$', dotAll: true);
  static final _private = RegExp(r'^_-(.+?)-_\s*(.*)$', dotAll: true);

  /// Nom à enregistrer sur le serveur pour le nom affiché [display] :
  /// préfixé « _-Compte-_ » si la playlist est privée à [privateFor].
  static String serverName(String display, {String? privateFor}) {
    final d = display.trim();
    return privateFor == null ? d : '_-${privateFor.trim()}-_ $d';
  }

  /// Compte propriétaire d'une playlist privée, ou null.
  String? get privateOwner {
    if (type != 'Playlist' || isSpotify) return null;
    return _private.firstMatch(name)?.group(1)?.trim();
  }

  bool get isPrivate => privateOwner != null;

  /// Compte auquel la playlist est réservée, ou null pour une playlist
  /// ordinaire.
  String? get spotifyOwner {
    if (type != 'Playlist') return null;
    return _prefix.firstMatch(name)?.group(1)?.trim();
  }

  bool get isSpotify => spotifyOwner != null;

  /// Verrouillée : impossible de la supprimer, renommer, ou d'y ajouter,
  /// retirer ou déplacer des morceaux.
  bool get isLocked => isSpotify;

  /// Nom à afficher : « Divers (Spotify) » au lieu de « __Alice__ Divers ».
  String get displayName {
    if (type != 'Playlist') return name;
    final m = _prefix.firstMatch(name);
    if (m != null) {
      final rest = m.group(2)!.trim();
      return rest.isEmpty ? 'Spotify' : '$rest (Spotify)';
    }
    final p = _private.firstMatch(name);
    if (p != null) return p.group(2)!.trim();
    return name;
  }

  /// Nom sans préfixe ni « (Spotify) » : base proposée pour un clone.
  String get baseName {
    final m = type == 'Playlist' ? _prefix.firstMatch(name) : null;
    return m != null ? m.group(2)!.trim() : displayName;
  }

  /// Vrai si ce compte peut voir la playlist.
  bool visibleTo(String username) {
    final owner = spotifyOwner ?? privateOwner;
    return owner == null ||
        owner.toLowerCase() == username.trim().toLowerCase();
  }
}

class ItemsPage {
  final List<JItem> items;
  final int total;
  const ItemsPage(this.items, this.total);
}

String formatDuration(Duration? d) {
  if (d == null) return '';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}
