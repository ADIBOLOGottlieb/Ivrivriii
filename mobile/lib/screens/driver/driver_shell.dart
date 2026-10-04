import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/app_nav_bar.dart';
import '../../models.dart';
import '../../services/driver_api.dart';
import '../../services/driver_tracker.dart';
import '../../widgets/animations.dart';
import 'driver_orders_screen.dart';
import 'driver_profile_screen.dart';
import 'driver_tracking_banner.dart';
import 'driver_actions.dart';

/// Espace livreur : À livrer, Mes livraisons, Historique, Profil.
class DriverShell extends StatefulWidget {
  const DriverShell({super.key});

  static DriverShellState? of(BuildContext context) => context.findAncestorStateOfType<DriverShellState>();

  @override
  State<DriverShell> createState() => DriverShellState();
}

class DriverShellState extends State<DriverShell> {
  static const availableTab = 0, mineTab = 1, historyTab = 2, profileTab = 3;
  static const _pollInterval = Duration(seconds: 20);

  int _index = availableTab;
  int _availableCount = 0;
  int _mineCount = 0;

  /// Livraisons « À livrer » déjà connues (null avant le premier chargement :
  /// pas d'alerte pour celles présentes à l'ouverture).
  Set<int>? _knownAvailable;
  Timer? _timer;
  int _ticks = 0;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _pollAvailable();
    _timer = Timer.periodic(_pollInterval, (_) {
      // L'onglet « À livrer » visible se rafraîchit lui-même ; ailleurs, on surveille ici.
      final state = WidgetsBinding.instance.lifecycleState;
      final foreground = state == null || state == AppLifecycleState.resumed;
      if (foreground && _index != availableTab) _pollAvailable();
      // Livraison attribuée par le restaurant pendant qu'on était ailleurs : le partage démarre
      // (vérifié toutes les minutes seulement, et seulement s'il ne tourne pas déjà).
      if (foreground && ++_ticks % 3 == 0 && !DriverTracker.instance.wanted) {
        DriverTracker.instance.refresh(currentUserId(context));
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Déconnexion : plus de partage de position.
    DriverTracker.instance.stop();
    super.dispose();
  }

  void goTo(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (index != _index) setState(() => _index = index);
  }

  Future<void> _pollAvailable() async {
    if (_polling) return;
    _polling = true;
    try {
      final list = await fetchDriverOrders(driverScopeAvailable);
      if (mounted) _onAvailable(list);
    } catch (_) {
      // Non bloquant : on réessaiera au prochain passage.
    } finally {
      _polling = false;
    }
  }

  /// Compare avec les livraisons connues : alerte pour chaque nouvelle arrivée.
  void _onAvailable(List<Order> list) {
    final ids = {for (final o in list) o.id};
    final known = _knownAvailable;
    _knownAvailable = ids;
    if (list.length != _availableCount) setState(() => _availableCount = list.length);
    if (known == null) return;
    final fresh = list.where((o) => !known.contains(o.id)).toList();
    if (fresh.isEmpty) return;
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    final first = fresh.first;
    final address = (first.address ?? '').trim();
    final text = fresh.length == 1
        ? 'Nouvelle livraison n°${first.id}${address.isEmpty ? '' : ' – $address'}'
        : '${fresh.length} nouvelles livraisons à prendre';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
          content: Row(
            children: [
              const Icon(Icons.delivery_dining_rounded, color: Colors.lightGreenAccent),
              const SizedBox(width: 10),
              Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis)),
            ],
          ),
          action: _index == availableTab ? null : SnackBarAction(label: 'Voir', onPressed: () => goTo(availableTab)),
        ),
      );
  }

  void _onMine(List<Order> list) {
    final n = list.where((o) => !o.awaitingReceipt).length;
    if (n != _mineCount) setState(() => _mineCount = n);
    // Ouverture de l'espace livreur, rafraîchissement : partage de position si une livraison est en cours.
    DriverTracker.instance.syncWith(list, currentUserId(context));
  }

  void _onTaken(Order o) => goTo(mineTab);

  Widget _badgeIcon(IconData icon, int count) => Badge(
    isLabelVisible: count > 0,
    label: Text('$count'),
    child: BounceOnChange(trigger: count, child: Icon(icon)),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FadeIndexedStack(
        index: _index,
        children: [
          DriverOrdersScreen(
            scope: driverScopeAvailable,
            title: 'À livrer',
            active: _index == availableTab,
            onLoaded: _onAvailable,
            onTaken: _onTaken,
          ),
          DriverOrdersScreen(
            scope: driverScopeMine,
            title: 'Mes livraisons',
            active: _index == mineTab,
            onLoaded: _onMine,
          ),
          DriverOrdersScreen(scope: driverScopeHistory, title: 'Historique', active: _index == historyTab),
          DriverProfileScreen(active: _index == profileTab),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const DriverTrackingBanner(),
          AppNavBar(
            selectedIndex: _index,
            onSelected: goTo,
            items: [
              AppNavItem(
                icon: _badgeIcon(Icons.delivery_dining_outlined, _availableCount),
                selectedIcon: _badgeIcon(Icons.delivery_dining_rounded, _availableCount),
                label: 'À livrer',
              ),
              AppNavItem(
                icon: _badgeIcon(Icons.two_wheeler_outlined, _mineCount),
                selectedIcon: _badgeIcon(Icons.two_wheeler_rounded, _mineCount),
                label: 'En cours',
              ),
              const AppNavItem(icon: Icon(Icons.history_rounded), label: 'Historique'),
              const AppNavItem(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Profil',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
