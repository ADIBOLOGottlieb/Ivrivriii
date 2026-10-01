import 'package:flutter/foundation.dart';

/// Signal global : une commande a changé (création, annulation, paiement, abandon...).
/// Les écrans qui affichent des commandes l'écoutent pour se recharger.
final ordersChanged = ValueNotifier<int>(0);

/// À appeler après toute action qui modifie une commande.
void notifyOrdersChanged() => ordersChanged.value++;
