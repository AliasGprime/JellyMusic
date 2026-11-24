import 'package:flutter/widgets.dart';

/// Largeur à partir de laquelle on passe à la mise en page « ordinateur » :
/// barre latérale, contenu central et barre de lecture en bas.
const double wideBreakpoint = 900;

bool isWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= wideBreakpoint;

/// Présent au-dessus des pages quand la barre de lecture « ordinateur » est
/// affichée : le mini-lecteur des pages se masque alors pour ne pas doubler.
class PlayerBarScope extends InheritedWidget {
  const PlayerBarScope({super.key, required super.child});

  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerBarScope>() != null;

  @override
  bool updateShouldNotify(PlayerBarScope oldWidget) => false;
}
