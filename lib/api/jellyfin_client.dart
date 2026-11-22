import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

class JellyfinException implements Exception {
  final String message;
  JellyfinException(this.message);
  @override
  String toString() => message;
}

/// Client minimal de l'API REST de Jellyfin, limité à la musique.
class JellyfinClient {
  static const clientName = 'JellyMusic';
  static const clientVersion = '1.0.0';
  static const deviceName = 'Android';

  final String baseUrl;
  final String deviceId;
  final String? token;
  final String? userId;
  final http.Client _http;

  JellyfinClient({
    required String baseUrl,
    required this.deviceId,
    this.token,
    this.userId,
    http.Client? httpClient,
  }) : baseUrl = normalizeUrl(baseUrl),
       _http = httpClient ?? http.Client();

  static String normalizeUrl(String url) {
    var u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  String get _authHeader {
    var s =
        'MediaBrowser Client="$clientName", Device="$deviceName", '
        'DeviceId="$deviceId", Version="$clientVersion"';
    if (token != null) s += ', Token="$token"';
    return s;
  }

  Map<String, String> get _headers => {
    'Authorization': _authHeader,
    'X-Emby-Authorization': _authHeader,
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Uri _uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$baseUrl$path');
    return (query == null || query.isEmpty)
        ? u
        : u.replace(queryParameters: query);
  }

  Future<dynamic> _get(String path, [Map<String, String>? query]) async {
    final res = await _http
        .get(_uri(path, query), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) {
      throw JellyfinException('Session expirée, reconnectez-vous.');
    }
    if (res.statusCode >= 400) {
      throw JellyfinException('Erreur du serveur (${res.statusCode}).');
    }
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<void> _post(String path, Map<String, dynamic> body) async {
    try {
      await _http
          .post(_uri(path), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Les rapports de lecture ne doivent jamais bloquer la musique.
    }
  }

  /// Vérifie que l'adresse pointe bien vers un serveur Jellyfin.
  Future<String> publicServerName() async {
    try {
      final j = await _get('/System/Info/Public') as Map<String, dynamic>;
      return (j['ServerName'] as String?) ?? 'Jellyfin';
    } on JellyfinException {
      rethrow;
    } catch (_) {
      throw JellyfinException(
        'Impossible de joindre le serveur à $baseUrl. Vérifiez l\'adresse et votre connexion.',
      );
    }
  }

  /// Authentifie l'utilisateur et renvoie un client portant le jeton.
  Future<JellyfinClient> login(String username, String password) async {
    await publicServerName();
    final res = await _http
        .post(
          _uri('/Users/AuthenticateByName'),
          headers: _headers,
          body: jsonEncode({'Username': username, 'Pw': password}),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401 || res.statusCode == 400) {
      throw JellyfinException('Nom d\'utilisateur ou mot de passe incorrect.');
    }
    if (res.statusCode >= 400) {
      throw JellyfinException('Échec de la connexion (${res.statusCode}).');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return JellyfinClient(
      baseUrl: baseUrl,
      deviceId: deviceId,
      token: j['AccessToken'] as String,
      userId: (j['User'] as Map<String, dynamic>)['Id'] as String,
      httpClient: _http,
    );
  }

  Future<void> logout() => _post('/Sessions/Logout', {});

  ItemsPage _page(dynamic j) {
    final m = j as Map<String, dynamic>;
    final items = ((m['Items'] as List?) ?? const [])
        .map((e) => JItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return ItemsPage(items, (m['TotalRecordCount'] as int?) ?? items.length);
  }

  Map<String, String> _paging(int start, int? limit) => {
    'StartIndex': '$start',
    if (limit != null) 'Limit': '$limit',
  };

  Future<ItemsPage> artists({int start = 0, int? limit}) async => _page(
    await _get('/Artists/AlbumArtists', {
      'userId': userId!,
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'EnableImageTypes': 'Primary',
      ..._paging(start, limit),
    }),
  );

  Future<ItemsPage> albums({
    String? artistId,
    int start = 0,
    int? limit,
  }) async => _page(
    await _get('/Items', {
      'userId': userId!,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': artistId != null ? 'ProductionYear,SortName' : 'SortName',
      'SortOrder': artistId != null ? 'Descending,Ascending' : 'Ascending',
      if (artistId != null) 'AlbumArtistIds': artistId,
      'Fields': 'ChildCount',
      ..._paging(start, limit),
    }),
  );

  Future<ItemsPage> songs({int start = 0, int? limit}) async => _page(
    await _get('/Items', {
      'userId': userId!,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      ..._paging(start, limit),
    }),
  );

  /// Sélection aléatoire de morceaux dans toute la bibliothèque.
  Future<List<JItem>> randomSongs({int limit = 200}) async => _page(
    await _get('/Items', {
      'userId': userId!,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'Random',
      'Limit': '$limit',
    }),
  ).items;

  Future<List<JItem>> albumTracks(String albumId) async => _page(
    await _get('/Items', {
      'userId': userId!,
      'ParentId': albumId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
      'SortOrder': 'Ascending',
    }),
  ).items;

  /// Tous les morceaux d'un artiste (pour « Lecture aléatoire » sur un artiste).
  Future<List<JItem>> artistTracks(String artistId) async => _page(
    await _get('/Items', {
      'userId': userId!,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'ArtistIds': artistId,
      'SortBy': 'Album,ParentIndexNumber,IndexNumber,SortName',
    }),
  ).items;

  /// Toutes les playlists (sauf celles typées vidéo), chacune avec son
  /// nombre réel de morceaux de musique dans [JItem.musicCount].
  Future<List<JItem>> playlists() async {
    final all = _page(
      await _get('/Items', {
        'userId': userId!,
        'IncludeItemTypes': 'Playlist',
        'Recursive': 'true',
        'SortBy': 'SortName',
        'Fields': 'ChildCount',
      }),
    ).items.where((p) => p.mediaType == null || p.mediaType == 'Audio');
    return Future.wait(
      all.map(
        (p) async => p.withMusicCount((await playlistTracks(p.id)).length),
      ),
    );
  }

  Future<List<JItem>> playlistTracks(String playlistId) async =>
      _page(await _get('/Playlists/$playlistId/Items', {'userId': userId!}))
          .items
          .where((i) => i.type == 'Audio')
          .toList();

  /// Requête qui modifie le serveur ; lève une exception en cas d'échec.
  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final req = http.Request(method, _uri(path, query))
      ..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(
      await _http.send(req).timeout(const Duration(seconds: 20)),
    );
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw JellyfinException(
        'Action refusée par le serveur (${res.statusCode}).',
      );
    }
    if (res.statusCode >= 400) {
      throw JellyfinException('Erreur du serveur (${res.statusCode}).');
    }
    if (res.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  /// Crée une playlist de musique et renvoie son identifiant.
  Future<String> createPlaylist(
    String name, {
    List<String> itemIds = const [],
  }) async {
    final j = await _send(
      'POST',
      '/Playlists',
      body: {
        'Name': name,
        'Ids': itemIds,
        'UserId': userId,
        'MediaType': 'Audio',
      },
    ) as Map<String, dynamic>;
    return j['Id'] as String;
  }

  Future<void> addToPlaylist(String playlistId, List<String> itemIds) => _send(
    'POST',
    '/Playlists/$playlistId/Items',
    query: {'ids': itemIds.join(','), 'userId': userId!},
  );

  /// Retire des entrées (identifiants « PlaylistItemId ») d'une playlist.
  Future<void> removeFromPlaylist(String playlistId, List<String> entryIds) =>
      _send(
        'DELETE',
        '/Playlists/$playlistId/Items',
        query: {'entryIds': entryIds.join(',')},
      );

  Future<void> movePlaylistItem(
    String playlistId,
    String entryId,
    int newIndex,
  ) => _send('POST', '/Playlists/$playlistId/Items/$entryId/Move/$newIndex');

  Future<void> renamePlaylist(String playlistId, String name) =>
      _send('POST', '/Playlists/$playlistId', body: {'Name': name});

  Future<void> deletePlaylist(String playlistId) =>
      _send('DELETE', '/Items/$playlistId');

  Future<List<JItem>> search(String term) async => _page(
    await _get('/Items', {
      'userId': userId!,
      'searchTerm': term,
      'IncludeItemTypes': 'Audio,MusicAlbum,MusicArtist,Playlist',
      'Recursive': 'true',
      'Limit': '60',
    }),
  ).items;

  String? imageUrl(String? itemId, {int maxWidth = 400}) {
    if (itemId == null) return null;
    return _uri('/Items/$itemId/Images/Primary', {
      'maxWidth': '$maxWidth',
      'quality': '90',
    }).toString();
  }

  /// En-têtes d'authentification pour le flux audio. Jellyfin 12 n'accepte
  /// plus le jeton dans l'URL (api_key) : il doit passer dans un en-tête.
  Map<String, String> get streamHeaders => {
    'Authorization': _authHeader,
    'X-Emby-Authorization': _authHeader,
  };

  /// URL de diffusion : le serveur envoie le fichier original si le téléphone
  /// sait le lire, sinon il le convertit en MP3.
  String streamUrl(String itemId) => _uri('/Audio/$itemId/universal', {
    'UserId': userId!,
    'DeviceId': deviceId,
    'MaxStreamingBitrate': '320000',
    'Container':
        'opus,webm|opus,mp3,aac,m4a|aac,m4b|aac,flac,webma,webm|webma,wav,ogg',
    'TranscodingContainer': 'mp3',
    'TranscodingProtocol': 'http',
    'AudioCodec': 'mp3',
  }).toString();

  static int _ticks(Duration d) => d.inMicroseconds * 10;

  Future<void> reportPlaying(String itemId) => _post('/Sessions/Playing', {
    'ItemId': itemId,
    'CanSeek': true,
    'PlayMethod': 'DirectStream',
  });

  Future<void> reportProgress(String itemId, Duration position, bool paused) =>
      _post('/Sessions/Playing/Progress', {
        'ItemId': itemId,
        'PositionTicks': _ticks(position),
        'IsPaused': paused,
        'CanSeek': true,
      });

  Future<void> reportStopped(String itemId, Duration position) => _post(
    '/Sessions/Playing/Stopped',
    {'ItemId': itemId, 'PositionTicks': _ticks(position)},
  );
}
