import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../widgets/app_nav_bar.dart';
import '../../providers/cart_provider.dart';
import '../../widgets/animations.dart';
import 'cart_screen.dart';
import 'home_screen.dart';
import 'orders_screen.dart';
import 'profile_screen.dart';

class ClientShell extends StatefulWidget {
  const ClientShell({super.key});

  static ClientShellState? of(BuildContext context) => context.findAncestorStateOfType<ClientShellState>();

  @override
  State<ClientShell> createState() => ClientShellState();
}

class ClientShellState extends State<ClientShell> {
  static const menuTab = 0, cartTab = 1, ordersTab = 2, profileTab = 3;
  int _index = 0;
  int _ordersRefresh = 0; // incrémenté à chaque appui sur « Commandes »

  void goTo(int index) {
    // Ferme le clavier (ex : recherche) pour qu'il ne masque pas la barre d'onglets.
    FocusManager.instance.primaryFocus?.unfocus();
    if (index == ordersTab) {
      // Même si l'onglet est déjà affiché : on recharge la liste.
      setState(() {
        _index = index;
        _ordersRefresh++;
      });
    } else if (index != _index) {
      setState(() => _index = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cartCount = context.select<CartProvider, int>((c) => c.count);
    return Scaffold(
      body: FadeIndexedStack(
        index: _index,
        children: [
          const HomeScreen(),
          const CartScreen(),
          OrdersScreen(active: _index == ordersTab, refreshToken: _ordersRefresh),
          const ProfileScreen(),
        ],
      ),
      bottomNavigationBar: AppNavBar(
        selectedIndex: _index,
        onSelected: goTo,
        items: [
          const AppNavItem(
            icon: Icon(Icons.restaurant_menu_outlined),
            selectedIcon: Icon(Icons.restaurant_menu_rounded),
            label: 'Menu',
          ),
          AppNavItem(
            icon: Badge(
              isLabelVisible: cartCount > 0,
              label: Text('$cartCount'),
              child: BounceOnChange(trigger: cartCount, child: const Icon(Icons.shopping_bag_outlined)),
            ),
            selectedIcon: Badge(
              isLabelVisible: cartCount > 0,
              label: Text('$cartCount'),
              child: BounceOnChange(trigger: cartCount, child: const Icon(Icons.shopping_bag_rounded)),
            ),
            label: 'Panier',
          ),
          const AppNavItem(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long_rounded),
            label: 'Commandes',
          ),
          const AppNavItem(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}
