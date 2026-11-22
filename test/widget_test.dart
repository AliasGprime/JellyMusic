import 'package:flutter_test/flutter_test.dart';
import 'package:jellymusic/api/jellyfin_client.dart';
import 'package:jellymusic/models.dart';
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

  test('nettoie les notes de version Markdown', () {
    expect(
      plainNotes('**Fonctions**\n- Lecture `rapide`\n## Titre'),
      'Fonctions\n• Lecture rapide\nTitre',
    );
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
}
