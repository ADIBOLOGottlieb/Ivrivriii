import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/admin_api.dart' show fetchOrdersPage, mergeFirstPage, oldestOrderId, ordersPageSize;
import '../../services/api.dart';
import '../../services/order_alert.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../utils/polling.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../shared/order_card.dart';
import '../shared/order_detail_screen.dart';
import 'admin_shell.dart';
import 'kitchen_display_screen.dart';

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

  /// Commandes en cours chargées d'un coup (une seule requête par cycle : liste, badge et alerte).
  static const _activeLimit = 200;

  String _filter = 'active';
  List<Order>? _orders;
  Object? _error;
  bool _hasMore = false;
  bool _loadingMore = false;
  int _gen = 0; // seule la dernière requête lancée est affichée
  bool _alertPrimed = false; // premier passage : commandes déjà là mémorisées sans sonner
  final Set<int> _updating = {};
  int? _selectedId; // tablette : commande affichée dans le panneau de détail
  late final SmartPoller _poller;

  @override
  void initState() {
    super.initState();
    OrderAlert.instance.init();
    // Toutes les 20 s, seulement quand l'onglet est affiché, sans écran par-dessus, app au premier plan.
    _poller = SmartPoller(
      onPoll: () => _load(silent: true),
      getInterval: (_) => const Duration(seconds: 20),
      canPoll: () => isRouteOnTop(context),
    );
    _poller.startPolling('on');
    if (!widget.active) _poller.pause();
    _load(); // premier chargement : badge « en attente »
  }

  @override
  void didUpdateWidget(AdminOrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    if (widget.active) {
      _poller.resume(pollNow: false);
      _load();
    } else {
      _poller.pause();
    }
  }

  @override
  void dispose() {
    _poller.stop();
    super.dispose();
  }

  /// Les filtres « En cours » et « En attente » sont servis par la même requête (commandes en cours).
  bool get _fromActive => _filter == 'active' || _filter == 'pending';

  String? get _apiStatus => _filter == 'all' ? null : _filter;

  /// Une seule requête : commandes en cours (filtres En cours / En attente, badge, alerte
  /// nouvelle commande) ou, pour l'historique, la première page du filtre choisi.
  /// Le rafraîchissement automatique ([silent]) ne recharge que les commandes en cours.
  Future<void> _load({bool silent = false}) async {
    final filter = _filter;
    // Le suivi automatique sur un filtre d'historique ne touche pas à la liste affichée.
    final gen = (_fromActive || !silent) ? ++_gen : _gen;
    try {
      if (_fromActive || silent) {
        final active = await fetchOrdersPage(admin: true, status: 'active', limit: _activeLimit);
        if (!mounted) return;
        _onActiveOrders(active, silent: silent);
        if (gen != _gen || filter != _filter || !_fromActive) return;
        setState(() {
          _orders = filter == 'pending' ? active.where((o) => o.status == 'pending').toList() : active;
          _hasMore = false;
          _error = null;
        });
      } else {
        final page = await fetchOrdersPage(admin: true, status: _apiStatus);
        if (!mounted || gen != _gen || filter != _filter) return;
        final merged = mergeFirstPage(page, _orders);
        setState(() {
          _orders = merged;
          _hasMore = page.length >= ordersPageSize && (merged.length > page.length ? _hasMore : true);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && gen == _gen && !silent) setState(() => _error = e);
    }
  }

  /// Badge « en attente » et alerte quand une nouvelle commande à préparer arrive : sonnerie en
  /// boucle jusqu'à « J'ai vu » (sauf ventes saisies à la caisse de cet appareil, cf. OrderAlert).
  /// Chargement manuel (non [silent]) : les commandes affichées sont mémorisées sans sonner.
  void _onActiveOrders(List<Order> active, {required bool silent}) {
    final pending = active.where((o) => o.status == 'pending').toList();
    final fresh = OrderAlert.instance.checkOrders(active, prime: !silent || !_alertPrimed);
    _alertPrimed = true;
    if (fresh.isNotEmpty) showMessage(context, '🔔 Nouvelle commande reçue !');
    AdminShell.of(context)?.setPendingCount(pending.length);
  }

  Future<void> _openKitchenDisplay() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const KitchenDisplayScreen()));
    if (mounted) _load();
  }

  /// « Charger plus » (historique) : commandes plus anciennes.
  Future<void> _loadMore() async {
    final before = oldestOrderId(_orders);
    if (_loadingMore || before == null || _fromActive) return;
    final filter = _filter;
    setState(() => _loadingMore = true);
    try {
      final page = await fetchOrdersPage(admin: true, status: _apiStatus, beforeId: before);
      if (!mounted || filter != _filter) return;
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

  void _selectFilter(String f) {
    if (f == _filter) return;
    setState(() {
      _filter = f;
      _orders = null;
      _hasMore = false;
      _error = null;
    });
    _load();
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Commandes'),
        actions: [
          TextButton.icon(
            onPressed: _openKitchenDisplay,
            icon: const Icon(Icons.soup_kitchen_rounded),
            label: const Text('Écran cuisine'),
          ),
          IconButton(tooltip: 'Actualiser', onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
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
                      backgroundColor: scheme.surface,
                      labelStyle: TextStyle(
                        color: _filter == f.key ? Colors.white : scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                      onSelected: (_) => _selectFilter(f.key),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        // Tablette : maître/détail (liste à gauche, commande choisie à droite).
        if (constraints.maxWidth < _splitWidth) return _list(orders, split: false);
        return Row(
          children: [
            SizedBox(width: constraints.maxWidth >= 1100 ? 440 : 380, child: _list(orders, split: true)),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(child: _detailPane(orders)),
          ],
        );
      }),
    );
  }

  /// Largeur (zone de contenu) à partir de laquelle la liste et le détail s'affichent côte à côte.
  static const _splitWidth = 720.0;

  Widget _detailPane(List<Order>? orders) {
    final id = _selectedId;
    // Onglet masqué : pas de détail (et donc pas de suivi automatique en arrière-plan).
    if (id == null || !widget.active) {
      return const EmptyState(
        emoji: '🧾',
        title: 'Choisissez une commande',
        message: 'Son détail et ses actions s\'affichent ici.',
      );
    }
    final initial = orders?.where((o) => o.id == id).firstOrNull;
    return OrderDetailScreen(key: ValueKey('detail-$id'), orderId: id, initial: initial, admin: true);
  }

  Widget _list(List<Order>? orders, {required bool split}) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
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
                    itemCount: orders.length + (_hasMore ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      if (i == orders.length) return _loadMoreButton();
                      final o = orders[i];
                      // En livraison : « Livrée » seulement après « Livraison faite » du livreur
                      // (sinon l'admin force depuis le détail de la commande).
                      final next = o.status == 'cancelled'
                          ? null
                          : adminNextStatus(o.status, o.isDelivery, driverDelivered: o.driverDeliveredAt != null);
                      final card = FadeSlideIn(
                        key: ValueKey('$_filter-${o.id}'),
                        delay: FadeSlideIn.stagger(i),
                        child: OrderCard(
                          order: o,
                          showCustomer: true,
                          onTap: () async {
                            if (split) {
                              // Tablette : détail affiché à droite de la liste.
                              setState(() => _selectedId = o.id);
                              return;
                            }
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => OrderDetailScreen(orderId: o.id, initial: o, admin: true),
                              ),
                            );
                            if (mounted) _load();
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
                      if (!split) return card;
                      // Commande affichée à droite : bordure de sélection.
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: o.id == _selectedId ? scheme.primary : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: card,
                      );
                    },
                  ),
    );
  }

  Widget _loadMoreButton() => Center(
        child: _loadingMore
            ? const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())
            : OutlinedButton.icon(
                onPressed: _loadMore,
                icon: const Icon(Icons.expand_more_rounded),
                label: const Text('Charger plus'),
              ),
      );
}
