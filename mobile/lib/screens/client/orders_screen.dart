import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../services/order_events.dart';
import '../../utils/polling.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../shared/order_card.dart';
import '../shared/order_detail_screen.dart';

class OrdersScreen extends StatefulWidget {
  /// Vrai quand l'onglet est visible : on rafraîchit à l'affichage.
  final bool active;

  /// Change à chaque appui sur l'onglet « Commandes » (même déjà actif) : force un rechargement.
  final int refreshToken;

  const OrdersScreen({super.key, this.active = false, this.refreshToken = 0});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order>? _orders;
  Object? _error;
  late SmartPoller _poller;
  // Seule la réponse de la dernière requête lancée est affichée (pas d'ancienne liste « En attente »).
  int _gen = 0;

  @override
  void initState() {
    super.initState();

    // Rafraîchissement de fond des commandes en cours.
    _poller = SmartPoller(
      onPoll: () => _load(silent: true),
      getInterval: (_) => const Duration(seconds: 20),
    );

    _load();
    _poller.startPolling('pending');
    ordersChanged.addListener(_onOrdersChanged);
  }

  @override
  void didUpdateWidget(OrdersScreen old) {
    super.didUpdateWidget(old);
    if ((widget.active && !old.active) || widget.refreshToken != old.refreshToken) _load(silent: true);
  }

  @override
  void dispose() {
    ordersChanged.removeListener(_onOrdersChanged);
    _poller.stop();
    super.dispose();
  }

  void _onOrdersChanged() => _load(silent: true);

  /// Charge les commandes. [silent] = true : pas d'écran d'erreur (rafraîchissement de fond).
  Future<void> _load({bool silent = false}) async {
    final gen = ++_gen;
    try {
      final orders = await Api.instance.myOrders();
      if (!mounted || gen != _gen) return;
      setState(() {
        _orders = orders;
        _error = null;
      });
    } catch (e) {
      if (mounted && gen == _gen && !silent) setState(() => _error = e);
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
      body = ListView(
        children: const [
          SizedBox(height: 80),
          EmptyState(
            emoji: '🧾',
            title: 'Aucune commande',
            message: 'Vos commandes apparaîtront ici.',
          ),
        ],
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: (active.isNotEmpty ? 1 : 0) + active.length + (past.isNotEmpty ? 1 : 0) + past.length,
        itemBuilder: (context, index) {
          int pos = 0;

          // Section « En cours »
          if (active.isNotEmpty) {
            if (index == pos) return const SectionTitle('En cours');
            pos++;
          }
          if (index < pos + active.length) {
            return _card(active[index - pos], index - pos);
          }
          pos += active.length;

          // Section « Historique »
          if (past.isNotEmpty) {
            if (index == pos) return const SectionTitle('Historique');
            pos++;
          }
          return _card(past[index - pos], active.length + (index - pos));
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Mes commandes')),
      body: RefreshIndicator(onRefresh: () => _load(silent: false), child: body),
    );
  }

  /// Carte animée ; la clé stable évite les saccades quand l'ordre de la liste change.
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
              if (mounted) _load(silent: true); // recharge au retour du détail
            },
          ),
        ),
      );
}
