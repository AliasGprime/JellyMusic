import 'package:flutter_test/flutter_test.dart';
import 'package:jellymusic/audio/android_eq.dart';
import 'package:jellymusic/api/jellyfin_client.dart';
import 'package:jellymusic/models.dart';
import 'package:jellymusic/state/download_store.dart';
import 'package:jellymusic/state/equalizer_store.dart';
import 'package:jellymusic/state/player_controller.dart';
import 'package:jellymusic/state/session.dart';
import 'package:jellymusic/ui/offline_library.dart';
import 'package:jellymusic/update/update_dialog.dart';
import 'package:jellymusic/update/updater.dart';

void main() {
  test('compare les numéros de version', () {
    expect(compareVersions('1.0.1', '1.0.0') > 0, isTrue);
    expect(compareVersions('v1.2.0', '1.10.0') < 0, isTrue);
    expect(compareVersions('2.0.0', '1.99.99') > 0, isTrue);
    expect(compareVersions('1.0.0', '1.0.0+5'), 0);
    expect(compareVersions('1.0', '1.0.0'), 0);
  });

  test('lit le fichier serveur.txt', () {
    expect(
      Session.parseServerFile('http://mon-serveur:8096/\n'),
      'http://mon-serveur:8096',
    );
    expect(
      Session.parseServerFile('# commentaire\n\n  https://x.ca  \nautre'),
      'https://x.ca',
    );
    expect(Session.parseServerFile('# seulement des commentaires\n'), isNull);
    expect(Session.parseServerFile(''), isNull);
    expect(Session.parseServerFile('<html>Not Found</html>'), isNull);
  });

  test('lit les réglages de l\'égaliseur', () {
    final s = EqSettings.fromJson(
      '{"enabled":true,"preamp":-3,"gains":[20,-20,1],"preset":"Rock"}',
    );
    expect(s.enabled, isTrue);
    expect(s.preamp, -3);
    expect(s.gains.length, 10); // bandes manquantes complétées
    expect(s.gains[0], eqMaxDb); // valeurs bornées à ±12 dB
    expect(s.gains[1], eqMinDb);
    expect(s.preset, 'Rock');
    expect(eqPresets.values.every((g) => g.length == 10), isTrue);
  });

  test(
    'aléatoire : « Lire ensuite » passe juste après le morceau en cours',
    () {
      final o = QueueShuffleOrder()..indices.addAll([3, 0, 2, 1]);
      // En cours : morceau 0 (2e dans l'ordre). Insertion à l'index 1.
      o.insertAfter = 0;
      o.insert(1, 1);
      expect(o.indices, [4, 0, 1, 3, 2]);
      // « Ajouter à la file » : à la fin.
      o.insert(5, 1);
      expect(o.indices, [4, 0, 1, 3, 2, 5]);
    },
  );

  test('nettoie les notes de version Markdown', () {
    expect(
      plainNotes('**Fonctions**\n- Lecture `rapide`\n## Titre'),
      'Fonctions\n• Lecture rapide\nTitre',
    );
  });

  test('playlists Spotify « __Compte__ Nom »', () {
    JItem pl(String name) =>
        JItem.fromJson({'Id': 'p', 'Name': name, 'Type': 'Playlist'});
    final s = pl('__Alice__ Divers');
    expect(s.spotifyOwner, 'Alice');
    expect(s.displayName, 'Divers (Spotify)');
    expect(s.isLocked, isTrue);
    expect(s.visibleTo('alice'), isTrue); // sans tenir compte des majuscules
    expect(s.visibleTo('Bob'), isFalse);
    final n = pl('Ma playlist');
    expect(n.isLocked, isFalse);
    expect(n.displayName, 'Ma playlist');
    expect(n.visibleTo('Bob'), isTrue);
  });

  test('playlists privées « _-Compte-_ Nom »', () {
    JItem pl(String name) =>
        JItem.fromJson({'Id': 'p', 'Name': name, 'Type': 'Playlist'});
    expect(
      PlaylistRules.serverName('Rock', privateFor: 'Alice'),
      '_-Alice-_ Rock',
    );
    expect(PlaylistRules.serverName(' Rock '), 'Rock');
    final r = pl('_-Alice-_ Rock');
    expect(r.privateOwner, 'Alice');
    expect(r.isPrivate, isTrue);
    expect(r.isLocked, isFalse);
    expect(r.displayName, 'Rock');
    expect(r.visibleTo('Alice'), isTrue);
    expect(r.visibleTo('Bob'), isFalse);
    // Une playlist Spotify n'est jamais prise pour une privée, et inversement.
    expect(pl('__Alice__ Divers').isPrivate, isFalse);
    expect(r.isSpotify, isFalse);
    expect(pl('__Alice__ Divers').baseName, 'Divers');
  });

  test('lettre de rangement d\'un titre', () {
    expect(JellyfinClient.letterOf('Makeba'), 'M');
    expect(JellyfinClient.letterOf('été indien'), 'E');
    expect(JellyfinClient.letterOf('(Don\'t Fear) The Reaper'), 'D');
    expect(JellyfinClient.letterOf('99 Red Balloons'), '#');
    expect(JellyfinClient.letterOf('…'), '#');
  });

  test('normalise l\'adresse du serveur', () {
    expect(
      JellyfinClient.normalizeUrl('mon-serveur:8096/'),
      'http://mon-serveur:8096',
    );
    expect(JellyfinClient.normalizeUrl(' https://x.ca '), 'https://x.ca');
  });

  test('lit un morceau Jellyfin', () {
    final t = JItem.fromJson({
      'Id': 'a1',
      'Name': 'Chanson',
      'Type': 'Audio',
      'AlbumId': 'b2',
      'Artists': ['Artiste'],
      'RunTimeTicks': 1950000000,
      'ImageTags': {},
      'AlbumPrimaryImageTag': 'tag',
    });
    expect(t.duration, const Duration(seconds: 195));
    expect(formatDuration(t.duration), '3:15');
    expect(t.imageItemId, 'b2');
    expect(t.artistLine, 'Artiste');
  });

  test('état hors connexion des playlists', () {
    final d = DownloadStore(Session());
    DownloadEntry e(String id) => DownloadEntry(
      track: JItem(id: id, name: id, type: 'Audio'),
      file: '/x/$id.mp3',
      bytes: 1,
    );
    expect(d.offlineStateOf(['a', 'b']), OfflineState.none);
    d.entries['a'] = e('a');
    expect(d.offlineStateOf(['a', 'b', 'c']), OfflineState.partial);
    expect(d.offlineStateOf(['b', 'c']), OfflineState.none);
    d.entries['b'] = e('b');
    expect(d.offlineStateOf(['a', 'b']), OfflineState.complete);
    expect(d.offlineStateOf(null), OfflineState.none);
  });

  test('lettres de la barre A-Z hors connexion', () {
    expect(OfflineLibrary.startsWith('Éric', 'E'), isTrue);
    expect(OfflineLibrary.startsWith('2Frères', '#'), isTrue);
    expect(OfflineLibrary.startsWith('2Frères', 'F'), isFalse);
    expect(OfflineLibrary.startsWith('abba', 'A'), isTrue);
    expect(OfflineLibrary.startsWith('Zaz', null), isTrue);
  });

  test('genres des morceaux téléchargés', () {
    final t = JItem.fromJson({
      'Id': 'a',
      'Name': 'A',
      'Type': 'Audio',
      'Genres': ['Rock', 'Pop'],
    });
    expect(t.genres, ['Rock', 'Pop']);
    expect(JItem.fromJson(t.toJson()).genres, ['Rock', 'Pop']);
    final old = JItem(id: 'b', name: 'B', type: 'Audio');
    expect(old.genres, isNull);
    expect(old.withGenres(['rock']).genres, ['rock']);
    expect(old.withGenres(['rock']).name, 'B');

    final d = DownloadStore(Session());
    for (final x in [
      t,
      old.withGenres(['rock']),
      old,
    ]) {
      d.entries[x.id + (x.genres == null ? '0' : '')] = DownloadEntry(
        track: x,
        file: '/x',
        bytes: 1,
      );
    }
    final lib = OfflineLibrary(d);
    expect(lib.genres.map((g) => g.name), ['Pop', 'Rock']);
    expect(lib.tracksOfGenre('ROCK').length, 2);
  });

  test('égaliseur Android : 10 bandes vers les bandes du téléphone', () {
    final g = <double>[6, 5, 4, 2, 0, 0, 0, 0, 0, 0];
    expect(curveAt(31, g), closeTo(6, 0.01));
    expect(curveAt(10, g), 6); // sous la première bande
    expect(curveAt(20000, g), 0); // au-dessus de la dernière
    expect(curveAt(62, g), closeTo(5, 0.1));
    // Entre 62 et 125 Hz (milieu en octaves ≈ 88 Hz) : entre 5 et 4.
    expect(curveAt(88, g), closeTo(4.5, 0.1));
    // Fréquence en millihertz (certains téléphones).
    expect(curveAt(62000, g), closeTo(5, 0.1)); // 62 Hz en millihertz
  });
}
