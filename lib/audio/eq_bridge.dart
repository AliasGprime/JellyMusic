// Lien vers le moteur d'égaliseur de la page web (window.jmEq).
// Ailleurs (Android) : égaliseur intégré du téléphone.
export 'eq_bridge_stub.dart' if (dart.library.js_interop) 'eq_bridge_web.dart';
