import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android : application glissée hors des applications récentes. Sans cela,
/// elle restait active en arrière-plan après avoir joué de la musique (même
/// en pause). On arrête tout proprement, puis elle se ferme vraiment.
class AppExit {
  static const _channel = MethodChannel('app.jellymusic/app');

  /// [cleanup] : arrêter la lecture, les téléchargements… (2 s au plus).
  static void onTaskRemoved(Future<void> Function() cleanup) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'taskRemoved') return;
      try {
        await cleanup().timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('Fermeture : $e');
      }
      await _channel.invokeMethod('exit');
    });
    _channel.invokeMethod<bool>('hookTaskRemoved').then((ok) {
      if (ok != true) debugPrint('Fermeture : crochet non installé');
    }, onError: (Object e) => debugPrint('Fermeture : $e'));
  }
}
