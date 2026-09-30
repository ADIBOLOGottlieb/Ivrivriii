import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/auth_provider.dart';
import 'providers/cart_provider.dart';
import 'screens/admin/admin_shell.dart';
import 'screens/auth/login_screen.dart';
import 'screens/client/client_shell.dart';
import 'screens/splash_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()..init()),
        ChangeNotifierProvider(create: (_) => CartProvider()),
      ],
      child: const IvrivriiApp(),
    ),
  );
}

class IvrivriiApp extends StatelessWidget {
  const IvrivriiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ivrivrii Chicken',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _Root(),
    );
  }
}

/// Aiguille vers l'espace client ou admin selon le compte connecté.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final Widget child;
    if (auth.initializing) {
      child = const SplashScreen();
    } else if (auth.user == null) {
      child = const LoginScreen();
    } else if (auth.user!.isAdmin) {
      child = const AdminShell();
    } else {
      child = const ClientShell();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: KeyedSubtree(key: ValueKey(child.runtimeType), child: child),
    );
  }
}
