import 'dart:math';

import 'package:flutter/foundation.dart';
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

  bool get isLoggedIn => client?.token != null;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    deviceId = _prefs.getString(_kDevice) ?? _newDeviceId();
    await _prefs.setString(_kDevice, deviceId);
    serverUrl = _prefs.getString(_kServer) ?? defaultServerUrl;
    username = _prefs.getString(_kUsername) ?? '';
    final token = _prefs.getString(_kToken);
    final userId = _prefs.getString(_kUser);
    if (token != null && userId != null) {
      client = JellyfinClient(
        baseUrl: serverUrl,
        deviceId: deviceId,
        token: token,
        userId: userId,
      );
    }
  }

  static String _newDeviceId() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> login(String server, String user, String password) async {
    final anon = JellyfinClient(baseUrl: server, deviceId: deviceId);
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
