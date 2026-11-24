import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/jellyfin_client.dart';

/// Aucune adresse par défaut : chacun entre celle de son propre serveur.
const defaultServerUrl = '';

/// Garde la connexion au serveur et la mémorise entre les lancements.
class Session extends ChangeNotifier {
  static const _kServer = 'server';
  static const _kToken = 'token';
  static const _kUser = 'userId';
  static const _kUsername = 'username';
  static const _kDevice = 'deviceId';

  late SharedPreferences _prefs;
  late String deviceId;
  JellyfinClient? client;
  String serverUrl = defaultServerUrl;
  String username = '';

  /// Sur le web : adresse imposée par le fichier « serveur.txt » placé à côté
  /// de la page. Quand elle existe, l'écran de connexion ne la demande plus.
  String? fixedServerUrl;
  bool get serverLocked => fixedServerUrl != null;

  bool get isLoggedIn => client?.token != null;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    deviceId = _prefs.getString(_kDevice) ?? _newDeviceId();
    await _prefs.setString(_kDevice, deviceId);
    serverUrl = _prefs.getString(_kServer) ?? _guessServerUrl();
    username = _prefs.getString(_kUsername) ?? '';
    var token = _prefs.getString(_kToken);
    final userId = _prefs.getString(_kUser);

    if (kIsWeb) {
      fixedServerUrl = await readServerFile();
      final fixed = fixedServerUrl;
      if (fixed != null) {
        // L'adresse du fichier a changé : l'ancienne connexion ne vaut plus.
        if (JellyfinClient.normalizeUrl(serverUrl) != fixed) {
          token = null;
          await _prefs.remove(_kToken);
          await _prefs.remove(_kUser);
        }
        serverUrl = fixed;
      }
    }

    if (token != null && userId != null) {
      client = JellyfinClient(
        baseUrl: serverUrl,
        deviceId: deviceId,
        token: token,
        userId: userId,
      );
    }
  }

  /// Sur le web, Jellyfin est sur la même machine que le site : on propose
  /// la même adresse avec le port 8096 de Jellyfin. Rien n'est écrit en dur.
  static String _guessServerUrl() {
    if (!kIsWeb) return defaultServerUrl;
    final base = Uri.base;
    if (base.host.isEmpty) return defaultServerUrl;
    return '${base.scheme}://${base.host}:8096';
  }

  /// Lit « serveur.txt » à côté de la page web. Les lignes vides et celles
  /// qui commencent par # sont ignorées ; la première autre ligne doit être
  /// une adresse http:// ou https://. Absent, vide ou invalide → null.
  static Future<String?> readServerFile() async {
    try {
      final uri = Uri.base
          .resolve('serveur.txt')
          .replace(
            queryParameters: {
              't': '${DateTime.now().millisecondsSinceEpoch}', // pas de cache
            },
          );
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      return parseServerFile(res.body);
    } catch (_) {
      return null;
    }
  }

  static String? parseServerFile(String text) {
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (!RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(line)) {
        return null;
      }
      return JellyfinClient.normalizeUrl(line);
    }
    return null;
  }

  static String _newDeviceId() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> login(String server, String user, String password) async {
    final anon = JellyfinClient(
      baseUrl: fixedServerUrl ?? server,
      deviceId: deviceId,
    );
    final c = await anon.login(user, password);
    client = c;
    serverUrl = c.baseUrl;
    username = user;
    await _prefs.setString(_kServer, c.baseUrl);
    await _prefs.setString(_kUsername, user);
    await _prefs.setString(_kToken, c.token!);
    await _prefs.setString(_kUser, c.userId!);
    notifyListeners();
  }

  Future<void> logout() async {
    final c = client;
    client = null;
    await _prefs.remove(_kToken);
    await _prefs.remove(_kUser);
    notifyListeners();
    if (c != null) await c.logout();
  }
}
