import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Notification silencieuse de progression des téléchargements (Android).
///
/// Elle démarre un service de premier plan : Android garde alors
/// l'application active pendant les téléchargements, même en arrière-plan ou
/// écran éteint.
class DownloadNotification {
  static const _channel = MethodChannel('app.jellymusic/downloads');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Appelé quand l'utilisateur touche « Arrêter » dans la notification.
  static void onCancel(VoidCallback cb) {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cancel') cb();
    });
  }

  /// Affiche ou met à jour la notification. [max] 0 : progression inconnue.
  static Future<void> update({
    required String title,
    required String text,
    int progress = 0,
    int max = 0,
  }) => _call('update', {
    'title': title,
    'text': text,
    'progress': progress,
    'max': max,
  });

  /// Retire la notification de progression.
  static Future<void> stop() => _call('stop');

  /// Résumé une fois la série terminée (touché : ouvre l'application).
  static Future<void> done(String title, String text) =>
      _call('done', {'title': title, 'text': text});

  /// Demande (une fois) l'autorisation d'afficher des notifications.
  static Future<void> askPermission() => _call('askPermission');

  static Future<void> clearDone() => _call('clearDone');

  static Future<void> _call(String method, [Object? args]) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod(method, args);
    } catch (e) {
      debugPrint('Notification de téléchargement : $e');
    }
  }
}
