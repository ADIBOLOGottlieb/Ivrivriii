import 'package:flutter/material.dart';

import '../../services/admin_api.dart';
import '../../utils/format.dart';
import '../../utils/polling.dart';
import '../../widgets/animations.dart';
import '../shared/order_detail_screen.dart';
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
  static const dashboardTab = 0, ordersTab = 1, menuTab = 2, moreTab = 3;
  int _index = 0;
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

  @override
  Widget build(BuildContext context) {
    final reviewCount = paymentReviewCount.value;
    return Scaffold(
      body: FadeIndexedStack(
        index: _index,
        children: [
          DashboardScreen(active: _index == dashboardTab),
          AdminOrdersScreen(active: _index == ordersTab),
          const AdminMenuScreen(),
          const AdminMoreScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: goTo,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: 'Tableau de bord',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _pendingCount > 0,
              label: Text('$_pendingCount'),
              child: BounceOnChange(trigger: _pendingCount, child: const Icon(Icons.receipt_long_outlined)),
            ),
            selectedIcon: Badge(
              isLabelVisible: _pendingCount > 0,
              label: Text('$_pendingCount'),
              child: BounceOnChange(trigger: _pendingCount, child: const Icon(Icons.receipt_long_rounded)),
            ),
            label: 'Commandes',
          ),
          const NavigationDestination(
            icon: Icon(Icons.restaurant_menu_outlined),
            selectedIcon: Icon(Icons.restaurant_menu_rounded),
            label: 'Menu',
          ),
          // Badge : paiements mobile money à vérifier (accès via « Plus »).
          NavigationDestination(
            icon: Badge(
              isLabelVisible: reviewCount > 0,
              label: Text('$reviewCount'),
              child: BounceOnChange(trigger: reviewCount, child: const Icon(Icons.more_horiz_rounded)),
            ),
            label: 'Plus',
          ),
        ],
      ),
    );
  }
}
