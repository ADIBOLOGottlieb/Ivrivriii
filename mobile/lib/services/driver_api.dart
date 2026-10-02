import '../models.dart';
import 'api.dart';

/// Onglets de l'espace livreur (paramètre `scope` de GET /api/driver/orders).
const driverScopeAvailable = 'available'; // prêtes, en livraison, sans livreur
const driverScopeMine = 'mine'; // prises par moi (y compris en attente du « Reçu »)
const driverScopeHistory = 'history'; // livrées par moi (50 dernières)

/// Statistiques du jour du livreur connecté.
class DriverStats {
  final int todayCount; // livraisons terminées aujourd'hui
  final int todayCash; // espèces encaissées aujourd'hui (FCFA)
  final int activeCount; // livraisons en cours

  const DriverStats({this.todayCount = 0, this.todayCash = 0, this.activeCount = 0});

  static int _n(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

  factory DriverStats.fromJson(Map<String, dynamic> j) => DriverStats(
        todayCount: _n(j['today_count']),
        todayCash: _n(j['today_cash']),
        activeCount: _n(j['active_count']),
      );
}

List<Order> _orders(dynamic r) =>
    ((r as List?) ?? const []).map((e) => Order.fromJson(e as Map<String, dynamic>)).toList();

/// Livraisons d'un onglet : [driverScopeAvailable], [driverScopeMine] ou [driverScopeHistory].
Future<List<Order>> fetchDriverOrders(String scope) async =>
    _orders(await Api.instance.get('/driver/orders', {'scope': scope}));

/// « Je prends cette livraison » (409 si déjà prise, 400 si non prête ou non payée).
Future<Order> takeOrder(int orderId) async =>
    Order.fromJson(await Api.instance.post('/driver/orders/$orderId/take') as Map<String, dynamic>);

/// « Livraison faite » : la commande attend ensuite le « Reçu » du client.
Future<Order> markDelivered(int orderId) async =>
    Order.fromJson(await Api.instance.post('/driver/orders/$orderId/delivered') as Map<String, dynamic>);

/// Rendre la livraison : elle repart dans « À livrer », sans livreur.
Future<Order> releaseOrder(int orderId) async =>
    Order.fromJson(await Api.instance.post('/driver/orders/$orderId/release') as Map<String, dynamic>);

Future<DriverStats> fetchDriverStats() async =>
    DriverStats.fromJson(await Api.instance.get('/driver/stats') as Map<String, dynamic>);
