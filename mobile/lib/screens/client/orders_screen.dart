import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../shared/order_card.dart';
import '../shared/order_detail_screen.dart';

class OrdersScreen extends StatefulWidget {
  /// Vrai quand l'onglet est visible : on rafraîchit à l'affichage.
  final bool active;
  const OrdersScreen({super.key, this.active = false});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order>? _orders;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (widget.active && (_orders?.any((o) => !o.isFinished) ?? false)) _load();
    });
  }

  @override
  void didUpdateWidget(OrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final orders = await Api.instance.myOrders();
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    final active = orders?.where((o) => !o.isFinished).toList() ?? [];
    final past = orders?.where((o) => o.isFinished).toList() ?? [];

    Widget body;
    if (orders == null) {
      body = _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    } else if (orders.isEmpty) {
      body = ListView(children: const [
        SizedBox(height: 80),
        EmptyState(
          emoji: '🧾',
          title: 'Aucune commande',
          message: 'Vos commandes apparaîtront ici.',
        ),
      ]);
    } else {
      body = ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (active.isNotEmpty) ...[
            const SectionTitle('En cours'),
            for (final (i, o) in active.indexed) _card(o, i),
          ],
          if (past.isNotEmpty) ...[
            const SectionTitle('Historique'),
            for (final (i, o) in past.indexed) _card(o, active.length + i),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Mes commandes')),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }

  Widget _card(Order o, int index) => FadeSlideIn(
        key: ValueKey('order-${o.id}'),
        delay: FadeSlideIn.stagger(index),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: OrderCard(
            order: o,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: o.id, initial: o)),
              );
              _load();
            },
          ),
        ),
      );
}
