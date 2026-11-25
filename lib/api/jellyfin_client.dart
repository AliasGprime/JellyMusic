import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:http/http.dart' as http;

import '../models.dart';

class JellyfinException implements Exception {
  final String message;
  JellyfinException(this.message);

  /// Le serveur ne répond pas (pas d'Internet, serveur éteint…).
  static final unreachable = JellyfinException(
    'Impossible de joindre le serveur. Vérifiez votre connexion Internet.',
  );
  @override
  String toString() => message;
}

/// Client minimal de l'API REST de Jellyfin, limité à la musique.
class JellyfinClient {
  static const clientName = 'JellyMusic';
  static const clientVersion = '1.0.0';
  static String get deviceName => kIsWeb ? 'Navigateur web' : 'Android';

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
    // Listes d'éléments : demander aussi la correction de volume (dB).
    if (query != null && path.endsWith('/Items')) {
      final f = query['Fields'];
      query = {
        ...query,
        'Fields': f == null ? 'NormalizationGain' : '$f,NormalizationGain',
      };
    }
    final http.Response res;
    try {
      res = await _http
          .get(_uri(path, query), headers: _headers)
          .timeout(const Duration(seconds: 20));
    } on http.ClientException {
      throw JellyfinException.unreachable;
    } on TimeoutException {
      throw JellyfinException.unreachable;
    }
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

