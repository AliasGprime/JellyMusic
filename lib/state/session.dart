import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api/jellyfin_client.dart';

/// Aucune adresse par défaut : chacun entre celle de son propre serveur.
const defaultServerUrl = '';

/// Le serveur est-il joignable ? (téléphone : sans Internet, l'application
/// passe en mode hors connexion avec les morceaux téléchargés).
enum ServerState { checking, online, offline }

/// Garde la connexion au serveur et la mémorise entre les lancements.
class Session extends ChangeNotifier {
  static const _kServer = 'server';
  static const _kToken = 'token';
  static const _kUser = 'userId';
  static const _kUsername = 'username';
  static const _kDevice = 'deviceId';
  static const _kForcedOffline = 'offline.forced';

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

  ServerState server = kIsWeb ? ServerState.online : ServerState.checking;

  /// Mode hors connexion choisi dans les Paramètres (même avec Internet).
  bool forcedOffline = false;

  /// Le serveur ne répond pas (sans compter le mode choisi).
  bool get serverUnreachable => server == ServerState.offline;

  /// Seuls les morceaux téléchargés sont utilisés.
  bool get offline => forcedOffline || serverUnreachable;

  Future<void> setForcedOffline(bool on) async {
    if (kIsWeb || forcedOffline == on) return;
    forcedOffline = on;
    notifyListeners();
    await _prefs.setBool(_kForcedOffline, on);
    if (!on) await checkServer();
  }

  StreamSubscription<List<ConnectivityResult>>? _netSub;

  /// Téléphone : vérifie si le serveur répond. Sinon, mode hors connexion,
  /// et nouvel essai automatique dès qu'un réseau apparaît.
  /// [quiet] : sans afficher « Connexion au serveur… » pendant l'essai.
  Future<void> checkServer({bool quiet = false}) async {
    final c = client;
    if (kIsWeb || c == null) {
      _setServer(ServerState.online);
      return;
    }
    _netSub ??= Connectivity().onConnectivityChanged.listen(_onNetChanged);
    // Hors connexion choisi : on ne contacte pas le serveur.
    if (forcedOffline) return;
    if (!quiet) _setServer(ServerState.checking);
    var ok = false;
    try {
      final net = await Connectivity().checkConnectivity();
      final none = net.every((r) => r == ConnectivityResult.none);
      ok = !none && await c.reachable();
    } catch (_) {
      ok = await c.reachable();
    }
    if (client != c) return; // déconnecté entre-temps
    if (forcedOffline) return; // choisi pendant l'essai
    _setServer(ok ? ServerState.online : ServerState.offline);
  }

  /// Réseau coupé (plus de quelques secondes) : mode hors connexion. Réseau
  /// revenu : nouvel essai de connexion au serveur.
  void _onNetChanged(List<ConnectivityResult> r) {
    if (forcedOffline || client == null) return;
    final none = r.every((x) => x == ConnectivityResult.none);
    if (none && server == ServerState.online) {
      // Passage du Wi-Fi aux données mobiles : coupure de quelques instants.
      Future.delayed(const Duration(seconds: 3), () async {
        final now = await Connectivity().checkConnectivity();
        if (client != null &&
            server == ServerState.online &&
            now.every((x) => x == ConnectivityResult.none)) {
          _setServer(ServerState.offline);
        }
      });
    } else if (!none && serverUnreachable) {
      // Le réseau met parfois quelques secondes à vraiment fonctionner.
      Future.delayed(const Duration(seconds: 2), () {
        if (serverUnreachable) checkServer(quiet: true);
      });
    }
  }

  void _setServer(ServerState s) {
    if (server == s) return;
    server = s;
    notifyListeners();
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    deviceId = _prefs.getString(_kDevice) ?? _newDeviceId();
    await _prefs.setString(_kDevice, deviceId);
    serverUrl = _prefs.getString(_kServer) ?? _guessServerUrl();
    username = _prefs.getString(_kUsername) ?? '';
    forcedOffline = !kIsWeb && (_prefs.getBool(_kForcedOffline) ?? false);
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
    this.server = ServerState.online;
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
