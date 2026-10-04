// Ventes au comptoir (caisse) : POST /api/admin/counter-orders (tout le personnel).
import '../models.dart';
import 'api.dart';

/// Service de la vente : consommée sur place ou à emporter.
enum CounterService { dineIn, takeaway }

extension CounterServiceApi on CounterService {
  String get apiValue => this == CounterService.dineIn ? 'dine_in' : 'takeaway';
  String get label => this == CounterService.dineIn ? 'Sur place' : 'À emporter';
}

/// Moyens de paiement acceptés à la caisse.
const counterPaymentMethods = <String, String>{
  'cash': 'Espèces',
  'flooz': 'Flooz',
  'mixx': 'Mixx by Yas',
};

/// Enregistre une vente au comptoir. Les prix sont recalculés par le serveur depuis le catalogue.
/// Espèces : commande 'confirmed' (envoyée en cuisine). Flooz / Mixx : commande 'pending' en attente
/// du paiement, à lancer ensuite avec `Api.instance.startPayment(order.id, phone)`.
Future<Order> createCounterOrder({
  required Map<int, int> items, // productId → quantité
  required CounterService service,
  required String paymentMethod,
  String? customerName,
  String? phone,
  String? note,
}) async {
  String? clean(String? s) {
    final t = s?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  final r = await Api.instance.post('/admin/counter-orders', {
    'items': [
      for (final e in items.entries)
        if (e.value > 0) {'product_id': e.key, 'quantity': e.value},
    ],
    'service': service.apiValue,
    'payment_method': paymentMethod,
    'customer_name': ?clean(customerName),
    'phone': ?clean(phone)?.replaceAll(RegExp(r'[\s.\-]'), ''),
    'note': ?clean(note),
  });
  return Order.fromJson(Map<String, dynamic>.from(r as Map));
}
