import 'android_eq.dart';

/// Android : égaliseur intégré du téléphone (voir android_eq.dart).
bool get equalizerSupported => androidEqualizer != null;

void applyEqualizer(String json) => applyAndroidEqualizer(json);

void applyOutputGain(double db) {}
