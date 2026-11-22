import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dépôt GitHub public où sont publiées les versions de l'application.
const updateRepo = 'AliasGprime/JellyMusic';

/// Une version publiée sur GitHub.
class AppRelease {
  final String version; // ex. 1.2.0
  final String tag; // ex. v1.2.0
  final String notes;
  final String apkUrl;
  final int apkSize;
  final String? sha256;
  final String pageUrl;

  const AppRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.apkSize,
    required this.sha256,
    required this.pageUrl,
  });
}

/// Compare deux numéros de version « 1.2.3 ». Renvoie > 0 si [a] est plus récent.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split(RegExp(r'[.+-]'))
      .take(3)
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final pa = parts(a), pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

class Updater {
  static const _kSkipped = 'update.skippedVersion';

  /// Version installée (ex. 1.0.0).
  static Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// Interroge GitHub. Renvoie la dernière version si elle est plus récente
  /// que celle installée, sinon null. Les versions « ignorées » par
  /// l'utilisateur ne sont pas proposées, sauf si [manual] est vrai.
  static Future<AppRelease?> check({bool manual = false}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final res = await http
        .get(
          Uri.parse('https://api.github.com/repos/$updateRepo/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) return null; // aucune version publiée
    if (res.statusCode != 200) {
      throw Exception('GitHub a répondu ${res.statusCode}');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String?) ?? '';
    final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
    final assets = ((j['assets'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final apk = assets
        .where((a) => (a['name'] as String? ?? '').endsWith('.apk'))
        .firstOrNull;
    if (apk == null || version.isEmpty) return null;

    final installed = await currentVersion();
    if (compareVersions(version, installed) <= 0) return null;
    if (!manual) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_kSkipped) == version) return null;
    }

    final digest = apk['digest'] as String?; // « sha256:… » fourni par GitHub
    return AppRelease(
      version: version,
      tag: tag,
      notes: ((j['body'] as String?) ?? '').trim(),
      apkUrl: apk['browser_download_url'] as String,
      apkSize: (apk['size'] as int?) ?? 0,
      sha256: digest != null && digest.startsWith('sha256:')
          ? digest.substring(7)
          : null,
      pageUrl: (j['html_url'] as String?) ?? '',
    );
  }

  static Future<void> skip(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSkipped, version);
  }
}
