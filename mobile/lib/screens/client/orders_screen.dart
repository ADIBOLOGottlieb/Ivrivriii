import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/admin_api.dart' show fetchOrdersPage, mergeFirstPage, oldestOrderId, ordersPageSize;
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
  static const _activeStatus = 'active', _idleStatus = 'idle';

  List<Order>? _orders;
  Object? _error;
  bool _hasMore = false;
  bool _loadingMore = false;
  late final SmartPoller _poller;
  // Seule la réponse de la dernière requête lancée est affichée (pas d'ancienne liste « En attente »).
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    // Suivi toutes les 20 s, seulement s'il y a une commande en cours et que l'onglet est affiché.
    _poller = SmartPoller(
      onPoll: () => _load(silent: true),
      getInterval: (s) => s == _activeStatus ? const Duration(seconds: 20) : null,
      canPoll: () => isRouteOnTop(context),
    );
    _poller.startPolling(_idleStatus);
    if (!widget.active) _poller.pause();
    _load();
    ordersChanged.addListener(_onOrdersChanged);
  }

  @override
  void didUpdateWidget(OrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      widget.active ? _poller.resume(pollNow: false) : _poller.pause();
    }
    if ((widget.active && !old.active) || widget.refreshToken != old.refreshToken) _load(silent: true);
  }

  @override
  void dispose() {
    ordersChanged.removeListener(_onOrdersChanged);
    _poller.stop();
    super.dispose();
  }

  void _onOrdersChanged() => _load(silent: true);

  /// Charge (ou rafraîchit) la première page. [silent] = true : pas d'écran d'erreur.
  Future<void> _load({bool silent = false}) async {
    final gen = ++_gen;
    try {
      final page = await fetchOrdersPage();
      if (!mounted || gen != _gen) return;
      final merged = mergeFirstPage(page, _orders);
      setState(() {
        _orders = merged;
        _hasMore = page.length >= ordersPageSize && (merged.length > page.length ? _hasMore : true);
        _error = null;
      });
      _poller.updateStatus(merged.any((o) => !o.isFinished) ? _activeStatus : _idleStatus);
    } catch (e) {
      if (mounted && gen == _gen && !silent) setState(() => _error = e);
    }
  }

  /// « Charger plus » : commandes plus anciennes.
  Future<void> _loadMore() async {
    final before = oldestOrderId(_orders);
    if (_loadingMore || before == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await fetchOrdersPage(beforeId: before);
      if (!mounted) return;
      setState(() {
        final current = _orders ?? [];
        final oldest = oldestOrderId(current) ?? before;
        _orders = [...current, ...page.where((o) => o.id < oldest)];
        _hasMore = page.length >= ordersPageSize;
      });
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
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
      final count =
          (active.isNotEmpty ? 1 : 0) + active.length + (past.isNotEmpty ? 1 : 0) + past.length + (_hasMore ? 1 : 0);
      body = ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: count,
        itemBuilder: (context, index) {
          if (_hasMore && index == count - 1) return _loadMoreButton();
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

  Widget _loadMoreButton() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Center(
          child: _loadingMore
              ? const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())
              : OutlinedButton.icon(
                  onPressed: _loadMore,
                  icon: const Icon(Icons.expand_more_rounded),
                  label: const Text('Charger plus'),
                ),
        ),
      );

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
