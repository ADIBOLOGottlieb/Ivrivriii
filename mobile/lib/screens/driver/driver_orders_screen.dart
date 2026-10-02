import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../services/driver_api.dart';
import '../../services/order_events.dart';
import '../../widgets/common.dart';
import 'delivery_card.dart';

/// Liste des livraisons d'un onglet (À livrer, Mes livraisons, Historique).
/// Rafraîchie toutes les 20 s quand l'onglet est visible, tirer pour actualiser.
class DriverOrdersScreen extends StatefulWidget {
  final String scope;
  final String title;
  final bool active;

  /// Appelé après chaque chargement réussi (alerte « nouvelle livraison », badges).
  final ValueChanged<List<Order>>? onLoaded;
  final ValueChanged<Order>? onTaken;

  const DriverOrdersScreen({
    super.key,
    required this.scope,
    required this.title,
    this.active = false,
    this.onLoaded,
    this.onTaken,
  });

  @override
  State<DriverOrdersScreen> createState() => _DriverOrdersScreenState();
}

class _DriverOrdersScreenState extends State<DriverOrdersScreen> {
  static const _pollInterval = Duration(seconds: 20);

  List<Order>? _orders;
  Object? _error;
  bool _loading = false;
  bool _reloadAfter = false;
  Timer? _timer;
  LatLng? _restaurant;

  @override
  void initState() {
    super.initState();
    ordersChanged.addListener(_load);
    _load();
    _loadRestaurant();
    _syncTimer();
  }

  @override
  void didUpdateWidget(DriverOrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
    if (widget.active != old.active) _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    ordersChanged.removeListener(_load);
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (!widget.active) return;
    _timer = Timer.periodic(_pollInterval, (_) {
      // Pas de requête quand l'application est en arrière-plan.
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) _load();
    });
  }

  Future<void> _loadRestaurant() async {
    try {
      final s = await Api.instance.settings();
      if (mounted && s.restaurantLat != null && s.restaurantLng != null) {
        setState(() => _restaurant = LatLng(s.restaurantLat!, s.restaurantLng!));
      }
    } catch (_) {
      // Distance non affichée.
    }
  }

  Future<void> _load() async {
    if (_loading) {
      _reloadAfter = true; // une action vient d'avoir lieu : on rechargera après la requête en cours
      return;
    }
    _loading = true;
    _reloadAfter = false;
    try {
      final list = await fetchDriverOrders(widget.scope);
      if (!mounted) return;
      setState(() {
        _orders = list;
        _error = null;
      });
      widget.onLoaded?.call(list);
    } catch (e) {
      // On garde la dernière liste affichée si on en a une.
      if (mounted) setState(() => _error = e);
    } finally {
      _loading = false;
    }
    if (_reloadAfter && mounted) await _load();
  }

  ({String emoji, String title, String message}) get _empty => switch (widget.scope) {
        driverScopeAvailable => (
            emoji: '🛵',
            title: 'Aucune livraison à prendre',
            message: 'Les commandes prêtes apparaîtront ici. La liste se met à jour toute seule.',
          ),
        driverScopeMine => (
            emoji: '📦',
            title: 'Aucune livraison en cours',
            message: 'Prenez une livraison dans l\'onglet « À livrer ».',
          ),
        _ => (
            emoji: '🧾',
            title: 'Pas encore d\'historique',
            message: 'Vos livraisons terminées apparaîtront ici.',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    final List<Widget> children;
    if (orders == null && _error != null) {
      children = [
        SizedBox(height: 480, child: ErrorRetry(error: _error!, onRetry: _load)),
      ];
    } else if (orders == null) {
      children = [const SizedBox(height: 300, child: Center(child: CircularProgressIndicator()))];
    } else if (orders.isEmpty) {
      final e = _empty;
      children = [SizedBox(height: 480, child: EmptyState(emoji: e.emoji, title: e.title, message: e.message))];
    } else {
      children = [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Mise à jour impossible : $_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600),
            ),
          ),
        for (final o in orders)
          DeliveryCard(
            key: ValueKey('${widget.scope}-${o.id}'),
            order: o,
            restaurant: _restaurant,
            onTaken: widget.onTaken,
          ),
      ];
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 6, bottom: 24),
          children: children,
        ),
      ),
    );
  }
}
