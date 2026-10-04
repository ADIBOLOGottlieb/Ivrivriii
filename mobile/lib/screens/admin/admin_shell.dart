import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/admin_api.dart';
import '../../utils/format.dart';
import '../../utils/polling.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart' show AppLogo;
import '../shared/order_detail_screen.dart';
import 'admin_layout.dart';
import 'admin_menu_screen.dart';
import 'admin_more_screen.dart';
import 'admin_orders_screen.dart';
import 'dashboard_screen.dart';

class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  static AdminShellState? of(BuildContext context) => context.findAncestorStateOfType<AdminShellState>();

  @override
  State<AdminShell> createState() => AdminShellState();
}

class AdminShellState extends State<AdminShell> {
  /// Identifiants des onglets (indépendants de leur position : le compte « cuisine » n'a pas de tableau de bord).
  static const dashboardTab = 0, ordersTab = 1, menuTab = 2, moreTab = 3;
  int _index = 0; // identifiant de l'onglet affiché
  int _pendingCount = 0;

  // Paiements reçus : toutes les 20 s, jamais quand l'application est en arrière-plan.
  late final SmartPoller _paymentsPoller =
      SmartPoller(onPoll: _pollPayments, getInterval: (_) => const Duration(seconds: 20));
  bool _pollingPayments = false;

  /// Dernier paiement reçu connu (null tant que le premier chargement n'a pas abouti :
  /// pas de notification pour les paiements antérieurs à l'ouverture de l'espace admin).
  int? _lastPaymentId;

  @override
  void initState() {
    super.initState();
    paymentReviewCount.addListener(_onReviewCountChanged);
    // Paiements : réservés au gérant (le compte « cuisine » recevrait un refus 403).
    if (context.read<AuthProvider>().user?.isKitchen ?? false) return;
    _pollPayments();
    _paymentsPoller.startPolling('on');
  }

  @override
  void dispose() {
    _paymentsPoller.stop();
    paymentReviewCount.removeListener(_onReviewCountChanged);
    super.dispose();
  }

  void _onReviewCountChanged() {
    if (mounted) setState(() {});
  }

  void goTo(int index) {
    // Ferme le clavier (ex : recherche) pour qu'il ne masque pas la barre d'onglets.
    FocusManager.instance.primaryFocus?.unfocus();
    if (index != _index) setState(() => _index = index);
  }

  void setPendingCount(int n) {
    if (n != _pendingCount) setState(() => _pendingCount = n);
  }

  /// Paiements reçus (notification) et nombre de paiements à vérifier (badge).
  Future<void> _pollPayments() async {
    if (_pollingPayments) return;
    _pollingPayments = true;
    try {
      final last = _lastPaymentId;
      final recent = await fetchRecentPayments(sinceId: last);
      if (!mounted) return;
      var maxId = last ?? 0;
      for (final p in recent) {
        if (p.id > maxId) maxId = p.id;
      }
      if (last != null) {
        final fresh = recent.where((p) => p.id > last).toList()..sort((a, b) => a.id.compareTo(b.id));
        final messenger = ScaffoldMessenger.of(context);
        for (final p in fresh) {
          messenger.showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
            content: Row(
              children: [
                const Icon(Icons.payments_rounded, color: Colors.lightGreenAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Paiement reçu – commande n°${p.orderId} – ${formatPrice(p.amount)} – '
                    '${paymentLabel(p.operator)}',
                  ),
                ),
              ],
            ),
            action: SnackBarAction(label: 'Voir', onPressed: () => _openOrder(p.orderId)),
          ));
        }
      }
      _lastPaymentId = maxId;
    } catch (_) {
      // Non bloquant : on réessaiera au prochain passage.
    }
    try {
      await fetchPaymentsReview(); // met à jour paymentReviewCount
    } catch (_) {
      // Non bloquant.
    } finally {
      _pollingPayments = false;
    }
  }

  void _openOrder(int orderId) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: orderId, admin: true)),
    );
  }

  /// Onglets visibles : le compte « cuisine » n'a ni tableau de bord ni argent.
  List<int> _tabsFor(bool kitchen) =>
      kitchen ? const [ordersTab, menuTab, moreTab] : const [dashboardTab, ordersTab, menuTab, moreTab];

  Widget _page(int tab) => switch (tab) {
        dashboardTab => DashboardScreen(active: _index == dashboardTab),
        ordersTab => AdminOrdersScreen(active: _index == ordersTab),
        menuTab => const AdminMenuScreen(),
        _ => const AdminMoreScreen(),
      };

  Widget _badge(int count, IconData icon) => Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: BounceOnChange(trigger: count, child: Icon(icon)),
      );

  /// Icône, icône sélectionnée et libellé d'un onglet.
  (Widget, Widget, String) _destination(int tab, int reviewCount) => switch (tab) {
        dashboardTab => (
            const Icon(Icons.dashboard_outlined),
            const Icon(Icons.dashboard_rounded),
            'Tableau de bord',
          ),
        ordersTab => (
            _badge(_pendingCount, Icons.receipt_long_outlined),
            _badge(_pendingCount, Icons.receipt_long_rounded),
            'Commandes',
          ),
        menuTab => (
            const Icon(Icons.restaurant_menu_outlined),
            const Icon(Icons.restaurant_menu_rounded),
            'Menu',
          ),
        // Badge : paiements mobile money à vérifier (accès via « Plus »).
        _ => (
            _badge(reviewCount, Icons.more_horiz_rounded),
            _badge(reviewCount, Icons.more_horiz_rounded),
            'Plus',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final kitchen = context.watch<AuthProvider>().user?.isKitchen ?? false;
    final reviewCount = kitchen ? 0 : paymentReviewCount.value;
    final tabs = _tabsFor(kitchen);
    // Onglet courant absent pour ce rôle (ex. tableau de bord en cuisine) : premier onglet visible.
    if (!tabs.contains(_index)) _index = tabs.first;
    final selected = tabs.indexOf(_index);
    final destinations = [for (final t in tabs) _destination(t, reviewCount)];

    final body = FadeIndexedStack(
      index: selected,
      children: [for (final t in tabs) _page(t)],
    );

    final width = MediaQuery.sizeOf(context).width;
    if (width >= adminTabletBreakpoint) {
      // Tablette : barre de navigation latérale (étendue sur grand écran) au lieu de la barre du bas.
      final extended = width >= adminRailExtendedBreakpoint;
      return Scaffold(
        body: SafeArea(
          right: false,
          bottom: false,
          child: Row(
            children: [
              NavigationRail(
                extended: extended,
                minExtendedWidth: 220,
                selectedIndex: selected,
                onDestinationSelected: (i) => goTo(tabs[i]),
                labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: AppLogo(size: extended ? 56 : 44),
                ),
                destinations: [
                  for (final d in destinations)
                    NavigationRailDestination(icon: d.$1, selectedIcon: d.$2, label: Text(d.$3)),
                ],
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (i) => goTo(tabs[i]),
        destinations: [
          for (final d in destinations) NavigationDestination(icon: d.$1, selectedIcon: d.$2, label: d.$3),
        ],
      ),
    );
  }
}
