import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Égaliseur intégré d'Android, branché sur le lecteur. Il a ses propres
/// bandes (souvent 5 : ~60 Hz, 230 Hz, 910 Hz, 3,6 kHz, 14 kHz) : les
/// réglages à 10 bandes de JellyMusic (les mêmes que la version web) sont
/// convertis pour ces bandes.
final AndroidEqualizer? androidEqualizer =
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? AndroidEqualizer()
    : null;

/// Fréquences (Hz) des 10 bandes de JellyMusic.
const _bandHz = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// Nombre de bandes de l'égaliseur du téléphone (connu après le premier
/// morceau lancé).
final ValueNotifier<int?> androidEqBands = ValueNotifier(null);

String? _latest;
bool _running = false;

/// Applique les réglages (JSON de EqSettings). Les réglages arrivent
/// parfois avant que le lecteur soit prêt : seul le dernier est appliqué,
/// dès que l'égaliseur du téléphone répond.
void applyAndroidEqualizer(String json) {
  final eq = androidEqualizer;
  if (eq == null) return;
  _latest = json;
  if (!_running) _run(eq);
}

Future<void> _run(AndroidEqualizer eq) async {
  _running = true;
  try {
    final p = await eq.parameters;
    androidEqBands.value = p.bands.length;
    while (_latest != null) {
      final j = jsonDecode(_latest!) as Map<String, dynamic>;
      _latest = null;
      final enabled = j['enabled'] == true;
      final preamp = ((j['preamp'] as num?) ?? 0).toDouble();
      final gains = [
        for (final g in (j['gains'] as List? ?? const []))
          (g as num).toDouble(),
      ];
      for (final b in p.bands) {
        final db = enabled ? curveAt(b.centerFrequency, gains) + preamp : 0.0;
        await b.setGain(db.clamp(p.minDecibels, p.maxDecibels).toDouble());
      }
      await eq.setEnabled(enabled);
    }
  } catch (e) {
    debugPrint('Égaliseur Android : $e');
  } finally {
    _running = false;
  }
}

/// Gain (dB) de la courbe à 10 bandes [gains] à la fréquence [hz] :
/// interpolation sur une échelle logarithmique (une bande par octave).
@visibleForTesting
double curveAt(double hz, List<double> gains) {
  if (gains.isEmpty) return 0;
  // Certains téléphones donnent la fréquence en millihertz.
  if (hz > 30000) hz /= 1000;
  final x = math.log(hz / _bandHz.first) / math.ln2; // position en octaves
  if (x <= 0) return gains.first;
  final last = math.min(gains.length, _bandHz.length) - 1;
  if (x >= last) return gains[last];
  final i = x.floor();
  final t = x - i;
  return gains[i] * (1 - t) + gains[i + 1] * t;
}
