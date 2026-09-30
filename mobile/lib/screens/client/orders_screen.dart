import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../utils/pagination.dart';
import '../../utils/polling.dart';
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
  late SmartPoller _poller;
  late RequestDeduplicator<List<Order>> _deduplicator;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    // Initialize request deduplicator
    _deduplicator = RequestDeduplicator();

    // Initialize smart poller for active orders
    _poller = SmartPoller(
      onPoll: () => _load(silent: true),
      getInterval: (_) => const Duration(seconds: 20),
    );

    _load();
    _poller.startPolling('pending');
    _scrollController.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(OrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
  }

  @override
  void dispose() {
    _poller.stop();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _deduplicator.clear();
    super.dispose();
  }

  /// Handle scroll events for potential pagination.
  void _handleScroll() {
    if (_scrollController.position.pixels > _scrollController.position.maxScrollExtent - 500) {
      // Could implement pagination here for users with many orders
    }
  }

  /// Load all orders with deduplication.
  /// [silent] = true skips error UI (for background refresh)
  Future<void> _load({bool silent = false}) async {
    try {
      final orders = await _deduplicator.dedupe('myOrders', () => Api.instance.myOrders());
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _error = null;
      });
    } catch (e) {
      if (mounted && !silent) setState(() => _error = e);
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
      body = const ListView(
        children: [
          SizedBox(height: 80),
          EmptyState(
            emoji: '🧾',
            title: 'Aucune commande',
            message: 'Vos commandes apparaîtront ici.',
          ),
        ],
      );
    } else {
      // Use ListView.builder for efficient rendering of large lists
      body = ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: (active.isNotEmpty ? 1 : 0) + active.length + (past.isNotEmpty ? 1 : 0) + past.length,
        itemBuilder: (context, index) {
          int pos = 0;

          // "En cours" section header
          if (active.isNotEmpty) {
            if (index == pos) return const SectionTitle('En cours');
            pos++;
          }

          // Active orders
          if (index < pos + active.length) {
            return _card(active[index - pos], index - pos);
          }
          pos += active.length;

          // "Historique" section header
          if (past.isNotEmpty) {
            if (index == pos) return const SectionTitle('Historique');
            pos++;
          }

          // Past orders
          return _card(past[index - pos], active.length + (index - pos));
        },
      );
    }

    return Scaffold(
      appBar: const AppBar(title: Text('Mes commandes')),
      body: RefreshIndicator(onRefresh: () => _load(silent: false), child: body),
    );
  }

  /// Build order card with fade-in animation and proper key tracking.
  /// Using ValueKey prevents rebuild jank when list order changes.
  Widget _card(Order o, int index) => FadeSlideIn(
    key: ValueKey('order-${o.id}'), // Stable key for list tracking
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
          _load(); // Refresh after returning from detail screen
        },
      ),
    ),
  );
}
