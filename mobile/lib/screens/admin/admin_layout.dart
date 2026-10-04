import 'package:flutter/material.dart';

/// Largeur à partir de laquelle l'espace admin passe en mise en page tablette (NavigationRail).
const adminTabletBreakpoint = 840.0;

/// Largeur à partir de laquelle le NavigationRail affiche ses libellés (rail étendu).
const adminRailExtendedBreakpoint = 1200.0;

/// Écran assez large pour la mise en page tablette.
bool isAdminTablet(BuildContext context) => MediaQuery.sizeOf(context).width >= adminTabletBreakpoint;

/// Limite la largeur du contenu sur tablette (centré en haut) ; sans effet sur téléphone.
class MaxContentWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const MaxContentWidth({super.key, required this.child, this.maxWidth = 900});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
    );
  }
}
