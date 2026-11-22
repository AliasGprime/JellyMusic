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
