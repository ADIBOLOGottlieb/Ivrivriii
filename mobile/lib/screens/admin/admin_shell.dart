import 'package:flutter/material.dart';

import '../../widgets/animations.dart';
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

  void goTo(int index) => setState(() => _index = index);

  void setPendingCount(int n) {
    if (n != _pendingCount) setState(() => _pendingCount = n);
  }

  @override
  Widget build(BuildContext context) {
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
          const NavigationDestination(
            icon: Icon(Icons.more_horiz_rounded),
            label: 'Plus',
          ),
        ],
      ),
    );
  }
}
