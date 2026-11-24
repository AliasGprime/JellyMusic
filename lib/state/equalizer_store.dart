import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/eq_bridge.dart';
import 'session.dart';

/// Bandes de l'égaliseur (mêmes fréquences que window.jmEq dans index.html).
const eqBandLabels = [
  '31',
  '62',
  '125',
  '250',
  '500',
  '1k',
  '2k',
  '4k',
  '8k',
  '16k',
];
const eqMinDb = -12.0;
const eqMaxDb = 12.0;

/// Préréglages (gain en dB par bande).
const eqPresets = <String, List<double>>{
  'Plat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Basses renforcées': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
  'Aigus renforcés': [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],
  'Voix': [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1],
  'Rock': [4, 3, 2, 0, -1, -1, 1, 2, 3, 4],
  'Pop': [-1, 0, 2, 3, 4, 3, 1, 0, -1, -1],
  'Jazz': [3, 2, 1, 2, -1, -1, 0, 1, 2, 3],
  'Classique': [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],
  'Électro': [5, 4, 1, 0, -2, 1, 0, 2, 4, 5],
  'Petit volume': [6, 4, 2, 0, 0, 0, 0, 2, 4, 5],
};
const eqCustom = 'Personnalisé';

class EqSettings {
  final bool enabled;
  final double preamp; // dB
  final List<double> gains; // dB, une valeur par bande
  final String preset;

  const EqSettings({
    required this.enabled,
    required this.preamp,
    required this.gains,
    required this.preset,
  });

  static const flat = EqSettings(
    enabled: false,
    preamp: 0,
    gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    preset: 'Plat',
  );

  EqSettings copyWith({
    bool? enabled,
    double? preamp,
    List<double>? gains,
    String? preset,
  }) => EqSettings(
    enabled: enabled ?? this.enabled,
    preamp: preamp ?? this.preamp,
    gains: gains ?? this.gains,
    preset: preset ?? this.preset,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'preamp': preamp,
    'gains': gains,
    'preset': preset,
  };

  static EqSettings fromJson(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    final gains = ((j['gains'] as List?) ?? const [])
        .map((g) => (g as num).toDouble().clamp(eqMinDb, eqMaxDb))
        .toList();
    while (gains.length < eqBandLabels.length) {
      gains.add(0);
    }
    return EqSettings(
      enabled: j['enabled'] == true,
      preamp: ((j['preamp'] as num?) ?? 0).toDouble().clamp(eqMinDb, 6.0),
      gains: gains.take(eqBandLabels.length).toList(),
      preset: (j['preset'] as String?) ?? eqCustom,
    );
  }
}

/// Où les réglages sont enregistrés.
enum EqStorage { account, browser }

/// Réglages de l'égaliseur du compte connecté. Ils sont enregistrés sur le
/// serveur Jellyfin (préférences de l'utilisateur), donc propres à chaque
/// compte et retrouvés sur n'importe quel navigateur. Si le serveur refuse,
/// repli : stockage dans ce navigateur, toujours séparé par compte.
class EqualizerStore extends ChangeNotifier {
  static const _prefKey = 'equalizer';

  final Session session;
  EqSettings settings = EqSettings.flat;
  EqStorage storage = EqStorage.account;
  bool loading = false;
  bool saving = false;
  String? _loadedFor;
  Timer? _saveTimer;

  EqualizerStore(this.session) {
    session.addListener(_onSession);
    _onSession();
  }

  bool get supported => equalizerSupported;

  String get _localKey => 'eq.${session.client?.userId}';

  void _onSession() {
    final user = session.isLoggedIn ? session.client?.userId : null;
    if (user == _loadedFor) return;
    // Changement de compte : un enregistrement encore en attente
    // appartient à l'ancien compte ; on l'annule pour qu'il ne soit jamais
    // écrit dans le nouveau.
    _saveTimer?.cancel();
    _saveTimer = null;
    _loadedFor = user;
    if (user == null) {
      // Déconnexion : on revient au son d'origine.
      settings = EqSettings.flat;
      _apply();
      notifyListeners();
    } else {
      load();
    }
  }

  Future<void> load() async {
    if (!supported || !session.isLoggedIn) return;
    final user = session.client!.userId;
    loading = true;
    notifyListeners();
    String? text;
    try {
      text = await session.client!.getUserSetting(_prefKey);
      storage = EqStorage.account;
    } catch (_) {
      storage = EqStorage.browser;
      text = (await SharedPreferences.getInstance()).getString(_localKey);
    }
    // Le compte a changé pendant le chargement : ces réglages ne sont plus
    // les bons (le nouveau compte a lancé son propre chargement).
    if (session.client?.userId != user) return;
    try {
      settings = text == null ? EqSettings.flat : EqSettings.fromJson(text);
    } catch (_) {
      settings = EqSettings.flat;
    }
    loading = false;
    _apply();
    notifyListeners();
  }

  void update(EqSettings s) {
    settings = s;
    _apply();
    notifyListeners();
    // Enregistre une fois que l'utilisateur a fini de bouger les curseurs.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _save);
  }

  void setBand(int i, double db) {
    final gains = List<double>.of(settings.gains)..[i] = db;
    update(settings.copyWith(gains: gains, preset: eqCustom));
  }

  void applyPreset(String name) {
    final g = eqPresets[name];
    if (g == null) return;
    // Baisse la pré-amplification de la moitié du plus fort renforcement,
    // pour éviter que le son sature (ex. Basses renforcées : -3 dB).
    final boost = g.reduce((a, b) => a > b ? a : b);
    final preamp = boost > 0 ? -(boost / 2).roundToDouble() : 0.0;
    update(
      settings.copyWith(
        gains: List.of(g),
        preset: name,
        enabled: true,
        preamp: preamp,
      ),
    );
  }

  void reset() => update(EqSettings.flat.copyWith(enabled: settings.enabled));

  void _apply() => applyEqualizer(jsonEncode(settings.toJson()));

  Future<void> _save() async {
    if (!session.isLoggedIn) return;
    final text = jsonEncode(settings.toJson());
    saving = true;
    notifyListeners();
    try {
      if (storage == EqStorage.account) {
        await session.client!.setUserSetting(_prefKey, text);
      }
    } catch (_) {
      storage = EqStorage.browser;
    }
    // Copie locale : sert de repli si le serveur ne répond pas.
    await (await SharedPreferences.getInstance()).setString(_localKey, text);
    saving = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    session.removeListener(_onSession);
    super.dispose();
  }
}
