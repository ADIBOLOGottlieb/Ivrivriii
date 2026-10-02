// Appels API de la livraison côté client (« Reçu ») et côté admin (livreurs, attribution).
import '../models.dart';
import 'api.dart';

Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// Délai par défaut (heures) avant la confirmation automatique de la réception.
const defaultDeliveryAutoConfirmHours = 12;

// ---------- Client ----------

/// Le client confirme avoir reçu sa commande : elle passe « delivered » (commande complète).
Future<Order> confirmReceived(int orderId) async =>
    Order.fromJson(_map(await Api.instance.post('/orders/$orderId/received')));

// ---------- Admin : livreurs ----------

Future<List<Driver>> fetchDrivers() async {
  final r = await Api.instance.get('/admin/drivers');
  return r is List ? r.map((e) => Driver.fromJson(_map(e))).toList() : <Driver>[];
}

Future<Driver> createDriver({required String name, required String phone, required String password}) async =>
    Driver.fromJson(_map(await Api.instance.post('/admin/drivers', {
      'name': name,
      'phone': phone,
      'password': password,
    })));

/// Modifie un livreur : activation, nom ou nouveau mot de passe (champs null non envoyés).
Future<Driver> updateDriver(int id, {bool? active, String? name, String? password}) async =>
    Driver.fromJson(_map(await Api.instance.patch('/admin/drivers/$id', {
      'active': ?active,
      'name': ?name,
      'password': ?password,
    })));

/// Attribue la commande à un livreur, ou la lui retire si [driverId] est null.
Future<Order> assignDriver(int orderId, int? driverId) async =>
    Order.fromJson(_map(await Api.instance.patch('/admin/orders/$orderId/assign', {'driver_id': driverId})));

// ---------- Admin : réglage de confirmation automatique ----------

/// Délai (heures) après « Livraison faite » au bout duquel la réception est confirmée automatiquement.
Future<int> fetchDeliveryAutoConfirmHours() async {
  final r = _map(await Api.instance.get('/settings'));
  final v = r['delivery_auto_confirm_hours'];
  final n = v is num ? v.toInt() : int.tryParse('$v');
  return n ?? defaultDeliveryAutoConfirmHours;
}

/// Enregistre ce réglage seul (AppSettings ne le contient pas) : n'écrase aucun autre paramètre.
Future<void> saveDeliveryAutoConfirmHours(int hours) async {
  await Api.instance.put('/admin/settings', {'delivery_auto_confirm_hours': hours});
}
