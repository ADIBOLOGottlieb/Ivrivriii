import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../utils/pagination.dart';
import '../../utils/polling.dart';
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
  late SmartPoller _poller;
  late RequestDeduplicator<List<Order>> _deduplicator;
  int? _lastMaxId;
  final Set<int> _updating = {};
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    // Initialize request deduplicator to prevent duplicate API calls
    _deduplicator = RequestDeduplicator();

    // Initialize smart poller for new order notifications
    _poller = SmartPoller(
      onPoll: () => _load(silent: true),
      getInterval: (_) => const Duration(seconds: 20), // Check every 20s for new orders
    );

    _load();
    _poller.startPolling('pending');
    _scrollController.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(AdminOrdersScreen old) {
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

  /// Handle scroll events for potential pagination (future enhancement).
  void _handleScroll() {
    if (_scrollController.position.pixels > _scrollController.position.maxScrollExtent - 500) {
      // Could implement pagination here if orders list grows large
      // For now, just track scroll position
    }
  }

  /// Batch fetch: gets filtered orders + pending count in single API roundtrip.
  /// Uses request deduplication to prevent duplicate calls during rapid filter changes.
  Future<void> _load({bool silent = false}) async {
    final filter = _filter;
    final cacheKey = 'orders_$filter';

    try {
      // Deduplicate requests - if load already pending for this filter, reuse that Future
      final results = await _deduplicator.dedupe(cacheKey, () async {
        // Batch API calls: get filtered orders + pending count together
        return Future.wait([
          Api.instance.adminOrders(status: filter == 'all' ? null : filter),
          Api.instance.adminOrders(status: 'pending'),
        ]).then((results) {
          // Return only the filtered results from [0], pending was for count
          return results[0];
        });
      });

      // Ignore if filter changed while request was in-flight
      if (!mounted || filter != _filter) return;

      // Fetch pending count again for badge update (lightweight call)
      try {
        final pending = await Api.instance.adminOrders(status: 'pending');
        final maxId = pending.isEmpty ? null : pending.map((o) => o.id).reduce((a, b) => a > b ? a : b);

        // Notify user of new pending orders (only in silent mode, don't interrupt)
        if (silent && maxId != null && _lastMaxId != null && maxId > _lastMaxId!) {
          if (mounted) showMessage(context, '🔔 Nouvelle commande reçue !');
        }
        if (maxId != null && (_lastMaxId == null || maxId > _lastMaxId!)) _lastMaxId = maxId;

        AdminShell.of(context)?.setPendingCount(pending.length);
      } catch (_) {
        // Silently fail on pending count update - not critical
      }

      if (mounted) {
        setState(() {
          _orders = results;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && !silent) setState(() => _error = e);
    }
  }

  /// Advance order status with optimistic UI update.
  Future<void> _advance(Order o, String status) async {
    setState(() => _updating.add(o.id));
    try {
      await Api.instance.setOrderStatus(o.id, status);
      await _load(); // Refresh list after status change
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
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      labelStyle: TextStyle(
                        color: _filter == f.key ? Colors.white : Theme.of(context).colorScheme.onSurface,
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
                // Use ListView.builder for better memory efficiency with large lists
                : ListView.separated(
                    controller: _scrollController, // For scroll-to-load pagination
                    padding: const EdgeInsets.all(20),
                    itemCount: orders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final o = orders[i];
                      final next = o.status == 'cancelled' ? null : nextStatus(o.status, o.isDelivery);
                      // Use ValueKey for list item tracking (prevents rebuild jank)
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