  /// Vrai si le serveur répond rapidement (sert à choisir, au démarrage,
  /// entre le mode normal et le mode hors connexion).
  Future<bool> reachable({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final res = await _http
          .get(_uri('/System/Info/Public'), headers: _headers)
          .timeout(timeout);
      return res.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  /// Vrai si le serveur répond mais ne renvoie aucun morceau pour ce
  /// compte (ex. : analyse de la bibliothèque en cours). Faux en cas
  /// d'erreur : les pages afficheront alors l'erreur elles-mêmes.
  Future<bool> libraryEmpty() async {
    try {
      final r = await _get('/Items', {
        'userId': userId!,
        'IncludeItemTypes': 'Audio',
        'Recursive': 'true',
        'Limit': '1',
        'EnableTotalRecordCount': 'true',
      }).timeout(const Duration(seconds: 10));
      final m = r as Map<String, dynamic>;
      return (m['TotalRecordCount'] as int? ?? 0) == 0 &&
          ((m['Items'] as List?)?.isEmpty ?? true);
    } catch (_) {
      return false;
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

  /// Filtre par première lettre : « A » à « Z », ou « # » pour tout ce qui
  /// commence par un chiffre ou un symbole (avant « A »).
  static Map<String, String> _letterFilter(String? letter) => switch (letter) {
    null => const {},
    '#' => const {'NameLessThan': 'A'},
    _ => {'NameStartsWith': letter},
  };

  Future<ItemsPage> artists({
    int start = 0,
    int? limit,
    String? letter,
  }) async => _page(
    await _get('/Artists/AlbumArtists', {
      'userId': userId!,
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'EnableImageTypes': 'Primary',
      ..._letterFilter(letter),
      ..._paging(start, limit),
    }),
  );

  Future<ItemsPage> albums({
    String? artistId,
    int start = 0,
    int? limit,
    String? letter,
  }) async => _page(
    await _get('/Items', {
      'userId': userId!,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': artistId != null ? 'ProductionYear,SortName' : 'SortName',
      'SortOrder': artistId != null ? 'Descending,Ascending' : 'Ascending',
      if (artistId != null) 'AlbumArtistIds': artistId,
      'Fields': 'ChildCount',
      ..._letterFilter(letter),
      ..._paging(start, limit),
    }),
  );

  Future<ItemsPage> songs({
    int start = 0,
    int? limit,
    String? letter,
    bool random = false,
  }) async {
    if (letter != null) {
      // Pour les morceaux, le filtre par lettre de Jellyfin ne marche pas
      // (il compare un nom de tri qui commence souvent par le n° de piste) :
      // on filtre ici sur le titre.
      final all = (await _songsSnapshot())
          .where((s) => letterOf(s.name) == letter)
          .toList();
      if (random) all.shuffle();
      final end = limit == null ? all.length : (start + limit);
      return ItemsPage(
        all.sublist(start.clamp(0, all.length), end.clamp(0, all.length)),
        all.length,
      );
    }
    return _page(
      await _get('/Items', {
        'userId': userId!,
        'IncludeItemTypes': 'Audio',
        'Recursive': 'true',
        'SortBy': random ? 'Random' : 'SortName',
        'SortOrder': 'Ascending',
        ..._paging(start, limit),
      }),
    );
  }

  /// Lettre de rangement d'un titre : première lettre (sans accent) ou
  /// chiffre ; « # » pour un chiffre ou un titre sans lettre.
  static String letterOf(String name) {
    const accents = {
      'À': 'A', 'Â': 'A', 'Ä': 'A', 'Á': 'A', 'Ã': 'A', 'Å': 'A', //
      'Ç': 'C', 'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E', 'Í': 'I', //
      'Ì': 'I', 'Î': 'I', 'Ï': 'I', 'Ñ': 'N', 'Ó': 'O', 'Ò': 'O', //
      'Ô': 'O', 'Ö': 'O', 'Õ': 'O', 'Ú': 'U', 'Ù': 'U', 'Û': 'U', //
      'Ü': 'U', 'Ý': 'Y', 'Ÿ': 'Y',
    };
    for (final ch in name.toUpperCase().split('')) {
      final c = accents[ch] ?? ch;
      if (RegExp(r'[A-Z]').hasMatch(c)) return c;
      if (RegExp(r'[0-9]').hasMatch(c)) return '#';
    }
    return '#';
  }

  /// Tous les morceaux (triés par titre), gardés 5 minutes en mémoire pour
  /// filtrer rapidement par lettre.
  Future<List<JItem>>? _songsCache;
  DateTime _songsCacheTime = DateTime(2000);

  Future<List<JItem>> _songsSnapshot() {
    final fresh =
        DateTime.now().difference(_songsCacheTime) < const Duration(minutes: 5);
    if (_songsCache != null && fresh) return _songsCache!;
    _songsCacheTime = DateTime.now();
    return _songsCache =
        () async {
          final all = <JItem>[];
          while (true) {
            final page = await songs(start: all.length, limit: 1000);
            all.addAll(page.items);
            if (page.items.isEmpty || all.length >= page.total) break;
          }
          return all;
        }().catchError((Object e) {
          _songsCache = null; // nouvel essai au prochain appel
          throw e;
        });
  }

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
        (p) async =>
            p.withMusic([for (final t in await playlistTracks(p.id)) t.id]),
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
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _http.send(req).timeout(const Duration(seconds: 20)),
      );
    } on http.ClientException {
      throw JellyfinException.unreachable;
    } on TimeoutException {
      throw JellyfinException.unreachable;
    }
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

  // ---- Réglages de l'application, propres à chaque compte ----
  // Rangés dans les « préférences d'affichage » de l'utilisateur sur le
  // serveur Jellyfin (champ CustomPrefs), sous l'identifiant « jellymusic ».

  static const _prefsId = 'jellymusic';

  Map<String, String> get _prefsQuery => {
    'userId': userId!,
    'client': clientName,
  };

  Future<Map<String, dynamic>> _displayPrefs() async =>
      (await _get('/DisplayPreferences/$_prefsId', _prefsQuery))
          as Map<String, dynamic>;

  Future<String?> getUserSetting(String key) async {
    final custom = (await _displayPrefs())['CustomPrefs'];
    return custom is Map ? custom[key] as String? : null;
  }

  Future<void> setUserSetting(String key, String value) async {
    final prefs = await _displayPrefs();
    final custom = Map<String, dynamic>.from(
      (prefs['CustomPrefs'] as Map?) ?? const {},
    );
    custom[key] = value;
    prefs['CustomPrefs'] = custom;
    await _send(
      'POST',
      '/DisplayPreferences/$_prefsId',
      query: _prefsQuery,
      body: prefs,
    );
  }

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
  /// Flux HLS (morceaux de 3 secondes) converti en MP3 à [kbps] : le
  /// lecteur ne charge que le segment utile, donc se déplacer dans le
  /// morceau est rapide (un flux MP3 continu obligerait à tout télécharger
  /// jusqu'à l'endroit voulu). Le jeton est dans l'adresse : il est repris
  /// par Jellyfin dans l'adresse de chaque segment.
  String hlsUrl(String itemId, int kbps) => _uri('/Audio/$itemId/main.m3u8', {
    'UserId': userId!,
    'DeviceId': deviceId,
    'ApiKey': token!,
    'MediaSourceId': itemId,
    'AudioCodec': 'mp3',
    'AudioBitRate': '${kbps * 1000}',
    'SegmentContainer': 'ts',
    // Une session de lecture par morceau lancé (Jellyfin y range ses
    // conversions en cours).
    'PlaySessionId':
        '${itemId.substring(0, 8)}${DateTime.now().millisecondsSinceEpoch}',
  }).toString();

  /// Débit des fichiers originaux (bits/s) de chaque morceau, pour estimer
  /// la place d'un téléchargement en qualité originale.
  Future<Map<String, int>> sourceBitrates(List<String> ids) async {
    final out = <String, int>{};
    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.skip(i).take(100).join(',');
      final j = await _get('/Items', {
        'userId': userId!,
        'Ids': chunk,
        'Fields': 'MediaSources',
      }) as Map<String, dynamic>;
      for (final it in (j['Items'] as List? ?? const [])) {
        final sources = it['MediaSources'] as List?;
        final bitrate = sources == null || sources.isEmpty
            ? null
            : (sources.first as Map)['Bitrate'];
        if (bitrate is num) out[it['Id'] as String] = bitrate.toInt();
      }
    }
    return out;
  }

  Map<String, String> get streamHeaders => {
    'Authorization': _authHeader,
    'X-Emby-Authorization': _authHeader,
  };

  /// URL de diffusion : le serveur envoie le fichier original si le téléphone
  /// sait le lire, sinon il le convertit en MP3.
  /// Adresse du flux audio. [maxKbps] : débit maximal en kb/s ; au-delà,
  /// Jellyfin convertit en MP3 à ce débit. null : fichier original, sans
  /// conversion (ex. FLAC sans perte).
  String streamUrl(
    String itemId, {
    int? maxKbps = 320,
  }) => _uri('/Audio/$itemId/universal', {
    'UserId': userId!,
    'DeviceId': deviceId,
    // Le navigateur ne peut pas ajouter d'en-tête au flux audio : sur le
    // web, le jeton passe donc dans l'adresse (paramètre ApiKey).
    if (kIsWeb) 'ApiKey': token!,
    'MaxStreamingBitrate': maxKbps == null ? '200000000' : '${maxKbps * 1000}',
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
