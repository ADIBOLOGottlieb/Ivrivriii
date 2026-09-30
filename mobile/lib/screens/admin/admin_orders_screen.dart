import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../shared/order_card.dart';
import '../shared/order_detail_screen.dart';
import 'admin_shell.dart';

class AdminOrdersScreen extends StatefulWidget {
  final bool active;
  const AdminOrdersScreen({super.key, this.active = false});

  @override
  State<AdminOrdersScreen> createState() => _AdminOrdersScreenState();
}

class _AdminOrdersScreenState extends State<AdminOrdersScreen> {
  static const _filters = <String, String>{
    'active': 'En cours',
    'pending': 'En attente',
    'delivered': 'Terminées',
    'cancelled': 'Annulées',
    'all': 'Toutes',
  };

  String _filter = 'active';
  List<Order>? _orders;
  Object? _error;
  Timer? _timer;
  int? _lastMaxId;
  final Set<int> _updating = {};

  @override
  void initState() {
    super.initState();
    _load();
    // Vérifie régulièrement l'arrivée de nouvelles commandes.
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _load(silent: true));
  }

  @override
  void didUpdateWidget(AdminOrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final filter = _filter;
    try {
      final results = await Future.wait([
        Api.instance.adminOrders(status: filter == 'all' ? null : filter),
        Api.instance.adminOrders(status: 'pending'),
      ]);
      // Ignore une réponse arrivée après un changement de filtre.
      if (!mounted || filter != _filter) return;
      final pending = results[1];
      final maxId = pending.isEmpty ? null : pending.map((o) => o.id).reduce((a, b) => a > b ? a : b);
      if (silent && maxId != null && _lastMaxId != null && maxId > _lastMaxId!) {
        showMessage(context, '🔔 Nouvelle commande reçue !');
      }
      if (maxId != null && (_lastMaxId == null || maxId > _lastMaxId!)) _lastMaxId = maxId;
      AdminShell.of(context)?.setPendingCount(pending.length);
      setState(() {
        _orders = results[0];
        _error = null;
      });
    } catch (e) {
      if (mounted && !silent) setState(() => _error = e);
    }
  }

  Future<void> _advance(Order o, String status) async {
    setState(() => _updating.add(o.id));
    try {
      await Api.instance.setOrderStatus(o.id, status);
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _updating.remove(o.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Commandes'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              children: [
                for (final f in _filters.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.value),
                      selected: _filter == f.key,
                      showCheckmark: false,
                      selectedColor: AppColors.red,
                      backgroundColor: Colors.white,
                      labelStyle: TextStyle(
                        color: _filter == f.key ? Colors.white : AppColors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                      onSelected: (_) {
                        setState(() {
                          _filter = f.key;
                          _orders = null;
                        });
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: orders == null
            ? (_error != null
                ? ListView(children: [ErrorRetry(error: _error!, onRetry: _load)])
                : const Center(child: CircularProgressIndicator()))
            : orders.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 80),
                    EmptyState(emoji: '✅', title: 'Aucune commande ici'),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.all(20),
                    itemCount: orders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final o = orders[i];
                      final next = o.status == 'cancelled' ? null : nextStatus(o.status, o.isDelivery);
                      return FadeSlideIn(
                        key: ValueKey('$_filter-${o.id}'),
                        delay: FadeSlideIn.stagger(i),
                        child: OrderCard(
                        order: o,
                        showCustomer: true,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => OrderDetailScreen(orderId: o.id, initial: o, admin: true),
                            ),
                          );
                          _load();
                        },
                        trailingAction: next == null
                            ? null
                            : FilledButton.tonalIcon(
                                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                                onPressed: _updating.contains(o.id) ? null : () => _advance(o, next),
                                icon: Icon(statusIcon(next), size: 18),
                                label: Text(statusLabel(next, delivery: o.isDelivery)),
                              ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
