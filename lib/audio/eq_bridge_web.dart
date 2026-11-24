import 'dart:js_interop';

@JS('jmEq')
external JSObject? get _jmEq;

@JS('jmEq.set')
external void _jmEqSet(JSString settings);

/// Vrai si la page web contient le moteur d'égaliseur (index.html).
bool get equalizerSupported => _jmEq != null;

/// Envoie les réglages (JSON) au moteur Web Audio de la page.
void applyEqualizer(String json) {
  if (_jmEq != null) _jmEqSet(json.toJS);
}

@JS('jmEq.setOutput')
external void _jmEqSetOutput(JSNumber db);

/// Gain de sortie (dB) de la normalisation du volume, avec limiteur.
void applyOutputGain(double db) {
  if (_jmEq != null) _jmEqSetOutput(db.toJS);
}
