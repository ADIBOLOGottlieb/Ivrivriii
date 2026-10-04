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
  /// Frais mobile money calculés sur sous-total + livraison, selon le taux FACTURÉ AU CLIENT
  /// (0 quand le restaurant absorbe la commission).
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

  /// Estimation selon les réglages : taux client via [AppSettings.clientFeePercentFor].
  factory OrderEstimate.forSettings(
    AppSettings settings, {
    required int subtotal,
    required bool delivery,
    required int deliveryFee,
    required String paymentMethod,
  }) =>
      OrderEstimate.compute(
        subtotal: subtotal,
        delivery: delivery,
        deliveryFee: deliveryFee,
        paymentMethod: paymentMethod,
        feePercent: settings.clientFeePercentFor(paymentMethod),
      );
}

/// « 3,4 km ».
String formatKm(double km) => '${km.toStringAsFixed(1).replaceAll('.', ',')} km';

/// Libellé de la ligne livraison : « Livraison (Tokoin) » en mode zone,
/// « Livraison (3,4 km) » si la distance est connue, sinon « Livraison ».
String deliveryLineLabel(DeliveryQuote? quote, {String? zoneName}) {
  final zone = (zoneName ?? quote?.zoneName ?? '').trim();
  if (zone.isNotEmpty) return 'Livraison ($zone)';
  final km = quote?.distanceKm;
  return km == null ? 'Livraison' : 'Livraison (${formatKm(km)})';
}

/// Message hors zone (celui du serveur, sinon un texte par défaut).
String outOfZoneMessage(DeliveryQuote quote) {
  var m = quote.message?.trim() ?? '';
  if (m.endsWith('.')) m = m.substring(0, m.length - 1);
  if (m.isNotEmpty) return m;
  if (quote.mode == 'zone') return 'Choisissez votre zone de livraison';
  final max = quote.maxKm;
  return max == null
      ? 'Adresse hors de la zone de livraison'
      : 'Adresse hors de la zone de livraison (maximum ${formatKm(max)})';
}

/// Prix de la zone la moins chère (null si aucune zone chargée).
int? cheapestZoneFee(List<DeliveryZone>? zones) {
  final active = (zones ?? const <DeliveryZone>[]).where((z) => z.active);
  if (active.isEmpty) return null;
  return active.map((z) => z.fee).reduce((a, b) => a < b ? a : b);
}

/// Choix d'une zone : « Tokoin — 800 FCFA ».
String zoneOptionLabel(DeliveryZone zone) => '${zone.name} — ${formatPrice(zone.fee)}';

/// Frais de livraison en bref (accueil) : « Livraison 500 FCFA », « Livraison dès 500 FCFA »
/// (au kilomètre ou par zone) ou « Livraison selon la zone » (zones pas encore chargées).
String deliveryFeeSummary(AppSettings settings, {List<DeliveryZone>? zones}) {
  if (settings.feeByZone) {
    final min = cheapestZoneFee(zones);
    return min == null ? 'Livraison selon la zone' : 'Livraison dès ${formatPrice(min)}';
  }
  return 'Livraison ${settings.feeByDistance ? 'dès ' : ''}${formatPrice(settings.deliveryFee)}';
}
