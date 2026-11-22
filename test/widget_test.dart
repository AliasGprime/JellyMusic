import 'package:flutter_test/flutter_test.dart';
import 'package:jellymusic/api/jellyfin_client.dart';
import 'package:jellymusic/models.dart';

void main() {
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
