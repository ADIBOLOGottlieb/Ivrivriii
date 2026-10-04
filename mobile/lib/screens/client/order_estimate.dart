import '../../models.dart';
import '../../utils/format.dart';

/// Estimation du montant d'une commande avant sa création (même formule que le serveur).
/// Le serveur reste maître du montant : la commande qu'il renvoie fait foi.
class OrderEstimate {
  final int subtotal;
  final int deliveryFee;
  final int paymentFee;

  const OrderEstimate({required this.subtotal, required this.deliveryFee, required this.paymentFee});

  int get total => subtotal + deliveryFee + paymentFee;

  /// [deliveryFee] : devis de livraison (ou frais fixes en repli), ignoré à emporter.
  /// Frais mobile money calculés sur sous-total + livraison, selon le taux de l'opérateur.
  factory OrderEstimate.compute({
    required int subtotal,
    required bool delivery,
    required int deliveryFee,
    required String paymentMethod,
    required num feePercent,
  }) {
    final fee = delivery ? deliveryFee : 0;
    return OrderEstimate(
      subtotal: subtotal,
      deliveryFee: fee,
      paymentFee: paymentFeeFor(subtotal + fee, paymentMethod, feePercent),
    );
  }
}

/// « 3,4 km ».
String formatKm(double km) => '${km.toStringAsFixed(1).replaceAll('.', ',')} km';

/// Libellé de la ligne livraison : « Livraison (3,4 km) » si la distance est connue.
String deliveryLineLabel(DeliveryQuote? quote) {
  final km = quote?.distanceKm;
  return km == null ? 'Livraison' : 'Livraison (${formatKm(km)})';
}

/// Message hors zone (celui du serveur, sinon un texte par défaut).
String outOfZoneMessage(DeliveryQuote quote) {
  var m = quote.message?.trim() ?? '';
  if (m.endsWith('.')) m = m.substring(0, m.length - 1);
  if (m.isNotEmpty) return m;
  final max = quote.maxKm;
  return max == null
      ? 'Adresse hors de la zone de livraison'
      : 'Adresse hors de la zone de livraison (maximum ${formatKm(max)})';
}
