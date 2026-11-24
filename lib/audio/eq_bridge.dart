// Lien vers le moteur d'égaliseur de la page web (window.jmEq).
// Sur Android, version vide : l'égaliseur n'existe que dans la version web.
export 'eq_bridge_stub.dart' if (dart.library.js_interop) 'eq_bridge_web.dart';
